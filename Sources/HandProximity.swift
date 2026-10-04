import Foundation
import simd

/// Relative image scale only. A monocular camera does not measure hand distance.
struct HandProximityState {
    var relativeScale: Float = 1
    var calibrated = false
    var ready = false
    var approaching = false
    var near = false
    /// True only on the one update which creates this event.
    var triggered = false
    /// Monotonic for this tracker, including calls to reset().
    var triggerID: UInt64 = 0
}

/// A deliberate, single open-palm approach. Uses capture timestamps, not render
/// timing. Missing geometry disables only this feature, never ordinary controls.
struct HandProximityTracker {
    private struct Sample {
        let size: SIMD2<Float>
        let timestamp: Double
    }
    private var calibrationSamples: [Sample] = []
    private var baseline: SIMD2<Float>?
    private var previousRaw: Sample?
    private var filteredSize: SIMD2<Float>?
    private var lastTimestamp: Double?
    private var lastEligibleTimestamp: Double?
    private var nearSince: Double?
    private var retreatSince: Double?
    private var lastTriggerTimestamp: Double?
    private var armed = false
    private var nearLatch = false
    private var triggerID: UInt64 = 0
    private var state = HandProximityState()

    mutating func reset() {
        let previousID = triggerID
        let previousTrigger = lastTriggerTimestamp
        self = HandProximityTracker()
        triggerID = previousID
        lastTriggerTimestamp = previousTrigger
        state.triggerID = previousID
    }

    mutating func process(_ frame: HandFrame?) -> HandProximityState {
        state.triggered = false
        guard let frame, frame.timestamp.isFinite else {
            interruptApproach()
            return state
        }
        guard lastTimestamp == nil || frame.timestamp > lastTimestamp! else {
            // Held frames keep their original capture timestamp. They must still
            // break approach evidence, even when their timestamp is a duplicate.
            if frame.isHolding { interruptApproach() }
            return state
        }
        lastTimestamp = frame.timestamp
        guard frame.intent == .palm, !frame.isHolding,
              frame.confidence >= 0.60, frame.palmGeometryConfidence >= 0.60,
              frame.palmWidth.isFinite, frame.palmLength.isFinite,
              frame.palmWidth >= 0.025, frame.palmLength >= 0.025,
              frame.palmWidth < 1.5, frame.palmLength < 1.5 else {
            interruptApproach()
            return state
        }
        let now = frame.timestamp
        if let previousTime = lastEligibleTimestamp {
            let gap = now - previousTime
            if gap > 0.60 {
                // A new appearance gets its own baseline. A hand appearing
                // already large never inherits an old hand's approach evidence.
                reset()
                lastTimestamp = now
            } else if gap > 0.15 {
                interruptApproach()
            }
        }
        lastEligibleTimestamp = now
        let raw = SIMD2(frame.palmWidth, frame.palmLength)
        if let previousRaw {
            let change = raw / previousRaw.size
            // A geometry jump is not an approach. A real approach must be
            // continuous; return to baseline before retrying after a jump.
            if change.x > 1.18 || change.y > 1.18 || change.x < 1 / 1.18 || change.y < 1 / 1.18 {
                interruptApproach(preservingConfirmedNear: false)
                self.previousRaw = Sample(size: raw, timestamp: now)
                filteredSize = raw
                return state
            }
        }
        let dt = Float(min(0.1, max(1.0 / 120, now - (previousRaw?.timestamp ?? now - 1.0 / 30))))
        previousRaw = Sample(size: raw, timestamp: now)
        let smooth = (filteredSize ?? raw) + (raw - (filteredSize ?? raw)) * (1 - exp(-dt / 0.065))
        filteredSize = smooth

        guard let baseline else {
            collectBaseline(raw, at: now)
            state.calibrated = self.baseline != nil
            state.ready = state.calibrated && cooldownFinished(at: now)
            return state
        }
        let ratios = smooth / baseline
        let relativeScale = sqrt(ratios.x * ratios.y)
        state.relativeScale = min(3, max(0.25, relativeScale))
        state.calibrated = true
        let shapeChange = ratios.x / ratios.y
        guard shapeChange >= 0.86 && shapeChange <= 1.16 else {
            // Turning/tilting often enlarges only one axis. Do not call that
            // forward motion, and do not adapt the baseline to the distortion.
            interruptApproach(preservingConfirmedNear: false)
            return state
        }
        let atBaseline = ratios.x >= 0.82 && ratios.y >= 0.82
            && ratios.x <= 1.10 && ratios.y <= 1.10
        if !armed {
            if atBaseline {
                if retreatSince == nil { retreatSince = now }
                if now - retreatSince! >= 0.25 && cooldownFinished(at: now) {
                    armed = true
                    nearLatch = false
                }
            } else { retreatSince = nil }
        }
        if ratios.x < 1.17 || ratios.y < 1.17 { nearLatch = false }
        state.ready = armed && atBaseline && cooldownFinished(at: now)
        state.approaching = armed && ratios.x >= 1.10 && ratios.y >= 1.10
        let clearlyNear = ratios.x >= 1.28 && ratios.y >= 1.28 && relativeScale >= 1.30
        if armed && clearlyNear && cooldownFinished(at: now) {
            if nearSince == nil { nearSince = now }
            if now - nearSince! >= 0.18 {
                triggerID &+= 1
                lastTriggerTimestamp = now
                armed = false
                nearLatch = true
                nearSince = nil
                retreatSince = nil
                state.triggered = true
                state.triggerID = triggerID
                state.ready = false
                state.approaching = false
            }
        } else { nearSince = nil }
        state.near = nearLatch
        return state
    }

    private mutating func collectBaseline(_ raw: SIMD2<Float>, at timestamp: Double) {
        calibrationSamples.append(Sample(size: raw, timestamp: timestamp))
        calibrationSamples.removeAll { timestamp - $0.timestamp > 0.55 }
        guard calibrationSamples.count >= 8,
              let first = calibrationSamples.first, timestamp - first.timestamp >= 0.45 else { return }
        let mean = calibrationSamples.reduce(SIMD2<Float>.zero) { $0 + $1.size } / Float(calibrationSamples.count)
        let stable = calibrationSamples.allSatisfy {
            let ratio = $0.size / mean
            return abs(ratio.x - 1) <= 0.045 && abs(ratio.y - 1) <= 0.045
        }
        guard stable else { return }
        baseline = mean
        filteredSize = mean
        calibrationSamples.removeAll(keepingCapacity: true)
        armed = true
        state.relativeScale = 1
    }

    private mutating func interruptApproach(preservingConfirmedNear: Bool = true) {
        nearSince = nil
        retreatSince = nil
        // A short held/occluded capture suppresses output, but does not erase a
        // high-five already issued. Fresh reliable geometry can restore `near`
        // without rearming or issuing a second token. Retreat, geometric jumps,
        // shape changes, and long-loss reset still clear the internal latch.
        if !preservingConfirmedNear { nearLatch = false }
        armed = false
        calibrationSamples.removeAll(keepingCapacity: true)
        state.ready = false
        state.approaching = false
        state.near = false
        state.triggered = false
        // Keep previousRaw: an abrupt size change on return must not sneak past
        // the discontinuity gate. Long loss explicitly clears it via reset().
    }

    private func cooldownFinished(at timestamp: Double) -> Bool {
        guard let lastTriggerTimestamp else { return true }
        return timestamp - lastTriggerTimestamp >= 1.20
    }
}
