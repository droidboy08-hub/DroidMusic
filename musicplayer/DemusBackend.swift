import Foundation
import Observation

// MARK: - Stream resolution types
//
// Streams are resolved via InnerTubeAPI (youtubei/v1/player client spoofing).
// Playback (Demus order): MWEB → ANDROID → ANDROID_VR → WEB_REMIX → ANDROID_MUSIC → TV_EMBEDDED.
// Metadata: IOS /player (fast, session-bound) fetched in parallel with stream resolve.
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

// MARK: - Demus Network Layer
actor DemusNetwork {
    static let shared = DemusNetwork()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config)
    }

    // MARK: - Top-level resolve (delegates to InnerTube client spoofing)
    func resolve(
        videoId: String,
        visitorData: String,
        quality: StreamingQuality
    ) async throws -> Resolved {
        let session = await MainActor.run {
            let boot = SessionBootstrap.shared
            return YouTubeSessionContext(
                visitorData: visitorData,
                cookieHeader: nil,
                sapisid: nil,
                poToken: boot.poToken,
                poTokenVisitorData: boot.poTokenVisitorData,
                dataSyncId: boot.dataSyncId,
                clientVersion: boot.clientVersion,
                signatureTimestamp: boot.signatureTimestamp,
                appInstallData: boot.appInstallData,
                coldConfigData: boot.coldConfigData,
                coldHashData: boot.coldHashData,
                hotHashData: boot.hotHashData,
                deviceExperimentId: boot.deviceExperimentId,
                rolloutToken: boot.rolloutToken,
                clickTrackingParams: boot.clickTrackingParams
            )
        }
        return try await InnerTubeAPI.shared.resolveStream(
            videoId: videoId,
            session: session,
            quality: quality
        )
    }

    // DIAGNOSTIC: fetch the stream URL with different User-Agents to find which
    // (if any) the googlevideo server accepts.
    func probe(_ url: URL) async {
        async let ios = status(url, ua: InnerTubeClient.ios.config.userAgent, label: "IOS-UA")
        async let mweb = status(url, ua: InnerTubeClient.mweb.config.userAgent, label: "MWEB-UA")
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
            "query": query
            // No params / filters — unrestricted search (all content types)
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
            URLQueryItem(name: "maxResults", value: "25"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: key)
            // Removed videoCategoryId filter to remove music-only search restriction
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
    
    func reset() {
        playingSong = nil
        history.removeAll()
        nextSongIds.removeAll()
        originalSongIds.removeAll()
        MusicPlayer.shared.stop()
    }

    /// Insert track at the front of the up-next queue (Play Next)
    func playNext(_ track: Track) {
        if playingSong == nil {
            play(track: track)
            return
        }
        nextSongIds.insert(track, at: 0)
    }

    /// Append track to the end of the up-next queue (Add to Queue)
    func addToQueue(_ track: Track) {
        if playingSong == nil {
            play(track: track)
            return
        }
        nextSongIds.append(track)
    }
}
