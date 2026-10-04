import Cocoa
import MetalKit
import AVFoundation
import simd

extension PupRenderer {
    /// The actual geometry-to-proximity-to-animation path, with generated camera
    /// observations and an injected monotonic clock. Never opens a camera.
    func verifyHighFive(to directory:URL)throws {
        let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let width=1440,height=900,fps:Int32=30,frameCount=240
        let size=CGSize(width:width,height:height)
        let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:width,height:height,mipmapped:false)
        td.usage=[.renderTarget,.shaderRead];td.storageMode = .shared
        let texture=device.makeTexture(descriptor:td)!
        let movie=directory.appendingPathComponent("模拟输入_推掌与单爪击掌.mp4")
        if fm.fileExists(atPath:movie.path){try fm.removeItem(at:movie)}
        let writer=try AVAssetWriter(outputURL:movie,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:12_000_000]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        writer.add(input);guard writer.startWriting() else{throw writer.error!};writer.startSession(atSourceTime:.zero)
        configure(size);setInputMode(.hand);clearInput();highFive.cancel(immediately:true);demo=false
        petBlend=0;movingBlend=0;motion.position=SIMD2(-1.9,-1.3);motion.velocity = .zero;motion.yaw = -0.22
        let origin=ProcessInfo.processInfo.systemUptime
        let target=SIMD2<Float>(2.1,0.7),normalized=target/SIMD2(uniforms.viewport.z,uniforms.viewport.w)+SIMD2(repeating:0.5)
        var phases=Set<String>(),timings:[Double]=[],maxError:Float=0,finite=true,saved=false,flashFrames=0,bodyOffset:Float=0
        var samples:[[String:Any]]=[]
        for f in 0..<frameCount {
            let t=Float(f)/Float(fps),scale:Float=t<1 ? 1:(t<1.65 ? 1+(t-1)/0.65*0.38:1.38)
            let now=origin+Double(t)
            setHand(HandFrame(tip:normalized,palm:normalized,palmRadius:0.07,intent:.palm,confidence:0.96,timestamp:now,isHolding:false,palmWidth:0.14*scale,palmLength:0.16*scale,palmGeometryConfidence:0.96))
            update(dt:1/Float(fps),size:size,now:now)
            phases.insert(highFive.phase.rawValue)
            let cb=encode(texture:texture);cb.commit();cb.waitUntilCompleted()
            if let error=cb.error{throw error}
            timings.append((cb.gpuEndTime-cb.gpuStartTime)*1000)
            let d=displacement();bodyOffset=max(bodyOffset,d.0);finite = finite && d.2
            if highFive.flashAge<1.2 {flashFrames+=1}
            if highFive.flashAge<0.15 {
                let paw=pawSampleIndices.reduce(SIMD3<Float>.zero){$0+pose($1)}/Float(pawSampleIndices.count)
                maxError=max(maxError,simd_distance(SIMD2(paw.x,paw.y),target))
                if !saved && highFive.flashAge>0.09 {try savePNG(texture,to:directory.appendingPathComponent("单爪击掌.png"));saved=true}
            }
            if f%15==0{samples.append(["time":t,"phase":highFive.phase.rawValue,"animation":highFive.animationTime,"scale":proximity.relativeScale,"near":proximity.near,"completed":highFive.completedCount,"root":[motion.position.x,motion.position.y]])}
            try appendVerificationFrame(texture:texture,adaptor:adaptor,input:input,writer:writer,frame:f,fps:fps,label:"SIMULATED INPUT · OPEN PALM / HIGH FIVE · "+highFive.phase.rawValue.uppercased(),locations:[normalized])
        }
        input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()}
        guard done.wait(timeout:.now()+60) == .success,writer.status == .completed else{throw writer.error ?? NSError(domain:"HighFiveVideo",code:1)}
        let checks:[String:Bool]=["singleApproachProducesExactlyOneContact":highFive.completedCount==1,"allPhasesVisited":phases.count==4,"actualPawAlignsWithPalm":saved && maxError<0.34,"flashIsTransient":flashFrames>0 && uniforms.highFiveTouch.w==0,"bodyNeverScatters":bodyOffset==0,"finiteGPUState":finite,"returnsToIdle":highFive.phase == .idle]
        timings.sort()
        let report:[String:Any]=["evidence":"Synthetic HandFrame geometry; native Metal renderer; camera not opened; no physical depth accuracy claim","allPassed":checks.values.allSatisfy{$0},"checks":checks,"completedCount":highFive.completedCount,"maximumContactErrorWorldUnits":maxError,"gpuMeanMs":timings.reduce(0,+)/Double(timings.count),"gpuP95Ms":timings[Int(Double(timings.count-1)*0.95)],"samples":samples]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("highfive_native_verification.json"))
        print("High-five native validation: \(checks.values.allSatisfy{$0} ? "PASS":"FAIL") \(checks)")
        if !checks.values.allSatisfy({$0}){throw NSError(domain:"HighFiveValidation",code:1)}
    }
}
