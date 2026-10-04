import Cocoa

/// A compact optional editor; the stage remains pure black while playing.
final class CustomizationPanel:NSPanel {
    var onImport:(()->Void)?
    var onChange:((MorphologyParameters)->Void)?
    var onReset:(()->Void)?
    private let photo=NSImageView(),note=NSTextField(wrappingLabelWithString:"")
    private let swatches=PhotoCoatSwatches(frame:.zero)
    private var sliders:[NSSlider]=[],values:[NSTextField]=[]
    private let ranges:[(Double,Double)]=[(0.45,2.4),(0.78,1.40),(0.60,1.32),(0.68,1.35),(0.82,1.24),(0.65,1.35),(0.70,1.55),(0,1)]
    private let names=["Size","Body length","Leg length","Body width","Head size","Muzzle length","Ear size","Ear droop"]
    init(){
        super.init(contentRect:NSRect(x:0,y:0,width:330,height:740),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
        title="Appearance";isFloatingPanel=true;hidesOnDeactivate=true;isReleasedWhenClosed=false
        appearance=NSAppearance(named:.darkAqua);backgroundColor=NSColor(white:0.07,alpha:1)
        let root=NSView(frame:NSRect(x:0,y:0,width:330,height:740));contentView=root
        photo.frame=NSRect(x:22,y:554,width:286,height:138);photo.imageScaling = .scaleProportionallyUpOrDown
        photo.wantsLayer=true;photo.layer?.backgroundColor=NSColor(white:0.12,alpha:1).cgColor;photo.layer?.cornerRadius=9;root.addSubview(photo)
        let importButton=NSButton(title:"Import a dog photo",target:self,action:#selector(importPhoto));importButton.bezelStyle = .rounded;importButton.frame=NSRect(x:22,y:703,width:286,height:28);root.addSubview(importButton)
        note.frame=NSRect(x:22,y:467,width:286,height:78);note.font = LumaStyle.font(11);note.textColor=NSColor(white:0.70,alpha:1);root.addSubview(note)
        swatches.frame=NSRect(x:22,y:438,width:286,height:24);root.addSubview(swatches)
        for i in names.indices{
            let y=CGFloat(400-i*42)
            let label=NSTextField(labelWithString:names[i]);label.frame=NSRect(x:22,y:y+12,width:100,height:18);label.font = LumaStyle.font(11);root.addSubview(label)
            let value=NSTextField(labelWithString:"");value.frame=NSRect(x:236,y:y+12,width:72,height:18);value.alignment = .right;value.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular);value.textColor = .secondaryLabelColor;root.addSubview(value);values.append(value)
            let slider=NSSlider(value:i==7 ? 0:1,minValue:ranges[i].0,maxValue:ranges[i].1,target:self,action:#selector(changed(_:)));slider.frame=NSRect(x:22,y:y-8,width:286,height:20);slider.tag=i;slider.isContinuous=true;slider.setAccessibilityLabel(names[i]);root.addSubview(slider);sliders.append(slider)
        }
        let caption=NSTextField(wrappingLabelWithString:"Size is an appearance estimate, not centimetres. Use the sliders to refine it. Photos stay on this Mac.");caption.frame=NSRect(x:22,y:42,width:286,height:49);caption.font = LumaStyle.font(10);caption.textColor = .secondaryLabelColor;root.addSubview(caption)
        let reset=NSButton(title:"Reset appearance",target:self,action:#selector(reset));reset.bezelStyle = .rounded;reset.frame=NSRect(x:22,y:8,width:138,height:28);root.addSubview(reset)
        let done=NSButton(title:"Done",target:self,action:#selector(done));done.bezelStyle = .rounded;done.frame=NSRect(x:232,y:8,width:76,height:28);root.addSubview(done)
    }
    func update(_ profile:DogPersonalization,image:NSImage?=nil){
        let p=profile.morphology
        let v=[p.sizeScale,p.bodyLength,p.legLength,p.bodyWidth,p.headSize,p.muzzleLength,p.earSize,p.earDroop]
        for i in sliders.indices{sliders[i].doubleValue=Double(v[i]);values[i].stringValue="\(Int(v[i]*100))%"}
        note.stringValue=profile.note
        swatches.samples=profile.coatSamples ?? [];swatches.needsDisplay=true
        if let image{photo.image=image}else if profile.photoFilename.isEmpty{photo.image=NSImage(systemSymbolName:"dog",accessibilityDescription:"Import dog photo")}
    }
    func setMessage(_ text:String){note.stringValue=text}
    @objc private func changed(_ sender:NSSlider){
        let v=sliders.map{Float($0.doubleValue)};for i in v.indices{values[i].stringValue="\(Int(v[i]*100))%"}
        onChange?(MorphologyParameters(bodyLength:v[1],legLength:v[2],headSize:v[4],muzzleLength:v[5],earSize:v[6],earDroop:v[7],bodyWidth:v[3],overallScale:v[0]).clamped())
    }
    @objc private func importPhoto(){onImport?()}
    @objc private func reset(){onReset?()}
    @objc private func done(){let host=parent;orderOut(nil);host?.makeKeyAndOrderFront(nil)}
}

final class PhotoCoatSwatches:NSView {
    var samples:[PhotoCoatSample]=[]
    override func draw(_ rect:NSRect){
        for (i,s) in samples.prefix(4).enumerated(){
            let x=CGFloat(i)*71,c=s.color
            NSColor(calibratedRed:CGFloat(c.red),green:CGFloat(c.green),blue:CGFloat(c.blue),alpha:1).setFill()
            let circle=NSBezierPath(ovalIn:NSRect(x:x,y:5,width:14,height:14));circle.fill();NSColor(white:1,alpha:0.35).setStroke();circle.lineWidth=0.6;circle.stroke()
            (s.name as NSString).draw(at:NSPoint(x:x+19,y:5),withAttributes:[.font:LumaStyle.font(10),.foregroundColor:NSColor(white:0.72,alpha:1)])
        }
        toolTip=samples.map{"\($0.name) · \(Int($0.share*100))%"}.joined(separator:"  ")
    }
}
