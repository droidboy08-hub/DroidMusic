import Foundation
import WebKit

// MARK: - Detection-proof stream extraction (Demus architecture)
//
// Loads the real MWEB watch page in a WKWebView. YouTube's own JS runs PoToken
// attestation (jnn-pa) and signature deciphering; we poll ytInitialPlayerResponse
// for a ready-to-play direct URL, then hand it to native AVPlayer.

@MainActor
final class WebViewStreamExtractor: NSObject, WKNavigationDelegate {
    static let shared = WebViewStreamExtractor()

    private static let mwebUA = InnerTubeClient.mweb.config.userAgent

    private let webView: WKWebView
    private var waiter: CheckedContinuation<Resolved?, Error>?
    private var pollTask: Task<Void, Never>?
    private var activeVideoId: String?

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Non-zero frame helps some JS/initialization on YouTube watch pages.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: cfg)
        super.init()
        webView.customUserAgent = Self.mwebUA
        webView.navigationDelegate = self
        webView.isHidden = true
        webView.alpha = 0.01 // mostly hidden but participates in layout
    }

    /// Extract a signed stream URL via the real watch page. nil = not ready in time.
    func extract(videoId: String, timeout: TimeInterval = 14) async throws -> Resolved? {
        pollTask?.cancel()
        pollTask = nil
        webView.stopLoading()
        if let pending = waiter {
            waiter = nil
            pending.resume(returning: nil)
        }
        activeVideoId = videoId

        return try await withCheckedThrowingContinuation { cont in
            waiter = cont
            // m.youtube.com + mweb UA gives a lighter page whose ytInitialPlayerResponse is populated faster
            // and already contains deciphered stream URLs.
            let url = URL(string: "https://m.youtube.com/watch?v=\(videoId)")!
            print("🌐 [WebExtract] loading watch page for \(videoId)")
            webView.load(URLRequest(url: url))

            pollTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(timeout)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard let self, self.activeVideoId == videoId else { return }
                    if let resolved = await self.pollPlayerResponse() {
                        self.finish(with: .success(resolved))
                        return
                    }
                }
                guard let self, self.activeVideoId == videoId else { return }
                print("🟡 [WebExtract] timed out for \(videoId)")
                self.finish(with: .success(nil))
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        activeVideoId = nil
        if let w = waiter {
            waiter = nil
            w.resume(returning: nil)
        }
        webView.stopLoading()
    }

    // MARK: - Polling

    private func pollPlayerResponse() async -> Resolved? {
        let js = """
        (function () {
            try {
                var pr = window.ytInitialPlayerResponse;
                if (!pr && window.ytplayer && window.ytplayer.config && window.ytplayer.config.args) {
                    try { pr = JSON.parse(window.ytplayer.config.args.player_response); } catch (e) {}
                }
                if (!pr || !pr.streamingData) return null;
                var status = pr.playabilityStatus && pr.playabilityStatus.status;
                if (status && status !== 'OK') return { error: pr.playabilityStatus.reason || status };

                var meta = {
                    durationSeconds: pr.videoDetails ? pr.videoDetails.lengthSeconds : null,
                    title: pr.videoDetails ? pr.videoDetails.title : null,
                    author: pr.videoDetails ? pr.videoDetails.author : null,
                    thumbnail: pr.videoDetails && pr.videoDetails.thumbnail
                        ? (pr.videoDetails.thumbnail.thumbnails || []).slice(-1)[0].url : null
                };
                var progressive = pr.streamingData.formats || [];
                var f18 = progressive.find(function (f) { return f.itag === 18 && f.url; });
                if (f18) {
                    return Object.assign({ url: f18.url, itag: 18, hasVideo: true }, meta);
                }
                var adaptive = pr.streamingData.adaptiveFormats || [];
                var audio = adaptive.find(function (f) { return f.itag === 140 && f.url; })
                    || adaptive.find(function (f) { return f.mimeType && f.mimeType.indexOf('audio') === 0 && f.url; });
                if (audio) {
                    return Object.assign({ url: audio.url, itag: audio.itag, hasVideo: false }, meta);
                }
                return null;
            } catch (e) { return null; }
        })();
        """

        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, _ in
                guard let dict = result as? [String: Any] else {
                    cont.resume(returning: nil)
                    return
                }
                if let err = dict["error"] as? String {
                    print("🟡 [WebExtract] playability: \(err)")
                    cont.resume(returning: nil)
                    return
                }
                guard let urlStr = dict["url"] as? String, let url = URL(string: urlStr) else {
                    cont.resume(returning: nil)
                    return
                }
                let itag = dict["itag"] as? Int ?? 18
                let hasVideo = dict["hasVideo"] as? Bool ?? (itag == 18)
                let rb = urlStr.contains("ratebypass=yes")
                let dur = (dict["durationSeconds"] as? String).flatMap(Double.init) ?? 0
                var meta: TrackMetadata?
                if let title = dict["title"] as? String {
                    meta = TrackMetadata(
                        title: title,
                        artist: dict["author"] as? String ?? "",
                        durationSeconds: dur > 0 ? dur : nil,
                        coverURL: dict["thumbnail"] as? String,
                        videoId: self.activeVideoId
                    )
                }
                print("🟢 [WebExtract] itag=\(itag) hasVideo=\(hasVideo) ratebypass=\(rb)")
                cont.resume(returning: Resolved(
                    url: url, itag: itag, hasVideo: hasVideo, needsChunkedLoader: !rb,
                    durationSeconds: dur,
                    userAgent: Self.mwebUA,
                    metadata: meta
                ))
            }
        }
    }

    private func finish(with result: Result<Resolved?, Error>) {
        pollTask?.cancel()
        pollTask = nil
        activeVideoId = nil
        guard let w = waiter else { return }
        waiter = nil
        switch result {
        case .success(let v): w.resume(returning: v)
        case .failure(let e):   w.resume(throwing: e)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("🟡 [WebExtract] navigation failed: \(error.localizedDescription)")
        finish(with: .success(nil))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("🟡 [WebExtract] provisional fail: \(error.localizedDescription)")
        finish(with: .success(nil))
    }
}