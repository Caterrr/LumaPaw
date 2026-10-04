import Cocoa

struct VoiceSettings:Codable {
    var petName="Luma"
    var previousPetName:String?
    var volume:Float=0.5
    var muted=false
    static func cleanedName(_ proposed:String)->String? {
        let name=proposed.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=20,
              !["sit","sit down","spin","turn around","high five","shake","come","come here","good boy","good girl","good dog","well done"].contains(name.lowercased()),
              name.unicodeScalars.contains(where:{CharacterSet.letters.contains($0)}),
              name.unicodeScalars.allSatisfy({$0.isASCII && (CharacterSet.alphanumerics.contains($0) || " -'".unicodeScalars.contains($0))}) else{return nil}
        return name
    }
}

final class VoicePanel:NSPanel {
    var onName:((String)->Bool)?,onToggleListening:(()->Void)?,onMute:((Bool)->Void)?,onVolume:((Float)->Void)?
    private let nameField=NSTextField(),listen=NSButton(),mute=NSButton(checkboxWithTitle:"Mute",target:nil,action:nil)
    private let volume=NSSlider(value:0.5,minValue:0,maxValue:1,target:nil,action:nil)
    private let statusLabel=NSTextField(wrappingLabelWithString:"Voice is off"),transcript=NSTextField(wrappingLabelWithString:""),feedback=NSTextField(labelWithString:"")
    init(){
        super.init(contentRect:NSRect(x:0,y:0,width:390,height:482),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        title="Name & sound";appearance=NSAppearance(named:.darkAqua);isReleasedWhenClosed=false;backgroundColor=NSColor(white:0.07,alpha:1)
        let view=NSView(frame:NSRect(x:0,y:0,width:390,height:482));contentView=view
        func label(_ text:String,_ y:CGFloat,_ size:CGFloat=12,_ color:CGFloat=0.65)->NSTextField {
            let l=NSTextField(labelWithString:text);l.font = LumaStyle.font(size);l.textColor=NSColor(white:color,alpha:1);l.frame=NSRect(x:24,y:y,width:342,height:23);view.addSubview(l);return l
        }
        _=label("A name to come home to",433,17,0.94)
        nameField.frame=NSRect(x:24,y:394,width:256,height:30);nameField.placeholderString="e.g. Luma or Coco";nameField.font = LumaStyle.font(15);nameField.target=self;nameField.action=#selector(saveName);nameField.setAccessibilityLabel("Dog's name");view.addSubview(nameField)
        let save=NSButton(title:"Save",target:self,action:#selector(saveName));save.frame=NSRect(x:290,y:393,width:76,height:32);save.bezelStyle = .rounded;view.addSubview(save)
        feedback.frame=NSRect(x:24,y:365,width:342,height:22);feedback.font = LumaStyle.font(11);feedback.textColor = .systemOrange;view.addSubview(feedback)
        _=label("Say their name, or say “Come here”.",336)
        _=label("“Sit” · “Spin” · “High five” · “Good boy”",312)
        listen.frame=NSRect(x:24,y:266,width:342,height:34);listen.bezelStyle = .rounded;listen.title="Use voice control";listen.target=self;listen.action=#selector(toggleListening);view.addSubview(listen)
        statusLabel.frame=NSRect(x:24,y:220,width:342,height:38);statusLabel.font = LumaStyle.font(11);statusLabel.textColor=NSColor(white:0.67,alpha:1);view.addSubview(statusLabel)
        transcript.frame=NSRect(x:24,y:180,width:342,height:36);transcript.font = LumaStyle.font(12);transcript.textColor=NSColor(white:0.87,alpha:1);view.addSubview(transcript)
        mute.frame=NSRect(x:24,y:142,width:74,height:24);mute.target=self;mute.action=#selector(muteChanged);view.addSubview(mute)
        volume.frame=NSRect(x:108,y:142,width:258,height:24);volume.target=self;volume.action=#selector(volumeChanged);volume.isContinuous=true;volume.setAccessibilityLabel("Sound volume");view.addSubview(volume)
        _=label("Soft breathing. Speech stays on this Mac.",112,11)
        _=label("Choose one control mode at a time.",81,11)
        _=label("Sound works with every control mode.",49,11)
        _=label("The microphone is off until you choose Voice.",10,10)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
    func configure(_ settings:VoiceSettings){nameField.stringValue=settings.petName;volume.floatValue=settings.volume;mute.state=settings.muted ? .on:.off}
    func updateStatus(_ text:String,transcript line:String,listening:Bool){statusLabel.stringValue=text;transcript.stringValue=line.isEmpty ? "":("Heard: "+line);listen.title=listening ? "Use mouse control":"Use voice control";listen.setAccessibilityLabel(listen.title)}
    @objc private func saveName(){guard let name=VoiceSettings.cleanedName(nameField.stringValue) else{feedback.stringValue="Use a short English name, different from a command.";return};if onName?(name)==true{nameField.stringValue=name;feedback.stringValue="You can call me \(name)."}}
    @objc private func toggleListening(){onToggleListening?()}
    @objc private func muteChanged(){onMute?(mute.state == .on)}
    @objc private func volumeChanged(){onVolume?(volume.floatValue)}
}
