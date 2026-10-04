import Foundation
import simd

struct HandThrow {
    let origin: SIMD2<Float>
    let travel: Float
}

/// Fresh fist evidence charges, bridging at most 120 ms of jitter. Uncertainty pauses the
/// charge; a completed throw alone latches until the hand is opened again.
struct HandThrowController {
    enum Phase { case idle, charging, waitingForOpen }
    private(set) var phase:Phase = .idle
    private(set) var progress:Float=0
    private(set) var center=SIMD2<Float>.zero
    private(set) var travel:Float=0
    let holdDuration:Double=1
    private let lossGrace:Double=0.95
    private var accumulated:Double=0,lastTime:Double=0,lastClosedTime:Double=0,lastClosedDelivery:Double=0,quietUntil:Double=0
    private var previousPalm:SIMD2<Float>?,previousClosed=false,openSince:Double?
    var active:Bool {phase == .charging}
    var ready:Bool {active && progress>=0.85}
    var suppressesOtherGestures:Bool {active || lastTime<quietUntil}
    var hint:String? {
        if phase == .waitingForOpen {return "Open hand to throw again"}
        guard active else{return nil}
        return String(format:previousClosed ? "Hold fist · %.1f s":"Hold steady · %.1f s",max(0,holdDuration-accumulated))
    }
    mutating func reset(){self=HandThrowController()}
    mutating func cancel(at time:Double?=nil){
        if active {quietUntil=(time ?? lastTime)+0.12}
        // Fetch and tracking interruptions must not undo the once-per-hold latch.
        if phase != .waitingForOpen {phase = .idle}
        accumulated=0;progress=0;travel=0;previousClosed=false;openSince=nil
    }
    private mutating func pause(at time:Double){
        previousClosed=false;openSince=nil
        if active && time-lastClosedTime>lossGrace {cancel(at:time)}
    }
    mutating func expire(at time:Double){
        // Charge uses capture intervals; loss grace uses arrival intervals. A
        // consistently delayed camera must not expire between valid deliveries.
        if active && time-lastClosedDelivery>lossGrace {cancel()}
    }
    private mutating func missing(at time:Double){previousClosed=false;openSince=nil;expire(at:time)}
    mutating func process(_ frame:HandFrame?,allowed:Bool,canBegin:Bool,now:Double?=nil)->HandThrow? {
        // Observe reopening while the dog fetches, but never charge during fetch.
        // Keeping a fist closed across delivery still cannot auto-launch another ball.
        if (!allowed || !canBegin) && phase != .waitingForOpen {cancel(at:now);return nil}
        guard let frame,frame.timestamp.isFinite else {missing(at:now ?? lastTime);return nil}
        if frame.isHolding {missing(at:now ?? max(lastTime,frame.timestamp));return nil}
        guard frame.timestamp>lastTime else{return nil}
        let gap=frame.timestamp-lastTime;lastTime=frame.timestamp
        guard let observation=frame.throwObservation,observation.isReliable(fallback:frame.confidence),
              observation.center.x.isFinite,observation.center.y.isFinite,
              observation.palm.x.isFinite,observation.palm.y.isFinite else {
            pause(at:lastTime);return nil
        }
        if phase == .waitingForOpen {
            // Debounce a single false open frame; opening never throws a ball.
            if observation.open {
                if openSince == nil || gap>lossGrace {openSince=lastTime}
                if lastTime-(openSince ?? lastTime)>=0.12 {phase = .idle;openSince=nil}
            }else {openSince=nil}
            previousPalm=observation.palm
            return nil
        }
        if observation.extendedFinger || frame.intent == .pointing {
            // Positive pointing evidence is not a tracking dropout. Discard the
            // charge so alternating pointing/fist labels cannot accumulate a throw.
            cancel(at:lastTime);previousPalm=observation.palm
            return nil
        }
        if observation.open {
            // Vision may briefly label a turned fist as open. A sustained open
            // cancels; a single noisy sample only pauses the verified timer.
            if openSince == nil || gap>lossGrace {openSince=lastTime}
            previousClosed=false;previousPalm=observation.palm
            if lastTime-(openSince ?? lastTime)>=0.22 {cancel(at:lastTime)}
            else if active && lastTime-lastClosedTime>lossGrace {cancel(at:lastTime)}
            return nil
        }
        openSince=nil
        if active && (lastTime-lastClosedTime>lossGrace || previousPalm.map{simd_distance($0,observation.palm)>0.32} == true) {
            cancel(at:lastTime)
        }
        previousPalm=observation.palm
        let confirmed=observation.closed || (active && observation.continuingClosed)
        guard confirmed else{pause(at:lastTime);return nil}
        if phase == .idle {
            guard lastTime>=quietUntil else{return nil}
            phase = .charging;accumulated=0;progress=0;center=observation.center
            lastClosedTime=lastTime;lastClosedDelivery=now ?? lastTime;previousClosed=true;return nil
        }
        // A fresh confirmed return can bridge one or two dropped camera frames.
        // Longer occlusions preserve progress but add no time and cannot throw.
        let confirmedGap=lastTime-lastClosedTime
        if previousClosed && gap<=lossGrace {accumulated+=gap}
        else if confirmedGap<=0.12 {accumulated+=confirmedGap}
        lastClosedTime=lastTime;lastClosedDelivery=now ?? lastTime;previousClosed=true;center=observation.center
        progress=min(1,Float(accumulated/holdDuration))
        guard accumulated>=holdDuration-0.000001 else{return nil}
        let event=HandThrow(origin:center,travel:center.x<0.5 ? 0.12:-0.12)
        phase = .waitingForOpen;quietUntil=lastTime+0.35
        accumulated=0;progress=0;travel=0;previousClosed=false;openSince=nil
        return event
    }
}
