import AVFoundation
import Foundation

@MainActor
final class Playback {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?
    private var completion: ((Bool) -> Void)?

    init() {
        let center = NotificationCenter.default
        observers = [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, .AVAudioEngineConfigurationChange].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == AVAudioSession.routeChangeNotification,
                   let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   raw == AVAudioSession.RouteChangeReason.categoryChange.rawValue { return }
                if name == AVAudioSession.interruptionNotification,
                   let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   raw == AVAudioSession.InterruptionType.ended.rawValue { return }
                let source = (note.object as? AVAudioEngine).map(ObjectIdentifier.init)
                Task { @MainActor in
                    guard let self else { return }
                    if name == .AVAudioEngineConfigurationChange, source != self.engine.map(ObjectIdentifier.init) { return }
                    self.cancel(notify: true)
                }
            }
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func cancel(notify: Bool = false) {
        generation = UUID()
        watchdog?.cancel()
        watchdog = nil
        let finished = completion
        completion = nil
        if let player { player.stop() }
        if let engine { engine.stop(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        engine = nil
        player = nil
        if notify { finished?(false) }
    }

    func play(_ question: Question, finished: @escaping (Bool) -> Void) {
        cancel()
        completion = finished
        let token = generation
        if Launch.testing && !Launch.has("-real-audio") {
            watchdog = Task {
                try? await Task.sleep(for: .milliseconds(Launch.has("-slow-audio") ? 3_500 : 180))
                guard generation == token else { return }
                complete(!Launch.has("-audio-failure"))
            }
            return
        }
        Task {
            let rendered = await Task.detached(priority: .userInitiated) { try? PianoSound.buffer(question) }.value
            guard generation == token else { return }
            guard let rendered else { complete(false); return }
            start(rendered, token: token)
        }
    }

    private func start(_ buffer: AVAudioPCMBuffer, token: UUID) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            self.engine = engine
            self.player = player
            try session.setActive(true)
            guard !session.currentRoute.outputs.isEmpty, session.outputVolume > 0,
                  engine.outputNode.outputFormat(forBus: 0).channelCount > 0 else { complete(false); return }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            try engine.start()
            let outputUIDs = session.currentRoute.outputs.map(\.uid)
            let clock = ContinuousClock()
            let started = clock.now
            let minimum = Duration.seconds(max(0, Double(buffer.frameLength) / buffer.format.sampleRate - 0.1))
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    let current = AVAudioSession.sharedInstance()
                    self.complete(clock.now - started >= minimum && self.engine?.isRunning == true &&
                                  current.outputVolume > 0 && current.currentRoute.outputs.map(\.uid) == outputUIDs)
                }
            }
            player.play()
            watchdog = Task {
                try? await Task.sleep(for: .seconds(5))
                guard generation == token else { return }
                complete(false)
            }
        } catch { complete(false) }
    }

    private func complete(_ success: Bool) {
        let finished = completion
        cancel()
        finished?(success)
    }
}
