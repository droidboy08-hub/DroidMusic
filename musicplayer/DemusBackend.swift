import Foundation
import Observation

// MARK: - Stream resolution types
//
// Dual-path: MWEB itag 18 (progressive H.264 + AAC, ratebypass) is primary —
// AVPlayer plays it directly and the video track drives the now-playing sheet.
// IOS itag 140 (AAC audio-only, needs chunked loader) is the fallback for
// videos that don't expose a direct itag-18 url.
struct Resolved {
    let url: URL
    let itag: Int
    let hasVideo: Bool            // true for itag 18 (muxed)
    let needsChunkedLoader: Bool  // true when ratebypass=yes is absent
    let durationSeconds: Double
    let userAgent: String         // UA of the client that minted the url (media GET must match it)
    var metadata: TrackMetadata? = nil   // from /player videoDetails (reused, no extra call)
}

enum PlayerError: Error {
    case notPlayable(String)   // age / region / login wall
    case noStream              // playable but no usable progressive/audio url
    case badResponse
}

// User-selectable search backend (Settings). rawValue is the segmented-control label.
enum SearchSource: String, CaseIterable, Codable {
    case youtubeMusic = "YT Music"   // WEB_REMIX InnerTube: no key, clean song metadata
    case dataAPI      = "YouTube API" // official Data API v3: needs key, ~100 searches/day
}

// Client identities. The /player call AND the media GET must use the SAME
// User-Agent, or googlevideo returns 403 (URLs are bound to the c= client + UA).
enum YTClient {
    nonisolated static let iosUserAgent = "com.google.ios.youtube/20.25.4 (iPhone17,1; U; CPU iOS 18_5 like Mac OS X)"
    nonisolated static let mwebUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    // ANDROID_VR returns pre-signed direct URLs (incl. progressive itag 18 with
    // ratebypass) and typically needs no po_token — our best shot at video.
    nonisolated static let androidVRUserAgent = "com.google.android.apps.youtube.vr.oculus/1.61.43 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
}

// MARK: - Demus Network Layer
actor DemusNetwork {
    static let shared = DemusNetwork()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config)
    }

    // MARK: - Top-level resolve
    //
    // Goal order: a DIRECT itag 18 (video, unthrottled) from any client → else
    // any audio stream (itag 140, throttled but plays). Native clients (IOS,
    // ANDROID_VR) give pre-signed urls; MWEB only ciphers itag 18.
    func resolve(
        videoId: String,
        visitorData: String,
        quality: StreamingQuality
    ) async throws -> Resolved {
        func log(_ tag: String, _ r: Resolved) {
            print("🟢 [Resolve] \(tag) itag=\(r.itag) hasVideo=\(r.hasVideo) needsLoader=\(r.needsChunkedLoader) dur=\(Int(r.durationSeconds))s")
        }

        // 1) MWEB progressive itag 18 (usually cipher-only → nil).
        do {
            if let r = try await resolveMWEB(videoId: videoId, visitorData: visitorData) { log("MWEB", r); return r }
        } catch { print("🟡 [MWEB] request threw: \(error.localizedDescription) → fallback") }

        // 2) Native clients. Prefer whichever yields VIDEO; remember audio as backup.
        let ios = try? await resolveIOS(videoId: videoId, visitorData: visitorData, quality: quality)
        if let ios, ios.hasVideo { log("IOS", ios); return ios }

        let vr = try? await resolveAndroidVR(videoId: videoId, visitorData: visitorData, quality: quality)
        if let vr, vr.hasVideo { log("ANDROID_VR", vr); return vr }

        // 3) No video anywhere → audio fallback (IOS preferred, then VR).
        if let ios { log("IOS", ios); return ios }
        if let vr { log("ANDROID_VR", vr); return vr }

        // 4) Surface the IOS playability reason to the UI.
        return try await resolveIOSStrict(videoId: videoId, visitorData: visitorData, quality: quality)
    }

    // MARK: - MWEB /player (progressive itag 18, muxed H.264 + AAC, ratebypass=yes)
    //
    // Returns nil when MWEB has no progressive itag-18 direct url (signatureCipher
    // only, or missing) — caller falls back to IOS itag 140.
    func resolveMWEB(videoId: String, visitorData: String) async throws -> Resolved? {
        let mwebVersion = "2.20260529.01.00"
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "MWEB",
                    "clientVersion": mwebVersion,
                    "hl": "en", "gl": "US",
                    "visitorData": visitorData,
                    "userAgent": YTClient.mwebUserAgent
                ]
            ],
            "videoId": videoId,
            "racyCheckOk": true,
            "contentCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://m.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue(YTClient.mwebUserAgent, forHTTPHeaderField: "User-Agent")
        // Web-based InnerTube clients (MWEB = client 2) often need these or the
        // /player response comes back without full `streamingData`. The native
        // IOS client doesn't require them, which is why itag 140 still resolved.
        request.setValue("2", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(mwebVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://m.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("🟡 [MWEB] HTTP \(code) or non-JSON body → fallback")
            return nil
        }

        let status = nav(json, "playabilityStatus", "status") as? String ?? "?"
        guard status == "OK" else {
            let reason = nav(json, "playabilityStatus", "reason") as? String ?? "-"
            print("🟡 [MWEB] playabilityStatus=\(status) (\(reason)) → fallback")
            return nil
        }
        guard let sd = json["streamingData"] as? [String: Any] else {
            print("🟡 [MWEB] no streamingData → fallback")
            return nil
        }

        // Progressive formats hold itag 18 (muxed). Must have a DIRECT url (not cipher).
        let progressive = (sd["formats"] as? [[String: Any]]) ?? []
        let itags = progressive.compactMap { $0["itag"] as? Int }
        guard let f18 = progressive.first(where: { ($0["itag"] as? Int) == 18 }) else {
            print("🟡 [MWEB] no itag 18 in progressive formats (have \(itags)) → fallback")
            return nil
        }
        guard let urlStr = f18["url"] as? String, let url = URL(string: urlStr) else {
            let cipher = (f18["signatureCipher"] ?? f18["cipher"]) != nil
            print("🟡 [MWEB] itag 18 present but \(cipher ? "signatureCipher-only (no direct url)" : "no url") → fallback")
            return nil
        }

        let rb = urlStr.contains("ratebypass=yes")
        let dur = videoDuration(json, fallbackMs: f18["approxDurationMs"] as? String)
        print("🟢 [MWEB] itag 18 direct url acquired (ratebypass=\(rb))")
        return Resolved(url: url, itag: 18, hasVideo: true,
                        needsChunkedLoader: !rb, durationSeconds: dur,
                        userAgent: YTClient.mwebUserAgent,
                        metadata: MetadataParser.parsePlayerResponse(json))
    }

    // MARK: - IOS /player (itag 140 audio-only fallback)
    //
    // Returns nil when no direct audio url is available. `resolveIOSStrict`
    // throws the playability reason for surfacing in the UI.
    func resolveIOS(videoId: String, visitorData: String, quality: StreamingQuality) async throws -> Resolved? {
        do {
            return try await resolveIOSStrict(
                videoId: videoId,
                visitorData: visitorData,
                quality: quality
            )
        }
        catch PlayerError.noStream { return nil }
        catch { throw error }   // notPlayable / badResponse propagate
    }

    private func resolveIOSStrict(
        videoId: String,
        visitorData: String,
        quality: StreamingQuality
    ) async throws -> Resolved {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw PlayerError.badResponse
        }
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "20.25.4",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone17,1",
                    "userAgent": YTClient.iosUserAgent,
                    "osName": "iPhone",
                    "osVersion": "18.5.0.22F76",
                    "visitorData": visitorData,
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "videoId": videoId,
            "racyCheckOk": true,
            "contentCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue(YTClient.iosUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlayerError.badResponse
        }

        let status = nav(json, "playabilityStatus", "status") as? String ?? "?"
        guard status == "OK" else {
            let reason = nav(json, "playabilityStatus", "reason") as? String
                ?? nav(json, "playabilityStatus", "errorScreen", "playerErrorMessageRenderer", "reason", "simpleText") as? String
                ?? status
            print("🔴 [Player] not playable: \(status) — \(reason)")
            throw PlayerError.notPlayable(reason)
        }
        guard let r = parseNative(
            json,
            ua: YTClient.iosUserAgent,
            label: "IOS",
            quality: quality
        ) else {
            print("🔴 [Player] no direct stream for \(videoId)")
            throw PlayerError.noStream
        }
        return r
    }

    // Shared native-client stream picker. Prefers a DIRECT progressive itag 18
    // (video; unthrottled when it carries ratebypass) → else adaptive audio
    // (itag 140 → 139 → any audio with a direct url). nil if nothing direct.
    private func parseNative(
        _ json: [String: Any],
        ua: String,
        label: String,
        quality: StreamingQuality
    ) -> Resolved? {
        let sd = json["streamingData"] as? [String: Any] ?? [:]
        let progressive = (sd["formats"] as? [[String: Any]]) ?? []
        let adaptive = (sd["adaptiveFormats"] as? [[String: Any]]) ?? []
        let meta = MetadataParser.parsePlayerResponse(json)   // reuse videoDetails, no extra call
        print("🔎 [\(label)] formats=\(progressive.compactMap { $0["itag"] as? Int }) adaptive=\(adaptive.compactMap { $0["itag"] as? Int })")

        if let f18 = progressive.first(where: { ($0["itag"] as? Int) == 18 }),
           let s = f18["url"] as? String, let url = URL(string: s) {
            let rb = s.contains("ratebypass=yes")
            print("🟢 [\(label)] itag 18 direct url (ratebypass=\(rb)) → video")
            return Resolved(url: url, itag: 18, hasVideo: true, needsChunkedLoader: !rb,
                            durationSeconds: videoDuration(json, fallbackMs: f18["approxDurationMs"] as? String),
                            userAgent: ua, metadata: meta)
        }
        let audioFormats = adaptive.filter {
            ($0["mimeType"] as? String)?.hasPrefix("audio") == true && $0["url"] != nil
        }
        func audio(_ itag: Int) -> [String: Any]? {
            audioFormats.first { ($0["itag"] as? Int) == itag }
        }
        let selectedAudio: [String: Any]?
        switch quality {
        case .low:
            selectedAudio = audio(139)
                ?? audioFormats.min { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }
        case .normal:
            selectedAudio = audio(140) ?? audio(139) ?? audioFormats.first
        case .high:
            selectedAudio = audioFormats.max {
                ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0)
            } ?? audio(140) ?? audio(139)
        }
        guard let f = selectedAudio,
              let s = f["url"] as? String, let url = URL(string: s) else { return nil }
        let rb = s.contains("ratebypass=yes")
        return Resolved(url: url, itag: (f["itag"] as? Int) ?? 140, hasVideo: false, needsChunkedLoader: !rb,
                        durationSeconds: videoDuration(json, fallbackMs: f["approxDurationMs"] as? String),
                        userAgent: ua, metadata: meta)
    }

    // MARK: - ANDROID_VR /player (native; best chance at direct itag 18 + ratebypass)
    func resolveAndroidVR(
        videoId: String,
        visitorData: String,
        quality: StreamingQuality
    ) async throws -> Resolved? {
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID_VR",
                    "clientVersion": "1.61.43",
                    "deviceMake": "Oculus",
                    "deviceModel": "Quest 3",
                    "osName": "Android",
                    "osVersion": "12L",
                    "androidSdkVersion": 32,
                    "userAgent": YTClient.androidVRUserAgent,
                    "visitorData": visitorData,
                    "hl": "en", "gl": "US"
                ]
            ],
            "videoId": videoId,
            "racyCheckOk": true,
            "contentCheckOk": true
        ]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue(YTClient.androidVRUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("🟡 [ANDROID_VR] HTTP \(code) or non-JSON → fallback")
            return nil
        }
        let status = nav(json, "playabilityStatus", "status") as? String ?? "?"
        guard status == "OK" else {
            print("🟡 [ANDROID_VR] playabilityStatus=\(status) → fallback")
            return nil
        }
        return parseNative(
            json,
            ua: YTClient.androidVRUserAgent,
            label: "ANDROID_VR",
            quality: quality
        )
    }

    private func videoDuration(_ json: [String: Any], fallbackMs: String?) -> Double {
        if let vd = json["videoDetails"] as? [String: Any],
           let s = vd["lengthSeconds"] as? String, let n = Double(s) { return n }
        if let s = fallbackMs, let n = Double(s) { return n / 1000.0 }
        return 0
    }

    // DIAGNOSTIC: fetch the stream URL with different User-Agents to find which
    // (if any) the googlevideo server accepts.
    func probe(_ url: URL) async {
        async let ios = status(url, ua: YTClient.iosUserAgent, label: "IOS-UA")
        async let mweb = status(url, ua: YTClient.mwebUserAgent, label: "MWEB-UA")
        async let acm = status(url, ua: "AppleCoreMedia/1.0.0.22F76 (iPhone; U; CPU OS 18_5 like Mac OS X)", label: "AppleCoreMedia-UA")
        async let none = status(url, ua: nil, label: "no-UA")
        _ = await (ios, mweb, acm, none)
    }

    private func status(_ url: URL, ua: String?, label: String) async {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        if let ua { r.setValue(ua, forHTTPHeaderField: "User-Agent") }
        do {
            let (data, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("🧪 [Probe \(label)] status=\(code) bytes=\(data.count)")
        } catch {
            print("🧪 [Probe \(label)] error=\(error.localizedDescription)")
        }
    }

    // MARK: - Search (two user-selectable backends; see SearchSource)
    func search(query: String, source: SearchSource) async throws -> [Track] {
        switch source {
        case .youtubeMusic: return try await searchYouTubeMusic(query: query)
        case .dataAPI:      return try await searchDataAPI(query: query)
        }
    }

    // MARK: YouTube Music (WEB_REMIX InnerTube) — no key, structured song results
    private func searchYouTubeMusic(query: String) async throws -> [Track] {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/search") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20250519.03.01"]],
            "query": query,
            "params": "Eg-KAQwIARAOEAQQQQ=="  // Songs-only filter
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return MetadataParser.parseSearchItems(json).map { $0.asTrack() }
    }

    // MARK: YouTube Data API v3 (search.list) — official, needs key, ~100 searches/day
    enum SearchError: LocalizedError {
        case missingAPIKey, quota, http(Int)
        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "Add a YouTube Data API key in Info.plist (YOUTUBE_API_KEY) to search."
            case .quota:         return "YouTube search quota reached for today. Try again tomorrow."
            case .http(let c):   return "Search failed (HTTP \(c))."
            }
        }
    }

    private struct YTSearchResponse: Decodable {
        struct Item: Decodable {
            struct ID: Decodable { let videoId: String? }
            struct Snippet: Decodable {
                struct Thumb: Decodable { let url: String }
                struct Thumbs: Decodable { let `default`: Thumb?; let medium: Thumb?; let high: Thumb? }
                let title: String
                let channelTitle: String
                let thumbnails: Thumbs
            }
            let id: ID
            let snippet: Snippet
        }
        let items: [Item]
    }

    nonisolated static var apiKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "YOUTUBE_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func searchDataAPI(query: String) async throws -> [Track] {
        let key = Self.apiKey
        guard !key.isEmpty else { throw SearchError.missingAPIKey }

        var comps = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        comps.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoCategoryId", value: "10"),   // Music
            URLQueryItem(name: "maxResults", value: "25"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = comps.url else { throw URLError(.badURL) }

        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            if code == 403 { throw SearchError.quota }      // quotaExceeded / keyInvalid
            throw SearchError.http(code)
        }

        let decoded = try JSONDecoder().decode(YTSearchResponse.self, from: data)
        return decoded.items.compactMap { item in
            guard let videoId = item.id.videoId else { return nil }
            let s = item.snippet
            let thumb = s.thumbnails.high?.url ?? s.thumbnails.medium?.url ?? s.thumbnails.default?.url
            return Track(title: Self.decodeHTMLEntities(s.title),
                         artist: Self.decodeHTMLEntities(s.channelTitle),
                         videoId: videoId,
                         thumbnailURL: thumb)
        }
    }

    /// The Data API returns titles with HTML entities (&amp;, &#39;, …). Decode the common ones.
    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
    }

    private func nav(_ dict: [String: Any], _ keys: Any...) -> Any? {
        var current: Any = dict
        for key in keys {
            if let k = key as? String, let d = current as? [String: Any] {
                guard let next = d[k] else { return nil }
                current = next
            } else if let k = key as? Int, let a = current as? [Any], a.indices.contains(k) {
                current = a[k]
            } else {
                return nil
            }
        }
        return current
    }
}

// MARK: - Demus Song Queue Engine
@MainActor
@Observable
final class SongQueue {
    static let shared = SongQueue()
    
    private(set) var playingSong: Track?
    private(set) var history: [Track] = []
    private(set) var nextSongIds: [Track] = []
    private(set) var originalSongIds: [Track] = []
    
    var isShuffle = false {
        didSet {
            if isShuffle {
                nextSongIds = originalSongIds
                    .filter { $0.id != playingSong?.id }
                    .shuffled()
            } else if let playingSong,
                      let currentIndex = originalSongIds.firstIndex(where: { $0.id == playingSong.id }) {
                nextSongIds = Array(originalSongIds.suffix(from: currentIndex).dropFirst())
            } else {
                nextSongIds = originalSongIds
            }
        }
    }
    
    var repeatMode: RepeatMode = .off
    enum RepeatMode { case off, all, one }
    
    private init() {}
    
    func play(track: Track, queue: [Track]? = nil) {
        if let q = queue {
            var seen = Set<UUID>()
            originalSongIds = q.filter { song in
                song.videoId != nil && seen.insert(song.id).inserted
            }
            if isShuffle {
                history.removeAll()
                nextSongIds = originalSongIds
                    .filter { $0.id != track.id }
                    .shuffled()
            } else {
                if let idx = originalSongIds.firstIndex(where: { $0.id == track.id }) {
                    history = Array(originalSongIds.prefix(upTo: idx))
                    nextSongIds = Array(originalSongIds.suffix(from: idx).dropFirst())
                } else {
                    history.removeAll()
                    nextSongIds = []
                }
            }
        } else if originalSongIds.isEmpty {
            originalSongIds = [track]
            nextSongIds = []
        }
        setPlaying(track, recordCurrent: queue == nil)
    }
    
    private func setPlaying(_ track: Track, recordCurrent: Bool = true) {
        if recordCurrent, let p = playingSong, p.id != track.id {
            history.append(p)
        }
        playingSong = track
        MusicPlayer.shared.play(track: track)
        MusicPlayer.shared.updateNowPlaying(track: track)
    }
    
    @discardableResult
    func next(automatic: Bool = false) -> Bool {
        if automatic, repeatMode == .one, let p = playingSong {
            setPlaying(p)
            return true
        }
        
        if !nextSongIds.isEmpty {
            let n = nextSongIds.removeFirst()
            setPlaying(n)
            return true
        }
        
        if repeatMode == .all && !originalSongIds.isEmpty {
            let restartQueue = originalSongIds.filter { $0.id != playingSong?.id }
            nextSongIds = isShuffle ? restartQueue.shuffled() : restartQueue
            if nextSongIds.isEmpty, let playingSong {
                nextSongIds = [playingSong]
            }
            let n = nextSongIds.removeFirst()
            setPlaying(n)
            return true
        }
        
        return false
    }
    
    func previous() {
        if !history.isEmpty {
            if let p = playingSong {
                nextSongIds.insert(p, at: 0)
            }
            let prev = history.removeLast()
            playingSong = prev
            MusicPlayer.shared.play(track: prev)
            MusicPlayer.shared.updateNowPlaying(track: prev)
        } else {
            MusicPlayer.shared.seek(to: 0)
        }
    }
    
    /// Play this track immediately after the current one. If nothing is
    /// playing, start it now.
    func playNext(_ track: Track) {
        guard track.videoId != nil else { return }
        guard playingSong != nil else { play(track: track); return }
        nextSongIds.removeAll { $0.id == track.id }
        nextSongIds.insert(track, at: 0)
        if !originalSongIds.contains(where: { $0.id == track.id }) {
            originalSongIds.append(track)
        }
    }

    /// Append this track to the end of the up-next queue. If nothing is
    /// playing, start it now.
    func addToQueue(_ track: Track) {
        guard track.videoId != nil else { return }
        guard playingSong != nil else { play(track: track); return }
        guard !nextSongIds.contains(where: { $0.id == track.id }) else { return }
        nextSongIds.append(track)
        if !originalSongIds.contains(where: { $0.id == track.id }) {
            originalSongIds.append(track)
        }
    }

    func reset() {
        playingSong = nil
        history.removeAll()
        nextSongIds.removeAll()
        originalSongIds.removeAll()
        MusicPlayer.shared.stop()
    }
}
