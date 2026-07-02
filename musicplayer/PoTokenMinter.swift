import Foundation
import WebKit

// MARK: - Proof-of-Origin (PO) token minter  (BotGuard, no video playback)
//
// Ported from NewPipe's PoTokenWebView + yt-dlp's WebPO handling. Instead of
// loading a watch page and scraping a playing video (which leaked audio and was
// flaky), we run YouTube's BotGuard attestation *directly* in a tiny local HTML
// page — pure JS crypto, no <video>, no media pipeline, silent.
//
// Flow (all orchestrated natively; the WebView only runs BotGuard JS):
//   1. POST /api/jnn/v1/Create      → BotGuard challenge
//   2. JS runBotGuard(challenge)    → botguardResponse + webPoSignalOutput
//   3. POST /api/jnn/v1/GenerateIT  → integrityToken (+ ttl)
//   4. JS obtainPoToken(signals, integrityToken, visitorData) → the pot
//
// Lifecycle (the "future-proof" part): the integrityToken from step 3 is valid
// ~6–12 h. We read its real ttl, keep a 10-min safety margin, and cap reuse at
// 6 h (matching yt-dlp). While it's valid, step 4 is cheap and re-runnable for
// any identifier with NO re-attestation. Past expiry (or on rejection) we
// re-attest. The pot is bound to the visitorData we pass in — the SAME one our
// InnerTube requests send — so there's no visitorData mismatch. See
// [[potoken-minting-ios]].
@MainActor
final class PoTokenMinter: NSObject, WKNavigationDelegate {
    static let shared = PoTokenMinter()

    /// A PO token, the visitorData it is bound to, and when it was minted.
    struct Minted {
        let value: String
        let visitorData: String
        let mintedAt: Date
        var age: TimeInterval { Date().timeIntervalSince(mintedAt) }
    }

    enum MintError: Error { case http(Int), parse(String), notReady }

    // BotGuard constants (public values observed in BotGuard requests; same as
    // NewPipe / bgutils-js).
    private static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private static let createURL = URL(string: "https://www.youtube.com/api/jnn/v1/Create")!
    private static let generateITURL = URL(string: "https://www.youtube.com/api/jnn/v1/GenerateIT")!
    private static let origin = URL(string: "https://www.youtube.com")!

    // Minimal page holding only the BotGuard interpreter. `globalThis` is used
    // throughout (not `this`) so it works regardless of strict/sloppy mode.
    private static let interpreterHTML = """
    <!DOCTYPE html><html><head><title></title><script>
    function loadBotGuard(challengeData) {
        globalThis.vm = globalThis[challengeData.globalName];
        globalThis.program = challengeData.program;
        globalThis.vmFunctions = {};
        if (!globalThis.vm) throw new Error('[BG]: VM not found');
        if (!globalThis.vm.a) throw new Error('[BG]: Could not load program');
        var cb = function (asyncSnapshotFunction, shutdownFunction, passEventFunction, checkCameraFunction) {
            globalThis.vmFunctions = {
                asyncSnapshotFunction: asyncSnapshotFunction,
                shutdownFunction: shutdownFunction,
                passEventFunction: passEventFunction,
                checkCameraFunction: checkCameraFunction
            };
        };
        globalThis.syncSnapshotFunction = globalThis.vm.a(globalThis.program, cb, true, undefined, function () {}, [[], []])[0];
        return new Promise(function (resolve, reject) {
            var i = 0;
            var id = setInterval(function () {
                if (globalThis.vmFunctions.asyncSnapshotFunction) { resolve(true); clearInterval(id); }
                if (i >= 10000) { reject('asyncSnapshotFunction null after 10s'); clearInterval(id); }
                i += 1;
            }, 1);
        });
    }
    function snapshot(args) {
        return new Promise(function (resolve, reject) {
            if (!globalThis.vmFunctions.asyncSnapshotFunction) return reject(new Error('[BG]: no async snapshot'));
            globalThis.vmFunctions.asyncSnapshotFunction(function (r) { resolve(r); },
                [args.contentBinding, args.signedTimestamp, args.webPoSignalOutput, args.skipPrivacyBuffer]);
        });
    }
    function runBotGuard(challengeData) {
        var js = challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
        if (js) { new Function(js)(); } else throw new Error('Could not load VM');
        var webPoSignalOutput = [];
        return loadBotGuard({ globalName: challengeData.globalName, globalObj: globalThis, program: challengeData.program })
            .then(function () { return snapshot({ webPoSignalOutput: webPoSignalOutput }); })
            .then(function (botguardResponse) { return { webPoSignalOutput: webPoSignalOutput, botguardResponse: botguardResponse }; });
    }
    function obtainPoToken(webPoSignalOutput, integrityToken, identifier) {
        var getMinter = webPoSignalOutput[0];
        if (!getMinter) throw new Error('PMD:Undefined');
        var mintCallback = getMinter(integrityToken);
        if (!(mintCallback instanceof Function)) throw new Error('APF:Failed');
        var result = mintCallback(identifier);
        if (!result) throw new Error('YNJ:Undefined');
        if (!(result instanceof Uint8Array)) throw new Error('ODM:Invalid');
        return result;
    }
    </script></head><body></body></html>
    """

    private let webView: WKWebView
    private var pageLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// When the current BotGuard attestation (integrityToken) stops being usable.
    private var attestationExpiry: Date?
    /// Last successfully minted streaming pot (with its bound visitorData).
    private(set) var current: Minted?
    /// Single-flight guard so concurrent callers share one mint.
    private var inFlight: Task<Minted?, Never>?

    private override init() {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        super.init()
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.isHidden = true   // no media → safe to stay hidden/detached
    }

    // MARK: - Public API

    /// Returns a pot bound to `vd`, re-attesting only when the integrity token has
    /// expired or `force` is set. Cheap on the common path (reuses the cached pot).
    func ensureValidToken(visitorData vd: String, force: Bool = false) async -> Minted? {
        if !force, let c = current, c.visitorData == vd, isAttestationValid {
            dlog("🔑 [PoToken] reuse cached (vd \(vd.prefix(10))…)")
            return c
        }
        if let t = inFlight { return await t.value }
        let task = Task { await mintFlow(visitorData: vd, force: force) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private var isAttestationValid: Bool {
        guard let e = attestationExpiry else { return false }
        return Date() < e
    }

    // MARK: - Mint flow

    private func mintFlow(visitorData vd: String, force: Bool) async -> Minted? {
        do {
            try await ensurePageLoaded()
            if force || !isAttestationValid {
                try await attest()
            }
            let pot = try await obtain(identifier: vd)
            let m = Minted(value: pot, visitorData: vd, mintedAt: Date())
            current = m
            dlog("🔑 [PoToken] minted ✓ (vd \(vd.prefix(10))…, pot \(pot.prefix(12))…)")
            return m
        } catch {
            dlog("🔑 [PoToken] mint failed ✗ (\(error)) — keeping \(current == nil ? "no" : "previous") token")
            return current
        }
    }

    /// Step 1+2+3: BotGuard challenge → run VM → integrity token. ~6 h reusable.
    private func attest() async throws {
        dlog("🔑 [PoToken] attesting via BotGuard…")
        let challengeRaw = try await post(Self.createURL, jsonArray: [Self.requestKey])
        let data = try parseChallengeData(challengeRaw)

        let botguardResponse = try await webView.callAsyncJavaScript(
            "const r = await runBotGuard(data); globalThis.webPoSignalOutput = r.webPoSignalOutput; return r.botguardResponse;",
            arguments: ["data": data], contentWorld: .page) as? String
        guard let botguardResponse, !botguardResponse.isEmpty else { throw MintError.parse("botguardResponse") }

        let itRaw = try await post(Self.generateITURL, jsonArray: [Self.requestKey, botguardResponse])
        let (itBytes, ttl) = try parseIntegrityTokenData(itRaw)
        _ = try await webView.callAsyncJavaScript(
            "globalThis.integrityToken = new Uint8Array(itBytes); return true;",
            arguments: ["itBytes": itBytes.map { Int($0) }], contentWorld: .page)

        // Real ttl, 10-min margin, capped at 6 h (yt-dlp default_ttl=21600).
        let reuse = max(min(ttl - 600, 21600), 300)
        attestationExpiry = Date().addingTimeInterval(reuse)
        dlog("🔑 [PoToken] attested ✓ (integrity ttl \(Int(ttl))s → reuse \(Int(reuse))s)")
    }

    /// Step 4: mint a pot for `identifier` (cheap; no network, no re-attestation).
    private func obtain(identifier: String) async throws -> String {
        let idBytes = Array(identifier.utf8).map { Int($0) }
        let result = try await webView.callAsyncJavaScript(
            "return Array.from(obtainPoToken(globalThis.webPoSignalOutput, globalThis.integrityToken, new Uint8Array(idBytes)));",
            arguments: ["idBytes": idBytes], contentWorld: .page)
        guard let nums = result as? [Any], !nums.isEmpty else { throw MintError.parse("pot result") }
        let bytes = nums.compactMap { ($0 as? NSNumber).map { UInt8(truncatingIfNeeded: $0.intValue) } }
        // YouTube's url-safe base64 (+→-, /→_), padding kept.
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Page load

    private func ensurePageLoaded() async throws {
        if pageLoaded { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loadWaiters.append(c)
            if loadWaiters.count == 1 {
                webView.loadHTMLString(Self.interpreterHTML, baseURL: Self.origin)
            }
        }
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        let waiters = loadWaiters; loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dlog("🔑 [PoToken] page load failed: \(error.localizedDescription)")
        let waiters = loadWaiters; loadWaiters.removeAll()
        waiters.forEach { $0.resume() }   // let the JS calls fail with a clear error
    }

    // MARK: - Native BotGuard service POSTs

    private func post(_ url: URL, jsonArray: [Any]) async throws -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonArray)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw MintError.http(code) }
        guard let s = String(data: data, encoding: .utf8) else { throw MintError.parse("post body utf8") }
        return s
    }

    // MARK: - Parse / encode helpers (ported from NewPipe JavaScriptUtil)

    /// Create-response → the `data` object runBotGuard() expects.
    private func parseChallengeData(_ raw: String) throws -> [String: Any] {
        guard let d = raw.data(using: .utf8),
              let scrambled = try JSONSerialization.jsonObject(with: d) as? [Any]
        else { throw MintError.parse("challenge root") }

        let challenge: [Any]
        if scrambled.count > 1, let s = scrambled[1] as? String {
            challenge = try descrambleToArray(s)
        } else if let arr0 = scrambled.first as? [Any] {
            challenge = arr0
        } else {
            throw MintError.parse("challenge shape")
        }

        func str(_ i: Int) -> String { (i < challenge.count ? challenge[i] as? String : nil) ?? "" }
        func firstString(_ i: Int) -> String {
            guard i < challenge.count, let a = challenge[i] as? [Any] else { return "" }
            return a.compactMap { $0 as? String }.first ?? ""
        }
        return [
            "messageId": str(0),
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": firstString(1),
                "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": firstString(2),
            ],
            "interpreterHash": str(3),
            "program": str(4),
            "globalName": str(5),
            "clientExperimentsStateBlob": str(7),
        ]
    }

    /// Scrambled challenge → base64-decode, +97 per byte, utf8 → JSON array.
    private func descrambleToArray(_ scrambled: String) throws -> [Any] {
        guard let bytes = ytBase64Decode(scrambled) else { throw MintError.parse("descramble b64") }
        let shifted = bytes.map { $0 &+ 97 }
        guard let str = String(bytes: shifted, encoding: .utf8),
              let arr = try JSONSerialization.jsonObject(with: Data(str.utf8)) as? [Any]
        else { throw MintError.parse("descramble json") }
        return arr
    }

    /// GenerateIT-response → (integrityToken bytes, ttl seconds).
    private func parseIntegrityTokenData(_ raw: String) throws -> ([UInt8], TimeInterval) {
        guard let d = raw.data(using: .utf8),
              let arr = try JSONSerialization.jsonObject(with: d) as? [Any],
              let itB64 = arr.first as? String,
              let bytes = ytBase64Decode(itB64)
        else { throw MintError.parse("integrity token") }
        let ttl = (arr.count > 1 ? (arr[1] as? NSNumber)?.doubleValue : nil) ?? 43200
        return (bytes, ttl)
    }

    /// YouTube's url-safe base64 variant (-→+, _→/, .→padding) → bytes.
    private func ytBase64Decode(_ s: String) -> [UInt8]? {
        var b = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: ".", with: "=")
            .replacingOccurrences(of: "=", with: "")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return [UInt8](data)
    }
}
