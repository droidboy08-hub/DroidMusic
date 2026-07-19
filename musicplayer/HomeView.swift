import SwiftUI

struct HomeView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(\.auriaSelectTab) private var selectTab

    // Home playlist rail: long-press a card to reveal its Hide options.
    @State private var revealHideFor: UUID? = nil
    @State private var revealTask: Task<Void, Never>? = nil
    @State private var pushedPlaylistId: UUID? = nil   // programmatic push (tap-to-open)

    // Mood chips → each opens Search pre-filled with its query (distinct music per mood).
    private let moods: [(label: String, icon: String)] = [
        ("Chill", "leaf.fill"),
        ("Focus", "scope"),
        ("Energize", "bolt.fill"),
        ("Late night", "moon.stars.fill"),
        ("Throwback", "backward.fill"),
    ]

    var body: some View {
        // Build the de-duplicated library once per render and reuse it for the
        // empty check, the rows, and each row's play queue.
        let library = libraryTracks
        return NavigationStack {
            List {
                // Top sections keep their own internal padding, so they sit as
                // edge-to-edge, separator-less, transparent rows.
                Group {
                    header
                    quickStart
                    playlistRail

                    sectionHeader(title: "From your library", actionTitle: "Library") {
                        selectTab(.library)
                    }
                    .padding(.bottom, 6)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                // The library itself — a real List so rows are cell-reused and
                // get native separators (and easy swipe actions later).
                if library.isEmpty {
                    compactEmptyRow(icon: "music.note", text: "Like songs or import a playlist to fill your library.")
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(library) { track in
                        trackRow(track: track, queue: library)
                            .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(theme.lineSoft)
                    }
                }

                Color.clear
                    .frame(height: 110)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .background(theme.palette.bg)
            .onScrollPhaseChange { _, phase in
                if phase != .idle, revealHideFor != nil { dismissReveal() }
            }
            .navigationDestination(item: $pushedPlaylistId) { id in
                if let pl = player.userPlaylists.first(where: { $0.id == id }) {
                    PlaylistDetailView(playlist: pl)
                }
            }
        }
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

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Jump in")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Shuffle the whole library
                    actionChip(icon: "shuffle", label: "Shuffle", filled: true) { shuffleLibrary() }

                    // Mood chips → curated searches
                    ForEach(moods, id: \.label) { mood in
                        actionChip(icon: mood.icon, label: mood.label, filled: false) { runSearch(mood.label) }
                    }

                    // Recent searches → re-run
                    if !player.recentSearches.isEmpty {
                        Rectangle().fill(theme.line).frame(width: 1, height: 20).padding(.horizontal, 2)
                        ForEach(player.recentSearches.prefix(8), id: \.self) { term in
                            searchChip(term)
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.bottom, 28)
    }

    private func actionChip(icon: String, label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if revealHideFor != nil { dismissReveal() }
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11.5, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(filled ? theme.palette.bg : theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(filled ? theme.accent : Color.clear)
                    .overlay(Capsule().strokeBorder(filled ? Color.clear : theme.line, lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
    }

    private func searchChip(_ term: String) -> some View {
        Button {
            if revealHideFor != nil { dismissReveal() }
            runSearch(term)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold))
                Text(term).font(.system(size: 13))
            }
            .foregroundStyle(theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func shuffleLibrary() {
        let queue = libraryTracks.shuffled()
        guard let first = queue.first else { return }
        player.play(track: first, queue: queue)
    }

    private func runSearch(_ term: String) {
        player.pendingSearch = term
        selectTab(.search)
    }

    private var playlistRail: some View {
        let visible = player.userPlaylists.filter { !player.hiddenHomeCardIds.contains($0.id) }
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Your playlists")

            if visible.isEmpty {
                compactEmptyRow(icon: "music.note.list", text: "Create playlists from Library or add the current song from Now Playing.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(visible) { playlist in
                            ZStack(alignment: .top) {
                                // Tap and long-press are mutually exclusive here — a
                                // recognised long-press won't also fire the tap, so the
                                // menu no longer competes with navigation.
                                playlistCard(playlist)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Any tap while a menu is open just dismisses it.
                                        if revealHideFor != nil { dismissReveal() }
                                        else { pushedPlaylistId = playlist.id }
                                    }
                                    .onLongPressGesture(minimumDuration: 0.55) {
                                        Haptics.impact(.medium)
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            revealHideFor = (revealHideFor == playlist.id) ? nil : playlist.id
                                        }
                                        if revealHideFor == playlist.id { scheduleRevealTimeout(for: playlist.id) }
                                        else { revealTask?.cancel() }
                                    }

                                if revealHideFor == playlist.id {
                                    hideMenu(for: playlist)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .onScrollPhaseChange { _, phase in
                    if phase != .idle, revealHideFor != nil { dismissReveal() }
                }
            }
        }
        .padding(.bottom, 30)
    }

    /// Long-press menu over a card's artwork: "Hide" (card + songs off Home) and
    /// a "Hide Songs" ⇄ "Show Songs" toggle for just this playlist's songs.
    private func hideMenu(for playlist: Playlist) -> some View {
        let songsHidden = player.hiddenHomeSongIds.contains(playlist.id)
        return VStack(spacing: 8) {
            // Hides the card too → the card leaves the rail, so this dismisses.
            menuPill("Hide", "eye.slash.fill", dismiss: true) {
                player.hiddenHomeCardIds.insert(playlist.id)
                player.hiddenHomeSongIds.insert(playlist.id)
            }
            // Toggles just the songs; the menu stays so its label can flip.
            menuPill(songsHidden ? "Show Songs" : "Hide Songs", "music.note.list", dismiss: false) {
                if songsHidden { player.hiddenHomeSongIds.remove(playlist.id) }
                else { player.hiddenHomeSongIds.insert(playlist.id) }
                scheduleRevealTimeout(for: playlist.id)   // keep it up, restart the timer
            }
        }
        .padding(12)
        .frame(width: 148, height: 148)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { dismissReveal() }   // tap the scrim to dismiss
        .transition(.opacity)
    }

    private func menuPill(_ title: String, _ icon: String, dismiss: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                action()
                if dismiss { revealHideFor = nil; revealTask?.cancel() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(.white.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func dismissReveal() {
        revealTask?.cancel()
        withAnimation { revealHideFor = nil }
    }

    /// Auto-dismiss the revealed menu after a few seconds of no interaction.
    private func scheduleRevealTimeout(for id: UUID) {
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, revealHideFor == id {
                withAnimation { revealHideFor = nil }
            }
        }
    }

    /// Every song in the user's library — liked songs plus all playlist
    /// tracks, de-duplicated by videoId (falling back to title+artist) so the
    /// same song appearing in several places is listed once.
    private var libraryTracks: [Track] {
        func key(_ t: Track) -> String { t.videoId ?? "\(t.title)|\(t.artist)".lowercased() }
        // Songs from playlists the user chose to hide from Home's library list.
        let hiddenKeys = Set(
            player.userPlaylists
                .filter { player.hiddenHomeSongIds.contains($0.id) }
                .flatMap { $0.tracks }
                .map(key)
        )
        var seen = Set<String>()
        var result: [Track] = []
        func add(_ tracks: [Track]) {
            for t in tracks {
                let k = key(t)
                if hiddenKeys.contains(k) { continue }
                if seen.insert(k).inserted { result.append(t) }
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

    private func trackRow(track: Track, queue: [Track]) -> some View {
        HStack(spacing: 12) {
            // Tapping the song area plays it; the menu is a sibling control so
            // it isn't nested inside this button.
            Button {
                if revealHideFor != nil { dismissReveal() }
                player.play(track: track, queue: queue)
            } label: {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !track.duration.isEmpty {
                Text(track.duration)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(theme.ink3)
            }

            TrackMenu(track: track)
        }
        .padding(.vertical, 10)
    }
}
