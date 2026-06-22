import SwiftUI

// MARK: - Fullscreen landscape video
//
// Reuses the shared AVPlayer via VideoLayerView (no second player is created —
// the same itag-18 muxed stream keeps playing, we just attach another
// AVPlayerLayer for the duration of the cover). Forces landscape on appear and
// restores portrait on dismiss. Controls auto-hide and toggle on tap.
struct FullScreenVideoView: View {
    @Environment(PlayerState.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoLayerView()
                .ignoresSafeArea()

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            OrientationLock.enterLandscape()
            scheduleAutoHide()
        }
        .onDisappear {
            hideWorkItem?.cancel()
            OrientationLock.enterPortrait()
        }
    }

    // MARK: Controls overlay
    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerTransport
            Spacer()
            bottomScrubber
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(player.currentTrack?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var centerTransport: some View {
        HStack(spacing: 48) {
            Button { player.playPreviousTrack() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!player.canPlayPreviousTrack)
            .opacity(player.canPlayPreviousTrack ? 1 : 0.4)

            Button { player.togglePlay() } label: {
                Group {
                    if player.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 76, height: 76)
                .background(.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)

            Button { player.playNextTrack() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!player.canPlayNextTrack)
            .opacity(player.canPlayNextTrack ? 1 : 0.4)
        }
        // Keep the auto-hide timer alive while the user is interacting.
        .onChange(of: player.isPlaying) { _, _ in scheduleAutoHide() }
    }

    private var bottomScrubber: some View {
        VStack(spacing: 6) {
            FullScreenScrubber(
                progress: Binding(
                    get: { player.progress },
                    set: { player.progress = $0 }
                ),
                onEditingChanged: { editing in
                    player.isSeeking = editing
                    if editing { hideWorkItem?.cancel() } else { scheduleAutoHide() }
                },
                onSeek: { player.seekTo($0) }
            )
            HStack {
                Text(player.formattedCurrent())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(player.formattedRemaining())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: Controls visibility
    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleAutoHide() } else { hideWorkItem?.cancel() }
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }
}

// MARK: - Scrubber (white, for the black fullscreen surface)
private struct FullScreenScrubber: View {
    @Binding var progress: Double
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onSeek: ((Double) -> Void)? = nil
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = progress.isFinite ? min(max(progress, 0), 1) : 0
            let fillW = max(0, w * p)
            let barH: CGFloat = isDragging ? 8 : 6

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: barH)
                Capsule()
                    .fill(.white)
                    .frame(width: max(fillW, barH), height: barH)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        if !isDragging { isDragging = true; onEditingChanged?(true) }
                        progress = w > 0 ? max(0, min(1, val.location.x / w)) : 0
                    }
                    .onEnded { val in
                        let seek = w > 0 ? max(0, min(1, val.location.x / w)) : 0
                        progress = seek
                        onSeek?(seek)
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
            .animation(.easeInOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 24)
    }
}
