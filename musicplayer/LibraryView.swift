import SwiftUI

struct LibraryView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player

    private let filters = ["Playlists", "Songs", "Albums", "Artists"]
    // Remembers the last-opened tab (persists across launches) so it's the default.
    @AppStorage("libraryActiveFilter") private var activeFilter = "Playlists"
    @State private var showImport = false
    @State private var isSyncing = false
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                AppBarView(
                    title: "Library",
                    onProfile: { player.showAccount = true },
                    onSync: {
                        guard !isSyncing else { return }
                        isSyncing = true
                        Task {
                            await YouTubeAccountSync.shared.sync(player: player)
                            await MainActor.run { isSyncing = false }
                        }
                    },
                    isSyncing: isSyncing
                )
                filterChips
                if activeFilter == "Playlists" || activeFilter == "Songs" {
                    searchBar
                }
                sortRow

                switch activeFilter {
                case "Songs":    songsContent
                case "Albums":   albumsContent
                case "Artists":  artistsContent
                default:         playlistsContent
                }

                Color.clear.frame(height: theme.showMiniPlayer ? 110 : 70)
            }
        }
        .scrollIndicators(.hidden)
        .background(theme.palette.bg)
    }

    // MARK: - Filter chip rail
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { f in
                    Button {
                        searchText = ""
                        withAnimation(.spring(duration: 0.22)) { activeFilter = f }
                    } label: {
                        Text(f)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(activeFilter == f ? theme.palette.bg : theme.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background {
                                Capsule()
                                    .fill(activeFilter == f ? theme.ink : .clear)
                                    .overlay(Capsule().strokeBorder(
                                        activeFilter == f ? theme.ink : theme.line,
                                        lineWidth: 1))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Search
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(theme.ink3)
            TextField(activeFilter == "Songs" ? "Search songs" : "Search playlists", text: $searchText)
                .font(.system(size: 15))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.palette.surfaceWarm, in: Capsule())
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var filteredPlaylists: [Playlist] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return player.userPlaylists }
        return player.userPlaylists.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var filteredSongs: [Track] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return player.likedTracks }
        return player.likedTracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Sort row
    private var sortRow: some View {
        HStack(spacing: 0) {
            Button {} label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14))
                    Text("Date added")
                        .font(.system(size: 13.5))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                }
                .foregroundStyle(theme.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {} label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 22)
        }
        .padding(.leading, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Playlists content (smart tiles + user playlists)
    private var playlistsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Smart collection tiles (hidden while searching to focus on results)
            if !isSearching {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 14
                ) {
                    NavigationLink {
                        PlaylistDetailView(playlist: Playlist(title: "Liked Songs", author: "You", tracks: player.likedTracks))
                    } label: {
                        libraryTile(label: "Liked", icon: "heart.fill", count: "\(player.likedTracks.count) tracks")
                    }
                    .buttonStyle(.plain)

                    Button { showImport = true } label: {
                        libraryTile(label: "Import", icon: "arrow.down.circle", count: "0 tracks")
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showImport) {
                        ImportPlaylistView()
                            .environment(theme)
                            .environment(player)
                    }
                }
                .padding(.horizontal, 22)
            }

            // User-created playlists
            let playlists = filteredPlaylists
            if !playlists.isEmpty {
                Text("My Playlists")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                    .kerning(1.2)
                    .textCase(.uppercase)
                    .padding(.horizontal, 22)
                    .padding(.top, isSearching ? 8 : 28)
                    .padding(.bottom, 10)

                LazyVStack(spacing: 0) {
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { idx, pl in
                        NavigationLink {
                            PlaylistDetailView(playlist: pl)
                        } label: {
                            userPlaylistRow(pl, isLast: idx == playlists.count - 1)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            let isHidden = player.hiddenHomeCardIds.contains(pl.id)
                            Button {
                                Haptics.menuSelection()
                                if isHidden {
                                    player.hiddenHomeCardIds.remove(pl.id)
                                    player.hiddenHomeSongIds.remove(pl.id)
                                } else {
                                    player.hiddenHomeCardIds.insert(pl.id)
                                    player.hiddenHomeSongIds.insert(pl.id)
                                }
                            } label: {
                                Label(isHidden ? "Show in Home" : "Hide from Home",
                                      systemImage: isHidden ? "house" : "house.slash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
            } else if isSearching {
                emptyState(icon: "magnifyingglass", message: "No playlists match “\(searchText)”")
            }
        }
    }

    private func userPlaylistRow(_ pl: Playlist, isLast: Bool) -> some View {
        HStack(spacing: 14) {
            ThumbnailView(url: pl.coverURL ?? pl.tracks.first?.thumbnailURL, seed: pl.tracks.first?.seed ?? 0, cornerRadius: 8)
                .frame(width: 44, height: 44)
                .overlay {
                    if pl.tracks.isEmpty {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(theme.ink2)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(pl.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text("\(pl.tracks.count) songs")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.ink3)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(theme.lineSoft).frame(height: 1) }
        }
    }

    private func libraryTile(label: String, icon: String, count: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.ink.opacity(0.85))
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text(count)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.ink3)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(theme.palette.surfaceWarm)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Songs content (list rows)
    private var songsContent: some View {
        Group {
            let songs = filteredSongs
            if songs.isEmpty {
                emptyState(icon: isSearching ? "magnifyingglass" : "music.note",
                           message: isSearching ? "No songs match “\(searchText)”" : "No songs yet")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { idx, track in
                        songRow(track: track, isLast: idx == songs.count - 1)
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }

    private func songRow(track: Track, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(url: track.thumbnailURL, seed: track.seed, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3)
            }
            Spacer()
            Text(track.duration)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.ink3)
            TrackMenu(track: track)
        }
        .padding(.vertical, 10)
        .onTapGesture {
            player.play(track: track, queue: player.likedTracks)
        }
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(theme.lineSoft).frame(height: 1) }
        }
    }

    // MARK: - Albums content (2-col grid)
    private var albumsContent: some View {
        Group {
            emptyState(icon: "square.stack", message: "No albums yet")
        }
    }

    // MARK: - Artists content (list rows with avatar)
    private var artistsContent: some View {
        Group {
            emptyState(icon: "person.2", message: "No artists yet")
        }
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(theme.ink3)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}


