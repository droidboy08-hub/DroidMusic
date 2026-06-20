import Foundation
import Observation
import SwiftUI

@Observable
final class PlayerState {
    var currentTrack: Track? = nil
    var isPlaying: Bool = false
    var progress: Double = 0.0
    var liked: Bool = false
    var showNowPlaying: Bool = false
    var showVideo: Bool = false {  // user preference: show the video layer in the sheet
        didSet {
            guard showVideo != oldValue else { return }
            // Switch the live stream between audio-only and muxed (video).
            MusicPlayer.shared.setVideoEnabled(showVideo)
        }
    }
    var hasVideo: Bool = false    // muxed video stream is currently loaded (itag 18)

    /// Whether video *can* be shown for the current track. Every playable track
    /// is a YouTube video, so the toggle is available whenever something plays —
    /// the muxed stream is only fetched on demand.
    var videoAvailable: Bool { currentTrack?.videoId != nil }
    var nowPlayingCoverURL: String? = nil  // high-res cover from /player videoDetails (fallback)
    var showAccount: Bool = false
    var isYouTubeLoggedIn: Bool = false
    var ytProfileImageURL: String? = nil
    var ytDisplayName: String? = nil
    var isLoading: Bool = false
    var debugMode: Bool = false
    var errorMessage: String? = nil

    var totalSeconds: Int = 0

    var currentSeconds: Int {
        guard totalSeconds > 0 else { return 0 }
        return Int(Double(totalSeconds) * progress)
    }

    /// Best cover for the big now-playing artwork: high-res rewrite of the
    /// current track's thumbnail, falling back to the /player videoDetails cover.
    var displayCoverURL: String? {
        MetadataParser.highResCoverURL(currentTrack?.thumbnailURL) ?? nowPlayingCoverURL
    }

    func formattedCurrent() -> String { formatTime(currentSeconds) }
    func formattedRemaining() -> String { 
        guard totalSeconds > 0 else { return "0:00" }
        return "−\(formatTime(max(0, totalSeconds - currentSeconds)))" 
    }

    private func formatTime(_ s: Int) -> String {
        "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    var isSeeking: Bool = false
    var isShuffle: Bool {
        get { SongQueue.shared.isShuffle }
        set { SongQueue.shared.isShuffle = newValue }
    }
    var isRepeat: Bool {
        SongQueue.shared.repeatMode != .off
    }
    var repeatIcon: String {
        SongQueue.shared.repeatMode == .one ? "repeat.1" : "repeat"
    }
    var repeatDescription: String {
        switch SongQueue.shared.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat Playlist"
        case .one: "Repeat One"
        }
    }
    
    var sleepMinutesRemaining: Int? = nil
    var canPlayPreviousTrack: Bool {
        !SongQueue.shared.history.isEmpty
    }
    var canPlayNextTrack: Bool {
        !SongQueue.shared.nextSongIds.isEmpty
            || SongQueue.shared.repeatMode == .all
            || SongQueue.shared.repeatMode == .one
    }
    var recommendedTracks: [Track] {
        let candidates = SongQueue.shared.nextSongIds + likedTracks
        var seen = Set<UUID>()

        return candidates.filter { track in
            track.id != currentTrack?.id
                && track.videoId != nil
                && seen.insert(track.id).inserted
        }
    }
    private var sleepTask: Task<Void, Never>? = nil

    // Persisted across launches via PersistenceStore (UserDefaults).
    // didSet on each property funnels every mutation — whether via the
    // PlayerState methods below or external @Bindable-style assignment —
    // into a single save call.
    var userPlaylists: [Playlist] = [] {
        didSet { PersistenceStore.save(userPlaylists, for: .userPlaylists) }
    }
    var likedTracks: [Track] = [] {
        didSet { PersistenceStore.save(likedTracks, for: .likedTracks) }
    }
    var recentSearches: [String] = [] {
        didSet { PersistenceStore.save(recentSearches, for: .recentSearches) }
    }

    init() {
        // Property observers don't fire during init, so these loads
        // hydrate state without re-saving the values we just read.
        if let v = PersistenceStore.load(.userPlaylists, as: [Playlist].self) { userPlaylists = v }
        if let v = PersistenceStore.load(.likedTracks, as: [Track].self) { likedTracks = v }
        if let v = PersistenceStore.load(.recentSearches, as: [String].self) { recentSearches = v }
    }

    @discardableResult
    func createPlaylist(name: String, adding track: Track? = nil) -> UUID? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }

        let playlist = Playlist(
            title: cleanName,
            author: "You",
            tracks: track.map { [$0] } ?? []
        )
        userPlaylists.append(playlist)
        return playlist.id
    }

    func recordSearch(_ term: String) {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return }
        recentSearches.removeAll { $0.localizedCaseInsensitiveCompare(cleanTerm) == .orderedSame }
        recentSearches.insert(cleanTerm, at: 0)
        if recentSearches.count > 10 {
            recentSearches = Array(recentSearches.prefix(10))
        }
    }

    func removeRecentSearch(_ term: String) {
        recentSearches.removeAll { $0.localizedCaseInsensitiveCompare(term) == .orderedSame }
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
    }

    func addToPlaylist(track: Track, playlistId: UUID) {
        if let idx = userPlaylists.firstIndex(where: { $0.id == playlistId }) {
            if !userPlaylists[idx].tracks.contains(where: { $0.id == track.id }) {
                userPlaylists[idx].tracks.append(track)
            }
        }
    }

    @MainActor
    func playNext(track: Track) { SongQueue.shared.playNext(track) }

    @MainActor
    func addToQueue(track: Track) { SongQueue.shared.addToQueue(track) }

    func toggleLike(track: Track) {
        if let idx = likedTracks.firstIndex(where: { $0.id == track.id }) {
            likedTracks.remove(at: idx)
            if currentTrack?.id == track.id { liked = false }
        } else {
            likedTracks.append(track)
            if currentTrack?.id == track.id { liked = true }
        }
    }

    func isLiked(track: Track) -> Bool {
        likedTracks.contains(where: { $0.id == track.id })
    }

    func deletePlaylist(at offsets: IndexSet) {
        userPlaylists.remove(atOffsets: offsets)
    }

    // MARK: - Playback control

    @MainActor
    func play(track: Track, queue: [Track]? = nil) {
        guard track.videoId != nil else { return }
        SongQueue.shared.play(track: track, queue: queue)
        syncState(with: track)
    }

    @MainActor
    private func syncState(with track: Track) {
        currentTrack = track
        isLoading = true
        errorMessage = nil
        progress = 0.0
        totalSeconds = 0
        nowPlayingCoverURL = nil
        liked = isLiked(track: track)

        let player = MusicPlayer.shared

        player.onNext     = { [weak self] in self?.playNextTrack() }
        player.onPrevious = { [weak self] in self?.playPreviousTrack() }

        player.onProgressUpdate = { [weak self] p in
            guard let self else { return }
            if !self.isSeeking { self.progress = p }
            let dur = Int(player.duration)
            if dur > 0 && dur != self.totalSeconds {
                self.totalSeconds = dur
            }
        }
        player.onPlaybackStatusChange = { [weak self] isPlaying, isLoading in
            guard let self else { return }
            self.isPlaying = isPlaying
            self.isLoading = isLoading
        }
        player.onPlaybackEnd = { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.progress  = 0
            self.playNextTrack(automatic: true)
        }
        player.onError = { [weak self] error in
            self?.isLoading = false
            self?.isPlaying = false
            self?.errorMessage = error.localizedDescription
        }
        player.onMediaInfo = { [weak self] hasVideo in
            self?.hasVideo = hasVideo
        }
        player.onMetadata = { [weak self] meta in
            // /player videoDetails cover, upgraded to high-res (fallback when the
            // search-provided thumbnail is missing).
            self?.nowPlayingCoverURL = MetadataParser.highResCoverURL(meta?.coverURL)
        }
    }

    @MainActor
    func togglePlay() {
        guard !isLoading else { return }
        if isPlaying {
            MusicPlayer.shared.pause()
        } else {
            MusicPlayer.shared.resume()
        }
    }

    @MainActor
    func resetPlayer() {
        isLoading = false
        isPlaying = false
        errorMessage = nil
        SongQueue.shared.reset()   // → MusicPlayer.stop() pauses AVPlayer + clears item
    }

    func toggleLike() {
        guard let t = currentTrack else { return }
        toggleLike(track: t)
    }
    
    func toggleShuffle() { isShuffle.toggle() }
    func toggleRepeat() {
        switch SongQueue.shared.repeatMode {
        case .off:
            SongQueue.shared.repeatMode = .all
        case .all:
            SongQueue.shared.repeatMode = .one
        case .one:
            SongQueue.shared.repeatMode = .off
        }
    }

    @MainActor
    func playNextTrack(automatic: Bool = false) {
        if SongQueue.shared.next(automatic: automatic) {
            if let t = SongQueue.shared.playingSong {
                syncState(with: t)
            }
        } else {
            resetPlayer()
        }
    }

    @MainActor
    func playPreviousTrack() {
        SongQueue.shared.previous()
        if let t = SongQueue.shared.playingSong {
            syncState(with: t)
        }
    }

    @MainActor
    func scheduleSleep(minutes: Int) {
        sleepTask?.cancel()
        sleepMinutesRemaining = minutes
        sleepTask = Task {
            var remaining = minutes * 60
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                remaining -= 1
                self.sleepMinutesRemaining = remaining / 60 == 0 && remaining > 0 ? 1 : remaining / 60
            }
            MusicPlayer.shared.pause()
            self.isPlaying = false
            self.sleepMinutesRemaining = nil
        }
    }

    func cancelSleep() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepMinutesRemaining = nil
    }

    func seekTo(_ progress: Double) {
        let clampedProgress = max(0, min(1, progress))
        self.progress = clampedProgress
        // Don't clear isSeeking here — the scrubber's onEditingChanged(false) clears it
        // after seek fires, preventing AVPlayer callbacks from snapping the bar back.
        MusicPlayer.shared.seek(to: clampedProgress)
    }
}
