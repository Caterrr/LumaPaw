import Cocoa
import MetalKit
import AVFoundation
import simd

extension PupRenderer {
    /// Native frames driven by synthetic input. Never opens camera or microphone.
    func verifyV6(to directory:URL)throws {
        let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let size=CGSize(width:1440,height:900),fps:Int32=30,frameCount=1080
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:1440,height:900,mipmapped:false)
        descriptor.usage=[.renderTarget,.shaderRead];descriptor.storageMode = .shared
        let texture=device.makeTexture(descriptor:descriptor)!
        let movie=directory.appendingPathComponent("模拟输入_向前跑与粒子新版.mp4")
        if fm.fileExists(atPath:movie.path){try fm.removeItem(at:movie)}
        let writer=try AVAssetWriter(outputURL:movie,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1440,AVVideoHeightKey:900,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:12_000_000]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1440,kCVPixelBufferHeightKey as String:900,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        writer.add(input);guard writer.startWriting() else{throw writer.error!};writer.startSession(atSourceTime:.zero)
        setInputMode(.mouse);clearInput();cancelVoiceActions();demo=false
        configure(size);motion.position=SIMD2(-2,-1.5);motion.velocity = .zero;motion.yaw = -0.22
        var visited=Set<String>(),modes=Set<String>(),errors:[String]=[]
        var backwardFrames=0,maxSpeed:Float=0,offset:Float=0,heartFrames=0,centreError:Float=100,gpu:[Double]=[]
        let snapshots:[Int:String]=[90:"01_向前奔跑.png",215:"02_转身后向左跑.png",330:"03_手势摸摸.png",505:"04_星光爱心.png",675:"05_坐下.png",790:"06_单爪握手.png",880:"07_转圈.png"]
        let origin=ProcessInfo.processInfo.systemUptime
        for frame in 0..<frameCount {
            let time=origin+Double(frame)/Double(fps)
            if frame<270 {
                setMouse(SIMD2(frame<150 ? 0.91:0.09,0.57))
            } else if frame<360 {
                if frame==270{setInputMode(.hand)}
                let p=pose(count/4)
                let point=SIMD2(p.x,p.y)/SIMD2(uniforms.viewport.z,uniforms.viewport.w)+SIMD2(repeating:0.5)
                setHand(HandFrame(tip:point,palm:point,palmRadius:0.065,intent:.palm,confidence:0.98,timestamp:time))
            } else {
                if frame==360{setInputMode(.voice);performVoiceCommand(.come)}
                if frame==480{performVoiceCommand(.praise)}
                if frame==600{performVoiceCommand(.sit)}
                if frame==690{performVoiceCommand(.shake)}
                if frame==840{performVoiceCommand(.spin)}
            }
            let previous=motion.position,previousYaw=motion.yaw
            update(dt:1/Float(fps),size:size,now:time)
            let dx=motion.position.x-previous.x
            // Spin is an authored in-place action. Pursuit translations should
            // never visibly slide backwards relative to their facing direction.
            let middleYaw=previousYaw+atan2(sin(motion.yaw-previousYaw),cos(motion.yaw-previousYaw))*0.5
            if abs(dx)>0.0001 && dx*cos(middleYaw) < -0.0001 {backwardFrames+=1}
            visited.insert(voiceActions.phase.rawValue);modes.insert(inputMode.rawValue)
            maxSpeed=max(maxSpeed,simd_length(motion.velocity))
            let cb=encode(texture:texture);cb.commit();cb.waitUntilCompleted()
            gpu.append((cb.gpuEndTime-cb.gpuStartTime)*1000)
            if let e=cb.error{errors.append(e.localizedDescription)}
            offset=max(offset,displacement().0)
            if uniforms.praise.w>0{heartFrames+=1}
            if frame==475{centreError=simd_distance(motion.position,SIMD2(0,-motion.height*0.5))}
            if let name=snapshots[frame]{try savePNG(texture,to:directory.appendingPathComponent(name))}
            let label="SIMULATED INPUT / "+inputMode.rawValue.uppercased()+" ONLY / "+(voiceActions.active ? voiceActions.phase.rawValue:motion.state).uppercased()
            try appendVerificationFrame(texture:texture,adaptor:adaptor,input:input,writer:writer,frame:frame,fps:fps,label:label,locations:[])
        }
        input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()}
        guard done.wait(timeout:.now()+60) == .success,writer.status == .completed else{throw writer.error ?? NSError(domain:"V6Video",code:1)}
        let checks:[String:Bool]=["noBackwardFrames":backwardFrames==0,"fasterCruise":maxSpeed>3.0,"modesExclusive":modes==Set(["mouse","hand","voice"]),"voiceCentre":centreError<0.13,"voiceActionsVisited":["happy","sitting","sitExit","shake","spin"].allSatisfy{visited.contains($0)},"particleHeartsEmitted":heartFrames>60,"bodyNeverScatters":offset==0,"noMetalErrors":errors.isEmpty]
        let report:[String:Any]=["allPassed":checks.values.allSatisfy{$0},"checks":checks,"backwardFrames":backwardFrames,"maximumSpeed":maxSpeed,"centreError":centreError,"heartFrames":heartFrames,"metalErrors":errors,"averageGPUMilliseconds":gpu.reduce(0,+)/Double(max(1,gpu.count)),"movie":movie.lastPathComponent,"evidence":"Synthetic mouse, hand and voice events rendered by native app. No camera or microphone capture."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("v6_native_verification.json"))
        print("V6 native verification: \(checks.values.allSatisfy{$0} ? "PASS":"FAIL") \(checks)")
        if !checks.values.allSatisfy({$0}){throw NSError(domain:"V6Verification",code:1)}
    }
}
