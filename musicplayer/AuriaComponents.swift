import SwiftUI

// MARK: - Animated EQ bars (now-playing indicator)
struct EQBarsView: View {
    let playing: Bool
    var color: Color = Color(hex: "#C8501B")
    var size: CGFloat = 14

    @State private var h0: CGFloat = 0.30
    @State private var h1: CGFloat = 0.90
    @State private var h2: CGFloat = 0.50

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            eqBar(height: h0)
            eqBar(height: h1)
            eqBar(height: h2)
        }
        .frame(width: size, height: size)
        .onAppear { kick() }
        .onChange(of: playing) { _, _ in kick() }
    }

    private func eqBar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2.5, height: size * height)
    }

    private func kick() {
        if playing {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { h0 = 1.0 }
            withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true).delay(0.12)) { h1 = 0.40 }
            withAnimation(.easeInOut(duration: 0.50).repeatForever(autoreverses: true).delay(0.22)) { h2 = 0.95 }
        } else {
            withAnimation(.spring(duration: 0.25)) { h0 = 0.4; h1 = 0.4; h2 = 0.4 }
        }
    }
}

// MARK: - Custom toggle  (matches design: accent when on, surfaceWarm when off)
struct AuriaToggle: View {
    @Binding var isOn: Bool
    @Environment(ThemeState.self) private var theme

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { isOn.toggle() }
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? theme.accent : theme.palette.surfaceWarm)
                    .frame(width: 46, height: 28)
                HStack {
                    if isOn { Spacer() }
                    Circle()
                        .fill(theme.palette.bg)
                        .shadow(color: .black.opacity(0.20), radius: 1.5, y: 1)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if isOn {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    if !isOn { Spacer() }
                }
                .padding(3)
                .frame(width: 46)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Spinning sync ring (arc that orbits an icon while loading)
private struct SyncRingView: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 28, height: 28)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Top app bar
struct AppBarView: View {
    let title: String
    var onProfile: (() -> Void)? = nil
    var onSync: (() -> Void)? = nil
    var isSyncing: Bool = false

    @Environment(ThemeState.self)  private var theme
    @Environment(PlayerState.self) private var player

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.ink)
                .kerning(-0.6)

            Spacer()

            iconButton(systemName: "clock.arrow.circlepath")

            // YouTube library sync / download button
            Button { onSync?() } label: {
                ZStack {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(theme.ink)

                    if isSyncing {
                        SyncRingView(color: theme.ink)
                    }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)

            Button {
                onProfile?()
            } label: {
                Circle()
                    .fill(theme.ink)
                    .frame(width: 32, height: 32)
                    .overlay {
                        if let imgURL = player.ytProfileImageURL, let url = URL(string: imgURL) {
                            AsyncImage(url: url) { phase in
                                if let img = phase.image {
                                    img.resizable().scaledToFill()
                                } else {
                                    Image(systemName: "person")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(theme.palette.bg)
                                }
                            }
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.palette.bg)
                        }
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func iconButton(systemName: String) -> some View {
        Button {} label: {
            Image(systemName: systemName)
                .font(.system(size: 18))
                .foregroundStyle(theme.ink)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mini player progress ring (isolated leaf)
// Reads player.playback.progress from the environment here only — ContentView
// and MiniPlayerView never touch playback, so progress ticks don't re-render tabs.
private struct MiniProgressRing: View {
    @Environment(PlayerState.self) private var player
    @Environment(ThemeState.self) private var theme

    var body: some View {
        let p = player.playback.progress.isFinite
            ? CGFloat(min(max(player.playback.progress, 0), 1)) : 0
        let hasError = player.errorMessage != nil
        ZStack {
            Circle()
                .stroke(theme.line, lineWidth: 2.5)
                .frame(width: 42, height: 42)
            Circle()
                .trim(from: 0, to: p)
                .stroke(hasError ? Color.red : theme.accent,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 42, height: 42)
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Mini player (pill above tab bar)
struct MiniPlayerView: View {
    let track: Track
    var playing: Bool
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var liked: Bool = false
    var onTap: () -> Void
    var onToggle: () -> Void
    var onLike: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    @Environment(ThemeState.self) private var theme
    @State private var swipeHapticTrigger = 0
    @State private var dragOffset: CGFloat = 0
    @State private var thresholdCrossed = false

    private let swipeThreshold: CGFloat = 55

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Circular album art with progress arc + play/pause overlay
                ZStack {
                    ThumbnailView(url: track.thumbnailURL, seed: track.seed, cornerRadius: 999)
                        .frame(width: 36, height: 36)

                    // Progress arc ring — isolated leaf so the per-tick progress
                    // read doesn't re-render this whole pill.
                    MiniProgressRing()

                    if errorMessage != nil {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.red)
                            .frame(width: 22, height: 22)
                            .background(theme.palette.bg.opacity(0.95), in: Circle())
                    } else {
                        Button(action: { onToggle() }) {
                            Group {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(theme.ink)
                                } else {
                                    Image(systemName: playing ? "pause.fill" : "play.fill")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(theme.ink)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                            }
                            .frame(width: 22, height: 22)
                            .background(theme.palette.bg.opacity(0.95), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                    }
                }
                .frame(width: 42, height: 42)

                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else {
                        HStack(spacing: 4) {
                            if track.explicit {
                                Image(systemName: "e.square.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(theme.ink3)
                            }
                            Text(track.artist)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.ink3)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 6) {
                    miniActionBtn(icon: "text.badge.plus", action: onAddToPlaylist)
                    Button {
                        Haptics.likeToggled()
                        onLike?()
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 14))
                            .foregroundStyle(liked ? theme.accent : theme.ink2)
                            .frame(width: 34, height: 34)
                            .background(theme.palette.bg, in: Circle())
                            .overlay(Circle().strokeBorder(theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(duration: 0.2), value: liked)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(theme.palette.surface)
                    .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
                    .shadow(color: theme.ink.opacity(0.06), radius: 10, y: 4)
            }
            // Flatten the pill's geometry so the album art, play/pause button and
            // action buttons all move as ONE rigid unit when the drag offset (or
            // its snap-back spring) is applied. Without this, each child resolves
            // its position independently and they desync.
            .geometryGroup()
        }
        .buttonStyle(.plain)
        .offset(x: dragOffset)
        .highPriorityGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard !isLoading,
                          abs(value.translation.width) > abs(value.translation.height) else { return }

                    dragOffset = value.translation.width

                    // Fire haptic once when threshold is first crossed
                    if !thresholdCrossed && abs(value.translation.width) > swipeThreshold {
                        thresholdCrossed = true
                        swipeHapticTrigger += 1
                    }
                }
                .onEnded { value in
                    guard !isLoading,
                          abs(value.translation.width) > abs(value.translation.height) else {
                        withAnimation(.interpolatingSpring(stiffness: 130, damping: 10)) { dragOffset = 0 }
                        thresholdCrossed = false
                        return
                    }

                    let goingNext = value.translation.width < 0

                    if abs(value.translation.width) > swipeThreshold {
                        if goingNext { onNext?() } else { onPrevious?() }
                    }
                    // Always snap back with rubber bounce
                    withAnimation(.interpolatingSpring(stiffness: 130, damping: 10)) {
                        dragOffset = 0
                    }
                    thresholdCrossed = false
                }
        )
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: swipeHapticTrigger)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func miniActionBtn(icon: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(theme.ink2)
                .frame(width: 34, height: 34)
                .background(theme.palette.bg, in: Circle())
                .overlay(Circle().strokeBorder(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// Reusable three-dot menu for any track (native Menu popover)
struct TrackMenu: View {
    let track: Track
    var playlist: Playlist? = nil
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player

    var body: some View {
        Menu {
            menuButton("Play Next", "text.line.first.and.arrowtriangle.forward") {
                player.playNext(track: track)
            }
            menuButton("Add to Queue", "text.append") {
                player.addToQueue(track: track)
            }
            menuButton("Add to Playlist", "text.badge.plus") {
                player.presentAddToPlaylist(for: track)
            }

            if player.isLiked(track: track) {
                menuButton("Unlike", "heart.slash") { player.toggleLike(track: track) }
            } else {
                menuButton("Like", "heart") { player.toggleLike(track: track) }
            }

            if let pl = playlist, player.userPlaylists.contains(where: { $0.id == pl.id }) {
                menuButton("Remove from this Playlist", "trash", role: .destructive) {
                    player.removeFromPlaylist(track: track, playlistId: pl.id)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .foregroundStyle(theme.ink3)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }

    /// One kebab item — plays a light tap, then runs its action. Routing every
    /// item through here means anything picked from the menu buzzes.
    private func menuButton(_ title: String, _ systemImage: String,
                            role: ButtonRole? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(role: role) {
            Haptics.menuSelection()
            action()
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

// MARK: - Custom tab bar (4 tabs)
enum AuriaTab { case home, search, explore, library }

struct AuriaTabItem {
    let id: AuriaTab
    let label: String
    let icon: String
}

struct TabBarView: View {
    @Binding var selected: AuriaTab
    @Environment(ThemeState.self) private var theme

    private let tabs: [AuriaTabItem] = [
        AuriaTabItem(id: .home,    label: "Home",    icon: "house"),
        AuriaTabItem(id: .search,  label: "Search",  icon: "magnifyingglass"),
        AuriaTabItem(id: .explore, label: "Explore", icon: "safari"),
        AuriaTabItem(id: .library, label: "Library", icon: "books.vertical"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.id.hashValue) { tab in
                tabItem(tab)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(theme.palette.bg)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.line)
                        .frame(height: 1)
                }
        }
    }

    @ViewBuilder
    private func tabItem(_ tab: AuriaTabItem) -> some View {
        let isActive = selected == tab.id
        Button {
            selected = tab.id
        } label: {
            VStack(spacing: 4) {
                // Top tick indicator (2 px, small gap below)
                if theme.tabStyle == .topTick {
                    Capsule()
                        .fill(isActive ? theme.accent : .clear)
                        .frame(width: 20, height: 2)
                }

                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? theme.ink : theme.ink3)

                // Bottom underline indicator
                if theme.tabStyle == .underline {
                    Capsule()
                        .fill(isActive ? theme.accent : .clear)
                        .frame(width: 20, height: 2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Scrubber (Apple Music-style thick bar, no thumb circle)
struct ScrubberView: View {
    @Binding var progress: Double
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onSeek: ((Double) -> Void)? = nil
    @Environment(ThemeState.self) private var theme
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = progress.isFinite ? min(max(progress, 0), 1) : 0
            let fillW = max(0, w * p)
            let barH: CGFloat = isDragging ? 10.5 : 8.5

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(theme.palette.surfaceWarm)
                    .frame(height: barH)
                // Fill
                Capsule()
                    .fill(theme.ink)
                    .frame(width: max(fillW, barH), height: barH)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        progress = w > 0 ? max(0, min(1, val.location.x / w)) : 0
                    }
                    .onEnded { val in
                        let seekProgress = w > 0 ? max(0, min(1, val.location.x / w)) : 0
                        progress = seekProgress
                        onSeek?(seekProgress)       // fire seek while isSeeking is still true
                        isDragging = false
                        onEditingChanged?(false)    // clear isSeeking last
                    }
            )
            .animation(.easeInOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 20)
    }
}

// MARK: - Settings row primitives
struct SettingsGroup<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    @Environment(ThemeState.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .kerning(1.4)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content
            }
            .background(theme.palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.bottom, 22)
    }
}

struct SettingRow<Content: View>: View {
    var isLast: Bool = false
    @ViewBuilder var content: Content
    @Environment(ThemeState.self) private var theme

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(theme.lineSoft).frame(height: 1).padding(.leading, 14)
                }
            }
    }
}

struct SettingToggleRow: View {
    let label: String
    var sub: String? = nil
    @Binding var value: Bool
    var isLast: Bool = false
    @Environment(ThemeState.self) private var theme

    var body: some View {
        SettingRow(isLast: isLast) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                if let sub {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.ink3)
                }
            }
            Spacer()
            AuriaToggle(isOn: $value)
        }
    }
}

struct SettingLinkRow: View {
    let icon: String?
    let label: String
    var value: String? = nil
    var isLast: Bool = false
    @Environment(ThemeState.self) private var theme

    var body: some View {
        SettingRow(isLast: isLast) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 22)
            }
            Text(label)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(theme.ink)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.ink3)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.ink3)
        }
    }
}

struct SettingSegmentedRow: View {
    let label: String
    @Binding var value: String
    let options: [String]
    var isLast: Bool = false
    @Environment(ThemeState.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(theme.ink)

            HStack(spacing: 2) {
                ForEach(options, id: \.self) { opt in
                    Button {
                        value = opt
                    } label: {
                        Text(opt)
                            .font(.system(size: 12.5, weight: value == opt ? .semibold : .medium))
                            .foregroundStyle(value == opt ? theme.ink : theme.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background {
                                if value == opt {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(theme.palette.bg)
                                        .shadow(color: theme.ink.opacity(0.10), radius: 2, y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(theme.palette.bgSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(theme.lineSoft).frame(height: 1).padding(.leading, 14)
            }
        }
    }
}

struct SettingSliderRow: View {
    let label: String
    @Binding var value: Double
    let min: Double
    let max: Double
    let unit: String
    @Environment(ThemeState.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                Text(label)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                Text("\(Int(value))\(unit)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.accent)
            }
            Slider(value: $value, in: min...max, step: 1)
                .tint(theme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.lineSoft).frame(height: 1).padding(.leading, 14)
        }
    }
}
