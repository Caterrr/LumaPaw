import Cocoa
import MetalKit
import MetalPerformanceShaders
import simd

struct PupUniforms {
    var clock=SIMD4<Float>(0,0,0,0)
    var viewport=SIMD4<Float>(1600,1000,11.2,7)
    var root=SIMD4<Float>(0,-1.3,-0.22,0)
    var frames=SIMD4<UInt32>(0,0,0,0)
    var animation=SIMD4<Float>(0,0,1,0.95)
    var otherFrames=SIMD4<UInt32>(0,0,0,0)
    var gait=SIMD4<Float>(0,0,0,0) // walk interpolation, pet interpolation, run fraction, pet weight
    var touch=SIMD4<Float>(0,0,0,0.65) // one palm centre, strength, radius
    var clipCounts=SIMD4<UInt32>(1,1,1,1)
    var effects=SIMD4<Float>(repeating:0)
    var praise=SIMD4<Float>(0,0,10,0) // heart emitter xy, age, active
    var highFiveTouch=SIMD4<Float>(0,0,10,0) // contact point, seconds since contact, active
    var background=SIMD4<Float>(0,0,0,0) // visibility * strength, interaction quieting, mote time, reserved
    var ball=SIMD4<Float>(repeating:0)
    var ballInfo=SIMD4<Float>(repeating:0)
    var presentation=SIMD4<Float>(1,0,0,0) // affine root scale, perspective amount
}
struct ClipInfo: Decodable {let name:String;let file:String;let normalsFile:String;let frameCount:Int;let fps:Float;var duration:Float?=nil;var loop:Bool?=nil}
struct AssetInfo: Decodable {let particleCount:Int;let clips:[ClipInfo]}
extension SIMD4 where Scalar == Float {var xyz:SIMD3<Float>{SIMD3(x,y,z)}}

/// Each animated surface sample is an exact barycentric combination of three
/// original mesh vertices. Invert well-spaced samples once to recover a compact
/// depth mesh from the SAME current blended pose, including personalized rigs.
private struct DepthSurfaceSource:Decodable {
    let triangles:[[Int]],weld:[Int],sampleTriangles:[[Int]],sampleBarycentric:[[Float]]
}
private typealias DogDepthSurface = (MTLBuffer,MTLBuffer,MTLBuffer,MTLBuffer,Int,Int)
private func depthSurface(_ resources:URL,_ device:MTLDevice,breed:DogBreed = .shiba)throws->DogDepthSurface {
    let m=try JSONDecoder().decode(DepthSurfaceSource.self,from:Data(contentsOf:resources.appendingPathComponent(breed.rigFilename)))
    let vertexCount=(m.weld.max() ?? -1)+1
    var groups:[[Int]:[Int]]=[:]
    for (i,t) in m.sampleTriangles.enumerated(){groups[t,default:[]].append(i)}
    var equations=[[Int:Float]?](repeating:nil,count:vertexCount),quality=[Float](repeating:0,count:vertexCount)
    for t in m.triangles {
        let ids=groups[t] ?? [];guard ids.count>=3 else{continue}
        let selected=(0..<3).map{axis in ids.max{m.sampleBarycentric[$0][axis]<m.sampleBarycentric[$1][axis]}!}
        let b=selected.map{m.sampleBarycentric[$0]}
        let matrix=simd_float3x3(columns:(SIMD3(b[0][0],b[1][0],b[2][0]),SIMD3(b[0][1],b[1][1],b[2][1]),SIMD3(b[0][2],b[1][2],b[2][2])))
        let q=abs(simd_determinant(matrix));guard q>0.015 else{continue}
        let inverse=simd_inverse(matrix)
        for corner in 0..<3 where q>quality[m.weld[t[corner]]] {
            var row:[Int:Float]=[:]
            for j in 0..<3 {row[selected[j],default:0]+=inverse[j][corner]}
            equations[m.weld[t[corner]]]=row;quality[m.weld[t[corner]]]=q
        }
    }
    // Tiny eye/ear triangles may have fewer than three samples. Recover their
    // remaining vertices from neighboring known vertices and one/two samples.
    for _ in 0..<8 {
        var progress=false
        for t in m.triangles {
            let unknown=(0..<3).filter{equations[m.weld[t[$0]]]==nil},ids=groups[t] ?? []
            guard !unknown.isEmpty,unknown.count<=2,!ids.isEmpty else{continue}
            var chosen:[Int]=[],inverse:[[Float]]=[]
            if unknown.count==1 {
                let axis=unknown[0],best=ids.max{m.sampleBarycentric[$0][axis]<m.sampleBarycentric[$1][axis]}!
                let value=m.sampleBarycentric[best][axis];guard value>0.015 else{continue}
                chosen=[best];inverse=[[1/value]]
            }else{
                var determinant:Float=0
                for a in ids {for b in ids where b>a {
                    let ba=m.sampleBarycentric[a],bb=m.sampleBarycentric[b]
                    let d=ba[unknown[0]]*bb[unknown[1]]-ba[unknown[1]]*bb[unknown[0]]
                    if abs(d)>abs(determinant){determinant=d;chosen=[a,b]}
                }}
                guard abs(determinant)>0.015 else{continue}
                let a=m.sampleBarycentric[chosen[0]],b=m.sampleBarycentric[chosen[1]]
                inverse=[[b[unknown[1]]/determinant,-a[unknown[1]]/determinant],[-b[unknown[0]]/determinant,a[unknown[0]]/determinant]]
            }
            for (r,corner) in unknown.enumerated() {
                var row:[Int:Float]=[:]
                for (j,sample) in chosen.enumerated() {
                    let coefficient=inverse[r][j];row[sample,default:0]+=coefficient
                    for known in 0..<3 where !unknown.contains(known) {
                        for (index,value) in equations[m.weld[t[known]]]! {row[index,default:0]-=coefficient*m.sampleBarycentric[sample][known]*value}
                    }
                }
                equations[m.weld[t[corner]]]=row.filter{abs($0.value)>0.0000001};progress=true
            }
        }
        if equations.allSatisfy({$0 != nil}){break};if !progress{break}
    }
    guard equations.allSatisfy({$0 != nil}) else{throw NSError(domain:"Incomplete animated depth surface",code:1)}
    var ranges:[SIMD2<UInt32>]=[],coefficients:[SIMD2<UInt32>]=[]
    for row in equations {
        let sorted=row!.sorted{$0.key<$1.key};ranges.append(SIMD2(UInt32(coefficients.count),UInt32(sorted.count)))
        for (index,weight) in sorted {coefficients.append(SIMD2(UInt32(index),weight.bitPattern))}
    }
    let indices=m.triangles.flatMap{$0.map{UInt32(m.weld[$0])}}
    func buffer<T>(_ array:[T])->MTLBuffer {array.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}}
    return (buffer(ranges),buffer(coefficients),buffer(indices),device.makeBuffer(length:vertexCount*16,options:.storageModePrivate)!,vertexCount,indices.count)
}
final class PupRenderer:NSObject,MTKViewDelegate {
    let device:MTLDevice,queue:MTLCommandQueue
    var idle:MTLBuffer,run:MTLBuffer,walk:MTLBuffer,pet:MTLBuffer,colors:MTLBuffer,normals:MTLBuffer,runNormals:MTLBuffer,walkNormals:MTLBuffer,petNormals:MTLBuffer
    var highfive:MTLBuffer,highfiveNormals:MTLBuffer
    var seeds:MTLBuffer
    let states:MTLBuffer
    private var breedSeeds:[DogBreed:MTLBuffer]=[:],breedSurfaces:[DogBreed:DogDepthSurface]=[:]
    let count:Int
    var idleInfo:ClipInfo,runInfo:ClipInfo,walkInfo:ClipInfo,petInfo:ClipInfo,highfiveInfo:ClipInfo
    var highFive=HighFiveController(),proximityTracker=HandProximityTracker(),proximity=HandProximityState()
    var highFivePaw=SIMD3<Float>(1.522,2.050,0.441),pawSampleIndices:[Int]=[]
    private var consumedHighFiveTrigger:UInt64=0
    private var pendingHighFiveTrigger:(id:UInt64,timestamp:Double)?
    var voiceActions=VoiceActionController()
    var mousePetSit=MousePetSitController()
    var screenHighFive=ScreenHighFiveController()
    var runningCircle=RunningCircleController()
    private(set) var screenHighFiveQueued=false
    private var screenFlashPoint=SIMD2<Float>.zero
    private var screenPoseHeight:Float=3,screenPoseForward:Float=2
    var voiceClips:[String:(positions:MTLBuffer,normals:MTLBuffer,info:ClipInfo)]=[:]
    var praiseAge:Float=10,praisePoint=SIMD2<Float>.zero
    var onVoiceActionStarted:((VoiceCommand)->Void)?
    private var seatedPointer:SIMD2<Float>?
    var voiceClip:(positions:MTLBuffer,normals:MTLBuffer,info:ClipInfo)? {voiceActions.clipName.flatMap{voiceClips[$0]}}
    var fetchClip:(positions:MTLBuffer,normals:MTLBuffer,info:ClipInfo)? {fetchReactionSelected ? voiceClips["fetch_pickup"]:nil}
    var screenClip:(positions:MTLBuffer,normals:MTLBuffer,info:ClipInfo)? {screenHighFive.active ? voiceClips["screen_highfive"]:nil}
    var reactionBuffer:MTLBuffer {fetchClip?.positions ?? screenClip?.positions ?? voiceClip?.positions ?? (highFive.usesClip ? highfive:pet)}
    var reactionNormals:MTLBuffer {fetchClip?.normals ?? screenClip?.normals ?? voiceClip?.normals ?? (highFive.usesClip ? highfiveNormals:petNormals)}
    var reactionInfo:ClipInfo {fetchClip?.info ?? screenClip?.info ?? voiceClip?.info ?? (highFive.usesClip ? highfiveInfo:petInfo)}
    var reactionLoops:Bool {fetchClip != nil ? false:screenClip != nil ? false:(voiceClip != nil ? voiceActions.loopsClip:!highFive.usesClip)}
    var reactionTime:Float {fetchClip != nil ? (fetchGame.poseActive ? fetchGame.clipTime:1.8):screenClip != nil ? screenHighFive.clipTime:(voiceClip != nil ? voiceActions.time:(highFive.usesClip ? highFive.animationTime:petTime))}
    let compute:MTLComputePipelineState,points:MTLRenderPipelineState,trailPipeline:MTLRenderPipelineState,ballPipeline:MTLRenderPipelineState,fur:MTLRenderPipelineState,down:MTLComputePipelineState,finish:MTLRenderPipelineState
    let reconstructDepth:MTLComputePipelineState,surfacePipeline:MTLRenderPipelineState,surfaceDepthState:MTLDepthStencilState
    var surfaceRanges:MTLBuffer,surfaceCoefficients:MTLBuffer,surfaceIndices:MTLBuffer,surfaceVertices:MTLBuffer
    var surfaceVertexCount:Int,surfaceIndexCount:Int
    let blur:MPSImageGaussianBlur
    var background:GaussianBackground?
    var backgroundEnabled=true,backgroundStrength:Float=0.65
    private var backgroundVisibility:Float=1,backgroundQuiet:Float=0,backgroundTime:Float=0
    private(set) var backgroundLoadError:String?
    let emptyBackground:MTLTexture
    var scene:MTLTexture?,small:MTLTexture?,blurred:MTLTexture?,surfaceDepth:MTLTexture?
    let motion=Pursuit()
    var uniforms=PupUniforms(),elapsed:Float=0,idleTime:Float=0,runTime:Float=0,walkTime:Float=0,petTime:Float=0
    // A dedicated idle-only preview keeps the home companion independent of
    // photo customization and in-game selection, without caching a second rig.
    private var homeIdle:(positions:MTLBuffer,normals:MTLBuffer,info:ClipInfo)?
    var homeMode=false
    var minimumWorldHeight:Float=6.8
    var allowsSeatedPetting=false
    var automaticallySitsWhilePetting=true
    var ambientParticleScale:Float=1
    let fetchGame=FetchGame()
    var handThrow=HandThrowController()
    private var fetchReactionSelected=false
    var noseSampleIndices:[Int]=[]
    var fetchNoseContact=SIMD3<Float>(1.6,0.24,0)
    var ballRadius:Float=0.12
    var mouthPosition:SIMD3<Float> {
        let nose=noseSampleIndices.isEmpty ? SIMD3(motion.position.x+cos(motion.yaw)*motion.noseReach,motion.position.y+motion.noseHeight,0):noseSampleIndices.reduce(SIMD3<Float>.zero){$0+pose($1)}/Float(noseSampleIndices.count)
        return nose+SIMD3(cos(motion.yaw)*ballRadius*0.15,-ballRadius*0.90,-sin(motion.yaw)*ballRadius*0.15)
    }
    let lightTrail=LightTrail()
    var lightTrailEnabled=true
    private var trailVertices:[LightTrail.Vertex]=[]
    private var trailIntent:HandIntent = .uncertain
    var petBlend:Float=0,movingBlend:Float=0
    // All locomotion uses the original gallop, including the first moving frame.
    let runFraction:Float=1
    var gaitLanding=GaitLanding()
    private var runStopTime:Float=0,runStopWeight:Float?
    var gaitPhase:Float=0,pettingDuration:Float=0,smoothedSpeed:Float=0,previousYaw:Float = -0.22
    var intent:HandIntent = .uncertain,palm:SIMD2<Float>?,palmRadius:Float=0.055
    var mousePetting=false,contactDuration:Float=0,releaseDuration:Float=0
    var morphology=MorphologyParameters()
    var morphologyEngine:ParametricDogAssets?
    var beagleMorphologyEngine:ParametricDogAssets?
    var dalmatianMorphologyEngine:ParametricDogAssets?
    private var coatColors:[DogBreed:MTLBuffer]=[:]
    func morphologyEngine(for breed:DogBreed)->ParametricDogAssets? {
        switch breed {case .shiba:return morphologyEngine;case .beagle:return beagleMorphologyEngine;case .dalmatian:return dalmatianMorphologyEngine}
    }
    var pointer:SIMD2<Float>?,fingers:[SIMD2<Float>]=[],lastFingers:[SIMD2<Float>]=[]
    private(set) var inputMode:InteractionMode = .mouse
    var inputIsCamera=false,cameraEnabled=false,handTimestamp:Double=0,handArrival:Double=0,handHolding=false,handGeometryReliable=false,demo=false,paused=false
    var lastTime=CACurrentMediaTime(),frames=0,touching=false
    var onFrame:(()->Void)?
    var gpuTimes:[Double]=[],metalErrors:[String]=[]
    var drawAttempts=0,drawPaused=0,drawOccluded=0,drawNoDrawable=0
    private let semaphore=DispatchSemaphore(value:2)
    init(resources:URL,loadBackground:Bool=true,bloomSigma:Float=4.0)throws {
        guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else{throw NSError(domain:"Metal",code:1)}
        device=d;queue=q
        let info=try JSONDecoder().decode(AssetInfo.self,from:Data(contentsOf:resources.appendingPathComponent("manifest.json")))
        count=info.particleCount
        guard let a=info.clips.first(where:{$0.name=="idle"}),let b=info.clips.first(where:{$0.name=="run"}),count>0 else{throw NSError(domain:"Clips",code:1)}
        idleInfo=a;runInfo=b
        walkInfo=info.clips.first(where:{$0.name=="walk"}) ?? a
        petInfo=info.clips.first(where:{$0.name=="pet"}) ?? a
        highfiveInfo=info.clips.first(where:{$0.name=="highfive"}) ?? a
        func load(_ name:String,_ expected:Int)throws->MTLBuffer {
            let data=try Data(contentsOf:resources.appendingPathComponent(name),options:.mappedIfSafe)
            guard data.count==expected else{throw NSError(domain:"Asset size: \(name), \(data.count) != \(expected)",code:1)}
            return data.withUnsafeBytes{d.makeBuffer(bytes:$0.baseAddress!,length:data.count,options:.storageModeShared)!}
        }
        idle=try load(a.file,count*a.frameCount*12);run=try load(b.file,count*b.frameCount*12)
        walk=try load(walkInfo.file,count*walkInfo.frameCount*12);pet=try load(petInfo.file,count*petInfo.frameCount*12)
        highfive=try load(highfiveInfo.file,count*highfiveInfo.frameCount*12);highfiveNormals=try load(highfiveInfo.normalsFile,count*highfiveInfo.frameCount*12)
        walkNormals=try load(walkInfo.normalsFile,count*walkInfo.frameCount*12);petNormals=try load(petInfo.normalsFile,count*petInfo.frameCount*12)
        seeds=try load("seeds.bin",count*16);colors=try load("colors.bin",count*16);normals=try load(a.normalsFile,count*a.frameCount*12);runNormals=try load(b.normalsFile,count*b.frameCount*12)
        states=d.makeBuffer(length:count*32,options:.storageModeShared)!;memset(states.contents(),0,states.length)
        let lib=try d.makeLibrary(source:String(contentsOf:resources.appendingPathComponent("Particles.metal"),encoding:.utf8),options:nil)
        compute=try d.makeComputePipelineState(function:lib.makeFunction(name:"simulate")!)
        reconstructDepth=try d.makeComputePipelineState(function:lib.makeFunction(name:"reconstructSurface")!)
        let surface=try depthSurface(resources,d)
        surfaceRanges=surface.0;surfaceCoefficients=surface.1;surfaceIndices=surface.2;surfaceVertices=surface.3;surfaceVertexCount=surface.4;surfaceIndexCount=surface.5
        let sp=MTLRenderPipelineDescriptor();sp.vertexFunction=lib.makeFunction(name:"surfaceVertex");sp.fragmentFunction=lib.makeFunction(name:"surfaceFragment");sp.depthAttachmentPixelFormat = .depth32Float
        surfacePipeline=try d.makeRenderPipelineState(descriptor:sp)
        let ds=MTLDepthStencilDescriptor();ds.depthCompareFunction = .less;ds.isDepthWriteEnabled=true;surfaceDepthState=d.makeDepthStencilState(descriptor:ds)!
        down=try d.makeComputePipelineState(function:lib.makeFunction(name:"downsample")!)
        let pd=MTLRenderPipelineDescriptor();pd.vertexFunction=lib.makeFunction(name:"particleVertex");pd.fragmentFunction=lib.makeFunction(name:"particleFragment");pd.colorAttachments[0].pixelFormat = .rgba16Float
        let ca=pd.colorAttachments[0]!;ca.isBlendingEnabled=true;ca.sourceRGBBlendFactor = .one;ca.destinationRGBBlendFactor = .one;ca.sourceAlphaBlendFactor = .one;ca.destinationAlphaBlendFactor = .one
        points=try d.makeRenderPipelineState(descriptor:pd)
        let tp=MTLRenderPipelineDescriptor();tp.vertexFunction=lib.makeFunction(name:"lightTrailVertex");tp.fragmentFunction=lib.makeFunction(name:"lightTrailFragment");tp.colorAttachments[0].pixelFormat = .rgba16Float
        let ta=tp.colorAttachments[0]!;ta.isBlendingEnabled=true;ta.sourceRGBBlendFactor = .one;ta.destinationRGBBlendFactor = .one;ta.sourceAlphaBlendFactor = .one;ta.destinationAlphaBlendFactor = .one
        trailPipeline=try d.makeRenderPipelineState(descriptor:tp)
        let bp=MTLRenderPipelineDescriptor();bp.vertexFunction=lib.makeFunction(name:"ballVertex");bp.fragmentFunction=lib.makeFunction(name:"ballFragment");bp.colorAttachments[0].pixelFormat = .rgba16Float
        let ba=bp.colorAttachments[0]!;ba.isBlendingEnabled=true;ba.sourceRGBBlendFactor = .one;ba.destinationRGBBlendFactor = .oneMinusSourceAlpha;ba.sourceAlphaBlendFactor = .one;ba.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        ballPipeline=try d.makeRenderPipelineState(descriptor:bp)
        let fp=MTLRenderPipelineDescriptor();fp.vertexFunction=lib.makeFunction(name:"furVertex");fp.fragmentFunction=lib.makeFunction(name:"furFragment");fp.colorAttachments[0].pixelFormat = .rgba16Float
        let fa=fp.colorAttachments[0]!;fa.isBlendingEnabled=true;fa.sourceRGBBlendFactor = .one;fa.destinationRGBBlendFactor = .oneMinusSourceAlpha;fa.sourceAlphaBlendFactor = .one;fa.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        fur=try d.makeRenderPipelineState(descriptor:fp)
        let fd=MTLRenderPipelineDescriptor();fd.vertexFunction=lib.makeFunction(name:"fullscreen");fd.fragmentFunction=lib.makeFunction(name:"finish");fd.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        finish=try d.makeRenderPipelineState(descriptor:fd)
        blur=MPSImageGaussianBlur(device:d,sigma:bloomSigma);blur.edgeMode = .clamp
        let empty=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
        empty.storageMode = .shared;empty.usage=[.shaderRead];emptyBackground=d.makeTexture(descriptor:empty)!
        var zero:UInt32=0;emptyBackground.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&zero,bytesPerRow:4)
        // Optional scenery must never prevent the dog from launching.
        do{if loadBackground{background=try GaussianBackground(device:d,library:lib,resources:resources)}}
        catch{backgroundLoadError=error.localizedDescription;backgroundEnabled=false}
        super.init();uniforms.clock.w=Float(count)
        morphologyEngine=try ParametricDogAssets(resources:resources)
        breedSeeds[.shiba]=seeds
        breedSurfaces[.shiba]=(surfaceRanges,surfaceCoefficients,surfaceIndices,surfaceVertices,surfaceVertexCount,surfaceIndexCount)
        beagleMorphologyEngine=try ParametricDogAssets(resources:resources,breed:.beagle)
        breedSeeds[.beagle]=try load("beagle_seeds.bin",count*16)
        coatColors[.beagle]=try load("beagle_colors.bin",count*16)
        breedSurfaces[.beagle]=try depthSurface(resources,d,breed:.beagle)
        dalmatianMorphologyEngine=try ParametricDogAssets(resources:resources,breed:.dalmatian)
        breedSeeds[.dalmatian]=try load("dalmatian_seeds.bin",count*16)
        coatColors[.dalmatian]=try load("dalmatian_colors.bin",count*16)
        breedSurfaces[.dalmatian]=try depthSurface(resources,d,breed:.dalmatian)
        let preview=try dalmatianMorphologyEngine!.bake(parameters:DogBreed.dalmatian.parameters,onlyClips:["idle"])
        if let clip=preview.clips["idle"] {
            func previewBuffer(_ data:Data)->MTLBuffer {data.withUnsafeBytes{d.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}}
            homeIdle=(previewBuffer(clip.positions),previewBuffer(clip.normals),ClipInfo(name:"idle",file:"",normalsFile:"",frameCount:clip.frameCount,fps:clip.fps,duration:clip.duration,loop:true))
        }
        try applyMorphology(morphologyEngine!.bake(parameters:MorphologyParameters()))
        applyPalette(.amber)
    }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){scene=nil}
    func world(_ p:SIMD2<Float>)->SIMD2<Float>{(p-SIMD2(repeating:0.5))*SIMD2(uniforms.viewport.z,uniforms.viewport.w)}
    func configure(_ size:CGSize){
        let aspect=Float(max(size.width,1)/max(size.height,1)),h=max(max(minimumWorldHeight,motion.height*1.65),8.5/aspect)
        if abs(uniforms.viewport.z-h*aspect)>0.01 || abs(uniforms.viewport.w-h)>0.01 {
            if fetchGame.active{fetchGame.reset()}
            if handThrow.active{handThrow.cancel()}
        }
        uniforms.viewport=SIMD4(Float(size.width),Float(size.height),h*aspect,h)
    }
    func clearInput(preserveTrail:Bool=false,preserveThrow:Bool=false) {
        if handThrow.active && !preserveThrow{handThrow.cancel()}
        if !preserveTrail {lightTrail.reset();trailVertices=[];fetchGame.reset()}
        proximityTracker.reset();proximity=HandProximityState();pendingHighFiveTrigger=nil;highFive.cancel()
        pointer=nil;palm=nil;fingers=[];lastFingers=[];intent = .uncertain;mousePetting=false;handHolding=false;handGeometryReliable=false
        contactDuration=0;releaseDuration=0
        releaseMouseSit()
    }
    func setInputMode(_ mode:InteractionMode){
        inputMode=mode;cameraEnabled = mode == .hand;demo=false
        clearInput();handThrow.reset();highFive.cancel(immediately:true);cancelVoiceActions()
        touching=false;pettingDuration=0;petBlend=0
    }
    func setHand(_ frame:HandFrame?,now:Double=ProcessInfo.processInfo.systemUptime){
        guard inputMode == .hand,cameraEnabled else{return};inputIsCamera=true
        guard let f=frame else{
            _=handThrow.process(nil,allowed:!homeMode,canBegin:true,now:now)
            clearInput(preserveTrail:true,preserveThrow:true);return
        }
        guard HandTrackingLimits.accepts(f,at:now) else {
            _=handThrow.process(nil,allowed:!homeMode,canBegin:true,now:now)
            return
        }
        if !f.isHolding {handArrival=now}
        let throwAllowed = !homeMode && !demo && !fetchGame.active && !voiceActions.active && !highFive.active && !screenHighFive.active && !screenHighFiveQueued && !runningCircle.active
        let canBegin = throwAllowed
        let event=handThrow.process(f,allowed:throwAllowed,canBegin:canBegin,now:now)
        if let event {
            let origin=world(event.origin)
            _=throwBall(handOrigin:origin,handTravel:event.travel)
            handTimestamp=f.timestamp
            return
        }
        if handThrow.suppressesOtherGestures {
            proximityTracker.reset();proximity=HandProximityState();pendingHighFiveTrigger=nil
            pointer=nil;palm=nil;fingers=[];intent = .uncertain;touching=false;contactDuration=0
            handTimestamp=f.timestamp;handHolding=f.isHolding;handGeometryReliable=false
            return
        }
        proximity=proximityTracker.process(f)
        if proximity.triggered && proximity.triggerID>consumedHighFiveTrigger {
            pendingHighFiveTrigger=(proximity.triggerID,f.timestamp)
        }
        pointer=f.intent == .pointing ? f.tip : nil
        palm=f.intent == .palm ? f.palm : nil
        handGeometryReliable=f.confidence>=0.60 && f.palmGeometryConfidence>=0.60 && f.palmWidth.isFinite && f.palmLength.isFinite && f.palmWidth>=0.025 && f.palmLength>=0.025 && f.palmWidth<1.5 && f.palmLength<1.5
        palmRadius=f.palmRadius;intent=f.intent;handTimestamp=f.timestamp;handHolding=f.isHolding
        fingers=f.intent == .pointing ? [f.tip] : (f.intent == .palm ? [f.palm] : [])
    }
    func setMouse(_ point:SIMD2<Float>?){
        guard inputMode == .mouse,!cameraEnabled && !demo else{return};inputIsCamera=false
        pointer=mousePetting ? nil:point;palm=mousePetting ? point:nil
        intent=point == nil ? .uncertain:(mousePetting ? .palm:.pointing)
        fingers=point.map{[$0]} ?? [];palmRadius=0.055
    }
    func setMousePetting(_ active:Bool,point:SIMD2<Float>?){
        guard inputMode == .mouse,!cameraEnabled && !demo else{return};mousePetting=active;setMouse(point)
        if !active{releaseMouseSit()}
    }
    private func releaseMouseSit(){
        if mousePetSit.release(){
            voiceActions.standAfterPetting(enterDuration:voiceClips["sit_enter"]?.info.duration ?? 1.4,
                                           exitDuration:voiceClips["sit_exit"]?.info.duration ?? 1.4)
        }
    }
    func pose(_ i:Int)->SIMD3<Float>{
        func sample(_ buffer:MTLBuffer,_ a:UInt32,_ b:UInt32,_ blend:Float,loop:Bool=true)->SIMD3<Float>{
            let v=buffer.contents().bindMemory(to:Float.self,capacity:buffer.length/4)
            func p(_ frame:UInt32)->SIMD3<Float>{let safe=min(Int(frame),buffer.length/(count*12)-1);let j=(safe*count+i)*3;return SIMD3(v[j],v[j+1],v[j+2])}
            let frameCount=UInt32(buffer.length/(count*12)),p0=p(loop ? (a+frameCount-1)%frameCount:(a>0 ? a-1:0)),p1=p(a),p2=p(b),p3=p(loop ? (b+1)%frameCount:min(b+1,frameCount-1))
            let t=blend,t2=t*t,t3=t2*t
            let quadratic:SIMD3<Float> = p0*2.0-p1*5.0+p2*4.0-p3
            let cubic:SIMD3<Float> = -p0+p1*3.0-p2*3.0+p3
            let curve:SIMD3<Float> = (p1*2.0+(p2-p0)*t+quadratic*t2+cubic*t3)*0.5
            return simd_clamp(curve,simd_min(p1,p2),simd_max(p1,p2))
        }
        let a=sample(idle,uniforms.frames.x,uniforms.frames.y,uniforms.animation.x)
        let b=sample(run,uniforms.frames.z,uniforms.frames.w,uniforms.animation.y)
        let w=sample(walk,uniforms.otherFrames.x,uniforms.otherFrames.y,uniforms.gait.x)
        let petPose=sample(reactionBuffer,uniforms.otherFrames.z,uniforms.otherFrames.w,uniforms.gait.y,loop:uniforms.effects.w<0.5)
        let locomotion=simd_mix(w,b,SIMD3(repeating:uniforms.gait.z))
        let v=simd_mix(simd_mix(a,locomotion,SIMD3(repeating:uniforms.clock.z)),petPose,SIMD3(repeating:uniforms.gait.w))
        let c=cos(uniforms.root.z),s=sin(uniforms.root.z),scale=uniforms.presentation.x
        let rotated=SIMD3(v.x*c+v.z*s,v.y,-v.x*s+v.z*c)*scale
        let denominator=max(0.65,1-(rotated.z/max(scale,0.001))*uniforms.presentation.y)
        return SIMD3(rotated.x/denominator+uniforms.root.x,rotated.y/denominator+uniforms.root.y,rotated.z)
    }
    func isHit(_ locations:[SIMD2<Float>],radius:Float=0.18)->Bool{
        guard !locations.isEmpty else{return false}
        for i in stride(from:0,to:count,by:max(1,count/1200)){
            let p=pose(i)
            if locations.contains(where:{simd_distance_squared($0,SIMD2(p.x,p.y))<radius*radius}){return true}
        };return false
    }
    @discardableResult func throwBall(handOrigin:SIMD2<Float>? = nil,handTravel:Float = 0)->Bool {
        guard !homeMode,!fetchGame.active else{return false}
        demo=false;clearInput();highFive.cancel(immediately:true);cancelVoiceActions()
        touching=false;pettingDuration=0
        let contact=fetchNoseContact+SIMD3<Float>(ballRadius*0.15,-ballRadius*0.90,0)
        return fetchGame.launch(root:motion.position,bounds:motion.rootBounds(SIMD2(uniforms.viewport.z,uniforms.viewport.w)),contact:contact,radius:ballRadius,height:motion.height,handOrigin:handOrigin,handTravel:handTravel)
    }
    func performVoiceCommand(_ command:VoiceCommand){
        guard inputMode == .voice else{return}
        lightTrail.reset();fetchGame.reset()
        demo=false;highFive.cancel();pendingHighFiveTrigger=nil;proximityTracker.reset();proximity=HandProximityState()
        touching=false;contactDuration=0;releaseDuration=0
        voiceActions.request(command)
    }
    func cancelVoiceActions(){
        voiceActions.reset();mousePetSit.reset();screenHighFiveQueued=false;screenHighFive.cancel();runningCircle.cancel()
        praiseAge=10;if !screenHighFive.active{petBlend=0};seatedPointer=nil
    }
    /// A committed screen performance finishes even if the camera hand leaves.
    /// Fade any petting pose and stop first, then run directly toward the viewer.
    func requestScreenHighFive(){
        guard !screenHighFive.active,!screenHighFiveQueued else{return}
        handThrow.cancel();fetchGame.reset();demo=false;screenHighFiveQueued=true;highFive.cancel();touching=false;contactDuration=0;releaseDuration=0
    }
    func update(dt raw:Float,size:CGSize,now:Double=ProcessInfo.processInfo.systemUptime){
        let dt:Float=raw.isFinite ? min(max(raw,0),1/15):0;configure(size);elapsed+=dt
        if demo {
            let cycle=elapsed.truncatingRemainder(dividingBy:22)
            if cycle<11 {intent = .pointing;pointer=SIMD2(0.5+sin(elapsed*0.55)*0.35,0.5);palm=nil;fingers=[pointer!]}
            else if cycle<19 {intent = .palm;pointer=nil;palm=(motion.position+SIMD2(0.5,2.1))/SIMD2(uniforms.viewport.z,uniforms.viewport.w)+SIMD2(repeating:0.5);fingers=[palm!]}
            else{clearInput()}
        }
        if cameraEnabled && !demo {
            handThrow.expire(at:now)
            if now-handArrival>HandTrackingLimits.occlusionHold {handHolding=true}
            if now-handArrival>HandTrackingLimits.arrivalTimeout {
                clearInput(preserveTrail:true,preserveThrow:true)
            }
        }
        let worldPalm=palm.map{world($0)}
        let radius=max(0.20,min(0.72,palmRadius*uniforms.viewport.w))
        let freshPalm=cameraEnabled && intent == .palm && !handHolding && handGeometryReliable && now-handTimestamp>=0 && now-handTimestamp<0.15
        if let pending=pendingHighFiveTrigger {
            // A held camera callback can arrive between the trigger and draw.
            // Keep that event briefly; never consume it on an uncertain frame.
            if fetchGame.active || highFive.active || voiceActions.active || screenHighFive.active || screenHighFiveQueued || now-pending.timestamp>0.28 || demo {
                consumedHighFiveTrigger=pending.id;pendingHighFiveTrigger=nil
            } else if proximity.near && freshPalm,worldPalm != nil {
                requestScreenHighFive()
                consumedHighFiveTrigger=pending.id;pendingHighFiveTrigger=nil
            }
        }
        let expectedPaw=SIMD2(highFivePaw.x*cos(motion.yaw)+highFivePaw.z*sin(motion.yaw),highFivePaw.y)+motion.position
        let arrivalTarget=freshPalm && proximity.near ? (worldPalm ?? highFive.target):highFive.target
        let arrived=simd_distance(expectedPaw,arrivalTarget)<0.16 && simd_length(motion.velocity)<0.12
        highFive.update(dt:dt,palm:worldPalm,fresh:freshPalm,near:proximity.near,arrived:arrived,reactionReady:petBlend<0.02,duration:Float(highfiveInfo.frameCount)/highfiveInfo.fps)
        let oldVoicePhase=voiceActions.phase,oldPraise=voiceActions.praiseCount
        if !mousePetSit.ownsSit,voiceActions.phase == .sitting,intent == .pointing,!handHolding,let pointer {
            if let previous=seatedPointer,simd_distance(pointer,previous)>0.045{voiceActions.standForHand()}
            else if seatedPointer == nil{seatedPointer=pointer}
        }
        let centreRoot=SIMD2<Float>(0,-motion.height*0.5)
        voiceActions.update(dt:dt,ready:petBlend<0.02 && movingBlend<0.02 && !gaitLanding.active && !highFive.active && !screenHighFive.active && !screenHighFiveQueued && !runningCircle.active,stopped:simd_length(motion.velocity)<0.12,
                            atCentre:simd_distance(motion.position,centreRoot)<0.12 && simd_length(motion.velocity)<0.10,
                            yaw:motion.yaw,duration:{self.voiceClips[$0]?.info.duration ?? 2.4},
                            screenHighFiveFinished:oldVoicePhase == .shake ? (!screenHighFive.active && !screenHighFiveQueued):nil,
                            runningCircleFinished:oldVoicePhase == .spin ? !runningCircle.active:nil)
        if voiceActions.phase == .shake && oldVoicePhase != .shake {requestScreenHighFive()}
        if voiceActions.phase == .spin && oldVoicePhase != .spin {
            _=runningCircle.request(position:motion.position,yaw:motion.yaw,worldSize:SIMD2(uniforms.viewport.z,uniforms.viewport.w),radius:motion.horizontalRadius,height:motion.height)
        }
        let circleOwned=runningCircle.active
        runningCircle.update(dt:dt)
        if screenHighFiveQueued,petBlend<0.02,movingBlend<0.02,!gaitLanding.active,simd_length(motion.velocity)<0.12,!highFive.active,!runningCircle.active {
            screenHighFiveQueued=false
            _=screenHighFive.request(position:motion.position,yaw:motion.yaw,height:motion.height,strideLength:motion.strideLength)
            gaitPhase=0;gaitLanding.reset()
        }
        let screenOwned=screenHighFive.active,oldScreenContact=screenHighFive.contactCount
        screenHighFive.update(dt:dt)
        if voiceActions.phase == .sitting && oldVoicePhase != .sitting{seatedPointer=pointer}
        if voiceActions.praiseCount != oldPraise{praiseAge=0;onVoiceActionStarted?(.praise)}else{praiseAge=min(10,praiseAge+dt)}
        let seatedPet=(allowsSeatedPetting && voiceActions.phase == .sitting) || mousePetSit.ownsSit
        let canPet = !homeMode && !fetchGame.active && (!voiceActions.active || seatedPet) && !highFive.active && !screenHighFive.active && !screenHighFiveQueued && !runningCircle.active && intent == .palm
        let actualContact=canPet && worldPalm.map{isHit([$0],radius:radius+(touching ? 0.10:0))} == true
        let petPressed = inputMode == .mouse ? mousePetting:(inputMode == .hand && intent == .palm)
        let contact=canPet && (actualContact || (petPressed && mousePetSit.retainsContact(at:worldPalm)))
        if contact {contactDuration+=dt;releaseDuration=0}else{contactDuration=0;releaseDuration+=dt}
        let wasTouching=touching
        if contactDuration>=0.045{touching=true}
        if releaseDuration>=0.18 || intent != .palm || highFive.active || (voiceActions.active && !seatedPet) || screenOwned || circleOwned || screenHighFiveQueued{touching=false;contactDuration=0}
        if touching && !wasTouching && petBlend<0.12 {petTime=0;pettingDuration=0}
        if touching{pettingDuration+=dt}else{pettingDuration=max(0,pettingDuration-dt*2)}
        // Held camera positions retain contact but cannot earn unobserved time.
        let petDelta = inputMode == .hand && handHolding ? 0:dt
        if let event=mousePetSit.update(dt:petDelta,enabled:automaticallySitsWhilePetting && (inputMode == .mouse || inputMode == .hand) && !homeMode && !demo,
                                         pressed:petPressed,contact:contact,actualContact:actualContact,
                                         point:worldPalm,phase:voiceActions.phase){
            switch event {
            case .sit:voiceActions.request(.sit);praiseAge=0
            case .stand:
                voiceActions.standAfterPetting(enterDuration:voiceClips["sit_enter"]?.info.duration ?? 1.4,
                                               exitDuration:voiceClips["sit_exit"]?.info.duration ?? 1.4)
            }
        }
        lightTrail.advance(dt:dt)
        let trailBlocked=homeMode || !lightTrailEnabled
        let fresh = !inputIsCamera || (!handHolding && now-handTimestamp<HandTrackingLimits.maximumFrameAge)
        // Show the same short white stroke at the actual interaction position:
        // fingertip for guiding, palm centre (mouse press) for petting/aiming.
        // Switching anchors must not draw a line between finger and palm.
        if trailIntent != intent {lightTrail.stopDrawing();trailIntent=intent}
        let trailPoint = intent == .palm ? worldPalm:(intent == .pointing ? pointer.map{world($0)}:nil)
        if !trailBlocked && trailPoint != nil && inputIsCamera && handHolding {lightTrail.pauseDrawing()}
        else {lightTrail.draw(at:!trailBlocked && fresh ? trailPoint:nil)}
        fetchGame.update(dt:dt,root:motion.position,speed:simd_length(motion.velocity),yaw:motion.yaw,reactionReady:petBlend<0.02 && movingBlend<0.02 && !gaitLanding.active)
        if fetchGame.poseActive {fetchReactionSelected=true}
        else if petBlend<0.01 {fetchReactionSelected=false}
        let approaching=highFive.phase == .approaching
        let coming=voiceActions.phase == .coming
        if screenOwned {
            // Apply the completion sample as well as active samples: the final
            // frame restores the exact original root and unit scale.
            motion.position=screenHighFive.position;motion.yaw=screenHighFive.yaw;motion.velocity = .zero
            // Fit unusually tall personalized ears/legs inside even the native
            // minimum window. Derive one close target, then ease toward it with
            // the controller so the fit never clamps a moving zoom abruptly.
            let floorMagnitude=min(2.25,max(1.35,motion.height*0.66))
            let fit=(uniforms.viewport.w*0.5-0.20+floorMagnitude)*max(0.65,1-screenPoseForward*0.05)/max(0.1,screenPoseHeight)
            let closeScale=min(1.55,max(1,fit)),scale=1+(screenHighFive.scale-1)*(closeScale-1)/0.55
            uniforms.presentation=SIMD4(scale,0.05*max(0,(scale-1)/0.55),0,0)
        }else if circleOwned {
            motion.position=runningCircle.position;motion.yaw=runningCircle.yaw;motion.velocity = .zero
            uniforms.presentation=SIMD4(runningCircle.scale,0,0,0)
        }else{
            let blocked=voiceActions.active || screenHighFiveQueued
            let pointerTarget=intent == .pointing && fresh ? pointer.map{world($0)}:nil
            let target=fetchGame.active ? fetchGame.target:(coming ? SIMD2<Float>.zero:(blocked ? nil:(approaching ? (freshPalm && proximity.near ? highFive.target:nil):(highFive.active ? nil:pointerTarget))))
            let offset:SIMD3<Float>?=fetchGame.active ? .zero:(coming ? SIMD3<Float>(0,motion.height*0.5,0):(approaching ? highFivePaw:nil))
            motion.synchronizeGait(to:gaitPhase)
            motion.update(dt:dt,target:target,touching:fetchGame.freezesBody || touching || highFive.usesClip || screenHighFiveQueued || (voiceActions.active && !coming),worldSize:SIMD2(uniforms.viewport.z,uniforms.viewport.w),targetOffset:offset,continuous:false,gentleTurns:fetchGame.active,pace:fetchGame.held ? 0.84:1)
            if let heading=fetchGame.desiredYaw,simd_length(motion.velocity)<0.20 {
                let difference=atan2(sin(heading-motion.yaw),cos(heading-motion.yaw))
                motion.yaw+=difference*(1-exp(-dt*10))
            }
            uniforms.presentation=SIMD4(1,0,0,0)
        }
        let speed=screenOwned ? abs(screenHighFive.forwardSpeed):(circleOwned ? runningCircle.speed:simd_length(motion.velocity))
        smoothedSpeed+=(speed-smoothedSpeed)*(1-exp(-dt*14))
        let movingTarget:Float=screenOwned ? screenHighFive.runWeight:(circleOwned ? runningCircle.runWeight:smooth(0.025,0.40,smoothedSpeed))
        if screenOwned || circleOwned {movingBlend=movingTarget}else{movingBlend+=(movingTarget-movingBlend)*(1-exp(-9*dt))}
        // Let the current pet pose relax before the authored sit begins. Once
        // owned, physical petting cannot force the standing pet clip back in.
        let petTarget:Float=mousePetSit.ownsSit ? (voiceActions.wantsClipWeight ? 1:0):(fetchGame.active ? (fetchGame.poseActive ? 1:0):(voiceActions.wantsClipWeight || highFive.wantsClipWeight || touching ? 1:0))
        let reactionRate:Float=fetchGame.active || fetchReactionSelected || highFive.active || voiceActions.active ? 10:(touching ? 5.0:3.6)
        if screenOwned {petBlend=screenHighFive.clipWeight}else{petBlend+=(petTarget-petBlend)*(1-exp(-reactionRate*dt))}
        idleTime+=dt
        let travelled:Float=screenOwned ? screenHighFive.travelledDistance:(circleOwned ? runningCircle.travelledDistance:motion.travelledDistance)
        if screenOwned || circleOwned {
            runStopWeight=nil;runStopTime=0
            gaitLanding.reset()
            gaitPhase=(gaitPhase+travelled/motion.strideLength).truncatingRemainder(dividingBy:1)
        } else if motion.strideStopped {
            // A regular arrival already travelled through the entire stride.
            // Blend out its landing pose without adding stationary foot cycles.
            gaitLanding.reset();gaitPhase=motion.phase
            if runStopWeight == nil {runStopWeight=movingBlend;runStopTime=0}
            runStopTime+=dt
            let t=min(1,runStopTime/0.24),ease=t*t*t*(10+t*(-15+6*t))
            movingBlend=(runStopWeight ?? 0)*(1-ease)
        } else {
            runStopWeight=nil;runStopTime=0
            let landed=gaitLanding.advance(dt:dt,distance:travelled,stride:motion.strideLength,phase:gaitPhase,blend:movingBlend,speed:speed)
            gaitPhase=landed.phase;movingBlend=landed.blend
        }
        if gaitPhase<0{gaitPhase+=1}
        walkTime=gaitPhase*Float(walkInfo.frameCount)/walkInfo.fps
        // Preserve the restored original gallop contact phase.
        let runPhase=(gaitPhase+0.40).truncatingRemainder(dividingBy:1)
        runTime=runPhase*Float(runInfo.frameCount)/runInfo.fps
        if touching || petBlend>0.01{petTime+=dt}
        func sample(_ t:Float,_ info:ClipInfo,loop:Bool=true)->(UInt32,UInt32,Float){
            let f=loop ? t*info.fps:min(t*info.fps,Float(info.frameCount-1))
            let a=Int(f)%info.frameCount,b=loop ? (a+1)%info.frameCount:min(a+1,info.frameCount-1)
            return(UInt32(a),UInt32(b),f-floor(f))
        }
        let a=sample(idleTime,idleInfo),b=sample(runTime,runInfo),w=sample(walkTime,walkInfo),p=sample(reactionTime,reactionInfo,loop:reactionLoops)
        uniforms.clipCounts.w=UInt32(reactionInfo.frameCount)
        uniforms.frames=SIMD4(a.0,a.1,b.0,b.1);uniforms.animation.x=a.2;uniforms.animation.y=b.2
        uniforms.otherFrames=SIMD4(w.0,w.1,p.0,p.1);uniforms.gait=SIMD4(w.2,p.2,runFraction,petBlend)
        uniforms.clock=SIMD4(elapsed,dt,movingBlend,Float(count));uniforms.root=SIMD4(motion.position.x,motion.position.y,motion.yaw,0)
        let centre=worldPalm ?? SIMD2(uniforms.touch.x,uniforms.touch.y)
        uniforms.touch=SIMD4(centre.x,centre.y,touching ? petBlend:0,max(0.65,radius+0.38))
        let turn=atan2(sin(motion.yaw-previousYaw),cos(motion.yaw-previousYaw))/max(dt,0.001)
        uniforms.effects=SIMD4(min(1,speed/max(motion.maxSpeed,0.1)),pettingDuration,min(4,max(-4,turn)),reactionLoops ? 0:1)
        previousYaw=motion.yaw
        if !pawSampleIndices.isEmpty {
            let paw=pawSampleIndices.reduce(SIMD3<Float>.zero){$0+pose($1)}/Float(pawSampleIndices.count)
            if screenHighFive.contactCount != oldScreenContact {screenFlashPoint=SIMD2(paw.x,paw.y)}
            if !screenOwned {highFive.observeContact(paw:SIMD2(paw.x,paw.y),palm:worldPalm,radius:min(0.34,max(0.20,radius*0.65)),fresh:freshPalm,near:proximity.near,timestamp:handTimestamp)}
        }
        if praiseAge<0.7 {
            let forward:Float=cos(motion.yaw)>=0 ? 1:-1
            praisePoint=mousePetSit.ownsSit ? SIMD2(mouthPosition.x,mouthPosition.y+0.18):motion.position+SIMD2(forward*motion.noseReach*0.65,motion.noseHeight+0.25)
        }
        uniforms.praise=SIMD4(praisePoint.x,praisePoint.y,praiseAge,praiseAge<3.6 ? 1:0)
        let screenFlash=screenHighFive.contactAge<1.2
        uniforms.highFiveTouch=screenFlash ? SIMD4(screenFlashPoint.x,screenFlashPoint.y,screenHighFive.contactAge,1):SIMD4(highFive.flashPoint.x,highFive.flashPoint.y,highFive.flashAge,highFive.flashAge<1.2 ? 1:0)
        let visibility:Float=backgroundEnabled && background != nil && !homeMode ? 1:0
        backgroundVisibility+=(visibility-backgroundVisibility)*(1-exp(-dt*9))
        if abs(backgroundVisibility-visibility)<0.001{backgroundVisibility=visibility}
        let quiet:Float=touching || highFive.active || voiceActions.active || screenOwned || circleOwned || screenHighFiveQueued ? 1:0
        backgroundQuiet+=(quiet-backgroundQuiet)*(1-exp(-dt*4))
        backgroundTime+=dt*(1-backgroundQuiet*0.75)
        let backgroundAspect=uniforms.viewport.x/max(1,uniforms.viewport.y)
        let backgroundCrop=backgroundAspect>1.6 ? SIMD2<Float>(1,1.6/backgroundAspect):SIMD2<Float>(backgroundAspect/1.6,1)
        background?.setInteraction(point:(pointer ?? palm).map{(SIMD2($0.x,1-$0.y)-SIMD2(repeating:0.5))*backgroundCrop+SIMD2(repeating:0.5)})
        background?.update(dt:dt,quiet:backgroundQuiet)
        uniforms.background=SIMD4(backgroundVisibility*min(1,max(0,backgroundStrength)),backgroundQuiet,backgroundTime,background?.daylight ?? 0)
        fetchGame.attach(to:mouthPosition,dt:dt)
        uniforms.ball=SIMD4(fetchGame.ball.x,fetchGame.ball.y,fetchGame.ball.z,fetchGame.radius)
        uniforms.ballInfo=SIMD4(fetchGame.visible && !homeMode ? 1:0,fetchGame.spin,fetchGame.ground,0)
        if handThrow.active && !homeMode && !fetchGame.active {
            let p=world(handThrow.center)
            uniforms.ball=SIMD4(p.x,max(motion.position.y+ballRadius,p.y),0.1,ballRadius)
            uniforms.ballInfo=SIMD4(1,elapsed*0.6,motion.position.y,0)
        }
        trailVertices=lightTrail.vertices(worldPerPixel:uniforms.viewport.z/max(1,uniforms.viewport.x))
        if homeMode {
            // Original standing idle, including breath and ears; no pursuit,
            // petting or microphone/camera source is active on the home page.
            uniforms.clock.z=0;uniforms.gait.w=0;uniforms.touch.z=0
            uniforms.root=SIMD4(0,-1.55,-0.30,0)
            uniforms.presentation=SIMD4(1,0,0,0)
            uniforms.background.x=0
        }
        uniforms.presentation.z=ambientParticleScale
    }
    var highFivePointerLabel:String? {
        if screenHighFive.contactAge<0.9{return "High five!"}
        if screenHighFive.active || screenHighFiveQueued{return "Coming closer"}
        if highFive.flashAge<0.9{return "High five!"}
        if highFive.phase == .approaching{return "Hold your palm steady"}
        if highFive.usesClip{return "Paw up"}
        if proximity.near{return "Pull back to try again"}
        if proximity.approaching{return "Coming closer"}
        if proximity.ready{return "Push toward the camera"}
        return nil
    }
    var highFiveHint:String? {
        if let hint=screenHighFive.hint{return hint}
        if screenHighFiveQueued{return "Ready for a high five"}
        if highFive.flashAge<0.9{return "High five! Pull back to try again."}
        if highFive.phase == .approaching{return "Coming closer · Hold your palm still"}
        if highFive.usesClip{return "Paw up · Hold your palm still"}
        if proximity.near{return "Pull back, then push toward the camera"}
        if proximity.approaching{return "Keep moving closer for a high five"}
        if intent == .palm && !handHolding {
            return proximity.ready ? "Push for a high five · Move your palm onto the dog to pet":"Face your palm toward the camera and hold briefly"
        }
        return nil
    }
    private func smooth(_ lo:Float,_ hi:Float,_ x:Float)->Float {let t=min(1,max(0,(x-lo)/(hi-lo)));return t*t*(3-2*t)}
    /// Replace complete corresponding animation caches together on the main thread.
    func applyMorphology(_ baked:BakedMorphology)throws {
        func buffer(_ data:Data)throws->MTLBuffer {
            guard !data.isEmpty,let b=data.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:data.count,options:.storageModeShared)}) else{throw NSError(domain:"Morphology buffer",code:1)};return b
        }
        var loaded:[String:(MTLBuffer,MTLBuffer,ClipInfo)]=[:]
        for name in ["idle","run","walk","pet","highfive","sit_enter","sit_hold","sit_exit","shake","happy","screen_highfive","fetch_pickup"]{
            guard let c=baked.clips[name],c.positions.count==count*c.frameCount*12,c.normals.count==c.positions.count else{throw NSError(domain:"Missing morphology clip: \(name)",code:1)}
            loaded[name]=(try buffer(c.positions),try buffer(c.normals),ClipInfo(name:name,file:"",normalsFile:"",frameCount:c.frameCount,fps:c.fps,duration:c.duration,loop:c.loop))
        }
        if let clip=baked.clips["screen_highfive"] {
            screenPoseHeight=0;screenPoseForward=0
            clip.positions.withUnsafeBytes { bytes in
                let values=bytes.bindMemory(to:Float.self)
                for at in stride(from:0,to:values.count,by:3){screenPoseHeight=max(screenPoseHeight,values[at+1]);screenPoseForward=max(screenPoseForward,values[at])}
            }
        }
        voiceClips=Dictionary(uniqueKeysWithValues:["sit_enter","sit_hold","sit_exit","shake","happy","screen_highfive","fetch_pickup"].map{($0,loaded[$0]!)})
        cancelVoiceActions()
        if runningCircle.active{runningCircle.cancel(immediately:true);motion.position=runningCircle.position;motion.yaw=runningCircle.yaw;motion.velocity = .zero}
        if screenHighFive.active {screenHighFive.cancel(immediately:true);motion.position=screenHighFive.position;motion.yaw=screenHighFive.yaw;motion.velocity = .zero}
        uniforms.presentation=SIMD4(1,0,0,0)
        let a=loaded["idle"]!,b=loaded["run"]!,w=loaded["walk"]!,p=loaded["pet"]!
        idle=a.0;normals=a.1;idleInfo=a.2;run=b.0;runNormals=b.1;runInfo=b.2
        walk=w.0;walkNormals=w.1;walkInfo=w.2;pet=p.0;petNormals=p.1;petInfo=p.2
        let h=loaded["highfive"]!;highfive=h.0;highfiveNormals=h.1;highfiveInfo=h.2
        highFive.cancel(immediately:true);proximityTracker.reset();proximity=HandProximityState();pendingHighFiveTrigger=nil
        highFivePaw=baked.pawContactMean["highfive"] ?? SIMD3(1.522,2.050,0.441)
        pawSampleIndices=baked.pawSampleIndices.filter{$0>=0 && $0<count}
        noseSampleIndices=baked.noseSampleIndices.filter{$0>=0 && $0<count}
        fetchNoseContact=baked.fetchNoseContact
        ballRadius=min(0.14,max(0.075,(baked.noseMean["idle"]?.y ?? 2.33)*0.05))
        handThrow.cancel();fetchGame.reset();fetchReactionSelected=false
        petBlend=0;touching=false;contactDuration=0
        lightTrail.reset();trailVertices=[]
        morphology=baked.parameters
        let breed=morphology.breed ?? .shiba
        if let surface=breedSurfaces[breed],let samples=breedSeeds[breed] {
            (surfaceRanges,surfaceCoefficients,surfaceIndices,surfaceVertices,surfaceVertexCount,surfaceIndexCount)=surface
            seeds=samples
        }
        memset(states.contents(),0,states.length)
        let nose=baked.noseMean["idle"] ?? SIMD3<Float>(1.86,2.33,0)
        motion.setMorphology(noseHeight:nose.y,noseReach:abs(nose.x)*cos(0.22),horizontalRadius:max(abs(baked.boundsMin.x),abs(baked.boundsMax.x))+0.15,height:baked.boundsMax.y+0.12,strideLength:1.45*breed.motionScale*morphology.sizeScale*(morphology.bodyLength*0.4+morphology.legLength*0.6),maxSpeed:3.4)
        idleTime=0;walkTime=0;runTime=0;petTime=0;gaitPhase=0;gaitLanding.reset();movingBlend=0;runStopWeight=nil;runStopTime=0
        uniforms.clipCounts=SIMD4(UInt32(idleInfo.frameCount),UInt32(runInfo.frameCount),UInt32(walkInfo.frameCount),UInt32(petInfo.frameCount))
        uniforms.frames = .zero;uniforms.otherFrames = .zero
    }
    func applyPalette(_ palette:DogCoatPalette){
        var values=[SIMD4<Float>](repeating:SIMD4(1,0.6,0.3,1),count:count)
        let source=seeds.contents().bindMemory(to:SIMD4<Float>.self,capacity:count)
        func linear(_ c:Float)->Float{let x=min(1,max(0,c));return x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4)}
        func glow(_ c:PhotoRGB)->SIMD3<Float>{let v=SIMD3(linear(c.red),linear(c.green),linear(c.blue));return SIMD3(repeating:0.08)+v*0.92}
        for i in 0..<count{
            let region=Int(source[i].z+0.5),material=Int(source[i].w+0.5)
            let c:PhotoRGB=material==1 ? palette.accent:([palette.body,palette.head,palette.legs,palette.tail][min(3,max(0,region))])
            var rgb=glow(c)
            if material==2{rgb=SIMD3(0.08,0.06,0.045)}
            if material==3{rgb=SIMD3(0.80,0.78,0.70)}
            if material==4{rgb=SIMD3(1.0,0.94,0.78)}
            if palette.fromPhoto != true,let breed=morphology.breed,let texture=coatColors[breed] {
                let original=texture.contents().bindMemory(to:SIMD4<Float>.self,capacity:count)[i].xyz
                let tint=glow(c)
                rgb=material == 0 ? original*tint:original
            }
            values[i]=SIMD4(rgb,1)
        }
        colors=values.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}
    }
    func emissionStats()->(active:Int,maximum:Float){let v=states.contents().bindMemory(to:Float.self,capacity:count*8);var n=0,m:Float=0;for i in 0..<count{let strength=v[i*8+7];if strength>0.01{n+=1};m=max(m,strength)};return(n,m)}
    func draw(in view:MTKView){
        let now=CACurrentMediaTime(),dt=Float(now-lastTime);lastTime=now
        drawAttempts+=1
        guard !paused else{drawPaused+=1;return}
        // WindowServer can mark a shown window occluded (including during
        // launch/capture). Only actual hiding or minimization pauses playback.
        guard let window=view.window,window.isVisible,!window.isMiniaturized,!NSApp.isHidden else{drawOccluded+=1;return}
        guard let drawable=view.currentDrawable else{drawNoDrawable+=1;return}
        semaphore.wait();update(dt:dt,size:view.drawableSize)
        let cb=encode(texture:drawable.texture);cb.present(drawable)
        let sem=semaphore;cb.addCompletedHandler{[weak self] b in
            let ms=(b.gpuEndTime-b.gpuStartTime)*1000,error=b.error?.localizedDescription
            DispatchQueue.main.async{if let self=self{if self.gpuTimes.count<3600{self.gpuTimes.append(ms)};if let e=error{self.metalErrors.append(e)}}};sem.signal()
        }
        cb.commit();frames+=1;onFrame?()
    }
    func encode(texture:MTLTexture)->MTLCommandBuffer{
        if scene?.width != texture.width || scene?.height != texture.height{
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:texture.width,height:texture.height,mipmapped:false);d.usage=[.renderTarget,.shaderRead];d.storageMode = .private;scene=device.makeTexture(descriptor:d)
            let z=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:texture.width,height:texture.height,mipmapped:false);z.usage=[.renderTarget,.shaderRead];z.storageMode = .private;surfaceDepth=device.makeTexture(descriptor:z)
            let b=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:max(1,texture.width/4),height:max(1,texture.height/4),mipmapped:false);b.usage=[.shaderRead,.shaderWrite];b.storageMode = .private;small=device.makeTexture(descriptor:b);blurred=device.makeTexture(descriptor:b)
        }
        var u=uniforms;let cb=queue.makeCommandBuffer()!
        let preview=homeMode ? homeIdle:nil
        // Bind matching preview geometry, surface and coat together. Every clip
        // slot uses idle because shader mixes still read the zero-weight slots.
        let idle=preview?.positions ?? self.idle,run=preview?.positions ?? self.run
        let walk=preview?.positions ?? self.walk,reactionBuffer=preview?.positions ?? self.reactionBuffer
        let normals=preview?.normals ?? self.normals,runNormals=preview?.normals ?? self.runNormals
        let walkNormals=preview?.normals ?? self.walkNormals,reactionNormals=preview?.normals ?? self.reactionNormals
        let seeds=preview != nil ? breedSeeds[.dalmatian]!:self.seeds
        let colors=preview != nil ? coatColors[.dalmatian]!:self.colors
        let surface=preview != nil ? breedSurfaces[.dalmatian]:nil
        let surfaceRanges=surface?.0 ?? self.surfaceRanges,surfaceCoefficients=surface?.1 ?? self.surfaceCoefficients
        let surfaceIndices=surface?.2 ?? self.surfaceIndices,surfaceVertices=surface?.3 ?? self.surfaceVertices
        let surfaceVertexCount=surface?.4 ?? self.surfaceVertexCount,surfaceIndexCount=surface?.5 ?? self.surfaceIndexCount
        if let preview {
            let f=idleTime*preview.info.fps,a=UInt32(Int(f)%preview.info.frameCount),b=(a+1)%UInt32(preview.info.frameCount)
            u.frames=SIMD4(a,b,a,b);u.otherFrames=SIMD4(a,b,a,b)
            u.animation.x=f-floor(f);u.animation.y=u.animation.x
            u.gait=SIMD4(u.animation.x,u.animation.x,0,0)
            u.clipCounts=SIMD4(repeating:UInt32(preview.info.frameCount))
            u.effects = .zero;u.praise.w=0;u.highFiveTouch.w=0
        }
        let ce=cb.makeComputeCommandEncoder()!;ce.setComputePipelineState(compute);ce.setBuffer(idle,offset:0,index:0);ce.setBuffer(run,offset:0,index:1);ce.setBuffer(states,offset:0,index:2);ce.setBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:3);ce.setBuffer(seeds,offset:0,index:4);ce.setBuffer(walk,offset:0,index:8);ce.setBuffer(reactionBuffer,offset:0,index:10);ce.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1));ce.endEncoding()
        let geometry=cb.makeComputeCommandEncoder()!;geometry.setComputePipelineState(reconstructDepth)
        geometry.setBuffer(idle,offset:0,index:0);geometry.setBuffer(run,offset:0,index:1);geometry.setBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:3)
        geometry.setBuffer(walk,offset:0,index:8);geometry.setBuffer(reactionBuffer,offset:0,index:10)
        geometry.setBuffer(surfaceRanges,offset:0,index:12);geometry.setBuffer(surfaceCoefficients,offset:0,index:13);geometry.setBuffer(surfaceVertices,offset:0,index:14)
        geometry.dispatchThreads(MTLSize(width:surfaceVertexCount,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:128,height:1,depth:1));geometry.endEncoding()
        let depthPass=MTLRenderPassDescriptor();depthPass.depthAttachment.texture=surfaceDepth;depthPass.depthAttachment.loadAction = .clear;depthPass.depthAttachment.storeAction = .store;depthPass.depthAttachment.clearDepth=1
        let depthEncoder=cb.makeRenderCommandEncoder(descriptor:depthPass)!;depthEncoder.setRenderPipelineState(surfacePipeline);depthEncoder.setDepthStencilState(surfaceDepthState)
        depthEncoder.setVertexBuffer(surfaceVertices,offset:0,index:0);depthEncoder.setVertexBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:3)
        depthEncoder.drawIndexedPrimitives(type:.triangle,indexCount:surfaceIndexCount,indexType:.uint32,indexBuffer:surfaceIndices,indexBufferOffset:0);depthEncoder.endEncoding()
        if u.background.x>0,let background {background.encode(cb,depth:surfaceDepth!,uniforms:u)}
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=scene;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
        let re=cb.makeRenderCommandEncoder(descriptor:pass)!;re.setRenderPipelineState(points);re.setFragmentTexture(surfaceDepth,index:0);re.setVertexBuffer(idle,offset:0,index:0);re.setVertexBuffer(run,offset:0,index:1);re.setVertexBuffer(states,offset:0,index:2);re.setVertexBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:3);re.setVertexBuffer(seeds,offset:0,index:4);re.setVertexBuffer(colors,offset:0,index:5);re.setVertexBuffer(normals,offset:0,index:6);re.setVertexBuffer(runNormals,offset:0,index:7);re.setVertexBuffer(walk,offset:0,index:8);re.setVertexBuffer(walkNormals,offset:0,index:9);re.setVertexBuffer(reactionBuffer,offset:0,index:10);re.setVertexBuffer(reactionNormals,offset:0,index:11);re.drawPrimitives(type:.point,vertexStart:0,vertexCount:count*8)
        re.setRenderPipelineState(fur);re.setFragmentBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:3)
        re.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:count)
        if !trailVertices.isEmpty,let buffer=trailVertices.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) {
            re.setRenderPipelineState(trailPipeline);re.setVertexBuffer(buffer,offset:0,index:0);re.setVertexBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:3)
            re.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:trailVertices.count)
        }
        if u.ballInfo.x>0 {
            re.setRenderPipelineState(ballPipeline);re.setVertexBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:3);re.setFragmentBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:3)
            re.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:2)
        }
        re.endEncoding()
        let de=cb.makeComputeCommandEncoder()!;de.setComputePipelineState(down);de.setTexture(scene,index:0);de.setTexture(small,index:1);de.dispatchThreads(MTLSize(width:small!.width,height:small!.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));de.endEncoding();blur.encode(commandBuffer:cb,sourceTexture:small!,destinationTexture:blurred!)
        let out=MTLRenderPassDescriptor();out.colorAttachments[0].texture=texture;out.colorAttachments[0].loadAction = .dontCare;out.colorAttachments[0].storeAction = .store
        let post=cb.makeRenderCommandEncoder(descriptor:out)!;post.setRenderPipelineState(finish);post.setFragmentTexture(scene,index:0);post.setFragmentTexture(blurred,index:1)
        let showBackground=u.background.x>0 && background != nil
        post.setFragmentTexture(showBackground ? background!.scene:emptyBackground,index:2)
        post.setFragmentTexture(showBackground ? background!.particles:emptyBackground,index:3)
        post.setFragmentTexture(surfaceDepth,index:4)
        post.setFragmentTexture(showBackground ? background!.softMask:emptyBackground,index:5)
        post.setFragmentBytes(&u,length:MemoryLayout<PupUniforms>.stride,index:0);post.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);post.endEncoding();return cb
    }
    func displacement()->(Float,Float,Bool){let p=states.contents().bindMemory(to:Float.self,capacity:count*8);var maxD:Float=0,sum:Float=0,finite=true
        for i in 0..<count{let d=simd_length(SIMD3(p[i*8],p[i*8+1],p[i*8+2]));maxD=max(maxD,d);sum+=d;finite=finite && d.isFinite};return(maxD,sum/Float(count),finite)}
    func savePNG(_ t:MTLTexture,to url:URL)throws{let n=t.width*t.height*4;var bytes=[UInt8](repeating:0,count:n);t.getBytes(&bytes,bytesPerRow:t.width*4,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0);for i in stride(from:0,to:n,by:4){bytes.swapAt(i,i+2)};let p=CGDataProvider(data:Data(bytes) as CFData)!;let cg=CGImage(width:t.width,height:t.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:t.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:p,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!;try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:url)}
}
