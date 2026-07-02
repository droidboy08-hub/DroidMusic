import Foundation

// MARK: - InnerTube private API (client spoofing + session binding)
//
// Playback (Demus order): MWEB → ANDROID → ANDROID_VR → WEB_REMIX → …
// Metadata: IOS /player only (fetchMetadata). Stream resolve never uses IOS.
//
// Requests are bound to a real WebView session: visitorData, cookies, poToken,
// and SAPISIDHASH must all come from the same warmed WKWebView or YouTube
// flags the client as synthetic.

struct InnerTubeClientConfig {
    nonisolated let clientId: Int
    nonisolated let clientName: String
    nonisolated let clientVersion: String
    nonisolated let userAgent: String
    nonisolated let apiKey: String?
    nonisolated let host: String
    nonisolated let origin: String?
    nonisolated let referer: String?
    nonisolated let extraClientFields: [String: Any]
    nonisolated let requiresPoToken: Bool

    nonisolated var playerURL: URL {
        var path = "https://\(host)/youtubei/v1/player?prettyPrint=false"
        if let apiKey { path += "&key=\(apiKey)" }
        return URL(string: path)!
    }
}

enum InnerTubeClient: CaseIterable, Sendable {
    case webRemix
    case android
    case androidVR
    case ios
    case androidMusic
    case mweb
    case tvEmbedded

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.webRemix, .webRemix),
             (.android, .android),
             (.androidVR, .androidVR),
             (.ios, .ios),
             (.androidMusic, .androidMusic),
             (.mweb, .mweb),
             (.tvEmbedded, .tvEmbedded):
            return true
        default:
            return false
        }
    }

    /// Clients whose streaming URLs require the PO token appended as `&pot=` (and
    /// which must therefore send the pot's bound visitorData). Per yt-dlp's GVS
    /// policy — ANDROID_VR / TV / IOS are intentionally excluded.
    nonisolated var usesGvsPoToken: Bool {
        switch self {
        case .mweb, .android, .webRemix, .androidMusic: return true
        case .androidVR, .ios, .tvEmbedded: return false
        }
    }

    nonisolated var config: InnerTubeClientConfig {
        switch self {
        case .webRemix:
            return InnerTubeClientConfig(
                clientId: 67,
                clientName: "WEB_REMIX",
                clientVersion: "1.20250519.03.01",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
                apiKey: "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30",
                host: "music.youtube.com",
                origin: "https://music.youtube.com",
                referer: "https://music.youtube.com/",
                extraClientFields: [:],
                requiresPoToken: true
            )
        case .android:
            return InnerTubeClientConfig(
                clientId: 3,
                clientName: "ANDROID",
                clientVersion: "21.02.35",
                userAgent: "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip",
                apiKey: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w",
                host: "www.youtube.com",
                origin: nil, referer: nil,
                extraClientFields: [
                    "androidSdkVersion": 30,
                    "osName": "Android",
                    "osVersion": "11",
                    "platform": "MOBILE"
                ],
                requiresPoToken: false
            )
        case .androidVR:
            return InnerTubeClientConfig(
                clientId: 28,
                clientName: "ANDROID_VR",
                clientVersion: "1.61.43",
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.43 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                apiKey: nil,
                host: "www.youtube.com",
                origin: nil, referer: nil,
                extraClientFields: [
                    "deviceMake": "Oculus",
                    "deviceModel": "Quest 3",
                    "osName": "Android",
                    "osVersion": "12L",
                    "androidSdkVersion": 32
                ],
                requiresPoToken: false
            )
        case .ios:
            return InnerTubeClientConfig(
                clientId: 5,
                clientName: "IOS",
                clientVersion: "20.25.4",
                userAgent: "com.google.ios.youtube/20.25.4 (iPhone17,1; U; CPU iOS 18_5 like Mac OS X)",
                apiKey: "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc",
                host: "music.youtube.com",
                origin: nil, referer: nil,
                extraClientFields: [
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone17,1",
                    "osName": "iPhone",
                    "osVersion": "18.5.0.22F76"
                ],
                requiresPoToken: false
            )
        case .androidMusic:
            return InnerTubeClientConfig(
                clientId: 21,
                clientName: "ANDROID_MUSIC",
                clientVersion: "7.11.50",
                userAgent: "com.google.android.apps.youtube.music/7.11.50 (Linux; U; Android 13; en_US) gzip",
                apiKey: "AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI",
                host: "music.youtube.com",
                origin: "https://music.youtube.com",
                referer: "https://music.youtube.com/",
                extraClientFields: [
                    "androidSdkVersion": 33,
                    "osName": "Android",
                    "osVersion": "13"
                ],
                requiresPoToken: false
            )
        case .mweb:
            return InnerTubeClientConfig(
                clientId: 2,
                clientName: "MWEB",
                clientVersion: "2.20260624.00.00",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
                apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
                host: "m.youtube.com",
                origin: "https://m.youtube.com",
                referer: "https://m.youtube.com/",
                extraClientFields: [:],
                requiresPoToken: true
            )
        case .tvEmbedded:
            return InnerTubeClientConfig(
                clientId: 85,
                clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
                clientVersion: "2.0",
                userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
                apiKey: nil,
                host: "www.youtube.com",
                origin: "https://www.youtube.com",
                referer: "https://www.youtube.com/",
                extraClientFields: [
                    "clientScreen": "EMBED",
                    "thirdParty": ["embedUrl": "https://www.youtube.com/"]
                ],
                requiresPoToken: false
            )
        }
    }
}

// MARK: - InnerTube player actor

actor InnerTubeAPI {
    static let shared = InnerTubeAPI()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
    }

    /// UA for googlevideo GET on unthrottled itag 18 (Demus uses AppleCoreMedia, not MWEB Safari).
    nonisolated static let appleCoreMediaUA =
        "AppleCoreMedia/1.0.0 (iPhone; U; CPU OS 18_0 like Mac OS X; en_us)"

    // MARK: - Metadata (IOS client — not used for stream URLs)

    /// Lightweight /player call spoofing IOS for videoDetails only.
    func fetchMetadata(
        videoId: String,
        session ctx: YouTubeSessionContext
    ) async -> TrackMetadata? {
        do {
            let json = try await player(videoId: videoId, session: ctx, client: .ios)
            let status = nav(json, "playabilityStatus", "status") as? String ?? "?"
            guard status == "OK" else { return nil }
            return MetadataParser.parsePlayerResponse(json)
        } catch {
            dlog("🟡 [InnerTube/IOS/metadata] \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Stream resolution (main playback entry)

    /// Demus-style playback resolve. IOS is reserved for metadata (see fetchMetadata).
    func resolveStream(
        videoId: String,
        session ctx: YouTubeSessionContext,
        quality: StreamingQuality
    ) async throws -> Resolved {
        // InnerTube first — fast and reliable. WebView is a short-timeout fallback only.
        do {
            return try await resolveViaInnerTube(
                videoId: videoId,
                session: ctx,
                quality: quality
            )
        } catch {
            if let web = try await WebViewStreamExtractor.shared.extract(
                videoId: videoId,
                timeout: 12
            ) {
                return web
            }
            throw error
        }
    }

    /// Demus playback client order — IOS intentionally excluded (metadata only).
    private func playbackClientOrder(session ctx: YouTubeSessionContext) -> [InnerTubeClient] {
        // Preferred: the plain ANDROID client backed by a PO token — more robust
        // long-term than ANDROID_VR (which can't play "made for kids" videos and may
        // go SABR-only on newer versions). ANDROID_VR sits right behind it as a
        // token-less fallback that always returns itag 18 + ratebypass, so both
        // cold-start (before a token is minted, ANDROID is omitted) and any ANDROID
        // failure fall straight through to it.
        var order: [InnerTubeClient] = []
        if ctx.poToken != nil { order.append(.android) }
        order.append(.androidVR)
        if ctx.poToken != nil { order.append(.mweb) }
        if ctx.isAuthenticated { order.append(.webRemix) }
        order += [.androidMusic, .tvEmbedded]
        return order
    }

    private func resolveViaInnerTube(
        videoId: String,
        session ctx: YouTubeSessionContext,
        quality: StreamingQuality
    ) async throws -> Resolved {
        let order = playbackClientOrder(session: ctx)

        var sessionCtx = ctx   // may adopt a refreshed pot token mid-cascade
        var lastPlayabilityError: String?
        var muxedFallback: (client: InnerTubeClient, resolved: Resolved)?
        var audioFallback: (client: InnerTubeClient, resolved: Resolved)?

        enum Outcome { case ideal(Resolved); case fallback(Resolved); case failed }

        // One attempt at a single client. Logs, records playability reasons; the
        // caller decides whether to keep it, retry, or move on.
        func attempt(_ client: InnerTubeClient, _ c: YouTubeSessionContext) async -> Outcome {
            let cfg = client.config
            do {
                let json = try await player(videoId: videoId, session: c, client: client)
                let status = nav(json, "playabilityStatus", "status") as? String ?? "?"
                if status != "OK" {
                    let reason = playabilityReason(json) ?? status
                    dlog("🟡 [InnerTube/\(cfg.clientName)] playability=\(status) (\(reason))")
                    if client == .webRemix || client == .tvEmbedded { lastPlayabilityError = reason }
                    return .failed
                }
                logStreamFormats(json, clientName: cfg.clientName)
                guard let resolved = parseStreamFormats(json, client: client, quality: quality, poToken: c.poToken) else {
                    dlog("🟡 [InnerTube/\(cfg.clientName)] no direct stream url")
                    return .failed
                }
                dlog("🟢 [InnerTube/\(cfg.clientName)] picked itag=\(resolved.itag) hasVideo=\(resolved.hasVideo) ratebypass=\(!resolved.needsChunkedLoader)")
                // Demus target: itag 18 + ratebypass=yes.
                return (resolved.hasVideo && !resolved.needsChunkedLoader) ? .ideal(resolved) : .fallback(resolved)
            } catch {
                dlog("🟡 [InnerTube/\(cfg.clientName)] \(error.localizedDescription)")
                return .failed
            }
        }

        for client in order {
            let cfg = client.config
            if cfg.requiresPoToken && sessionCtx.poToken == nil { continue }

            if client.usesGvsPoToken {
                let bind = sessionCtx.poTokenVisitorData != nil ? "vd=pot" : "vd=session"
                dlog("🔑 [InnerTube/\(cfg.clientName)] attempt poToken=\(sessionCtx.poToken != nil ? "✓" : "✗") \(bind)")
            }

            var outcome = await attempt(client, sessionCtx)

            // A pot client that failed with a token attached usually means the token
            // was rejected (stale/mismatched). Force one fresh mint and retry this
            // client once with it before falling through to ANDROID_VR.
            if case .failed = outcome, client.usesGvsPoToken, sessionCtx.poToken != nil {
                if let fresh = await SessionBootstrap.shared.refreshPoTokenNow() {
                    sessionCtx = sessionCtx.withPoToken(fresh.token, visitorData: fresh.visitorData)
                    dlog("🔁 [InnerTube/\(cfg.clientName)] retrying with refreshed poToken")
                    outcome = await attempt(client, sessionCtx)
                }
            }

            switch outcome {
            case .ideal(let resolved):
                return resolved
            case .fallback(let resolved):
                if resolved.hasVideo {
                    if muxedFallback == nil || !muxedFallback!.resolved.needsChunkedLoader {
                        muxedFallback = (client, resolved)
                    }
                } else if audioFallback == nil
                            || resolved.itag > (audioFallback?.resolved.itag ?? 0)
                            || (!resolved.needsChunkedLoader && audioFallback!.resolved.needsChunkedLoader) {
                    audioFallback = (client, resolved)
                }
            case .failed:
                break
            }
        }

        if let muxedFallback { return muxedFallback.resolved }
        if let audioFallback { return audioFallback.resolved }
        if let reason = lastPlayabilityError { throw PlayerError.notPlayable(reason) }
        throw PlayerError.noStream
    }

    // MARK: - Raw /player call

    func player(
        videoId: String,
        session ctx: YouTubeSessionContext,
        client: InnerTubeClient
    ) async throws -> [String: Any] {
        let cfg = client.config
        let effectiveClientVersion = (cfg.clientName.hasPrefix("WEB") || cfg.clientName == "MWEB")
            ? (ctx.clientVersion ?? cfg.clientVersion)
            : cfg.clientVersion
        // Pot-requiring clients must send the visitorData the token is bound to,
        // else the pot (in body + on the stream URL) is rejected. Others (notably
        // ANDROID_VR) keep the session visitorData.
        let effectiveVisitorData = (client.usesGvsPoToken ? ctx.poTokenVisitorData : nil) ?? ctx.visitorData
        var clientDict: [String: Any] = [
            "clientName": cfg.clientName,
            "clientVersion": effectiveClientVersion,
            "hl": "en",
            "gl": "US",
            "visitorData": effectiveVisitorData,
            "userAgent": cfg.userAgent
        ]
        for (k, v) in cfg.extraClientFields { clientDict[k] = v }

        var context: [String: Any] = ["client": clientDict]
        if ctx.isAuthenticated {
            context["user"] = ["lockedSafetyMode": false]
        }

        let body: [String: Any]
        if client == .ios {
            // IOS: metadata / session spoofing only — not used for stream minting.
            body = YouTubeContextBuilder.iosPlayerBody(videoId: videoId, session: ctx)
        } else {
            var generic: [String: Any] = [
                "context": context,
                "videoId": videoId,
                "racyCheckOk": true,
                "contentCheckOk": true,
                "playbackContext": [
                    "contentPlaybackContext": [
                        "html5Preference": "HTML5_PREF_WANTS",
                        "signatureTimestamp": ctx.signatureTimestamp ?? 0
                    ]
                ]
            ]
            if let poToken = ctx.poToken {
                generic["serviceIntegrityDimensions"] = ["poToken": poToken]
            }
            if client == .tvEmbedded {
                generic["params"] = "2AMB"
            }
            body = generic
        }

        var request = URLRequest(url: cfg.playerURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Demus sends CFNetwork UA with no X-YouTube-* headers; match that for IOS.
        if client == .ios {
            request.setValue("Auria/1 CFNetwork/3826.600.41 Darwin/24.6.0", forHTTPHeaderField: "User-Agent")
            if !ctx.visitorData.isEmpty {
                request.setValue(ctx.visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
            }
        } else {
            request.setValue(effectiveVisitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
            request.setValue(cfg.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("\(cfg.clientId)", forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(effectiveClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        }

        if let origin = cfg.origin ?? (cfg.host.contains("music") ? "https://music.youtube.com" : nil) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue((cfg.referer ?? origin + "/"), forHTTPHeaderField: "Referer")
            if let auth = ctx.authorizationHeader(origin: origin) {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }
        // Only attach web cookies for web-family clients (or when explicitly authenticated).
        // Mobile spoof clients (ANDROID/IOS) should not carry web session cookies.
        let isWebClient = cfg.clientName.hasPrefix("WEB") || cfg.clientName == "MWEB" || cfg.origin != nil
        if isWebClient, let cookies = ctx.cookieHeader {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        if ctx.isAuthenticated {
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let pot = ctx.poToken != nil ? "pot✓" : "pot✗"
            let bind = client.usesGvsPoToken && ctx.poTokenVisitorData != nil ? "vd=pot" : "vd=session"
            dlog("🔴 [InnerTube/\(cfg.clientName)] /player HTTP \(code) (\(pot), \(bind), \(data.count) bytes)")
            throw PlayerError.badResponse
        }
        return json
    }

    // MARK: - Format parsing

    private func parseStreamFormats(
        _ json: [String: Any],
        client: InnerTubeClient,
        quality: StreamingQuality,
        poToken: String? = nil
    ) -> Resolved? {
        let cfg = client.config
        let sd = json["streamingData"] as? [String: Any] ?? [:]
        let progressive = (sd["formats"] as? [[String: Any]]) ?? []
        let adaptive = (sd["adaptiveFormats"] as? [[String: Any]]) ?? []
        let meta = MetadataParser.parsePlayerResponse(json)

        // Per yt-dlp's GVS policy, web-family + plain ANDROID streaming URLs require
        // the PO token appended as `&pot=`. ANDROID_VR/TV explicitly don't — adding
        // it there would bind-mismatch a working URL, so only append for these.
        func withPot(_ urlStr: String) -> String {
            guard let poToken, client.usesGvsPoToken,
                  !urlStr.contains("pot=") else { return urlStr }
            let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = poToken.addingPercentEncoding(withAllowedCharacters: unreserved) ?? poToken
            return urlStr + (urlStr.contains("?") ? "&" : "?") + "pot=" + encoded
        }

        let audioFormats = adaptive.filter {
            ($0["mimeType"] as? String)?.hasPrefix("audio") == true && directURL(from: $0) != nil
        }
        func audio(_ itag: Int) -> [String: Any]? {
            audioFormats.first { ($0["itag"] as? Int) == itag }
        }

        func pickAudio() -> [String: Any]? {
            guard !audioFormats.isEmpty else { return nil }
            switch quality {
            case .low:
                return audio(139)
                    ?? audioFormats.min { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }
            case .normal:
                return audio(140) ?? audio(251) ?? audio(139) ?? audioFormats.first
            case .high:
                return audio(251)
                    ?? audioFormats.max {
                        ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0)
                    } ?? audio(140) ?? audio(139)
            }
        }

        func mediaUserAgent(itag: Int, ratebypass: Bool) -> String {
            if itag == 18 && ratebypass { return Self.appleCoreMediaUA }
            return cfg.userAgent
        }

        func resolvedAudio(_ f: [String: Any]) -> Resolved? {
            guard let urlStr = directURL(from: f), let url = URL(string: withPot(urlStr)) else { return nil }
            let itag = (f["itag"] as? Int) ?? 140
            let rb = urlStr.contains("ratebypass=yes")
            return Resolved(
                url: url, itag: itag, hasVideo: false, needsChunkedLoader: !rb,
                durationSeconds: videoDuration(json, fallbackMs: f["approxDurationMs"] as? String),
                userAgent: mediaUserAgent(itag: itag, ratebypass: rb), metadata: meta
            )
        }

        // Prefer itag 18 with ratebypass (Demus MWEB path).
        if let f18 = progressive.first(where: { ($0["itag"] as? Int) == 18 }),
           let urlStr = directURL(from: f18), let url = URL(string: withPot(urlStr)) {
            let rb = urlStr.contains("ratebypass=yes")
            return Resolved(
                url: url, itag: 18, hasVideo: true, needsChunkedLoader: !rb,
                durationSeconds: videoDuration(json, fallbackMs: f18["approxDurationMs"] as? String),
                userAgent: mediaUserAgent(itag: 18, ratebypass: rb), metadata: meta
            )
        }

        guard let f = pickAudio() else { return nil }
        return resolvedAudio(f)
    }

    private func logStreamFormats(_ json: [String: Any], clientName: String) {
        let sd = json["streamingData"] as? [String: Any] ?? [:]
        let progressive = (sd["formats"] as? [[String: Any]]) ?? []
        for f in progressive where (f["itag"] as? Int) == 18 {
            let urlStr = directURL(from: f) ?? ""
            dlog("🎬 [InnerTube/\(clientName)] itag=18 ratebypass=\(urlStr.contains("ratebypass=yes")) url=\(!urlStr.isEmpty)")
        }
        let adaptive = (sd["adaptiveFormats"] as? [[String: Any]]) ?? []
        let audio = adaptive.filter { ($0["mimeType"] as? String)?.hasPrefix("audio") == true }
        guard !audio.isEmpty else {
            dlog("🟡 [InnerTube/\(clientName)] no adaptive audio formats")
            return
        }
        for f in audio.sorted(by: { ($0["itag"] as? Int ?? 0) < ($1["itag"] as? Int ?? 0) }) {
            let itag = f["itag"] as? Int ?? -1
            let urlStr = directURL(from: f) ?? ""
            let rb = urlStr.contains("ratebypass=yes")
            let cipher = f["signatureCipher"] != nil || f["cipher"] != nil
            let br = f["bitrate"] as? Int ?? 0
            dlog("🔊 [InnerTube/\(clientName)] audio itag=\(itag) bitrate=\(br) ratebypass=\(rb) cipher=\(cipher) url=\(!urlStr.isEmpty)")
        }
    }

    private func directURL(from format: [String: Any]) -> String? {
        if let url = format["url"] as? String, !url.isEmpty { return url }
        if format["signatureCipher"] != nil || format["cipher"] != nil { return nil }
        return nil
    }

    private func videoDuration(_ json: [String: Any], fallbackMs: String?) -> Double {
        if let vd = json["videoDetails"] as? [String: Any],
           let s = vd["lengthSeconds"] as? String, let n = Double(s) { return n }
        if let s = fallbackMs, let n = Double(s) { return n / 1000.0 }
        return 0
    }

    private func playabilityReason(_ json: [String: Any]) -> String? {
        nav(json, "playabilityStatus", "reason") as? String
            ?? nav(json, "playabilityStatus", "errorScreen", "playerErrorMessageRenderer", "reason", "simpleText") as? String
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