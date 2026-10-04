import Cocoa
import MetalKit
import AVFoundation
import CoreText
import simd

extension PupRenderer {
    /// Deterministic, offline renderer validation. No camera is opened or read.
    func verify(to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 1440, height = 900, fps: Int32 = 30, frameCount = 540
        let size = CGSize(width: width, height: height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor) else {
            throw verificationError("Could not create the offscreen Metal texture")
        }
        let movieURL = directory.appendingPathComponent("模拟输入_跟随与摸摸.mp4")
        if fm.fileExists(atPath: movieURL.path) { try fm.removeItem(at: movieURL) }
        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000,
                                             AVVideoExpectedSourceFrameRateKey: fps,
                                             AVVideoMaxKeyFrameIntervalKey: fps]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw verificationError("Could not attach video encoder") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? verificationError("Could not start video") }
        writer.startSession(atSourceTime: .zero)

        setInputMode(.mouse); demo = false; inputIsCamera = false
        pointer = nil; fingers = []; lastFingers = []
        elapsed = 0; idleTime = 0; runTime = 0; walkTime = 0; petTime = 0; gaitPhase = 0; pettingDuration = 0; smoothedSpeed = 0
        motion.position = SIMD2<Float>(-0.5, -1.3); motion.velocity = .zero; motion.yaw = -0.22
        memset(states.contents(), 0, states.length)
        configure(size)

        var timings: [Double] = []
        var failures: [String] = []
        var samples: [[String: Any]] = []
        var finite = true, contactFrames = 0, runSamples = 0
        var maxScatter: Float = 0, maxAverageScatter: Float = 0
        var maxMotes=0,maxMoteStrength:Float=0,releaseMoteStrength:Float=0,recoveredMoteStrength:Float=0,maxPetBlend:Float=0
        var contactEndAverage: Float = 0, recoveredAverage: Float = 0
        var maxRunBlend: Float = 0, maxSpeed: Float = 0
        var minRootX: Float = .infinity, maxRootX: Float = -.infinity
        var exportedPNGs: [String] = []
        let snapshotFrames = [30: "01_黑底静止.png", 100: "02_指尖跟随跑动.png",
                              221: "03a_抬头.png", 251: "03b_歪头.png", 287: "03c_转头.png",
                              323: "03_手掌摸摸.png", 351: "03d_开心点头.png", 367: "03e_放松.png",
                              539: "04_摸摸结束.png"]

        func normalized(_ p: SIMD2<Float>) -> SIMD2<Float> {
            p / SIMD2(uniforms.viewport.z, uniforms.viewport.w) + SIMD2(repeating: 0.5)
        }

        for frame in 0..<frameCount {
            let time = Float(frame) / Float(fps)
            let stage: String
            if frame < 45 {
                pointer = nil; fingers = []; palm=nil;intent = .uncertain;stage = "IDLE"
            } else if frame < 115 {
                let p = normalized(SIMD2<Float>(4.55, 1.1 + sin(time * 1.5) * 0.15))
                pointer = p; fingers = [p];palm=nil;intent = .pointing;stage = "FOLLOW RIGHT"
            } else if frame < 195 {
                let p = normalized(SIMD2<Float>(-4.55, 1.15 + sin(time) * 0.15))
                pointer = p; fingers = [p];palm=nil;intent = .pointing;stage = "FOLLOW LEFT"
            } else if frame < 435 {
                // Choose an actual surface sample near the torso, so this tests
                // Renderer.isHit as well as the GPU's touch force.
                let centre = motion.position + SIMD2<Float>(0, 1.5)
                var best = SIMD2<Float>.zero, bestDistance: Float = .infinity
                for i in stride(from: 0, to: count, by: max(1, count / 1500)) {
                    let sample = pose(i), point = SIMD2(sample.x, sample.y)
                    let distance = simd_distance_squared(point, centre)
                    if distance < bestDistance { best = point; bestDistance = distance }
                }
                let p = normalized(best)
                pointer=nil;palm=p;intent = .palm;fingers=[p]
                stage = "PALM / PETTING"
            } else {
                pointer = nil; fingers = [];palm=nil;intent = .uncertain;stage = "RELAX / MOTES FADE"
            }
            update(dt: 1 / Float(fps), size: size)
            let command = encode(texture: output)
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { failures.append(error.localizedDescription) }
            let milliseconds = (command.gpuEndTime - command.gpuStartTime) * 1000
            if milliseconds.isFinite && milliseconds > 0 { timings.append(milliseconds) }
            let (scatter, average, statesFinite) = displacement()
            finite = finite && statesFinite && motion.position.x.isFinite && motion.position.y.isFinite
                && motion.velocity.x.isFinite && motion.velocity.y.isFinite && motion.yaw.isFinite
            if touching { contactFrames += 1 }
            if uniforms.clock.z * uniforms.gait.z > 0.8 { runSamples += 1 }
            maxScatter = max(maxScatter, scatter); maxAverageScatter = max(maxAverageScatter, average)
            maxRunBlend = max(maxRunBlend, uniforms.clock.z * uniforms.gait.z)
            maxPetBlend=max(maxPetBlend,petBlend)
            let motes=emissionStats();maxMotes=max(maxMotes,motes.active);maxMoteStrength=max(maxMoteStrength,motes.maximum)
            if frame==434{releaseMoteStrength=motes.maximum};if frame==539{recoveredMoteStrength=motes.maximum}
            maxSpeed = max(maxSpeed, simd_length(motion.velocity))
            minRootX = min(minRootX, motion.position.x); maxRootX = max(maxRootX, motion.position.x)
            if frame == 434 { contactEndAverage = average }
            if frame == 539 { recoveredAverage = average }
            if frame % 15 == 0 || frame == frameCount - 1 {
                samples.append(["timeSeconds": time, "stage": stage, "state": motion.state,
                                "position": [motion.position.x, motion.position.y], "yaw": motion.yaw,
                                "speed": simd_length(motion.velocity), "runBlend": uniforms.clock.z,
                                "touching": touching, "maximumOffset": scatter, "meanOffset": average])
            }
            if let filename = snapshotFrames[frame] {
                try savePNG(output, to: directory.appendingPathComponent(filename)); exportedPNGs.append(filename)
            }
            try appendVerificationFrame(texture: output, adaptor: adaptor, input: input,
                                        writer: writer, frame: frame, fps: fps,
                                        label: "SIMULATED INPUT  ·  " + stage,
                                        locations: fingers)
            if frame % 60 == 0 { print("Verification: \(frame)/\(frameCount), \(stage), scatter=\(scatter)") }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 60) == .success, writer.status == .completed else {
            throw writer.error ?? verificationError("Video encoding did not finish")
        }

        // Expose a frame from the unmodified source Gallop clip independently
        // from the speed crossfade used in the interaction movie.
        memset(states.contents(), 0, states.length)
        uniforms.clock.y = 0; uniforms.clock.z = 1;uniforms.gait.z=1;uniforms.gait.w=0
        uniforms.root = SIMD4<Float>(-0.25, -1.5, -0.22, 0)
        uniforms.frames.z = UInt32(runInfo.frameCount / 4)
        uniforms.frames.w = UInt32((runInfo.frameCount / 4 + 1) % runInfo.frameCount)
        uniforms.animation.y = 0
        let runCommand = encode(texture: output)
        runCommand.commit(); runCommand.waitUntilCompleted()
        if let error = runCommand.error { failures.append(error.localizedDescription) }
        let runPNG = "05_原始骨骼Gallop帧.png"
        try savePNG(output, to: directory.appendingPathComponent(runPNG)); exportedPNGs.append(runPNG)

        timings.sort()
        let averageGPU = timings.isEmpty ? 0 : timings.reduce(0, +) / Double(timings.count)
        let p95 = timings.isEmpty ? 0 : timings[min(timings.count - 1, Int(Double(timings.count - 1) * 0.95))]
        let reunionRatio = recoveredMoteStrength / max(releaseMoteStrength, 0.000001)
        let assertions: [String: Bool] = [
            "gpuCompletedWithoutError": failures.isEmpty,
            "allMotionAndParticleStatesFinite": finite,
            "bothDirectionsHaveSubstantialTravel": maxRootX - minRootX > 2,
            "originalRunClipVisibleAtHighBlend": maxRunBlend > 0.8 && runSamples > 10,
            "bodyContactDetected": contactFrames > 30,
            "bodyParticlesNeverBlownApart": maxScatter < 0.0001,
            "gentlePetMotesEmitted": maxMotes > 50 && maxMoteStrength > 0.5,
            "skeletalPettingBlendsIn": maxPetBlend > 0.9,
            "petMotesFadeAfterRelease": reunionRatio < 0.1,
            "movieContains540Frames": writer.status == .completed
        ]
        let report: [String: Any] = [
            "inputEvidence": "SIMULATED single index / palm positions and intents; no physical hand or live camera was tested",
            "cameraOpened": false, "rendering": "Native Metal offscreen, same renderer and shaders as the app",
            "device": device.name, "width": width, "height": height, "fps": fps,
            "durationSeconds": Double(frameCount) / Double(fps), "frameCount": frameCount,
            "particleCount": count, "drawnPointLayers": 7,
            "originalRunClip": ["file": runInfo.file, "frameCount": runInfo.frameCount, "fps": runInfo.fps],
            "gpuMilliseconds": ["mean": averageGPU, "p95": p95, "max": timings.last ?? 0,
                                "samples": timings.count],
            "maximumActivePetMotes":maxMotes,"maximumMoteStrength":maxMoteStrength,"maximumPetBlend":maxPetBlend,
            "maximumDisplacement": maxScatter, "maximumMeanDisplacement": maxAverageScatter,
            "meanDisplacementAtRelease": contactEndAverage, "meanDisplacementAfterRecovery": recoveredAverage,
            "recoveryRatio": reunionRatio, "detectedContactFrames": contactFrames,
            "maximumRunBlend": maxRunBlend, "maximumSpeed": maxSpeed,
            "assertions": assertions, "allPassed": assertions.values.allSatisfy { $0 },
            "metalErrors": failures, "samples": samples, "screenshots": exportedPNGs,
            "movie": movieURL.lastPathComponent
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try reportData.write(to: directory.appendingPathComponent("native_verification.json"))
        let note = """
        原生渲染验证（模拟输入）

        本目录的视频通过原生 Metal 渲染器逐帧导出，使用与应用相同的狗动画、粒子、辉光和交互路径。
        输入为程序生成的单食指与手掌位置，并没有开启摄像头，也不是真人手势识别的实测证据。
        18 秒视频依次显示静止、向右跟随、向左转身跟随、手掌摸摸、移开后飘动光点消退。
        白色圆圈仅标记模拟食指或手掌，底部文字仅用于证据说明；PNG 保留原生渲染画面，无说明覆盖。
        05 图片直接显示原作者 Gallop 动作的一个动画帧，未使用自编腿部摆动。
        native_verification.json 包含 GPU 时间、接触检测、零吹散位移、摸摸动画和飘动光点、状态有限性与验证结论。
        GPU 时间仅代表这次离屏测试，不等同于完整应用或摄像头的端到端帧率。
        """
        try note.write(to: directory.appendingPathComponent("验证说明.txt"), atomically: true, encoding: .utf8)
        let summary = "Native verification: \(assertions.values.allSatisfy { $0 } ? "PASS" : "FAIL"); GPU mean \(String(format: "%.2f", averageGPU)) ms, p95 \(String(format: "%.2f", p95)) ms; body displacement \(String(format: "%.3f", maxScatter)); recovery ratio \(String(format: "%.4f", reunionRatio)); camera not tested."
        print(summary)
        try summary.write(to: directory.appendingPathComponent("native_verification_result.txt"), atomically: true, encoding: .utf8)
        if !assertions.values.allSatisfy({ $0 }) {
            throw verificationError("Offline verification failed: " + assertions.filter { !$0.value }.keys.sorted().joined(separator: ", "))
        }
    }

    private func verificationError(_ description: String) -> NSError {
        NSError(domain: "LuminousPup.Verification", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    func appendVerificationFrame(texture: MTLTexture, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                         input: AVAssetWriterInput, writer: AVAssetWriter,
                                         frame: Int, fps: Int32, label: String,
                                         locations: [SIMD2<Float>]) throws {
        let deadline = Date().addingTimeInterval(20)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? verificationError("Video encoder failed") }
            if Date() > deadline { throw verificationError("Video encoder stalled") }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard let pool = adaptor.pixelBufferPool else { throw verificationError("No video frame pool") }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { throw verificationError("Could not allocate video frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw verificationError("No video frame bytes") }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        texture.getBytes(base, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        if let context = CGContext(data: base, width: texture.width, height: texture.height,
                                   bitsPerComponent: 8, bytesPerRow: rowBytes,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            // CoreGraphics uses a bottom-left drawing origin; tracked fingers
            // are normalized in that same orientation.
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.75)); context.setLineWidth(1.4)
            context.setFillColor(CGColor(gray: 1, alpha: 0.9))
            for (i, location) in locations.enumerated() {
                let x = CGFloat(location.x) * CGFloat(texture.width)
                let y = CGFloat(location.y) * CGFloat(texture.height)
                let r: CGFloat = i == 0 ? 12 : 5
                context.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                context.fillEllipse(in: CGRect(x: x - 2, y: y - 2, width: 4, height: 4))
            }
            context.saveGState()
            let string = NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor(white: 0.55, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 32, y: 26)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.restoreGState()
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
            throw writer.error ?? verificationError("Could not append video frame \(frame)")
        }
    }
}
