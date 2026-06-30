import SwiftUI

@main
struct AryaMusixApp: App {
    @State private var theme = ThemeState()
    @State private var player = PlayerState()
    @State private var settings = SettingsState()

    init() {
        // Headless scraper check: launch with `SCRAPER_TEST` to print results.
        // e.g. xcrun simctl launch --console-pty <udid> DroidMusxc.musicplayer SCRAPER_TEST
        if CommandLine.arguments.contains("SCRAPER_TEST") {
            Task { await Self.runScraperTest() }
        }
    }

    @MainActor
    private static func runScraperTest() async {
        let id = "49wVHQCgjPpN3qzPylIUND"   // 340-track public test playlist
        print("SCRAPER_TEST ▶︎ scraping \(id)")
        do {
            let scraper = SpotifyWebScraper()
            scraper.debug = true
            let r = try await scraper.scrape(playlistId: id)
            print("SCRAPER_TEST ✓ name=\(r.name ?? "nil") cover=\(r.coverURL ?? "nil")")
            print("SCRAPER_TEST ✓ got \(r.tracks.count) tracks")
            for t in r.tracks.prefix(10) {
                print("  • \(t.title) — \(t.artist) (\(Int(t.durationSec))s)")
            }
        } catch {
            print("SCRAPER_TEST ✗ \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(theme: theme, player: player, settings: settings)
        }
    }
}

private struct AppRootView: View {
    @Environment(\.colorScheme) private var colorScheme

    let theme: ThemeState
    let player: PlayerState
    let settings: SettingsState

    private var preferredColorScheme: ColorScheme? {
        // System chrome matches the selected Background palette.
        theme.palette.isDark ? .dark : .light
    }

    var body: some View {
        ContentView()
            .environment(theme)
            .environment(player)
            .environment(settings)
            .preferredColorScheme(preferredColorScheme)
            .onAppear {
                MusicPlayer.shared.streamingQuality = settings.streamingQuality
                player.miniPlayerEnabled = theme.showMiniPlayer
                if settings.appTheme == "System" {
                    theme.applyThemePreset("System", systemDark: colorScheme == .dark)
                }
            }
            .onChange(of: theme.showMiniPlayer) { _, shown in
                player.miniPlayerEnabled = shown
            }
            .onChange(of: colorScheme) { _, newValue in
                if settings.appTheme == "System" {
                    theme.applyThemePreset("System", systemDark: newValue == .dark)
                }
            }
            .onChange(of: settings.streamingQuality) { _, newValue in
                MusicPlayer.shared.streamingQuality = newValue
            }
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                SessionBootstrap.shared.start()
            }
    }
}
