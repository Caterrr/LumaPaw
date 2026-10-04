import Cocoa
import simd

enum LumaStyle {
    static let brand="LumaPaw"
    static func font(_ size:CGFloat,light:Bool=false)->NSFont {
        NSFont(name:light ? "AvenirNext-UltraLight":"AvenirNext-Regular",size:size)
            ?? NSFont(name:"HelveticaNeue-Light",size:size) ?? .systemFont(ofSize:size,weight:light ? .ultraLight:.regular)
    }
    static let ink=NSColor(calibratedRed:0.92,green:0.91,blue:0.86,alpha:1)
    static func symbol(_ name:String,_ label:String)->NSImage? {
        NSImage(systemSymbolName:name,accessibilityDescription:label)?.withSymbolConfiguration(.init(pointSize:16,weight:.light))
    }
}

/// The letters are sampled into independent points. Pointer velocity creates a
/// local gust; a damped spring restores each point's own glyph position.
final class ParticleWordmark {
    struct Grain {
        var home:SIMD2<Float>,position:SIMD2<Float>,velocity:SIMD2<Float>
        let seed:Float,radius:CGFloat,opacity:CGFloat,drift:SIMD2<Float>
    }
    private(set) var grains:[Grain]=[]
    private(set) var textSize=CGSize.zero
    private(set) var wind:Float=0
    private var pointer:SIMD2<Float>?,pointerVelocity=SIMD2<Float>.zero
    private var lastEvent:Double=0,elapsed:Float=0
    private var gustDirection=SIMD2<Float>(0.92,0.39)
    func rebuild(fontSize:CGFloat){
        let font=LumaStyle.font(fontSize,light:true)
        let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:NSColor.white,.kern:fontSize*0.055]
        let text=NSAttributedString(string:LumaStyle.brand,attributes:attributes),size=text.size()
        let width=Int(ceil(size.width))+8,height=Int(ceil(size.height))+8
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32),let data=bitmap.bitmapData else{return}
        memset(data,0,width*height*4)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        text.draw(at:NSPoint(x:4,y:4));NSGraphicsContext.restoreGraphicsState()
        grains.removeAll(keepingCapacity:true)
        // Independent, jittered samples and uneven density avoid the old checkerboard.
        // Keep the random sequence stable during layout so resizing never flickers.
        var randomState:UInt64=0x4c756d61506177
        func random()->Float {
            randomState=randomState &* 6364136223846793005 &+ 1442695040888963407
            return Float((randomState >> 40) & 0xffffff)/Float(0xffffff)
        }
        for y in 0..<height {for x in 0..<width {
            let coverage=Float(data[y*width*4+x*4+3])/255
            guard coverage>0.06 else{continue}
            let density:Float=0.65+0.14*sin(Float(x)*0.045+Float(y)*0.091)
            guard random()<coverage*density else{continue}
            let seed=random(),jx=(random()-0.5)*1.6,jy=(random()-0.5)*1.6
            // Bitmap rows are top-to-bottom, while the view uses Cocoa's Y-up.
            let p=SIMD2(Float(x)+jx,Float(height-y)+jy)
            grains.append(Grain(home:p,position:p,velocity:.zero,seed:seed,
                radius:CGFloat(0.29+pow(random(),2.2)*0.65),
                opacity:CGFloat(0.40+random()*0.56),
                drift:SIMD2(0.2+random()*0.85,0.2+random()*0.75)))
            // A few loose motes soften the type's edge without obscuring the letters.
            if random()<0.085 {
                let angle=random()*Float.pi*2,distance:Float=2+random()*5
                let loose=p+SIMD2(cos(angle),sin(angle))*distance,phase=random()
                grains.append(Grain(home:loose,position:loose,velocity:.zero,seed:phase,
                    radius:CGFloat(0.30+random()*0.58),opacity:CGFloat(0.12+random()*0.19),
                    drift:SIMD2(0.8+random()*1.3,0.8+random()*1.2)))
            }
        }}
        textSize=CGSize(width:width,height:height);pointer=nil;pointerVelocity = .zero;wind=0;elapsed=0;lastEvent=0
    }
    func movePointer(to p:SIMD2<Float>,at timestamp:Double){
        if let previous=pointer, timestamp>lastEvent {
            let dt=Float(min(0.1,max(0.008,timestamp-lastEvent)))
            let velocity=(p-previous)/dt,speed=simd_length(velocity)
            pointerVelocity=simd_mix(pointerVelocity,velocity*min(1,480/max(1,speed)),SIMD2(repeating:0.28))
            if speed>35 {gustDirection=simd_normalize(gustDirection*0.72+velocity/max(1,speed)*0.28)}
        }else{pointerVelocity = .zero}
        pointer=p;lastEvent=timestamp
    }
    func leave(){pointer=nil;pointerVelocity = .zero}
    func advance(dt:Float){
        let dt=min(1/30,max(0,dt));elapsed+=dt
        wind+=((pointer == nil ? Float(0):1)-wind)*(1-exp(-dt*2.8))
        pointerVelocity *= exp(-dt*3.0)
        for i in grains.indices {
            var g=grains[i]
            let breath=SIMD2(sin(elapsed*0.48+g.seed*31),cos(elapsed*0.39+g.seed*47))*g.drift
            var reach:Float=0,flow=SIMD2<Float>.zero
            if let pointer {
                // Keep a gentle breeze alive while the pointer rests on the type.
                // Home-space influence carries motes beyond the cursor radius;
                // it avoids a rigid ring that immediately springs back inward.
                let delta=g.home-pointer,distance=simd_length(delta),radius:Float=120
                let falloff=max(0,1-distance/radius)
                reach=falloff*falloff*(3-2*falloff)*wind
                let phase=elapsed*(0.48+g.seed*0.25)+g.seed*32
                let angle=sin(phase)*0.72+sin(g.seed*73)*0.60
                let direction=SIMD2(gustDirection.x*cos(angle)-gustDirection.y*sin(angle),gustDirection.x*sin(angle)+gustDirection.y*cos(angle))
                let curl=SIMD2(-delta.y,delta.x)/max(34,distance)
                flow=direction*(190+g.seed*130)+curl*(65*sin(phase*0.7))+SIMD2(0,38)+pointerVelocity*0.65
            }
            let spring:Float=7.5*(1-reach)+0.85*reach
            var acceleration=(g.home+breath-g.position)*spring-g.velocity*(4.8-2.4*reach)
            acceleration+=flow*reach
            g.velocity+=acceleration*dt;g.position+=g.velocity*dt
            grains[i]=g
        }
    }
    var maximumDisplacement:Float {grains.map{simd_length($0.position-$0.home)}.max() ?? 0}
    func draw(at origin:NSPoint,time:Float){
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        context.saveGState();context.translateBy(x:origin.x,y:origin.y)
        context.setFillColor(NSColor(calibratedRed:0.93,green:0.88,blue:0.72,alpha:0.045).cgColor)
        for g in grains {let r=g.radius*2.6;context.addEllipse(in:CGRect(x:CGFloat(g.position.x)-r,y:CGFloat(g.position.y)-r,width:r*2,height:r*2))};context.fillPath()
        // Broad luminosity variation gives a cloud of light, not dots on graph paper.
        for band in 0..<7 {
            let alpha:CGFloat=0.18+CGFloat(band)*0.125
            context.setFillColor(LumaStyle.ink.withAlphaComponent(alpha).cgColor)
            for g in grains where min(6,max(0,Int((g.opacity-0.12)/0.13)))==band {
                let r=g.radius*(0.94+0.10*CGFloat(sin(time*(0.65+g.seed*0.3)+g.seed*31)))
                context.addEllipse(in:CGRect(x:CGFloat(g.position.x)-r,y:CGFloat(g.position.y)-r,width:r*2,height:r*2))
            };context.fillPath()
        }
        context.restoreGState()
    }
}

/// Slow eddies are drawn by HomeView so they aren't clipped to the button.
final class ParticleMenuButton:NSButton {
    struct Mote {var p:SIMD2<Float>;var v:SIMD2<Float>;var origin:SIMD2<Float>;var age:Float;var life:Float;var radius:CGFloat;var seed:Float}
    var primary=false
    private(set) var hover:CGFloat=0
    private(set) var motes:[Mote]=[]
    private var inside=false,tracking:NSTrackingArea?,emission:Float=0,elapsed:Float=0,randomState:UInt64=9173
    override var acceptsFirstResponder:Bool{true}
    override init(frame:NSRect){super.init(frame:frame);isBordered=false;focusRingType = .none}
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
    override func updateTrackingAreas(){
        super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)}
        let area=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil);tracking=area;addTrackingArea(area)
    }
    func setPointerInside(_ value:Bool){inside=value}
    override func mouseEntered(with event:NSEvent){setPointerInside(true)}
    override func mouseExited(with event:NSEvent){setPointerInside(false)}
    private func random()->Float{randomState=randomState &* 6364136223846793005 &+ 1;return Float((randomState>>40)&0xffffff)/Float(0xffffff)}
    private func emit(_ count:Int){
        let b=bounds.insetBy(dx:14,dy:10),w=Float(b.width),h=Float(b.height),perimeter=2*(w+h)
        guard perimeter>0 else{return}
        for _ in 0..<count where motes.count<220 {
            var t=random()*perimeter
            let p:SIMD2<Float>,n:SIMD2<Float>
            if t<w{p=SIMD2(Float(b.minX)+t,Float(b.minY));n=SIMD2(0,-1)}
            else if t<w+h{t-=w;p=SIMD2(Float(b.maxX),Float(b.minY)+t);n=SIMD2(1,0)}
            else if t<2*w+h{t-=w+h;p=SIMD2(Float(b.maxX)-t,Float(b.maxY));n=SIMD2(0,1)}
            else{t-=2*w+h;p=SIMD2(Float(b.minX),Float(b.maxY)-t);n=SIMD2(-1,0)}
            let tangent=SIMD2(-n.y,n.x),angle=(random()-0.5)*2.6
            let direction=n*cos(angle)+tangent*sin(angle)
            let v=direction*(12+random()*22)
            motes.append(Mote(p:p,v:v,origin:p,age:0,life:2.4+random()*1.9,radius:CGFloat(0.45+random()*0.90),seed:random()))
        }
    }
    func advance(dt raw:CGFloat){
        let dt=Float(min(0.05,max(0,raw))),active=inside || window?.firstResponder === self
        elapsed+=dt
        // Constant-rate opacity: no sudden burst on entry or jump on reversal.
        hover=active ? min(1,hover+CGFloat(dt)/0.70):max(0,hover-CGFloat(dt)/0.85)
        for i in motes.indices{
            var m=motes[i];m.age+=dt
            let phase=m.seed*Float.pi*2
            let flow=SIMD2(sin(m.p.y*0.025+elapsed*0.55+phase),cos(m.p.x*0.019-elapsed*0.43+phase))*10
            m.v+=(flow-m.v*0.36)*dt;m.p+=m.v*dt;motes[i]=m
        }
        motes.removeAll{$0.age >= $0.life}
        if hover>0.001{
            emission+=dt*54*Float(hover);let count=Int(emission);emission-=Float(count);emit(count)
        }else{emission=0}
        needsDisplay=true;superview?.needsDisplay=true
    }
    var maximumSpread:Float{motes.map{simd_distance($0.p,$0.origin)}.max() ?? 0}
    func drawParticles(at origin:NSPoint){
        guard let c=NSGraphicsContext.current?.cgContext else{return}
        c.saveGState();c.translateBy(x:origin.x,y:origin.y)
        for m in motes{
            let t=CGFloat(m.age/m.life),fadeIn=min(1,CGFloat(m.age)/0.55)
            let alpha=fadeIn*pow(1-t,1.3)*0.76,r=m.radius
            c.setFillColor(NSColor(calibratedRed:1,green:0.91,blue:0.72,alpha:alpha*0.10).cgColor)
            c.fillEllipse(in:CGRect(x:CGFloat(m.p.x)-r*3,y:CGFloat(m.p.y)-r*3,width:r*6,height:r*6))
            c.setFillColor(LumaStyle.ink.withAlphaComponent(alpha).cgColor)
            c.fillEllipse(in:CGRect(x:CGFloat(m.p.x)-r,y:CGFloat(m.p.y)-r,width:r*2,height:r*2))
        };c.restoreGState()
    }
    override func draw(_ dirtyRect:NSRect){
        let box=bounds.insetBy(dx:14,dy:10)
        NSColor(white:0.7,alpha:0.035*hover).setFill();NSBezierPath(rect:box).fill()
        let border=NSBezierPath(rect:box);border.lineWidth=0.7;LumaStyle.ink.withAlphaComponent(0.72*hover).setStroke();border.stroke()
        let attributes:[NSAttributedString.Key:Any]=[.font:LumaStyle.font(primary ? 16:12),.kern:primary ? 3.0:2.2,.foregroundColor:LumaStyle.ink.withAlphaComponent(primary ? 0.82+0.18*hover:0.48+0.45*hover)]
        let label=NSAttributedString(string:title,attributes:attributes),size=label.size()
        label.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2+1))
    }
}

final class HomeView:NSView {
    let wordmark=ParticleWordmark(),start=ParticleMenuButton(frame:.zero),info=ParticleMenuButton(frame:.zero)
    private var tracking:NSTrackingArea?,wordmarkOrigin=NSPoint.zero,fontSize:CGFloat=0,time:Float=0
    var onStart:(()->Void)?,onInfo:(()->Void)?
    override var acceptsFirstResponder:Bool{true}
    override var isOpaque:Bool{false}
    override init(frame:NSRect){
        super.init(frame:frame);autoresizingMask=[.width,.height]
        start.title="Start";start.primary=true;start.target=self;start.action=#selector(begin)
        start.setAccessibilityIdentifier("home-start");start.setAccessibilityLabel("Start")
        info.title="About";info.target=self;info.action=#selector(showInfo)
        info.setAccessibilityIdentifier("home-info");info.setAccessibilityLabel("About")
        addSubview(start);addSubview(info)
        setAccessibilityElement(false)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
    override func layout(){
        super.layout()
        let size=min(112,max(70,bounds.width*0.093))
        if abs(size-fontSize)>0.2 {fontSize=size;wordmark.rebuild(fontSize:size)}
        wordmarkOrigin=NSPoint(x:(bounds.width-wordmark.textSize.width)/2,y:bounds.height*0.795-wordmark.textSize.height*0.42)
        start.frame=NSRect(x:bounds.midX-104,y:max(96,bounds.height*0.15),width:208,height:66)
        info.frame=NSRect(x:bounds.midX-104,y:start.frame.minY-66,width:208,height:54)
    }
    override func updateTrackingAreas(){
        super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)}
        let area=NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil);tracking=area;addTrackingArea(area)
    }
    override func mouseMoved(with event:NSEvent){
        let p=convert(event.locationInWindow,from:nil)
        wordmark.movePointer(to:SIMD2(Float(p.x-wordmarkOrigin.x),Float(p.y-wordmarkOrigin.y)),at:event.timestamp)
    }
    override func mouseExited(with event:NSEvent){wordmark.leave()}
    override func keyDown(with event:NSEvent){
        if event.keyCode==36 {begin()}else{super.keyDown(with:event)}
    }
    func advance(dt:Float){guard !isHidden else{return};time+=dt;wordmark.advance(dt:dt);start.advance(dt:CGFloat(dt));info.advance(dt:CGFloat(dt));needsDisplay=true}
    override func draw(_ dirtyRect:NSRect){wordmark.draw(at:wordmarkOrigin,time:time);start.drawParticles(at:start.frame.origin);info.drawParticles(at:info.frame.origin)}
    @objc private func begin(){wordmark.leave();onStart?()}
    @objc private func showInfo(){wordmark.leave();onInfo?()}
}
