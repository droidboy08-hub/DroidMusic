import SwiftUI

// MARK: - In-memory image cache
//
// A process-wide NSCache of decoded UIImages keyed by URL, so the same cover
// isn't refetched/redecoded every time a row scrolls back on screen or the
// now-playing sheet reopens. NSCache evicts automatically under memory pressure.
enum ImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 250
        return c
    }()
}

// MARK: - Cached async image view
//
// Drop-in replacement for AsyncImage that checks ImageCache first. Mirrors the
// success/placeholder split the app already uses (procedural art fallback).
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    init(url: URL?,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        uiImage = nil
        guard let url else { return }
        let key = url as NSURL
        if let cached = ImageCache.shared.object(forKey: key) {
            uiImage = cached
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        ImageCache.shared.setObject(image, forKey: key)
        guard !Task.isCancelled else { return }
        uiImage = image
    }
}
