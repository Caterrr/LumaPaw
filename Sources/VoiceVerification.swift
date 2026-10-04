import Cocoa
import MetalKit
import AVFoundation
import simd

extension PupRenderer {
    /// Generated transcripts enter the same parser and action controller. This
    /// proves rendering/audio timing, not microphone recognition accuracy.
    func verifyVoice(to directory:URL,resources:URL)throws {
        let fm=FileManager.default;try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let size=CGSize(width:1440,height:900),fps:Int32=30,frames=660
        let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:1440,height:900,mipmapped:false)
        td.usage=[.renderTarget,.shaderRead];td.storageMode = .shared
        let texture=device.makeTexture(descriptor:td)!
        let rawMovie=directory.appendingPathComponent("voice_silent_render.mp4")
        if fm.fileExists(atPath:rawMovie.path){try fm.removeItem(at:rawMovie)}
        let writer=try AVAssetWriter(outputURL:rawMovie,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1440,AVVideoHeightKey:900,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:12_000_000]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1440,kCVPixelBufferHeightKey as String:900,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        writer.add(input);guard writer.startWriting() else{throw writer.error!};writer.startSession(atSourceTime:.zero)
        setInputMode(.voice);clearInput();cancelVoiceActions();highFive.cancel(immediately:true);demo=false
        configure(size);motion.position=SIMD2(-2.55,-1.5);motion.velocity = .zero;motion.yaw = -0.22;petBlend=0;movingBlend=0
        let cues:[Int:String]=[15:"豆豆",90:"坐下",180:"握手",330:"转圈",450:"真棒",570:"豆豆"]
        let snapshots:[Int:String]=[70:"01_叫名字回中间.png",158:"02_坐下.png",267:"03_握手.png",366:"04_转圈.png",477:"05_开心冒爱心.png"]
        var parser=VoiceCommandParser(petName:"豆豆"),transcript="",segments:[VoiceTranscriptSegment]=[]
        var visited=Set<String>(),commands:[String]=[],barkTimes:[Double]=[],happyTimes:[Double]=[],time:Double=0
        var errors:[String]=[],offset:Float=0,heartFrames=0,centreError:Float=100
        let origin=ProcessInfo.processInfo.systemUptime
        onVoiceActionStarted={command in if command == .praise{happyTimes.append(time)}}
        defer{onVoiceActionStarted=nil}
        for frame in 0..<frames {
            time=Double(frame)/Double(fps)
            if let cue=cues[frame] {
                transcript+=cue+"，";segments.append(VoiceTranscriptSegment(text:cue,timestamp:origin+time,duration:0.4))
                for command in parser.process(transcript,sessionID:1,at:origin+time,segments:segments){
                    commands.append(command.rawValue);performVoiceCommand(command)
                    if command == .come{barkTimes.append(time)}
                }
            }
            update(dt:1/Float(fps),size:size,now:origin+time)
            visited.insert(voiceActions.phase.rawValue)
            let cb=encode(texture:texture);cb.commit();cb.waitUntilCompleted();if let e=cb.error{errors.append(e.localizedDescription)}
            offset=max(offset,displacement().0);if uniforms.praise.w>0{heartFrames+=1}
            if frame==88{centreError=simd_distance(motion.position,SIMD2(0,-motion.height*0.5))}
            if let name=snapshots[frame]{try savePNG(texture,to:directory.appendingPathComponent(name))}
            try appendVerificationFrame(texture:texture,adaptor:adaptor,input:input,writer:writer,frame:frame,fps:fps,label:"SIMULATED TRANSCRIPTS / VOICE ACTIONS · "+voiceActions.phase.rawValue.uppercased(),locations:[])
        }
        input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()}
        guard done.wait(timeout:.now()+60) == .success,writer.status == .completed else{throw writer.error ?? NSError(domain:"VoiceVideo",code:1)}
        let movie=directory.appendingPathComponent("模拟口令_声音与动作.mp4")
        try mixVoicePreview(video:rawMovie,output:movie,resources:resources,barks:barkTimes,happy:happyTimes)
        let checks:[String:Bool]=["oneCommandPerCue":commands==["come","sit","shake","spin","praise","come"],"calledDogReachesCentre":centreError<0.13,"sitHoldAndExitVisited":visited.contains("sitting") && visited.contains("sitExit"),"allActionsVisited":["coming","shake","spin","happy"].allSatisfy{visited.contains($0)},"praiseHeartsEmitted":heartFrames>60,"oneBarkPerNameCall":barkTimes.count==2,"bodyNeverScatters":offset==0,"noMetalErrors":errors.isEmpty]
        let report:[String:Any]=["evidence":"Generated transcripts, actual parser/actions/Metal. Audio mixed from shipped dog recordings. No microphone capture or live speech tested.","checks":checks,"allPassed":checks.values.allSatisfy{$0},"commands":commands,"centreError":centreError,"barkTimes":barkTimes,"happyTimes":happyTimes,"heartFrames":heartFrames,"metalErrors":errors,"movie":movie.lastPathComponent]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("voice_native_verification.json"))
        print("Voice native verification: \(checks.values.allSatisfy{$0} ? "PASS":"FAIL") \(checks)")
        if !checks.values.allSatisfy({$0}){throw NSError(domain:"VoiceVerification",code:1)}
    }
    private func mixVoicePreview(video:URL,output:URL,resources:URL,barks:[Double],happy:[Double])throws {
        let fm=FileManager.default;if fm.fileExists(atPath:output.path){try fm.removeItem(at:output)}
        let source=AVURLAsset(url:video),composition=AVMutableComposition(),duration=source.duration
        let track=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!
        guard let sourceTrack=source.tracks(withMediaType:.video).first else{throw NSError(domain:"VoiceVideoTrack",code:1)}
        try track.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:sourceTrack,at:.zero)
        var parameters:[AVMutableAudioMixInputParameters]=[]
        func addSound(_ name:String,at times:[Double],gain:Float,loop:Bool=false)throws {
            let asset=AVURLAsset(url:resources.appendingPathComponent("audio/"+name))
            guard let audio=asset.tracks(withMediaType:.audio).first else{throw NSError(domain:"VoiceAudioTrack",code:1)}
            let destination=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!
            let length=CMTimeGetSeconds(asset.duration),total=CMTimeGetSeconds(duration)
            let starts=loop ? stride(from:0.0,to:total,by:length).map{$0}:times
            for t in starts{let remaining=max(0,min(length,total-t));if remaining>0{try destination.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:remaining,preferredTimescale:48000)),of:audio,at:CMTime(seconds:t,preferredTimescale:48000))}}
            let parameter=AVMutableAudioMixInputParameters(track:destination);parameter.setVolume(gain,at:.zero);parameters.append(parameter)
        }
        try addSound("dog_breath_loop.wav",at:[],gain:0.10,loop:true)
        try addSound("dog_bark.wav",at:barks,gain:0.30)
        try addSound("dog_happy.wav",at:happy,gain:0.21)
        let mix=AVMutableAudioMix();mix.inputParameters=parameters
        guard let exporter=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality) else{throw NSError(domain:"VoiceMovieExport",code:1)}
        exporter.audioMix=mix;exporter.outputURL=output;exporter.outputFileType = .mp4
        let finished=DispatchSemaphore(value:0);exporter.exportAsynchronously{finished.signal()}
        guard finished.wait(timeout:.now()+60) == .success,exporter.status == .completed else{throw exporter.error ?? NSError(domain:"VoiceMovieExport",code:2)}
    }
}
