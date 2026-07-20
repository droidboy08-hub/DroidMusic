import SwiftUI

// MARK: - Main app shell
// Holds the 3-tab layout with persistent mini player + tab bar.
// NowPlayingView and AccountView are presented as full-screen covers.
struct ContentView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(SettingsState.self) private var settings

    @State private var selectedTab: AuriaTab = .home
    @State private var mountedTabs: Set<AuriaTab> = [.home]

    // Navigation paths for tabs that support deep navigation (e.g. playlists).
    // Resetting a path on tab selection ensures clicking a nav tab always lands on the tab root.
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()

    // Create playlist sheet state (lifted so the FAB can live above the mini player)
    @State private var showCreatePlaylist = false
    @State private var createPlaylistName = ""
    @State private var showSpotifyImport = false

    var body: some View {
        ZStack {
            tabLayer(.home)      { NavigationStack(path: $homePath) { HomeView() } }
            tabLayer(.search)    { SearchView() }
            tabLayer(.explore)   { ExploreView() }
            tabLayer(.library)   { NavigationStack(path: $libraryPath) { LibraryView() } }

            // Hidden WebView that keeps the YouTube session (visitorData + cookies + poToken) warm.
            // Must stay in the view tree for reliable navigation / JS execution.
            SessionWebViewHost()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if theme.showMiniPlayer, let track = player.currentTrack {
                    if settings.newMiniPlayer {
                        NewMiniPlayerView(
                            track: track,
                            onTap: { player.showNowPlaying = true }
                        )
                    } else {
                        MiniPlayerView(
                            track: track,
                            onTap: { player.showNowPlaying = true },
                            onNext: {
                                guard player.canPlayNextTrack else { return }
                                player.playNextTrack()
                            },
                            onPrevious: {
                                guard player.canPlayPreviousTrack else { return }
                                player.playPreviousTrack()
                            }
                        )
                    }
                }
                TabBarView(selected: $selectedTab)
            }
        }
        // FAB for Library tab — placed in a later overlay so it floats *above* the mini player
        .overlay(alignment: .bottomTrailing) {
            if selectedTab == .library {
                Button {
                    createPlaylistName = ""
                    showCreatePlaylist = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.palette.bg)
                        .frame(width: 56, height: 56)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: theme.accent.opacity(0.35), radius: 12, y: 5)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 18)
                .padding(.bottom, fabBottomPadding)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            mountedTabs.insert(tab)
            // Clicking any main navigation tab always takes the user to that tab's root.
            // This pops playlist details (and any other pushed views) so "just go to it".
            switch tab {
            case .home:    homePath = NavigationPath()
            case .library: libraryPath = NavigationPath()
            default: break
            }
        }
        .sheet(isPresented: $showCreatePlaylist) {
            NewPlaylistSheet(
                isPresented: $showCreatePlaylist,
                name: $createPlaylistName,
                onCreate: {
                    if player.createPlaylist(name: createPlaylistName) != nil {
                        Haptics.playlistCreated()
                        if selectedTab != .library { selectedTab = .library }
                    }
                },
                onSpotify: { showSpotifyImport = true }
            )
            .environment(theme)
            .environment(player)
        }
        .sheet(isPresented: $showSpotifyImport) {
            ImportPlaylistView()
                .environment(theme)
                .environment(player)
        }
        .sheet(isPresented: Binding(get: { player.showAddToPlaylist }, set: { player.showAddToPlaylist = $0 })) {
            if let track = player.addToPlaylistTrack {
                AddToPlaylistView(track: track)
                    .environment(theme)
                    .environment(player)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { player.showNowPlaying }, set: { player.showNowPlaying = $0 })) {
            NowPlayingView()
                .environment(theme)
                .environment(player)
                .presentationBackground(.clear)
        }
        .overlay {
            ZStack {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Springy grow-from-the-icon. The box scales empty; AccountView fades
            // its content in near the end so the scale stays smooth.
            .scaleEffect(player.showAccount ? 1 : 0.01, anchor: .accountIcon)
            .opacity(player.showAccount ? 1 : 0)
        }
        .animation(.interpolatingSpring(stiffness: 130, damping: 12), value: player.showAccount)
        .background(theme.palette.bg.ignoresSafeArea())
        .environment(\.auriaSelectTab, { tab in selectedTab = tab })
    }

    /// Mount tabs on first visit.
    /// NOTE: We deliberately skip drawingGroup on .home and .library because they
    /// contain NavigationStack. Applying drawingGroup to a NavigationStack causes
    /// "Unable to render flattened version of PlatformViewControllerRepresentableAdaptor<NavigationStackRepresentable>"
    /// and related SwiftUI faults.
    @ViewBuilder
    private func tabLayer<Tab: View>(_ tab: AuriaTab, @ViewBuilder content: () -> Tab) -> some View {
        if mountedTabs.contains(tab) {
            let isActive = selectedTab == tab
            let shouldRasterize = !isActive && (tab == .search || tab == .explore)

            content()
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .zIndex(isActive ? 1 : 0)
                .modifier(InactiveTabRasterizer(isInactive: shouldRasterize))
        }
    }

    private var fabBottomPadding: CGFloat {
        // Position the FAB above the mini player + tab bar with a visible gap.
        // Mini player pill + its padding ≈ 66pt, tab bar ≈ 68pt.
        let hasMiniPlayer = theme.showMiniPlayer && player.currentTrack != nil
        let tabBarHeight: CGFloat = 68
        let miniPlayerHeight: CGFloat = 66
        let gap: CGFloat = hasMiniPlayer ? 24 : 14   // extra distance above the mini player
        return (hasMiniPlayer ? miniPlayerHeight : 0) + tabBarHeight + gap
    }
}

// MARK: - Rasterize simple tabs only (search/explore) for GPU savings.
// We never apply drawingGroup to tabs containing NavigationStack (.home / .library)
// because it triggers SwiftUI faults like "Unable to render flattened version of ...NavigationStackRepresentable".
private struct InactiveTabRasterizer: ViewModifier {
    let isInactive: Bool
    func body(content: Content) -> some View {
        if isInactive {
            content.drawingGroup(opaque: false)
        } else {
            content
        }
    }
}

// MARK: - Anchor point for the account icon popup origin
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