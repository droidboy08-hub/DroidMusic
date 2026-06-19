import Foundation

// MARK: - Unified metadata type
//
// One shape produced by BOTH the /player path (videoDetails) and the
// search/browse path (renderers), so the UI has a single consistent type.
nonisolated struct TrackMetadata: Equatable {
    let title: String
    let artist: String
    let durationSeconds: Double?   // nil when unknown (guard division on this)
    let coverURL: String?
    let videoId: String?
}

extension TrackMetadata {
    /// Bridge to the app's existing Track model (the rest of the app speaks Track).
    nonisolated func asTrack() -> Track {
        Track(title: title, artist: artist, duration: "",
              videoId: videoId, thumbnailURL: coverURL)
    }
}

// MARK: - Defensive InnerTube/JSON metadata parser
//
// Pure JSON parsing of responses we already fetch — no ciphers, no extra calls.
// Every path is walked through optionals and skips malformed entries rather than
// crashing, because YouTube's renderer nesting drifts over time.
nonisolated enum MetadataParser {

    // MARK: /player → videoDetails (reuse the response we fetch for the stream URL)
    static func parsePlayerResponse(_ json: [String: Any]) -> TrackMetadata? {
        guard let vd = json["videoDetails"] as? [String: Any] else { return nil }
        let title  = (vd["title"]  as? String) ?? ""
        let artist = (vd["author"] as? String) ?? ""
        // lengthSeconds is a String; treat 0/invalid as unknown (nil) so progress math can guard it.
        let duration = (vd["lengthSeconds"] as? String).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        let thumbs = (((vd["thumbnail"] as? [String: Any])?["thumbnails"]) as? [[String: Any]]) ?? []
        let cover  = thumbs.last?["url"] as? String   // last = highest res
        let videoId = vd["videoId"] as? String
        guard !title.isEmpty || videoId != nil else { return nil }
        return TrackMetadata(title: title, artist: artist, durationSeconds: duration,
                             coverURL: cover, videoId: videoId)
    }

    // MARK: /search & /browse → list rows
    //
    // Recursively collects every song-row renderer ANYWHERE in the tree, so it
    // works for search, browse, and continuation shapes without path-specific
    // code (the nesting that drifts). Rows without a videoId (albums/artists/
    // playlists) are skipped; duplicates are de-duped by videoId.
    static func parseSearchItems(_ json: [String: Any]) -> [TrackMetadata] {
        var out: [TrackMetadata] = []
        var seen = Set<String>()
        collectRenderers(json) { renderer, kind in
            let meta = (kind == .responsiveList)
                ? parseResponsiveListItem(renderer)
                : parseTwoRowItem(renderer)
            if let m = meta, let vid = m.videoId, !vid.isEmpty, seen.insert(vid).inserted {
                out.append(m)
            }
        }
        return out
    }

    private enum RendererKind { case responsiveList, twoRow }

    private static func collectRenderers(_ node: Any,
                                         _ body: (_ renderer: [String: Any], _ kind: RendererKind) -> Void) {
        if let dict = node as? [String: Any] {
            if let r = dict["musicResponsiveListItemRenderer"] as? [String: Any] { body(r, .responsiveList) }
            if let r = dict["musicTwoRowItemRenderer"]        as? [String: Any] { body(r, .twoRow) }
            for (_, v) in dict { collectRenderers(v, body) }
        } else if let arr = node as? [Any] {
            for v in arr { collectRenderers(v, body) }
        }
    }

    private static func parseResponsiveListItem(_ r: [String: Any]) -> TrackMetadata? {
        let flex = r["flexColumns"] as? [[String: Any]] ?? []
        func columnText(_ i: Int) -> String? {
            guard flex.indices.contains(i),
                  let col = flex[i]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                  let runs = (col["text"] as? [String: Any])?["runs"] as? [[String: Any]] else { return nil }
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        let title = columnText(0) ?? ""
        guard !title.isEmpty else { return nil }
        let artist = columnText(1) ?? ""
        let videoId = (r["playlistItemData"] as? [String: Any])?["videoId"] as? String ?? findVideoId(r)
        return TrackMetadata(title: title, artist: artist, durationSeconds: nil,
                             coverURL: lastThumbnailURL(in: r), videoId: videoId)
    }

    private static func parseTwoRowItem(_ r: [String: Any]) -> TrackMetadata? {
        func runsText(_ key: String) -> String? {
            guard let runs = (r[key] as? [String: Any])?["runs"] as? [[String: Any]] else { return nil }
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        let title = runsText("title") ?? ""
        guard !title.isEmpty else { return nil }
        let artist = runsText("subtitle") ?? ""
        let videoId = ((r["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
            ?? findVideoId(r)
        return TrackMetadata(title: title, artist: artist, durationSeconds: nil,
                             coverURL: lastThumbnailURL(in: r), videoId: videoId)
    }

    /// First `watchEndpoint.videoId` found anywhere under the node.
    private static func findVideoId(_ node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let we = dict["watchEndpoint"] as? [String: Any], let vid = we["videoId"] as? String { return vid }
            for (_, v) in dict { if let f = findVideoId(v) { return f } }
        } else if let arr = node as? [Any] {
            for v in arr { if let f = findVideoId(v) { return f } }
        }
        return nil
    }

    /// Highest-res thumbnail URL under the node (last of the first `thumbnails` array found).
    private static func lastThumbnailURL(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let thumbs = dict["thumbnails"] as? [[String: Any]], let url = thumbs.last?["url"] as? String {
                return url
            }
            for (_, v) in dict { if let f = lastThumbnailURL(in: v) { return f } }
        } else if let arr = node as? [Any] {
            for v in arr { if let f = lastThumbnailURL(in: v) { return f } }
        }
        return nil
    }

    // MARK: - High-res cover rewrite
    //
    // googleusercontent / ytimg thumbnail URLs carry a size param (=w60-h60-…,
    // =s544-c, or /s120/). Bump it for the big now-playing cover. If no size
    // param is present, the URL is returned unchanged.
    static func highResCoverURL(_ urlString: String?, size: Int = 1200) -> String? {
        guard let s = urlString, !s.isEmpty else { return urlString }
        return s
            .replacingOccurrences(of: "=w\\d+-h\\d+", with: "=w\(size)-h\(size)", options: .regularExpression)
            .replacingOccurrences(of: "=s\\d+",        with: "=s\(size)",          options: .regularExpression)
            .replacingOccurrences(of: "/s\\d+/",       with: "/s\(size)/",         options: .regularExpression)
    }
}
