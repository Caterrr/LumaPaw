import Foundation

/// Screen-plane pursuit. Reversals take a short curved step while the displayed
/// body changes facing, so normal pursuit never parks to pivot in place.
final class Pursuit {
    var position = SIMD2<Float>(-0.5, -1.3)
    var velocity = SIMD2<Float>.zero
    var yaw: Float = -0.22
    private(set) var runBlend: Float = 0
    /// Turn intensity for the moving trajectory; gait uses travelledDistance.
    private(set) var turnBlend: Float = 0
    /// A complete original-rig running cycle covers exactly `strideLength`.
    private(set) var phase: Float = 0
    /// Actual root distance this update, after bounds, for the renderer's gait.
    private(set) var travelledDistance: Float = 0
    private(set) var state = "idle"

    private(set) var maxSpeed: Float = 3.4
    private var acceleration: Float { maxSpeed * 2.4 }
    private var braking: Float { maxSpeed * 3.6 }
    private(set) var noseHeight: Float = 2.33
    private(set) var noseReach: Float = 1.82
    private(set) var horizontalRadius: Float = 2.3
    private(set) var height: Float = 3.05
    private(set) var strideLength: Float = 1.45
    private let arrivalRadius: Float = 0.07
    private var resumeRadius: Float { max(0.45, strideLength * 0.45) }
    /// True only for a normal, complete-stride arrival. Emergency stops still
    /// let the renderer finish their feet without moving outside the window.
    private(set) var strideStopped = false
    private var strideRemaining: Float = 0
    private var strideDirection = SIMD2<Float>(1, 0)
    private var strideTarget: SIMD2<Float>?
    func synchronizeGait(to value: Float) {
        if value.isFinite { phase = (value - floor(value)) }
    }
    private var facing: Float = 1
    private var headingVelocity: Float = 0
    private var filteredTarget: SIMD2<Float>?
    private var heldTarget: SIMD2<Float>?
    private var holding = false

    /// The displayed form's measured bounds and stride remain authoritative.
    func setMorphology(noseHeight: Float, noseReach: Float, horizontalRadius: Float,
                       height: Float, strideLength: Float, maxSpeed: Float? = nil) {
        func positive(_ value: Float, previous: Float, lower: Float = 0.05) -> Float {
            value.isFinite && value >= lower ? min(value, 12) : previous
        }
        self.noseHeight = positive(noseHeight, previous: self.noseHeight)
        self.noseReach = positive(noseReach, previous: self.noseReach)
        self.horizontalRadius = max(self.noseReach + 0.05,
                                    positive(horizontalRadius, previous: self.horizontalRadius))
        self.height = max(self.noseHeight + 0.05, positive(height, previous: self.height))
        self.strideLength = positive(strideLength, previous: self.strideLength, lower: 0.1)
        if let maxSpeed, maxSpeed.isFinite, maxSpeed >= 0.1 {
            self.maxSpeed = min(maxSpeed, 6)
            let speed = magnitude(velocity)
            if speed > self.maxSpeed { velocity *= self.maxSpeed / speed }
        }
        heldTarget = nil; holding = false; strideRemaining = 0; strideStopped = false
    }

    func update(dt: Float, target: SIMD2<Float>?, touching: Bool,
                worldSize: SIMD2<Float>, targetOffset: SIMD3<Float>? = nil, continuous: Bool = false, gentleTurns: Bool = false, pace: Float = 1) {
        travelledDistance = 0
        guard dt.isFinite, dt > 0 else { return }
        let elapsed = min(dt, 0.25)
        let steps = max(1, Int(ceil(elapsed / (1.0 / 120.0))))
        let step = elapsed / Float(steps)
        let validTarget = target.flatMap { isFinite($0) ? $0 : nil }
        let validOffset = targetOffset.flatMap {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite ? $0 : nil
        }
        let size = SIMD2<Float>(
            worldSize.x.isFinite ? max(0.1, worldSize.x) : 10,
            worldSize.y.isFinite ? max(0.1, worldSize.y) : 7
        )
        if !isFinite(position) { position = SIMD2<Float>(-0.5, -1.3) }
        if !isFinite(velocity) { velocity = .zero }
        if !yaw.isFinite { yaw = -0.22 }
        // A resized window/form may move the legal root range. That necessary
        // boundary correction is not walking and must not advance the gait.
        position = clamped(position, rootBounds(size))
        if continuous { holding=false;heldTarget=nil;strideRemaining=0;strideStopped=false }
        if validTarget == nil || touching {
            filteredTarget = nil; heldTarget = nil; holding = false; strideRemaining = 0; strideStopped = false
        }
        for _ in 0..<steps {
            integrate(dt: step, target: validTarget, touching: touching, size: size, targetOffset: validOffset, continuous: continuous, gentleTurns: gentleTurns, pace: pace)
        }
    }

    private func integrate(dt: Float, target: SIMD2<Float>?, touching: Bool,
                           size: SIMD2<Float>, targetOffset: SIMD3<Float>?, continuous: Bool, gentleTurns: Bool, pace: Float) {
        let previousPosition = position, bounds = rootBounds(size)
        var desiredVelocity = SIMD2<Float>.zero
        var finishing = false
        let completeStride = targetOffset == nil && !continuous
        if let target, !touching {
            filteredTarget = filteredTarget.map { $0 + (target-$0)*(1-exp(-24*dt)) } ?? target
        }
        if let finger=filteredTarget, target != nil, !touching {
            // A stride stop belongs to the pointer location that requested it.
            // Retarget without zeroing velocity or phase when that location is
            // no longer current; otherwise we stop and reaccelerate mid-chase.
            if completeStride, strideRemaining>0, let committed=strideTarget,
               let latest=target, magnitude(latest-committed)>resumeRadius {
                strideRemaining=0;strideTarget=nil;strideStopped=false
            }
            if holding, let heldTarget, magnitude(finger-heldTarget)>(gentleTurns ? 0.04:resumeRadius) {
                holding=false;self.heldTarget=nil;strideStopped=false
            }
            if !holding {
                let delta: SIMD2<Float>
                if let offset=targetOffset {
                    let direction:Float=finger.x-position.x >= 0 ? 1:-1
                    let angle:Float=direction>0 ? -0.22 : -.pi+0.22
                    let goal=clamped(finger-SIMD2(offset.x*cos(angle)+offset.z*sin(angle),offset.y),bounds)
                    delta=goal-position
                } else {
                    // A radial nose-reach zone replaces separate X/Y offsets.
                    // Both coordinates travel together along the pointer ray.
                    let ray=finger-(position+SIMD2(0,noseHeight))
                    let distance=magnitude(ray)
                    delta=distance>0.00001 ? ray/distance*max(0,distance-noseReach):.zero
                }
                let distance=magnitude(delta),speed=magnitude(velocity)
                // Steering remains filtered, but filter lag must not commit a
                // stop after the actual pointer has already moved farther away.
                let latestDistance=completeStride ? max(0,magnitude((target ?? finger)-(position+SIMD2(0,noseHeight)))-noseReach):distance
                if strideRemaining>0 && completeStride {
                    finishing=true;desiredVelocity=strideDirection*maxSpeed
                } else if !continuous && distance<arrivalRadius && (!completeStride || speed<0.025) {
                    holding=true;heldTarget=finger
                } else {
                    let direction=distance>0.00001 ? delta/distance :
                        (speed>0.001 ? velocity/speed:SIMD2(facing,0))
                    if completeStride {
                        desiredVelocity=direction*maxSpeed
                        let nextLanding=max(0.001,(1-phase)*strideLength)
                        if max(distance,latestDistance)<=nextLanding+arrivalRadius {
                            strideRemaining=nextLanding;strideDirection=direction
                            strideTarget=target ?? finger;finishing=true
                        }
                    } else {
                        let desiredSpeed=continuous ? maxSpeed:min(maxSpeed,sqrt(2*braking*0.86*max(0,distance-arrivalRadius*0.5)))
                        desiredVelocity=direction*desiredSpeed*min(1,max(0.3,pace))
                    }
                }
            }
            state=holding ? "arrived":(finishing ? "finishingStride":"following")
        } else {
            state=touching ? "touching":(magnitude(velocity)>0.025 ? "stopping":"idle")
        }

        let desiredSpeed=magnitude(desiredVelocity),oldSpeed=magnitude(velocity)
        if desiredSpeed>0.00001 {
            let desiredDirection=desiredVelocity/desiredSpeed
            var direction=desiredDirection
            if oldSpeed>0.05 {
                let oldDirection=velocity/oldSpeed
                var angle=atan2(oldDirection.x*desiredDirection.y-oldDirection.y*desiredDirection.x,
                                dot(oldDirection,desiredDirection))
                if abs(angle)>Float.pi-0.01 {
                    // A full reversal follows a small moving arc into free space.
                    let vertical:Float=bounds.1.y-position.y>=position.y-bounds.0.y ? 1:-1
                    angle=Float.pi*(oldDirection.x>=0 ? vertical:-vertical)
                }
                angle=clamp(angle,-12*dt,12*dt)
                direction=SIMD2(oldDirection.x*cos(angle)-oldDirection.y*sin(angle),
                                oldDirection.x*sin(angle)+oldDirection.y*cos(angle))
            }
            let rate:Float=desiredSpeed<oldSpeed ? braking:acceleration
            let speed=oldSpeed+clamp(desiredSpeed-oldSpeed,-rate*dt,rate*dt)
            velocity=direction*speed
        } else {
            velocity=movedToward(velocity,.zero,braking*dt)
            if magnitude(velocity)<0.025 {velocity = .zero}
        }
        // Heading follows the moving trajectory without owning its translation.
        // In particular, turning never zeroes X or postpones Y movement.
        let speed=magnitude(velocity)
        if speed>0.025 {
            let horizontal=desiredSpeed>0.01 ? desiredVelocity.x/desiredSpeed:velocity.x/speed
            if abs(horizontal)>0.12 {facing=horizontal>0 ? 1:-1}
            let desiredYaw:Float=facing>0 ? -0.22:-.pi+0.22
            let angle=shortestAngle(desiredYaw-yaw)
            let limit:Float=gentleTurns ? 5.5:14,force:Float=gentleTurns ? 34:100
            let angularAcceleration=clamp(324*angle-36*headingVelocity,-force,force)
            headingVelocity=clamp(headingVelocity+angularAcceleration*dt,-limit,limit)
            let rotation=headingVelocity*dt
            if abs(rotation)>abs(angle) && rotation*angle>0 {yaw=desiredYaw;headingVelocity=0}
            else {yaw=shortestAngle(yaw+rotation)}
            turnBlend += ((abs(angle)>0.02 ? Float(1):0)-turnBlend)*(1-exp(-16*dt))
        } else {turnBlend *= exp(-16*dt);headingVelocity *= exp(-20*dt)}
        var step=velocity*dt
        if finishing && magnitude(step)>strideRemaining {step *= strideRemaining/magnitude(step)}
        position += step
        let bounded=clamped(position,bounds),hitBoundary=bounded.x != position.x || bounded.y != position.y
        position=bounded
        let travelled=magnitude(position-previousPosition)
        phase=(phase+travelled/strideLength).truncatingRemainder(dividingBy:1)
        if finishing {strideRemaining=max(0,strideRemaining-travelled)}
        if (finishing && strideRemaining<0.00001) || hitBoundary {
            strideStopped = !hitBoundary
            if strideStopped {phase=0}
            strideRemaining=0;holding=true;heldTarget=finishing ? (strideTarget ?? filteredTarget):filteredTarget
            velocity = .zero;state="arrived"
        }
        if target == nil && !touching && magnitude(velocity)==0 {state="idle"}
        let targetBlend=clamp(magnitude(velocity)/maxSpeed,0,1)
        runBlend += (targetBlend-runBlend)*(1-exp(-12*dt))
        if runBlend<0.003 && targetBlend==0 {runBlend=0}
        travelledDistance += travelled
    }

    func rootBounds(_ size: SIMD2<Float>) -> (SIMD2<Float>, SIMD2<Float>) {
        let half = size * 0.5
        var lower = SIMD2<Float>(-half.x + horizontalRadius, -half.y + 0.12)
        var upper = SIMD2<Float>(half.x - horizontalRadius, half.y - height)
        if lower.x > upper.x { lower.x = 0; upper.x = 0 }
        if lower.y > upper.y {
            let centre = (lower.y + upper.y) * 0.5
            lower.y = centre; upper.y = centre
        }
        return (lower, upper)
    }
    private func clamped(_ value: SIMD2<Float>, _ bounds: (SIMD2<Float>, SIMD2<Float>)) -> SIMD2<Float> {
        SIMD2<Float>(clamp(value.x, bounds.0.x, bounds.1.x), clamp(value.y, bounds.0.y, bounds.1.y))
    }
    private func movedToward(_ value: SIMD2<Float>, _ target: SIMD2<Float>, _ distance: Float) -> SIMD2<Float> {
        let delta = target - value, length = magnitude(delta)
        return length <= distance ? target : value + delta * (distance / length)
    }
    private func shortestAngle(_ angle: Float) -> Float { atan2(sin(angle), cos(angle)) }
    private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float { min(upper, max(lower, value)) }
    private func magnitude(_ vector: SIMD2<Float>) -> Float { sqrt(dot(vector, vector)) }
    private func dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.x + a.y * b.y }
    private func isFinite(_ vector: SIMD2<Float>) -> Bool { vector.x.isFinite && vector.y.isFinite }
}
