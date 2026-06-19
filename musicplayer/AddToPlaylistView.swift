import SwiftUI

struct AddToPlaylistView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(\.dismiss) private var dismiss

    let track: Track
    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                trackPreview

                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Add to")

                    if player.userPlaylists.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(player.userPlaylists.enumerated()), id: \.element.id) { index, playlist in
                                    playlistRow(
                                        playlist,
                                        isLast: index == player.userPlaylists.count - 1
                                    )
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .background(theme.palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(theme.ink)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var trackPreview: some View {
        HStack(spacing: 14) {
            ThumbnailView(url: track.thumbnailURL, seed: track.seed, cornerRadius: 12)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(14)
        .background(theme.palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if isCreatingPlaylist {
                createPlaylistForm
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.palette.surfaceWarm)
                    .frame(width: 86, height: 86)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(theme.ink2)
                    }

                Text("No playlists yet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text("Create a playlist and add this song to it.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)

                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        isCreatingPlaylist = true
                    }
                    isNameFieldFocused = true
                } label: {
                    Label("Create Playlist", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.palette.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(theme.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(theme.palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var createPlaylistForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Playlist")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)

            TextField("Playlist name", text: $newPlaylistName)
                .font(.system(size: 16))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .focused($isNameFieldFocused)
                .submitLabel(.done)
                .onSubmit(createPlaylist)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(theme.palette.bg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1)
                }

            HStack(spacing: 10) {
                Button("Back") {
                    isNameFieldFocused = false
                    withAnimation(.spring(duration: 0.25)) {
                        isCreatingPlaylist = false
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(theme.palette.bg, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
                .buttonStyle(.plain)

                Button("Create & Add") {
                    createPlaylist()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(canCreatePlaylist ? theme.ink : theme.ink.opacity(0.25), in: Capsule())
                .buttonStyle(.plain)
                .disabled(!canCreatePlaylist)
            }
        }
        .padding(.horizontal, 18)
    }

    private var canCreatePlaylist: Bool {
        !newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createPlaylist() {
        guard canCreatePlaylist else { return }
        player.createPlaylist(name: newPlaylistName, adding: track)
        dismiss()
    }

    private func playlistRow(_ playlist: Playlist, isLast: Bool) -> some View {
        Button {
            player.addToPlaylist(track: track, playlistId: playlist.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ThumbnailView(url: playlist.tracks.first?.thumbnailURL, seed: playlist.tracks.first?.seed ?? 0, cornerRadius: 8)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if playlist.tracks.isEmpty {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 16, weight: .light))
                                .foregroundStyle(theme.ink2)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text("\(playlist.tracks.count) songs")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink3)
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(theme.lineSoft).frame(height: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.ink3)
            .kerning(1.2)
            .textCase(.uppercase)
            .padding(.horizontal, 2)
    }
}
