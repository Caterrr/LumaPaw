import Foundation

/// Semantic edges, not animation-frame callbacks, trigger one-shot sounds.
struct DogSoundState {
    var active = false
    var running: Float = 0
    var petting = false
    var seated = false
    var throwCount = 0, pickups = 0, deliveries = 0, highFives = 0, praises = 0
}
enum DogSoundEvent: Hashable { case pet, sit, throwBall, pickup, delivery, highFive, praise }
struct DogSoundEvents {
    private var previous: DogSoundState?
    mutating func update(_ state: DogSoundState) -> [DogSoundEvent] {
        defer { previous = state }
        guard let old = previous, old.active, state.active else { return [] }
        var events: [DogSoundEvent] = []
        if state.throwCount > old.throwCount { events.append(.throwBall) }
        if state.pickups > old.pickups { events.append(.pickup) }
        if state.deliveries > old.deliveries { events.append(.delivery) }
        if state.highFives > old.highFives { events.append(.highFive) }
        if state.praises > old.praises { events.append(.praise) }
        if state.seated && !old.seated { events.append(.sit) }
        if state.petting && !old.petting { events.append(.pet) }
        return events
    }
}
