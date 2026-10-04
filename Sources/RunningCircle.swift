import Foundation
import simd

enum RunningCirclePhase:String {case idle,entering,running,returning,cancelling}
/// A complete travelling loop in a shallow ground plane. Yaw follows the 3D
/// tangent and gait follows measured distance; there is no stationary spin.
struct RunningCircleController {
    private(set) var phase:RunningCirclePhase = .idle
    private(set) var position=SIMD2<Float>.zero
    private(set) var yaw:Float=0
    private(set) var speed:Float=0
    private(set) var travelledDistance:Float=0
    private(set) var runWeight:Float=0
    private(set) var scale:Float=1
    private(set) var completedCount=0
    private(set) var progress:Float=0
    private var start=SIMD2<Float>.zero,centre=SIMD2<Float>.zero,entry=SIMD2<Float>.zero
    private var initialYaw:Float=0,entryYaw:Float=0,theta0:Float=0,time:Float=0
    private var rx:Float=1.6,ry:Float=0.42,entryDuration:Float=0,returnDuration:Float=0
    private var cancelStart=SIMD2<Float>.zero,cancelVelocity=SIMD2<Float>.zero,velocity=SIMD2<Float>.zero
    private var cancelWeight:Float=0,cancelYaw:Float=0,cancelScale:Float=1
    static let lapDuration:Float=3.1
    var active:Bool {phase != .idle}
    var hint:String? {active ? "One happy lap, then back to you":nil}
    @discardableResult mutating func request(position:SIMD2<Float>,yaw:Float,worldSize:SIMD2<Float>,radius:Float,height:Float)->Bool {
        guard !active,position.x.isFinite,position.y.isFinite,yaw.isFinite else{return false}
        start=position;self.position=position;initialYaw=yaw;self.yaw=yaw
        let lo=SIMD2<Float>(-max(0.15,worldSize.x/2-radius-0.18),-worldSize.y/2+0.18)
        let hi=SIMD2<Float>(-lo.x,max(lo.y+0.3,worldSize.y/2-height-0.2))
        rx=min(1.65,max(0.12,(hi.x-lo.x)*0.42));ry=min(0.46,max(0.07,(hi.y-lo.y)*0.32))
        var best:Float = .infinity
        // Select the legal tangent entry closest to the current position and
        // heading. At a corner we run a short approach to the nearest loop.
        for index in 0..<144 {
            let theta=Float(index)/144*2 * .pi
            let offset=SIMD2(rx*cos(theta),ry*sin(theta))
            let c=simd_clamp(start-offset,lo+SIMD2(rx,ry),hi-SIMD2(rx,ry))
            let p=c+offset,targetYaw = -theta - .pi/2
            let heading=atan2(sin(targetYaw-yaw),cos(targetYaw-yaw))
            let cost=simd_distance(p,start)*5+abs(heading)*0.10
            if cost<best{best=cost;centre=c;entry=p;theta0=theta;entryYaw=yaw+heading}
        }
        entryDuration=simd_distance(entry,start)>0.012 ? max(0.42,simd_distance(entry,start)/2.5):0
        returnDuration=entryDuration>0 ? max(0.62,entryDuration):0
        time=0;progress=0;speed=0;travelledDistance=0;runWeight=0;scale=1;velocity = .zero
        phase=entryDuration>0 ? .entering:.running;return true
    }
    mutating func update(dt raw:Float){
        travelledDistance=0;guard raw.isFinite,raw>0 else{return}
        var left=min(raw,0.25)
        while left>0.000001 {let dt=min(left,1/120 as Float);left-=dt;step(dt)}
    }
    private mutating func step(_ dt:Float){
        guard active else{speed=0;return}
        let old=position;time+=dt
        switch phase {
        case .idle:break
        case .entering:
            let u=min(1,time/entryDuration),q=Self.ease(u)
            position=simd_mix(start,entry,SIMD2(repeating:q));yaw=initialYaw+(entryYaw-initialYaw)*Self.ease(u)
            speed=simd_distance(position,old)/dt;travelledDistance+=simd_distance(position,old)
            runWeight=Self.ease(time/0.15)*(1-Self.ease((u-0.80)/0.20))*0.9
            if u>=1{position=entry;initialYaw=entryYaw;phase = .running;time=0}
        case .running:
            let u=min(1,time/Self.lapDuration),q=Self.lapEase(u)
            let theta=theta0+q*2 * .pi
            position=centre+SIMD2(rx*cos(theta),ry*sin(theta))
            // Ground depth is compressed into the screen's vertical dimension.
            // Measure the uncompacted arc so paws never slide through the lap.
            let dx=position.x-old.x,dz=(position.y-old.y)*rx/max(0.05,ry)
            let distance=sqrt(dx*dx+dz*dz);travelledDistance+=distance;speed=distance/dt
            let offset=entryYaw-initialYaw
            yaw=entryYaw-q*2 * .pi-offset*(1-Self.ease(time/0.55))
            runWeight=Self.ease(time/0.20)*(1-Self.ease((time-(Self.lapDuration-0.26))/0.26))
            scale=1+sin(theta)*0.035-sin(theta0)*0.035;progress=q
            if u>=1 {
                position=entry;scale=1;runWeight=0;speed=0
                if returnDuration>0{phase = .returning;time=0}else{finish(completed:true)}
            }
        case .returning:
            let u=min(1,time/returnDuration),q=Self.ease(u)
            position=simd_mix(entry,start,SIMD2(repeating:q))
            let delta=start-entry
            let heading=abs(delta.x)>0.01 ? (delta.x>=0 ? Float(0):Float.pi):entryYaw
            let direction=entryYaw+atan2(sin(heading-entryYaw),cos(heading-entryYaw))
            yaw=entryYaw+(direction-entryYaw)*Self.ease(u)-2 * .pi
            speed=simd_distance(position,old)/dt;travelledDistance+=simd_distance(position,old)
            runWeight=Self.ease(time/0.16)*(1-Self.ease((u-0.80)/0.20))*0.85
            if u>=1{finish(completed:true)}
        case .cancelling:
            let u=min(1,time/0.65),q=Self.ease(u)
            let t2=u*u,t3=t2*u
            position=(2*t3-3*t2+1)*cancelStart+(t3-2*t2+u)*cancelVelocity*0.65+(-2*t3+3*t2)*start
            yaw=cancelYaw;runWeight=cancelWeight*(1-q);scale=1+(cancelScale-1)*(1-q)
            speed=simd_distance(position,old)/dt;travelledDistance+=simd_distance(position,old)
            if u>=1{finish(completed:false)}
        }
        velocity=(position-old)/dt
    }
    mutating func cancel(immediately:Bool=false){
        guard active else{return}
        if immediately{finish(completed:false);return}
        guard phase != .cancelling else{return}
        cancelStart=position;cancelVelocity=velocity;cancelWeight=runWeight;cancelYaw=yaw;cancelScale=scale;time=0;phase = .cancelling
    }
    private mutating func finish(completed:Bool){
        if completed{completedCount+=1;progress=1}
        position=start;scale=1;phase = .idle;runWeight=0;speed=0;velocity = .zero;time=0
    }
    private static func lapEase(_ t:Float)->Float {
        let ramp:Float=0.12
        if t<ramp{let x=t/ramp;return ramp*(x*x*x-0.5*x*x*x*x)/(1-ramp)}
        if t>1-ramp{return 1-lapEase(1-t)}
        return (t-ramp*0.5)/(1-ramp)
    }
    private static func ease(_ x:Float)->Float{let t=min(1,max(0,x));return min(1,max(0,t*t*t*(t*(t*6-15)+10)))}
}
