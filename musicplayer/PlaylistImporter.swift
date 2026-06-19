import Foundation

// MARK: - Source detection

enum PlaylistSource {
    case youtube(id: String)
    case spotify(id: String)

    static func detect(_ raw: String) throws -> PlaylistSource {
        // Normalise — accept bare IDs and full URLs
        let str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: str.hasPrefix("http") ? str : "https://\(str)") else {
            throw ImportError.unsupportedURL
        }
        let host = url.host ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // YouTube / YouTube Music
        if host.contains("youtube.com") {
            if let id = comps?.queryItems?.first(where: { $0.name == "list" })?.value {
                return .youtube(id: id)
            }
        }

        // Spotify
        if host.contains("spotify.com") {
            let parts = url.pathComponents            // ["", "playlist", "37i9dQ…"]
            if let idx = parts.firstIndex(of: "playlist"),
               parts.indices.contains(idx + 1) {
                return .spotify(id: parts[idx + 1])
            }
        }

        throw ImportError.unsupportedURL
    }
}

// MARK: - Errors & progress

enum ImportError: LocalizedError {
    case unsupportedURL
    case network(String)
    case spotifyCredentialsMissing

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "Only YouTube and Spotify playlist URLs are supported."
        case .network(let msg):
            return msg
        case .spotifyCredentialsMissing:
            return "Add SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET to Info.plist to import Spotify playlists."
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

    private let ytmContext: [String: Any] = [
        "client": ["clientName": "WEB_REMIX", "clientVersion": "1.20250519.03.01"]
    ]

    // ── Entry points ──────────────────────────────────────────────────────────

    func importYouTube(
        playlistId: String,
        onProgress: @Sendable @escaping (ImportProgress) -> Void
    ) async throws -> [TrackMetadata] {
        let browseId = "VL" + playlistId
        var all: [TrackMetadata] = []
        var seen = Set<String>()
        var token: String? = nil

        repeat {
            let json = try await browseRequest(browseId: browseId, continuation: token)
            let batch = parsePlaylistTracks(json)
            for t in batch {
                guard let vid = t.videoId, seen.insert(vid).inserted else { continue }
                all.append(t)
            }
            token = findContinuationToken(json)
            let snap = all.count
            await MainActor.run { onProgress(ImportProgress(phase: "Loading…", current: snap, total: snap)) }
        } while token != nil

        return all
    }

    func importSpotify(
        playlistId: String,
        onProgress: @Sendable @escaping (ImportProgress) -> Void
    ) async throws -> (imported: [TrackMetadata], missed: [String]) {
        guard
            let clientId     = Bundle.main.object(forInfoDictionaryKey: "SPOTIFY_CLIENT_ID")     as? String, !clientId.isEmpty,
            let clientSecret = Bundle.main.object(forInfoDictionaryKey: "SPOTIFY_CLIENT_SECRET") as? String, !clientSecret.isEmpty
        else { throw ImportError.spotifyCredentialsMissing }

        let token      = try await spotifyToken(clientId: clientId, secret: clientSecret)
        let spotTracks = try await fetchSpotifyTracks(playlistId: playlistId, token: token)
        let total      = spotTracks.count

        var imported: [TrackMetadata] = []
        var missed:   [String]        = []

        // Process in batches of 5 (rate-limit courtesy)
        for (i, st) in spotTracks.enumerated() {
            let idx = i
            await MainActor.run {
                onProgress(ImportProgress(phase: "Matching tracks on YouTube", current: idx + 1, total: total))
            }
            if let match = await matchOnYouTube(title: st.title, artist: st.artist, durationSec: st.durationSec) {
                imported.append(match)
            } else {
                missed.append("\(st.title) — \(st.artist)")
            }
            if (i + 1) % 5 == 0 {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms every 5 tracks
            }
        }
        return (imported, missed)
    }

    // ── YouTube match (also exposed for re-use) ───────────────────────────────

    func matchOnYouTube(title: String, artist: String, durationSec: Double?) async -> TrackMetadata? {
        let query = "\(title) \(artist)"
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/search") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "context": ytmContext,
            "query":   query,
            "params":  "Eg-KAQwIARAOEAQQQQ==" // Songs-only filter
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await session.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let candidates = MetadataParser.parseSearchItems(json)
        return bestMatch(candidates: candidates, title: title, artist: artist, durationSec: durationSec)
    }

    // ── YouTube browse ────────────────────────────────────────────────────────

    private func browseRequest(browseId: String, continuation: String?) async throws -> [String: Any] {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/browse") else {
            throw ImportError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

    // ── Spotify helpers ───────────────────────────────────────────────────────

    private struct SpotifyTrack { let title: String; let artist: String; let durationSec: Double }

    private func spotifyToken(clientId: String, secret: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let creds = Data("\(clientId):\(secret)".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        let (data, _) = try await session.data(for: req)
        struct R: Decodable { let access_token: String }
        if let decoded = try? JSONDecoder().decode(R.self, from: data) { return decoded.access_token }
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw ImportError.network("Spotify auth failed: \(raw.prefix(200))")
    }

    private func fetchSpotifyTracks(playlistId: String, token: String) async throws -> [SpotifyTrack] {
        var result: [SpotifyTrack] = []
        var offset = 0
        let limit  = 100

        while true {
            var comps = URLComponents(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks")!
            comps.queryItems = [
                URLQueryItem(name: "limit",  value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "fields", value: "next,items(track(name,duration_ms,artists(name)))")
            ]
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await session.data(for: req)

            guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else { throw ImportError.network("Could not parse Spotify tracks") }

            for item in items {
                guard let track      = item["track"]    as? [String: Any],
                      let name       = track["name"]    as? String,
                      let durMs      = track["duration_ms"] as? Int,
                      let artists    = track["artists"] as? [[String: Any]],
                      let artist     = artists.first?["name"] as? String
                else { continue }
                result.append(SpotifyTrack(title: name, artist: artist,
                                           durationSec: Double(durMs) / 1000))
            }

            if (json["next"] as? String) == nil { break }
            offset += limit
        }
        return result
    }

    // ── Scoring ───────────────────────────────────────────────────────────────

    private func bestMatch(candidates: [TrackMetadata],
                           title: String,
                           artist: String,
                           durationSec: Double?) -> TrackMetadata? {
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
            if let target = durationSec, let candidate = c.durationSeconds {
                let diff = abs(target - candidate)
                if      diff <= 5  { score += 2.5 }
                else if diff <= 15 { score += 1.0 }
                else if diff > 60  { score -= 3.5 } // loop / mix / sped-up reject
            }

            guard score > 2.0 else { continue } // minimum match quality
            if best == nil || score > best!.score { best = (score, c) }
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
