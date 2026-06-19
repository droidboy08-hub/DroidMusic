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

// MARK: - Session bootstrap (IOS-client architecture)
//
// We no longer scrape the watch page. The IOS /player call just needs a valid
// `visitorData` + a warmed session. This hidden WebView loads music.youtube.com
// once at launch, reads VISITOR_DATA out of ytcfg, and keeps the session/cookies
// alive. The same visitorData is reused for many /player calls until it expires.
@MainActor
final class SessionBootstrap: NSObject, WKNavigationDelegate {
    static let shared = SessionBootstrap()

    let webView: WKWebView
    private(set) var visitorData: String?

    private var loading = false
    private var waiters: [CheckedContinuation<String?, Never>] = []

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: cfg)
        // Mobile-Safari UA so music.youtube.com serves the page we expect.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        super.init()
        webView.navigationDelegate = self
        webView.isHidden = true
    }

    /// Begin (or no-op if we already have data / are mid-load).
    func start() {
        guard !loading, visitorData == nil else { return }
        loading = true
        print("🟣 [Session] bootstrapping visitorData…")
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
    }

    /// Force a fresh bootstrap (e.g. visitorData expired / /player errored).
    func refresh() {
        visitorData = nil
        loading = false
        start()
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
            try {
                if (window.ytcfg && ytcfg.data_ && ytcfg.data_.VISITOR_DATA) return ytcfg.data_.VISITOR_DATA;
                if (window.ytcfg && ytcfg.get) return ytcfg.get('VISITOR_DATA');
            } catch (e) {}
            return null;
        })();
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            self.loading = false
            if let vd = result as? String, !vd.isEmpty {
                self.visitorData = vd
                print("🟣 [Session] visitorData acquired (\(vd.prefix(12))…)")
            } else {
                print("🔴 [Session] VISITOR_DATA not found on page")
            }
            self.resumeWaiters()
        }
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("🔴 [Session] navigation failed: \(error.localizedDescription)")
        loading = false
        resumeWaiters()
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("🔴 [Session] provisional navigation failed: \(error.localizedDescription)")
        loading = false
        resumeWaiters()
    }
}
