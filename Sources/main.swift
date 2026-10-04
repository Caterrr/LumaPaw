import Cocoa
import MetalKit
import UniformTypeIdentifiers

final class Stage:MTKView{
    weak var controller:AppController?
    var tracking:NSTrackingArea?
    override var acceptsFirstResponder:Bool{true}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let t=tracking{removeTrackingArea(t)};let t=NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil);tracking=t;addTrackingArea(t)}
    override func mouseMoved(with event:NSEvent){guard controller?.isHome == false,controller?.inputMode == .mouse else{return};let p=convert(event.locationInWindow,from:nil);let valid=p.y>132 && p.y<bounds.height-85;controller?.renderer.setMouse(valid ? SIMD2(Float(p.x/bounds.width),Float(p.y/bounds.height)):nil)}
    override func mouseDragged(with event:NSEvent){mouseMoved(with:event)}
    private func point(_ event:NSEvent)->SIMD2<Float>{let p=convert(event.locationInWindow,from:nil);return SIMD2(Float(p.x/bounds.width),Float(p.y/bounds.height))}
    override func mouseDown(with event:NSEvent){guard controller?.isHome == false,controller?.inputMode == .mouse else{return};controller?.renderer.setMousePetting(true,point:point(event))}
    override func mouseUp(with event:NSEvent){guard controller?.isHome == false,controller?.inputMode == .mouse else{return};controller?.renderer.setMousePetting(false,point:point(event))}
    override func mouseEntered(with event:NSEvent){mouseMoved(with:event)}
    override func mouseExited(with event:NSEvent){guard controller?.isHome == false,controller?.inputMode == .mouse else{return};controller?.renderer.setMouse(nil)}
    override func keyDown(with event:NSEvent){if event.keyCode==53{controller?.goHome(nil)}else if event.charactersIgnoringModifiers==" " && controller?.isHome == false{controller?.toggleCamera(nil)}else{super.keyDown(with:event)}}
}
final class AppController:NSObject,NSApplicationDelegate,NSWindowDelegate{
    var window:NSWindow!,stage:Stage!,renderer:PupRenderer!
    let home=HomeView(frame:.zero)
    let intro=IntroView(frame:.zero)
    private var introOwnsFullScreen=false
    private var explorerWindow:SplatExplorerWindow?
    var ballButton:NSButton!
    var isHome=true
    var homeButton:NSButton!
    var modeIcons:[InteractionMode:NSButton]=[:]
    let brightnessIcon=NSImageView(),motionIcon=NSImageView()
    private var lastHomeTick:Double=0
    let cameraPreview=CameraPreviewView()
    var tracker=HandTracker()
    let overlay=PointerOverlay(),status=NSTextField(labelWithString:""),hint=NSTextField(labelWithString:""),title=NSTextField(labelWithString:"LumaPaw")
    var quitButton:NSButton!,editButton:NSButton!,cameraStatus="Camera is off",lastUI:Double=0
    var backgroundButton:NSButton!,backgroundSlider:NSSlider!,backgroundMenuItem:NSMenuItem!
    let backgroundPopover=NSPopover(),backgroundVisibility=NSSwitch()
    var backgroundViewButton:NSPopUpButton!,backgroundMotionSlider:NSSlider!
    let backgroundLabel=NSTextField(labelWithString:"Brightness"),backgroundMotionLabel=NSTextField(labelWithString:"Motion")
    var modeMenuItems:[InteractionMode:NSMenuItem]=[:]
    var breedButton:NSPopUpButton!
    // Every new launch starts with the yellow Shiba; switching remains available in-session.
    var activeBreed:DogBreed = .shiba
    private var modeGate=InteractionModeGate(),inputSuspended=false
    var inputMode:InteractionMode {modeGate.mode}
    var soundEvents = DogSoundEvents()
    var voice:VoiceTracker!,dogAudio:DogAudio?,voicePanel:VoicePanel?,voiceSettings=VoiceSettings()
    var voiceSettingsButton:NSButton!,needsVoiceSetup=false,voiceStatus="Voice is off",lastTranscript=""
    var voiceWanted:Bool {inputMode == .voice}
    var editor:CustomizationPanel?,profile=AppController.defaultProfile(),profileImage:NSImage?
    var profileBusy=false,profileMessage="",profileGeneration=0,pendingChange:DispatchWorkItem?
    let profileQueue=DispatchQueue(label:"LuminousPup.PhotoAndMorphology",qos:.userInitiated)
    static func defaultProfile(_ breed:DogBreed = .shiba)->DogPersonalization{DogPersonalization(morphology:breed.parameters,palette:breed.palette,name:"LumaPaw",photoFilename:"",confidence:0,note:breed.profileNote,warnings:[],measuredProportions:false)}
    var voiceSettingsURL:URL{profileURL.deletingLastPathComponent().appendingPathComponent("voice_settings.json")}
    var profileURL:URL{FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("local.aisaka.luminous-pup").appendingPathComponent(activeBreed.profileFilename)}
    var profilePhotoURL:URL{profileURL.deletingLastPathComponent().appendingPathComponent(activeBreed.photoFilename)}

    func applicationDidFinishLaunching(_ note:Notification){
        NSApp.setActivationPolicy(.regular)
        do{
            renderer=try PupRenderer(resources:Bundle.main.resourceURL!)
            let defaults=UserDefaults.standard
            renderer.lightTrailEnabled=defaults.object(forKey:"lightTrailEnabled") as? Bool ?? true
            renderer.backgroundEnabled=renderer.background != nil && (defaults.object(forKey:"barnetBackgroundEnabled") as? Bool ?? true)
            if defaults.object(forKey:"barnetBackgroundStrength") != nil{renderer.backgroundStrength=min(1,max(0,defaults.float(forKey:"barnetBackgroundStrength")))}
            if defaults.object(forKey:"barnetDynamicStrength") != nil{renderer.background?.dynamicStrength=min(1,max(0,defaults.float(forKey:"barnetDynamicStrength")))}
            // Introduce the newly requested meadow once; later slider choices remain saved.
            if renderer.background != nil && !defaults.bool(forKey:"sunlitMeadowIntroduced") {
                renderer.backgroundEnabled=true;renderer.backgroundStrength=0.92;renderer.background?.dynamicStrength=0.12
                defaults.set(true,forKey:"barnetBackgroundEnabled");defaults.set(0.92,forKey:"barnetBackgroundStrength")
                defaults.set(0.12,forKey:"barnetDynamicStrength");defaults.set(true,forKey:"sunlitMeadowIntroduced")
            }
            if let i=CommandLine.arguments.firstIndex(of:"--verify-v6"){try renderer.verifyV6(to:URL(fileURLWithPath:CommandLine.arguments[i+1]));NSApp.terminate(nil);return}
            if let i=CommandLine.arguments.firstIndex(of:"--verify-voice"){try renderer.verifyVoice(to:URL(fileURLWithPath:CommandLine.arguments[i+1]),resources:Bundle.main.resourceURL!);NSApp.terminate(nil);return}
            if let i=CommandLine.arguments.firstIndex(of:"--verify-highfive"){try renderer.verifyHighFive(to:URL(fileURLWithPath:CommandLine.arguments[i+1]));NSApp.terminate(nil);return}
            if CommandLine.arguments.contains("--verify"){let i=CommandLine.arguments.firstIndex(of:"--verify")!;let out=URL(fileURLWithPath:CommandLine.arguments[i+1]);try renderer.verify(to:out);let photoIndex=CommandLine.arguments.firstIndex(of:"--photo");let photoURL=photoIndex.flatMap{ $0+1<CommandLine.arguments.count ? URL(fileURLWithPath:CommandLine.arguments[$0+1]):nil };try renderer.verifyAppearances(to:out.appendingPathComponent("appearance-comparison"),photoURL:photoURL);NSApp.terminate(nil);return}
            setupVoice()
            let menu=NSMenu(),item=NSMenuItem(),appMenu=NSMenu();appMenu.addItem(withTitle:"Quit LumaPaw",action:#selector(quit(_:)),keyEquivalent:"q");item.submenu=appMenu;menu.addItem(item)
            let control=NSMenuItem(),cm=NSMenu(title:"Controls")
            for (index,mode) in InteractionMode.allCases.enumerated(){
                let entry=cm.addItem(withTitle:mode.displayName,action:#selector(selectModeMenu(_:)),keyEquivalent:String(index+1))
                entry.target=self;entry.representedObject=mode.rawValue;modeMenuItems[mode]=entry
            }
            cm.addItem(.separator())
            cm.addItem(withTitle:"Import dog photo",action:#selector(importPhoto(_:)),keyEquivalent:"o")
            cm.addItem(withTitle:"Appearance",action:#selector(showEditor(_:)),keyEquivalent:"e")
            cm.addItem(withTitle:"Name & sound",action:#selector(showVoiceSettings(_:)),keyEquivalent:"n")
            cm.addItem(withTitle:"Mute / Unmute",action:#selector(toggleSound(_:)),keyEquivalent:"u")
            backgroundMenuItem=cm.addItem(withTitle:"Hide background",action:#selector(toggleBackground(_:)),keyEquivalent:"b");backgroundMenuItem.target=self
            cm.addItem(withTitle:"Save snapshot",action:#selector(snapshot(_:)),keyEquivalent:"s")
            control.title="Controls";control.submenu=cm;menu.addItem(control);NSApp.mainMenu=menu
            window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            window.title="LumaPaw";window.appearance=NSAppearance(named:.darkAqua);window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.isMovableByWindowBackground=false;window.backgroundColor = .black;window.minSize=NSSize(width:800,height:560);window.delegate=self
            for b in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton]{window.standardWindowButton(b)?.isHidden=true}
            stage=Stage(frame:window.contentView!.bounds,device:renderer.device);stage.controller=self;stage.colorPixelFormat = .bgra8Unorm_srgb;stage.preferredFramesPerSecond=60;stage.clearColor=MTLClearColorMake(0,0,0,1);stage.framebufferOnly=false;stage.autoresizingMask=[.width,.height];stage.delegate=renderer;window.contentView=stage
            overlay.frame=stage.bounds;overlay.autoresizingMask=[.width,.height];stage.addSubview(overlay)
            stage.addSubview(cameraPreview);cameraPreview.setEnabled(false);cameraPreview.isHidden=true
            func label(_ l:NSTextField,_ font:NSFont,_ color:NSColor){l.font=LumaStyle.font(font.pointSize);l.textColor=color;l.isSelectable=false;l.backgroundColor = .clear;stage.addSubview(l)}
            label(title,.systemFont(ofSize:12,weight:.medium),NSColor(white:0.85,alpha:1));label(status,.systemFont(ofSize:11,weight:.regular),NSColor(white:0.52,alpha:1));label(hint,.systemFont(ofSize:12,weight:.regular),NSColor(white:0.43,alpha:1));hint.alignment = .center
            voiceSettingsButton=icon("waveform",name:"Name & sound",action:#selector(showVoiceSettings(_:)))
            editButton=icon("slider.horizontal.3",name:"Appearance",action:#selector(showEditor(_:)))
            quitButton=icon("xmark",name:"Quit",action:#selector(quit(_:)))
            homeButton=icon("house",name:"Home",action:#selector(goHome(_:)))
            ballButton=icon("tennisball",name:"Throw ball",action:#selector(throwBall(_:)))
            ballButton.setAccessibilityIdentifier("throw-ball")
            for (index,mode) in InteractionMode.allCases.enumerated(){
                let symbol=["cursorarrow","hand.raised","mic"][index]
                let button=icon(symbol,name:mode.displayName+" control",action:#selector(modeIconChanged(_:)))
                button.tag=index;button.setAccessibilityIdentifier("mode-"+mode.rawValue)
                modeIcons[mode]=button
            }
            breedButton=NSPopUpButton(frame:.zero,pullsDown:false);breedButton.bezelStyle = .rounded
            breedButton.font = .systemFont(ofSize:11,weight:.medium);breedButton.appearance=NSAppearance(named:.darkAqua)
            for breed in DogBreed.menuOrder {breedButton.addItem(withTitle:breed.title);breedButton.lastItem?.representedObject=breed.rawValue}
            breedButton.selectItem(at:DogBreed.menuOrder.firstIndex(of:activeBreed) ?? 0)
            breedButton.target=self;breedButton.action=#selector(changeBreed(_:))
            breedButton.setAccessibilityLabel("Choose dog");breedButton.setAccessibilityIdentifier("dog-breed")
            breedButton.toolTip="Choose Large, Medium or Small";stage.addSubview(breedButton)
            backgroundButton=NSButton(title:"",target:self,action:#selector(showBackgroundSettings(_:)))
            backgroundButton.bezelStyle = .rounded;backgroundButton.font = .systemFont(ofSize:11,weight:.medium)
            backgroundButton.appearance=NSAppearance(named:.darkAqua);backgroundButton.setAccessibilityIdentifier("background-settings")
            backgroundButton.title="";backgroundButton.image=LumaStyle.symbol("sparkles.rectangle.stack","Toggle background") ?? LumaStyle.symbol("photo","Toggle background")
            backgroundButton.isBordered=false;backgroundButton.contentTintColor=NSColor(white:0.65,alpha:1)
            stage.addSubview(backgroundButton)
            backgroundSlider=NSSlider(value:Double(renderer.backgroundStrength),minValue:0.0,maxValue:1.0,target:self,action:#selector(changeBackgroundStrength(_:)))
            backgroundSlider.isContinuous=true;backgroundSlider.controlSize = .small;backgroundSlider.setAccessibilityLabel("Background brightness")
            backgroundSlider.setAccessibilityIdentifier("background-strength");backgroundSlider.toolTip="Adjust background brightness"
            stage.addSubview(backgroundSlider)
            brightnessIcon.image=LumaStyle.symbol("sun.max","Brightness");brightnessIcon.contentTintColor=NSColor(white:0.48,alpha:1);stage.addSubview(brightnessIcon)
            backgroundViewButton=NSPopUpButton(frame:.zero,pullsDown:false);backgroundViewButton.bezelStyle = .rounded
            backgroundViewButton.font = .systemFont(ofSize:11,weight:.medium);backgroundViewButton.appearance=NSAppearance(named:.darkAqua)
            backgroundViewButton.addItems(withTitles:renderer.background?.viewNames ?? ["Background unavailable"])
            backgroundViewButton.selectItem(at:renderer.background?.currentViewIndex ?? 0)
            backgroundViewButton.target=self;backgroundViewButton.action=#selector(changeBackgroundView(_:))
            backgroundViewButton.setAccessibilityIdentifier("background-view");backgroundViewButton.setAccessibilityLabel("Choose scene")
            backgroundViewButton.toolTip="Choose a Gaussian splat environment. Meadow: ground sampled from Fiets_Park by aaahhh, CC BY 4.0. Ground particles, wind and colours adapted for LumaPaw. https://superspl.at/scene/e23af0a4";stage.addSubview(backgroundViewButton)
            backgroundMotionSlider=NSSlider(value:Double(renderer.background?.dynamicStrength ?? 0.55),minValue:0,maxValue:1,target:self,action:#selector(changeBackgroundMotion(_:)))
            backgroundMotionSlider.isContinuous=true;backgroundMotionSlider.controlSize = .small
            backgroundMotionSlider.setAccessibilityLabel("Background motion");backgroundMotionSlider.setAccessibilityIdentifier("background-motion")
            backgroundMotionSlider.toolTip="Adjust ambient motion";stage.addSubview(backgroundMotionSlider)
            motionIcon.image=LumaStyle.symbol("wind","Motion");motionIcon.contentTintColor=NSColor(white:0.48,alpha:1);stage.addSubview(motionIcon)
            for popup in [breedButton!]{
                popup.isBordered=false;popup.imagePosition = .imageOnly
                (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
                let symbol=popup === breedButton ? "pawprint":"photo.on.rectangle"
                for item in popup.itemArray{item.image=LumaStyle.symbol(symbol,item.title)}
            }
            setupBackgroundPopover()
            title.isHidden=true
            home.frame=stage.bounds;home.onStart={[weak self]in self?.startExperience()}
            home.onInfo={[weak self]in self?.showIntro()}
            stage.addSubview(home);stage.addSubview(quitButton,positioned:.above,relativeTo:home)
            intro.frame=stage.bounds;intro.onExit={[weak self]in self?.finishIntro()}
            intro.onExplore={[weak self]in self?.showExplorer()}
            stage.addSubview(intro,positioned:.above,relativeTo:quitButton)
            refreshBackgroundControls();renderer.homeMode=true
            renderer.motion.position=SIMD2(0,-1.55);renderer.motion.yaw = -0.30

            layout();window.center();window.makeKeyAndOrderFront(nil);window.makeFirstResponder(stage);window.acceptsMouseMovedEvents=true;NSApp.activate(ignoringOtherApps:true)
            selectMode(.mouse,force:true)
            renderer.onFrame={[weak self]in
                guard let self else{return};let now=CACurrentMediaTime()
                let dt=Float(min(1/30,max(0,now-self.lastHomeTick)))
                self.home.advance(dt:dt);self.intro.advance(dt:dt);self.lastHomeTick=now
                self.updateDogSounds()
                self.refresh()
            }
            if CommandLine.arguments.contains("--demo"){renderer.demo=true}
            if let data=try? Data(contentsOf:profileURL),let saved=try? JSONDecoder().decode(DogPersonalization.self,from:data){
                profileImage=NSImage(contentsOf:profilePhotoURL)
                var yellow=saved;yellow.palette = .amber
                requestProfile(yellow,persist:false)
            }else if activeBreed != .shiba {requestProfile(Self.defaultProfile(activeBreed))}
            dogAudio?.setSuspended(true);dogAudio?.startAmbient();refresh(force:true);updatePage();window.makeFirstResponder(home)
        }catch{if CommandLine.arguments.contains("--verify-v6") || CommandLine.arguments.contains("--verify-voice") || CommandLine.arguments.contains("--verify") || CommandLine.arguments.contains("--verify-highfive"){fputs("Verification error: \(error)\n",stderr);exit(1)};let alert=NSAlert();alert.messageText="LumaPaw could not start";alert.informativeText=error.localizedDescription;alert.runModal();NSApp.terminate(nil)}
    }
    func icon(_ symbol:String,name:String,action:Selector)->NSButton{let b=NSButton(image:LumaStyle.symbol(symbol,name)!,target:self,action:action);b.bezelStyle = .regularSquare;b.isBordered=false;b.contentTintColor=NSColor(white:0.72,alpha:1);b.toolTip=name;b.setAccessibilityLabel(name);stage.addSubview(b);return b}
    func layout(){
        guard stage != nil else{return};let w=stage.bounds.width,h=stage.bounds.height
        home.frame=stage.bounds;home.needsLayout=true
        intro.frame=stage.bounds;intro.needsLayout=true
        cameraPreview.frame=NSRect(x:26,y:h-284,width:252,height:202)
        homeButton.frame=NSRect(x:26,y:h-61,width:32,height:32)
        breedButton.frame=NSRect(x:76,y:h-61,width:38,height:32)
        ballButton.frame=NSRect(x:125,y:h-61,width:32,height:32)
        for (index,mode) in InteractionMode.allCases.enumerated(){modeIcons[mode]?.frame=NSRect(x:w-291+CGFloat(index)*43,y:h-61,width:34,height:32)}
        editButton.frame=NSRect(x:w-150,y:h-61,width:32,height:32)
        voiceSettingsButton.frame=NSRect(x:w-103,y:h-61,width:32,height:32)
        quitButton.frame=NSRect(x:w-57,y:h-61,width:28,height:32)
        backgroundButton.frame=NSRect(x:26,y:28,width:34,height:34)
        hint.frame=NSRect(x:50,y:80,width:w-100,height:22)
        status.frame=NSRect(x:127,y:36,width:max(100,w-480),height:19)
    }
    func updatePage(){
        guard stage != nil else{return}
        var controls:[NSView]=[homeButton,breedButton,ballButton,editButton,voiceSettingsButton]
        controls += [backgroundButton]
        if isHome { backgroundPopover.performClose(nil) }
        controls.append(contentsOf:Array(modeIcons.values))
        for view in controls{view.isHidden=isHome}
        title.isHidden=true;home.isHidden = !isHome || intro.isRunning
        quitButton.isHidden=intro.isRunning
        cameraPreview.isHidden=isHome || inputMode != .hand
        overlay.isHidden=isHome;hint.isHidden=isHome || !renderer.handThrow.active;status.isHidden=true
    }
    func showExplorer(){
        guard isHome,intro.isRunning else{return}
        if let explorerWindow{explorerWindow.present();return}
        do{
            let explorer=try SplatExplorerWindow(resources:Bundle.main.resourceURL!)
            explorer.onClose={[weak self]in
                guard let self else{return};self.explorerWindow=nil;self.stage.isPaused=false
                self.lastHomeTick=CACurrentMediaTime();self.window.makeKeyAndOrderFront(nil);self.window.makeFirstResponder(self.intro)
            }
            explorerWindow=explorer;renderer.clearInput();stage.isPaused=true;explorer.present()
        }catch{let alert=NSAlert();alert.messageText="Unable to open Barnet 3";alert.informativeText=error.localizedDescription;alert.beginSheetModal(for:window)}
    }
    func showIntro(){
        guard isHome,!intro.isRunning else{return}
        renderer.clearInput()
        introOwnsFullScreen = !window.styleMask.contains(.fullScreen)
        intro.begin();updatePage();window.makeFirstResponder(intro)
        if introOwnsFullScreen {window.collectionBehavior.insert(.fullScreenPrimary);window.toggleFullScreen(nil)}
    }
    private func finishIntro(){
        if introOwnsFullScreen && window.styleMask.contains(.fullScreen){window.toggleFullScreen(nil)}
        updatePage();window.makeFirstResponder(home)
    }
    func windowDidEnterFullScreen(_ notification:Notification){
        layout()
        if introOwnsFullScreen && !intro.isRunning {window.toggleFullScreen(nil)}
    }
    func windowDidExitFullScreen(_ notification:Notification){introOwnsFullScreen=false;layout()}
    @objc func throwBall(_ sender:Any?){
        guard !profileBusy else{return};_ = renderer.throwBall();refresh(force:true);window.makeFirstResponder(stage)
    }
    func startExperience(){
        guard isHome else{return}
        if activeBreed != .shiba {
            guard !profileBusy else{return}
            saveProfile();activeBreed = .shiba
            breedButton.selectItem(at:DogBreed.menuOrder.firstIndex(of:.shiba)!)
            profileImage=NSImage(contentsOf:profilePhotoURL)
            var yellow=(try? Data(contentsOf:profileURL)).flatMap{try? JSONDecoder().decode(DogPersonalization.self,from:$0)} ?? Self.defaultProfile(.shiba)
            yellow.palette = .amber
            requestProfile(yellow,persist:false,onApplied:{[weak self]in self?.startExperience()})
            return
        }
        profile.palette = .amber;renderer.applyPalette(.amber)
        isHome=false;renderer.homeMode=false
        dogAudio?.setSuspended(inputSuspended)
        renderer.clearInput();renderer.motion.position=SIMD2(0,-1.55);renderer.motion.yaw = -0.30
        selectMode(.mouse,force:true);updatePage();window.makeFirstResponder(stage)
    }
    @objc func goHome(_ sender:Any?){
        if intro.isRunning {intro.finish();return}
        guard !isHome else{return}
        selectMode(.mouse,force:true);voicePanel?.orderOut(nil);editor?.orderOut(nil)
        isHome=true;renderer.homeMode=true;dogAudio?.setSuspended(true);renderer.clearInput();renderer.cancelVoiceActions()
        renderer.highFive.cancel(immediately:true);renderer.screenHighFive.cancel(immediately:true);renderer.runningCircle.cancel(immediately:true)
        renderer.motion.position=SIMD2(0,-1.55);renderer.motion.velocity = .zero;renderer.motion.yaw = -0.30
        renderer.petBlend=0;renderer.movingBlend=0;renderer.gaitLanding.reset();updatePage();window.makeFirstResponder(home)
    }
    @objc func modeIconChanged(_ sender:NSButton){selectMode(InteractionMode.allCases[sender.tag])}
    func setupBackgroundPopover(){
        let controller=NSViewController()
        let root=NSView(frame:NSRect(x:0,y:0,width:284,height:208));controller.view=root
        func label(_ text:String,_ x:CGFloat,_ y:CGFloat){
            let v=NSTextField(labelWithString:text);v.font=LumaStyle.font(12)
            v.textColor=NSColor(white:0.78,alpha:1);v.frame=NSRect(x:x,y:y,width:172,height:20);root.addSubview(v)
        }
        label("Background",20,169)
        backgroundVisibility.frame=NSRect(x:220,y:167,width:44,height:24)
        backgroundVisibility.target=self;backgroundVisibility.action=#selector(toggleBackground(_:))
        backgroundVisibility.setAccessibilityLabel("Show background");backgroundVisibility.setAccessibilityIdentifier("background-toggle");root.addSubview(backgroundVisibility)
        backgroundViewButton.frame=NSRect(x:18,y:119,width:248,height:28)
        backgroundViewButton.isBordered=true;backgroundViewButton.imagePosition = .imageLeft
        root.addSubview(backgroundViewButton)
        label("Brightness",46,85);brightnessIcon.frame=NSRect(x:20,y:86,width:16,height:16)
        backgroundSlider.frame=NSRect(x:18,y:65,width:248,height:20)
        label("Motion",46,37);motionIcon.frame=NSRect(x:20,y:38,width:16,height:16)
        backgroundMotionSlider.frame=NSRect(x:18,y:17,width:248,height:20)
        for view in [brightnessIcon,backgroundSlider!,motionIcon,backgroundMotionSlider!] {root.addSubview(view)}
        backgroundPopover.contentViewController=controller;backgroundPopover.contentSize=root.bounds.size
        backgroundPopover.behavior = .transient;backgroundPopover.appearance=NSAppearance(named:.darkAqua)
    }
    @objc func showBackgroundSettings(_ sender:Any?){
        if backgroundPopover.isShown{backgroundPopover.performClose(nil);return}
        refreshBackgroundControls()
        backgroundPopover.show(relativeTo:backgroundButton.bounds,of:backgroundButton,preferredEdge:.maxY)
    }
    func refreshBackgroundControls(){
        let available=renderer.background != nil,on=renderer.backgroundEnabled && available
        let title=available ? (on ? "Hide background":"Show background"):"Background unavailable"
        backgroundButton?.title="";backgroundButton?.isEnabled=available;backgroundButton?.setAccessibilityLabel("Background settings")
        backgroundButton?.contentTintColor=NSColor(white:on ? 0.9:0.4,alpha:1)
        backgroundButton?.toolTip=available ? "Background settings":renderer.backgroundLoadError
        backgroundVisibility.state=on ? .on:.off;backgroundVisibility.isEnabled=available
        backgroundSlider?.isEnabled=on;backgroundMenuItem?.title=title;backgroundMenuItem?.isEnabled=available
        backgroundMenuItem?.state=on ? .on:.off
        backgroundMotionSlider?.isEnabled=on;backgroundViewButton?.isEnabled=on
    }
    @objc func changeBreed(_ sender:NSPopUpButton){
        guard let raw=sender.selectedItem?.representedObject as? String,let breed=DogBreed(rawValue:raw),breed != activeBreed else{return}
        pendingChange?.cancel();pendingChange=nil;profileGeneration+=1
        saveProfile()
        activeBreed=breed
        profileImage=NSImage(contentsOf:profilePhotoURL)
        let saved=(try? Data(contentsOf:profileURL)).flatMap{try? JSONDecoder().decode(DogPersonalization.self,from:$0)}
        requestProfile(saved ?? Self.defaultProfile(breed))
        window?.makeFirstResponder(stage)
    }
    @objc func toggleBackground(_ sender:Any?){
        guard renderer.background != nil else{return}
        renderer.backgroundEnabled.toggle();UserDefaults.standard.set(renderer.backgroundEnabled,forKey:"barnetBackgroundEnabled")
        refreshBackgroundControls();if !backgroundPopover.isShown{window?.makeFirstResponder(stage)}
    }
    @objc func changeBackgroundStrength(_ sender:NSSlider){
        renderer.backgroundStrength=Float(sender.doubleValue)
        UserDefaults.standard.set(sender.doubleValue,forKey:"barnetBackgroundStrength")
    }
    @objc func changeBackgroundMotion(_ sender:NSSlider){
        renderer.background?.dynamicStrength=Float(sender.doubleValue)
        UserDefaults.standard.set(sender.doubleValue,forKey:"barnetDynamicStrength")
    }
    @objc func changeBackgroundView(_ sender:NSPopUpButton){
        renderer.background?.selectView(sender.indexOfSelectedItem);if !backgroundPopover.isShown{window?.makeFirstResponder(stage)}
    }
    func windowDidResize(_ notification:Notification){layout()}
    func refreshPointerOverlay(){
        cameraPreview.setThrowStatus(inputMode == .hand ? (renderer.fetchGame.active ? "Fetching ball…":renderer.handThrow.hint):nil)
        overlay.throwCenter = !isHome && inputMode == .hand && renderer.handThrow.active ? renderer.handThrow.center:nil
        overlay.throwProgress=renderer.handThrow.progress;overlay.throwReady=renderer.handThrow.ready;overlay.throwTravel=renderer.handThrow.travel
        overlay.pointingLabel=inputMode == .mouse ? "Move to lead":"Point to lead"
        overlay.interactionLabel=inputMode == .hand ? renderer.highFivePointerLabel:nil;overlay.active = !isHome && inputMode != .voice && !renderer.fingers.isEmpty;overlay.locations=renderer.fingers;overlay.touching=renderer.touching;overlay.palm=renderer.intent == .palm;overlay.holding=renderer.handHolding;overlay.palmRadius=CGFloat(max(0.20,min(0.72,renderer.palmRadius*renderer.uniforms.viewport.w))/renderer.uniforms.viewport.w)*stage.bounds.height;overlay.needsDisplay=true
    }
    func refresh(force:Bool=false){let now=CACurrentMediaTime();guard force || now-lastUI>0.033 else{return};lastUI=now
        refreshPointerOverlay()
        hint.isHidden=isHome || !renderer.handThrow.active
        switch inputMode {
        case .mouse:
            status.stringValue=renderer.demo ? "Follow demo":"Mouse control"
            hint.stringValue=(renderer.touching ? (renderer.mousePetSit.ownsSit ? "Enjoying your touch · Release to stand":"Petting · Hold for 2 seconds to sit"):"Move to lead · Hold on your dog to pet")
        case .hand:
            status.stringValue=cameraStatus
            hint.stringValue=renderer.handThrow.hint ?? renderer.highFiveHint ?? (renderer.touching ? (renderer.mousePetSit.ownsSit ? "Enjoying your touch · Move away to stand":"Petting · Hold for 2 seconds to sit"):"Point to lead · Palm to pet · Hold a fist for 1 second to throw")
        case .voice:
            status.stringValue=voiceStatus
            hint.stringValue=renderer.voiceActions.hint ?? ("Say “"+voiceSettings.petName+"”, “Come here”, “Sit”, “Spin” or “High five”")
        }
        ballButton?.isEnabled = !profileBusy && !renderer.fetchGame.active && !renderer.handThrow.active
        ballButton?.contentTintColor=renderer.fetchGame.active ? NSColor(white:0.35,alpha:1):NSColor(white:0.78,alpha:1)
        ballButton?.toolTip=renderer.fetchGame.active ? renderer.fetchGame.hint:"Throw ball"
        if renderer.fetchGame.active {hint.stringValue=renderer.fetchGame.hint}
        let panelStatus=voiceWanted ? voiceStatus:("Using "+inputMode.displayName+" control · Microphone off")
        voicePanel?.updateStatus(panelStatus,transcript:voiceWanted ? lastTranscript:"",listening:voiceWanted)
        status.isHidden=isHome || (!profileBusy && !(inputMode == .voice && !voice.isListening))
        if profileBusy {status.stringValue=profileMessage}
        else if !profileMessage.isEmpty && inputMode == .mouse {status.stringValue=profileMessage}
    }
    func setupVoice(){
        needsVoiceSetup = !FileManager.default.fileExists(atPath:voiceSettingsURL.path)
        if let data=try? Data(contentsOf:voiceSettingsURL),let saved=try? JSONDecoder().decode(VoiceSettings.self,from:data){
            voiceSettings=saved
            if let name=VoiceSettings.cleanedName(saved.petName){voiceSettings.petName=name}
            else{voiceSettings.previousPetName=saved.petName;voiceSettings.petName="Luma";saveVoiceSettings()}
            voiceSettings.volume=saved.volume.isFinite ? min(1,max(0,saved.volume)):0.5
        }
        voice=VoiceTracker(petName:voiceSettings.petName)
        do{dogAudio=try DogAudio(resources:Bundle.main.resourceURL!);dogAudio?.setVolume(voiceSettings.volume);dogAudio?.setMuted(voiceSettings.muted)}catch{voiceStatus="Audio unavailable: "+error.localizedDescription}
        dogAudio?.onBarkPlayback={[weak self] duration in
            guard let self,self.inputMode == .voice else{return};self.voice.suppressCommands(for:duration)
        }
    }
    func updateDogSounds(){
        let r=renderer!
        let state=DogSoundState(active:!isHome && !inputSuspended && !r.paused && !profileBusy,
            running:r.movingBlend,petting:r.touching && r.pettingDuration>0.35,
            seated:r.voiceActions.phase == .sitting,
            throwCount:r.fetchGame.throwCount,pickups:r.fetchGame.contactEvents,
            deliveries:r.fetchGame.releaseEvents,
            highFives:r.screenHighFive.contactCount+r.highFive.completedCount,
            praises:r.voiceActions.praiseCount)
        for event in soundEvents.update(state){dogAudio?.respond(to:event)}
        dogAudio?.setActivity(state.active ? state.running:0)
    }
    func receiveVoice(_ command:VoiceCommand){
        guard inputMode == .voice,!inputSuspended,!renderer.paused,!profileBusy else{return}
        if command == .come{dogAudio?.bark()}
        renderer.performVoiceCommand(command);refresh(force:true)
    }
    /// The only input-mode authority. Old source objects lose their callbacks
    /// before stopping; each new activation owns distinct source identities.
    func selectMode(_ mode:InteractionMode,force:Bool=false){
        guard Thread.isMainThread else{DispatchQueue.main.async{[weak self]in self?.selectMode(mode,force:force)};return}
        guard !intro.isRunning else{return}
        guard force || mode != inputMode else{return}
        if isHome && mode != .mouse {startExperience()}
        let ticket=modeGate.select(mode,at:ProcessInfo.processInfo.systemUptime)
        tracker.onUpdate=nil;tracker.onPreview=nil;tracker.onStatus=nil;tracker.stop()
        voice?.onCommand=nil;voice?.onStatus=nil;voice?.onTranscript=nil;voice?.onListeningChanged=nil;voice?.stop()
        dogAudio?.setListening(false)
        renderer.demo=false;renderer.setInputMode(mode);renderer.clearInput();renderer.cancelVoiceActions()
        lastTranscript="";profileMessage=""
        cameraPreview.setEnabled(mode == .hand && !inputSuspended);cameraPreview.isHidden=mode != .hand
        if !inputSuspended {
            switch mode {
            case .mouse: break
            case .hand:
                cameraStatus="Starting camera…"
                tracker=HandTracker()
                tracker.onUpdate={[weak self]frame in
                    guard let self,!self.inputSuspended,self.modeGate.accepts(ticket,capturedAt:frame?.timestamp) else{return}
                    self.renderer.setHand(frame);self.refreshPointerOverlay()
                }
                tracker.onPreview={[weak self]frame in
                    guard let self,!self.inputSuspended,self.modeGate.accepts(ticket,capturedAt:frame?.timestamp) else{return}
                    self.cameraPreview.update(frame:frame)
                }
                tracker.onStatus={[weak self]text in
                    guard let self,!self.inputSuspended,self.modeGate.accepts(ticket) else{return}
                    self.cameraStatus=text;self.cameraPreview.setStatus(text);self.refresh(force:true)
                }
                tracker.start()
            case .voice:
                voiceStatus="Starting on-device English speech…"
                voice=VoiceTracker(petName:voiceSettings.petName)
                voice.onCommand={[weak self]command in
                    guard let self,!self.inputSuspended,self.modeGate.accepts(ticket) else{return};self.receiveVoice(command)
                }
                voice.onStatus={[weak self]text in
                    guard let self,!self.inputSuspended,self.modeGate.accepts(ticket) else{return}
                    self.voiceStatus=text;self.refresh(force:true)
                }
                voice.onTranscript={[weak self]text in
                    guard let self,!self.inputSuspended,self.modeGate.accepts(ticket) else{return}
                    self.lastTranscript=String(text.suffix(56));self.refresh(force:true)
                }
                voice.onListeningChanged={[weak self]active in
                    guard let self,!self.inputSuspended,self.modeGate.accepts(ticket) else{return}
                    self.dogAudio?.setListening(active);self.refresh(force:true)
                }
                voice.start()
            }
        }
        for (candidate,button) in modeIcons {
            button.contentTintColor=candidate == mode ? LumaStyle.ink:NSColor(white:0.35,alpha:1)
            button.wantsLayer=true;button.layer?.backgroundColor=NSColor(white:1,alpha:candidate == mode ? 0.065:0).cgColor;button.layer?.cornerRadius=6
            button.setAccessibilityValue(candidate == mode ? "Selected":"")
        }
        for (candidate,item) in modeMenuItems{item.state=candidate == mode ? .on:.off}
        if stage != nil{layout();refresh(force:true);updatePage()}
    }
    @objc func modeChanged(_ sender:NSPopUpButton){guard let raw=sender.selectedItem?.representedObject as? String,let mode=InteractionMode(rawValue:raw) else{return};selectMode(mode)}
    @objc func selectModeMenu(_ sender:NSMenuItem){guard let raw=sender.representedObject as? String,let mode=InteractionMode(rawValue:raw) else{return};selectMode(mode)}

    func saveVoiceSettings(){do{try FileManager.default.createDirectory(at:voiceSettingsURL.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(voiceSettings).write(to:voiceSettingsURL,options:.atomic)}catch{voiceStatus="Settings could not be saved: "+error.localizedDescription}}
    @objc func toggleVoice(_ sender:Any?){selectMode(inputMode == .voice ? .mouse:.voice)}
    @objc func toggleSound(_ sender:Any?){voiceSettings.muted.toggle();dogAudio?.setMuted(voiceSettings.muted);saveVoiceSettings();voicePanel?.configure(voiceSettings);refresh(force:true)}
    @objc func showVoiceSettings(_ sender:Any?){
        if voicePanel == nil {
            let panel=VoicePanel();voicePanel=panel
            panel.onName={[weak self] name in guard let self else{return false};self.voiceSettings.petName=name;self.voice.setName(name);self.saveVoiceSettings();self.refresh(force:true);return true}
            panel.onToggleListening={[weak self] in self?.toggleVoice(nil)}
            panel.onMute={[weak self] value in guard let self else{return};self.voiceSettings.muted=value;self.dogAudio?.setMuted(value);self.saveVoiceSettings()}
            panel.onVolume={[weak self] value in guard let self else{return};self.voiceSettings.volume=value;self.dogAudio?.setVolume(value);self.saveVoiceSettings()}
        }
        voicePanel!.configure(voiceSettings);voicePanel!.updateStatus(voiceWanted ? voiceStatus:("Using "+inputMode.displayName+" control · Microphone off"),transcript:voiceWanted ? lastTranscript:"",listening:voiceWanted)
        voicePanel!.setFrameOrigin(NSPoint(x:window.frame.maxX-410,y:window.frame.midY-241));window.addChildWindow(voicePanel!,ordered:.above);voicePanel!.makeKeyAndOrderFront(nil)
    }
    @objc func toggleCamera(_ sender:Any?){selectMode(inputMode == .hand ? .mouse:.hand)}
    @objc func showEditor(_ sender:Any?){
        if editor == nil {
            let panel=CustomizationPanel();editor=panel
            panel.onImport={[weak self] in self?.importPhoto(nil)}
            panel.onReset={[weak self] in guard let self else{return};self.profileImage=nil;self.requestProfile(Self.defaultProfile(self.activeBreed))}
            panel.onChange={[weak self] parameters in
                guard let self else{return};self.pendingChange?.cancel();self.profileGeneration+=1
                var proposed=self.profile;proposed.morphology=parameters
                proposed.morphology.breed=self.activeBreed == .shiba ? nil:self.activeBreed
                if parameters.sizeScale != self.profile.morphology.sizeScale {
                    proposed.note="Size adjusted manually. Photo coat colours are kept.";proposed.sizeEstimate=nil
                }
                self.profile=proposed
                let work=DispatchWorkItem{[weak self]in self?.requestProfile(proposed)};self.pendingChange=work
                DispatchQueue.main.asyncAfter(deadline:.now()+0.28,execute:work)
            }
        }
        editor!.update(profile,image:profileImage)
        editor!.setFrameOrigin(NSPoint(x:window.frame.maxX-350,y:window.frame.midY-370))
        window.addChildWindow(editor!,ordered:.above);editor!.makeKeyAndOrderFront(nil)
    }
    @objc func importPhoto(_ sender:Any?){
        pendingChange?.cancel();showEditor(nil)
        let panel=NSOpenPanel();panel.allowedContentTypes=[.jpeg,.png,.heic,.tiff,.image];panel.allowsMultipleSelection=false;panel.canChooseFiles=true;panel.canChooseDirectories=false
        panel.message="Choose a clear photo of one dog. A full-body side view works best."
        // Keep the picker application-modal while the floating editor is hidden.
        editor?.orderOut(nil);window.makeKeyAndOrderFront(nil)
        let result=panel.runModal()
        showEditor(nil)
        guard result == .OK,let url=panel.url else{return}
        do {
            self.profileGeneration+=1;let generation=self.profileGeneration
            self.profileBusy=true;self.profileMessage="Analysing photo on this Mac…";self.editor?.setMessage(self.profileMessage);self.refresh(force:true)
            let base=self.profile.morphology
            self.profileQueue.async{[weak self]in
                do{
                    let analyzed=try PhotoPersonalizer.analyze(url:url,base:base)
                    DispatchQueue.main.async{[weak self]in
                        guard let self,self.profileGeneration==generation else{return}
                        self.requestProfile(analyzed,image:NSImage(contentsOf:url),matchPhotoBreed:true)
                    }
                }catch{DispatchQueue.main.async{[weak self]in
                    guard let self,self.profileGeneration==generation else{return};self.profileBusy=false;self.profileMessage=error.localizedDescription;self.editor?.setMessage(error.localizedDescription);self.refresh(force:true)
                }}
            }
        }
    }
    func requestProfile(_ input:DogPersonalization,persist:Bool=true,image:NSImage?=nil,matchPhotoBreed:Bool=false,onApplied:(()->Void)?=nil){
        let targetBreed=matchPhotoBreed ? (input.morphology.breed ?? .shiba):activeBreed
        let proposedImage=image ?? profileImage
        var proposed=input
        if proposed.note.unicodeScalars.contains(where:{(0x3400...0x9FFF).contains($0.value)}){proposed.note=activeBreed.profileNote;proposed.warnings=[]}
        proposed.morphology.breed=targetBreed == .shiba ? nil:targetBreed
        pendingChange?.cancel();pendingChange=nil
        editor?.update(proposed,image:proposedImage)
        profileGeneration+=1;let generation=profileGeneration
        profileBusy=true;profileMessage="Fitting your dog…";editor?.setMessage(profileMessage);refresh(force:true)
        guard let engine=renderer.morphologyEngine(for:targetBreed) else{profileBusy=false;return}
        profileQueue.async{[weak self]in
            do{
                let baked=try engine.bake(parameters:proposed.morphology)
                DispatchQueue.main.async{[weak self]in
                    guard let self,self.profileGeneration==generation else{return}
                    do{
                        try self.renderer.applyMorphology(baked);self.renderer.applyPalette(proposed.palette)
                        if self.activeBreed != targetBreed {
                            self.saveProfile()
                            self.activeBreed=targetBreed
                            self.breedButton.selectItem(at:DogBreed.menuOrder.firstIndex(of:targetBreed)!)
                        }
                        self.profile=proposed;self.profile.morphology=baked.parameters;self.profileImage=proposedImage
                        self.profileBusy=false;self.profileMessage=proposed.photoFilename.isEmpty ? "Appearance updated":("Photo appearance · "+proposed.name)
                        UserDefaults.standard.set(self.activeBreed.rawValue,forKey:"dogBreed")
                        self.editor?.update(self.profile,image:self.profileImage)
                        if persist{self.saveProfile()};self.refresh(force:true);onApplied?()
                    }catch{self.profileBusy=false;self.profileMessage=error.localizedDescription;self.editor?.setMessage(error.localizedDescription)}
                }
            }catch{DispatchQueue.main.async{[weak self]in
                guard let self,self.profileGeneration==generation else{return};self.profileBusy=false;self.profileMessage=error.localizedDescription;self.editor?.setMessage(error.localizedDescription);self.refresh(force:true)
            }}
        }
    }
    func saveProfile(){
        do{
            let folder=profileURL.deletingLastPathComponent();try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try JSONEncoder().encode(profile).write(to:profileURL,options:.atomic)
            let thumbnail=profilePhotoURL
            if let image=profileImage {
                let small=NSImage(size:NSSize(width:360,height:240));small.lockFocus();NSColor.black.setFill();NSRect(x:0,y:0,width:360,height:240).fill()
                let scale=min(360/max(1,image.size.width),240/max(1,image.size.height));let size=NSSize(width:image.size.width*scale,height:image.size.height*scale)
                image.draw(in:NSRect(x:(360-size.width)/2,y:(240-size.height)/2,width:size.width,height:size.height));small.unlockFocus()
                if let tiff=small.tiffRepresentation,let png=NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]){try png.write(to:thumbnail,options:.atomic)}
            }else if FileManager.default.fileExists(atPath:thumbnail.path){try FileManager.default.removeItem(at:thumbnail)}
        }catch{profileMessage="Appearance applied, but could not save: "+error.localizedDescription}
    }
    @objc func snapshot(_ sender:Any?){let root=Bundle.main.bundleURL.deletingLastPathComponent();do{let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:Int(stage.drawableSize.width),height:Int(stage.drawableSize.height),mipmapped:false);d.usage=[.renderTarget,.shaderRead];d.storageMode = .shared;let t=renderer.device.makeTexture(descriptor:d)!;let cb=renderer.encode(texture:t);cb.commit();cb.waitUntilCompleted();try renderer.savePNG(t,to:root.appendingPathComponent("preview/current-frame.png"));let diagnostic:[String:Any]=["drawAttempts":renderer.drawAttempts,"drawPaused":renderer.drawPaused,"drawOccluded":renderer.drawOccluded,"drawNoDrawable":renderer.drawNoDrawable,"frames":renderer.frames,"rendererPaused":renderer.paused,"stagePaused":stage.isPaused,"enableSetNeedsDisplay":stage.enableSetNeedsDisplay,"windowVisible":window.isVisible,"windowMiniaturized":window.isMiniaturized,"appHidden":NSApp.isHidden,"occlusion":window.occlusionState.rawValue,"metalErrors":renderer.metalErrors]
        try JSONSerialization.data(withJSONObject:diagnostic,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("preview/render-status.json"));status.stringValue="Snapshot saved to preview/current-frame.png"}catch{status.stringValue=error.localizedDescription}}
    @objc func quit(_ sender:Any?){voice?.stop();dogAudio?.stop();tracker.stop();NSApp.terminate(nil)}
    func applicationDidResignActive(_ notification:Notification){
        guard renderer != nil else{return}
        // A visible camera interaction continues when another app has focus.
        if inputMode == .mouse{renderer.clearInput()}
    }
    func setSuspended(_ suspended:Bool){
        guard renderer != nil else{return};renderer.paused=suspended;renderer.lastTime=CACurrentMediaTime()
        if inputSuspended != suspended{inputSuspended=suspended;selectMode(inputMode,force:true)}
        dogAudio?.setSuspended(suspended || isHome)
    }
    func windowDidMiniaturize(_ notification:Notification){setSuspended(true)}
    func windowDidDeminiaturize(_ notification:Notification){setSuspended(window.isMiniaturized || NSApp.isHidden)}
    func applicationDidHide(_ notification:Notification){setSuspended(true)}
    func applicationDidUnhide(_ notification:Notification){setSuspended(window.isMiniaturized || NSApp.isHidden)}
    func applicationDidBecomeActive(_ notification:Notification){guard renderer != nil else{return};setSuspended(window.isMiniaturized || NSApp.isHidden)}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
    func applicationWillTerminate(_ notification:Notification){voice?.stop();dogAudio?.stop();tracker.stop()}
}
let app=NSApplication.shared
let controller=AppController();app.delegate=controller;app.run()
