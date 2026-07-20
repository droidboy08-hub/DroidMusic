import SwiftUI

struct SettingsView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(SettingsState.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var showAllPalettes = false
    private let collapsedPaletteCount = 4
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    searchGroup
                    playbackGroup
                    appearanceGroup
                    themeGroup
                    aboutGroup
                    debugGroup
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView().environment(theme)
        }
        .background(theme.palette.bg.ignoresSafeArea())
    }

    // MARK: - Top bar
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Text("Settings")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(theme.ink)
                .kerning(-0.4)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Search
    private var searchGroup: some View {
        SettingsGroup(label: "Search") {
            SettingSegmentedRow(
                label: "Search source",
                value: Binding(
                    get: { settings.searchSource.rawValue },
                    set: { v in settings.searchSource = SearchSource(rawValue: v) ?? .youtubeMusic }
                ),
                options: SearchSource.allCases.map(\.rawValue)
            )
            if settings.searchSource == .dataAPI {
                let hasKey = !DemusNetwork.apiKey.isEmpty
                SettingRow(isLast: true) {
                    Image(systemName: hasKey ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(hasKey ? theme.accent : .orange)
                    Text(hasKey ? "API key detected" : "No API key — add YOUTUBE_API_KEY in Info.plist")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.ink2)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Playback
    private var playbackGroup: some View {
        SettingsGroup(label: "Playback") {
            SettingSegmentedRow(
                label: "Streaming quality",
                value: Binding(
                    get: { settings.streamingQuality.rawValue },
                    set: { settings.streamingQuality = StreamingQuality(rawValue: $0) ?? .high }
                ),
                options: StreamingQuality.allCases.map(\.rawValue)
            )
            SettingSliderRow(label: "Crossfade", value: Bindable(settings).crossfade, min: 0, max: 12, unit: "s")
            SettingToggleRow(label: "Gapless playback", sub: "Removes silence between tracks", value: Bindable(settings).gapless)
            SettingToggleRow(label: "Normalize volume", sub: "Match loudness across tracks", value: Bindable(settings).normalize)
            SettingLinkRow(icon: "slider.vertical.3", label: "Equalizer", value: "Bass Boost", isLast: true)
        }
    }

    // MARK: - Appearance
    private var appearanceGroup: some View {
        SettingsGroup(label: "Appearance") {
            SettingSegmentedRow(
                label: "Theme",
                value: Binding(
                    get: { settings.appTheme },
                    set: { newValue in
                        settings.appTheme = newValue
                        theme.applyThemePreset(newValue, systemDark: colorScheme == .dark)
                    }
                ),
                options: ["Light", "System", "Dark"],
                isLast: true
            )
        }
    }

    // MARK: - Theme (mirrors Tweaks panel)
    private var themeGroup: some View {
        SettingsGroup(label: "Theme") {
            paletteRow
            accentRow
            displayFontRow
            tabIndicatorRow
            miniPlayerRow
            newMiniPlayerRow
        }
    }

    private var paletteRow: some View {
        let count = AuriaPalette.all.count
        let visibleCount = showAllPalettes ? count : min(collapsedPaletteCount, count)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.28)) { showAllPalettes.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showAllPalettes ? "Less" : "More")
                            .font(.system(size: 12.5, weight: .medium))
                        Image(systemName: showAllPalettes ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0..<visibleCount, id: \.self) { i in
                    let pal = AuriaPalette.all[i]
                    let isActive = theme.paletteIndex == i
                    Button {
                        theme.paletteIndex = i
                    } label: {
                        VStack(spacing: 6) {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)],
                                      spacing: 0) {
                                ForEach([pal.bg, pal.bgSoft, pal.surface, pal.surfaceWarm], id: \.self) { c in
                                    Rectangle().fill(c).aspectRatio(1, contentMode: .fit)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isActive ? theme.accent : .clear, lineWidth: 2))

                            Text(AuriaPalette.names[i])
                                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive ? theme.ink : theme.ink3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.lineSoft).frame(height: 1).padding(.leading, 14)
        }
        .onAppear { if theme.paletteIndex >= collapsedPaletteCount { showAllPalettes = true } }
    }

    private var accentRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("Accent")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(theme.accentNames[theme.accentIndex])
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3)
            }
            HStack(spacing: 10) {
                ForEach(theme.accentColors.indices, id: \.self) { i in
                    let isActive = theme.accentIndex == i
                    Button {
                        theme.accentIndex = i
                    } label: {
                        Circle()
                            .fill(theme.accentColors[i])
                            .frame(width: 36, height: 36)
                            .overlay {
                                if isActive {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay(Circle().strokeBorder(
                                isActive ? theme.ink : Color.black.opacity(0.10),
                                lineWidth: isActive ? 2 : 1
                            ).padding(isActive ? -2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.lineSoft).frame(height: 1).padding(.leading, 14)
        }
    }

    private var displayFontRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display font")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ForEach(theme.displayFontNames.indices, id: \.self) { i in
                let isActive = theme.displayFontIndex == i
                Button {
                    theme.displayFontIndex = i
                } label: {
                    HStack {
                        Text(theme.displayFontNames[i])
                            .font(.system(size: 20, weight: .regular, design: .serif))
                            .foregroundStyle(theme.ink)
                            .kerning(-0.3)
                        Spacer()
                        if isActive {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.lineSoft).frame(height: 1).padding(.leading, 14)
        }
    }

    private var tabIndicatorRow: some View {
        SettingSegmentedRow(
            label: "Tab indicator",
            value: Binding(
                get: { theme.tabStyle.rawValue },
                set: { v in theme.tabStyle = TabIndicatorStyle(rawValue: v) ?? .topTick }
            ),
            options: TabIndicatorStyle.allCases.map(\.rawValue)
        )
    }

    private var miniPlayerRow: some View {
        SettingToggleRow(
            label: "Show mini player",
            sub: "When music is playing",
            value: Binding(get: { theme.showMiniPlayer }, set: { theme.showMiniPlayer = $0 })
        )
    }

    private var newMiniPlayerRow: some View {
        SettingToggleRow(
            label: "New mini player",
            sub: "Redesigned pill with swipe-to-change",
            value: Bindable(settings).newMiniPlayer,
            isLast: true
        )
    }

    // MARK: - About
    private var aboutGroup: some View {
        SettingsGroup(label: "About") {
            SettingLinkRow(icon: "puzzlepiece", label: "Integrations")
            SettingLinkRow(icon: "person", label: "Privacy & data")
            SettingRow(isLast: true) {
                Text("Version")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink2)
                Spacer()
                Text("ARYAMUSIX 1.0.0")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    // MARK: - Debug
    private var debugGroup: some View {
        SettingsGroup(label: "Support & Debug") {
            VStack(spacing: 0) {
                Toggle(isOn: Bindable(player).debugMode) {
                    HStack(spacing: 12) {
                        Image(systemName: "eye")
                            .font(.system(size: 18))
                            .foregroundStyle(theme.ink)
                        Text("Show Background Player")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.ink)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                
                Divider().padding(.leading, 44)

                Button { showDiagnostics = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 18))
                            .foregroundStyle(theme.ink)
                        Text("PoToken Diagnostics")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 44)

                Button {
                    player.resetPlayer()
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.red)
                        Text("Reset Playback Engine")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
