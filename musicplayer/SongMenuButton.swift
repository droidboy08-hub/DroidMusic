import SwiftUI

/// The three-dots overflow menu for a song row.
///
/// Uses a native SwiftUI `Menu` (system popup) rather than a hand-rolled
/// overlay — positioning, dismissal, haptics, Dynamic Type and accessibility
/// all come for free. Drop it in wherever a song row needs a "more" button.
struct SongMenuButton: View {
    let track: Track
    var iconSize: CGFloat = 16
    var hitSize: CGFloat = 32

    @Environment(PlayerState.self) private var player
    @Environment(ThemeState.self) private var theme
    @State private var showAddToPlaylist = false

    var body: some View {
        Menu {
            Button {
                player.playNext(track: track)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                player.addToQueue(track: track)
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }

            Button {
                showAddToPlaylist = true
            } label: {
                Label("Add to Playlist…", systemImage: "plus.rectangle.on.rectangle")
            }

            let liked = player.isLiked(track: track)
            Button {
                player.toggleLike(track: track)
            } label: {
                Label(liked ? "Remove from Library" : "Add to Library",
                      systemImage: liked ? "heart.slash" : "heart")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: iconSize))
                .foregroundStyle(theme.ink3)
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistView(track: track)
                .environment(theme)
                .environment(player)
        }
    }
}
