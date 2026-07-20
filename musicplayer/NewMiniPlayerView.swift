//
//  NewMiniPlayerView.swift
//  Auria
//
//  Port of Metrolist's NewMiniPlayer design + architecture.
//  Reference: Metrolist 13.6.1, ui/player/MiniPlayer.kt (GPL-3.0).
//  Reimplemented in SwiftUI from the layout spec — no code copied.
//
//  Deviation from Metrolist: drop shadow retained (theirs has none).
//
//  Adapted for this project: type names prefixed `New…` so it can live
//  alongside the classic MiniPlayerView behind the "New mini player" toggle;
//  progress read as `player.playback.progress`; local SecondaryPressStyle.
//

import SwiftUI

// ═════════════════════════════════════════════════════════════════════════
// MARK: - Spec
// ═════════════════════════════════════════════════════════════════════════

private enum Spec {
    // Container — MiniPlayerHeight = 64.dp, RoundedCornerShape(32.dp)
    static let height: CGFloat = 64
    static let corner: CGFloat = 32
    static let outerHPadding: CGFloat = 12
    static let innerPadding: CGFloat = 8
    static let borderWidth: CGFloat = 1
    // Old-pill look: borders read clearly instead of hairline-faint.
    static let borderAlpha: CGFloat = 1.0

    // Play button
    static let playBox: CGFloat = 48        // progress arc diameter
    static let thumb: CGFloat = 40          // artwork
    static let ringStroke: CGFloat = 3
    // Track ring stays visible (grayish) even at zero progress.
    static let ringTrackAlpha: CGFloat = 1.0
    static let pausedScrimAlpha: CGFloat = 0.4

    // Action buttons
    static let actionSize: CGFloat = 40
    static let iconSize: CGFloat = 20
    static let likedBorderAlpha: CGFloat = 1.0
    static let likedFillAlpha: CGFloat = 0.1
    static let iconAlpha: CGFloat = 0.7

    // Spacing
    static let afterPlay: CGFloat = 16
    static let afterInfo: CGFloat = 12
    static let betweenActions: CGFloat = 8

    // Type
    static let titleSize: CGFloat = 14
    static let artistSize: CGFloat = 12
    static let errorSize: CGFloat = 10
    static let artistAlpha: CGFloat = 0.7

    // Swipe
    /// Finger tracking: not 1:1 — a stiff interactive spring trails the
    /// finger by a few points, low-pass-filtering touch noise so the drag
    /// doesn't jitter. Retargets smoothly every frame at 120Hz.
    static let track = Animation.interactiveSpring(response: 0.15, dampingFraction: 0.86)
    static let gestureSlop: CGFloat = 10
    static let velocityWeight: CGFloat = 0.12  // projects a flick into extra travel

    static let ringHz: Double = 12
}

enum MiniSwipe {
    static let enabledKey = "swipeThumbnail"
    static let sensitivityKey = "swipeSensitivity"
}

/// Press feedback for the round action buttons (scale + dim while held).
struct SecondaryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// ═════════════════════════════════════════════════════════════════════════
// MARK: - Mini player
// ═════════════════════════════════════════════════════════════════════════

struct NewMiniPlayerView: View {
    let track: Track
    var onTap: (() -> Void)? = nil

    @Environment(PlayerState.self) private var player
    @Environment(ThemeState.self) private var theme

    @AppStorage(MiniSwipe.enabledKey) private var swipeEnabled = true
    @AppStorage(MiniSwipe.sensitivityKey) private var sensitivity = 0.73

    @State private var offsetX: CGFloat = 0
    @State private var settleAnim: Animation? = nil
    @State private var dragAxis: Axis? = nil

    // Sensitivity slider → commit distance. Higher sensitivity = shorter
    // travel: 120pt at 0, 40pt at 1, ≈62pt at the 0.73 default.
    private var swipeThreshold: CGFloat {
        CGFloat(120 - 80 * sensitivity)
    }

    var body: some View {
        bar
            .offset(x: offsetX)
            .animation(settleAnim, value: offsetX)
            .frame(height: Spec.height)
            .padding(.horizontal, Spec.outerHPadding)
            .padding(.bottom, 8)
            .highPriorityGesture(swipeGesture, including: swipeEnabled ? .all : .subviews)
    }

    // ─── The bar ─────────────────────────────────────────────────────────

    private var bar: some View {
        HStack(spacing: 0) {
            MiniPlayButton(track: track)

            Spacer().frame(width: Spec.afterPlay)

            MiniSongInfo(track: track)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(width: Spec.afterInfo)

            NewMiniAddToPlaylistButton(track: track)

            Spacer().frame(width: Spec.betweenActions)

            MiniFavoriteButton()
        }
        .padding(Spec.innerPadding)
        .frame(maxWidth: .infinity)
        .frame(height: Spec.height)
        // Light pill; the filled base-color buttons and ring read against it.
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Spec.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Spec.corner, style: .continuous)
                .stroke(theme.line.opacity(Spec.borderAlpha), lineWidth: Spec.borderWidth)
        }
        .geometryGroup()
        .contentShape(RoundedRectangle(cornerRadius: Spec.corner, style: .continuous))
        .onTapGesture {
            onTap?()
        }
    }

    // ─── Gesture ─────────────────────────────────────────────────────────

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: Spec.gestureSlop)
            .onChanged { value in
                if dragAxis == nil {
                    let w = abs(value.translation.width)
                    let h = abs(value.translation.height)
                    guard max(w, h) > 2 else { return }
                    dragAxis = w > h ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }

                settleAnim = Spec.track                 // smoothed finger tracking
                let raw = liveTranslation(value.translation.width)

                // Direction gating: refuse to travel toward a track that
                // doesn't exist, but always allow the return to centre.
                let blocked = (raw > 0 && !player.canPlayPreviousTrack)
                           || (raw < 0 && !player.canPlayNextTrack)
                guard !blocked else { return }

                offsetX = raw                           // 1:1, no rubber band
            }
            .onEnded { value in
                defer { dragAxis = nil }
                guard dragAxis == .horizontal else { settle(); return }

                let raw = liveTranslation(value.translation.width)
                // A flick projects into extra travel, so a short fast swipe
                // commits just like a long slow drag.
                let projected = raw + value.velocity.width * Spec.velocityWeight
                let commit = max(abs(raw), abs(projected)) > swipeThreshold

                if commit {
                    if raw > 0, player.canPlayPreviousTrack {
                        player.playPreviousTrack()
                    } else if raw < 0, player.canPlayNextTrack {
                        player.playNextTrack()
                    }
                }
                settle(fingerVelocity: value.velocity.width)
            }
    }

    /// Compose accumulates post-slop deltas, so the recogniser's dead zone
    /// never lands in the offset. Subtracting it here matches that.
    private func liveTranslation(_ raw: CGFloat) -> CGFloat {
        let sign: CGFloat = raw < 0 ? -1 : 1
        return sign * max(0, abs(raw) - Spec.gestureSlop)
    }

    /// One spring for every outcome. No withAnimation — the modifier owns it,
    /// so a track change in the same pass cannot inherit the transaction.
    ///
    /// The spring inherits the finger's release velocity (normalized to the
    /// travel distance, as interpolatingSpring expects) so the settle
    /// continues the gesture's momentum instead of restarting from rest —
    /// this is what makes the hand-off read as one motion at 120Hz.
    private func settle(fingerVelocity: CGFloat = 0) {
        let distance = -offsetX   // animation travel: current → 0
        var normalized: Double = 0
        if abs(distance) > 1 {
            normalized = Double(fingerVelocity / distance)
            normalized = min(max(normalized, -25), 25)
        }
        settleAnim = .interpolatingSpring(
            mass: 1, stiffness: 200, damping: 28.3, initialVelocity: normalized
        )
        offsetX = 0
    }
}

// ═════════════════════════════════════════════════════════════════════════
// MARK: - Play button
// ═════════════════════════════════════════════════════════════════════════

struct MiniPlayButton: View {
    let track: Track

    @Environment(PlayerState.self) private var player
    @Environment(ThemeState.self) private var theme

    var body: some View {
        Button {
            player.togglePlay()
        } label: {
            ZStack {
                NewMiniProgressRing(player: player,
                                    progress: theme.accent,
                                    trackColor: theme.line.opacity(Spec.ringTrackAlpha))

                ThumbnailView(url: track.thumbnailURL, seed: track.seed, cornerRadius: 999)
                    .frame(width: Spec.thumb, height: Spec.thumb)
                    .clipShape(Circle())
                    .overlay {
                        Circle().stroke(theme.line.opacity(Spec.borderAlpha),
                                        lineWidth: Spec.borderWidth)
                    }

                // Paused state layers on top — never an if/else, so there is
                // no view insertion to fade mid-gesture.
                Circle()
                    .fill(.black.opacity(Spec.pausedScrimAlpha))
                    .frame(width: Spec.thumb, height: Spec.thumb)
                    .opacity(player.isPlaying ? 0 : 1)

                Image(systemName: "play.fill")
                    .font(.system(size: Spec.iconSize * 0.8, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(player.isPlaying ? 0 : 1)
            }
            .frame(width: Spec.playBox, height: Spec.playBox)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
        // No loading spinner — Metrolist has none here. Buffering reads as
        // paused, which is why nothing can restructure during a swipe.
    }
}

// ═════════════════════════════════════════════════════════════════════════
// MARK: - Progress ring
// ═════════════════════════════════════════════════════════════════════════

/// Metrolist reads progress only inside `drawWithContent` — the draw phase,
/// never composition, so the tick cannot invalidate the bar. Canvas +
/// TimelineView is the SwiftUI equivalent.
///
/// `player` arrives as a plain parameter rather than via @Environment so this
/// view registers no observation dependency on it.
struct NewMiniProgressRing: View {
    let player: PlayerState
    let progress: Color
    let trackColor: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / Spec.ringHz)) { _ in
            Canvas { ctx, size in
                let raw = player.playback.progress
                let p: Double = raw.isFinite ? min(max(raw, 0), 1) : 0

                let inset = Spec.ringStroke / 2
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                let style = StrokeStyle(lineWidth: Spec.ringStroke, lineCap: .round)

                ctx.stroke(Path(ellipseIn: rect), with: .color(trackColor), style: style)

                guard p > 0 else { return }
                var arc = Path()
                arc.addArc(center: CGPoint(x: size.width / 2, y: size.height / 2),
                           radius: rect.width / 2,
                           startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * p),
                           clockwise: false)
                ctx.stroke(arc, with: .color(progress), style: style)
            }
        }
        .frame(width: Spec.playBox, height: Spec.playBox)
        .transaction { $0.animation = nil }
    }
}

// ═════════════════════════════════════════════════════════════════════════
// MARK: - Song info
// ═════════════════════════════════════════════════════════════════════════

struct MiniSongInfo: View {
    let track: Track

    @Environment(PlayerState.self) private var player
    @Environment(ThemeState.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(track.title)
                .font(.system(size: Spec.titleSize, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            HStack(spacing: 4) {
                if track.explicit {
                    Text("E")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.ink.opacity(Spec.artistAlpha))
                        .padding(.horizontal, 3)
                        .background(theme.line.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: 2))
                }
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: Spec.artistSize))
                        .foregroundStyle(theme.ink.opacity(Spec.artistAlpha))
                        .lineLimit(1)
                }
            }

            if player.errorMessage != nil {
                Text("Error playing")
                    .font(.system(size: Spec.errorSize))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        // Metrolist marquees title and artist after a 3s delay at 30dp/s.
        // SwiftUI has no equivalent — truncation for now; a custom marquee
        // is a separate piece of work.
    }
}

// ═════════════════════════════════════════════════════════════════════════
// MARK: - Action buttons
// ═════════════════════════════════════════════════════════════════════════

/// Shared 40pt circle chrome: 1pt border, optional tinted fill, 20pt icon.
private struct MiniActionButton: View {
    let systemName: String
    let tint: Color
    let border: Color
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Spec.iconSize * 0.8, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: Spec.actionSize, height: Spec.actionSize)
                .background(fill, in: Circle())
                .overlay {
                    Circle().stroke(border, lineWidth: Spec.borderWidth)
                }
                .contentShape(Circle())
        }
        .buttonStyle(SecondaryPressStyle())
    }
}

/// Stateless — Metrolist's AddToPlaylistButton takes only onClick. The sheet
/// lives here rather than in the parent; parent-owned presentation state
/// would re-render the whole bar on every open.
struct NewMiniAddToPlaylistButton: View {
    let track: Track

    @Environment(PlayerState.self) private var player
    @Environment(ThemeState.self) private var theme
    @State private var showSheet = false

    var body: some View {
        MiniActionButton(
            systemName: "plus",
            tint: theme.ink.opacity(Spec.iconAlpha),
            border: theme.line.opacity(Spec.borderAlpha),
            fill: theme.palette.bg
        ) { showSheet = true }
        .sheet(isPresented: $showSheet) {
            AddToPlaylistView(track: track)
                .environment(theme)
                .environment(player)
        }
    }
}

/// Observes PlayerState for itself, so the parent never needs to know
/// whether the track is liked — and never re-renders when it changes.
struct MiniFavoriteButton: View {
    @Environment(PlayerState.self) private var player
    @Environment(ThemeState.self) private var theme

    private var isLiked: Bool { player.liked }

    var body: some View {
        MiniActionButton(
            systemName: isLiked ? "heart.fill" : "heart",
            tint: isLiked ? theme.accent : theme.ink.opacity(Spec.iconAlpha),
            border: isLiked ? theme.accent.opacity(Spec.likedBorderAlpha)
                            : theme.line.opacity(Spec.borderAlpha),
            fill: theme.palette.bg
        ) {
            player.toggleLike()
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════
// MARK: - Settings rows
// ═════════════════════════════════════════════════════════════════════════

/// Rows for the Theme settings group, below "Show mini player".
struct MiniPlayerSwipeSettingsRows: View {
    @AppStorage(MiniSwipe.enabledKey) private var swipeEnabled = true
    @AppStorage(MiniSwipe.sensitivityKey) private var sensitivity = 0.73

    @Environment(ThemeState.self) private var theme

    var body: some View {
        SettingToggleRow(
            label: "Swipe to change track",
            sub: "Drag the mini player left or right",
            value: $swipeEnabled,
            isLast: !swipeEnabled
        )

        if swipeEnabled {
            SettingRow(isLast: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("Swipe sensitivity")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(theme.ink)
                        Spacer()
                        Text("\(Int((sensitivity * 100).rounded()))%")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(theme.accent)
                    }
                    Slider(value: $sensitivity, in: 0...1)
                        .tint(theme.ink)
                }
            }
        }
    }
}
