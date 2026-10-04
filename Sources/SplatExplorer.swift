import Cocoa
import MetalKit
import simd

struct ExplorerSettings:Decodable {
 let name:String,eye:[Float],yaw:Float,pitch:Float,moveSpeed:Float,boundsMin:[Float],boundsMax:[Float]
}
struct ExplorerUniforms {
 var right:SIMD4<Float>,down:SIMD4<Float>,forward:SIMD4<Float>,eye:SIMD4<Float>,camera:SIMD4<Float>
}
/// Keeps the original world-space covariance. Camera changes reproject and
/// re-sort the complete scan; this is not a fixed background or an image panorama.
final class SplatExplorerRenderer:NSObject,MTKViewDelegate {
 let device:MTLDevice,queue:MTLCommandQueue,source:MTLBuffer,projected:MTLBuffer,order:MTLBuffer
 let pipeline:MTLRenderPipelineState,project:MTLComputePipelineState,settings:ExplorerSettings
 let count:Int
 private let positions:[SIMD3<Float>]
 private var indices:[UInt32],scratch:[UInt32],keys:[UInt32]
 private var previousTime=0.0,dirty=true
 var eye:SIMD3<Float>,yaw:Float,pitch:Float
 var held=Set<UInt16>(),boost=false
 var onError:((String)->Void)?
 var forward:SIMD3<Float>{SIMD3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))}
 var right:SIMD3<Float>{SIMD3(cos(yaw),0,-sin(yaw))}
 init(resources:URL)throws {
  guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else{throw NSError(domain:"Metal is unavailable",code:1)}
  device=d;queue=q
  settings=try JSONDecoder().decode(ExplorerSettings.self,from:Data(contentsOf:resources.appendingPathComponent("barnet_explorer.json")))
  eye=SIMD3(settings.eye[0],settings.eye[1],settings.eye[2]);yaw=settings.yaw;pitch=settings.pitch
  let data=try Data(contentsOf:resources.appendingPathComponent("barnet_explorer.bin"),options:.mappedIfSafe)
  guard !data.isEmpty,data.count%80==0,data.withUnsafeBytes({$0.bindMemory(to:Float.self).allSatisfy{$0.isFinite}}) else{throw NSError(domain:"Invalid exploration scan",code:2)}
  let n=data.count/80;count=n
  source=data.withUnsafeBytes{d.makeBuffer(bytes:$0.baseAddress!,length:data.count,options:.storageModeShared)!}
  projected=d.makeBuffer(length:count*48,options:.storageModePrivate)!
  order=d.makeBuffer(length:count*4,options:.storageModeShared)!
  positions=data.withUnsafeBytes{raw in let f=raw.bindMemory(to:Float.self);return (0..<n).map{SIMD3(f[$0*20],f[$0*20+1],f[$0*20+2])}}
  indices=(0..<count).map{UInt32($0)};scratch=indices;keys=[UInt32](repeating:0,count:count)
  let lib=try d.makeLibrary(source:String(contentsOf:resources.appendingPathComponent("Explorer.metal"),encoding:.utf8),options:nil)
  project=try d.makeComputePipelineState(function:lib.makeFunction(name:"exploreProject")!)
  let desc=MTLRenderPipelineDescriptor();desc.vertexFunction=lib.makeFunction(name:"exploreVertex");desc.fragmentFunction=lib.makeFunction(name:"exploreFragment")
  let c=desc.colorAttachments[0]!;c.pixelFormat = .bgra8Unorm_srgb;c.isBlendingEnabled=true;c.sourceRGBBlendFactor = .one;c.destinationRGBBlendFactor = .oneMinusSourceAlpha;c.sourceAlphaBlendFactor = .one;c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
  pipeline=try d.makeRenderPipelineState(descriptor:desc);super.init()
 }
 func reset(){eye=SIMD3(settings.eye[0],settings.eye[1],settings.eye[2]);yaw=settings.yaw;pitch=settings.pitch;held.removeAll();dirty=true}
 func look(dx:Float,dy:Float){yaw+=dx*0.004;pitch=min(1.45,max(-1.45,pitch+dy*0.004));dirty=true}
 func move(_ delta:SIMD3<Float>){
  eye+=delta
  eye=simd_clamp(eye,SIMD3(settings.boundsMin[0],settings.boundsMin[1],settings.boundsMin[2]),SIMD3(settings.boundsMax[0],settings.boundsMax[1],settings.boundsMax[2]));dirty=true
 }
 func advance(dt:Float){
  var v=SIMD3<Float>.zero
  if held.contains(13){v+=forward};if held.contains(1){v-=forward}
  if held.contains(0){v-=right};if held.contains(2){v+=right}
  if held.contains(12){v.y+=1};if held.contains(14){v.y-=1}
  if simd_length_squared(v)>0{move(simd_normalize(v)*settings.moveSpeed*min(dt,0.05)*(boost ? 3:1))}
 }
 private func sort(){
  let f=forward
  for i in 0..<count{let z=max(0,simd_dot(positions[i]-eye,f));keys[i] = ~z.bitPattern;indices[i]=UInt32(i)}
  // Stable radix passes retain the most significant 24 depth bits. Linear work
  // avoids an O(n log n) comparison sort for every mouse movement.
  for shift in [UInt32(8),16,24]{
   var bins=[Int](repeating:0,count:256)
   for i in indices{bins[Int((keys[Int(i)]>>shift)&255)]+=1}
   var sum=0;for b in 0..<256{let n=bins[b];bins[b]=sum;sum+=n}
   for i in indices{let b=Int((keys[Int(i)]>>shift)&255);scratch[bins[b]]=i;bins[b]+=1}
   swap(&indices,&scratch)
  }
  _ = indices.withUnsafeBytes{memcpy(order.contents(),$0.baseAddress!,count*4)}
 }
 func encode(to texture:MTLTexture)->MTLCommandBuffer {
  sort()
  let width=Float(texture.width),height=Float(texture.height),focal=height*0.85
  let down=simd_cross(forward,right)
  var u=ExplorerUniforms(right:SIMD4(right,0),down:SIMD4(down,0),forward:SIMD4(forward,0),eye:SIMD4(eye,1),camera:SIMD4(width,height,focal,Float(count)))
  let cb=queue.makeCommandBuffer()!,ce=cb.makeComputeCommandEncoder()!
  ce.setComputePipelineState(project);ce.setBuffer(source,offset:0,index:0);ce.setBuffer(projected,offset:0,index:1);ce.setBytes(&u,length:MemoryLayout<ExplorerUniforms>.stride,index:2)
  ce.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1));ce.endEncoding()
  let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
  let re=cb.makeRenderCommandEncoder(descriptor:pass)!;re.setRenderPipelineState(pipeline);re.setVertexBuffer(projected,offset:0,index:0);re.setVertexBuffer(order,offset:0,index:1);re.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:count);re.endEncoding();return cb
 }
 func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){dirty=true}
 func draw(in view:MTKView){
  let now=CACurrentMediaTime();advance(dt:Float(previousTime==0 ? 0:now-previousTime));previousTime=now
  guard dirty,let drawable=view.currentDrawable else{return}
  dirty=false;let cb=encode(to:drawable.texture);cb.present(drawable);cb.commit()
  // A single frame owns shared projection/sort buffers until GPU completion.
  cb.waitUntilCompleted();if let error=cb.error{onError?(error.localizedDescription)}
 }
 func invalidate(){dirty=true}
}

final class ExplorerView:MTKView {
 var explorer:SplatExplorerRenderer!,onClose:(()->Void)?
 override var acceptsFirstResponder:Bool{true}
 override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self)}
 override func mouseDragged(with event:NSEvent){explorer.look(dx:Float(event.deltaX),dy:Float(event.deltaY))}
 override func rightMouseDown(with event:NSEvent){window?.makeFirstResponder(self)}
 override func rightMouseDragged(with event:NSEvent){explorer.move(explorer.right*(-Float(event.deltaX)*0.003)+SIMD3(0,-Float(event.deltaY)*0.003,0))}
 override func scrollWheel(with event:NSEvent){let scale:Float=event.hasPreciseScrollingDeltas ? 0.008:0.08;explorer.move(explorer.forward*Float(event.scrollingDeltaY)*scale)}
 override func keyDown(with event:NSEvent){
  if event.keyCode==53{onClose?()}else if event.keyCode==15{explorer.reset()}else if [0,1,2,12,13,14].contains(event.keyCode){explorer.held.insert(event.keyCode)}else{super.keyDown(with:event)}
 }
 override func keyUp(with event:NSEvent){explorer.held.remove(event.keyCode)}
 override func flagsChanged(with event:NSEvent){explorer.boost=event.modifierFlags.contains(.shift)}
}

final class SplatExplorerWindow:NSWindowController,NSWindowDelegate {
 let renderer:SplatExplorerRenderer,view:ExplorerView
 var onClose:(()->Void)?
 private let help=NSTextField(labelWithString:"Drag to look · WASD to move · Q / E down / up\nScroll to move · Shift for speed · R to reset · Esc to return")
 private var finished=false
 init(resources:URL)throws {
  renderer=try SplatExplorerRenderer(resources:resources)
  view=ExplorerView(frame:NSRect(x:0,y:0,width:1120,height:760),device:renderer.device)
  let window=NSWindow(contentRect:view.bounds,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  window.title="Barnet 3 · Explore";window.backgroundColor = .black;window.minSize=NSSize(width:640,height:440);window.contentView=view;window.isReleasedWhenClosed=false
  window.collectionBehavior.insert(.fullScreenAuxiliary)
  super.init(window:window);window.delegate=self
  view.explorer=renderer;view.delegate=renderer;view.colorPixelFormat = .bgra8Unorm_srgb;view.framebufferOnly=false;view.preferredFramesPerSecond=60
  view.onClose={[weak self]in self?.close()};renderer.onError={[weak self]message in self?.help.stringValue="Unable to render this view. Press R to reset. \(message)"}
  func button(_ symbol:String,_ label:String,_ action:Selector,x:CGFloat){
   let b=NSButton(image:LumaStyle.symbol(symbol,label)!,target:self,action:action);b.isBordered=false;b.contentTintColor = .white;b.wantsLayer=true;b.layer?.backgroundColor=NSColor.black.withAlphaComponent(0.65).cgColor;b.layer?.cornerRadius=10;b.frame=NSRect(x:x,y:20,width:40,height:40);b.autoresizingMask=[.maxYMargin];b.toolTip=label;b.setAccessibilityLabel(label);view.addSubview(b)
  }
  button("arrow.left","Return to About",#selector(returnHome),x:20)
  button("arrow.counterclockwise","Reset view",#selector(resetView),x:70)
  button("questionmark","Explorer controls",#selector(toggleHelp),x:120)
  help.frame=NSRect(x:180,y:20,width:780,height:46);help.font=LumaStyle.font(12);help.textColor = .white;help.maximumNumberOfLines=2;help.wantsLayer=true;help.layer?.backgroundColor=NSColor.black.withAlphaComponent(0.6).cgColor;help.autoresizingMask=[.width,.maxYMargin];view.addSubview(help)
  window.center()
 }
 required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
 func present(){showWindow(nil);window?.makeKeyAndOrderFront(nil);window?.makeFirstResponder(view);renderer.invalidate()}
 @objc private func returnHome(){close()}
 @objc private func resetView(){renderer.reset();window?.makeFirstResponder(view)}
 @objc private func toggleHelp(){help.isHidden.toggle();window?.makeFirstResponder(view)}
 func windowDidResignKey(_ notification:Notification){renderer.held.removeAll();renderer.boost=false;view.isPaused=true}
 func windowDidBecomeKey(_ notification:Notification){view.isPaused=false;renderer.invalidate()}
 func windowWillClose(_ notification:Notification){view.isPaused=true;renderer.held.removeAll();if !finished{finished=true;onClose?()}}
}
