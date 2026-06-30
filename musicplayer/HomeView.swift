import SwiftUI

struct HomeView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(\.auriaSelectTab) private var selectTab

    enum LibrarySort: String, CaseIterable {
        case lastPlayed = "Last Played"
        case name = "Name"
        case recentlyAdded = "Recently Added"
        case random = "Random"
    }

    @State private var librarySort: LibrarySort = .lastPlayed

    private var recentTracks: [Track] {
        if let currentTrack = player.currentTrack {
            return [currentTrack] + player.likedTracks.filter { $0.id != currentTrack.id }
        }
        return player.likedTracks
    }

    private var sortedLibraryTracks: [Track] {
        let base = libraryTracks
        switch librarySort {
        case .lastPlayed:
            let recent = player.recentPlayOrder
            let recentMap = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element.id, $0.offset) })
            return base.sorted { a, b in
                let posA = recentMap[a.id] ?? Int.max
                let posB = recentMap[b.id] ?? Int.max
                return posA < posB
            }
        case .name:
            return base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recentlyAdded:
            // Reverse of build order (liked first, then playlists) approximates recently added
            return Array(base.reversed())
        case .random:
            return base.shuffled()
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Top sections (they already contain their own horizontal padding)
                header

                recentlySearched

                playlistRail

                HStack(alignment: .center) {
                    Text("From your library")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.ink)
                        .kerning(-0.3)

                    Spacer()

                    // Order toggle button
                    Button {
                        cycleLibrarySort()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: librarySortIcon)
                                .font(.system(size: 12))
                            Text(librarySort.rawValue)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.palette.surfaceWarm, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button("Library") {
                        selectTab(.library)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 6)

                // Library tracks (using LazyVStack + ScrollView instead of List).
                // This avoids SwiftUI "List failed to visit cell content" warnings
                // that commonly appear when List + NavigationLink + complex cells
                // live inside a NavigationStack that is also being opacity/drawingGroup-ed
                // by the custom tab system.
                if libraryTracks.isEmpty {
                    compactEmptyRow(icon: "music.note", text: "Like songs or import a playlist to fill your library.")
                        .padding(.horizontal, 22)
                } else {
                    let tracks = sortedLibraryTracks
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        trackRow(track: track)
                            .padding(.horizontal, 22)

                        if index < tracks.count - 1 {
                            Rectangle()
                                .fill(theme.lineSoft)
                                .frame(height: 1)
                                .padding(.leading, 22)
                        }
                    }
                }

                Color.clear
                    .frame(height: 110)
            }
        }
        .scrollIndicators(.hidden)
        .background(theme.palette.bg)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Home")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .kerning(-0.7)
            }

            Spacer()

            Button {
                selectTab(.search)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 38, height: 38)
                    .background(theme.palette.surfaceWarm, in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                player.showAccount = true
            } label: {
                Image(systemName: "person")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.palette.bg)
                    .frame(width: 38, height: 38)
                    .background(theme.ink, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private var recentlySearched: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Recently played")

            if recentTracks.isEmpty {
                compactEmptyRow(icon: "clock.arrow.circlepath", text: "Songs you play or like will appear here.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentTracks.prefix(8)) { track in
                            Button {
                                player.play(track: track, queue: recentTracks)
                            } label: {
                                HStack(spacing: 0) {
                                    Text(track.title)
                                        .fontWeight(.semibold)
                                    Text(" · \(track.artist)")
                                        .foregroundStyle(theme.ink3)
                                }
                                .font(.system(size: 13))
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: 120, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(theme.palette.surface)
                                .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22)
                }
            }
        }
        .padding(.bottom, 28)
    }

    private var playlistRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Your playlists")

            let playlists = prioritizedPlaylists
            if playlists.isEmpty {
                compactEmptyRow(icon: "music.note.list", text: "Create playlists from Library or add the current song from Now Playing.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(playlists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                playlistCard(playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22)
                }
            }
        }
        .padding(.bottom, 30)
    }

    /// Sort playlists by lastPlayedAt descending (most recently played first).
    /// Playlists never played (lastPlayedAt == nil) come after, preserving their relative order.
    private var prioritizedPlaylists: [Playlist] {
        let playlists = player.userPlaylists
        return playlists.enumerated().sorted { lhs, rhs in
            let l = lhs.element.lastPlayedAt ?? .distantPast
            let r = rhs.element.lastPlayedAt ?? .distantPast
            if l != r { return l > r }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// Every song in the user's library — liked songs plus all playlist
    /// tracks, de-duplicated by videoId (falling back to title+artist) so the
    /// same song appearing in several places is listed once.
    private var libraryTracks: [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        func add(_ tracks: [Track]) {
            for t in tracks {
                let key = t.videoId ?? "\(t.title)|\(t.artist)".lowercased()
                if seen.insert(key).inserted { result.append(t) }
            }
        }
        add(player.likedTracks)
        for playlist in player.userPlaylists { add(playlist.tracks) }
        return result
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .kerning(1.4)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 22)
    }

    private func sectionHeader(title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(theme.ink)
                .kerning(-0.3)

            Spacer()

            Button(actionTitle, action: action)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
    }

    private func cycleLibrarySort() {
        let all = LibrarySort.allCases
        if let idx = all.firstIndex(of: librarySort) {
            librarySort = all[(idx + 1) % all.count]
        }
    }

    private var librarySortIcon: String {
        switch librarySort {
        case .lastPlayed: return "clock.arrow.circlepath"
        case .name: return "textformat.abc"
        case .recentlyAdded: return "calendar.badge.plus"
        case .random: return "shuffle"
        }
    }

    private func compactEmptyRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(theme.ink3)
                .frame(width: 38, height: 38)
                .background(theme.palette.surfaceWarm, in: Circle())

            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(14)
        .background(theme.palette.surface.opacity(0.72))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 22)
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if playlist.coverURL != nil || playlist.tracks.first != nil {
                    ThumbnailView(
                        url: playlist.coverURL ?? playlist.tracks.first?.thumbnailURL,
                        seed: playlist.tracks.first?.seed ?? 0,
                        cornerRadius: 12
                    )
                    .frame(width: 148, height: 148)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.palette.surfaceWarm)
                        .frame(width: 148, height: 148)

                    Image(systemName: "music.note.list")
                        .font(.system(size: 34, weight: .thin))
                        .foregroundStyle(theme.ink2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text("\(playlist.tracks.count) songs")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3)
            }
            .frame(width: 148, alignment: .leading)
        }
    }

    private func trackRow(track: Track) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(url: track.thumbnailURL, seed: track.seed, cornerRadius: 8)
                .frame(width: 48, height: 48)

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

            if !track.duration.isEmpty {
                Text(track.duration)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(theme.ink3)
            }

            TrackMenu(track: track)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            player.play(track: track, queue: libraryTracks)
        }
    }
}
