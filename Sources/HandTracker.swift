import AppKit
import AVFoundation
import Vision
import CoreImage
import simd

enum HandIntent: Equatable {
    case pointing
    case palm
    case uncertain
}

enum HandTrackingLimits {
    static let maximumFrameAge:Double = 0.40
    static let occlusionHold:Double = 0.36
    static let arrivalTimeout:Double = 0.55
    static func accepts(_ frame:HandFrame,at now:Double)->Bool {
        let age=now-frame.timestamp
        return age.isFinite && age >= -0.05 && age <= maximumFrameAge+(frame.isHolding ? occlusionHold:0)
    }
}

/// Whole-hand evidence for throwing; a visible thumb is not required.
struct HandThrowObservation {
    var center: SIMD2<Float>
    var palm: SIMD2<Float>
    var closed: Bool
    var open: Bool
    /// Whole-hand evidence; fingertip confidence is only relevant to pointing.
    var confidence: Float? = nil
    /// Two reliably curled fingers sustain an acquired fist when others are occluded.
    var continuingClosed: Bool = false
    /// Any measured finger extension vetoes throwing, even below palm-action confidence.
    var extendedFinger: Bool = false
    func isReliable(fallback:Float)->Bool {
        let value=confidence ?? fallback
        return value.isFinite && value>=0.50
    }
}

/// One whole hand, mirrored like a mirror: x left → right, y bottom → top.
/// Only `.pointing` may guide the dog; only `.palm` may pet it.
struct HandFrame {
    let tip: SIMD2<Float>
    let palm: SIMD2<Float>
    /// Radius in normalized vertical screen units; scale by world/view height.
    let palmRadius: Float
    let intent: HandIntent
    let confidence: Float
    /// Capture timestamp, aligned to the monotonic ProcessInfo.systemUptime clock.
    let timestamp: Double
    /// Brief occlusion: position and timestamp remain the last reliable capture.
    var isHolding: Bool = false
    /// Reliable image-space palm dimensions, in normalized vertical-image units.
    /// Zero means unavailable. These are relative scale cues, never real depth.
    var palmWidth: Float = 0
    var palmLength: Float = 0
    var palmGeometryConfidence: Float = 0
    var throwObservation: HandThrowObservation? = nil
}

/// Small, in-memory camera preview. Image and marker come from the SAME capture.
/// The image is already mirrored; raw marker coordinates are bottom-left 0...1.
/// Unlike HandFrame, these coordinates have no active-area remapping.
struct CameraPreviewFrame {
    var fist: SIMD2<Float>? = nil
    let image: CGImage
    let tip: SIMD2<Float>?
    let palm: SIMD2<Float>?
    let palmRadius: Float
    let intent: HandIntent
    let confidence: Float
    let timestamp: Double
}

enum CameraPreviewProjection {
    static func mirrorPoint(_ point: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(1 - point.x), Float(point.y))
    }
    static func makeImage(_ original: CIImage, context: CIContext) -> CGImage? {
        let mirrored = original.oriented(.upMirrored)
        let scale = min(1, 320 / max(mirrored.extent.width, 1))
        let small = mirrored.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent)
    }
}

/// Lightweight in-memory timing only. No camera images or per-frame log is kept.
struct HandTrackingDiagnostics {
    var processedFrames: UInt64 = 0
    var staleFramesDropped: UInt64 = 0
    var latestCaptureToHandlerMilliseconds: Double = 0
    var latestVisionMilliseconds: Double = 0
    var meanVisionMilliseconds: Double = 0
    var maximumVisionMilliseconds: Double = 0
    var latestPreviewMilliseconds: Double = 0
    var latestCaptureToUpdateMilliseconds: Double = 0
}

/// Protected by HandTracker.callbackLock. Scheduling one UI block is sufficient,
/// because newer camera samples replace the single pending value (including nil).
struct LatestHandFrameMailbox {
    private var pending: HandFrame?
    private var generation: UInt64 = 0
    private var scheduled = false
    mutating func enqueue(_ frame: HandFrame?, generation: UInt64) -> Bool {
        pending = frame
        self.generation = generation
        let needsSchedule = !scheduled
        scheduled = true
        return needsSchedule
    }
    mutating func consume(currentGeneration: UInt64) -> (frame: HandFrame?, valid: Bool) {
        let result = (pending, generation == currentGeneration)
        pending = nil
        scheduled = false
        return result
    }
}

/// Entirely local hand tracking. Instantiation never opens the camera.
/// Both callbacks arrive on the main thread. `nil` means the hand is lost.
/// Include NSCameraUsageDescription in the application's Info.plist.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private typealias Joint = VNHumanHandPoseObservation.JointName
    private let session = AVCaptureSession()
    // Capture setup, Vision and filtering share one serial queue: no races, no UI blocking.
    private let captureQueue = DispatchQueue(label: "LuminousPup.HandTracking", qos: .userInitiated)
    private let callbackLock = NSLock()
    private var updateCallback: ((HandFrame?) -> Void)?
    private var statusCallback: ((String) -> Void)?
    private var previewCallback: ((CameraPreviewFrame?) -> Void)?
    private var pendingPreview: CameraPreviewFrame?
    private var previewDeliveryScheduled = false
    private var previewGeneration: UInt64 = 0
    private var pendingPreviewGeneration: UInt64 = 0
    private var callbackGeneration: UInt64 = 0
    private var updateMailbox = LatestHandFrameMailbox()
    private var timing = HandTrackingDiagnostics()

    var diagnostics: HandTrackingDiagnostics {
        callbackLock.lock(); defer { callbackLock.unlock() }; return timing
    }

    var onUpdate: ((HandFrame?) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return updateCallback }
        set { callbackLock.lock(); updateCallback = newValue; callbackLock.unlock() }
    }
    var onStatus: ((String) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return statusCallback }
        set { callbackLock.lock(); statusCallback = newValue; callbackLock.unlock() }
    }

    var onPreview: ((CameraPreviewFrame?) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return previewCallback }
        set { callbackLock.lock(); previewCallback = newValue; callbackLock.unlock() }
    }

    // Access these properties only on captureQueue.
    private var wanted = false
    private var suspended = false
    private var authorizationPending = false
    private var configured = false
    private var camera: AVCaptureDevice?
    private var output: AVCaptureVideoDataOutput?
    private var watchdog: DispatchSourceTimer?
    private var lastGoodTime: Double?
    private var lastImageTime: Double = 0
    private var startTime: Double = 0
    private var lastVisionTime: Double = 0
    private var lastPreviewTime: Double = 0
    private lazy var previewContext = CIContext(options: [.cacheIntermediates: false])
    private var hadHand = false
    private var lastStatus = ""
    private var poseFilter = HandPoseFilter()
    private var captureClockOffset: Double?
    private var lastCaptureTimestamp: Double = 0
    private var notificationTokens: [NSObjectProtocol] = []
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()

    override init() {
        super.init()
        observe(AVCaptureSession.wasInterruptedNotification, object: session) { tracker, _ in
            tracker.invalidateHand()
            tracker.clearPreview()
            tracker.report("Camera interrupted. Check other camera apps.")
        }
        observe(AVCaptureSession.interruptionEndedNotification, object: session) { tracker, _ in
            if tracker.wanted && !tracker.suspended { tracker.beginIfAuthorized() }
        }
        observe(AVCaptureSession.runtimeErrorNotification, object: session) { tracker, note in
            tracker.invalidateHand()
            tracker.clearPreview()
            if let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                tracker.report("Camera unavailable: \(error.localizedDescription)")
            } else {
                tracker.report("Camera unavailable. Turn Hand off and try again.")
            }
        }
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        watchdog?.cancel()
        output?.setSampleBufferDelegate(nil, queue: nil)
        // Deinitialization must not block the main thread on camera shutdown.
        let existingSession = session
        captureQueue.async { if existingSession.isRunning { existingSession.stopRunning() } }
    }

    /// Safe from any thread. Only this method can trigger the system permission prompt.
    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.captureQueue.async { [weak self] in
                guard let self else { return }
                self.wanted = true
                self.beginIfAuthorized()
            }
        }
    }

    /// Stops capture, clears the latest hand and cancels pending frame delivery.
    func stop() {
        // Match start()'s main-thread hop so rapid start→stop preserves call order.
        DispatchQueue.main.async { [weak self] in
            self?.captureQueue.async { [weak self] in
                guard let self else { return }
                self.wanted = false
                self.pauseCapture(status: "Camera is off")
            }
        }
    }

    /// Explicit lifecycle control: hiding/minimizing pauses capture; losing key
    /// focus does not. The caller should combine its hidden/minimized flags.
    func setSuspended(_ value: Bool) {
        captureQueue.async { [weak self] in
            guard let self, self.suspended != value else { return }
            self.suspended = value
            if value {
                if self.wanted { self.pauseCapture(status: "Camera paused. Return to this window to resume.") }
            } else if self.wanted { self.beginIfAuthorized() }
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject?,
                         handler: @escaping (HandTracker, Notification) -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] note in
            self?.captureQueue.async { [weak self] in
                guard let self else { return }
                handler(self, note)
            }
        }
        notificationTokens.append(token)
    }

    private func beginIfAuthorized() {
        guard wanted else { return }
        guard !suspended else {
            report("Camera paused. Return to this window to resume.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            guard !authorizationPending else { return }
            guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
                report("Open the complete app to use the camera.")
                return
            }
            authorizationPending = true
            report("Allow the camera. Images stay on this Mac.")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                self?.captureQueue.async { [weak self] in
                    guard let self else { return }
                    self.authorizationPending = false
                    if self.wanted { self.beginIfAuthorized() }
                }
            }
        case .denied:
            invalidateHand()
            report("Allow Camera in System Settings > Privacy & Security.")
        case .restricted:
            invalidateHand()
            report("Camera access is restricted by macOS.")
        @unknown default:
            report("Camera permission is unavailable.")
        }
    }

    private func startCapture() {
        guard !session.isRunning else { return }
        do {
            if configured && camera?.isConnected != true {
                session.beginConfiguration()
                output?.setSampleBufferDelegate(nil, queue: nil)
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
                session.commitConfiguration()
                configured = false
                camera = nil
                output = nil
            }
            if !configured { try configureSession() }
            guard let camera, camera.isConnected else {
                report("No camera found. Connect one and try again.")
                return
            }
            guard !camera.isInUseByAnotherApplication else {
                report("Camera in use. Close the other camera app and retry.")
                return
            }
            report("Starting camera…")
            callbackLock.lock(); timing = HandTrackingDiagnostics(); callbackLock.unlock()
            captureClockOffset = nil
            lastCaptureTimestamp = 0
            lastVisionTime = 0
            lastPreviewTime = 0
            startTime = ProcessInfo.processInfo.systemUptime
            lastImageTime = startTime
            session.startRunning()
            guard session.isRunning else {
                report("Camera could not start. Check other camera apps.")
                return
            }
            startWatchdog()
            report("Point to lead. Open your palm to pet.")
        } catch {
            invalidateHand()
            report("Camera could not start: \(error.localizedDescription)")
        }
    }

    private func configureSession() throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw TrackingError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Use the full wide image, retaining detail for smaller/distant hands.
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        else if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else { throw TrackingError.cannotConfigure }
        session.addInput(input)
        guard session.canAddOutput(videoOutput) else {
            session.removeInput(input)
            throw TrackingError.cannotConfigure
        }
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        // Mirror exactly once in coordinate conversion below, regardless of camera defaults.
        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        camera = device
        output = videoOutput
        configured = true
    }

    private func pauseCapture(status: String) {
        watchdog?.cancel()
        watchdog = nil
        if session.isRunning { session.stopRunning() }
        invalidateHand()
        clearPreview()
        report(status)
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 0.04, repeating: 0.04)
        timer.setEventHandler { [weak self] in
            guard let self, self.wanted, !self.suspended else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.expireHand(at: now)
            if now - self.lastImageTime > 2.5 {
                self.clearPreview()
                self.report("No camera frames. Check the connection and other camera apps.")
            }
        }
        watchdog = timer
        timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard wanted, !suspended, session.isRunning else { return }
        let arrivalTime = ProcessInfo.processInfo.systemUptime
        lastImageTime = arrivalTime
        // Prefer the camera's presentation timestamp. Some drivers use a different
        // origin, so align that origin once without replacing capture intervals.
        let presentation = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let timestamp: Double
        if presentation.isFinite && presentation > 0 {
            if captureClockOffset == nil {
                captureClockOffset = abs(presentation - arrivalTime) < 5 ? 0 : arrivalTime - presentation
            }
            timestamp = presentation + (captureClockOffset ?? 0)
        } else {
            timestamp = arrivalTime
        }
        guard timestamp > lastCaptureTimestamp else { return }
        lastCaptureTimestamp = timestamp
        // Keep normal 30 Hz input intact; cap faster cameras without using render dt.
        guard timestamp - lastVisionTime >= 1.0 / 40.0 else { return }
        lastVisionTime = timestamp
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var previewMeasurement: HandMeasurement?
        var previewIntent: HandIntent = .uncertain
        var previewConfidence: Float = 0
        var previewFist = false
        defer {
            publishPreview(pixelBuffer, timestamp: timestamp, measurement: previewMeasurement,
                           intent: previewIntent, confidence: previewConfidence, fist: previewFist)
        }
        do {
            let visionStarted = ProcessInfo.processInfo.systemUptime
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
            let visionMS = (ProcessInfo.processInfo.systemUptime - visionStarted) * 1000
            callbackLock.lock()
            timing.processedFrames &+= 1
            timing.latestCaptureToHandlerMilliseconds = max(0, arrivalTime - timestamp) * 1000
            timing.latestVisionMilliseconds = visionMS
            timing.meanVisionMilliseconds += (visionMS - timing.meanVisionMilliseconds) / Double(timing.processedFrames)
            timing.maximumVisionMilliseconds = max(timing.maximumVisionMilliseconds, visionMS)
            callbackLock.unlock()
            guard let observation = request.results?.first,
                  let recognized = try? observation.recognizedPoints(.all) else {
                handleMissingHand(capturedAt: timestamp)
                return
            }
            previewConfidence = 0.1
            // Anatomical joints are used only to classify the whole hand locally.
            // They are never exposed as separate controls or rendered as a skeleton.
            let samples = recognized.mapValues {
                HandJointSample(position: CameraPreviewProjection.mirrorPoint($0.location),
                                confidence: $0.confidence)
            }
            let aspect = Float(CVPixelBufferGetWidth(pixelBuffer)) / Float(CVPixelBufferGetHeight(pixelBuffer))
            guard let measurement = HandPostureClassifier.measure(samples, aspect: aspect,
                handedness: observation.chirality.rawValue, timestamp: timestamp) else {
                handleMissingHand(capturedAt: timestamp)
                return
            }
            previewMeasurement = measurement
            previewConfidence = measurement.confidence
            guard let frame = poseFilter.process(measurement) else {
                // Acquisition/one rejected sample must not bypass the loss grace.
                expireHand(at: arrivalTime)
                report("Hold one hand steady. Point or open your palm.")
                return
            }
            // A slow Vision result must not revive an input already stale at display.
            guard HandTrackingLimits.accepts(frame,at:ProcessInfo.processInfo.systemUptime) else {
                callbackLock.lock(); timing.staleFramesDropped &+= 1; callbackLock.unlock()
                expireHand(at: ProcessInfo.processInfo.systemUptime)
                return
            }
            // A held control uses an OLD reliable position. Never label this
            // capture's unconfirmed raw point as a confirmed preview gesture.
            previewIntent = frame.isHolding ? .uncertain : frame.intent
            previewFist = !frame.isHolding && frame.throwObservation?.closed == true
                && frame.throwObservation?.isReliable(fallback:frame.confidence) == true
            if !frame.isHolding && (frame.intent != .uncertain || frame.throwObservation != nil) { lastGoodTime = ProcessInfo.processInfo.systemUptime }
            hadHand = frame.intent != .uncertain || frame.throwObservation != nil
            if frame.isHolding {
                report("Tracking paused · Holding position")
            } else { switch frame.intent {
            case .pointing: report("Point and move gently to lead your dog.")
            case .palm: report("Move your open palm onto your dog to pet.")
            case .uncertain: report("Point to lead, or open your palm to pet.")
            } }
            deliver(frame)
        } catch {
            handleMissingHand(capturedAt: timestamp)
            report("Hand tracking unavailable: \(error.localizedDescription)")
        }
    }

    private func publishPreview(_ buffer: CVPixelBuffer, timestamp: Double,
                                measurement: HandMeasurement?, intent: HandIntent,
                                confidence: Float, fist: Bool) {
        guard timestamp - lastPreviewTime >= 1.0 / 35.0 else { return }
        callbackLock.lock()
        let hasSubscriber = previewCallback != nil
        callbackLock.unlock()
        guard hasSubscriber else { return }
        lastPreviewTime = timestamp
        // At normal 30 Hz, image and marker update together for every processed
        // capture. The single delivery slot bounds pending UI work and memory.
        let previewStarted = ProcessInfo.processInfo.systemUptime
        // AVCapture connection is unmirrored; mirror the camera image exactly once.
        guard let image = CameraPreviewProjection.makeImage(CIImage(cvPixelBuffer: buffer), context: previewContext) else { return }
        callbackLock.lock()
        timing.latestPreviewMilliseconds = (ProcessInfo.processInfo.systemUptime - previewStarted) * 1000
        callbackLock.unlock()
        enqueuePreview(CameraPreviewFrame(fist: fist ? measurement?.throwObservation?.center:nil, image: image,
            tip: intent == .pointing ? measurement?.tip : nil,
            palm: intent == .palm ? measurement?.palm : nil,
            palmRadius: measurement?.palmRadius ?? 0,
            intent: intent, confidence: confidence, timestamp: timestamp))
    }

    private func clearPreview() {
        callbackLock.lock()
        previewGeneration &+= 1
        callbackLock.unlock()
        enqueuePreview(nil)
    }

    /// Coalesce camera images into a single pending UI delivery; a slow UI cannot
    /// accumulate full-frame images or receive a long queue of old camera frames.
    private func enqueuePreview(_ frame: CameraPreviewFrame?) {
        callbackLock.lock()
        pendingPreview = frame
        pendingPreviewGeneration = previewGeneration
        let shouldSchedule = !previewDeliveryScheduled
        previewDeliveryScheduled = true
        callbackLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            let frame = self.pendingPreview
            let valid = self.pendingPreviewGeneration == self.previewGeneration
            let callback = self.previewCallback
            self.pendingPreview = nil
            self.previewDeliveryScheduled = false
            self.callbackLock.unlock()
            guard valid else { return }
            // Even after main-thread congestion, the UI must not revive old imagery.
            if let frame, ProcessInfo.processInfo.systemUptime - frame.timestamp > 0.65 {
                callback?(nil)
            } else { callback?(frame) }
        }
    }

    private func handleMissingHand(capturedAt timestamp: Double) {
        let now=ProcessInfo.processInfo.systemUptime
        if let held = poseFilter.missing(at: timestamp) {
            deliver(held)
            report("Tracking paused · Holding position")
        } else if hadHand {
            // A prolonged fist/occlusion stops control, while the spatial track
            // stays available for a quick return of the same physical hand.
            hadHand = false
            deliver(nil)
        }
        expireHand(at: now)
    }

    private func expireHand(at now: Double) {
        if let lastGoodTime, now - lastGoodTime > HandTrackingLimits.arrivalTimeout {
            invalidateHand(resetFilter: false)
            report("No hand visible. Bring one hand into view.")
        }
    }

    private func invalidateHand(resetFilter: Bool = true) {
        hadHand = false
        lastGoodTime = nil
        if resetFilter { poseFilter.reset() }
        callbackLock.lock()
        callbackGeneration &+= 1
        callbackLock.unlock()
        deliver(nil)
    }

    private func deliver(_ frame: HandFrame?) {
        callbackLock.lock()
        let shouldSchedule = updateMailbox.enqueue(frame, generation: callbackGeneration)
        callbackLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            let pending = self.updateMailbox.consume(currentGeneration: self.callbackGeneration)
            let callback = self.updateCallback
            if let frame = pending.frame {
                self.timing.latestCaptureToUpdateMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - frame.timestamp) * 1000
            }
            self.callbackLock.unlock()
            guard pending.valid else { return }
            // Do not animate through a backlog after the UI was briefly busy.
            if let frame = pending.frame, !HandTrackingLimits.accepts(frame,at:ProcessInfo.processInfo.systemUptime) {
                callback?(nil)
            } else { callback?(pending.frame) }
        }
    }

    private func report(_ text: String) {
        guard text != lastStatus else { return }
        lastStatus = text
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            let callback = self.statusCallback
            self.callbackLock.unlock()
            callback?(text)
        }
    }

    private enum TrackingError: LocalizedError {
        case noCamera, cannotConfigure
        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera found"
            case .cannotConfigure: return "Unsupported camera configuration"
            }
        }
    }
}

// Pure posture/temporal logic is kept separate from camera acquisition so it can
// be verified with synthetic measurements without camera access or permission.
struct HandJointSample {
    let position: SIMD2<Float>
    let confidence: Float
}

struct HandMeasurement {
    let tip: SIMD2<Float>
    let palm: SIMD2<Float>
    let palmRadius: Float
    let intent: HandIntent
    let confidence: Float
    let handedness: Int
    let timestamp: Double
    var palmWidth: Float = 0
    var palmLength: Float = 0
    var palmGeometryConfidence: Float = 0
    var throwObservation: HandThrowObservation? = nil
}

enum HandPostureClassifier {
    private typealias Joint = VNHumanHandPoseObservation.JointName
    private enum Extension { case open, folded, unknown }
    private struct Evidence {
        var state: Extension = .unknown
        var confidence: Float = 0
        var strong = false
    }

    static func measure(_ points: [VNHumanHandPoseObservation.JointName: HandJointSample],
                        aspect: Float, handedness: Int, timestamp: Double) -> HandMeasurement? {
        guard aspect.isFinite, aspect > 0, timestamp.isFinite else { return nil }
        func point(_ name: Joint, minimum: Float = 0.22) -> HandJointSample? {
            guard let p = points[name], p.confidence >= minimum,
                  p.position.x.isFinite, p.position.y.isFinite else { return nil }
            return p
        }
        let scaleXY = SIMD2<Float>(aspect, 1)
        let baseNames: [Joint] = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let pipNames: [Joint] = [.indexPIP, .middlePIP, .ringPIP, .littlePIP]
        let bases = baseNames.compactMap { point($0) }
        guard !bases.isEmpty else { return nil }
        let mcpCenter = bases.reduce(SIMD2<Float>.zero) { $0 + $1.position } / Float(bases.count)
        let actualWrist = point(.wrist)
        let wrist: SIMD2<Float>
        if let actualWrist {
            wrist = actualWrist.position
        } else {
            // An open palm often loses its wrist at the image border. Estimate
            // only the palm support from at least two observed finger bases.
            guard bases.count >= 2 else { return nil }
            let axes = zip(baseNames, pipNames).compactMap { base, pip -> SIMD2<Float>? in
                guard let a = point(base), let b = point(pip) else { return nil }
                return b.position - a.position
            }
            guard !axes.isEmpty else { return nil }
            let axis = axes.reduce(SIMD2<Float>.zero, +) / Float(axes.count)
            guard simd_length(axis * scaleXY) > 0.01 else { return nil }
            wrist = mcpCenter - axis * 1.45
        }
        let length = simd_length((mcpCenter - wrist) * scaleXY)
        var width: Float = 0
        for a in bases { for b in bases { width = max(width, simd_length((a.position - b.position) * scaleXY)) } }
        let scale = max(width, length)
        guard scale >= 0.025, scale <= 0.75 else { return nil }
        let palm = wrist * 0.4 + mcpCenter * 0.6
        let radius = max(length * 0.65, bases.map { simd_length(($0.position - palm) * scaleXY) }.max() ?? 0) * 0.95

        func evidence(_ mcp: Joint, _ pip: Joint, _ dip: Joint, _ end: Joint) -> Evidence {
            guard let a = point(mcp) else { return Evidence() }
            let c = point(end, minimum: 0.30) ?? point(dip, minimum: 0.30)
            guard let c else { return Evidence() }
            let b = point(pip) ?? point(dip)
            if let b, simd_distance(b.position, c.position) > 0.005 {
                let first = (b.position - a.position) * scaleXY
                let second = (c.position - b.position) * scaleXY
                let firstLength = simd_length(first), secondLength = simd_length(second)
                guard firstLength > 0.005, secondLength > 0.003 else { return Evidence() }
                let straightness = simd_dot(first, second) / (firstLength * secondLength)
                let reach = (simd_length((c.position - wrist) * scaleXY)
                             - simd_length((b.position - wrist) * scaleXY)) / scale
                let ratio = simd_length((c.position - a.position) * scaleXY) / firstLength
                let confidence = min(c.confidence, (a.confidence + b.confidence) * 0.5)
                if (straightness > 0.22 && reach > 0.09 && ratio > 1.18)
                    || (straightness > 0.65 && ratio > 1.45) {
                    return Evidence(state: .open, confidence: confidence,
                                    strong: straightness > 0.60 && reach > 0.22)
                }
                // A sideways straight finger can have almost no radial reach.
                // Require bending/compactness together, not radial reach alone.
                if (straightness < 0.10 && ratio < 1.18) || (ratio < 1.08 && reach < 0.035) {
                    return Evidence(state: .folded, confidence: confidence, strong: true)
                }
                return Evidence()
            }
            // PIP can be occluded while the MCP and fingertip remain visible.
            let baseAxis = (a.position - wrist) * scaleXY
            let finger = (c.position - a.position) * scaleXY
            let reach = simd_length(finger) / scale
            let alignment = simd_dot(baseAxis, finger) / max(simd_length(baseAxis) * simd_length(finger), 0.00001)
            if reach > 0.62 && alignment > 0.45 {
                return Evidence(state: .open, confidence: min(a.confidence, c.confidence) * 0.9,
                                strong: reach > 0.9 && alignment > 0.70)
            }
            if reach < 0.30 { return Evidence(state: .folded, confidence: min(a.confidence, c.confidence), strong: true) }
            return Evidence()
        }
        let index = evidence(.indexMCP, .indexPIP, .indexDIP, .indexTip)
        let others = [evidence(.middleMCP, .middlePIP, .middleDIP, .middleTip),
                      evidence(.ringMCP, .ringPIP, .ringDIP, .ringTip),
                      evidence(.littleMCP, .littlePIP, .littleDIP, .littleTip)]
        let all = [index] + others
        // A palm is an action with stronger evidence than an uncertain extension:
        // three actual fingertips (not DIP fallbacks), clear extension, and
        // reliable palm support. The fourth finger and wrist may be occluded.
        let tips: [Joint] = [.indexTip, .middleTip, .ringTip, .littleTip]
        let palmExtensions = zip(all, tips).filter { evidence, name in
            evidence.state == .open && evidence.strong && evidence.confidence >= 0.58
                && point(name, minimum: 0.58) != nil
        }.map { $0.0 }
        let reliableBases = bases.filter { $0.confidence >= 0.45 }.count
        let reliablePalmSupport = reliableBases >= 3
            || (reliableBases >= 2 && (actualWrist?.confidence ?? 0) >= 0.55)
        let folded = others.filter { $0.state == .folded }.count
        let otherOpens = others.filter { $0.state == .open && $0.strong && $0.confidence >= 0.58 }.count
        let tip = point(.indexTip, minimum: 0.40)
        // Keep pinches neutral. Throwing uses a whole fist, not thumb contact.
        // Ordinary pointing/petting still work without a visible thumb.
        let pinch: Bool
        if let tip, let thumb = point(.thumbTip, minimum: 0.45) {
            pinch = simd_length((tip.position - thumb.position) * scaleXY) < scale * 0.25
        } else { pinch = false }
        let intent: HandIntent
        if palmExtensions.count >= 3 && reliablePalmSupport {
            // Three strongly supported extensions suffice for a tilted palm.
            intent = .palm
        } else if index.state == .open, tip != nil, otherOpens <= 1, (!pinch || index.strong),
                  folded >= 1 || (index.strong && actualWrist != nil) {
            // Folded fingers are routinely hidden behind the pointing finger.
            // Never require all three of them to be recognized simultaneously.
            intent = .pointing
        } else {
            intent = .uncertain
        }
        let supportConfidence = bases.map(\.confidence).reduce(0, +) / Float(bases.count)
        let actionConfidence: Float
        if intent == .palm { actionConfidence = palmExtensions.map(\.confidence).reduce(0, +) / Float(palmExtensions.count) }
        else { actionConfidence = tip?.confidence ?? supportConfidence }
        let confidence = min(0.99, actionConfidence * 0.65 + supportConfidence * 0.35)
        // Proximity has stricter geometry requirements than ordinary controls.
        // Do not reuse an estimated wrist or a changing subset of knuckles: either
        // would turn occlusion into an apparent change of distance.
        var palmWidth: Float = 0, palmLength: Float = 0, geometryConfidence: Float = 0
        let proximityBases = baseNames.compactMap { point($0, minimum: 0.55) }
        if let measuredWrist = point(.wrist, minimum: 0.55), proximityBases.count == 4 {
            let center = proximityBases.reduce(SIMD2<Float>.zero) { $0 + $1.position } / 4
            palmWidth = simd_length((proximityBases[3].position - proximityBases[0].position) * scaleXY)
            palmLength = simd_length((center - measuredWrist.position) * scaleXY)
            geometryConfidence = min(measuredWrist.confidence, proximityBases.map(\.confidence).min() ?? 0)
        }
        // Extension vetoes use a lower threshold than palm activation: a weak
        // but visible pointing finger must never be outvoted by three curled ones.
        let curled = all.filter { $0.state == .folded && $0.strong && $0.confidence >= 0.50 }.count
        let extendedFinger = intent == .pointing || all.contains { $0.state == .open && $0.confidence >= 0.30 }
        // Starting requires visible index curl. Losing that finger is tolerated
        // only after a fist has already been acquired, never as proof of closure.
        let indexCurled = index.state == .folded && index.strong && index.confidence >= 0.35
        let fist = curled >= 3 && indexCurled && !extendedFinger && reliablePalmSupport
        let openHand = palmExtensions.count >= 3 && reliablePalmSupport
        let supported = all.filter { $0.confidence >= 0.50 }.count >= 2 && reliablePalmSupport
        let partialFist = curled >= 2 && !extendedFinger && reliablePalmSupport
        let throwEvidence = (fist || partialFist) ? all.filter { $0.state == .folded && $0.strong && $0.confidence >= 0.50 }
            : (openHand ? palmExtensions : all.filter { $0.confidence >= 0.50 })
        let throwConfidence=min(supportConfidence,throwEvidence.map(\.confidence).reduce(0,+)/Float(max(1,throwEvidence.count)))
        let throwObservation: HandThrowObservation? = supported
            ? HandThrowObservation(center: palm, palm: palm, closed: fist, open: openHand, confidence:throwConfidence, continuingClosed:partialFist, extendedFinger:extendedFinger) : nil
        return HandMeasurement(tip: tip?.position ?? palm, palm: palm, palmRadius: radius,
                               intent: intent, confidence: confidence,
                               handedness: handedness, timestamp: timestamp,
                               palmWidth: palmWidth, palmLength: palmLength,
                               palmGeometryConfidence: geometryConfidence, throwObservation: throwObservation)
    }
}

struct HandPoseFilter {
    private var anchor: HandMeasurement?
    private var lastMeasurementTime: Double?
    private var pending: HandMeasurement?
    private var pendingSince: Double = 0
    private var pendingCount = 0
    private var tipCoordinates = AdaptiveHandCoordinateFilter()
    private var palmCoordinates = AdaptiveHandCoordinateFilter()
    private var throwCoordinates = AdaptiveHandCoordinateFilter()
    private var smoothedRadius: Float = 0
    private var stableIntent: HandIntent = .uncertain
    private var candidateIntent: HandIntent = .uncertain
    private var candidateSince: Double = 0
    private var candidateCount = 0
    private var lastReliableFrame: HandFrame?
    private let holdDuration: Double = HandTrackingLimits.occlusionHold

    mutating func reset() { self = HandPoseFilter() }

    /// A missing/low-quality capture interrupts confirmation, but never updates
    /// the coordinate filters or extends the age of the last reliable action.
    mutating func missing(at timestamp: Double) -> HandFrame? {
        candidateIntent = .uncertain
        candidateCount = 0
        return heldFrame(at: timestamp)
    }

    mutating func process(_ input: HandMeasurement) -> HandFrame? {
        guard input.timestamp.isFinite else { return nil }
        if let lastMeasurementTime {
            guard input.timestamp > lastMeasurementTime else { return nil }
            if input.timestamp - lastMeasurementTime > HandTrackingLimits.arrivalTimeout { reset() }
        }
        lastMeasurementTime = input.timestamp
        guard input.confidence >= 0.30,
              input.tip.x.isFinite, input.tip.y.isFinite,
              input.palm.x.isFinite, input.palm.y.isFinite,
              input.palmRadius.isFinite, input.palmRadius > 0 else {
            _ = missing(at: input.timestamp)
            return heldOrInactive(at: input.timestamp)
        }
        let intent = advanceIntent(input.intent, at: input.timestamp)
        if input.intent == .uncertain && stableIntent == .pointing,
           input.throwObservation?.closed != true,input.throwObservation?.continuingClosed != true,
           input.throwObservation?.open != true {
            return heldOrInactive(at:input.timestamp)
        }
        guard input.intent != .uncertain || input.throwObservation != nil else {
            return heldOrInactive(at: input.timestamp)
        }
        let dt = Float(min(0.1, max(1.0 / 120.0, input.timestamp - (anchor?.timestamp ?? input.timestamp - 1.0 / 30.0))))
        var needsAcquisition = anchor == nil
        if let anchor {
            // Vision's chirality label can flip during a turn. Identity is gated
            // by spatial continuity, never by that label alone. While pointing,
            // a reliable fingertip also survives jumping/occluded palm bases.
            let limit = min(0.34, max(0.17, 0.075 + dt * 2.2 + anchor.palmRadius * 0.55))
            needsAcquisition = continuityDistance(input, anchor) > limit
        }
        if needsAcquisition {
            guard acceptsReacquisition(input) else { return heldOrInactive(at: input.timestamp) }
            tipCoordinates.reset()
            palmCoordinates.reset()
            throwCoordinates.reset()
            smoothedRadius = 0
            lastReliableFrame = nil
            // Keep gesture evidence gathered during identity acquisition, so a
            // returning hand does not incur two consecutive confirmation waits.
            anchor = input
        } else {
            pending = nil
            pendingCount = 0
        }
        guard intent != .uncertain || input.throwObservation != nil else { return heldOrInactive(at: input.timestamp) }
        // Only a confirmed action may update the spatial anchor or coordinates.
        // In particular, an absent indexTip's palm fallback never enters the tip
        // filter during an ambiguous/fist frame.
        anchor = input
        let smoothedTip: SIMD2<Float>
        if intent == .pointing {
            smoothedTip = tipCoordinates.process(Self.mapToActiveArea(input.tip), timestamp: input.timestamp)
        } else {
            // Palm-only samples need no fingertip; avoid contaminating its filter.
            smoothedTip = lastReliableFrame?.tip ?? Self.mapToActiveArea(input.tip)
        }
        let smoothedPalm = palmCoordinates.process(Self.mapToActiveArea(input.palm), timestamp: input.timestamp)
        let radius = min(0.22, max(0.025, input.palmRadius / 0.72))
        smoothedRadius = smoothedRadius == 0 ? radius : smoothedRadius + (radius - smoothedRadius) * (1 - exp(-dt / 0.10))
        var throwObservation = input.throwObservation
        if let observation = throwObservation {
            throwObservation?.center = throwCoordinates.process(Self.mapToActiveArea(observation.center), timestamp: input.timestamp)
            throwObservation?.palm = smoothedPalm
        }
        let frame = HandFrame(tip: smoothedTip, palm: smoothedPalm, palmRadius: smoothedRadius,
                              intent: intent, confidence: input.confidence, timestamp: input.timestamp,
                              palmWidth: input.palmWidth, palmLength: input.palmLength,
                              palmGeometryConfidence: input.palmGeometryConfidence, throwObservation: throwObservation)
        lastReliableFrame = frame
        return frame
    }

    private func heldFrame(at timestamp: Double) -> HandFrame? {
        guard var frame = lastReliableFrame, timestamp >= frame.timestamp,
              timestamp - frame.timestamp <= holdDuration else { return nil }
        frame.isHolding = true
        return frame
    }

    private func heldOrInactive(at timestamp: Double) -> HandFrame? {
        if let held = heldFrame(at: timestamp) { return held }
        guard let frame = lastReliableFrame else { return nil }
        return HandFrame(tip: frame.tip, palm: frame.palm, palmRadius: frame.palmRadius,
                         intent: .uncertain, confidence: 0, timestamp: timestamp)
    }

    private func continuityDistance(_ a: HandMeasurement, _ b: HandMeasurement) -> Float {
        if a.intent == .pointing && b.intent == .pointing {
            return min(simd_distance(a.tip, b.tip),simd_distance(a.palm,b.palm))
        }
        return simd_distance(a.palm, b.palm)
    }

    private mutating func acceptsReacquisition(_ input: HandMeasurement) -> Bool {
        if let pending,
           continuityDistance(input, pending) < 0.20,
           input.timestamp - pending.timestamp < 0.15 {
            pendingCount += 1
        } else {
            pendingSince = input.timestamp
            pendingCount = 1
        }
        pending = input
        let dwell = anchor == nil ? 0.030 : 0.08
        guard pendingCount >= 2, input.timestamp - pendingSince >= dwell else { return false }
        self.pending = nil
        pendingCount = 0
        return true
    }

    private mutating func advanceIntent(_ raw: HandIntent, at timestamp: Double) -> HandIntent {
        if let frame = lastReliableFrame, timestamp - frame.timestamp > 0.26 {
            stableIntent = .uncertain
        }
        guard raw != .uncertain else {
            candidateIntent = .uncertain
            candidateCount = 0
            return .uncertain
        }
        if raw == stableIntent {
            candidateIntent = raw
            candidateSince = timestamp
            candidateCount = 0
            return stableIntent
        }
        if raw != candidateIntent {
            candidateIntent = raw
            candidateSince = timestamp
            candidateCount = 1
        } else { candidateCount += 1 }
        // Accidental palm classifications cannot briefly pet the dog. Deliberate
        // palms need sustained evidence; a clear pointing pose returns quickly.
        let dwell: Double = raw == .palm ? 0.22 : 0.030
        if timestamp - candidateSince >= dwell && candidateCount >= 2 {
            stableIntent = raw
            return raw
        }
        return .uncertain
    }

    static func mapToActiveArea(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let mapped = (point - SIMD2<Float>(0.12,0.14)) / SIMD2<Float>(0.76,0.72)
        return SIMD2(min(1, max(0, mapped.x)), min(1, max(0, mapped.y)))
    }
}


/// One Euro style filter, expressed in normalized screen units. The derivative
/// comes from consecutive RAW captures, never raw-minus-filtered displacement.
/// Each axis has a smoothly varying cutoff; fast horizontal motion therefore
/// does not needlessly amplify stationary vertical noise. No position prediction.
/// Algorithm reference: https://gery.casiez.net/1euro/
struct AdaptiveHandCoordinateFilter {
    private var lastRaw: SIMD2<Float>?
    private var value: SIMD2<Float>?
    private var derivative = SIMD2<Float>.zero
    private var lastTimestamp: Double?
    private let minimumCutoff: Float = 0.8
    private let speedCoefficient: Float = 60
    private let derivativeCutoff: Float = 0.7

    mutating func reset() { self = AdaptiveHandCoordinateFilter() }

    mutating func process(_ raw: SIMD2<Float>, timestamp: Double) -> SIMD2<Float> {
        guard raw.x.isFinite, raw.y.isFinite, timestamp.isFinite else { return value ?? .zero }
        guard let previousRaw = lastRaw, let previousValue = value, let previousTime = lastTimestamp else {
            lastRaw = raw; value = raw; lastTimestamp = timestamp
            return raw
        }
        let elapsed = timestamp - previousTime
        guard elapsed > 0 else { return previousValue }
        // Hand loss/reacquisition should not drag a new hand from an old location.
        if elapsed > 0.35 {
            reset()
            lastRaw = raw; value = raw; lastTimestamp = timestamp
            return raw
        }
        let dt = Float(max(elapsed, 1.0 / 240.0))
        let rawDerivative = (raw - previousRaw) / dt
        derivative += (rawDerivative - derivative) * alpha(cutoff: derivativeCutoff, dt: dt)
        let xAlpha = alpha(cutoff: minimumCutoff + speedCoefficient * abs(derivative.x), dt: dt)
        let yAlpha = alpha(cutoff: minimumCutoff + speedCoefficient * abs(derivative.y), dt: dt)
        let filtered = previousValue + (raw - previousValue) * SIMD2(xAlpha, yAlpha)
        lastRaw = raw; value = filtered; lastTimestamp = timestamp
        return filtered
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return dt / (dt + tau)
    }
}
