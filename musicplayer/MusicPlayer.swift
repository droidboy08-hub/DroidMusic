import Foundation
import AVFoundation
import MediaPlayer

// MARK: - AryaMusix audio engine (native AVPlayer, dual-path)
//
// PRIMARY: MWEB /player → progressive itag 18 (muxed H.264 + AAC, ratebypass).
//   AVPlayer pulls the whole file with one Range request → 206, no chunking
//   loader, video track already there for the now-playing sheet.
// FALLBACK: IOS /player → adaptive itag 140 (AAC audio-only). googlevideo
//   refuses whole-file ranges, so this path goes through StreamResourceLoader.
@MainActor
final class MusicPlayer {
    static let shared = MusicPlayer()

    let player = AVPlayer()                 // exposed so the video layer can attach
    private(set) var duration: Double = 0
    private(set) var hasVideo: Bool = false // true while playing a muxed itag
    private(set) var currentMetadata: TrackMetadata?  // /player videoDetails for the current item
    var streamingQuality: StreamingQuality = .high

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

    private init() {
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
        // Progress tick (~4×/sec).
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {   // periodic observer is on the main queue
                guard let self, !self.isResolvingStream else { return }
                let cur = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                guard cur.isFinite, self.duration > 0 else { return }
                self.onProgressUpdate?(cur / self.duration)   // normalized 0–1
                self.updateNowPlayingPosition(current: cur, duration: self.duration)
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

    /// Resolve a stream URL (MWEB itag 18 → IOS itag 140 fallback) and play it.
    /// One retry with a refreshed session covers stale `visitorData`.
    private func resolveAndPlay(videoId: String, generation: Int, allowRetry: Bool) async {
        guard let visitorData = await SessionBootstrap.shared.visitorDataValue() else {
            if generation == loadGeneration {
                fail("Couldn't establish a YouTube session — check your connection.")
            }
            return
        }
        do {
            let r = try await DemusNetwork.shared.resolve(
                videoId: videoId,
                visitorData: visitorData,
                quality: streamingQuality
            )
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

        // DIAGNOSTIC: confirm the audio session is actually live & routed for output.
        let s = AVAudioSession.sharedInstance()
        print("🔈 [Audio] category=\(s.category.rawValue) mode=\(s.mode.rawValue) otherPlaying=\(s.isOtherAudioPlaying) outputs=\(s.currentRoute.outputs.map { $0.portType.rawValue })")
        do {
            try s.setCategory(.playback, mode: .default)
            try s.setActive(true)
        } catch { print("🔴 [Audio] activate failed: \(error)") }

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
        print("🧩 [Playback] itag=\(r.itag) hasVideo=\(r.hasVideo) ratebypass=\(!r.needsChunkedLoader) via loader")
        observeItem(item, generation: generation)

        // DIAGNOSTIC: capture the HTTP status from googlevideo (403 = expired/UA/IP-locked).
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let e = item.errorLog()?.events.last {
                    print("🔴 [Playback] errorLog status=\(e.errorStatusCode) domain=\(e.errorDomain) comment=\(e.errorComment ?? "-") uri=\((e.uri ?? "").prefix(80))")
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
            print("🔴 [Playback] failedToPlayToEnd: \(String(describing: err))")
        }

        // didPlayToEnd → advance queue.
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.loadGeneration else { return }
                self.onPlaybackEnd?()
            }
        }

        player.replaceCurrentItem(with: item)
        isResolvingStream = false
        player.play()
        print("▶️ [Playback] play() called — rate=\(player.rate) host=\(r.url.host ?? "?")")

        // DIAGNOSTIC: 2.5s later, report why we are/aren't actually playing.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard generation == self.loadGeneration else { return }
            let reason = self.player.reasonForWaitingToPlay?.rawValue ?? "nil"
            print("⏱️ [Playback +2.5s] tcs=\(self.player.timeControlStatus.rawValue) rate=\(self.player.rate) waitReason=\(reason) itemStatus=\(self.player.currentItem?.status.rawValue ?? -1) likelyToKeepUp=\(self.player.currentItem?.isPlaybackLikelyToKeepUp ?? false) loadedRanges=\(self.player.currentItem?.loadedTimeRanges.count ?? 0) playerErr=\(String(describing: self.player.error))")
        }
    }

    private func observeItem(_ item: AVPlayerItem, generation: Int) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let itemError = item.error
            let itemDuration = item.duration.seconds
            print("📦 [Item] status=\(status.rawValue) error=\(String(describing: itemError))")
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
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(1, progress)) * duration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
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
