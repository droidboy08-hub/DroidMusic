import SwiftUI

// MARK: - Import source
//
// The three cards in the import carousel. Each has brand colours; the card fills
// with its tint on completion (DroidMusic stays light, matching the design).
enum ImportSource: Int, CaseIterable, Identifiable {
    case spotify, youtube, droidmusic
    var id: Int { rawValue }

    var name: String {
        switch self {
        case .spotify:    return "Spotify"
        case .youtube:    return "YouTube"
        case .droidmusic: return "DroidMusic"
        }
    }
    var sub: String {
        switch self {
        case .spotify:    return "Playlists & Albums"
        case .youtube:    return "Videos & Playlists"
        case .droidmusic: return "Local Library"
        }
    }
    var tint: Color {
        switch self {
        case .spotify:    return Color(hex: "#1DB954")
        case .youtube:    return Color(hex: "#FF0000")
        case .droidmusic: return Color(hex: "#141414")
        }
    }
    /// Card background turns `tint` on completion (DroidMusic stays light).
    var fillsOnDone: Bool { self != .droidmusic }
}

// MARK: - YouTube glyph (rounded box + play triangle)
struct YouTubeMark: View {
    var box: Color
    var play: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: min(w, h) * 0.3, style: .continuous)
                    .fill(box)
                Path { p in
                    let tw = w * 0.12, th = h * 0.42
                    let cx = w / 2, cy = h / 2
                    p.move(to: CGPoint(x: cx - tw, y: cy - th / 2))
                    p.addLine(to: CGPoint(x: cx - tw, y: cy + th / 2))
                    p.addLine(to: CGPoint(x: cx + tw * 1.7, y: cy))
                    p.closeSubpath()
                }
                .fill(play)
            }
        }
    }
}

// MARK: - DroidMusic glyph (rounded tile + note)
struct DroidMusicMark: View {
    var tile: Color
    var note: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tile)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(note)
            }
    }
}

// MARK: - Import source card
//
// A 160×200 card with the source logo, name, sub-label and a live song counter.
// Two ring overlays trace the rounded border: a faint full ring, and a coloured
// `progress` ring (0…1). On `isDone`, brand-fills and recolours its contents.
struct ImportSourceCard: View {
    let source: ImportSource
    var progress: Double = 0
    var isDone: Bool = false
    var counter: String = ""
    var cardBG: Color
    var ink: Color
    var ink3: Color

    private var filled: Bool { isDone && source.fillsOnDone }
    private var bg: Color { filled ? source.tint : cardBG }
    private var nameColor: Color { filled ? .white : ink }
    private var subColor: Color { filled ? .white.opacity(0.75) : ink3 }
    private var counterColor: Color { filled ? .white.opacity(0.9) : ink3 }

    var body: some View {
        VStack(spacing: 12) {
            logo
            Text(source.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(nameColor)
            Text(source.sub)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(subColor)
            Text(counter)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(counterColor)
                .frame(height: 16)
        }
        .frame(width: 160, height: 200)
        .background(bg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(ink.opacity(0.07), lineWidth: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .inset(by: 1.5)
                .trim(from: 0, to: progress)
                .stroke(source.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .animation(.easeOut(duration: 0.3), value: progress)
        .animation(.easeInOut(duration: 0.45), value: isDone)
    }

    @ViewBuilder private var logo: some View {
        switch source {
        case .spotify:
            SpotifyMark(tint: filled ? .white : source.tint,
                        bar: filled ? source.tint : cardBG)
                .frame(width: 76, height: 76)
        case .youtube:
            YouTubeMark(box: filled ? .white : source.tint,
                        play: filled ? source.tint : .white)
                .frame(width: 84, height: 60)
        case .droidmusic:
            DroidMusicMark(tile: source.tint, note: .white)
                .frame(width: 72, height: 72)
        }
    }
}
