import Foundation

enum VoiceActionPhase:String {
    case idle, preparing, coming, sitEnter, sitting, sitExit, shake, happy, spin, settling
}

/// Latest spoken request wins the queue, while a seated dog always stands up
/// through the authored exit. Animation endpoints are never skipped to move.
struct VoiceActionController {
    private(set) var phase:VoiceActionPhase = .idle
    private(set) var time:Float=0
    private(set) var pending:VoiceCommand?
    private(set) var completedCount=0
    private(set) var praiseCount=0
    private(set) var startYaw:Float=0
    private var settlingClip:String?
    private var standRequested=false
    var active:Bool {phase != .idle}
    var clipName:String? {
        switch phase {
        case .sitEnter:return "sit_enter"
        case .sitting:return "sit_hold"
        case .sitExit:return "sit_exit"
        case .shake:return nil
        case .happy:return "happy"
        case .settling:return settlingClip
        default:return nil
        }
    }
    var wantsClipWeight:Bool {clipName != nil && phase != .settling}
    var loopsClip:Bool {phase == .sitting}
    mutating func request(_ command:VoiceCommand) {
        pending=command
        if phase == .idle || phase == .coming {phase = .preparing;time=0}
        else if phase == .sitting {phase = .sitExit;time=0}
    }
    mutating func standForHand() {
        if phase == .sitting {pending=nil;phase = .sitExit;time=0}
    }
    mutating func standInPlace(){
        pending=nil
        switch phase {
        case .sitting:phase = .sitExit;time=0
        case .sitEnter:standRequested=true
        case .preparing:phase = .idle;time=0
        default:break
        }
    }
    /// Enter/exit are the same eased pose in opposite directions. Releasing
    /// a mouse stroke midway reverses at that exact pose, without finishing
    /// the downward motion first or snapping through a standing frame.
    mutating func standAfterPetting(enterDuration:Float,exitDuration:Float){
        pending=nil;standRequested=false
        if phase == .sitEnter {
            let progress=min(1,max(0,time/max(0.001,enterDuration)))
            phase = .sitExit;time=(1-progress)*exitDuration
        }else{standInPlace()}
    }
    mutating func reset(){let count=completedCount,praise=praiseCount;self=Self();completedCount=count;praiseCount=praise}
    mutating func update(dt:Float,ready:Bool,stopped:Bool,atCentre:Bool,yaw:Float,
                         duration:(String)->Float,screenHighFiveFinished:Bool?=nil,runningCircleFinished:Bool?=nil) {
        guard dt.isFinite,dt>0 else{return}
        switch phase {
        case .idle:break
        case .preparing:
            guard ready,stopped,let command=pending else{return}
            pending=nil;time=0;startYaw=yaw
            switch command {
            case .come:phase = .coming
            case .sit:phase = .sitEnter
            case .spin:phase = .spin
            case .shake:phase = .shake
            case .praise:phase = .happy;praiseCount+=1
            }
        case .coming:
            time+=dt
            if atCentre || time>10 {completedCount+=1;phase = .idle;time=0}
        case .sitting:
            time=(time+dt).truncatingRemainder(dividingBy:max(0.1,duration("sit_hold")))
        case .sitEnter:
            time=min(duration("sit_enter"),time+dt)
            if time>=duration("sit_enter") {
                completedCount+=1;phase=pending == nil && !standRequested ? .sitting:.sitExit;time=0;standRequested=false
            }
        case .sitExit:
            time=min(duration("sit_exit"),time+dt)
            if time>=duration("sit_exit"){settlingClip="sit_exit";phase = .settling}
        case .shake:
            time+=dt
            if screenHighFiveFinished ?? (time>=duration("screen_highfive")) {
                completedCount+=1;settlingClip=nil;phase = .settling;time=0
            }
        case .happy:
            let clip=clipName!,end=duration(clip)
            time=min(end,time+dt)
            if time>=end{completedCount+=1;settlingClip=clip;phase = .settling}
        case .spin:
            if runningCircleFinished ?? (time>=RunningCircleController.lapDuration) {completedCount+=1;phase = .settling;settlingClip=nil;time=0}
            else{time+=dt}
        case .settling:
            if ready {phase=pending == nil ? .idle:.preparing;settlingClip=nil;time=0}
        }
    }
    var hint:String? {
        switch phase {
        case .idle:return nil
        case .preparing:return "I heard you"
        case .coming:return "Woof! Coming over"
        case .sitEnter:return "Sitting down"
        case .sitting:return "Sitting · Say my name to call me over"
        case .sitExit:return "Standing up · On my way"
        case .shake:return "Coming over for a high five"
        case .happy:return "That made my day!"
        case .spin:return "Going for a spin"
        case .settling:return "Ready for you"
        }
    }
}
