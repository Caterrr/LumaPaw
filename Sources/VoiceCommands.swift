import Foundation

enum VoiceCommand: String, CaseIterable {
    case come, sit, spin, shake, praise
}

/// Times are monotonic seconds in the same clock as `process(at:)`.
struct VoiceTranscriptSegment {
    let text: String
    let timestamp: Double
    let duration: Double
}

/// Pure streaming command extraction. Never opens audio, saves transcripts, or
/// treats a repeated partial/final hypothesis as a new utterance.
struct VoiceCommandParser {
    private struct Token {
        let value: String
        let timestamp: Double
    }
    private struct Occurrence: Hashable {
        let command: VoiceCommand
        let ordinal: Int
    }
    private(set) var petName: String
    private var nameTokens: [String]
    private var session: UInt64 = 0
    private var seen: [Occurrence: Double] = [:]
    private var lastEmitted: [VoiceCommand: Double] = [:]
    private var suppressed: [ClosedRange<Double>] = []
    private let debounce: Double = 0.70
    private static let phrases: [(VoiceCommand, String)] = [
        (.come,"come here"),(.come,"come"),(.sit,"sit down"),(.sit,"sit"),
        (.spin,"spin"),(.spin,"turn around"),(.shake,"high five"),(.shake,"give me five"),(.shake,"shake"),
        (.praise,"good boy"),(.praise,"good girl"),(.praise,"good dog"),(.praise,"well done")
    ]

    init(petName: String = "Luma") {
        let name = String(petName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        self.petName = name
        nameTokens = Self.words(name)
        if Self.phrases.contains(where: { Self.words($0.1) == nameTokens }) { nameTokens = [] }
    }

    mutating func setName(_ name: String) {
        let oldSession = session
        self = VoiceCommandParser(petName: name)
        session = oldSession
    }

    mutating func reset() { self = VoiceCommandParser(petName: petName) }

    mutating func suppressCommands(from start: Double, until end: Double) {
        guard start.isFinite, end.isFinite, end > start else { return }
        suppressed.append(start...end)
        if suppressed.count > 32 { suppressed.removeFirst(suppressed.count - 32) }
    }

    mutating func process(_ transcript: String, sessionID: UInt64, at timestamp: Double,
                          segments: [VoiceTranscriptSegment] = []) -> [VoiceCommand] {
        guard timestamp.isFinite, sessionID >= session else { return [] }
        if sessionID > session {
            session = sessionID
            seen.removeAll(keepingCapacity: true)
        }
        var tokens: [Token] = []
        if !segments.isEmpty {
            for segment in segments {
                let words = Self.words(segment.text)
                let start = segment.timestamp.isFinite ? segment.timestamp : timestamp
                let duration = segment.duration.isFinite ? max(0, segment.duration) : 0
                for (index, value) in words.enumerated() {
                    tokens.append(Token(value: value, timestamp: start + duration * Double(index) / Double(max(1, words.count))))
                }
            }
        } else {
            tokens = Self.words(transcript).map { Token(value: $0, timestamp: timestamp) }
        }
        guard !tokens.isEmpty else { return [] }
        var patterns = Self.phrases.map { ($0.0, Self.words($0.1)) }
        if !nameTokens.isEmpty { patterns.append((.come, nameTokens)) }
        var matches: [(offset: Int, end:Int, command: VoiceCommand, ordinal: Int, time: Double)] = []
        for (command, phrase) in patterns {
            guard phrase.count <= tokens.count else { continue }
            var ordinal = 0, cursor = 0
            while cursor <= tokens.count - phrase.count {
                if Array(tokens[cursor..<(cursor + phrase.count)].map(\.value)) == phrase {
                    ordinal += 1
                    matches.append((cursor, cursor+phrase.count, command, ordinal, tokens[cursor].timestamp))
                    cursor += phrase.count
                } else { cursor += 1 }
            }
        }
        matches.sort { $0.offset == $1.offset ? $0.end > $1.end : $0.offset < $1.offset }
        var emitted: [VoiceCommand] = []
        var ordinals: [VoiceCommand: Int] = [:]
        var lastEnd:[VoiceCommand:Int]=[:]
        for match in matches {
            // “Sit” and “sit down” are one audio occurrence, including when a
            // partial hypothesis gains its second word a second later.
            if match.offset < (lastEnd[match.command] ?? -1){continue}
            lastEnd[match.command]=match.end
            ordinals[match.command, default: 0] += 1
            let occurrence = Occurrence(command: match.command, ordinal: ordinals[match.command]!)
            if let previous = seen[occurrence] {
                // Some recognizer revisions replace their transcript window.
                // Only a genuinely newer AUDIO occurrence can reuse that ordinal;
                // a repeated untimed partial/final can never become another call.
                guard !segments.isEmpty && match.time - previous >= debounce else { continue }
            }
            seen[occurrence] = match.time
            // Consume suppressed occurrences now, including a delayed result for
            // audio heard during a bark. They must not escape on a later final.
            guard !suppressed.contains(where: { $0.contains(match.time) }) else { continue }
            if let previous = lastEmitted[match.command], match.time - previous < debounce { continue }
            lastEmitted[match.command] = match.time
            emitted.append(match.command)
        }
        return emitted
    }

    /// Names and English commands match whole words (Milo never matches Camilo).
    /// Preserve Unicode name tokenization when reading an older saved profile.
    private static func words(_ text: String) -> [String] {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result: [String] = [], latin = ""
        func flush() { if !latin.isEmpty { result.append(latin); latin = "" } }
        for scalar in normalized.unicodeScalars {
            let value = scalar.value
            let cjk = (0x3400...0x9FFF).contains(value) || (0x20000...0x3134F).contains(value)
            if cjk {
                flush(); result.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                latin.unicodeScalars.append(scalar)
            } else { flush() }
        }
        flush()
        return result
    }
}
