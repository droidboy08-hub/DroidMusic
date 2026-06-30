import SwiftUI
import AVKit

private enum NowPlayingPanel: CaseIterable {
    case artwork, lyrics, queue
    var label: String {
        switch self { case .artwork: "Now Playing"; case .lyrics: "Lyrics"; case .queue: "Queue" }
    }
    var icon: String {
        switch self { case .artwork: "music.note"; case .lyrics: "text.alignleft"; case .queue: "list.bullet" }
    }
}

// MARK: - AirPlay picker (wraps AVRoutePickerView)
private struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .label
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = tintColor
        v.activeTintColor = tintColor
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
    }
}

struct NowPlayingView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var activePanel: NowPlayingPanel = .artwork
    @State private var showSleepSheet = false
    @State private var showAddToPlaylist = false

    // Elastic button-weight animation state
    @State private var isPressingPlay = false
    @State private var isPressingPrev = false
    @State private var isPressingNext = false

    // Drag-to-dismiss state
    @State private var dragOffset: CGFloat = 0
    @State private var screenWidth: CGFloat = 393
    // Dismiss threshold = half the album art height = (screenWidth - 56pt padding) / 2
    private var dismissThreshold: CGFloat { (screenWidth - 56) / 4 }
    private var dragProgress: CGFloat { min(1, max(0, dragOffset / 450)) }
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                if v.translation.height > 0 { dragOffset = v.translation.height }
            }
            .onEnded { v in
                let velocity = v.velocity.height
                if velocity > 600 || dragOffset > dismissThreshold {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        dragOffset = 0
                    }
                }
            }
    }

    var body: some View {
        ZStack {
            theme.palette.bg
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header.simultaneousGesture(dragGesture)
                videoImageToggle
                    .padding(.bottom, 4)

                switch activePanel {
                case .artwork: artworkPanel
                case .lyrics:  lyricsPanel
                case .queue:   queuePanel
                }

                Spacer(minLength: 0)
            }
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .background(GeometryReader { geo in
            Color.clear.onAppear { screenWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in screenWidth = w }
        })
        .offset(y: dragOffset)
        .scaleEffect(1 - dragProgress * 0.05, anchor: .bottom)
        .opacity(1 - dragProgress * 0.35)
        .animation(.interactiveSpring(), value: dragOffset)
        .onAppear { player.setNowPlayingVisible(true) }
        .onDisappear { player.setNowPlayingVisible(false) }
        .sheet(isPresented: $showSleepSheet) { sleepSheet }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistView(track: track)
                    .environment(theme)
                    .environment(player)
            }
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -8))

            Spacer()

            Text("Now playing")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .kerning(1.4)
                .textCase(.uppercase)

            Spacer()

            // AirPlay
            AirPlayButton(tintColor: UIColor(theme.ink))
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Video / Image capsule toggle
    //
    // Centered pill with two segments. The active segment has a filled inner
    // capsule; the inactive one is transparent. Video is disabled (and the
    // selection pinned to Image) when the resolved stream has no video track.
    private var videoImageToggle: some View {
        let videoActive = player.showVideo && player.hasVideo

        return HStack(spacing: 6) {
            capsuleSegment(icon: "video.fill", label: "Video",
                           isActive: videoActive,
                           isEnabled: player.hasVideo) {
                guard player.hasVideo else { return }
                withAnimation(.spring(duration: 0.25)) {
                    player.showVideo = true
                    activePanel = .artwork
                }
            }
            capsuleSegment(icon: "photo", label: "Image",
                           isActive: !videoActive,
                           isEnabled: true) {
                withAnimation(.spring(duration: 0.25)) {
                    player.showVideo = false
                    activePanel = .artwork
                }
            }
        }
        .frame(maxWidth: .infinity)   // center the pair
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    // Both segments share identical padding + Capsule frame so their hit
    // areas / outlines are the same size; only the fill swaps for active.
    private func capsuleSegment(icon: String, label: String,
                                isActive: Bool, isEnabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isActive ? theme.palette.bg : theme.ink2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(isActive ? theme.ink : Color.clear))
            .overlay(Capsule().strokeBorder(isActive ? Color.clear : theme.line, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Artwork panel
    private var artworkPanel: some View {
        VStack(spacing: 0) {
            artwork
            titleRow
            scrubber
            primaryControls
            secondaryControls
            if player.showVideo && player.hasVideo && !player.recommendedTracks.isEmpty {
                recommendations
            }
        }
    }

    private var artwork: some View {
        Group {
            if player.showVideo && player.hasVideo {
                // Muxed itag-18 stream: attach AVPlayerLayer to the shared player.
                // One stream, one player → audio + video are inherently synced.
                VideoLayerView()
                    .aspectRatio(16/9, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .shadow(color: theme.ink.opacity(0.22), radius: 30, y: 15)
                    .shadow(color: theme.ink.opacity(0.10), radius: 9, y: 3)
            } else {
                ThumbnailView(url: player.displayCoverURL, seed: player.currentTrack?.seed ?? 0, cornerRadius: 8, fullResolution: true)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .shadow(color: theme.ink.opacity(0.22), radius: 30, y: 15)
                    .shadow(color: theme.ink.opacity(0.10), radius: 9, y: 3)
            }
        }
        .animation(.spring(duration: 0.3), value: player.showVideo)
        .animation(.spring(duration: 0.3), value: player.hasVideo)
        .simultaneousGesture(dragGesture)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(player.currentTrack?.title ?? "")
                    .font(theme.displayFont(size: 32))
                    .foregroundStyle(theme.ink)
                    .kerning(-0.4)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if player.currentTrack?.explicit ?? false {
                        Image(systemName: "e.square.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.ink3)
                    }
                    Text(player.currentTrack?.artist ?? "")
                        .font(.system(size: 13.5))
                        .foregroundStyle(theme.ink3)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                // Share
                if let videoId = player.currentTrack?.videoId,
                   let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)") {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.ink)
                            .frame(width: 38, height: 38)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else {
                    iconButton(systemName: "square.and.arrow.up")
                }

                // Like
                Button { player.toggleLike() } label: {
                    Image(systemName: player.liked ? "heart.fill" : "heart")
                        .font(.system(size: 16))
                        .foregroundStyle(player.liked ? theme.accent : theme.ink)
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(player.liked ? theme.accent : theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .animation(.spring(duration: 0.2), value: player.liked)

                // Add to Playlist
                Button { showAddToPlaylist = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.ink)
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 6)
    }

    private var scrubber: some View {
        VStack(spacing: 10) {
            ScrubberView(
                progress: Binding(
                    get: { player.playback.progress },
                    set: { player.playback.progress = $0 }
                ),
                onEditingChanged: { player.isSeeking = $0 },
                onSeek: { player.seekTo($0) }
            )
            HStack {
                Text(player.playback.formattedCurrent())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(theme.ink3)
                Spacer()
                Text(player.playback.formattedRemaining())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(theme.ink3)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    // MARK: - Primary Controls (Experimental: exact Metrolist Player.kt port)
    //
    // Ported directly from Metrolist Player.kt lines 1516–1696:
    //
    //  Weight spring (interpolatingSpring stiffness=500, damping≈27):
    //    playPauseWeight: pressed=1.9 | side-pressed=1.1 | default=1.3
    //    backButtonWeight: pressed=0.65 | play-pressed=0.35 | default=0.45
    //    nextButtonWeight: pressed=0.65 | play-pressed=0.35 | default=0.45
    //  All three buttons share the full row width proportionally (Compose weight()).
    //  isPlaying does NOT change weights — only press interactions do.
    //
    //  Corner radius (tween 90ms linear, NOT a spring):
    //    Play button only: 36pt paused (pill) → 24pt playing (rounded rect)
    //    Side buttons: always Capsule (fully rounded), never change.
    //
    //  AnimatedContent (icon + text together, crossfade + slight scale):
    //    Matches Compose AnimatedContent default transition.

    private var primaryControls: some View {
        // Weights from Metrolist source — press-driven only, not play-state-driven
        let ppW:   CGFloat = isPressingPlay ? 1.9 : (isPressingPrev || isPressingNext ? 1.1 : 1.3)
        let backW: CGFloat = isPressingPrev  ? 0.65 : (isPressingPlay ? 0.35 : 0.45)
        let nextW: CGFloat = isPressingNext  ? 0.65 : (isPressingPlay ? 0.35 : 0.45)
        let total = ppW + backW + nextW

        return GeometryReader { geo in
            let gap: CGFloat = 8          // Metrolist: Spacer(width = 8.dp)
            let avail = geo.size.width - gap * 2
            let playWidth = avail * ppW  / total
            let backWidth = avail * backW / total
            let nextWidth = avail * nextW / total

            HStack(spacing: gap) {

                // ── Prev ─────────────────────────────────────────────────────
                Button { player.playPreviousTrack() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.ink)
                        .frame(width: backWidth, height: 56)
                        .background(
                            theme.palette.surfaceWarm,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                }
                .buttonStyle(PressTrackingStyle(pressing: $isPressingPrev))
                .disabled(!player.canPlayPreviousTrack)

                // ── Play / Pause ───────────────────────────────────────────────
                // Corner radius: tween(90ms linear) — separate from the weight spring
                Button { player.togglePlay() } label: {
                    ZStack {
                        if player.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().tint(theme.palette.bg)
                                Text("Loading")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        } else if player.isPlaying {
                            // AnimatedContent targetState=true
                            HStack(spacing: 8) {
                                Image(systemName: "pause.fill").font(.system(size: 28))
                                Text("Pause").font(.system(size: 16, weight: .semibold))
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        } else {
                            // AnimatedContent targetState=false
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill").font(.system(size: 28))
                                Text("Play").font(.system(size: 16, weight: .semibold))
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                    .foregroundStyle(theme.palette.bg)
                    .frame(width: playWidth, height: 68)
                    .background(
                        theme.ink,
                        in: Capsule()
                    )
                }
                .buttonStyle(PressTrackingStyle(pressing: $isPressingPlay))
                .disabled(player.isLoading)
                // AnimatedContent crossfade (easeInOut ~150ms matches Compose default)
                .animation(.easeInOut(duration: 0.15), value: player.isPlaying)
                .animation(.easeInOut(duration: 0.15), value: player.isLoading)

                // ── Next ─────────────────────────────────────────────────────
                Button { player.playNextTrack() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.ink)
                        .frame(width: nextWidth, height: 56)
                        .background(
                            theme.palette.surfaceWarm,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                }
                .buttonStyle(PressTrackingStyle(pressing: $isPressingNext))
                .disabled(!player.canPlayNextTrack)
            }
            // Weight spring: stiffness=500, dampingRatio=0.6
            // dampingCoeff = 2 × 0.6 × √500 ≈ 26.8
            .animation(.interpolatingSpring(stiffness: 500, damping: 27), value: isPressingPlay)
            .animation(.interpolatingSpring(stiffness: 500, damping: 27), value: isPressingPrev)
            .animation(.interpolatingSpring(stiffness: 500, damping: 27), value: isPressingNext)
        }
        .frame(height: 68)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    // MARK: - Press-tracking ButtonStyle
    // Feeds isPressed into a @Binding so the label can react to press state directly.
    private struct PressTrackingStyle: ButtonStyle {
        @Binding var pressing: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, v in pressing = v }
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 8) {
            // Shuffle
            secondaryBtn(icon: "shuffle", active: player.isShuffle) { player.toggleShuffle() }

            // Repeat
            secondaryBtn(icon: player.repeatIcon, active: player.isRepeat) {
                player.toggleRepeat()
            }
            .accessibilityLabel(player.repeatDescription)
            .animation(.spring(duration: 0.2), value: player.repeatDescription)

            // Like / Save
            secondaryBtn(icon: player.liked ? "heart.fill" : "heart", active: player.liked) { player.toggleLike() }
                .animation(.spring(duration: 0.2), value: player.liked)

            // Queue
            secondaryBtn(icon: "list.bullet", active: activePanel == .queue) {
                withAnimation(.spring(duration: 0.25)) { activePanel = .queue }
            }

            // More
            Menu {
                if let track = player.currentTrack {
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
                        player.presentAddToPlaylist(for: track)
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }

                    if player.isLiked(track: track) {
                        Button {
                            player.toggleLike(track: track)
                        } label: {
                            Label("Unlike", systemImage: "heart.slash")
                        }
                    } else {
                        Button {
                            player.toggleLike(track: track)
                        } label: {
                            Label("Like", systemImage: "heart")
                        }
                    }

                    Divider()
                }
                
                // Sleep timer
                Button { showSleepSheet = true } label: {
                    Label(player.sleepMinutesRemaining != nil ? "Change sleep timer" : "Sleep timer", systemImage: "moon")
                }
                if player.sleepMinutesRemaining != nil {
                    Button(role: .destructive) {
                        player.cancelSleep()
                    } label: {
                        Label("Cancel sleep timer", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.palette.bg)
                    .frame(width: 40, height: 40)
                    .background(theme.ink, in: Circle())
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 44)
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommended")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .kerning(1.2)
                .textCase(.uppercase)
                .padding(.horizontal, 28)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(player.recommendedTracks.prefix(10).enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.play(track: track, queue: player.recommendedTracks)
                        } label: {
                            HStack(spacing: 12) {
                                ThumbnailView(
                                    url: track.thumbnailURL,
                                    seed: track.seed,
                                    cornerRadius: 8
                                )
                                .frame(width: 48, height: 48)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(theme.ink)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(theme.ink3)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.ink2)
                                    .frame(width: 32, height: 32)
                                    .background(theme.palette.bg, in: Circle())

                                TrackMenu(track: track)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if index < min(player.recommendedTracks.count, 10) - 1 {
                                    Rectangle()
                                        .fill(theme.lineSoft)
                                        .frame(height: 1)
                                        .padding(.leading, 60)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1)
            }
            .padding(.horizontal, 28)
            .frame(maxHeight: 220)
        }
        .padding(.top, -28)
        .padding(.bottom, 18)
    }

    private func secondaryBtn(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(active ? theme.accent : theme.ink2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(height: 40)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(active ? theme.accent : theme.line, lineWidth: 1))
    }

    // MARK: - Sleep sheet
    private var sleepSheet: some View {
        NavigationStack {
            List {
                if player.sleepMinutesRemaining != nil {
                    Button(role: .destructive) {
                        player.cancelSleep()
                        showSleepSheet = false
                    } label: {
                        Label("Cancel sleep timer", systemImage: "xmark.circle")
                    }
                }
                ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { mins in
                    Button {
                        player.scheduleSleep(minutes: mins)
                        showSleepSheet = false
                    } label: {
                        HStack {
                            Text("\(mins) minutes")
                            Spacer()
                            if player.sleepMinutesRemaining != nil && player.sleepMinutesRemaining == mins {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    }
                    .foregroundStyle(theme.ink)
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSleepSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Lyrics panel
    private var lyricsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if SampleData.lyrics.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 36, weight: .thin))
                            .foregroundStyle(theme.ink3)
                        Text("No lyrics available")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
                ForEach(Array(SampleData.lyrics.enumerated()), id: \.element.id) { idx, line in
                    if line.text.isEmpty {
                        Spacer().frame(height: 18)
                    } else {
                        Text(line.text)
                            .font(line.isChorus
                                ? theme.displayFont(size: 20)
                                : .system(size: 18, weight: .medium))
                            .foregroundStyle(line.isChorus ? theme.ink : theme.ink2)
                            .kerning(-0.2)
                            .padding(.vertical, 4)
                    }
                }
                Color.clear.frame(height: theme.showMiniPlayer ? 96 : 56)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Queue panel
    private var queuePanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ThumbnailView(url: player.currentTrack?.thumbnailURL, seed: player.currentTrack?.seed ?? 0, cornerRadius: 6)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now playing")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .kerning(1.1)
                            .textCase(.uppercase)
                        Text(player.currentTrack?.title ?? "")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        Text(player.currentTrack?.artist ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.ink3)
                    }
                    Spacer()
                    EQBarsView(playing: player.isPlaying, color: theme.accent)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(theme.palette.surface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.line).frame(height: 1)
                }

                HStack {
                    Text("Up next")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                        .kerning(1.2)
                        .textCase(.uppercase)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 8)

                VStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(theme.ink3)
                    Text("Queue is empty")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)

                Color.clear.frame(height: theme.showMiniPlayer ? 96 : 56)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func iconButton(systemName: String) -> some View {
        Button {} label: {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundStyle(theme.ink)
                .frame(width: 38, height: 38)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
