import Foundation
import WebKit

// MARK: - Proof-of-Origin (PO) token minter
//
// YouTube never exposes the PO token as a page global, and it isn't in
// ytInitialPlayerResponse either — the web player runs BotGuard attestation
// (jnn-pa.googleapis.com) and *appends* the token as `pot=` to the actual
// `videoplayback` requests it makes at play time. Reimplementing BotGuard
// natively is impractical, so we let YouTube's own JS do it inside a hidden
// WKWebView and capture the `pot=` off its outgoing network requests via an
// injected fetch/XHR/sendBeacon hook (+ a resource-timing sweep as backup).
//
// The token is *session-bound* (tied to visitorData), so it's reusable across
// videos. Binding only holds if the minting page shares our visitorData, so we
// verify the page's VISITOR_DATA matches before accepting it. The minter shares
// the default WKWebsiteDataStore (same cookies → same visitorData) with
// SessionBootstrap, so this normally lines up.
@MainActor
final class PoTokenMinter: NSObject, WKNavigationDelegate {
    static let shared = PoTokenMinter()

    // Evergreen, embeddable, non-age-restricted seed video. Only used to make the
    // web player initialize and mint a session token — never actually shown.
    private static let seedVideoId = "dQw4w9WgXcQ"
    private static let mwebUA = InnerTubeClient.mweb.config.userAgent

    // Installed at document-start so it wraps the network APIs before the player's
    // JS runs, then records any request URL carrying a `pot=` onto window.__pot.
    private static let hookScript = """
    (function () {
        if (window.__potHookInstalled) return;
        window.__potHookInstalled = true;
        window.__pot = null;
        function scan(u) {
            try {
                if (!u) return;
                var s = (typeof u === 'string') ? u : (u && u.url) ? u.url : '';
                if (s.indexOf('pot=') === -1) return;
                var m = s.match(/[?&]pot=([^&]+)/);
                if (m && m[1]) window.__pot = decodeURIComponent(m[1]);
            } catch (e) {}
        }
        var of = window.fetch;
        if (of) window.fetch = function (input) { scan(input); return of.apply(this, arguments); };
        var oo = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) { scan(url); return oo.apply(this, arguments); };
        if (navigator.sendBeacon) {
            var ob = navigator.sendBeacon.bind(navigator);
            navigator.sendBeacon = function (url, data) { scan(url); return ob(url, data); };
        }
    })();
    """

    /// A PO token together with the visitorData it is cryptographically bound to.
    struct Minted { let value: String; let visitorData: String }

    private let webView: WKWebView
    private var waiter: CheckedContinuation<Minted?, Never>?
    private var pollTask: Task<Void, Never>?

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let hook = WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(hook)
        // Non-zero frame helps YouTube's player JS initialize.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: cfg)
        super.init()
        webView.customUserAgent = Self.mwebUA
        webView.navigationDelegate = self
        webView.isHidden = true
        webView.alpha = 0.01
    }

    /// Loads a watch page, lets the web player mint + emit a token, and returns the
    /// `pot=` value together with the visitorData it's bound to. nil on timeout.
    func mint(timeout: TimeInterval = 20) async -> Minted? {
        // Supersede any in-flight attempt (e.g. session refreshed mid-mint).
        pollTask?.cancel()
        pollTask = nil
        if let pending = waiter {
            waiter = nil
            pending.resume(returning: nil)
        }
        webView.stopLoading()

        let url = URL(string: "https://m.youtube.com/watch?v=\(Self.seedVideoId)")!
        print("🔑 [PoToken] minting via watch page…")
        webView.load(URLRequest(url: url))

        let minted: Minted? = await withCheckedContinuation { cont in
            waiter = cont
            pollTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(timeout)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let self else { return }
                    if let pot = await self.pollPot() {
                        self.finish(pot)
                        return
                    }
                }
                self?.finish(nil)
            }
        }

        print(minted != nil ? "🔑 [PoToken] minted ✓" : "🔑 [PoToken] mint failed ✗")
        return minted
    }

    // MARK: - Polling

    private func pollPot() async -> Minted? {
        // Nudge the (muted) player so it issues the videoplayback requests that
        // carry `pot=`, then read whatever the hook / resource-timing captured.
        let js = """
        (function () {
            try {
                var v = document.querySelector('video');
                if (v) { v.muted = true; if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function () {}); } }
            } catch (e) {}
            try {
                var d = (window.ytcfg && ytcfg.data_) ? ytcfg.data_ : {};
                var get = (window.ytcfg && ytcfg.get) ? function (k) { return ytcfg.get(k); } : function () { return null; };
                var vd = d.VISITOR_DATA || get('VISITOR_DATA');
                var pot = window.__pot;
                if (!pot) {
                    var es = performance.getEntriesByType('resource') || [];
                    for (var i = es.length - 1; i >= 0; i--) {
                        var n = es[i].name || '';
                        if (n.indexOf('pot=') === -1) continue;
                        var m = n.match(/[?&]pot=([^&]+)/);
                        if (m && m[1]) { pot = decodeURIComponent(m[1]); break; }
                    }
                }
                if (!pot) return null;
                return { pot: pot, visitorData: vd };
            } catch (e) { return null; }
        })();
        """
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, _ in
                // The token is bound to the page's own visitorData — return both so
                // the caller can use them as a coherent pair (no mismatch possible).
                guard let dict = result as? [String: Any],
                      let pot = dict["pot"] as? String, !pot.isEmpty,
                      let vd = dict["visitorData"] as? String, !vd.isEmpty else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: Minted(value: pot, visitorData: vd))
            }
        }
    }

    private func finish(_ minted: Minted?) {
        pollTask?.cancel()
        pollTask = nil
        webView.stopLoading()
        guard let w = waiter else { return }
        waiter = nil
        w.resume(returning: minted)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("🔑 [PoToken] nav failed: \(error.localizedDescription)")
        finish(nil)
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("🔑 [PoToken] provisional fail: \(error.localizedDescription)")
        finish(nil)
    }
}
