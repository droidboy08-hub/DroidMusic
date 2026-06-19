import SwiftUI

struct PlaylistDetailView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                
                if playlist.tracks.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { idx, track in
                            songRow(track: track, isLast: idx == playlist.tracks.count - 1)
                                .onTapGesture {
                                    player.play(track: track, queue: playlist.tracks)
                                }
                        }
                    }
                    .padding(.horizontal, 22)
                }
                
                Color.clear.frame(height: 120)
            }
        }
        .background(theme.palette.bg)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.ink)
                        .padding(8)
                        .background(theme.palette.surfaceWarm, in: Circle())
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 20) {
            ThumbnailView(url: playlist.coverURL ?? playlist.tracks.first?.thumbnailURL, seed: playlist.tracks.first?.seed ?? 0, cornerRadius: 16)
                .frame(width: 200, height: 200)
                .shadow(color: theme.ink.opacity(0.15), radius: 20, y: 10)
            
            VStack(spacing: 4) {
                Text(playlist.title)
                    .font(theme.editorialFont(size: 28, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text(playlist.author)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink3)
            }
            
            HStack(spacing: 12) {
                Button {
                    if let first = playlist.tracks.first {
                        player.play(track: first, queue: playlist.tracks)
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(theme.ink, in: Capsule())
                        .foregroundStyle(theme.palette.bg)
                }
                .disabled(playlist.tracks.isEmpty)
                
                Button {
                    if !playlist.tracks.isEmpty {
                        let shuffled = playlist.tracks.shuffled()
                        player.play(track: shuffled.first!, queue: shuffled)
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .bold))
                        .padding(12)
                        .background(theme.palette.surfaceWarm, in: Circle())
                        .foregroundStyle(theme.ink)
                }
                .disabled(playlist.tracks.isEmpty)
            }
        }
        .padding(.top, 40)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(theme.ink3)
            Text("No songs in this playlist")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.ink3)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    private func songRow(track: Track, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(url: track.thumbnailURL, seed: track.seed, cornerRadius: 6)
                .frame(width: 44, height: 44)
            
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
            
            SongMenuButton(track: track, iconSize: 14)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(theme.lineSoft).frame(height: 1) }
        }
    }
}
