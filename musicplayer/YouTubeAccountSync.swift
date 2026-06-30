import Foundation
import WebKit
import CommonCrypto

// MARK: - YouTube Account Sync
//
// Uses cookies from WKWebsiteDataStore (stored by the YouTube login WebView) to
// fetch the signed-in account's display name and profile picture.
//
// Playlist sync has been intentionally removed — the authenticated session and
// cookie/SAPISIDHASH infrastructure here will be reused for track recommendations.
//
// Auth mechanism: SAPISIDHASH (SHA1 of timestamp + SAPISID + origin) sent as
// Authorization header — required for InnerTube to accept cookie-based auth.

actor YouTubeAccountSync {

    static let shared = YouTubeAccountSync()

    struct CookieInfo {
        let header:      String
        let sapisid:     String?   // SAPISID or __Secure-3PAPISID — needed for SAPISIDHASH
        let visitorData: String?   // X-Goog-Visitor-Id — required for authenticated InnerTube responses
    }

    private let ytmContext: [String: Any] = [
        "client": [
            "clientName":    "WEB_REMIX",
            "clientVersion": "1.20250519.03.01",
            "hl":            "en",
            "gl":            "US"
        ]
    ]

    // MARK: - Entry point

    func sync(player: PlayerState) async {
        print("🎵 [Sync] Starting account sync...")
        guard let info = await buildCookieInfo() else {
            print("🎵 [Sync] ❌ No YouTube cookies found — user not logged in?")
            return
        }
        print("🎵 [Sync] ✅ Cookies ready — header \(info.header.count) chars, sapisid: \(info.sapisid != nil ? "✅" : "❌ MISSING")")

        let accountInfo = await fetchAccountInfo(cookieInfo: info)

        await MainActor.run {
            if let accountInfo {
                player.ytDisplayName     = accountInfo.name
                player.ytProfileImageURL = accountInfo.imageURL
                player.isYouTubeLoggedIn = true
                print("🎵 [Sync] ✅ Signed in as \(accountInfo.name)")
            }
        }
    }

    // MARK: - Account info

    private struct AccountInfo { let name: String; let imageURL: String? }

    private func fetchAccountInfo(cookieInfo: CookieInfo) async -> AccountInfo? {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/browse") else { return nil }
        var req = makeRequest(url: url, cookieInfo: cookieInfo, origin: "https://music.youtube.com")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context":  ytmContext,
            "browseId": "FEmusic_home"
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let name     = findAccountName(json) ?? "YouTube User"
        let imageURL = findProfileImageURL(json)
        return AccountInfo(name: name, imageURL: imageURL)
    }

    // MARK: - Home recommendations

    struct YTMShelf {
        let title:  String
        let tracks: [Track]
    }

    /// Fetches the YTM home page and returns named shelves of playable tracks.
    /// Requires the user to be signed in (cookieInfo must have valid SAPISID).
    func fetchHomeRecommendations() async -> [YTMShelf] {
        guard let cookieInfo = await buildCookieInfo() else { return [] }
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/browse") else { return [] }
        var req = makeRequest(url: url, cookieInfo: cookieInfo, origin: "https://music.youtube.com")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context":  ytmContext,
            "browseId": "FEmusic_home"
        ])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        print("🎵 [YTM] Home response \(data.count) bytes")

        var shelves: [YTMShelf] = []

        // Walk every musicCarouselShelfRenderer in the response
        collectLeaves(json, key: "musicCarouselShelfRenderer") { shelf in
            if let s = self.parseShelf(shelf) { shelves.append(s) }
        }
        // Some layouts use musicImmersiveCarouselShelfRenderer for the top shelf
        collectLeaves(json, key: "musicImmersiveCarouselShelfRenderer") { shelf in
            if let s = self.parseShelf(shelf) { shelves.insert(s, at: 0) }
        }

        print("🎵 [YTM] Parsed \(shelves.count) shelves, tracks: \(shelves.map { "\($0.title)=\($0.tracks.count)" })")
        return shelves
    }

    private func parseShelf(_ shelf: [String: Any]) -> YTMShelf? {
        // Shelf title — try basic header first, then immersive header
        let basicHeader = (shelf["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
        let titleRuns   = (basicHeader?["title"] as? [String: Any])?["runs"] as? [[String: Any]]
        let title       = titleRuns?.compactMap { $0["text"] as? String }.joined() ?? "Recommended"

        let contents = shelf["contents"] as? [[String: Any]] ?? []
        var tracks: [Track] = []

        for item in contents {
            if let r = item["musicTwoRowItemRenderer"] as? [String: Any],
               let t = trackFromTwoRowItem(r) { tracks.append(t) }
            if let r = item["musicResponsiveListItemRenderer"] as? [String: Any],
               let t = trackFromResponsiveItem(r) { tracks.append(t) }
        }

        guard !tracks.isEmpty else { return nil }
        return YTMShelf(title: title, tracks: tracks)
    }

    private func trackFromTwoRowItem(_ r: [String: Any]) -> Track? {
        // Only playable tracks have watchEndpoint (albums/playlists have browseEndpoint)
        let navEp   = r["navigationEndpoint"] as? [String: Any]
        let watchEp = navEp?["watchEndpoint"] as? [String: Any]
        guard let videoId = watchEp?["videoId"] as? String else { return nil }

        let titleRuns = (r["title"] as? [String: Any])?["runs"] as? [[String: Any]]
        let title     = titleRuns?.compactMap { $0["text"] as? String }.joined() ?? ""
        guard !title.isEmpty else { return nil }

        // Subtitle runs: ["Song", " • ", "Artist"] — take text after the bullet
        let subRuns = (r["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        let subTexts = subRuns.compactMap { $0["text"] as? String }
        let artist: String
        if let dotIdx = subTexts.firstIndex(where: { $0.contains("•") }) {
            artist = subTexts[(dotIdx + 1)...].joined().trimmingCharacters(in: .whitespaces)
        } else {
            artist = subTexts.filter { !$0.contains("•") }.last ?? ""
        }

        let thumbs  = ((r["thumbnailRenderer"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])
            .flatMap { ($0["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] }
        let thumbURL = thumbs?.last?["url"] as? String

        return Track(title: title, artist: artist, videoId: videoId, thumbnailURL: thumbURL)
    }

    private func trackFromResponsiveItem(_ r: [String: Any]) -> Track? {
        // videoId lives in the overlay play button or the nav endpoint
        let overlay  = (r["overlay"] as? [String: Any])?["musicItemThumbnailOverlayRenderer"] as? [String: Any]
        let playNav  = ((overlay?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any])?["playNavigationEndpoint"] as? [String: Any]
        let videoId  = ((playNav ?? (r["navigationEndpoint"] as? [String: Any]))?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
        guard let videoId else { return nil }

        let flex  = r["flexColumns"] as? [[String: Any]] ?? []
        let col0  = flex.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        let title = ((col0?["text"] as? [String: Any])?["runs"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined() ?? ""
        guard !title.isEmpty else { return nil }

        let col1   = (flex.count > 1 ? flex[1] : nil)?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        let artist = ((col1?["text"] as? [String: Any])?["runs"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined() ?? ""

        let thumbs   = ((r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])
            .flatMap { ($0["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] }
        let thumbURL = thumbs?.last?["url"] as? String

        return Track(title: title, artist: artist, videoId: videoId, thumbnailURL: thumbURL)
    }

    // MARK: - SAPISIDHASH (required for authenticated InnerTube requests)

    /// Format: SAPISIDHASH <timestamp>_<SHA1("<timestamp> <sapisid> <origin>")>
    private func sapisidhash(sapisid: String, origin: String) -> String {
        let ts   = Int(Date().timeIntervalSince1970)
        let msg  = "\(ts) \(sapisid) \(origin)"
        let data = Data(msg.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }

    // MARK: - Helpers

    func buildCookieInfo() async -> CookieInfo? {
        let visitorData = await SessionBootstrap.shared.visitorDataValue()

        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
            }
        }

        let relevant = cookies.filter {
            $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
        }
        guard !relevant.isEmpty else { return nil }

        let header  = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let sapisid = relevant.first(where: { $0.name == "__Secure-3PAPISID" })?.value
                    ?? relevant.first(where: { $0.name == "SAPISID" })?.value

        return CookieInfo(header: header, sapisid: sapisid, visitorData: visitorData)
    }

    func makeRequest(url: URL, cookieInfo: CookieInfo, origin: String,
                     clientName: String = "67",
                     clientVersion: String = "1.20250519.03.01",
                     userAgent: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(origin,             forHTTPHeaderField: "Origin")
        req.setValue(origin + "/",       forHTTPHeaderField: "Referer")
        req.setValue(cookieInfo.header,  forHTTPHeaderField: "Cookie")
        req.setValue(
            userAgent ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue(clientName,    forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("0",           forHTTPHeaderField: "X-Goog-AuthUser")
        if let vd = cookieInfo.visitorData {
            req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if let sapisid = cookieInfo.sapisid {
            req.setValue(YouTubeSession.sapisidHash(sapisid: sapisid, origin: origin), forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func findAccountName(_ node: Any) -> String? {
        if let dict = node as? [String: Any] {
            for key in ["accountName", "displayName", "title"] {
                if let val = dict[key] {
                    if let s = val as? String, !s.isEmpty { return s }
                    if let inner = val as? [String: Any],
                       let runs  = inner["runs"] as? [[String: Any]],
                       let text  = runs.first?["text"] as? String, !text.isEmpty { return text }
                }
            }
            for (_, v) in dict { if let f = findAccountName(v) { return f } }
        } else if let arr = node as? [Any] { for v in arr { if let f = findAccountName(v) { return f } } }
        return nil
    }

    private func findProfileImageURL(_ node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let thumbs = dict["thumbnails"] as? [[String: Any]] {
                let urls = thumbs.compactMap { $0["url"] as? String }
                if let p = urls.first(where: { $0.contains("googleusercontent") || $0.contains("lh3.google") }) { return p }
                if let l = urls.last { return l }
            }
            for (_, v) in dict { if let f = findProfileImageURL(v) { return f } }
        } else if let arr = node as? [Any] { for v in arr { if let f = findProfileImageURL(v) { return f } } }
        return nil
    }

    private func collectLeaves(_ node: Any, key: String, _ body: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            if let r = dict[key] as? [String: Any] { body(r) }
            for (_, v) in dict { collectLeaves(v, key: key, body) }
        } else if let arr = node as? [Any] {
            for v in arr { collectLeaves(v, key: key, body) }
        }
    }
}
