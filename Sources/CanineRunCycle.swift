import Foundation
import simd

/// A four-beat rotary gallop on the original skeleton. Foot trajectories
/// are defined in distance/phase space: during stance dx/dphase == -stride,
/// cancelling forward root travel instead of skating along the ground.
enum CanineRunCycle {
    static let frameCount = 96
    static let stance: Float = 0.26
    static let landingPhase: Float = 0.60
    // Hind left, hind right, front right, front left: two suspension windows.
    static let hindLeftContact: Float = 0
    static let hindRightContact: Float = 0.08
    static let frontRightContact: Float = 0.44
    static let frontLeftContact: Float = 0.52
    static func strideLength(_ m: MorphologyParameters) -> Float {
        1.95 * (m.bodyLength * 0.4 + m.legLength * 0.6)
    }
    static func cycle(_ phase: Float) -> Float { phase - floor(phase) }
    private static func pulse(_ phase:Float,_ start:Float,_ end:Float)->Float {
        let q=(phase-start)/(end-start)
        return q>0 && q<1 ? 64*q*q*q*pow(1-q,3):0
    }
    static func suspension(_ phase:Float) -> Float {
        let p=cycle(phase+landingPhase)
        return 0.04*pulse(p,0.34,0.44)+0.08*pulse(p,0.78,1)
    }
    private static func xyz(_ p: SIMD4<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y, p.z) }
    private static func unit(_ v: SIMD3<Float>) -> SIMD3<Float> { v / max(0.000001, simd_length(v)) }

    struct Footfall {
        let x: Float, lift: Float, pitch: Float, swing: Float
        let grounded: Bool
    }
    static func footfall(phase: Float, stride: Float, lift: Float, gather: Float = 0) -> Footfall {
        let p = cycle(phase)
        if p <= stance {
            return Footfall(x: stride * (stance * 0.5 - p), lift: 0, pitch: 0, swing: 0, grounded: true)
        }
        let q = (p - stance) / (1 - stance), q2 = q*q, q3 = q2*q
        let ease = q3 * (10 + q * (-15 + 6*q))
        // Quintic horizontal return and sixth-order clearance both match the
        // stance velocity/acceleration at toe-off, touchdown, and loop wrap.
        let clearance = 64 * q3 * pow(1-q, 3)
        let x = stride * (-stance*0.5 - (1-stance)*q + ease) + gather*clearance
        let pitch = -0.32 * sin(2 * .pi * q) * pow(sin(.pi*q), 2)
        return Footfall(x: x, lift: lift*clearance, pitch: pitch, swing: clearance, grounded: false)
    }

    static func pose(neutral: [simd_float4x4], parents: [Int], phase: Float,
                     parameters m: MorphologyParameters) -> [simd_float4x4] {
        let phase = cycle(phase), p = cycle(phase + landingPhase)
        let beat = 2 * Float.pi * p, stride = strideLength(m)
        var g = neutral
        // Rear-leg drive, extended suspension, front-leg landing, gathered
        // suspension. The torso rises with propulsion and compresses on contact.
        let rise=0.16*pulse(p,0.12,0.48)+0.13*(pulse(p,0.62,1.06)+pulse(p+1,0.62,1.06))
        let drop = (-0.205 + rise) * m.legLength
        let sway = 0.009 * m.bodyWidth * sin(beat)
        for i in 0..<38 { g[i].columns.3 += SIMD4(0, drop, sway, 0) }
        func point(_ i: Int) -> SIMD3<Float> { xyz(g[i].columns.3) }
        func rotateBranch(_ root: Int, _ angle: Float, _ axis: SIMD3<Float>) {
            let center = point(root)
            var rotation = simd_float4x4(simd_quatf(angle: angle, axis: axis))
            rotation.columns.3 = SIMD4(center - xyz(rotation * SIMD4(center, 0)), 1)
            for i in root..<38 {
                var ancestor = i
                while ancestor >= 0 && ancestor != root { ancestor = parents[ancestor] }
                if ancestor == root { g[i] = rotation * g[i] }
            }
        }
        let reachScale=min(1,m.legLength/m.bodyLength)
        let pitch = 0.035*sin(beat-0.8)*reachScale, spine = 0.14*cos(beat-5.3)*reachScale
        rotateBranch(1, pitch, SIMD3(0,0,1))
        rotateBranch(2, spine, SIMD3(0,0,1))
        rotateBranch(3, -spine*0.5, SIMD3(0,0,1))
        rotateBranch(4, -spine*0.5, SIMD3(0,0,1))
        rotateBranch(1, 0.008*sin(2 * .pi * p), SIMD3(1,0,0))
        rotateBranch(5, -0.07-pitch, SIMD3(0,0,1))
        rotateBranch(8, 0.015*sin(beat-0.8), SIMD3(0,0,1))
        rotateBranch(31, 0.035*sin(2 * .pi * p-0.7), SIMD3(0,1,0))
        rotateBranch(32, 0.024*sin(2 * .pi * p-1.1), SIMD3(0,1,0))
        rotateBranch(9, 0.014*sin(beat-0.7), SIMD3(0,0,1))
        rotateBranch(13, 0.014*sin(beat-0.9), SIMD3(0,0,1))

        func aim(_ matrix: simd_float4x4, _ old: SIMD3<Float>, _ new: SIMD3<Float>, _ origin: SIMD3<Float>) -> simd_float4x4 {
            var result = simd_float4x4(simd_quatf(from: unit(old), to: unit(new))) * matrix
            result.columns.3 = SIMD4(origin, 1)
            return result
        }
        // Anatomical bend directions are explicit, so knees/elbows never flip
        // when a target passes through the limb's nearly straight position.
        func solve(_ upper: Int, _ lower: Int, _ oldEnd: SIMD3<Float>, _ target: SIMD3<Float>, pole: SIMD3<Float>) -> SIMD3<Float> {
            let origin = point(upper), oldBend = point(lower)
            let l1 = simd_length(oldBend-origin), l2 = simd_length(oldEnd-oldBend)
            let direction = unit(target-origin)
            let distance = min(max(simd_length(target-origin), abs(l1-l2)+0.00001), (l1+l2)*0.9995)
            let end = origin + direction*distance
            let bendDirection = unit(pole-direction*simd_dot(pole,direction))
            let along = (l1*l1-l2*l2+distance*distance)/(2*distance)
            let bend = origin + direction*along + bendDirection*sqrt(max(0,l1*l1-along*along))
            g[upper] = aim(g[upper],oldBend-origin,bend-origin,origin)
            g[lower] = aim(g[lower],oldEnd-oldBend,end-bend,bend)
            return end
        }
        func placeFoot(_ foot: Int, _ toe: Int, _ target: SIMD3<Float>, _ pitch: Float) {
            g[foot] = simd_float4x4(simd_quatf(angle: pitch, axis: SIMD3(0,0,1))) * neutral[foot]
            g[foot].columns.3 = SIMD4(target,1)
            g[toe] = g[foot] * simd_inverse(neutral[foot]) * neutral[toe]
        }
        for (shoulder,upper,lower,foot,toe,contact) in [(17,18,19,40,41,frontLeftContact),(20,21,22,44,45,frontRightContact)] {
            let f = footfall(phase: p-contact, stride: stride, lift: 0.34*m.legLength)
            let scapula = 0.05*m.legLength*cos(2 * .pi * (p-contact))
            for j in [shoulder,upper,lower] { g[j].columns.3.x += scapula }
            let oldFoot = xyz(neutral[foot].columns.3)
            let target = oldFoot + SIMD3(f.x,f.lift,0)
            // The neutral foot belongs to an independent IK root; transform its
            // rest endpoint by the lower limb's torso motion before solving.
            let oldEnd = xyz(g[lower] * simd_inverse(neutral[lower]) * SIMD4(oldFoot,1))
            let end = solve(upper,lower,oldEnd,target,pole:SIMD3(-1,0,0))
            placeFoot(foot,toe,end,f.pitch*min(1,m.legLength/m.bodyLength))
        }
        for (hip,knee,hock,foot,toe,contact) in [(24,25,26,38,39,hindLeftContact),(28,29,30,42,43,hindRightContact)] {
            let f = footfall(phase: p-contact, stride: stride, lift: 0.28*m.legLength*reachScale,gather:0.14*m.legLength*reachScale)
            let oldFoot = xyz(neutral[foot].columns.3), target = oldFoot + SIMD3(f.x,f.lift,0)
            let restOffset = xyz(neutral[hock].columns.3)-oldFoot
            let hockRotation = simd_quatf(angle: (0.16*sin(2 * .pi * (p-contact))+0.30*f.swing)*reachScale, axis: SIMD3(0,0,1))
            let hockTarget = target + hockRotation.act(restOffset)
            let oldHock = point(hock)
            let end = solve(hip,knee,oldHock,hockTarget,pole:SIMD3(1,0,0))
            let oldEnd = xyz(g[hock] * simd_inverse(neutral[hock]) * SIMD4(oldFoot,1))
            g[hock] = aim(g[hock],oldEnd-oldHock,target-end,end)
            placeFoot(foot,toe,target,f.pitch*0.65*min(1,m.legLength/m.bodyLength))
        }
        // During the two airborne windows the complete skeleton follows the
        // flight arc, including independent foot roots, preserving every limb.
        let flight=suspension(phase)*m.legLength
        for i in g.indices {g[i].columns.3.y += flight}
        return g
    }
}
