import SwiftUI
import WebKit

// MARK: - Host view (kept alive in ContentView so the session webview persists)
struct SessionWebViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        SessionBootstrap.shared.start()
        return SessionBootstrap.shared.webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Session bootstrap (InnerTube visitorData)
//
// InnerTube /player calls need a valid `visitorData`. This hidden WebView loads
// music.youtube.com once at launch, reads VISITOR_DATA out of ytcfg, and keeps
// the session/cookies alive for all InnerTube client-spoofed requests.
//
// After a successful harvest we also fire a one-shot MWEB `generate_204` CDN probe
// (same handshake the m.youtube.com web player performs before streaming).
@MainActor
final class SessionBootstrap: NSObject, WKNavigationDelegate {
    static let shared = SessionBootstrap()

    struct Snapshot {
        let visitorData: String
        let poToken: String?
        let poTokenVisitorData: String?
        let dataSyncId: String?
        let clientVersion: String?
        let signatureTimestamp: Int?
        let appInstallData: String?
        let coldConfigData: String?
        let coldHashData: String?
        let hotHashData: String?
        let deviceExperimentId: String?
        let rolloutToken: String?
        let clickTrackingParams: String?
    }

    let webView: WKWebView
    private(set) var visitorData: String?
    private(set) var poToken: String?
    /// The visitorData our PO token is bound to (from the minter's watch page; may
    /// differ from `visitorData`). Pot-requiring clients must use this pairing.
    private(set) var poTokenVisitorData: String?
    private(set) var dataSyncId: String?
    private(set) var clientVersion: String?
    private(set) var signatureTimestamp: Int?
    private(set) var appInstallData: String?
    private(set) var coldConfigData: String?
    private(set) var coldHashData: String?
    private(set) var hotHashData: String?
    private(set) var deviceExperimentId: String?
    private(set) var rolloutToken: String?
    private(set) var clickTrackingParams: String?

    private var loading = false
    private var waiters: [CheckedContinuation<String?, Never>] = []
    /// Bumped on `refresh()` so MWEB warmup runs once per bootstrap cycle.
    private var bootstrapGeneration = 0
    private var lastWarmupGeneration = -1
    private var poTokenRefreshTask: Task<Void, Never>?

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: cfg)
        // Mobile-Safari UA so music.youtube.com serves the page we expect.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        super.init()
        webView.navigationDelegate = self
        webView.isHidden = true
    }

    /// Begin (or no-op if we already have data / are mid-load).
    func start() {
        guard !loading, visitorData == nil else { return }
        loading = true
        dlog("🟣 [Session] bootstrapping visitorData…")
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
    }

    /// Force a fresh bootstrap (e.g. visitorData expired / /player errored).
    func refresh() {
        visitorData = nil
        poToken = nil
        poTokenVisitorData = nil
        dataSyncId = nil
        clientVersion = nil
        signatureTimestamp = nil
        appInstallData = nil
        coldConfigData = nil
        coldHashData = nil
        hotHashData = nil
        deviceExperimentId = nil
        rolloutToken = nil
        clickTrackingParams = nil
        poTokenRefreshTask?.cancel()
        loading = false
        bootstrapGeneration += 1
        start()
    }

    /// Full session snapshot for detection-resistant InnerTube calls.
    func sessionSnapshot() async -> Snapshot? {
        if let vd = visitorData {
            return currentSnapshot(visitorData: vd)
        }
        _ = await visitorDataValue()
        guard let vd = visitorData else { return nil }
        return currentSnapshot(visitorData: vd)
    }

    /// Cached visitorData, or await the in-flight bootstrap (with a safety timeout).
    func visitorDataValue() async -> String? {
        if let vd = visitorData { return vd }
        start()
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self?.resumeWaiters()   // give back whatever we have (possibly nil)
            }
        }
    }

    private func currentSnapshot(visitorData vd: String) -> Snapshot {
        Snapshot(
            visitorData: vd,
            poToken: poToken,
            poTokenVisitorData: poTokenVisitorData,
            dataSyncId: dataSyncId,
            clientVersion: clientVersion,
            signatureTimestamp: signatureTimestamp,
            appInstallData: appInstallData,
            coldConfigData: coldConfigData,
            coldHashData: coldHashData,
            hotHashData: hotHashData,
            deviceExperimentId: deviceExperimentId,
            rolloutToken: rolloutToken,
            clickTrackingParams: clickTrackingParams
        )
    }

    /// Mint a real PO token in the background (page globals never carry one).
    /// Unlocks the MWEB client and supplies `serviceIntegrityDimensions.poToken`
    /// for all InnerTube clients. Best-effort: playback never waits on this.
    private func mintPoTokenIfNeeded(visitorData vd: String) {
        guard poToken == nil else { return }
        let gen = bootstrapGeneration
        Task { [weak self] in
            // Bind the pot to OUR visitorData so it always validates (no mismatch).
            let minted = await PoTokenMinter.shared.ensureValidToken(visitorData: vd)
            guard let self, let minted,
                  self.bootstrapGeneration == gen   // session not refreshed since
            else { return }
            self.poToken = minted.value
            self.poTokenVisitorData = minted.visitorData
            dlog("🔑 [PoToken] bound to session ✓ (vd \(vd.prefix(10))…, age \(Int(minted.age))s)")
            self.schedulePoTokenRefresh()
        }
    }

    /// Keep the ANDROID/MWEB token warm. `ensureValidToken` only re-mints once the
    /// cached token ages past its stale threshold, so this loop is cheap on most
    /// ticks and just refreshes the stored pair. Cancelled on `refresh()`.
    private func schedulePoTokenRefresh() {
        poTokenRefreshTask?.cancel()
        let gen = bootstrapGeneration
        poTokenRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                guard let self, !Task.isCancelled, self.bootstrapGeneration == gen,
                      let vd = self.visitorData else { return }
                if let minted = await PoTokenMinter.shared.ensureValidToken(visitorData: vd),
                   self.bootstrapGeneration == gen {
                    self.poToken = minted.value
                    self.poTokenVisitorData = minted.visitorData
                    dlog("🔑 [PoToken] periodic check ✓ (age \(Int(minted.age))s)")
                }
            }
        }
    }

    /// Force a fresh token right now and adopt it. Used by InnerTube when the
    /// ANDROID client rejects the current token mid-playback (likely stale).
    func refreshPoTokenNow() async -> (token: String, visitorData: String)? {
        guard let vd = visitorData,
              let minted = await PoTokenMinter.shared.ensureValidToken(visitorData: vd, force: true)
        else { return nil }
        poToken = minted.value
        poTokenVisitorData = minted.visitorData
        dlog("🔑 [PoToken] force-refreshed ✓ (age \(Int(minted.age))s)")
        return (minted.value, minted.visitorData)
    }

    /// Fire-and-forget: does not block playback or visitorData waiters.
    private func scheduleMWEBWarmupIfNeeded() {
        let gen = bootstrapGeneration
        guard lastWarmupGeneration != gen else { return }
        lastWarmupGeneration = gen
        Task { await MWEBSessionWarmup.run() }
    }

    private func resumeWaiters() {
        guard !waiters.isEmpty else { return }
        let vd = visitorData
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: vd) }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        let js = """
        (function () {
            var out = {};
            try {
                var d = (window.ytcfg && ytcfg.data_) ? ytcfg.data_ : {};
                var g = (window.ytcfg && ytcfg.get) ? function (k) { return ytcfg.get(k); } : function () { return null; };
                out.visitorData   = d.VISITOR_DATA   || g('VISITOR_DATA');
                out.poToken       = d.PO_TOKEN       || d.GWS_PO_TOKEN || g('PO_TOKEN');
                out.dataSyncId    = d.DATASYNC_ID    || g('DATASYNC_ID');
                out.clientVersion = d.INNERTUBE_CONTEXT_CLIENT_VERSION || g('INNERTUBE_CONTEXT_CLIENT_VERSION');
                out.signatureTimestamp = d.STS || g('STS') || g('SIGNATURE_TIMESTAMP');
                out.deviceExperimentId = d.DEVICE_EXPERIMENT_ID || g('DEVICE_EXPERIMENT_ID');
                out.rolloutToken = d.ROLLOUT_TOKEN || g('ROLLOUT_TOKEN');
                out.clickTrackingParams = d.CLICKTRACKING_PARAMS || g('CLICKTRACKING_PARAMS');
                var cfg = d.WEB_PLAYER_CONTEXT_CONFIGS || g('WEB_PLAYER_CONTEXT_CONFIGS');
                if (cfg && cfg.configInfo) {
                    out.appInstallData = cfg.configInfo.appInstallData;
                    out.coldConfigData = cfg.configInfo.coldConfigData;
                    out.coldHashData = cfg.configInfo.coldHashData;
                    out.hotHashData = cfg.configInfo.hotHashData;
                }
            } catch (e) {}
            return out;
        })();
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            self.loading = false
            if let dict = result as? [String: Any],
               let vd = dict["visitorData"] as? String, !vd.isEmpty {
                self.visitorData = vd
                self.poToken = dict["poToken"] as? String
                self.dataSyncId = dict["dataSyncId"] as? String
                self.clientVersion = dict["clientVersion"] as? String
                if let sts = dict["signatureTimestamp"] as? NSNumber {
                    self.signatureTimestamp = sts.intValue
                } else if let sts = dict["signatureTimestamp"] as? Int {
                    self.signatureTimestamp = sts
                }
                self.appInstallData = dict["appInstallData"] as? String
                self.coldConfigData = dict["coldConfigData"] as? String
                self.coldHashData = dict["coldHashData"] as? String
                self.hotHashData = dict["hotHashData"] as? String
                self.deviceExperimentId = dict["deviceExperimentId"] as? String
                self.rolloutToken = dict["rolloutToken"] as? String
                self.clickTrackingParams = dict["clickTrackingParams"] as? String
                let pot = self.poToken != nil ? "poToken✓" : "poToken✗"
                let sts = self.signatureTimestamp.map(String.init) ?? "nil"
                let cfg = self.coldHashData != nil ? "configInfo✓" : "configInfo✗"
                dlog("🟣 [Session] visitorData (\(vd.prefix(12))…) \(pot) STS=\(sts) \(cfg)")
                self.scheduleMWEBWarmupIfNeeded()
                self.mintPoTokenIfNeeded(visitorData: vd)
            } else {
                dlog("🔴 [Session] VISITOR_DATA not found on page")
            }
            self.resumeWaiters()
        }
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dlog("🔴 [Session] navigation failed: \(error.localizedDescription)")
        loading = false
        resumeWaiters()
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dlog("🔴 [Session] provisional navigation failed: \(error.localizedDescription)")
        loading = false
        resumeWaiters()
    }
}

// MARK: - MWEB CDN connectivity probe (generate_204)
//
// Demus / m.youtube.com pings a Google CDN edge with an empty 204 before streaming.
// We mimic the request shape (Origin + Referer + MWEB UA). URLSession follows
// redirector → regional `*.googlevideo.com` / `*.c.youtube.com` automatically.
private enum MWEBSessionWarmup {
    private static let origin = "https://m.youtube.com"
    private static let userAgent = InnerTubeClient.mweb.config.userAgent

    private static let endpoints = [
        "https://redirector.googlevideo.com/generate_204",
        "https://www.youtube.com/generate_204",
    ]

    static func run() async {
        let session = URLSession(configuration: .default)
        for endpoint in endpoints {
            guard let startURL = URL(string: endpoint) else { continue }
            var request = URLRequest(url: startURL)
            request.httpMethod = "GET"
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("\(origin)/", forHTTPHeaderField: "Referer")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.timeoutInterval = 8

            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                let code = http.statusCode
                let host = response.url?.host ?? startURL.host ?? "?"
                // 204 No Content is the expected CDN connectivity response.
                if code == 204 {
                    dlog("🟣 [Session] MWEB warmup generate_204 → \(code) (\(host))")
                    return
                }
                dlog("🟡 [Session] MWEB warmup \(host) → HTTP \(code), trying next…")
            } catch {
                dlog("🟡 [Session] MWEB warmup \(startURL.host ?? "?") error: \(error.localizedDescription)")
            }
        }
        dlog("🟡 [Session] MWEB warmup: no 204 (non-fatal, playback unchanged)")
    }
}
