import Foundation
import simd

enum ScreenHighFivePhase:String {
    case idle, approaching, reaching, holding, withdrawing, retreating, cancelling
}

/// A complete, deterministic screen-touch performance. The gait is driven by
/// virtual forward travel as well as screen displacement: running toward the
/// camera must still move all four legs when its screen centre barely moves.
/// Renderer applies scale about the root, before camera projection and depth.
struct ScreenHighFiveController {
    static let frontYaw:Float = -.pi/2
    static let approachDuration:Float = 1.30
    static let pawDuration:Float = 2.40
    static let retreatDuration:Float = 1.45
    static let contactTime:Float = 1.05
    private(set) var phase:ScreenHighFivePhase = .idle
    private(set) var position=SIMD2<Float>.zero
    private(set) var yaw:Float = frontYaw
    private(set) var scale:Float = 1
    private(set) var forwardSpeed:Float = 0
    private(set) var runWeight:Float = 0
    private(set) var clipTime:Float = 0
    private(set) var clipWeight:Float = 0
    private(set) var contactAge:Float = 10
    private(set) var contactCount=0
    private(set) var completedCount=0
    private(set) var time:Float = 0
    var active:Bool {phase != .idle}
    var usesClip:Bool {clipWeight>0.0001}
    var hint:String? {
        switch phase {
        case .idle:return nil
        case .approaching:return "Here I come"
        case .reaching:return "Paw up · Ready for you"
        case .holding:return "High five!"
        case .withdrawing,.retreating,.cancelling:return "Heading back"
        }
    }
    private var start=SIMD2<Float>.zero,contact=SIMD2<Float>.zero
    private var startYaw:Float=frontYaw,front:Float=frontYaw
    private var contacted=false
    private(set) var travelledDistance:Float=0
    private var pathDistance:Float=2.9,arrivalDuration:Float=1.3,returnDuration:Float=1.45
    private var returnYaw:Float=0

    private var cancelPosition=SIMD2<Float>.zero,cancelVelocity=SIMD2<Float>.zero
    private var cancelScale:Float=1,cancelScaleVelocity:Float=0,cancelYaw:Float=frontYaw,cancelYawVelocity:Float=0
    private var cancelClipWeight:Float=0,cancelRunWeight:Float=0
    private var positionVelocity=SIMD2<Float>.zero,scaleVelocity:Float=0,yawVelocity:Float=0
    private let closeScale:Float=1.55
    static let pawPlaybackRate:Float=1.62
    private let cancelDuration:Float=0.90

    @discardableResult mutating func request(position:SIMD2<Float>,yaw:Float,height:Float,strideLength:Float=1.45)->Bool {
        guard !active,position.x.isFinite,position.y.isFinite,yaw.isFinite,height.isFinite,height>0 else{return false}
        start=position;self.position=position;startYaw=yaw;self.yaw=yaw
        front=yaw+atan2(sin(Self.frontYaw-yaw),cos(Self.frontYaw-yaw))
        contact=SIMD2(0,-min(2.25,max(1.35,height*0.66)))
        let stride=max(0.35,strideLength)
        pathDistance=ceil(sqrt(pow(simd_length(contact-start),2)+2.35*2.35)/stride)*stride
        arrivalDuration=max(Self.approachDuration,pathDistance/(3.4*0.78))
        returnDuration=max(Self.retreatDuration,pathDistance/(3.1*0.78))
        let away=atan2(2.35,start.x-contact.x)
        returnYaw=front+atan2(sin(away-front),cos(away-front))
        travelledDistance=0
        scale=1;runWeight=0;forwardSpeed=0;clipTime=0;clipWeight=0;time=0
        contactAge=10;contacted=false;positionVelocity = .zero;scaleVelocity=0;yawVelocity=0
        phase = .approaching;return true
    }
    mutating func update(dt raw:Float) {
        travelledDistance=0
        guard raw.isFinite,raw>0 else{return}
        // Fixed small integration chunks make low/high refresh-rate behaviour
        // equivalent and avoid skipping the single contact event after a stall.
        var remaining=min(raw,0.25)
        while remaining>0.000001 {
            let dt=min(remaining,1/120 as Float);remaining-=dt;step(dt:dt)
        }
    }
    private mutating func step(dt:Float) {
        contactAge=min(10,contactAge+dt)
        guard active else{return}
        let before=position,beforeScale=scale,beforeYaw=yaw
        time+=dt
        switch phase {
        case .idle:break
        case .approaching:
            let u=min(1,time/arrivalDuration),q=Self.travel(u)
            let oldQ=Self.travel(max(0,(time-dt)/arrivalDuration))
            position=simd_mix(start,contact,SIMD2(repeating:q))
            scale=1+(closeScale-1)*q
            yaw=startYaw+(front-startYaw)*Self.smooth(time/0.55)
            let distance=(q-oldQ)*pathDistance;travelledDistance+=distance;forwardSpeed=distance/dt
            runWeight=Self.smooth(time/0.18)*(1-Self.smooth((u-0.87)/0.13))
            if u>=1 {phase = .reaching;time=0;position=contact;yaw=front;scale=closeScale;forwardSpeed=0;runWeight=0}
        case .reaching,.holding,.withdrawing:
            clipTime=min(Self.pawDuration,time*Self.pawPlaybackRate)
            clipWeight=Self.smooth(clipTime/0.22)*(1-Self.smooth((clipTime-(Self.pawDuration-0.22))/0.22))
            // The original skeleton supplies the entire reach and recoil. Do
            // not move the root at contact: the pad should feel pinned to glass.
            position=contact;yaw=front;scale=closeScale;forwardSpeed=0;runWeight=0
            if !contacted && clipTime>=Self.contactTime {contacted=true;contactCount+=1;contactAge=0}
            phase=clipTime<1.02 ? .reaching:(clipTime<1.40 ? .holding:.withdrawing)
            if clipTime>=Self.pawDuration {phase = .retreating;time=0;clipWeight=0}
        case .retreating:
            let u=min(1,time/returnDuration),q=Self.travel(u)
            let oldQ=Self.travel(max(0,(time-dt)/returnDuration))
            // Turn on a moving arc, then run forwards away from the screen.
            let bend=sin(Float.pi*q)*0.16
            position=simd_mix(contact,start,SIMD2(repeating:q))+SIMD2(bend*(start.x>=0 ? 1:-1),0)
            scale=closeScale-(closeScale-1)*q
            yaw=front+(returnYaw-front)*Self.smooth(time/0.62)
            let distance=(q-oldQ)*pathDistance;travelledDistance+=distance;forwardSpeed=distance/dt
            runWeight=Self.smooth(time/0.20)*(1-Self.smooth((u-0.87)/0.13))
            if u>=1 {completedCount+=1;finish()}
        case .cancelling:
            let u=min(1,time/cancelDuration)
            position=Self.hermite(cancelPosition,cancelVelocity*cancelDuration,start,u)
            scale=Self.hermite(cancelScale,cancelScaleVelocity*cancelDuration,1,u)
            yaw=Self.hermite(cancelYaw,cancelYawVelocity*cancelDuration,front,u)
            clipTime=min(Self.pawDuration,clipTime+dt)
            let fade=1-Self.smooth(u)
            clipWeight=cancelClipWeight*fade;runWeight=cancelRunWeight*fade
            let distance=sqrt(simd_length_squared(position-before)+pow((scale-beforeScale)*2.35/0.55,2))
            travelledDistance+=distance;forwardSpeed=distance/dt
            if u>=1 {finish()}
        }
        positionVelocity=(position-before)/dt;scaleVelocity=(scale-beforeScale)/dt;yawVelocity=(yaw-beforeYaw)/dt
    }
    mutating func cancel(immediately:Bool=false) {
        guard active else{return}
        if immediately {finish();return}
        guard phase != .cancelling else{return}
        cancelPosition=position;cancelVelocity=positionVelocity
        cancelScale=scale;cancelScaleVelocity=scaleVelocity;cancelYaw=yaw;cancelYawVelocity=yawVelocity
        cancelClipWeight=clipWeight;cancelRunWeight=runWeight;phase = .cancelling;time=0
    }
    private mutating func finish(){phase = .idle;position=start;scale=1;runWeight=0;forwardSpeed=0;clipWeight=0;clipTime=0;time=0;positionVelocity = .zero;scaleVelocity=0;yawVelocity=0}
    // Integrated smooth acceleration / cruise / braking: bounded peak speed,
    // unlike a compressed whole-path quintic with a large mid-run surge.
    private static func travel(_ x:Float)->Float {
        let t=min(1,max(0,x)),r:Float=0.22
        if t<r {let u=t/r;return r*(u*u*u-0.5*u*u*u*u)/(1-r)}
        if t>1-r{return 1-travel(1-t)}
        return (t-r*0.5)/(1-r)
    }
    private static func smooth(_ x:Float)->Float {let t=min(1,max(0,x));return min(1,max(0,t*t*t*(t*(t*6-15)+10)))}
    private static func derivative(_ t:Float)->Float {30*t*t*(1-t)*(1-t)}
    private static func hermite(_ a:Float,_ v:Float,_ b:Float,_ t:Float)->Float {
        let t2=t*t,t3=t2*t;return (2*t3-3*t2+1)*a+(t3-2*t2+t)*v+(-2*t3+3*t2)*b
    }
    private static func hermite(_ a:SIMD2<Float>,_ v:SIMD2<Float>,_ b:SIMD2<Float>,_ t:Float)->SIMD2<Float> {
        SIMD2(hermite(a.x,v.x,b.x,t),hermite(a.y,v.y,b.y,t))
    }
}
