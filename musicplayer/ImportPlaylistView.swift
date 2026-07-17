import SwiftUI

struct ImportPlaylistView: View {
    @Environment(ThemeState.self)  private var theme
    @Environment(PlayerState.self) private var player
    @Environment(\.dismiss)        private var dismiss

    @State private var urlText      = ""
    @State private var phase: Phase = .idle
    @State private var progress     = ImportProgress(phase: "", current: 0, total: 0)
    @State private var resultTracks: [TrackMetadata] = []
    @State private var missed:       [String]        = []
    @State private var errorMsg:     String?         = nil
    @State private var playlistName  = ""
    @State private var coverURL:     String?         = nil
    @State private var useBestGuess  = false
    @State private var importDone    = false   // drives the card's final "filled" frame
    @State private var showPlaylistPicker = false

    // Source-card carousel
    @State private var activeCard = 0
    @State private var cardDrag: CGFloat = 0
    @State private var showHint = true

    private let importer = PlaylistImporter()

    enum Phase { case idle, running, summary }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .idle, .running: importScaffold
                case .summary:        summaryView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Import Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(theme.ink)
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMsg != nil },
                set: { if !$0 { errorMsg = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMsg ?? "")
            }
        }
        .environment(theme)
        .environment(player)
    }

    // MARK: Idle / running — source carousel + paste form
    private var importScaffold: some View {
        VStack(spacing: 0) {
            carousel
                .padding(.top, 12)

            Text("Swipe to switch")
                .font(.system(size: 12, weight: .medium))
                .kerning(0.5)
                .foregroundStyle(theme.ink3)
                .opacity(showHint && phase == .idle ? 1 : 0)
                .padding(.top, 16)

            Spacer(minLength: 12)

            VStack(spacing: 0) {
                Text("Paste The Playlist Link")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .padding(.bottom, 8)
                Text("Enter a link to any Spotify, YouTube,\nor Music playlist to import it.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)

                TextField("Playlist Link", text: $urlText)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(phase == .running)
                    .padding(16)
                    .background(theme.palette.surfaceWarm, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(theme.line, lineWidth: 1))

                Button { startImport() } label: {
                    Text("Import")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canImport ? theme.palette.bg : theme.ink.opacity(0.35))
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(canImport ? theme.ink : theme.ink.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canImport || phase == .running)
                .padding(.top, 20)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var canImport: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Carousel
    private var carousel: some View {
        ZStack {
            ForEach(ImportSource.allCases) { src in
                let i = src.rawValue
                let isActive = (i == activeCard)
                ImportSourceCard(
                    source: src,
                    progress: isActive ? ringProgress : 0,
                    isDone: importDone && isActive,
                    counter: (isActive && phase == .running && progress.current > 0)
                        ? "\(progress.current) song\(progress.current == 1 ? "" : "s")" : "",
                    cardBG: theme.palette.surface,
                    ink: theme.ink,
                    ink3: theme.ink3
                )
                .scaleEffect(isActive ? activeScale : 0.82)
                .opacity(isActive ? activeOpacity : 0.5)
                .offset(x: cardX(i, isActive))
                .zIndex(isActive ? 1 : 0)
            }
        }
        .frame(height: 214)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(phase == .running ? nil : dragGesture)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: activeCard)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { cardDrag = $0.translation.width }
            .onEnded { v in
                let dx = v.translation.width
                let n = ImportSource.allCases.count
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                    if dx < -40 { activeCard = (activeCard + 1) % n }
                    else if dx > 40 { activeCard = (activeCard - 1 + n) % n }
                    cardDrag = 0
                }
                showHint = false
            }
    }

    /// -1 (left) / 0 (active) / +1 (right), wrapping for 3 cards.
    private func cardOffset(_ i: Int) -> Int {
        let n = ImportSource.allCases.count
        let diff = i - activeCard
        if diff == 0 { return 0 }
        if diff == 1 || diff == -(n - 1) { return 1 }
        return -1
    }

    private func cardX(_ i: Int, _ isActive: Bool) -> CGFloat {
        if isActive { return cardDrag }
        let off = cardOffset(i)
        // Neighbour subtly pulls in when the drag heads its way.
        let pull = min(1, abs(cardDrag) / 140)
        let relevant = (cardDrag < 0 && off == 1) || (cardDrag > 0 && off == -1)
        return CGFloat(off) * 70 * (1 - (relevant ? pull : 0) * 0.5)
    }

    private var activeScale: CGFloat { max(0.88, 1 - abs(cardDrag) / 500) }
    private var activeOpacity: Double { max(0.4, 1 - Double(abs(cardDrag)) / 260) }

    private var ringProgress: Double {
        if importDone { return 1 }
        guard phase == .running, progress.total > 0 else { return 0 }
        return min(1, Double(progress.current) / Double(progress.total))
    }

    // MARK: Summary
    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(spacing: 14) {
                    ThumbnailView(url: coverURL,
                                  seed: resultTracks.first?.videoId?.hashValue ?? 0,
                                  cornerRadius: 14)
                        .frame(width: 132, height: 132)
                        .shadow(color: theme.ink.opacity(0.18), radius: 14, y: 8)

                    Text("Import complete")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(theme.ink)
                    Text("\(resultTracks.count) track\(resultTracks.count == 1 ? "" : "s") imported" +
                         (missed.isEmpty ? "" : " · \(missed.count) not found"))
                        .font(.system(size: 14))
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                .padding(.bottom, 20)

                // Editable playlist name
                TextField("Playlist name", text: $playlistName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                // Missed tracks
                if !missed.isEmpty {
                    sectionHeader("Not found on YouTube")
                    VStack(spacing: 0) {
                        ForEach(missed.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(missed[i])
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(theme.ink2)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 18)
                                if i < missed.count - 1 {
                                    Divider().overlay(theme.lineSoft).padding(.leading, 18)
                                }
                            }
                        }
                    }
                    .background(theme.palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    Text("These tracks weren't matched on YouTube Music. You can add them manually.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink3)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }

                if !missed.isEmpty {
                    Toggle("Import best guesses for unmatched tracks", isOn: $useBestGuess)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .tint(theme.accent)
                }

                // Save button
                Button {
                    if useBestGuess && !missed.isEmpty {
                        Task {
                            await applyBestGuesses()
                            saveToLibrary()
                            dismiss()
                        }
                    } else {
                        saveToLibrary()
                        dismiss()
                    }
                } label: {
                    Text("Add to Library")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.palette.bg)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(resultTracks.isEmpty ? theme.ink.opacity(0.25) : theme.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(resultTracks.isEmpty)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                // Add the imported tracks into an existing library playlist instead.
                Button { showPlaylistPicker = true } label: {
                    Text("Add to Playlist")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(theme.palette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(resultTracks.isEmpty)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showPlaylistPicker) { playlistPicker }
    }

    // MARK: Playlist picker (add imported tracks to a library playlist)
    private var playlistPicker: some View {
        NavigationStack {
            Group {
                if player.userPlaylists.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(theme.ink3)
                        Text("No playlists in your library yet")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(player.userPlaylists) { pl in
                                Button { addImported(to: pl.id) } label: { pickerRow(pl) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPlaylistPicker = false }.foregroundStyle(theme.ink)
                }
            }
        }
        .environment(theme)
        .environment(player)
        .presentationDetents([.medium, .large])
    }

    private func pickerRow(_ pl: Playlist) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(url: pl.coverURL ?? pl.tracks.first?.thumbnailURL,
                          seed: pl.tracks.first?.seed ?? 0, cornerRadius: 8)
                .frame(width: 44, height: 44)
                .overlay {
                    if pl.tracks.isEmpty {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(theme.ink2)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(pl.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.ink)
                Text("\(pl.tracks.count) songs").font(.system(size: 12)).foregroundStyle(theme.ink3)
            }
            Spacer()
            Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(theme.ink3)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Add every imported track into the chosen playlist, then close the flow.
    private func addImported(to playlistId: UUID) {
        for meta in resultTracks {
            player.addToPlaylist(track: meta.asTrack(), playlistId: playlistId)
        }
        Haptics.addedToPlaylist()
        showPlaylistPicker = false
        dismiss()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.ink3)
            .kerning(1.1)
            .textCase(.uppercase)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
    }

    // MARK: - Logic

    private func startImport() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        importDone = false
        progress = ImportProgress(phase: "", current: 0, total: 0)
        phase = .running

        Task {
            do {
                let source = try PlaylistSource.detect(raw)
                await MainActor.run {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                        switch source {
                        case .youtube:  activeCard = ImportSource.youtube.rawValue
                        default:        activeCard = ImportSource.spotify.rawValue
                        }
                    }
                }
                switch source {
                case .youtube(let id):
                    let tracks = try await importer.importYouTube(playlistId: id) { p in
                        DispatchQueue.main.async { self.progress = p }
                    }
                    await MainActor.run {
                        self.resultTracks = tracks
                        self.missed = []
                        self.completeRunning()
                    }

                case .spotifyPlaylist(let id):
                    let (tracks, misses, name, cover) = try await importer.importSpotifyPlaylist(playlistId: id) { p in
                        DispatchQueue.main.async { self.progress = p }
                    }
                    await MainActor.run {
                        self.resultTracks = tracks
                        self.missed = misses
                        self.coverURL = cover
                        // Default the name field to the real Spotify name
                        // unless the user already typed one.
                        if self.playlistName.trimmingCharacters(in: .whitespaces).isEmpty,
                           let name, !name.isEmpty {
                            self.playlistName = name
                        }
                        self.completeRunning()
                    }

                case .spotifyAlbum(let id):
                    let (tracks, misses, name, cover) = try await importer.importSpotifyAlbum(albumId: id) { p in
                        DispatchQueue.main.async { self.progress = p }
                    }
                    await MainActor.run {
                        self.resultTracks = tracks
                        self.missed = misses
                        self.coverURL = cover
                        if self.playlistName.trimmingCharacters(in: .whitespaces).isEmpty,
                           let name, !name.isEmpty {
                            self.playlistName = name
                        }
                        self.completeRunning()
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMsg = error.localizedDescription
                    self.phase = .idle
                }
            }
        }
    }

    /// Import finished — let the badge settle into its filled last frame for a
    /// beat before revealing the summary.
    @MainActor private func completeRunning() {
        withAnimation { importDone = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            phase = .summary
            importDone = false
        }
    }

    private func saveToLibrary() {
        let name = playlistName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Imported Playlist"
            : playlistName
        let tracks = resultTracks.map { $0.asTrack() }
        let playlist = Playlist(title: name, author: "Import", tracks: tracks, coverURL: coverURL)
        player.userPlaylists.append(playlist)
    }

    private func applyBestGuesses() async {
        var newGuesses: [TrackMetadata] = []
        for miss in missed {
            let parts = miss.components(separatedBy: " — ")
            guard parts.count == 2 else { continue }
            if let guess = await importer.bestGuessMatch(title: parts[0], artist: parts[1]) {
                newGuesses.append(guess)
            }
        }
        resultTracks.append(contentsOf: newGuesses)
        missed.removeAll()
    }
}
