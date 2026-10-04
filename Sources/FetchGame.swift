import Foundation
import simd

/// Ball physics and the ordered fetch performance. Pose sampling and mouth
/// attachment are supplied by the renderer, so the ball follows the real skin.
final class FetchGame {
    enum Phase:String {case idle,chasing,settling,pickup,returning}
    private(set) var phase:Phase = .idle
    private(set) var age:Float=0
    private(set) var ball=SIMD3<Float>.zero
    private(set) var ballVelocity=SIMD2<Float>.zero
    private(set) var radius:Float=0.12
    private(set) var ground:Float = -1.55
    private(set) var visible=false,held=false
    private(set) var completed=0,throwCount=0
    private(set) var contactEvents=0,releaseEvents=0
    private(set) var spin:Float=0
    private(set) var home=SIMD2<Float>.zero
    private var pickupMouth=SIMD3<Float>(1.6,0.12,0),direction:Float=1
    private var bounds=(SIMD2<Float>(-3,-3),SIMD2<Float>(3,1))
    private var resting:Float=0,bounces=0
    private var landingRoot:Float=0,flightDuration:Float=1
    private var lastMouth=SIMD3<Float>.zero,blendFrom=SIMD3<Float>.zero,attachAge:Float=0
    var active:Bool{phase != .idle}
    var poseActive:Bool{phase == .pickup}
    var clipTime:Float{min(1.8,age)}
    var desiredYaw:Float? {
        if phase == .chasing || phase == .settling || phase == .pickup {return direction>0 ? -0.22:-Float.pi+0.22}
        return nil
    }
    var target:SIMD2<Float>? {
        switch phase {
        case .chasing,.settling:
            if bounces==0 && age<flightDuration*0.80 {return SIMD2(landingRoot,ground)}
            let projected=ball.x+ballVelocity.x*0.12
            return SIMD2(min(bounds.1.x,max(bounds.0.x,projected-pickupMouth.x*direction)),ground)
        case .returning:return home
        default:return nil
        }
    }
    var freezesBody:Bool{phase == .pickup}
    var hint:String {
        switch phase {
        case .idle:return "Throw a ball"
        case .chasing:return "Go get it!"
        case .settling,.pickup:return "Picking it up"
        case .returning:return "Bringing it back"
        }
    }
    func reset(){phase = .idle;age=0;held=false;visible=false;ballVelocity = .zero;resting=0}
    @discardableResult func launch(root:SIMD2<Float>,bounds newBounds:(SIMD2<Float>,SIMD2<Float>),contact:SIMD3<Float>,radius newRadius:Float,height:Float,handOrigin:SIMD2<Float>? = nil,handTravel:Float = 0)->Bool {
        guard !active else{return false}
        bounds=newBounds;home=simd_min(bounds.1,simd_max(bounds.0,root));ground=home.y;radius=newRadius
        pickupMouth=contact;pickupMouth.x=abs(contact.x)*cos(0.22)
        let right=bounds.1.x-home.x,left=home.x-bounds.0.x
        direction=abs(right-left)<0.2 ? (throwCount%2==0 ? 1:-1):(right>left ? 1:-1)
        var destinationRoot=direction>0 ? bounds.1.x-0.08:bounds.0.x+0.08
        if let origin=handOrigin {
            let sign:Float=handTravel >= 0 ? 1:-1
            let distance=min(5.5,max(1.4,abs(handTravel)*22))
            let landing=min(bounds.1.x+pickupMouth.x-0.08,max(bounds.0.x-pickupMouth.x+0.08,origin.x+sign*distance))
            // Approach the landing spot from the dog's side, independently of
            // the hand's throw direction, so every landing stays reachable.
            direction=landing >= home.x ? 1:-1
            destinationRoot=min(bounds.1.x-0.08,max(bounds.0.x+0.08,landing-pickupMouth.x*direction))
        }
        landingRoot=destinationRoot
        let landing=destinationRoot+pickupMouth.x*direction
        ball=SIMD3(home.x-direction*min(0.3,height*0.12),ground+height*0.62,0.1)
        if let origin=handOrigin {
            ball=SIMD3(origin.x,max(ground+radius,origin.y),0.1)
        }
        // Extra flight time for a high hand avoids a downward launch impulse.
        let fallTime=sqrt(max(0,2*(ball.y-ground-radius)/9))
        let duration=handOrigin == nil ? min(1.2,max(0.78,abs(landing-ball.x)/5))
            : min(1.7,max(fallTime+0.15,max(0.78,abs(landing-ball.x)/5)))
        flightDuration=duration
        ballVelocity=SIMD2((landing-ball.x)/duration,(ground+radius-ball.y+4.5*duration*duration)/duration)
        phase = .chasing;age=0;resting=0;held=false;visible=true;throwCount+=1;bounces=0;attachAge=0
        return true
    }
    private func transition(_ next:Phase){phase=next;age=0;resting=0}
    func update(dt raw:Float,root:SIMD2<Float>,speed:Float,yaw:Float,reactionReady:Bool){
        guard raw.isFinite,raw>0,active else{return};let dt=min(1/15,raw);age+=dt
        if phase == .chasing || phase == .settling {
            let steps=max(1,Int(ceil(dt*120))),h=dt/Float(steps)
            for _ in 0..<steps {
                ballVelocity.y-=9*h;ball.x+=ballVelocity.x*h;ball.y+=ballVelocity.y*h
                let minX=bounds.0.x+pickupMouth.x*direction,maxX=bounds.1.x+pickupMouth.x*direction
                if (bounces>0 || ball.y<ground+radius) && (ball.x<minX || ball.x>maxX) {ball.x=min(maxX,max(minX,ball.x));ballVelocity.x *= -0.22}
                if ball.y<ground+radius {
                    ball.y=ground+radius
                    if abs(ballVelocity.y)>0.65 && bounces<3 {ballVelocity.y = abs(ballVelocity.y)*0.34;ballVelocity.x *= 0.67;bounces+=1}
                    else{ballVelocity.y=0;ballVelocity.x *= exp(-h*8)}
                }
                spin+=ballVelocity.x/radius*h
            }
            if abs(ballVelocity.x)<0.05 && abs(ballVelocity.y)<0.08{ballVelocity = .zero}
            let desired=target ?? root,angle=desiredYaw ?? yaw
            let facingError=abs(atan2(sin(angle-yaw),cos(angle-yaw)))
            if simd_distance(desired,root)<0.11 && speed<0.10 && simd_length(ballVelocity)<0.12 && facingError<0.08 {
                if phase == .chasing {transition(.settling)}
                resting+=dt
                if resting>0.16 && reactionReady {transition(.pickup)}
            }else if phase == .settling {transition(.chasing)}
        }else if phase == .pickup {
            if age>=0.84 && !held {held=true;blendFrom=ball;attachAge=0;contactEvents+=1}
            if age>=1.82 {transition(.returning)}
        }else if phase == .returning {
            if simd_distance(root,home)<0.10 && speed<0.09 && reactionReady {
                // Arrival completes delivery in this frame: no lingering ball or
                // put-down delay before the next button/gesture throw is available.
                held=false;visible=false;ballVelocity = .zero
                releaseEvents+=1;completed+=1;transition(.idle)
            }
        }
    }

    /// Called after pose/heading integration. The held ball never lags behind
    /// the muzzle during the turn back, locomotion or lowering it to the floor.
    func attach(to mouth:SIMD3<Float>,dt:Float){
        lastMouth=mouth
        if held {
            attachAge+=dt;let t=min(1,attachAge/0.08),s=t*t*(3-2*t)
            ball=blendFrom+(mouth-blendFrom)*s
        }
    }
}
