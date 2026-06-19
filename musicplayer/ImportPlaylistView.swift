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

    private let importer = PlaylistImporter()

    enum Phase { case idle, running, summary }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .idle:    idleView
                case .running: progressView
                case .summary: summaryView
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

    // MARK: Idle — URL paste
    private var idleView: some View {
        ScrollView {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "link.badge.plus")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(theme.ink2)

            VStack(spacing: 8) {
                Text("Paste a playlist link")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text("Supports YouTube, YouTube Music\nand Spotify (public playlists)")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                TextField("https://music.youtube.com/playlist?list=…", text: $urlText, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .padding(14)
                    .background(theme.palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))
                    .lineLimit(3)

                TextField("Playlist name (optional)", text: $playlistName)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .padding(14)
                    .background(theme.palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))
            }
            .padding(.horizontal, 24)

            Spacer()

            Button { startImport() } label: {
                Text("Import")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.palette.bg)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(
                        urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? theme.ink.opacity(0.25) : theme.ink,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 24)
            .padding(.bottom, 36)
        }
        .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Progress
    private var progressView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(theme.accent)
            VStack(spacing: 6) {
                Text(progress.phase)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.ink)
                if progress.total > 0 {
                    Text("\(progress.current) / \(progress.total)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(theme.ink3)
                }
            }
            Spacer()
        }
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

                // Save button
                Button {
                    saveToLibrary()
                    dismiss()
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
                .padding(.bottom, 40)
            }
        }
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
        phase = .running

        Task {
            do {
                let source = try PlaylistSource.detect(raw)
                switch source {
                case .youtube(let id):
                    let tracks = try await importer.importYouTube(playlistId: id) { p in
                        DispatchQueue.main.async { self.progress = p }
                    }
                    await MainActor.run {
                        self.resultTracks = tracks
                        self.missed = []
                        self.phase = .summary
                    }

                case .spotify(let id):
                    let (tracks, misses, name, cover) = try await importer.importSpotify(playlistId: id) { p in
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
                        self.phase = .summary
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

    private func saveToLibrary() {
        let name = playlistName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Imported Playlist"
            : playlistName
        let tracks = resultTracks.map { $0.asTrack() }
        let playlist = Playlist(title: name, author: "Import", tracks: tracks, coverURL: coverURL)
        player.userPlaylists.append(playlist)
    }
}
