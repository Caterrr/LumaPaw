import AVFoundation
import Foundation

// Injectable playback surface keeps queue, mute, and lifecycle tests silent.
protocol DogAudioPlayback: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var volume: Float { get set }
    var numberOfLoops: Int { get set }
    var isPlaying: Bool { get }
    func play() -> Bool
    func pause()
    func stop()
    func setVolume(_ volume: Float, fadeDuration: TimeInterval)
}
extension AVAudioPlayer: DogAudioPlayback {}

/// Main-thread, output-only audio. Never requests microphone access or changes
/// system volume. Restoring the app resumes ambience, never stale bark requests.
final class DogAudio {
    /// Called immediately BEFORE each actual bark/happy playback attempt. The
    /// recognizer should suppress input for this duration plus its own short tail.
    var onBarkPlayback: ((TimeInterval) -> Void)?
    private(set) var isMuted = false
    private(set) var isSuspended = false
    private(set) var isListening = false
    private(set) var volume: Float = 0.5
    private(set) var lastPlaybackError: String?
    private(set) var pendingBarkCount = 0

    private enum Effect { case bark, happy, whine, sniff }
    private let ambient: DogAudioPlayback
    private let barkPlayer: DogAudioPlayback
    private let happyPlayer: DogAudioPlayback
    private let whinePlayer: DogAudioPlayback?
    private let sniffPlayer: DogAudioPlayback?
    private var activity: Float = 0
    private var eventTimes: [DogSoundEvent: TimeInterval] = [:]
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let clock: () -> TimeInterval
    private var ambientRequested = false
    private var effectPlaying = false
    private var waiting: [Effect] = []
    private var playbackGeneration: UInt64 = 0
    private var lastHappyTime = -Double.infinity

    convenience init(resources: URL) throws {
        // Accept either a Bundle resource root or the audio directory itself.
        let folder = resources.lastPathComponent == "audio" ? resources : resources.appendingPathComponent("audio")
        func load(_ name: String) throws -> AVAudioPlayer {
            let player = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(name))
            guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else {
                throw NSError(domain: "LuminousPup.DogAudio", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not prepare dog audio: \(name)"])
            }
            return player
        }
        try self.init(ambient: load("dog_breath_loop.wav"), bark: load("dog_bark.wav"),
                      happy: load("dog_happy.wav"), whine: load("dog_whine.wav"), sniff: load("dog_sniff.wav"))
    }

    init(ambient: DogAudioPlayback, bark: DogAudioPlayback, happy: DogAudioPlayback,
         whine: DogAudioPlayback? = nil, sniff: DogAudioPlayback? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.ambient = ambient; barkPlayer = bark; happyPlayer = happy
        whinePlayer = whine; sniffPlayer = sniff
        whine?.numberOfLoops = 0; sniff?.numberOfLoops = 0
        whine?.volume = 0; sniff?.volume = 0
        self.clock = clock; self.schedule = schedule
        ambient.numberOfLoops = -1; bark.numberOfLoops = 0; happy.numberOfLoops = 0
        ambient.volume = 0; bark.volume = 0; happy.volume = 0
    }

    func startAmbient() {
        checkThread(); ambientRequested = true; refreshAmbient()
    }
    func setMuted(_ muted: Bool) {
        checkThread(); guard muted != isMuted else { return }; isMuted = muted
        if muted { cancelEffects(); ambient.pause() }
        refreshVolumes(); refreshAmbient()
    }
    func setVolume(_ value: Float) {
        checkThread(); guard value.isFinite else { return }
        volume = min(1, max(0, value))
        if volume == 0 { cancelEffects(); ambient.pause() }
        refreshVolumes(); refreshAmbient()
    }
    func setListening(_ listening: Bool) {
        checkThread(); isListening = listening; refreshVolumes()
    }
    func setSuspended(_ suspended: Bool) {
        checkThread(); guard suspended != isSuspended else { return }; isSuspended = suspended
        if suspended { cancelEffects(); ambient.pause() }
        refreshVolumes(); refreshAmbient()
    }
    func bark() {
        checkThread(); enqueue(.bark)
    }
    /// Optional gentle response. At most once in four seconds; never queues
    /// behind a voice bark or delays it with repeated petting sounds.
    func happy() {
        checkThread()
        guard audible, !effectPlaying, waiting.isEmpty, clock()-lastHappyTime >= 4 else { return }
        lastHappyTime = clock(); enqueue(.happy)
    }
    /// Context effects expire immediately when busy; never play an old pet or
    /// pickup response later over an unrelated action.
    func respond(to event: DogSoundEvent) {
        checkThread()
        let cooldown: TimeInterval = event == .pet ? 8 : (event == .sit ? 4 : 1.2)
        guard audible, !effectPlaying, waiting.isEmpty,
              clock() - (eventTimes[event] ?? -Double.infinity) >= cooldown else { return }
        eventTimes[event] = clock()
        switch event {
        case .pet, .sit: enqueue(whinePlayer == nil ? .happy : .whine)
        case .pickup: enqueue(sniffPlayer == nil ? .happy : .sniff)
        case .throwBall: enqueue(.bark)
        case .delivery, .highFive, .praise: enqueue(.happy)
        }
    }
    func setActivity(_ running: Float) {
        checkThread(); guard running.isFinite else { return }
        let value = min(1, max(0, running))
        guard abs(value - activity) > 0.04 else { return }
        activity = value; refreshAmbient()
    }
    func stop() {
        checkThread(); ambientRequested = false; ambient.stop(); ambient.currentTime = 0
        cancelEffects()
    }

    private var audible: Bool { !isMuted && !isSuspended && volume > 0 }
    private var ambientVolume: Float {
        guard audible else { return 0 }
        return volume * (0.32 + activity * 0.36) * (isListening ? 0.06 : 1) * (effectPlaying ? 0.12 : 1)
    }
    private func refreshAmbient() {
        guard ambientRequested, audible else { return }
        if !ambient.isPlaying {
            ambient.volume = 0
            if !ambient.play() { lastPlaybackError = "Breathing audio is unavailable"; return }
        }
        ambient.setVolume(ambientVolume, fadeDuration: 0.45)
    }
    private func refreshVolumes() {
        ambient.setVolume(ambientVolume, fadeDuration: 0.18)
        barkPlayer.volume = audible ? volume * 0.60 : 0
        happyPlayer.volume = audible ? volume * 0.42 : 0
        whinePlayer?.volume = audible ? volume * 0.40 : 0
        sniffPlayer?.volume = audible ? volume * 0.46 : 0
    }
    private func enqueue(_ effect: Effect) {
        guard audible else { return }
        // The current sound plus two pending name calls is the entire queue.
        guard waiting.count < 2 else { return }
        waiting.append(effect); pendingBarkCount = waiting.count
        if !effectPlaying { playNext() }
    }
    private func playNext() {
        guard audible, !waiting.isEmpty else { return }
        let effect = waiting.removeFirst(); pendingBarkCount = waiting.count
        let player: DogAudioPlayback
        switch effect {
        case .bark: player = barkPlayer
        case .happy: player = happyPlayer
        case .whine: player = whinePlayer ?? happyPlayer
        case .sniff: player = sniffPlayer ?? happyPlayer
        }
        effectPlaying = true; refreshVolumes(); player.currentTime = 0
        let generation = playbackGeneration
        onBarkPlayback?(player.duration)
        // A callback may mute/suspend the app; do not sound after that change.
        guard audible, generation == playbackGeneration else { return }
        if !player.play() { lastPlaybackError = "Dog response audio is unavailable" }
        schedule(player.duration + 0.12) { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.effectPlaying = false
            self.refreshVolumes()
            self.playNext()
        }
    }
    private func cancelEffects() {
        playbackGeneration &+= 1
        waiting.removeAll(); pendingBarkCount = 0; effectPlaying = false
        barkPlayer.stop(); happyPlayer.stop(); whinePlayer?.stop(); sniffPlayer?.stop()
        barkPlayer.currentTime = 0; happyPlayer.currentTime = 0
        whinePlayer?.currentTime = 0; sniffPlayer?.currentTime = 0
    }
    private func checkThread() { precondition(Thread.isMainThread, "DogAudio must run on the main thread") }
}
