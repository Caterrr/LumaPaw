import Cocoa

/// A quiet, opaque introduction. The containing controller owns native full-screen
/// transitions; this view owns only its scrolling, typography and dismissal.
final class IntroView:NSView {
    struct Passage {
        let text:String
        var fontSize:CGFloat=13
    }
    static let passages:[Passage]=[
        .init(text:"Presented by Cater",fontSize:24),
        .init(text:"Can interactive art bring people and pets closer together? This project begins with an intimate, everyday experience: the bond between people and pets often takes shape beyond words. An approach, a gesture, or a moment of waiting can become a way of understanding one another."),
        .init(text:"I use flowing light and particles to form a pet’s body, allowing it to change in response to human movement and interaction. Its outline gathers and disperses, giving companionship a delicate, shifting form. Through these interactions, I hope to draw attention to details we often overlook: how we express care and how we sense another living being’s response."),
        .init(text:"Companionship takes shape in these moments of response and waiting. Approaching, touching, and lingering evoke changes in light, colour, and motion, while the pet’s movements and gaze become subtle ripples on the screen. Interaction unfolds through observation and feedback, without relying on explicit commands. The screen becomes a record of shared moments, inviting us to notice the lives beside us."),
        .init(text:"To my friends Mia, Holger, and Cyan — thank you for sharing this hackathon experience with me. Different teams, shared memories.")
    ]
    var onExit:(()->Void)?,onExplore:(()->Void)?
    private(set) var scrollOffset:CGFloat=0
    private(set) var manualVelocity:CGFloat=0
    private(set) var closeVisibility:CGFloat=0
    private(set) var isRunning=false
    let closeButton=NSButton()
    let exploreButton=AboutExploreButton(frame:.zero)
    private var scrollActivity:CGFloat=0,time:CGFloat=0
    var textWidth:CGFloat {min(920,max(180,bounds.width-128))}
    private func passageHeight(_ passage:Passage)->CGFloat {
        attributedPassage(passage,alpha:1).boundingRect(with:NSSize(width:textWidth,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading]).height
    }
    private var passageCenters:[CGFloat] {
        var centers:[CGFloat]=[],lastHeight:CGFloat=0,last:CGFloat=0
        for (i,p) in Self.passages.enumerated(){
            let h=passageHeight(p),gap:CGFloat=58
            let y=i==0 ? bounds.height*0.28:last+lastHeight/2+h/2+gap
            centers.append(y);last=y;lastHeight=h
        }
        return centers
    }
    private var exploreWidth:CGFloat {min(480,textWidth*0.70)}
    private var exploreHeight:CGFloat {exploreWidth*0.51+34}
    private var exploreTop:CGFloat {(passageCenters.last ?? 0)+passageHeight(Self.passages.last!)/2+30}
    // Rest at the final card so readers have time to enter the shared memory.
    var maximumScroll:CGFloat {max(0,exploreTop+exploreHeight-bounds.height*0.82)}
    var autoSpeed:CGFloat {14}
    override var isOpaque:Bool{true}
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{true}
    override init(frame:NSRect){
        super.init(frame:frame)
        autoresizingMask=[.width,.height]
        wantsLayer=true;layer?.backgroundColor=NSColor.black.cgColor
        closeButton.image=LumaStyle.symbol("xmark","Close About")
        closeButton.isBordered=false;closeButton.focusRingType = .none
        closeButton.contentTintColor=NSColor(white:0.76,alpha:1)
        closeButton.target=self;closeButton.action=#selector(closeIntro)
        closeButton.setAccessibilityIdentifier("intro-exit")
        closeButton.setAccessibilityLabel("Close About")
        closeButton.toolTip="Close About"
        closeButton.isHidden=true
        addSubview(closeButton)
        exploreButton.target=self;exploreButton.action=#selector(explore)
        exploreButton.setAccessibilityIdentifier("about-explore")
        exploreButton.setAccessibilityLabel("Explore our hackathon memory")
        exploreButton.toolTip="Explore Barnet 3"
        exploreButton.isHidden=true;addSubview(exploreButton)
        setAccessibilityElement(false)
        setAccessibilityLabel("LumaPaw information")
        setAccessibilityHelp("Scroll up or down to move through the introduction. Press Escape to exit.")
        isHidden=true
    }
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
    override func layout(){
        super.layout()
        closeButton.frame=NSRect(x:max(10,bounds.width-54),y:18,width:36,height:36)
        updateExplore()
        needsDisplay=true
    }
    /// Starts from the first passage each time. The root controller calls this
    /// after adding the view and can call it again to replay from the home page.
    func begin(){
        scrollOffset=0;manualVelocity=0;scrollActivity=0;closeVisibility=0
        time=0;isRunning=true;isHidden=false
        closeVisibility=1;closeButton.isHidden=false;closeButton.alphaValue=1
        updateExplore()
        window?.makeFirstResponder(self);needsDisplay=true
    }
    func finish(){
        guard isRunning else{return}
        isRunning=false;isHidden=true;manualVelocity=0;scrollActivity=0
        closeVisibility=0;closeButton.isHidden=true
        exploreButton.isHidden=true
        onExit?()
    }
    @objc private func closeIntro(){finish()}
    @objc private func explore(){guard isRunning else{return};manualVelocity=0;onExplore?()}
    func showLastPassage(){scrollOffset=maximumScroll;manualVelocity=0;updateExplore();needsDisplay=true}
    private func updateExplore(){
        let y=exploreTop-scrollOffset
        exploreButton.frame=NSRect(x:(bounds.width-exploreWidth)/2,y:y,width:exploreWidth,height:exploreHeight)
        let alpha=min(1,time/1.8)*max(0,min(1,(bounds.height-y)/90))*max(0,min(1,(y+exploreHeight)/70))
        exploreButton.alphaValue=alpha
        exploreButton.isHidden = !isRunning || alpha<0.01
        exploreButton.isEnabled=alpha>0.3
    }
    override func keyDown(with event:NSEvent){
        switch event.keyCode {
        case 53:finish()
        case 125:scroll(by:-5,precise:false)
        case 126:scroll(by:5,precise:false)
        case 121:scroll(by:-22,precise:false)
        case 116:scroll(by:22,precise:false)
        case 119:showLastPassage()
        case 115:scrollOffset=0;manualVelocity=0;updateExplore();needsDisplay=true
        case 36 where exploreButton.isEnabled && exploreButton.frame.maxY<=bounds.height:explore()
        default:super.keyDown(with:event)
        }
    }
    override func scrollWheel(with event:NSEvent){
        scroll(by:event.scrollingDeltaY,precise:event.hasPreciseScrollingDeltas)
    }
    /// Positive native wheel deltas move up; negative deltas move down.
    /// Direct displacement makes contact feel immediate, with a damped impulse
    /// continuing that movement smoothly between the incoming wheel events.
    func scroll(by deltaY:CGFloat,precise:Bool=true){
        guard isRunning,abs(deltaY)>0.001 else{return}
        let delta=deltaY*(precise ? 1:15)
        manualVelocity=max(-bounds.height*2.2,min(bounds.height*2.2,manualVelocity-delta*19))
        scrollOffset=max(0,min(maximumScroll,scrollOffset-delta*0.32))
        scrollActivity=0.70
        closeVisibility=max(closeVisibility,0.26)
        closeButton.isHidden=false;closeButton.alphaValue=closeVisibility
        updateExplore()
        needsDisplay=true
    }
    func advance(dt:Float){
        guard isRunning,!isHidden else{return}
        let dt=CGFloat(min(1/30,max(0,dt)))
        time+=dt;scrollActivity=max(0,scrollActivity-dt)
        manualVelocity *= exp(-dt*3.2)
        // A short pause in the automatic drift lets an upward gesture settle.
        let automatic=scrollActivity>0 ? 0:autoSpeed
        scrollOffset=max(0,min(maximumScroll,scrollOffset+(automatic+manualVelocity)*dt))
        if scrollOffset<=0 && manualVelocity<0 {manualVelocity=0}
        if scrollOffset>=maximumScroll && manualVelocity>0 {manualVelocity=0}
        // Dismissal must remain discoverable even while automatic scrolling rests.
        closeVisibility=1;closeButton.alphaValue=1;closeButton.isHidden=false
        updateExplore();exploreButton.advance(dt:dt)
        needsDisplay=true
    }
    private func attributedPassage(_ passage:Passage,alpha:CGFloat)->NSAttributedString {
        let paragraph=NSMutableParagraphStyle()
        paragraph.alignment = .center;paragraph.lineSpacing=7
        let fontSize=passage.fontSize
        return NSAttributedString(string:passage.text,attributes:[
            .font:LumaStyle.font(fontSize,light:true),.kern:fontSize*0.012,
            .foregroundColor:LumaStyle.ink.withAlphaComponent(alpha),.paragraphStyle:paragraph
        ])
    }
    override func draw(_ dirtyRect:NSRect){
        NSColor.black.setFill();bounds.fill()
        guard isRunning else{return}
        let width=textWidth
        let centers=passageCenters
        let entry=min(1,time/1.8)
        for (index,passage) in Self.passages.enumerated() {
            let center=centers[index]-scrollOffset
            // Fade gently into and out of the darkness near the screen edges.
            let distance=abs(center-bounds.midY)/max(1,bounds.height*0.59)
            let edge=max(0,min(1,(1-distance)*2.0))
            let alpha=edge*entry
            guard alpha>0.003 else{continue}
            let text=attributedPassage(passage,alpha:0.90*alpha)
            let rect=text.boundingRect(with:NSSize(width:width,height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading])
            let drawingRect=NSRect(x:(bounds.width-width)/2,y:center-rect.height/2,width:width,height:rect.height+4)
            NSGraphicsContext.saveGraphicsState()
            let shadow=NSShadow();shadow.shadowOffset = .zero
            shadow.shadowBlurRadius=13
            shadow.shadowColor=NSColor(calibratedRed:0.95,green:0.91,blue:0.80,alpha:0.28*alpha)
            shadow.set()
            text.draw(with:drawingRect,options:[.usesLineFragmentOrigin,.usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// An actual scene preview follows the dedication; it opens the free camera.
final class AboutExploreButton:NSButton {
    var preview=NSImage(contentsOf:Bundle.main.url(forResource:"barnet_explorer_preview",withExtension:"png") ?? URL(fileURLWithPath:"/missing"))
    private var tracking:NSTrackingArea?,inside=false,hover:CGFloat=0
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{true}
    override init(frame:NSRect){super.init(frame:frame);isBordered=false;focusRingType = .none}
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
    override func accessibilityPerformPress()->Bool{
        guard isEnabled,let action else{return false}
        return sendAction(action,to:target)
    }
    override func keyDown(with event:NSEvent){
        if event.keyCode==36 || event.keyCode==49{performClick(nil)}else{super.keyDown(with:event)}
    }
    override func updateTrackingAreas(){
        super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)}
        let area=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        tracking=area;addTrackingArea(area)
    }
    override func mouseEntered(with event:NSEvent){inside=true}
    override func mouseExited(with event:NSEvent){inside=false}
    func advance(dt:CGFloat){hover=inside ? min(1,hover+dt/0.7):max(0,hover-dt/0.85);needsDisplay=true}
    override func draw(_ dirtyRect:NSRect){
        let rect=NSRect(x:1,y:1,width:bounds.width-2,height:bounds.height-35)
        NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6).addClip()
        preview?.draw(in:rect,from:.zero,operation:.sourceOver,fraction:0.72+hover*0.22,respectFlipped:true,hints:nil)
        NSGraphicsContext.restoreGraphicsState()
        let border=NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6);border.lineWidth=0.6
        LumaStyle.ink.withAlphaComponent(0.15+hover*0.25).setStroke();border.stroke()
        let label=NSAttributedString(string:"Explore this moment  ↗",attributes:[.font:LumaStyle.font(12,light:true),.kern:0.6,.foregroundColor:LumaStyle.ink.withAlphaComponent(0.68+hover*0.25)])
        let size=label.size();label.draw(in:NSRect(x:(bounds.width-size.width)/2,y:bounds.height-23,width:size.width,height:22))
    }
}
