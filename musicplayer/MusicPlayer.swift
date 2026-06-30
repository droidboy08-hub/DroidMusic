import Foundation
import AVFoundation
import MediaPlayer

// MARK: - AryaMusix audio engine (Demus-style InnerTube playback)
//
// Stream: MWEB itag 18 (ratebypass) first, then other playback clients.
// Metadata: IOS /player fetched in parallel while the stream URL resolves.
// AVPlayer plays via StreamResourceLoader (AppleCoreMedia UA on unthrottled itag 18).
@MainActor
final class MusicPlayer {
    static let shared = MusicPlayer()

    let player = AVPlayer()                 // exposed so the video layer can attach
    private(set) var duration: Double = 0
    private(set) var hasVideo: Bool = false // true while playing a muxed itag
    private(set) var currentMetadata: TrackMetadata?  // /player videoDetails for the current item
    var streamingQuality: StreamingQuality = .high
    /// 10 Hz when Now Playing is open; 1 Hz for the mini-player ring only.
    var highFrequencyProgress = false

    // MARK: - Callbacks (wired by PlayerState)
    var onProgressUpdate:       ((Double) -> Void)?      // normalized 0–1
    var onPlaybackStatusChange: ((Bool, Bool) -> Void)?  // (isPlaying, isLoading)
    var onPlaybackEnd:          (() -> Void)?
    var onError:                ((Error) -> Void)?
    var onNext:                 (() -> Void)?
    var onPrevious:             (() -> Void)?
    var onMediaInfo:            ((Bool) -> Void)?              // (hasVideo)
    var onMetadata:             ((TrackMetadata?) -> Void)?   // from /player videoDetails

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    /// Retains the resource-loader for the current item (asset holds it weakly).
    private var resourceLoaderDelegate: StreamResourceLoader?
    private let loaderQueue = DispatchQueue(label: "com.aryamusix.streamloader")

    /// Token to discard stream URLs that arrive after the user moved on.
    private var loadGeneration = 0
    /// Prevents the previous AVPlayerItem from publishing stale time/duration
    /// while the next track's stream URL is still being resolved.
    private var isResolvingStream = false
    /// Suppresses progress updates while AVPlayer.seek(...) is still resolving asynchronously.
    /// Prevents the bar from snapping back to the pre-seek position.
    private var isSeekInFlight = false
    private var seekGeneration = 0
    private var lastUIProgressTime: CFTimeInterval = 0
    private var lastLockScreenTime: CFTimeInterval = 0
    private var itemObservers: [NSObjectProtocol] = []

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        configureAudioSession()
        observePlayer()
        setupRemoteControls()
    }

    // MARK: - Audio session (Phase 4)

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[MusicPlayer] AudioSession error: \(error)")
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) {
                    MainActor.assumeIsolated { self?.resume() }
                }
            }
        }
    }

    // MARK: - Player observation

    private func observePlayer() {
        // Sample on a background queue; throttle UI + lock-screen writes onto MainActor.
        let tickQueue = DispatchQueue(label: "com.aryamusix.playback.tick", qos: .utility)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: tickQueue
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isResolvingStream else { return }

                // Always keep duration fresh
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }

                guard !self.isSeekInFlight else { return }

                let cur = time.seconds
                guard cur.isFinite, self.duration > 0 else { return }

                let now = CACurrentMediaTime()
                let norm = cur / self.duration
                let uiInterval = self.highFrequencyProgress ? 0.10 : 1.0

                if now - self.lastUIProgressTime >= uiInterval {
                    self.lastUIProgressTime = now
                    self.onProgressUpdate?(norm)
                }
                if now - self.lastLockScreenTime >= 1.0 {
                    self.lastLockScreenTime = now
                    self.updateNowPlayingPosition(current: cur, duration: self.duration)
                }
            }
        }

        // Playing vs. buffering/paused.
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, !self.isResolvingStream else { return }
                switch status {
                case .playing:
                    self.onPlaybackStatusChange?(true, false)
                    MPNowPlayingInfoCenter.default().playbackState = .playing
                case .waitingToPlayAtSpecifiedRate:
                    self.onPlaybackStatusChange?(false, true)
                case .paused:
                    self.onPlaybackStatusChange?(false, false)
                    MPNowPlayingInfoCenter.default().playbackState = .paused
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Transport

    func play(track: Track) {
        duration = 0
        isResolvingStream = true
        isSeekInFlight = false
        seekGeneration += 1
        hasVideo = false
        currentMetadata = nil
        onMetadata?(nil)
        loadGeneration += 1
        let generation = loadGeneration
        let videoId = track.videoId ?? ""
        guard !videoId.isEmpty else { return }
        onPlaybackStatusChange?(false, true) // loading until URL resolved + buffered
        Task { await resolveAndPlay(videoId: videoId, generation: generation, allowRetry: true) }
    }

    /// Resolve via WebView attestation (primary) + session-bound InnerTube (fallback).
    private func resolveAndPlay(videoId: String, generation: Int, allowRetry: Bool) async {
        guard let session = await YouTubeSession.build() else {
            if generation == loadGeneration {
                fail("Couldn't establish a YouTube session — check your connection.")
            }
            return
        }
        do {
            async let stream = InnerTubeAPI.shared.resolveStream(
                videoId: videoId,
                session: session,
                quality: streamingQuality
            )
            async let iosMeta = InnerTubeAPI.shared.fetchMetadata(
                videoId: videoId,
                session: session
            )
            var r = try await stream
            if let meta = await iosMeta {
                r.metadata = meta
            }
            guard generation == loadGeneration else { return }  // user moved on
            startPlayback(resolved: r)
        } catch PlayerError.notPlayable(let reason) {
            if generation == loadGeneration { fail(reason) }     // age/region/login — don't retry
        } catch {
            if allowRetry {
                SessionBootstrap.shared.refresh()                // visitorData may be stale
                await resolveAndPlay(videoId: videoId, generation: generation, allowRetry: false)
            } else if generation == loadGeneration {
                fail("Couldn't load this track. It may be unavailable.")
            }
        }
    }

    private func fail(_ message: String) {
        isResolvingStream = false
        onError?(NSError(domain: "AryaMusix", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func startPlayback(resolved r: Resolved) {
        let generation = loadGeneration
        if r.durationSeconds > 0 { duration = r.durationSeconds }
        hasVideo = r.hasVideo
        onMediaInfo?(r.hasVideo)
        currentMetadata = r.metadata
        onMetadata?(r.metadata)

        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .moviePlayback)
            try s.setActive(true)
        } catch { print("[MusicPlayer] AudioSession: \(error)") }

        // Always proxy through StreamResourceLoader. googlevideo URLs are bound to
        // the minting client's UA and CoreMedia's own requests get 403'd; the loader
        // injects the correct UA via URLSession (the public-API way to set request
        // headers for AVPlayer). With ratebypass every chunk succeeds; without it
        // (adaptive itag 140) googlevideo throttles after ~1 MB — a YouTube-side
        // limit we can't beat without an nsig solver.
        let loader = StreamResourceLoader(realURL: r.url, headers: ["User-Agent": r.userAgent])
        let asset = AVURLAsset(url: StreamResourceLoader.proxyURL(for: r.url))
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
        resourceLoaderDelegate = loader
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        observeItem(item, generation: generation)
        attachItemObservers(item: item, generation: generation)

        player.replaceCurrentItem(with: item)
        isResolvingStream = false
        lastUIProgressTime = 0
        lastLockScreenTime = 0
        player.play()
    }

    private func attachItemObservers(item: AVPlayerItem, generation: Int) {
        clearItemObservers()
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, generation == self.loadGeneration else { return }
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.onError?(err ?? NSError(domain: "AryaMusix", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Playback ended unexpectedly."]))
            }
        })
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.loadGeneration else { return }
                self.onPlaybackEnd?()
            }
        })
    }

    private func clearItemObservers() {
        for token in itemObservers { NotificationCenter.default.removeObserver(token) }
        itemObservers.removeAll()
    }

    private func observeItem(_ item: AVPlayerItem, generation: Int) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let itemError = item.error
            let itemDuration = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                if status == .failed {
                    let err = itemError ?? NSError(domain: "AryaMusix", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Playback failed (stream may have expired)."])
                    self.onError?(err)
                } else if status == .readyToPlay {
                    if itemDuration.isFinite, itemDuration > 0 { self.duration = itemDuration }
                }
            }
        }
    }

    func resume() { player.play() }
    func pause()  { player.pause() }

    func stop() {
        loadGeneration += 1
        isResolvingStream = false
        isSeekInFlight = false
        seekGeneration += 1
        clearItemObservers()
        WebViewStreamExtractor.shared.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        duration = 0
        hasVideo = false
        onMediaInfo?(false)
        currentMetadata = nil
        onMetadata?(nil)
    }

    func seekForward()  { seekRelative(10) }
    func seekBackward() { seekRelative(-10) }

    private func seekRelative(_ delta: Double) {
        let cur = player.currentTime().seconds
        guard cur.isFinite else { return }
        let target = max(0, min(cur + delta, duration > 0 ? duration : .greatestFiniteMagnitude))
        performSeek(toSeconds: target)
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(1, progress)) * duration
        performSeek(toSeconds: target)
    }

    /// Performs an async seek and suppresses progress updates until AVPlayer confirms completion.
    /// On completion we emit the actual settled position once.
    private func performSeek(toSeconds targetSeconds: Double) {
        seekGeneration += 1
        let thisGen = seekGeneration
        isSeekInFlight = true

        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        // Use zero tolerance for music scrubbing feel (exact position)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == thisGen else { return }
                self.isSeekInFlight = false

                // Emit the real position now that the seek has landed.
                // This prevents the "jump forward" after stale ticks were ignored.
                let cur = self.player.currentTime().seconds
                if cur.isFinite, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    let norm = max(0, min(1, cur / d))
                    self.lastUIProgressTime = 0 // allow this update to go through immediately
                    self.onProgressUpdate?(norm)
                }
            }
        }
    }

    // MARK: - Now Playing (MPNowPlayingInfoCenter)

    func updateNowPlaying(track: Track) {
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle:                    track.title,
            MPMediaItemPropertyArtist:                   track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: 0.0),
            MPMediaItemPropertyPlaybackDuration:         NSNumber(value: 0.0),
            MPNowPlayingInfoPropertyPlaybackRate:        NSNumber(value: 1.0)
        ]

        guard let urlStr = track.thumbnailURL, let url = URL(string: urlStr) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func updateNowPlayingPosition(current: Double, duration: Double) {
        guard duration > 0 else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: current)
        info[MPMediaItemPropertyPlaybackDuration]         = NSNumber(value: duration)
        info[MPNowPlayingInfoPropertyPlaybackRate]        = NSNumber(value: player.rate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Command Center

    private func setupRemoteControls() {
        let rc = MPRemoteCommandCenter.shared()

        rc.playCommand.addTarget  { [weak self] _ in self?.resume(); return .success }
        rc.pauseCommand.addTarget { [weak self] _ in self?.pause();  return .success }
        rc.nextTrackCommand.addTarget     { [weak self] _ in self?.onNext?();     return .success }
        rc.previousTrackCommand.addTarget { [weak self] _ in self?.onPrevious?(); return .success }

        rc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                let dur = self?.duration ?? 0
                if dur > 0 { self?.seek(to: e.positionTime / dur) }
            }
            return .success
        }

        rc.seekBackwardCommand.isEnabled = true
        rc.seekBackwardCommand.addTarget { [weak self] _ in self?.seekBackward(); return .success }
        rc.seekForwardCommand.isEnabled  = true
        rc.seekForwardCommand.addTarget  { [weak self] _ in self?.seekForward();  return .success }
    }
}
