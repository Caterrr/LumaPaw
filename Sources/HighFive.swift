import Foundation

enum HighFivePhase: String {
    case idle, approaching, gesture, settling
}

/// A single confirmed approach event owns one attempt. Camera gesture detection
/// owns rearming after retreat; this controller owns motion, contact, and recovery.
/// No camera, renderer, or wall clock is accessed here.
struct HighFiveController {
    private(set) var phase: HighFivePhase = .idle
    private(set) var target = SIMD2<Float>.zero
    private(set) var animationTime: Float = 0
    private(set) var contactFired = false
    private(set) var completedCount = 0
    private(set) var flashAge: Float = 10
    private(set) var flashPoint = SIMD2<Float>.zero

    var active: Bool { phase != .idle }
    var usesClip: Bool { phase == .gesture || phase == .settling }
    var wantsClipWeight: Bool { phase == .gesture }

    private var cancelled = false
    private var approachElapsed: Float = 0
    private var missingElapsed: Float = 0
    private var contactObservations = 0
    private var lastContactTimestamp: Double?
    private let missingGrace: Float = 0.14
    private let approachTimeout: Float = 4.5
    private let contactStart: Float = 1.05
    private let contactEnd: Float = 1.40

    mutating func request(target: SIMD2<Float>) {
        guard phase == .idle, Self.finite(target) else { return }
        self.target = target
        phase = .approaching
        animationTime = 0
        approachElapsed = 0
        missingElapsed = 0
        cancelled = false
        contactFired = false
        flashAge = 10
        resetContactEvidence()
    }

    mutating func update(dt: Float, palm: SIMD2<Float>?, fresh: Bool, near: Bool,
                         arrived: Bool, reactionReady: Bool, duration: Float = 2.5) {
        guard dt.isFinite, dt > 0 else { return }
        flashAge = min(10, flashAge + dt)
        let clipDuration = duration.isFinite && duration > 0 ? duration : 2.5
        let validPalm = palm.flatMap { Self.finite($0) ? $0 : nil }
        let hasFreshPalm = fresh && validPalm != nil

        switch phase {
        case .idle:
            return
        case .approaching:
            approachElapsed += dt
            missingElapsed = hasFreshPalm ? 0 : missingElapsed + dt
            // A held/uncertain frame may report near=false. It is NOT evidence
            // of retreat; only a fresh observed palm can cancel immediately.
            if (hasFreshPalm && !near) || missingElapsed > missingGrace || approachElapsed >= approachTimeout {
                cancel()
                return
            }
            if hasFreshPalm && near, let validPalm { target = validPalm }
            if hasFreshPalm && near && arrived && reactionReady {
                phase = .gesture
                animationTime = 0
                missingElapsed = 0
                resetContactEvidence()
            }
        case .gesture:
            animationTime = min(clipDuration, animationTime + dt)
            missingElapsed = hasFreshPalm ? 0 : missingElapsed + dt
            if (hasFreshPalm && !near) || missingElapsed > missingGrace {
                cancel()
                return
            }
            // Root movement has finished. A moving hand may affect actual
            // contact, but never snaps the dog's raised paw to a new target.
            if animationTime >= clipDuration {
                phase = .settling
                resetContactEvidence()
            }
        case .settling:
            // Continue the existing clip while its weight eases down. Cancelling
            // never jumps animationTime straight to a later lowering pose.
            animationTime = min(clipDuration, animationTime + dt)
            if reactionReady {
                phase = .idle
                missingElapsed = 0
                resetContactEvidence()
            }
        }
    }

    mutating func observeContact(paw: SIMD2<Float>, palm: SIMD2<Float>?, radius: Float,
                                 fresh: Bool, near: Bool, timestamp: Double) {
        guard phase == .gesture, !cancelled, !contactFired,
              animationTime >= contactStart, animationTime <= contactEnd else {
            resetContactEvidence()
            return
        }
        guard fresh, near, timestamp.isFinite, radius.isFinite, radius > 0,
              Self.finite(paw), let palm, Self.finite(palm) else {
            resetContactEvidence()
            return
        }
        // A 60 Hz renderer may observe the same 30 Hz camera frame repeatedly.
        // Only strictly newer captures count, not another render of that frame.
        if let lastContactTimestamp, timestamp <= lastContactTimestamp { return }
        lastContactTimestamp = timestamp
        let delta = paw - palm
        guard delta.x * delta.x + delta.y * delta.y <= radius * radius else {
            contactObservations = 0
            return
        }
        contactObservations += 1
        guard contactObservations >= 2 else { return }
        contactFired = true
        completedCount += 1
        flashAge = 0
        flashPoint = paw
    }

    mutating func cancel(immediately: Bool = false) {
        cancelled = true
        flashAge = 10
        missingElapsed = 0
        resetContactEvidence()
        if immediately {
            phase = .idle
            animationTime = 0
            approachElapsed = 0
        } else if phase == .approaching {
            phase = .idle
            animationTime = 0
            approachElapsed = 0
        } else if phase == .gesture {
            phase = .settling
        }
    }

    private mutating func resetContactEvidence() {
        contactObservations = 0
        lastContactTimestamp = nil
    }
    private static func finite(_ p: SIMD2<Float>) -> Bool { p.x.isFinite && p.y.isFinite }
}
