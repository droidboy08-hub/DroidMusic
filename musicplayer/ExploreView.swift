import SwiftUI

struct ExploreView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(SettingsState.self) private var settings

    @State private var madeForYou: [Track] = []
    @State private var trendingTracks: [Track] = []
    @State private var ytmShelves: [YouTubeAccountSync.YTMShelf] = []
    @State private var genreTracks: [Track] = []
    @State private var selectedGenre: Genre?
    @State private var isLoading = false
    @State private var isLoadingGenre = false
    @State private var errorMessage: String?

    private var recommendationKey: String {
        // Invalidate when explore history changes (scoped to Explore tab)
        let exploreSig = player.exploreHistory.prefix(3).compactMap { $0.videoId ?? $0.artist }.joined(separator: ",")
        return [
            player.currentTrack?.artist,
            player.likedTracks.last?.artist,
            player.recentSearches.first,
            exploreSig,
            settings.searchSource.rawValue
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    private var quickPicks: [Track] {
        uniqueTracks(madeForYou + trendingTracks)
    }

    /// Simple session-based continuation (approximates sequential/session models + RL greedy selection from blueprint).
    /// Uses the current Explore profile + MMR ranked results.
    private var exploreRadio: [Track] {
        let base = madeForYou + trendingTracks + Array(player.exploreHistory.prefix(4))
        let scored = rankForExplore(base).map { ($0, 1.0) }
        return Array(applyMMR(scored, lambda: 0.7).prefix(8))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                AppBarView(title: "Explore") {
                    player.showAccount = true
                }

                if isLoading && madeForYou.isEmpty {
                    loadingState
                } else {
                    // YouTube Music personalised shelves (signed-in)
                    if !ytmShelves.isEmpty {
                        ForEach(ytmShelves.prefix(5), id: \.title) { shelf in
                            horizontalTrackSection(
                                title: shelf.title,
                                subtitle: "From YouTube Music",
                                tracks: shelf.tracks
                            )
                        }
                    } else {
                        // Fallback: search-based sections
                        if !madeForYou.isEmpty {
                            horizontalTrackSection(
                                title: "Made for you",
                                subtitle: player.exploreHistory.isEmpty ? "Based on what you listen to" : "Personalized from your Explore activity",
                                tracks: madeForYou
                            )
                        }

                        // Explicit Explore-scoped history (only visible/populated from Explore plays)
                        if !player.exploreHistory.isEmpty {
                            let exploreQueue = uniqueTracks(player.exploreHistory + madeForYou)
                            horizontalTrackSection(
                                title: "Your Explore picks",
                                subtitle: "Recently played from here + similar",
                                tracks: Array(exploreQueue.prefix(8))
                            )
                        }

                        // Persisted old + new mixed recommendations (remembers previous Explore recs)
                        if !player.exploreRecommendations.isEmpty {
                            horizontalTrackSection(
                                title: "Your recommendations",
                                subtitle: "Old favorites mixed with new from recent plays",
                                tracks: Array(player.exploreRecommendations.prefix(10))
                            )
                        }

                        if !quickPicks.isEmpty {
                            quickPicksSection
                        }

                        if !exploreRadio.isEmpty {
                            horizontalTrackSection(
                                title: "Explore Radio",
                                subtitle: "Keeps the vibe from your recent plays",
                                tracks: exploreRadio
                            )
                        }

                        if !trendingTracks.isEmpty {
                            horizontalTrackSection(
                                title: "Trending now",
                                subtitle: "Popular tracks to try",
                                tracks: trendingTracks
                            )
                        }
                    }

                    moodsSection

                    if let selectedGenre {
                        genreResultsSection(selectedGenre)
                    }

                    if let errorMessage, madeForYou.isEmpty && trendingTracks.isEmpty {
                        errorState(errorMessage)
                    }
                }

                Color.clear.frame(height: theme.showMiniPlayer ? 110 : 70)
            }
        }
        .scrollIndicators(.hidden)
        .background(theme.palette.bg)
        .refreshable {
            await loadRecommendations()
        }
        .task(id: recommendationKey) {
            await loadRecommendations()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(theme.accent)
            Text("Finding music for you")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func horizontalTrackSection(
        title: String,
        subtitle: String,
        tracks: [Track]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: title, subtitle: subtitle)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(tracks.prefix(12)) { track in
                        Button {
                            player.recordExplorePlay(track)
                            player.play(track: track, queue: tracks)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ThumbnailView(
                                    url: track.thumbnailURL,
                                    seed: track.seed,
                                    cornerRadius: 12
                                )
                                .frame(width: 148, height: 148)

                                Text(track.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)

                                HStack {
                                    Text(track.artist)
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.ink3)
                                        .lineLimit(1)
                                    Spacer()
                                    TrackMenu(track: track)
                                }
                            }
                            .frame(width: 148, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.bottom, 30)
    }

    private var quickPicksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Quick picks",
                subtitle: "Start a radio from any song"
            )

            VStack(spacing: 0) {
                ForEach(Array(quickPicks.prefix(5).enumerated()), id: \.element.id) { index, track in
                    Button {
                        player.recordExplorePlay(track)
                        player.play(track: track, queue: quickPicks)
                    } label: {
                        HStack(spacing: 12) {
                            ThumbnailView(
                                url: track.thumbnailURL,
                                seed: track.seed,
                                cornerRadius: 8
                            )
                            .frame(width: 50, height: 50)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.ink3)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.ink2)
                                .frame(width: 34, height: 34)
                                .background(theme.palette.surfaceWarm, in: Circle())

                            TrackMenu(track: track)
                        }
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            if index < min(quickPicks.count, 5) - 1 {
                                Rectangle()
                                    .fill(theme.lineSoft)
                                    .frame(height: 1)
                                    .padding(.leading, 62)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
        }
        .padding(.bottom, 30)
    }

    private var moodsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Browse all",
                subtitle: "Moods and genres"
            )

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(SampleData.genres) { genre in
                    genreCard(genre)
                }
            }
            .padding(.horizontal, 22)
        }
        .padding(.bottom, 30)
    }

    private func genreCard(_ genre: Genre) -> some View {
        let isSelected = selectedGenre?.id == genre.id

        return Button {
            selectedGenre = genre
            Task {
                await loadGenre(genre)
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: genre.colorHex))
                    .frame(height: 82)

                Image(systemName: genreIcon(for: genre.name))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white.opacity(0.22))
                    .rotationEffect(.degrees(12))
                    .offset(x: 108, y: -18)

                Text(genre.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private func genreResultsSection(_ genre: Genre) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "\(genre.name) picks",
                subtitle: "Recommended for this mood"
            )

            if isLoadingGenre {
                ProgressView()
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(genreTracks.prefix(6).enumerated()), id: \.element.id) { index, track in
                        chartRow(
                            track: track,
                            rank: index + 1,
                            isLast: index == min(genreTracks.count, 6) - 1
                        )
                    }
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.bottom, 30)
    }

    private func chartRow(track: Track, rank: Int, isLast: Bool) -> some View {
        Button {
            player.recordExplorePlay(track)
            player.play(track: track, queue: genreTracks)
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(rank <= 3 ? theme.accent : theme.ink3)
                    .frame(width: 24)

                ThumbnailView(
                    url: track.thumbnailURL,
                    seed: track.seed,
                    cornerRadius: 8
                )
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 30, height: 30)

                TrackMenu(track: track)
            }
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(theme.lineSoft)
                        .frame(height: 1)
                        .padding(.leading, 82)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(theme.ink)
                .kerning(-0.35)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 22)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.ink3)
            Text("Recommendations unavailable")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 30)
    }

    @MainActor
    private func loadRecommendations() async {
        isLoading = true
        errorMessage = nil

        // Try YouTube Music personalised home first (requires sign-in)
        if player.isYouTubeLoggedIn {
            let shelves = await YouTubeAccountSync.shared.fetchHomeRecommendations()
            if !shelves.isEmpty {
                ytmShelves    = shelves
                madeForYou    = shelves.first?.tracks ?? []
                trendingTracks = shelves.dropFirst().first?.tracks ?? []
                
                // Remember YTM recs for future mixing with new Explore plays
                let ytmRecs = uniqueTracks((shelves.first?.tracks ?? []) + (shelves.dropFirst().first?.tracks ?? []))
                let mixed = player.mixExploreRecommendations(oldRecs: player.exploreRecommendations, newRecs: ytmRecs)
                player.exploreRecommendations = Array(mixed.prefix(20))
                
                isLoading = false
                return
            }
        }

        // Fall back to search-based recommendations
        ytmShelves = []
        let source = settings.searchSource

        // Seed from old recommendations if we have history but no current recs
        if player.exploreRecommendations.isEmpty && !player.exploreHistory.isEmpty {
            player.exploreRecommendations = Array(player.exploreHistory.prefix(8))
        }

        // Explore-scoped candidate generation (limited to keep it fast & optimized)
        let exploreArtists = topExploreArtists(limit: 2)
        let baseQuery = personalizedQuery

        do {
            var candidates: [Track] = []

            // Core personalized fetch
            let main = try await DemusNetwork.shared.search(query: baseQuery, source: source)
            candidates.append(contentsOf: main)

            // Extra targeted searches driven by Explore play history
            for artist in exploreArtists {
                let more = try await DemusNetwork.shared.search(query: "\(artist) mix similar", source: source)
                candidates.append(contentsOf: more)
            }

            // Some discovery / trending
            let trend = try await DemusNetwork.shared.search(query: "trending music", source: source)
            candidates.append(contentsOf: trend)

            // Local re-ranking using simple Explore taste profile (no heavy ML)
            let ranked = rankForExplore(candidates)
            let newRecs = uniqueTracks(Array(ranked.prefix(14)))
            
            // Mix old remembered recommendations with new ones (from recent Explore plays)
            let mixed = player.mixExploreRecommendations(oldRecs: player.exploreRecommendations, newRecs: newRecs)
            madeForYou = uniqueTracks(mixed)
            trendingTracks = uniqueTracks(Array(ranked.dropFirst(5).prefix(10)))
        } catch {
            errorMessage = error.localizedDescription
            // last resort
            if madeForYou.isEmpty {
                let fallback = try? await DemusNetwork.shared.search(query: "discover new music", source: source)
                madeForYou = uniqueTracks(fallback ?? [])
            }
        }
        isLoading = false
    }

    @MainActor
    private func loadGenre(_ genre: Genre) async {
        isLoadingGenre = true
        genreTracks = []

        do {
            genreTracks = uniqueTracks(
                try await DemusNetwork.shared.search(
                    query: "\(genre.name) music",
                    source: settings.searchSource
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingGenre = false
    }

    private var personalizedQuery: String {
        // Prefer Explore history (scoped recs) then general taste
        if let artist = topExploreArtist {
            return "\(artist) similar songs"
        }
        if let artist = player.currentTrack?.artist, !artist.isEmpty {
            return "\(artist) songs"
        }
        if let artist = player.likedTracks.last?.artist, !artist.isEmpty {
            return "\(artist) songs"
        }
        if let recentSearch = player.recentSearches.first {
            return recentSearch
        }
        return "new music 2025"
    }

    /// Top artist from recent Explore plays (for Explore-scoped personalization)
    private var topExploreArtist: String? {
        topExploreArtists(limit: 1).first
    }

    private func topExploreArtists(limit: Int) -> [String] {
        guard !player.exploreHistory.isEmpty else { return [] }
        // Recency decay: newer plays weigh more (exponential decay approximation)
        var weighted: [String: Double] = [:]
        for (index, track) in player.exploreHistory.prefix(30).enumerated() {
            let weight = pow(0.85, Double(index))  // decay factor
            weighted[track.artist, default: 0] += weight
        }
        return weighted.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    private func uniqueTracks(_ tracks: [Track]) -> [Track] {
        var seenVideoIds = Set<String>()
        return tracks.filter { track in
            guard let videoId = track.videoId, !videoId.isEmpty else { return false }
            return seenVideoIds.insert(videoId).inserted
        }
    }

    /// Lightweight local re-ranker for Explore recommendations.
    /// Implements ideas from the blueprint: content-based (keywords), recency-weighted CF (history), + MMR diversity.
    /// Fully client-side, O(n log n) on tiny sets, no external deps.
    private func rankForExplore(_ candidates: [Track]) -> [Track] {
        let history = player.exploreHistory
        guard !history.isEmpty else { return uniqueTracks(candidates) }

        // Recency + frequency weighted profile (user "embedding" approximation)
        var artistWeights: [String: Double] = [:]
        for (index, track) in history.prefix(30).enumerated() {
            let decay = pow(0.88, Double(index))
            artistWeights[track.artist, default: 0] += decay
        }

        let likedExploreKeywords: Set<String> = Set(
            history.prefix(12).flatMap { track in
                track.title.lowercased().split(separator: " ")
                    .map(String.init)
                    .filter { $0.count > 3 }
            }
        )

        let likedArtistsOverall = Set(player.likedTracks.prefix(12).map { $0.artist })

        func relevanceScore(_ t: Track) -> Double {
            var s: Double = 0.0

            if let w = artistWeights[t.artist] {
                s += w * 3.5
            } else if likedArtistsOverall.contains(t.artist) {
                s += 1.2
            }

            let titleWords = Set(t.title.lowercased().split(separator: " ").map(String.init))
            let overlap = titleWords.intersection(likedExploreKeywords).count
            s += Double(overlap) * 0.9

            if !t.explicit { s += 0.25 }
            return s
        }

        let unique = uniqueTracks(candidates)
        let scored = unique.map { ($0, relevanceScore($0)) }

        // Apply MMR diversity (blueprint style) to avoid artist overload
        return applyMMR(scored, lambda: 0.65)
    }

    /// Simple Maximal Marginal Relevance for diversity (approximates the blueprint's diversity re-ranker).
    /// Uses artist as similarity proxy for optimization (cheap).
    private func applyMMR(_ scored: [(Track, Double)], lambda: Double) -> [Track] {
        guard !scored.isEmpty else { return [] }
        var selected: [Track] = []
        var remaining = scored

        // Pick highest relevance first
        if let first = remaining.max(by: { $0.1 < $1.1 }) {
            selected.append(first.0)
            remaining.removeAll { $0.0.id == first.0.id }
        }

        while selected.count < min(12, scored.count), !remaining.isEmpty {
            var bestIdx = 0
            var bestScore = -Double.infinity

            for (i, (track, rel)) in remaining.enumerated() {
                let maxSim = selected.map { other in
                    // Similarity proxy: same artist = 1.0, else 0
                    track.artist == other.artist ? 1.0 : 0.0
                }.max() ?? 0.0

                let mmr = lambda * rel - (1 - lambda) * maxSim
                if mmr > bestScore {
                    bestScore = mmr
                    bestIdx = i
                }
            }

            let chosen = remaining[bestIdx]
            selected.append(chosen.0)
            remaining.remove(at: bestIdx)
        }

        return selected
    }

    private func genreIcon(for genre: String) -> String {
        switch genre {
        case "Jazz": "music.quarternote.3"
        case "Hip-Hop": "waveform"
        case "Classical": "pianokeys"
        case "Electronic": "bolt.fill"
        case "Ambient": "cloud.fill"
        case "Acoustic": "guitars.fill"
        default: "music.note"
        }
    }
}
