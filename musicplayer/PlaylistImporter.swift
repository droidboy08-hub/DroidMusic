import Foundation

// MARK: - Source detection

enum PlaylistSource {
    case youtube(id: String)
    case spotifyPlaylist(id: String)
    case spotifyAlbum(id: String)

    static func detect(_ raw: String) throws -> PlaylistSource {
        // Normalise — accept bare IDs, full URLs, and share links
        let str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: str.hasPrefix("http") ? str : "https://\(str)") else {
            throw ImportError.unsupportedURL
        }
        let host = (url.host ?? "").lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // YouTube / YouTube Music (watch links with &list=, playlist links, etc.)
        if host.contains("youtube.com") || host.contains("youtu.be") {
            if let listID = comps?.queryItems?.first(where: { $0.name.lowercased() == "list" })?.value,
               !listID.isEmpty {
                return .youtube(id: listID)
            }
            // Some music.youtube share formats or bare list ids
            if let path = url.pathComponents.last, path.hasPrefix("PL") || path.hasPrefix("OL") || path.hasPrefix("UU") {
                return .youtube(id: path)
            }
        }

        // Spotify
        if host.contains("spotify.com") || host.contains("spotify.link") {
            let parts = url.pathComponents

            if let idx = parts.firstIndex(of: "playlist"),
               parts.indices.contains(idx + 1) {
                return .spotifyPlaylist(id: parts[idx + 1])
            }

            if let idx = parts.firstIndex(of: "album"),
               parts.indices.contains(idx + 1) {
                return .spotifyAlbum(id: parts[idx + 1])
            }

            // spotify.link short links are usually resolved by the web player anyway
        }

        if host.contains("spotify.com") {
            if url.pathComponents.contains("artist") {
                throw ImportError.network("For artists, please copy a specific album link (e.g. open.spotify.com/album/...) instead of the artist page.")
            }
        }

        // Fallback: allow a bare YouTube playlist id if it looks like one
        if str.uppercased().hasPrefix("PL") || str.uppercased().hasPrefix("OL") {
            return .youtube(id: str)
        }

        throw ImportError.unsupportedURL
    }
}

// MARK: - Errors & progress

enum ImportError: LocalizedError {
    case unsupportedURL
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "Only YouTube, YouTube Music, Spotify playlists, and Spotify albums are supported."
        case .network(let msg):
            return msg
        }
    }
}

struct ImportProgress: Equatable {
    var phase: String
    var current: Int
    var total: Int
}

// MARK: - PlaylistImporter

actor PlaylistImporter {

    private let session = URLSession.shared

    // Dedicated faster session for track matching with higher connection limit
    private let matchingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private var ytmContext: [String: Any] = [
        "client": ["clientName": "WEB_REMIX", "clientVersion": "1.20250601.01.00"]
    ]

    // Simple in-memory cache for matched tracks (keyed by normalized title|artist)
    // Avoids re-searching the same song across imports or within large batches
    private var matchCache: [String: TrackMetadata] = [:]

    private func cacheKey(title: String, artist: String) -> String {
        "\(normalise(title))|\(normalise(artist))"
    }

    // Fetch a fresh session context for headers (visitorData + cookies + poToken if available)
    private func currentSessionContext() async -> YouTubeSessionContext? {
        return await YouTubeSession.build()
    }

    private func youTubeHeaders(using ctx: YouTubeSessionContext?) -> [String: String] {
        var h: [String: String] = [
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
            "Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        if let c = ctx {
            h["X-Goog-Visitor-Id"] = c.visitorData
            if let cookie = c.cookieHeader {
                h["Cookie"] = cookie
            }
            if let auth = c.authorizationHeader(origin: "https://music.youtube.com") {
                h["Authorization"] = auth
            }
            if let cv = c.clientVersion, !cv.isEmpty {
                // keep body context up to date when we use it
            }
        }
        return h
    }

    // ── Entry points ──────────────────────────────────────────────────────────

    func importYouTube(
        playlistId: String,
        onProgress: @Sendable @escaping (ImportProgress) -> Void
    ) async throws -> [TrackMetadata] {
        let ctx = await currentSessionContext()
        if let cv = ctx?.clientVersion, !cv.isEmpty {
            ytmContext = ["client": ["clientName": "WEB_REMIX", "clientVersion": cv]]
        }

        let browseId = "VL" + playlistId
        var all: [TrackMetadata] = []
        var seen = Set<String>()
        var token: String? = nil
        var reportedTotal = 0

        repeat {
            let json = try await browseRequest(browseId: browseId, continuation: token, context: ctx)
            let batch = parsePlaylistTracks(json)
            for t in batch {
                guard let vid = t.videoId, seen.insert(vid).inserted else { continue }
                all.append(t)
            }
            token = findContinuationToken(json)

            // Try to get a real total from the response for better progress UI
            if reportedTotal == 0, let tot = extractPlaylistTotal(json) {
                reportedTotal = tot
            }

            let snap = all.count
            let total = max(reportedTotal, snap)
            await MainActor.run {
                onProgress(ImportProgress(phase: "Loading YouTube playlist…", current: snap, total: total))
            }
        } while token != nil

        return all
    }

    private func extractPlaylistTotal(_ json: [String: Any]) -> Int? {
        // Look for common places where playlist header reports track count
        var best: Int? = nil
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let count = (d["itemCount"] as? Int) ?? (d["itemCount"] as? Double).map(Int.init) {
                    if best == nil || count > best! { best = count }
                }
                if let stats = d["stats"] as? [String: Any],
                   let c = stats["numberOfItems"] as? [String: Any],
                   let text = c["text"] as? String,
                   let n = Int(text.filter { $0.isNumber }) {
                    if best == nil || n > best! { best = n }
                }
                for (_, v) in d { walk(v) }
            } else if let arr = node as? [Any] {
                for v in arr { walk(v) }
            }
        }
        walk(json)
        return best
    }

    func importSpotifyPlaylist(
        playlistId: String,
        onProgress: @Sendable @escaping (ImportProgress) -> Void
    ) async throws -> (imported: [TrackMetadata], missed: [String], name: String?, coverURL: String?) {
        await MainActor.run {
            onProgress(ImportProgress(phase: "Reading Spotify playlist…", current: 0, total: 0))
        }

        // No usable Spotify API anymore (403 / Feb-2026 policy) — scrape the
        // web player in a hidden WKWebView instead. See SpotifyWebScraper.
        let scraper    = await SpotifyWebScraper()
        let scraped    = try await scraper.scrape(playlistId: playlistId)
        let spotTracks = scraped.tracks
        let total      = spotTracks.count

        guard total > 0 else {
            throw ImportError.network("Couldn't read any tracks. Make sure the Spotify playlist is public and try again.")
        }

        var imported: [TrackMetadata] = []
        var missed:   [String]        = []

        // Aggressive concurrency for speed (even on small playlists)
        let concurrency = 6
        var index = 0

        while index < spotTracks.count {
            let end = min(index + concurrency, spotTracks.count)
            let batch = Array(spotTracks[index..<end])

            await withTaskGroup(of: (TrackMetadata?, String?).self) { group in
                var gIdx = index
                for st in batch {
                    let currentGIdx = gIdx
                    gIdx += 1
                    group.addTask {
                        await MainActor.run {
                            onProgress(ImportProgress(phase: "Matching tracks on YouTube", current: currentGIdx + 1, total: total))
                        }
                        let match = await self.withTimeout(seconds: 10) {
                            await self.matchOnYouTube(title: st.title, artist: st.artist, durationSec: st.durationSec)
                        }
                        if let m = match {
                            return (m, nil)
                        } else {
                            return (nil, "\(st.title) — \(st.artist)")
                        }
                    }
                }

                for await res in group {
                    if let m = res.0 { imported.append(m) }
                    if let miss = res.1 { missed.append(miss) }
                }
            }

            index = end
            // No sleep for maximum speed
        }

        return (imported, missed, scraped.name, scraped.coverURL)
    }

    func importSpotifyAlbum(
        albumId: String,
        onProgress: @Sendable @escaping (ImportProgress) -> Void
    ) async throws -> (imported: [TrackMetadata], missed: [String], name: String?, coverURL: String?) {
        await MainActor.run {
            onProgress(ImportProgress(phase: "Reading Spotify album…", current: 0, total: 0))
        }

        let scraper = await SpotifyWebScraper()
        let scraped = try await scraper.scrapeAlbum(albumId: albumId)
        let spotTracks = scraped.tracks
        let total = spotTracks.count

        guard total > 0 else {
            throw ImportError.network("Couldn't read any tracks from this album. Make sure the album is public and try again (Spotify web scraping can be flaky).")
        }

        // Fetch session context once (avoid MainActor contention inside the hot loop)
        let ctx = await currentSessionContext()
        if let cv = ctx?.clientVersion, !cv.isEmpty {
            ytmContext = ["client": ["clientName": "WEB_REMIX", "clientVersion": cv]]
        }

        var imported: [TrackMetadata] = []
        var missed: [String] = []

        // Balanced for higher success rate on albums (less aggressive than before to avoid rate limits/misses)
        let concurrency = 4
        var index = 0

        while index < spotTracks.count {
            let end = min(index + concurrency, spotTracks.count)
            let batch = Array(spotTracks[index..<end])

            await withTaskGroup(of: (TrackMetadata?, String?).self) { group in
                var gIdx = index
                for st in batch {
                    let currentGIdx = gIdx
                    gIdx += 1
                    group.addTask {
                        await MainActor.run {
                            onProgress(ImportProgress(phase: "Matching tracks on YouTube", current: currentGIdx + 1, total: total))
                        }
                        // Timeout each match
                        let m = await self.withTimeout(seconds: 15) {
                            await self.matchOnYouTube(title: st.title, artist: st.artist, durationSec: st.durationSec, context: ctx)
                        }
                        if let mm = m {
                            return (mm as TrackMetadata?, nil)
                        } else {
                            return (nil, "\(st.title) — \(st.artist)")
                        }
                    }
                }

                for await res in group {
                    if let m = res.0 { imported.append(m) }
                    if let miss = res.1 { missed.append(miss) }
                }
            }

            index = end

            // Small sleep to be nicer to YouTube and improve match success
            if index < spotTracks.count {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // Final progress
        await MainActor.run {
            onProgress(ImportProgress(phase: "Matching tracks on YouTube", current: total, total: total))
        }

        return (imported, missed, scraped.name, scraped.coverURL)
    }

    // ── YouTube match (also exposed for re-use) ───────────────────────────────

    func matchOnYouTube(title: String, artist: String, durationSec: Double?, context: YouTubeSessionContext? = nil, bestGuess: Bool = false) async -> TrackMetadata? {
        let key = cacheKey(title: title, artist: artist)
        if let cached = matchCache[key] {
            return cached
        }

        let ctx: YouTubeSessionContext?
        if let provided = context {
            ctx = provided
        } else {
            ctx = await currentSessionContext()
        }
        if let cv = ctx?.clientVersion, !cv.isEmpty {
            ytmContext = ["client": ["clientName": "WEB_REMIX", "clientVersion": cv]]
        }

        let query = "\(title) \(artist)"
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/search") else { return nil }

        // First try with session headers (if we have visitorData etc.)
        if let ctx = ctx {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            for (k, v) in youTubeHeaders(using: ctx) {
                req.setValue(v, forHTTPHeaderField: k)
            }

            let body: [String: Any] = [
                "context": ytmContext,
                "query": query,
                "params": "Eg-KAQwIARAOEAQQQQ=="
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            if let (data, response) = try? await matchingSession.data(for: req),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let candidates = MetadataParser.parseSearchItems(json)
                if let best = bestMatch(candidates: candidates, title: title, artist: artist, durationSec: durationSec, strict: !bestGuess) {
                    matchCache[key] = best
                    return best
                }
            }
        }

        // Fallback: simple unauthenticated search (more reliable when poToken is missing)
        if let best = await simpleYouTubeSearchMatch(title: title, artist: artist, durationSec: durationSec, bestGuess: bestGuess) {
            matchCache[key] = best
            return best
        }
        return nil
    }

    // MARK: - Timeout helper (returns nil on timeout)
    private func withTimeout<T>(seconds: Double, _ operation: @escaping () async -> T?) async -> T? {
        do {
            return try await withThrowingTaskGroup(of: T?.self) { group in
                group.addTask {
                    await operation()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    return nil
                }
                let result = try await group.next()
                group.cancelAll()
                return result ?? nil
            }
        } catch {
            return nil
        }
    }

    /// Simple unauthenticated YouTube Music search (used as fallback for matching).
    private func simpleYouTubeSearchMatch(title: String, artist: String, durationSec: Double?, bestGuess: Bool = false) async -> TrackMetadata? {
        let query = "\(title) \(artist)"
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/search") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20250601.01.00"]],
            "query": query,
            "params": "Eg-KAQwIARAOEAQQQQ=="
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await matchingSession.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let candidates = MetadataParser.parseSearchItems(json)
        return bestMatch(candidates: candidates, title: title, artist: artist, durationSec: durationSec, strict: !bestGuess)
    }

    /// Public helper for "import best guess" option
    func bestGuessMatch(title: String, artist: String, durationSec: Double? = nil) async -> TrackMetadata? {
        return await matchOnYouTube(title: title, artist: artist, durationSec: durationSec, bestGuess: true)
    }

    // ── YouTube browse ────────────────────────────────────────────────────────

    private func browseRequest(browseId: String, continuation: String?, context: YouTubeSessionContext? = nil) async throws -> [String: Any] {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/browse") else {
            throw ImportError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        // Apply rich headers (visitor, cookies, auth, UA, origin etc.)
        for (k, v) in youTubeHeaders(using: context) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        var body: [String: Any] = ["context": ytmContext]
        if let cont = continuation { body["continuation"] = cont }
        else                       { body["browseId"]     = browseId }

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ImportError.network("Browse HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.network("Could not parse browse response")
        }
        return json
    }

    private func parsePlaylistTracks(_ json: [String: Any]) -> [TrackMetadata] {
        // Base parse (title, artist, videoId, cover)
        var tracks = MetadataParser.parseSearchItems(json)

        // Merge duration from fixedColumns (playlist-specific field)
        var durMap: [String: Double] = [:]
        collectLeaves(json, key: "musicResponsiveListItemRenderer") { r in
            guard let vid = self.videoIdIn(r) else { return }
            if let dur = self.durationFromFixedCols(r) { durMap[vid] = dur }
        }
        tracks = tracks.map { t in
            guard let vid = t.videoId, let dur = durMap[vid] else { return t }
            return TrackMetadata(title: t.title, artist: t.artist,
                                 durationSeconds: dur,
                                 coverURL: t.coverURL, videoId: vid)
        }
        return tracks
    }

    private func durationFromFixedCols(_ r: [String: Any]) -> Double? {
        guard let fixed = r["fixedColumns"] as? [[String: Any]],
              let col   = fixed.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any],
              let runs  = (col["text"] as? [String: Any])?["runs"] as? [[String: Any]],
              let text  = runs.first?["text"] as? String
        else { return nil }
        return parseDurationText(text)
    }

    private func parseDurationText(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    private func findContinuationToken(_ json: [String: Any]) -> String? {
        var token: String? = nil
        collectLeaves(json, key: "continuationItemRenderer") { r in
            guard token == nil else { return }
            let endpoint = r["continuationEndpoint"] as? [String: Any]
            let command  = endpoint?["continuationCommand"] as? [String: Any]
            token = command?["token"] as? String
        }
        if token != nil { return token }
        // Older shape
        collectLeaves(json, key: "nextContinuationData") { r in
            if token == nil { token = r["continuation"] as? String }
        }
        return token
    }

    // ── Scoring ───────────────────────────────────────────────────────────────

    private func bestMatch(candidates: [TrackMetadata],
                           title: String,
                           artist: String,
                           durationSec: Double?,
                           strict: Bool = true) -> TrackMetadata? {
        let nTitle  = normalise(title)
        let nArtist = normalise(artist)
        var best: (score: Double, track: TrackMetadata)? = nil

        for c in candidates {
            var score = 0.0
            let cTitle  = normalise(c.title)
            let cArtist = normalise(c.artist)

            // Title overlap (Jaccard on word tokens)
            score += tokenOverlap(nTitle, cTitle) * 3.0

            // Artist match
            if !nArtist.isEmpty && (cArtist.contains(nArtist) || nArtist.contains(cArtist)) {
                score += 2.0
            }

            // Duration proximity
            if let target = durationSec, target.isFinite, let candidate = c.durationSeconds, candidate.isFinite {
                let diff = abs(target - candidate)
                if      diff <= 5  { score += 2.5 }
                else if diff <= 15 { score += 1.0 }
                else if diff > 60  { score -= 2.0 }
            }

            let threshold = strict ? 1.0 : 0.1
            guard score > threshold else { continue }
            if best == nil || score > best!.score { best = (score, c) }
        }

        if best == nil && !candidates.isEmpty {
            if strict {
                return nil
            }
            // Best guess mode: pick closest by duration or first
            if let target = durationSec {
                var closest: (diff: Double, track: TrackMetadata)? = nil
                for c in candidates {
                    if let cand = c.durationSeconds {
                        let d = abs(target - cand)
                        if d < 60 && (closest == nil || d < closest!.diff) {
                            closest = (d, c)
                        }
                    }
                }
                if let cl = closest { return cl.track }
            }
            return candidates.first
        }

        return best?.track
    }

    private func normalise(_ s: String) -> String {
        var r = s.lowercased()
        let patterns = [
            "\\(feat[^)]*\\)", "\\[feat[^\\]]*\\]", "\\(ft\\.[^)]*\\)",
            "\\(official[^)]*\\)", "\\[official[^\\]]*\\]",
            "\\(lyrics[^)]*\\)", "\\[lyrics[^\\]]*\\]",
            "\\(audio[^)]*\\)",  "\\[audio[^\\]]*\\]",
            "\\(remaster[^)]*\\)", "\\[remaster[^\\]]*\\]",
            "\\(slowed[^)]*\\)", "\\(sped[^)]*\\)", "\\(reverb[^)]*\\)"
        ]
        for p in patterns {
            r = r.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        r = r.components(separatedBy: .punctuationCharacters).joined(separator: " ")
        r = r.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return r
    }

    private func tokenOverlap(_ a: String, _ b: String) -> Double {
        let setA = Set(a.split(separator: " ").map(String.init))
        let setB = Set(b.split(separator: " ").map(String.init))
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        return Double(setA.intersection(setB).count) / Double(setA.union(setB).count)
    }

    // ── Generic tree-walker (mirrors MetadataParser.collectRenderers) ─────────

    private func collectLeaves(_ node: Any, key: String, _ body: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            if let r = dict[key] as? [String: Any] { body(r) }
            for (_, v) in dict { collectLeaves(v, key: key, body) }
        } else if let arr = node as? [Any] {
            for v in arr { collectLeaves(v, key: key, body) }
        }
    }

    private func videoIdIn(_ node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let vid = (dict["playlistItemData"] as? [String: Any])?["videoId"] as? String { return vid }
            if let we  = dict["watchEndpoint"] as? [String: Any], let vid = we["videoId"] as? String { return vid }
            for (_, v) in dict { if let f = videoIdIn(v) { return f } }
        } else if let arr = node as? [Any] {
            for v in arr { if let f = videoIdIn(v) { return f } }
        }
        return nil
    }
}
