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
            VStack(spacing: 8) {
                trackPreview

                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(player.userPlaylists.isEmpty ? "Create one" : "Add to")

                    // One unified card: "New Playlist" is always the first row,
                    // existing playlists scroll below it. Increased size to show more playlists.
                    VStack(spacing: 0) {
                        createRow

                        if !player.userPlaylists.isEmpty {
                            Rectangle().fill(theme.lineSoft).frame(height: 1)
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(player.userPlaylists.enumerated()), id: \.element.id) { index, playlist in
                                        playlistRow(playlist, isLast: index == player.userPlaylists.count - 1)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            .frame(minHeight: 180)  // give more room to the playlist list
                        }
                    }
                    .background(theme.palette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(minHeight: 220)  // increase overall container size for playlists
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
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
        HStack(spacing: 12) {
            ThumbnailView(url: track.thumbnailURL, seed: track.seed, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var createRow: some View {
        if isCreatingPlaylist {
            HStack(spacing: 12) {
                Button {
                    newPlaylistName = ""
                    isNameFieldFocused = false
                    withAnimation(.easeInOut(duration: 0.2)) { isCreatingPlaylist = false }
                } label: {
                    createTile(systemName: "xmark")
                }
                .buttonStyle(.plain)

                TextField("Playlist name", text: $newPlaylistName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .focused($isNameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(createPlaylist)
                    .textInputAutocapitalization(.words)
                    .onAppear { isNameFieldFocused = true }

                Button("Create") { createPlaylist() }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(canCreatePlaylist ? theme.accent : theme.ink3)
                    .buttonStyle(.plain)
                    .disabled(!canCreatePlaylist)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            Button {
                newPlaylistName = ""
                withAnimation(.easeInOut(duration: 0.2)) { isCreatingPlaylist = true }
            } label: {
                HStack(spacing: 12) {
                    createTile(systemName: "plus")
                    Text("New Playlist")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func createTile(systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.accent.opacity(0.12))
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
    }

    private func playlistRow(_ playlist: Playlist, isLast: Bool) -> some View {
        let isSelected = playlist.tracks.contains { $0.id == track.id }
        return Button {
            if !isSelected {
                player.addToPlaylist(track: track, playlistId: playlist.id)
                Haptics.addedToPlaylist()
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                ThumbnailView(url: playlist.coverURL ?? playlist.tracks.first?.thumbnailURL, seed: playlist.tracks.first?.seed ?? 0, cornerRadius: 8)
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

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.accent)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
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
        .disabled(isSelected)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.ink3)
            .kerning(1.2)
            .textCase(.uppercase)
            .padding(.horizontal, 2)
    }

    private var canCreatePlaylist: Bool {
        !newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createPlaylist() {
        guard canCreatePlaylist else { return }
        if player.createPlaylist(name: newPlaylistName, adding: track) != nil {
            Haptics.playlistCreated()
        }
        dismiss()
    }

}
