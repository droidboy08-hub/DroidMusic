import SwiftUI

// MARK: - Spotify logo mark
//
// The Spotify glyph: a filled disc with three upward-bowing sound-wave bars.
// `tint` is the disc colour; `bar` is the wave colour — usually the surface
// behind it, so the waves read as cut-outs.
struct SpotifyMark: View {
    let tint: Color
    let bar: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let lw = s * 0.085
            ZStack {
                Circle().fill(tint)
                arc(size: s, y: 0.40, halfWidth: 0.30, rise: 0.11, lineWidth: lw)
                arc(size: s, y: 0.545, halfWidth: 0.245, rise: 0.095, lineWidth: lw)
                arc(size: s, y: 0.675, halfWidth: 0.175, rise: 0.075, lineWidth: lw)
            }
            .frame(width: s, height: s)
        }
    }

    private func arc(size s: CGFloat, y: CGFloat, halfWidth: CGFloat, rise: CGFloat, lineWidth lw: CGFloat) -> some View {
        Path { p in
            let cx = s / 2
            let hw = s * halfWidth
            let yy = s * y
            p.move(to: CGPoint(x: cx - hw, y: yy))
            p.addQuadCurve(to: CGPoint(x: cx + hw, y: yy),
                           control: CGPoint(x: cx, y: yy - s * rise))
        }
        .stroke(bar, style: StrokeStyle(lineWidth: lw, lineCap: .round))
    }
}

// MARK: - Animated Spotify import badge
//
// A Spotify logo inside a green ring, with three modes:
//   .interactive — press to fill (green disc grows, logo turns white + scales),
//                  release snaps back; a quick tap pulses.
//   .loading     — gently "breathes" (scales in/out on a loop) to signal work.
//   .done        — the filled last frame (green disc, white logo, scaled), static.
enum SpotifyBadgeMode { case interactive, loading, done }

struct SpotifyImportBadge: View {
    var size: CGFloat = 120
    /// Colour behind the logo at rest (the sheet background) so the wave
    /// cut-outs blend in until the green fill takes over.
    var restBar: Color
    var mode: SpotifyBadgeMode = .interactive

    @State private var pressed = false     // interactive press-fill
    @State private var breathe = false     // loading breathing loop
    private let green = Color(hex: "#1DB954")
    private var fillCurve: Animation { .timingCurve(0.22, 1, 0.36, 1, duration: 0.4) }

    /// Green disc + white logo, scaled up — the "active"/last frame.
    private var filled: Bool { mode == .done || (mode == .interactive && pressed) }
    private var breathScale: CGFloat { mode == .loading ? (breathe ? 1.06 : 0.94) : 1 }

    var body: some View {
        ZStack {
            Circle()
                .fill(green)
                .scaleEffect(filled ? 1 : 0)           // grows from the centre
            SpotifyMark(tint: filled ? .white : green,
                        bar: filled ? green : restBar)
                .frame(width: size * 0.66, height: size * 0.66)
                .scaleEffect(filled ? 1.25 : 1)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(green, lineWidth: 3))
        .scaleEffect(breathScale)                       // breathing (loading only)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: 60, maximumDistance: 40,
                            pressing: { if mode == .interactive { pressed = $0 } },
                            perform: {})
        .animation(fillCurve, value: filled)
        .onAppear { syncBreathing() }
        .onChange(of: mode) { _, _ in syncBreathing() }
    }

    /// Start/stop the perpetual breathing pulse to match the current mode.
    private func syncBreathing() {
        if mode == .loading {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                breathe = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { breathe = false }
        }
    }
}
