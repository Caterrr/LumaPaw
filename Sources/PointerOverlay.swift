import Cocoa

final class PointerOverlay:NSView{
    var throwCenter:SIMD2<Float>?,throwProgress:Float=0,throwReady=false,throwTravel:Float=0
    var pointingLabel="Point to lead";var interactionLabel:String?;var locations:[SIMD2<Float>]=[];var touching=false;var active=false;var palm=false;var holding=false;var palmRadius:CGFloat=30
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    override func draw(_ rect:NSRect){
        if let p=throwCenter {
            let c=NSPoint(x:CGFloat(p.x)*bounds.width,y:CGFloat(p.y)*bounds.height),radius:CGFloat=27
            let tint=throwReady ? NSColor(calibratedRed:0.76,green:1,blue:0.64,alpha:0.95):NSColor(white:1,alpha:0.8)
            NSColor(white:1,alpha:0.14).setStroke()
            let base=NSBezierPath(ovalIn:NSRect(x:c.x-radius,y:c.y-radius,width:radius*2,height:radius*2));base.lineWidth=2;base.stroke()
            let arc=NSBezierPath();arc.appendArc(withCenter:c,radius:radius,startAngle:90,endAngle:90-CGFloat(throwProgress)*360,clockwise:true);arc.lineWidth=2;tint.setStroke();arc.stroke()
            let symbol="hand.raised.fingers.slash"
            if let image=LumaStyle.symbol(symbol,"Hold your fist for 1 second")?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[tint])) {image.isTemplate=false;image.draw(in:NSRect(x:c.x-9,y:c.y-radius-24,width:18,height:18),from:.zero,operation:.sourceOver,fraction:0.9)}
            return
        }
        // Mouse and hand movement use only the renderer's 0.15-second white
        // swipe line. Keep the deliberate fist-throw progress feedback above.
    }
}
