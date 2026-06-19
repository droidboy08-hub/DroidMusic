import SwiftUI

@main
struct AryaMusixApp: App {
    @State private var theme = ThemeState()
    @State private var player = PlayerState()
    @State private var settings = SettingsState()

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
        switch settings.appTheme {
        case "Light": .light
        case "Dark": .dark
        default: nil
        }
    }

    var body: some View {
        ContentView()
            .environment(theme)
            .environment(player)
            .environment(settings)
            .preferredColorScheme(preferredColorScheme)
            .onAppear {
                theme.updateAppearance(appTheme: settings.appTheme, systemColorScheme: colorScheme)
                MusicPlayer.shared.streamingQuality = settings.streamingQuality
            }
            .onChange(of: colorScheme) { _, newValue in
                theme.updateAppearance(appTheme: settings.appTheme, systemColorScheme: newValue)
            }
            .onChange(of: settings.appTheme) { _, newValue in
                theme.updateAppearance(appTheme: newValue, systemColorScheme: colorScheme)
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
