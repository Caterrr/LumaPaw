import Foundation

enum InteractionMode: String, CaseIterable {
    case mouse, hand, voice
    var displayName: String {
        switch self {
        case .mouse: return "Mouse"
        case .hand: return "Hand"
        case .voice: return "Voice"
        }
    }
}

/// A callback belongs to the particular mode activation which installed it.
/// Returning to the same mode cannot make an old activation valid again.
struct InteractionModeTicket: Equatable {
    let mode: InteractionMode
    let generation: UInt64
    let activatedAt: Double
}

struct InteractionModeGate {
    private(set) var mode: InteractionMode = .mouse
    private(set) var generation: UInt64 = 0
    private(set) var activatedAt: Double = 0

    @discardableResult
    mutating func select(_ mode: InteractionMode, at timestamp: Double) -> InteractionModeTicket {
        self.mode = mode
        generation &+= 1
        activatedAt = timestamp.isFinite ? timestamp : 0
        return InteractionModeTicket(mode: mode, generation: generation, activatedAt: activatedAt)
    }

    func accepts(_ ticket: InteractionModeTicket, capturedAt timestamp: Double? = nil) -> Bool {
        guard ticket.mode == mode, ticket.generation == generation else { return false }
        if let timestamp { return timestamp.isFinite && timestamp >= activatedAt }
        return true
    }
}
