import SwiftUI

// Loads a real thumbnail URL if available, falls back to procedural art.
struct ThumbnailView: View {
    let url: String?
    var seed: Int = 0
    var cornerRadius: CGFloat = 6
    /// Skip downsampling and decode at full resolution. Only the now-playing
    /// main artwork sets this — everywhere else the image is decoded to the
    /// size it's actually shown at.
    var fullResolution: Bool = false
    /// Keep the previous cover visible while a new URL loads (mini player swipe).
    var holdWhileLoading: Bool = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let urlStr = url, let imageURL = URL(string: urlStr) {
                    CachedAsyncImage(url: imageURL,
                                     targetSize: fullResolution ? nil : geometry.size,
                                     holdWhileLoading: holdWhileLoading) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        AlbumArtView(seed: seed, cornerRadius: cornerRadius)
                    }
                } else {
                    AlbumArtView(seed: seed, cornerRadius: cornerRadius)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

// Procedural album art — 5 variants, 8 colour palettes, seeded.
struct AlbumArtView: View {
    let seed: Int
    var cornerRadius: CGFloat = 6

    private static let palettes: [[Color]] = [
        [Color(hex: "#C8501B"), Color(hex: "#13110E"), Color(hex: "#F2ECDF"), Color(hex: "#8A4A1F")],
        [Color(hex: "#3D4A35"), Color(hex: "#F2ECDF"), Color(hex: "#C8501B"), Color(hex: "#1A2118")],
        [Color(hex: "#13110E"), Color(hex: "#F2ECDF"), Color(hex: "#C8501B"), Color(hex: "#4A4438")],
        [Color(hex: "#8A4A1F"), Color(hex: "#F1D7C0"), Color(hex: "#13110E"), Color(hex: "#C8501B")],
        [Color(hex: "#3D4A35"), Color(hex: "#E8DFC9"), Color(hex: "#13110E"), Color(hex: "#C8501B")],
        [Color(hex: "#C8501B"), Color(hex: "#F1D7C0"), Color(hex: "#13110E"), Color(hex: "#3D4A35")],
        [Color(hex: "#1A2118"), Color(hex: "#3D4A35"), Color(hex: "#F2ECDF"), Color(hex: "#C8501B")],
        [Color(hex: "#4A4438"), Color(hex: "#F2ECDF"), Color(hex: "#C8501B"), Color(hex: "#13110E")],
    ]

    var body: some View {
        GeometryReader { geo in
            let p = Self.palettes[seed % Self.palettes.count]
            let v = seed % 5
            let s = geo.size

            Canvas { ctx, size in
                switch v {
                case 0: drawVariant0(ctx, size: size, p: p)
                case 1: drawVariant1(ctx, size: size, p: p)
                case 2: drawVariant2(ctx, size: size, p: p)
                case 3: drawVariant3(ctx, size: size, p: p)
                default: drawVariant4(ctx, size: size, p: p)
                }
                // Subtle highlight gloss
                let gloss = Path(ellipseIn: CGRect(x: -size.width * 0.1, y: -size.height * 0.1,
                                                   width: size.width * 0.9, height: size.height * 0.7))
                ctx.fill(gloss, with: .color(.white.opacity(0.07)))
            }
            .frame(width: s.width, height: s.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // Variant 0: background + large circle + small circle + bottom strip
    private func drawVariant0(_ ctx: GraphicsContext, size: CGSize, p: [Color]) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(p[0]))
        ctx.fill(Path(ellipseIn: CGRect(x: w * 0.20, y: h * 0.25, width: w * 0.60, height: w * 0.60)), with: .color(p[2]))
        ctx.fill(Path(ellipseIn: CGRect(x: w * 0.36, y: h * 0.41, width: w * 0.28, height: w * 0.28)), with: .color(p[1]))
        ctx.fill(Path(CGRect(x: 0, y: h * 0.78, width: w, height: h * 0.22)), with: .color(p[3]))
    }

    // Variant 1: vertical stripes + horizontal band
    private func drawVariant1(_ ctx: GraphicsContext, size: CGSize, p: [Color]) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(p[0]))
        for i in 0..<8 {
            let x = CGFloat(i) * w * 0.13
            ctx.fill(Path(CGRect(x: x, y: 0, width: w * 0.06, height: h)),
                     with: .color(i % 2 == 1 ? p[1] : p[2]))
        }
        ctx.fill(Path(CGRect(x: 0, y: h * 0.40, width: w, height: h * 0.20)),
                 with: .color(p[3].opacity(0.85)))
    }

    // Variant 2: nested squares
    private func drawVariant2(_ ctx: GraphicsContext, size: CGSize, p: [Color]) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(p[1]))
        ctx.fill(Path(CGRect(x: w * 0.10, y: h * 0.10, width: w * 0.80, height: h * 0.80)), with: .color(p[0]))
        ctx.fill(Path(CGRect(x: w * 0.20, y: h * 0.20, width: w * 0.60, height: h * 0.60)), with: .color(p[2]))
        ctx.fill(Path(CGRect(x: w * 0.32, y: h * 0.32, width: w * 0.36, height: h * 0.36)), with: .color(p[3]))
    }

    // Variant 3: wave paths + circle accent
    private func drawVariant3(_ ctx: GraphicsContext, size: CGSize, p: [Color]) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(p[0]))

        var wave1 = Path()
        wave1.move(to: CGPoint(x: 0, y: h * 0.70))
        wave1.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.60),
                           control: CGPoint(x: w * 0.25, y: h * 0.40))
        wave1.addQuadCurve(to: CGPoint(x: w, y: h * 0.50),
                           control: CGPoint(x: w * 0.75, y: h * 0.80))
        wave1.addLine(to: CGPoint(x: w, y: h))
        wave1.addLine(to: CGPoint(x: 0, y: h))
        wave1.closeSubpath()
        ctx.fill(wave1, with: .color(p[3]))

        var wave2 = Path()
        wave2.move(to: CGPoint(x: 0, y: h * 0.80))
        wave2.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.75),
                           control: CGPoint(x: w * 0.25, y: h * 0.55))
        wave2.addQuadCurve(to: CGPoint(x: w, y: h * 0.65),
                           control: CGPoint(x: w * 0.75, y: h * 0.95))
        wave2.addLine(to: CGPoint(x: w, y: h))
        wave2.addLine(to: CGPoint(x: 0, y: h))
        wave2.closeSubpath()
        ctx.fill(wave2, with: .color(p[2].opacity(0.90)))

        ctx.fill(Path(ellipseIn: CGRect(x: w * 0.61, y: h * 0.14, width: w * 0.28, height: w * 0.28)),
                 with: .color(p[2]))
    }

    // Variant 4: triangle with inner triangle + circle
    private func drawVariant4(_ ctx: GraphicsContext, size: CGSize, p: [Color]) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(p[2]))

        var tri1 = Path()
        tri1.move(to: CGPoint(x: w * 0.50, y: h * 0.08))
        tri1.addLine(to: CGPoint(x: w * 0.92, y: h * 0.92))
        tri1.addLine(to: CGPoint(x: w * 0.08, y: h * 0.92))
        tri1.closeSubpath()
        ctx.fill(tri1, with: .color(p[0]))

        var tri2 = Path()
        tri2.move(to: CGPoint(x: w * 0.50, y: h * 0.30))
        tri2.addLine(to: CGPoint(x: w * 0.76, y: h * 0.82))
        tri2.addLine(to: CGPoint(x: w * 0.24, y: h * 0.82))
        tri2.closeSubpath()
        ctx.fill(tri2, with: .color(p[3]))

        ctx.fill(Path(ellipseIn: CGRect(x: w * 0.41, y: h * 0.59, width: w * 0.18, height: h * 0.18)),
                 with: .color(p[1]))
    }
}

#Preview {
    HStack(spacing: 8) {
        ForEach(0..<5) { i in
            AlbumArtView(seed: i, cornerRadius: 8)
                .frame(width: 64, height: 64)
        }
    }
    .padding()
}
