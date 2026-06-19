import SwiftUI

// MARK: - Main app shell
// Holds the 3-tab layout with persistent mini player + tab bar.
// NowPlayingView and AccountView are presented as full-screen covers.
struct ContentView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(SettingsState.self) private var settings

    @State private var selectedTab: AuriaTab = .home
    @State private var showAddToPlaylist = false
    var body: some View {
        GeometryReader { _ in
            ZStack {
                // Tab content — all four stay alive to preserve scroll position
                HomeView()
                    .opacity(selectedTab == .home ? 1 : 0)
                    .allowsHitTesting(selectedTab == .home)

                SearchView()
                    .opacity(selectedTab == .search ? 1 : 0)
                    .allowsHitTesting(selectedTab == .search)

                ExploreView()
                    .opacity(selectedTab == .explore ? 1 : 0)
                    .allowsHitTesting(selectedTab == .explore)

                LibraryView()
                    .opacity(selectedTab == .library ? 1 : 0)
                    .allowsHitTesting(selectedTab == .library)
                // NOTE: the itag-18 video surface lives INSIDE NowPlayingView's
                // artwork frame (one AVPlayerLayer on the shared MusicPlayer.player,
                // auto-sized via layerClass). It is not mounted here — a behind-the-
                // cover layer never shows (fullScreenCover is opaque) and the manual
                // frame math was a CoreGraphics-NaN source.
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Shared bottom bar overlay
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    if theme.showMiniPlayer, let track = player.currentTrack {
                        MiniPlayerView(
                            track: track,
                            playing: player.isPlaying,
                            progress: player.progress,
                            isLoading: player.isLoading,
                            errorMessage: player.errorMessage,
                            liked: player.liked,
                            onTap: { player.showNowPlaying = true },
                            onToggle: { player.togglePlay() },
                            onLike: { player.toggleLike() },
                            onAddToPlaylist: { showAddToPlaylist = true },
                            onPrevious: {
                                guard player.canPlayPreviousTrack else { return }
                                player.playPreviousTrack()
                            },
                            onNext: {
                                guard player.canPlayNextTrack else { return }
                                player.playNextTrack()
                            }
                        )
                    }
                    TabBarView(selected: $selectedTab)
                }
            }
            .sheet(isPresented: $showAddToPlaylist) {
                if let track = player.currentTrack {
                    AddToPlaylistView(track: track)
                        .environment(theme)
                        .environment(player)
                }
            }
            // Full-screen now-playing cover
            .fullScreenCover(isPresented: Binding(get: { player.showNowPlaying }, set: { player.showNowPlaying = $0 })) {
                NowPlayingView()
                    .environment(theme)
                    .environment(player)
                    .presentationBackground(.clear) // lets app content show through on drag
            }
            // Account popup — scales from icon position using full-screen anchor
            .overlay {
                ZStack {
                    // Tap-outside-to-dismiss (only blocks touches when visible)
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { player.showAccount = false }
                        .allowsHitTesting(player.showAccount)

                    AccountView()
                        .environment(theme)
                        .environment(player)
                        .environment(settings)
                        .padding(.horizontal, 16)
                        .allowsHitTesting(player.showAccount)
                }
                // Apply scale to the full-screen ZStack so anchor maps to screen coords
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(player.showAccount ? 1 : 0.01, anchor: .accountIcon)
                .opacity(player.showAccount ? 1 : 0)
            }
            .animation(.interpolatingSpring(stiffness: 130, damping: 12), value: player.showAccount)
            .background(theme.palette.bg.ignoresSafeArea())
            .environment(\.auriaSelectTab, { tab in selectedTab = tab })
        }
    }
}

// MARK: - Anchor point for the account icon popup origin
// Icon is 32×32 at top-right: horizontal = screenWidth - 22 - 16, vertical ≈ safeTop + 24
// Expressed as a UnitPoint so scaleEffect can originate from there on any device.
extension UnitPoint {
    static let accountIcon = UnitPoint(x: 0.92, y: 0.05)
}

// MARK: - Environment key for child views to request a tab switch
private struct AuriaSelectTabKey: EnvironmentKey {
    static let defaultValue: (AuriaTab) -> Void = { _ in }
}
extension EnvironmentValues {
    var auriaSelectTab: (AuriaTab) -> Void {
        get { self[AuriaSelectTabKey.self] }
        set { self[AuriaSelectTabKey.self] = newValue }
    }
}

#Preview {
    ContentView()
        .environment(ThemeState())
        .environment(PlayerState())
        .environment(SettingsState())
}
