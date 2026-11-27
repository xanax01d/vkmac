import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import MediaPlayer

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one
}

@MainActor
final class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published private(set) var currentTrack: AudioTrack?
    @Published private(set) var queue: [AudioTrack] = []
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bitrateKbps: Int? = nil
    @Published private(set) var sleepTimerMinutesRemaining: Int? = nil
    @Published var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying && !usingEngine {
                player.rate = playbackRate
            }
        }
    }
    @Published var isShuffle: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Float = 1.0 {
        didSet {
            player.volume = volume
            audioEngine.mainMixerNode.outputVolume = volume
        }
    }

    var onTrackStarted: ((AudioTrack) -> Void)?
    var onQueueEnded: (() -> Void)?
    var localURLResolver: ((AudioTrack) -> URL?)?
    @Published var crossfadeSeconds: Double = 0

    private let player = AVPlayer()
    private let audioEngine = AVAudioEngine()
    private let enginePlayerNode = AVAudioPlayerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 5)
    private var engineAudioFile: AVAudioFile?
    private var engineSeekOffset: Double = 0
    private var engineTimer: Timer?
    private var usingEngine: Bool = false
    private var eqSetupDone: Bool = false

    private var fadingOutPlayer: AVPlayer?
    private var fadeTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var sleepTimerTask: Task<Void, Never>?
    private var isSeeking = false
    private var consecutiveFailures = 0
    private var lastOutputDeviceId: AudioDeviceID = 0
    private var cachedArtworkUrl: String?
    private var cachedArtwork: MPMediaItemArtwork?

    init() {
        setupEQ()
        setupTimeObserver()
        setupRemoteCommands()
        setupAudioRouteObserver()
    }

    private func setupEQ() {
        let freqs: [Float] = [60, 230, 910, 3600, 14000]
        for (i, freq) in freqs.enumerated() where i < eqNode.bands.count {
            eqNode.bands[i].filterType = .parametric
            eqNode.bands[i].frequency = freq
            eqNode.bands[i].bandwidth = 1.0
            eqNode.bands[i].gain = 0
            eqNode.bands[i].bypass = false
        }
        eqNode.bypass = false
        audioEngine.attach(enginePlayerNode)
        audioEngine.attach(eqNode)
        audioEngine.connect(enginePlayerNode, to: eqNode, format: nil)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: nil)
        eqSetupDone = true
    }

    func applyEQ(bands: [Float]) {
        guard eqSetupDone else { return }
        for i in 0..<min(bands.count, eqNode.bands.count) {
            eqNode.bands[i].gain = max(-12, min(12, bands[i]))
        }
    }

    var isEngineEQActive: Bool { usingEngine }

    private static func currentDefaultOutputDevice() -> AudioDeviceID {
        var deviceId: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceId)
        return deviceId
    }

    private func setupAudioRouteObserver() {
        lastOutputDeviceId = Self.currentDefaultOutputDevice()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newId = Self.currentDefaultOutputDevice()
                guard newId != 0, newId != self.lastOutputDeviceId else { return }
                self.lastOutputDeviceId = newId
                if self.isPlaying {
                    self.pause()
                }
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        durationObservation?.invalidate()
        itemStatusObservation?.invalidate()
        engineTimer?.invalidate()
    }

    func play(track: AudioTrack, in queue: [AudioTrack]? = nil) {
        if let queue, !queue.isEmpty {
            self.queue = queue
            if let idx = queue.firstIndex(where: { $0.id == track.id && $0.ownerId == track.ownerId }) {
                self.currentIndex = idx
            } else {
                self.queue.insert(track, at: 0)
                self.currentIndex = 0
            }
        } else if let idx = self.queue.firstIndex(where: { $0.id == track.id && $0.ownerId == track.ownerId }) {
            self.currentIndex = idx
        } else {
            self.queue = [track]
            self.currentIndex = 0
        }

        loadAndPlay(track)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        if usingEngine {
            enginePlayerNode.pause()
            engineTimer?.invalidate()
            engineTimer = nil
        } else {
            player.pause()
        }
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        guard currentTrack != nil else { return }
        if usingEngine {
            if !audioEngine.isRunning {
                try? audioEngine.start()
            }
            enginePlayerNode.play()
            startEngineTimer()
        } else {
            player.play()
            if playbackRate != 1.0 {
                player.rate = playbackRate
            }
        }
        isPlaying = true
        updateNowPlayingInfo()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMinutesRemaining = minutes
        guard let minutes, minutes > 0 else { return }
        sleepTimerTask = Task { [weak self] in
            var remaining = minutes
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                remaining -= 1
                await MainActor.run {
                    self?.sleepTimerMinutesRemaining = remaining > 0 ? remaining : nil
                }
            }
            await MainActor.run {
                self?.pause()
            }
        }
    }

    func stop() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMinutesRemaining = nil
        stopEngine()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        bitrateKbps = nil
        updateNowPlayingInfo()
    }

    private func stopEngine() {
        engineTimer?.invalidate()
        engineTimer = nil
        enginePlayerNode.stop()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        engineAudioFile = nil
        usingEngine = false
    }

    private func isPlayable(_ track: AudioTrack) -> Bool {
        localURLResolver?(track) != nil || track.streamUrl.flatMap(URL.init(string:)) != nil
    }

    func nextTrack() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one, let track = currentTrack {
            seek(to: 0)
            loadAndPlay(track)
            return
        }

        if isShuffle, queue.count > 1 {
            let playableIndices = queue.indices.filter { $0 != currentIndex && isPlayable(queue[$0]) }
            if let nextIdx = playableIndices.randomElement() {
                currentIndex = nextIdx
                loadAndPlay(queue[currentIndex])
                return
            }
        }

        var candidate = currentIndex + 1
        while candidate < queue.count {
            if isPlayable(queue[candidate]) {
                currentIndex = candidate
                loadAndPlay(queue[currentIndex])
                return
            }
            candidate += 1
        }

        if repeatMode == .all {
            if let firstPlayable = queue.indices.first(where: { isPlayable(queue[$0]) }) {
                currentIndex = firstPlayable
                loadAndPlay(queue[firstPlayable])
                return
            }
        }

        if let onQueueEnded {
            onQueueEnded()
        }
        pause()
        seek(to: 0)
    }

    func appendAndPlayNext(_ tracks: [AudioTrack]) {
        guard !tracks.isEmpty else { return }
        let startIdx = queue.count
        queue.append(contentsOf: tracks)
        currentIndex = startIdx
        loadAndPlay(queue[startIdx])
    }

    func playNext(_ track: AudioTrack) {
        if queue.isEmpty || currentIndex < 0 {
            play(track: track, in: [track])
            return
        }
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertAt)
    }

    func playAt(index: Int) {
        guard index >= 0 && index < queue.count else { return }
        currentIndex = index
        loadAndPlay(queue[index])
    }

    func removeFromQueue(at index: Int) {
        guard index >= 0 && index < queue.count, index != currentIndex else { return }
        queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        }
    }

    func previousTrack() {
        guard !queue.isEmpty else { return }
        if currentTime > 3.0 {
            seek(to: 0)
            return
        }
        var candidate = currentIndex - 1
        while candidate >= 0 {
            if isPlayable(queue[candidate]) {
                currentIndex = candidate
                loadAndPlay(queue[candidate])
                return
            }
            candidate -= 1
        }
        if repeatMode == .all {
            if let lastPlayable = queue.indices.reversed().first(where: { isPlayable(queue[$0]) }) {
                currentIndex = lastPlayable
                loadAndPlay(queue[lastPlayable])
                return
            }
        }
        seek(to: 0)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(duration, 0)))
        if usingEngine, let file = engineAudioFile {
            let sampleRate = file.processingFormat.sampleRate
            let targetFrame = AVAudioFramePosition(clamped * sampleRate)
            let remaining = max(0, file.length - targetFrame)
            engineSeekOffset = clamped
            currentTime = clamped
            enginePlayerNode.stop()
            if remaining > 0 {
                let wasPlaying = isPlaying
                enginePlayerNode.scheduleSegment(
                    file,
                    startingFrame: targetFrame,
                    frameCount: AVAudioFrameCount(remaining),
                    at: nil
                ) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.usingEngine, self.isPlaying else { return }
                        if self.currentTime >= max(self.duration - 1.0, 0) {
                            self.nextTrack()
                        }
                    }
                }
                if wasPlaying {
                    if !audioEngine.isRunning { try? audioEngine.start() }
                    enginePlayerNode.play()
                }
            }
            updateNowPlayingInfo()
            return
        }

        isSeeking = true
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = clamped
                self.isSeeking = false
                self.updateNowPlayingInfo()
            }
        }
    }

    private func startEngineTimer() {
        engineTimer?.invalidate()
        engineTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.usingEngine, self.isPlaying,
                      let nodeTime = self.enginePlayerNode.lastRenderTime,
                      let playerTime = self.enginePlayerNode.playerTime(forNodeTime: nodeTime),
                      let file = self.engineAudioFile else { return }
                let secs = self.engineSeekOffset + Double(playerTime.sampleTime) / file.processingFormat.sampleRate
                if secs.isFinite && secs >= 0 {
                    self.currentTime = min(secs, self.duration)
                }
            }
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func loadAndPlay(_ track: AudioTrack) {
        currentTrack = track
        currentTime = 0
        duration = Double(track.durationSec)
        bitrateKbps = nil
        stopEngine()

        let localUrl = localURLResolver?(track)
        let resolvedUrl: URL? = localUrl ?? track.streamUrl.flatMap(URL.init(string:))
        guard let url = resolvedUrl else {
            isPlaying = false
            updateNowPlayingInfo()
            return
        }

        if let localUrl, let audioFile = try? AVAudioFile(forReading: localUrl) {
            usingEngine = true
            engineAudioFile = audioFile
            engineSeekOffset = 0
            let fileDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            if fileDuration.isFinite && fileDuration > 0 {
                duration = fileDuration
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
            audioEngine.mainMixerNode.outputVolume = volume
            enginePlayerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.usingEngine, self.isPlaying else { return }
                    if self.currentTime >= max(self.duration - 1.0, 0) {
                        self.nextTrack()
                    }
                }
            }
            do {
                try audioEngine.start()
                enginePlayerNode.play()
                startEngineTimer()
                consecutiveFailures = 0
                isPlaying = true
                onTrackStarted?(track)
                updateNowPlayingInfo()
                return
            } catch {
                stopEngine()
            }
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        durationObservation?.invalidate()
        itemStatusObservation?.invalidate()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        durationObservation = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let secs = item.duration.seconds
            if secs.isFinite && secs > 0 {
                Task { @MainActor [weak self] in
                    self?.duration = secs
                    self?.updateNowPlayingInfo()
                }
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.consecutiveFailures = 0
                case .failed:
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures < min(self.queue.count, 5) {
                        self.nextTrack()
                    } else {
                        self.consecutiveFailures = 0
                        self.isPlaying = false
                        self.updateNowPlayingInfo()
                    }
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.nextTrack()
            }
        }

        if crossfadeSeconds > 0, let prevItem = player.currentItem, isPlaying {
            let fadeOut = AVPlayer(playerItem: prevItem)
            fadeOut.volume = volume
            fadeOut.play()
            fadingOutPlayer = fadeOut
            let steps = 15
            let stepNs = UInt64((crossfadeSeconds / Double(steps)) * 1_000_000_000)
            let targetVol = volume
            fadeTask?.cancel()
            fadeTask = Task { [weak self] in
                for i in 1...steps {
                    try? await Task.sleep(nanoseconds: stepNs)
                    guard !Task.isCancelled else { return }
                    let frac = Float(i) / Float(steps)
                    await MainActor.run {
                        self?.fadingOutPlayer?.volume = targetVol * (1.0 - frac)
                        self?.player.volume = targetVol * frac
                    }
                }
                await MainActor.run {
                    self?.fadingOutPlayer?.pause()
                    self?.fadingOutPlayer = nil
                    self?.player.volume = targetVol
                }
            }
            player.replaceCurrentItem(with: item)
            player.volume = 0
        } else {
            player.replaceCurrentItem(with: item)
            player.volume = volume
        }
        player.play()
        player.rate = playbackRate
        isPlaying = true
        onTrackStarted?(track)
        updateNowPlayingInfo()
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSeeking else { return }
                let secs = time.seconds
                if secs.isFinite && secs >= 0 {
                    self.currentTime = secs
                }
                if let event = self.player.currentItem?.accessLog()?.events.last {
                    let bps = event.indicatedBitrate > 0 ? event.indicatedBitrate : event.observedBitrate
                    if bps > 0 {
                        self.bitrateKbps = Int((bps / 1000.0).rounded())
                    }
                }
            }
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resume()
            }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.nextTrack()
            }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.previousTrack()
            }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.seek(to: posEvent.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: "VK Музыка",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let coverStr = track.coverUrl {
            if cachedArtworkUrl == coverStr, let artwork = cachedArtwork {
                info[MPMediaItemPropertyArtwork] = artwork
            } else if let url = URL(string: coverStr) {
                cachedArtworkUrl = coverStr
                cachedArtwork = nil
                Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = NSImage(data: data) else { return }
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    await MainActor.run {
                        guard let self, self.cachedArtworkUrl == coverStr else { return }
                        self.cachedArtwork = artwork
                        self.updateNowPlayingInfo()
                    }
                }
            }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
