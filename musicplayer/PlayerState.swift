import Foundation
import Observation
import SwiftUI

@Observable
final class PlayerState {
    var currentTrack: Track? = nil
    var isPlaying: Bool = false
    var liked: Bool = false
    var showNowPlaying: Bool = false
    /// Mirrors ThemeState.showMiniPlayer (synced from the app root). When the mini
    /// player is hidden, a user-initiated play opens the full Now Playing cover.
    var miniPlayerEnabled: Bool = true
    var showVideo: Bool = false   // user preference: show the video layer in the sheet
    var hasVideo: Bool = false    // resolved track actually carries a video track (itag 18)
    var nowPlayingCoverURL: String? = nil  // high-res cover from /player videoDetails (fallback)
    var showAccount: Bool = false
    var isYouTubeLoggedIn: Bool = false
    var ytProfileImageURL: String? = nil
    var ytDisplayName: String? = nil
    var isLoading: Bool = false
    var debugMode: Bool = false
    var errorMessage: String? = nil

    /// High-frequency playback ticks — isolated so tab lists don't re-render.
    let playback = PlaybackProgress()

    /// Best cover for the big now-playing artwork: high-res rewrite of the
    /// current track's thumbnail, falling back to the /player videoDetails cover.
    var displayCoverURL: String? {
        MetadataParser.highResCoverURL(currentTrack?.thumbnailURL) ?? nowPlayingCoverURL
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

    /// Order of recently played tracks (current first, then history reversed).
    /// Used for "Last Played" sort in Home library section.
    var recentPlayOrder: [Track] {
        var order: [Track] = []
        if let current = currentTrack {
            order.append(current)
        }
        order.append(contentsOf: SongQueue.shared.history.reversed())
        return order
    }
    private var sleepTask: Task<Void, Never>? = nil

    // Persisted across launches via PersistenceStore (UserDefaults).
    // didSet on each property funnels every mutation — whether via the
    // PlayerState methods below or external @Bindable-style assignment —
    // into a single save call.
    var userPlaylists: [Playlist] = [] {
        didSet { PersistenceStore.save(userPlaylists, for: .userPlaylists) }
    }
    /// Playlists whose card is hidden from the Home rail (Home long-press → "Hide").
    var hiddenHomeCardIds: Set<UUID> = [] {
        didSet { PersistenceStore.save(hiddenHomeCardIds, for: .hiddenHomeCardIds) }
    }
    /// Playlists whose songs are hidden from Home's "From your library" list
    /// (Home long-press → "Hide" or "Hide Songs").
    var hiddenHomeSongIds: Set<UUID> = [] {
        didSet { PersistenceStore.save(hiddenHomeSongIds, for: .hiddenHomeSongIds) }
    }
    var likedTracks: [Track] = [] {
        didSet { PersistenceStore.save(likedTracks, for: .likedTracks) }
    }
    var recentSearches: [String] = [] {
        didSet { PersistenceStore.save(recentSearches, for: .recentSearches) }
    }
    /// A search query requested from elsewhere (e.g. Home mood/recent chips). The
    /// Search tab picks this up, runs it, and clears it. Transient (not persisted).
    var pendingSearch: String? = nil

    /// Tracks played specifically while browsing/playing from the Explore tab.
    /// Used only to power Explore-tab recommendations (scoped per user request).
    var exploreHistory: [Track] = [] {
        didSet { PersistenceStore.save(exploreHistory, for: .exploreHistory) }
    }

    /// Persisted previous recommendations from the Explore tab.
    /// Allows remembering old recommendations and mixing with new ones based on recent plays.
    var exploreRecommendations: [Track] = [] {
        didSet { PersistenceStore.save(exploreRecommendations, for: .exploreRecommendations) }
    }

    /// List of recently played playlist IDs (most recent first).
    /// (Legacy; now using lastPlayedAt on Playlist for sorting "Your playlists".)
    var recentPlaylistIDs: [UUID] = [] {
        didSet {
            PersistenceStore.save(recentPlaylistIDs, for: .recentPlaylistIDs)
        }
    }

    init() {
        // Property observers don't fire during init, so these loads
        // hydrate state without re-saving the values we just read.
        if let v = PersistenceStore.load(.userPlaylists, as: [Playlist].self) { userPlaylists = v }
        if let v = PersistenceStore.load(.likedTracks, as: [Track].self) { likedTracks = v }
        if let v = PersistenceStore.load(.recentSearches, as: [String].self) { recentSearches = v }
        if let v = PersistenceStore.load(.exploreHistory, as: [Track].self) { exploreHistory = v }
        if let v = PersistenceStore.load(.exploreRecommendations, as: [Track].self) { exploreRecommendations = v }
        if let v = PersistenceStore.load(.recentPlaylistIDs, as: [UUID].self) { recentPlaylistIDs = v }
        if let v = PersistenceStore.load(.hiddenHomeCardIds, as: Set<UUID>.self) { hiddenHomeCardIds = v }
        if let v = PersistenceStore.load(.hiddenHomeSongIds, as: Set<UUID>.self) { hiddenHomeSongIds = v }
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

    func removeFromPlaylist(track: Track, playlistId: UUID) {
        if let idx = userPlaylists.firstIndex(where: { $0.id == playlistId }) {
            userPlaylists[idx].tracks.removeAll { $0.id == track.id }
        }
    }

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
        let removedIDs = offsets.map { userPlaylists[$0].id }
        userPlaylists.remove(atOffsets: offsets)
        recentPlaylistIDs.removeAll { removedIDs.contains($0) }
    }

    // MARK: - Playback control

    @MainActor
    func play(track: Track, queue: [Track]? = nil) {
        guard track.videoId != nil else { return }

        // If the queue matches one of our playlists, record lastPlayedAt (descending sort for "Your playlists").
        if let q = queue {
            let qIDs = Set(q.map { $0.id })
            if let idx = userPlaylists.firstIndex(where: { Set($0.tracks.map { $0.id }) == qIDs }) {
                userPlaylists[idx].lastPlayedAt = Date()
            }
        }

        SongQueue.shared.play(track: track, queue: queue)
        syncState(with: track)
        // Mini player hidden → no compact surface to reach Now Playing, so a
        // user-initiated play opens the full cover. Auto-advance uses other paths.
        if !miniPlayerEnabled { showNowPlaying = true }
    }

    @MainActor
    func playNext(track: Track) {
        SongQueue.shared.playNext(track)
    }

    @MainActor
    func addToQueue(track: Track) {
        SongQueue.shared.addToQueue(track)
    }

    // For global add to playlist sheet support
    var showAddToPlaylist: Bool = false
    var addToPlaylistTrack: Track? = nil

    @MainActor
    func presentAddToPlaylist(for track: Track) {
        addToPlaylistTrack = track
        showAddToPlaylist = true
    }

    /// Record a play that originated in the Explore tab.
    /// This powers Explore-only recommendations and is kept small for performance.
    @MainActor
    func recordExplorePlay(_ track: Track) {
        guard track.videoId != nil else { return }
        // Avoid immediate duplicates
        if exploreHistory.first?.videoId == track.videoId { return }
        exploreHistory.insert(track, at: 0)
        if exploreHistory.count > 40 {
            exploreHistory.removeLast()
        }
    }

    /// Mix old persisted recommendations with newly generated ones.
    /// Remembers old recommendations, filters out recently played, and interleaves for variety.
    /// Called from Explore tab only.
    @MainActor
    func mixExploreRecommendations(oldRecs: [Track], newRecs: [Track]) -> [Track] {
        let playedIds = Set(exploreHistory.prefix(20).compactMap { $0.videoId })
        let filteredOld = oldRecs.filter { !playedIds.contains($0.videoId ?? "") }
        
        var mixed: [Track] = []
        var oldIter = filteredOld.makeIterator()
        var newIter = newRecs.makeIterator()
        
        // Interleave: prefer some old + new for mixing
        var useOld = true
        while mixed.count < 20 {
            if useOld, let old = oldIter.next() {
                if !mixed.contains(where: { $0.videoId == old.videoId }) {
                    mixed.append(old)
                }
            } else if let new = newIter.next() {
                if !mixed.contains(where: { $0.videoId == new.videoId }) && !playedIds.contains(new.videoId ?? "") {
                    mixed.append(new)
                }
            } else {
                break
            }
            useOld.toggle()
            // Occasionally add extra new for freshness
            if mixed.count % 3 == 0, let extra = newIter.next() {
                if !mixed.contains(where: { $0.videoId == extra.videoId }) {
                    mixed.append(extra)
                }
            }
        }
        
        // Update persisted
        exploreRecommendations = mixed
        return mixed
    }

    @MainActor
    private func syncState(with track: Track) {
        currentTrack = track
        isLoading = true
        errorMessage = nil
        playback.reset()
        nowPlayingCoverURL = nil
        liked = isLiked(track: track)

        let engine = MusicPlayer.shared
        engine.highFrequencyProgress = showNowPlaying

        engine.onNext     = { [weak self] in self?.playNextTrack() }
        engine.onPrevious = { [weak self] in self?.playPreviousTrack() }

        engine.onProgressUpdate = { [weak self] p in
            guard let self else { return }
            if !self.isSeeking { self.playback.progress = p }
            let dur = Int(engine.duration)
            if dur > 0 && dur != self.playback.totalSeconds {
                self.playback.totalSeconds = dur
            }
        }
        engine.onPlaybackStatusChange = { [weak self] isPlaying, isLoading in
            guard let self else { return }
            self.isPlaying = isPlaying
            self.isLoading = isLoading
        }
        engine.onPlaybackEnd = { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.playback.progress = 0
            self.playNextTrack(automatic: true)
        }
        engine.onError = { [weak self] error in
            self?.isLoading = false
            self?.isPlaying = false
            self?.errorMessage = error.localizedDescription
        }
        engine.onMediaInfo = { [weak self] hasVideo in
            self?.hasVideo = hasVideo
        }
        engine.onMetadata = { [weak self] meta in
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
        playback.progress = clampedProgress
        MusicPlayer.shared.seek(to: clampedProgress)
    }

    /// Called when Now Playing opens/closes — controls UI tick rate.
    func setNowPlayingVisible(_ visible: Bool) {
        MusicPlayer.shared.highFrequencyProgress = visible
    }

}
