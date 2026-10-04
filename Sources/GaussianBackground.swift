import Foundation
import MetalKit
import MetalPerformanceShaders
import simd

private struct BarnetUniforms {
    var clock=SIMD4<Float>(0,0.55,0,1)
    var transition=SIMD4<Float>(0,0,0,0)
    var camera=SIMD4<Float>(1600,1000,930,0)
    var interaction=SIMD4<Float>(0.5,0.5,0.35,0.38)
}

/// Native 3D Gaussian environment. Every visible frame projects the original
/// covariance from animated centres, then composites the environment and
/// detached, depth-sorted ellipses. AQ and Barnet share the scene catalog.
final class GaussianBackground {
    private struct View {
        let gaussians:MTLBuffer,projected:MTLBuffer,motes:MTLBuffer
        let count:Int,moteCount:Int
        let focal:Float,depthSeeds:[SIMD2<Float>]
        let daylight:Float
    }
    private let views:[View]
    let viewNames:[String]
    private struct Catalog:Decodable {let views:[Entry];let defaultView:String?}
    private struct Entry:Decodable {let name:String,file:String,motes:String;let focalPixels:Float;var daylight:Bool? = nil}
    private(set) var currentViewIndex=0
    private(set) var transitionProgress:Float=1
    var transitionActive:Bool {transitionTarget != nil}
    var dynamicStrength:Float=0.55 {
        didSet {if !dynamicStrength.isFinite{dynamicStrength=0.55}else{dynamicStrength=min(1,max(0,dynamicStrength))}}
    }
    var daylight:Float {
        let start=views[currentViewIndex].daylight
        guard let target=transitionTarget else{return start}
        let t=transitionProgress*transitionProgress*(3-2*transitionProgress)
        return start+(views[target].daylight-start)*t
    }
    var count:Int{views[currentViewIndex].count}
    var moteCount:Int{views[currentViewIndex].moteCount}
    var gaussians:MTLBuffer{views[currentViewIndex].gaussians}
    var motes:MTLBuffer{views[currentViewIndex].motes}
    let splatPipeline:MTLRenderPipelineState,motePipeline:MTLRenderPipelineState
    let maskPipeline:MTLComputePipelineState,projectPipeline:MTLComputePipelineState,mixPipeline:MTLComputePipelineState
    let maskBlur:MPSImageGaussianBlur
    private(set) var scene:MTLTexture
    let particles:MTLTexture
    private var oldScene:MTLTexture,newScene:MTLTexture
    private let qualityLock=NSLock()
    private var qualityLevel=0,pendingQuality=0,expensiveFrames=0,comfortableFrames=0
    var renderScale:Float{Float(scene.width)/1280}
    var mask:MTLTexture?,softMask:MTLTexture?
    private var time:Float=0,quiet:Float=0,smoothedStrength:Float=0.55
    private var interactionPoint:SIMD2<Float>?,fieldCentre=SIMD2<Float>(0.5,0.5),fieldPressure:Float=0.35
    func setInteraction(point:SIMD2<Float>?){interactionPoint=point}
    var fieldPosition:SIMD2<Float>{fieldCentre}
    private var transitionTarget:Int?,queuedView:Int?
    private let transitionDuration:Float=2.1
    // Retained for callers that previously reported cache/render statistics.
    // Static image caching is intentionally gone: cacheRenders stays zero.
    private(set) var cacheRenders=0,dynamicRenders=0

    init(device:MTLDevice,library:MTLLibrary,resources:URL)throws {
        let shaderURL=resources.appendingPathComponent("Background.metal")
        let bgLibrary=try device.makeLibrary(source:String(contentsOf:shaderURL,encoding:.utf8),options:nil)
        func load(_ name:String)throws->(MTLBuffer,Int){
            let data=try Data(contentsOf:resources.appendingPathComponent(name),options:.mappedIfSafe)
            guard !data.isEmpty,data.count%80==0,
                  data.withUnsafeBytes({$0.bindMemory(to:Float.self).allSatisfy{$0.isFinite}}),
                  let buffer=data.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)})
            else{throw NSError(domain:"Invalid 3D Gaussian background asset: \(name)",code:1)}
            return(buffer,data.count/80)
        }
        let entries: [Entry]
        var defaultView:String?
        if let data=try? Data(contentsOf:resources.appendingPathComponent("background_scenes.json")) {
            let catalog=try JSONDecoder().decode(Catalog.self,from:data);entries=catalog.views;defaultView=catalog.defaultView
        } else {
            entries=[Entry(name:"Forest",file:"barnet_view0.bin",motes:"barnet_view0_motes.bin",focalPixels:930)]
        }
        guard !entries.isEmpty else{throw NSError(domain:"No background scenes",code:1)}
        viewNames=entries.map(\.name)
        views=try entries.map{entry in
            let (g,c)=try load(entry.file)
            // A representative subset of the actual source ellipses supplies
            // foreground flakes, regardless of older sparse mote assets.
            let values=g.contents().bindMemory(to:Float.self,capacity:c*20)
            let total=min(entry.daylight == true ? 160:3600,c),step=Float(c)/Float(total)
            var particles=[Float]();particles.reserveCapacity(total*20)
            var depthSeeds=[SIMD2<Float>]();depthSeeds.reserveCapacity(total)
            for i in 0..<total {
                let at=min(c-1,Int((Float(i)+0.5)*step))*20
                particles.append(contentsOf:UnsafeBufferPointer(start:values+at,count:20))
                depthSeeds.append(SIMD2(values[at+2],values[at+3]))
            }
            let m=particles.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}
            guard let p=device.makeBuffer(length:c*48,options:.storageModePrivate) else{throw NSError(domain:"Background allocation",code:2)}
            return View(gaussians:g,projected:p,motes:m,count:c,moteCount:total,focal:entry.focalPixels,depthSeeds:depthSeeds,daylight:entry.daylight == true ? 1:0)
        }
        currentViewIndex=entries.firstIndex{$0.file==defaultView} ?? (views.count>2 ? 2:0)
        func pipeline(_ vertex:String,_ fragment:String,additive:Bool)throws->MTLRenderPipelineState {
            let p=MTLRenderPipelineDescriptor();p.vertexFunction=bgLibrary.makeFunction(name:vertex);p.fragmentFunction=bgLibrary.makeFunction(name:fragment)
            let c=p.colorAttachments[0]!;c.pixelFormat = .rgba16Float;c.isBlendingEnabled=true
            c.sourceRGBBlendFactor = .one;c.destinationRGBBlendFactor = additive ? .one:.oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one;c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor:p)
        }
        func compute(_ name:String)throws->MTLComputePipelineState{
            guard let f=bgLibrary.makeFunction(name:name) else{throw NSError(domain:"Missing background kernel: \(name)",code:3)}
            return try device.makeComputePipelineState(function:f)
        }
        splatPipeline=try pipeline("barnetSplatVertex","barnetSplatFragment",additive:false)
        motePipeline=try pipeline("barnetMoteVertex","barnetMoteFragment",additive:false)
        maskPipeline=try compute("barnetDogMask");projectPipeline=try compute("barnetProject");mixPipeline=try compute("barnetMix")
        maskBlur=MPSImageGaussianBlur(device:device,sigma:7);maskBlur.edgeMode = .clamp
        func texture(_ width:Int,_ height:Int)->MTLTexture{
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
            d.storageMode = .private;d.usage=[.renderTarget,.shaderRead,.shaderWrite];return device.makeTexture(descriptor:d)!
        }
        scene=texture(1280,800);oldScene=texture(1280,800);newScene=texture(1280,800);particles=texture(1280,800)
    }

    /// A selection made during a transition is queued, avoiding a cut or a reset
    /// in the middle of a wave. Choosing the arriving view clears a queued return.
    func selectView(_ index:Int){
        guard views.indices.contains(index) else{return}
        if let target=transitionTarget{queuedView=index==target ? nil:index;return}
        guard index != currentViewIndex else{return}
        transitionTarget=index;transitionProgress=0
    }
    func update(dt:Float,quiet:Float){
        guard dt.isFinite,dt>=0 else{return}
        let step=min(dt,0.1)
        self.quiet=quiet.isFinite ? min(1,max(0,quiet)):0
        smoothedStrength+=(dynamicStrength-smoothedStrength)*(1-exp(-step*5))
        if abs(smoothedStrength-dynamicStrength)<0.0001{smoothedStrength=dynamicStrength}
        time+=step*(1-self.quiet*0.25)
        let target=interactionPoint ?? SIMD2(0.5+sin(time*0.24)*0.28,0.5+cos(time*0.19)*0.16)
        let distance=simd_length(target-fieldCentre)
        fieldCentre+=(target-fieldCentre)*(1-exp(-step*4.5))
        let pressure:Float=interactionPoint == nil ? 0.35:min(1,0.55+distance*4)
        fieldPressure+=(pressure-fieldPressure)*(1-exp(-step*6))
        if let target=transitionTarget {
            transitionProgress=min(1,transitionProgress+step/transitionDuration)
            if transitionProgress>=1 {
                currentViewIndex=target;transitionTarget=nil
                if let next=queuedView{queuedView=nil;selectView(next)}
            }
        }
    }
    private func uniforms(for index:Int,incoming:Bool)->BarnetUniforms{
        var u=BarnetUniforms();u.clock=SIMD4(time,smoothedStrength,quiet,transitionProgress)
        u.transition=SIMD4(transitionActive ? 1:0,incoming ? 1:0,Float(views[index].count),0)
        u.camera.z=views[index].focal;u.camera.w=views[index].daylight;u.interaction=SIMD4(fieldCentre.x,fieldCentre.y,fieldPressure,0.38);return u
    }
    private func trackFrameCost(_ milliseconds:Double){
        guard milliseconds.isFinite,milliseconds>0 else{return}
        qualityLock.lock();defer{qualityLock.unlock()}
        expensiveFrames=milliseconds>16.2 ? expensiveFrames+1:0
        comfortableFrames=milliseconds<10.5 ? comfortableFrames+1:0
        // Prioritize the dog when the full command buffer repeatedly misses its
        // 60 Hz budget. Long hysteresis prevents fluctuating scene sharpness.
        if expensiveFrames>=45{pendingQuality=min(2,pendingQuality+1);expensiveFrames=0}
        if comfortableFrames>=600{pendingQuality=max(0,pendingQuality-1);comfortableFrames=0}
    }
    private func applyPendingQuality(device:MTLDevice){
        qualityLock.lock();let desired=pendingQuality;qualityLock.unlock()
        guard desired != qualityLevel else{return}
        let dimensions=[(1280,800),(1024,640),(800,500)],size=dimensions[desired]
        func texture()->MTLTexture{
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:size.0,height:size.1,mipmapped:false)
            d.storageMode = .private;d.usage=[.renderTarget,.shaderRead,.shaderWrite];return device.makeTexture(descriptor:d)!
        }
        scene=texture();oldScene=texture();newScene=texture();qualityLevel=desired
    }
    func encode(_ cb:MTLCommandBuffer,depth:MTLTexture,uniforms:PupUniforms){
        applyPendingQuality(device:cb.device)
        cb.addCompletedHandler{[weak self] buffer in
            self?.trackFrameCost((buffer.gpuEndTime-buffer.gpuStartTime)*1000)
        }
        func renderView(_ index:Int,to target:MTLTexture,incoming:Bool){
            let view=views[index];var u=self.uniforms(for:index,incoming:incoming)
            let ce=cb.makeComputeCommandEncoder()!;ce.label="Project moving Barnet 3D covariance"
            ce.setComputePipelineState(projectPipeline);ce.setBuffer(view.gaussians,offset:0,index:0);ce.setBuffer(view.projected,offset:0,index:1)
            ce.setBytes(&u,length:MemoryLayout<BarnetUniforms>.stride,index:2)
            ce.dispatchThreads(MTLSize(width:view.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1));ce.endEncoding()
            let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=target;p.colorAttachments[0].loadAction = .clear
            p.colorAttachments[0].storeAction = .store;p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
            let re=cb.makeRenderCommandEncoder(descriptor:p)!;re.label="Depth-sorted moving Barnet Gaussians"
            re.setRenderPipelineState(splatPipeline);re.setVertexBuffer(view.projected,offset:0,index:0)
            re.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:view.count);re.endEncoding()
        }
        if let next=transitionTarget {
            renderView(currentViewIndex,to:oldScene,incoming:false);renderView(next,to:newScene,incoming:true)
            var weight=transitionProgress
            let ce=cb.makeComputeCommandEncoder()!;ce.label="Smooth Barnet view transition"
            ce.setComputePipelineState(mixPipeline);ce.setTexture(oldScene,index:0);ce.setTexture(newScene,index:1);ce.setTexture(scene,index:2)
            ce.setBytes(&weight,length:MemoryLayout<Float>.size,index:0)
            ce.dispatchThreads(MTLSize(width:scene.width,height:scene.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));ce.endEncoding()
        }else{renderView(currentViewIndex,to:scene,incoming:false)}
        let w=max(1,depth.width/4),h=max(1,depth.height/4)
        if mask?.width != w || mask?.height != h {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r16Float,width:w,height:h,mipmapped:false)
            d.storageMode = .private;d.usage=[.shaderRead,.shaderWrite]
            mask=cb.device.makeTexture(descriptor:d);softMask=cb.device.makeTexture(descriptor:d)
        }
        let e=cb.makeComputeCommandEncoder()!;e.setComputePipelineState(maskPipeline)
        e.setTexture(depth,index:0);e.setTexture(mask,index:1)
        e.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));e.endEncoding()
        maskBlur.encode(commandBuffer:cb,sourceTexture:mask!,destinationTexture:softMask!)
        let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=particles;p.colorAttachments[0].loadAction = .clear
        p.colorAttachments[0].storeAction = .store;p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        let re=cb.makeRenderCommandEncoder(descriptor:p)!;re.label="Depth-sorted detached Gaussian ellipses";re.setRenderPipelineState(motePipeline)
        for (index,incoming) in [(currentViewIndex,false)]+(transitionTarget.map{[($0,true)]} ?? []){
            var u=self.uniforms(for:index,incoming:incoming);let view=views[index]
            if view.daylight > 0.5 {continue} // Ground grass never detaches into floating debris.
            // Sorting only the detached population avoids re-sorting hundreds
            // of thousands of stable architectural splats. New buffers are
            // retained by the command buffer, so in-flight frames never race.
            func ease(_ value:Float)->Float{let x=min(1,max(0,value));return x*x*x*(x*(x*6-15)+10)}
            let motion=sqrt(u.clock.y)*(1-u.clock.z*0.32),burst:Float=transitionActive ? pow(max(0,sin(transitionProgress * .pi)),0.72):0
            let depths=view.depthSeeds.map{pair -> Float in
                let phase=time*(0.095+pair.y*0.022)+pair.y*7.19,life=phase-floor(phase)
                let amount=max(ease(life/0.90)*motion,burst*0.98)
                return max(0.32,pair.x*(1-0.88*amount))
            }
            let order=(0..<view.moteCount).sorted{depths[$0]>depths[$1]}.map{UInt32($0)}
            let orderBuffer=order.withUnsafeBytes{cb.device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}
            re.setVertexBuffer(view.motes,offset:0,index:0);re.setVertexBuffer(orderBuffer,offset:0,index:1)
            re.setVertexBytes(&u,length:MemoryLayout<BarnetUniforms>.stride,index:2)
            re.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:view.moteCount)
        }
        re.endEncoding();dynamicRenders+=1
    }
}
