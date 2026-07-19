import SwiftUI
import UIKit
import ImageIO

// MARK: - In-memory image cache
//
// A process-wide NSCache of decoded UIImages keyed by URL + target pixel size,
// so the same cover isn't refetched/redecoded every time a row scrolls back on
// screen or the now-playing sheet reopens. Keying by size means a cover shown
// at 44pt and at 200pt each keep their own right-sized bitmap instead of one
// stomping the other. NSCache evicts automatically under memory pressure.
enum ImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 250
        return c
    }()
}

// MARK: - ImageIO downsampling
//
// Decodes only a thumbnail at `maxPixel`, so a 544²/640² source shown in a 44pt
// row costs ~a few KB of memory instead of the full decoded bitmap. The decode
// happens at the target size (kCGImageSourceCreateThumbnailFromImageAlways), so
// there's no full-size intermediate.
// `nonisolated` so it runs on a background executor, never the main actor —
// decoding during a fast scroll must not block the UI.
nonisolated private func downsampledImage(from data: Data, maxPixel: CGFloat) -> UIImage? {
    let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

// MARK: - Cached async image view
//
// Drop-in replacement for AsyncImage that checks ImageCache first and, when a
// `targetSize` is given, downsamples to that size. Pass `targetSize: nil` to
// keep full resolution (used only for the now-playing main artwork).
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let targetSize: CGSize?
    /// Keep the last decoded image on screen while a new URL loads, instead of
    /// dropping to the placeholder on a cache miss. Used by the mini player so a
    /// swipe-triggered cover change never flashes the procedural placeholder.
    private let holdWhileLoading: Bool
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var uiImage: UIImage?

    init(url: URL?,
         targetSize: CGSize? = nil,
         holdWhileLoading: Bool = false,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.targetSize = targetSize
        self.holdWhileLoading = holdWhileLoading
        self.content = content
        self.placeholder = placeholder
    }

    /// Longest edge in pixels to decode to, bucketed to 32px steps so we don't
    /// cache a near-identical bitmap for every fractional layout size. `nil`
    /// means "full resolution" (no target requested).
    private var maxPixelDimension: CGFloat? {
        guard let targetSize else { return nil }
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }
        let scale = displayScale > 0 ? displayScale : 3
        let raw = max(targetSize.width, targetSize.height) * scale
        return (raw / 32).rounded(.up) * 32
    }

    private var cacheKey: NSString {
        guard let url else { return "" as NSString }
        if let px = maxPixelDimension { return "\(url.absoluteString)|\(Int(px))" as NSString }
        return url.absoluteString as NSString
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: cacheKey) { await load() }
    }

    private func load() async {
        guard let url else { uiImage = nil; return }
        // A target size was requested but the view isn't laid out yet — wait for
        // the next pass rather than fetching a full-size image we'd re-decode.
        if targetSize != nil, maxPixelDimension == nil { return }

        // Cache hit → swap in instantly. Crucially we DON'T clear uiImage first,
        // so a recycled row showing the right cached cover never flashes the
        // procedural placeholder mid-scroll.
        let key = cacheKey
        if let cached = ImageCache.shared.object(forKey: key) {
            uiImage = cached
            return
        }

        // Cache miss → show the placeholder while we fetch + decode off the main
        // actor (so fast scrolling never stalls on network or image decoding).
        // With holdWhileLoading we keep the current image up instead, so the
        // swap is old-cover → new-cover rather than a placeholder flash.
        if !holdWhileLoading { uiImage = nil }
        let image = await fetchAndDecode(url: url, maxPixel: maxPixelDimension)
        guard let image, !Task.isCancelled else { return }

        ImageCache.shared.setObject(image, forKey: key)
        uiImage = image
    }

    nonisolated private func fetchAndDecode(url: URL, maxPixel: CGFloat?) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        if let maxPixel {
            return downsampledImage(from: data, maxPixel: maxPixel) ?? UIImage(data: data)
        }
        return UIImage(data: data)
    }
}
