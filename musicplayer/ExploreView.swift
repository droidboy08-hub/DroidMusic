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
        [
            player.currentTrack?.artist,
            player.likedTracks.last?.artist,
            player.recentSearches.first,
            settings.searchSource.rawValue
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    private var quickPicks: [Track] {
        uniqueTracks(madeForYou + trendingTracks)
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
                                subtitle: "Based on what you listen to",
                                tracks: madeForYou
                            )
                        }
                        if !quickPicks.isEmpty {
                            quickPicksSection
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

                                Text(track.artist)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.ink3)
                                    .lineLimit(1)
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
                isLoading = false
                return
            }
        }

        // Fall back to search-based recommendations
        ytmShelves = []
        let tasteQuery = personalizedQuery
        let source = settings.searchSource
        do {
            async let personal = DemusNetwork.shared.search(query: tasteQuery, source: source)
            async let trending = DemusNetwork.shared.search(query: "trending music", source: source)
            let (personalResults, trendingResults) = try await (personal, trending)
            madeForYou     = uniqueTracks(personalResults)
            trendingTracks = uniqueTracks(trendingResults)
        } catch {
            errorMessage = error.localizedDescription
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
        if let artist = player.currentTrack?.artist, !artist.isEmpty {
            return "\(artist) songs"
        }
        if let artist = player.likedTracks.last?.artist, !artist.isEmpty {
            return "\(artist) songs"
        }
        if let recentSearch = player.recentSearches.first {
            return recentSearch
        }
        return "new music"
    }

    private func uniqueTracks(_ tracks: [Track]) -> [Track] {
        var seenVideoIds = Set<String>()
        return tracks.filter { track in
            guard let videoId = track.videoId, !videoId.isEmpty else { return false }
            return seenVideoIds.insert(videoId).inserted
        }
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
