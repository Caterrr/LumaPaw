import AppKit
import AVFoundation
import Speech

/// Streaming local-only Mandarin recognition. Construction is inert; only an
/// explicit start() may request permission or open the microphone.
final class VoiceTracker: NSObject {
    private let work = DispatchQueue(label: "LuminousPup.VoiceTracking", qos: .userInitiated)
    private let lock = NSLock()
    private var commandCallback: ((VoiceCommand) -> Void)?
    private var statusCallback: ((String) -> Void)?
    private var transcriptCallback: ((String) -> Void)?
    private var listeningCallback: ((Bool) -> Void)?
    private var _isListening = false
    private var _status = "Voice is off"
    private var callbackGeneration: UInt64 = 0

    var onCommand: ((VoiceCommand) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return commandCallback }
        set { lock.lock(); commandCallback = newValue; lock.unlock() }
    }
    var onStatus: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return statusCallback }
        set { lock.lock(); statusCallback = newValue; lock.unlock() }
    }
    var onTranscript: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return transcriptCallback }
        set { lock.lock(); transcriptCallback = newValue; lock.unlock() }
    }
    var onListeningChanged: ((Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return listeningCallback }
        set { lock.lock(); listeningCallback = newValue; lock.unlock() }
    }
    var isListening: Bool { lock.lock(); defer { lock.unlock() }; return _isListening }
    var status: String { lock.lock(); defer { lock.unlock() }; return _status }

    // Confined to work queue. No microphone is touched while these are nil.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var parser: VoiceCommandParser
    private var wanted = false
    private var suspended = false
    private var permissionPending = false
    private var recognitionGeneration: UInt64 = 0
    private var sessionStart: Double = 0
    private var rotation: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    private var retryCount = 0
    private var tapInstalled = false

    init(petName: String = "Luma") { parser = VoiceCommandParser(petName: petName); super.init() }

    deinit {
        rotation?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
    }

    func start() {
        // Permission prompts must originate on the main thread, and this main
        // hop preserves start/stop order even when a button is clicked quickly.
        DispatchQueue.main.async { [weak self] in
            self?.work.async { [weak self] in
                guard let self else { return }
                self.wanted = true
                self.retryCount = 0
                self.authorizeAndStart()
            }
        }
    }

    func stop() {
        // Suppress already-queued UI commands as soon as the user turns it off.
        invalidateCallbacks()
        DispatchQueue.main.async { [weak self] in
            self?.work.async { [weak self] in
                guard let self else { return }
                self.wanted = false
                self.invalidateCallbacks()
                self.shutdown()
                self.parser.reset()
                self.emitTranscript("")
                self.report("Voice is off")
            }
        }
    }

    func setSuspended(_ value: Bool) {
        work.async { [weak self] in
            guard let self, self.suspended != value else { return }
            self.suspended = value
            if value {
                self.invalidateCallbacks()
                self.shutdown()
                if self.wanted { self.report("Voice paused. Return to this window to resume.") }
            } else if self.wanted { self.authorizeAndStart() }
        }
    }

    func setName(_ name: String) {
        work.async { [weak self] in
            guard let self else { return }
            self.invalidateCallbacks()
            self.parser.setName(name)
            self.emitTranscript("")
            if self.engine != nil { self.restart(after: 0.10, status: nil) }
        }
    }

    /// Called immediately before a dog sound starts. Capture continues, but its
    /// short acoustic interval plus 150 ms tail cannot generate commands.
    func suppressCommands(for duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        let start = ProcessInfo.processInfo.systemUptime
        work.async { [weak self] in
            self?.parser.suppressCommands(from: start, until: start + min(duration, 8) + 0.15)
        }
    }

    private func authorizeAndStart() {
        guard wanted, !suspended, engine == nil, !permissionPending else { return }
        if recognizer == nil { recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            wanted = false
            report("On-device English recognition is unavailable.")
            return
        }
        guard recognizer.isAvailable else {
            recover("On-device speech is unavailable.")
            return
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
                wanted = false; report("Open the complete app to use speech recognition."); return
            }
            permissionPending = true
            report("Allow speech recognition. Audio stays on this Mac.")
            DispatchQueue.main.async { [weak self] in
                SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                    self?.work.async { [weak self] in
                        guard let self else { return }
                        self.permissionPending = false
                        self.authorizeAndStart()
                    }
                }
            }
            return
        case .denied:
            wanted = false; report("Allow Speech Recognition in System Settings > Privacy & Security."); return
        case .restricted:
            wanted = false; report("Speech recognition is restricted by macOS."); return
        @unknown default:
            wanted = false; report("Speech permission is unavailable."); return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginRecognition(recognizer)
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                wanted = false; report("Open the complete app to use the microphone."); return
            }
            permissionPending = true
            report("Allow the microphone to talk to your dog.")
            DispatchQueue.main.async { [weak self] in
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    self?.work.async { [weak self] in
                        guard let self else { return }
                        self.permissionPending = false
                        self.authorizeAndStart()
                    }
                }
            }
        case .denied:
            wanted = false; report("Allow Microphone in System Settings > Privacy & Security.")
        case .restricted:
            wanted = false; report("The microphone is restricted by macOS.")
        @unknown default:
            wanted = false; report("Microphone permission is unavailable.")
        }
    }

    private func beginRecognition(_ recognizer: SFSpeechRecognizer) {
        guard wanted, !suspended, recognizer.supportsOnDeviceRecognition else { return }
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            wanted = false; report("No microphone found. Check Sound Input in System Settings."); return
        }
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        // Both checks are mandatory: Apple only honors this flag for a supported
        // on-device recognizer. Never retry with false or a cloud recognizer.
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .unspecified
        recognitionRequest.contextualStrings = [parser.petName, "come here", "sit", "spin", "high five", "good boy", "good girl"].filter { !$0.isEmpty }
        recognitionRequest.addsPunctuation = true
        engine = audio
        request = recognitionRequest
        sessionStart = ProcessInfo.processInfo.systemUptime
        let origin = sessionStart
        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.work.async { [weak self] in
                guard let self, self.wanted, !self.suspended, generation == self.recognitionGeneration else { return }
                if let result {
                    self.retryCount = 0
                    let transcription = result.bestTranscription
                    let hasAudioTiming = transcription.segments.contains { $0.duration > 0 || $0.timestamp > 0 }
                    let segments = hasAudioTiming ? transcription.segments.map {
                        VoiceTranscriptSegment(text: $0.substring, timestamp: origin + $0.timestamp, duration: $0.duration)
                    } : []
                    let commands = self.parser.process(transcription.formattedString, sessionID: generation,
                        at: ProcessInfo.processInfo.systemUptime, segments: segments)
                    self.emitTranscript(String(transcription.formattedString.suffix(120)))
                    for command in commands { self.emit(command) }
                    if result.isFinal { self.restart(after: 0.12, status: nil); return }
                }
                if let error { self.recover("Speech interrupted: \(error.localizedDescription)") }
            }
        }
        // Capture is appended directly to this request; no audio queue, recording,
        // file or upload is created. Old tap closures own only their old request.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        tapInstalled = true
        do {
            audio.prepare()
            try audio.start()
            setListening(true)
            report("Listening · Say “Come here”, “Sit”, “Spin” or “High five”.")
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: audio, queue: nil) { [weak self] _ in
                self?.work.async { [weak self] in
                    guard let self, generation == self.recognitionGeneration, self.wanted, !self.suspended else { return }
                    self.restart(after: 0.35, status: "Microphone changed. Reconnecting…")
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: work)
            timer.schedule(deadline: .now() + 45)
            timer.setEventHandler { [weak self] in
                guard let self, generation == self.recognitionGeneration else { return }
                self.restart(after: 0.12, status: nil)
            }
            rotation = timer; timer.resume()
        } catch {
            shutdown()
            wanted = false
            report("Microphone could not start: \(error.localizedDescription)")
        }
    }

    private func recover(_ message: String) {
        retryCount += 1
        guard retryCount <= 4 else {
            shutdown(); wanted = false
            report("Speech unavailable. Turn Voice off and try again.")
            return
        }
        restart(after: min(4, Double(retryCount)), status: message)
    }

    private func restart(after delay: TimeInterval, status: String?) {
        shutdown()
        if let status { report(status) }
        let generation = recognitionGeneration
        work.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wanted, !self.suspended, generation == self.recognitionGeneration else { return }
            self.authorizeAndStart()
        }
    }

    private func shutdown() {
        recognitionGeneration &+= 1
        rotation?.cancel(); rotation = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil; engine = nil
        setListening(false)
    }

    private func invalidateCallbacks() { lock.lock(); callbackGeneration &+= 1; lock.unlock() }
    private func dispatchCallback(_ body: @escaping (VoiceTracker) -> Void) {
        lock.lock(); let generation = callbackGeneration; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let valid = generation == self.callbackGeneration; self.lock.unlock()
            if valid { body(self) }
        }
    }
    private func emit(_ command: VoiceCommand) { dispatchCallback { $0.onCommand?(command) } }
    private func emitTranscript(_ text: String) { dispatchCallback { $0.onTranscript?(text) } }
    private func report(_ text: String) {
        lock.lock(); let changed = _status != text; _status = text; lock.unlock()
        if changed { dispatchCallback { $0.onStatus?(text) } }
    }
    private func setListening(_ value: Bool) {
        lock.lock(); let changed = _isListening != value; _isListening = value; lock.unlock()
        if changed { dispatchCallback { $0.onListeningChanged?(value) } }
    }
}
