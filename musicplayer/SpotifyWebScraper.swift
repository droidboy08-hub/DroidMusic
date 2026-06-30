import Foundation
import WebKit
import UIKit

/// A single track scraped from the Spotify web player. `Sendable` so it can
/// cross from the `@MainActor` scraper back into the `PlaylistImporter` actor.
struct SpotifyScrapedTrack: Sendable {
    let uri: String
    let title: String
    let artist: String
    let durationSec: Double
}

/// The full result of a scrape: the track list plus the playlist's own
/// display name and cover-art URL (when the player exposes them).
struct SpotifyScrapeResult: Sendable {
    var name: String?
    var coverURL: String?
    var tracks: [SpotifyScrapedTrack]
}

enum SpotifyContentType {
    case playlist
    case album
}

/// Scrapes a public Spotify playlist by driving a hidden `WKWebView`.
///
/// Spotify's anonymous `get_access_token` endpoint now returns 403 and the
/// Feb-2026 API policy killed Client-Credentials OAuth, so the only
/// credential-free route is a real browser context. We load the web player,
/// intercept its `fetchPlaylist` GraphQL calls (pathfinder), and replay the
/// captured request deterministically to page through the whole playlist.
/// If the player never issues a usable request we fall back to parsing the
/// embed page's `__NEXT_DATA__` (good for ~the first 100 tracks).
@MainActor
final class SpotifyWebScraper: NSObject, WKScriptMessageHandler {

    // Desktop UA — a mobile UA stops the web player from booting.
    private let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Set to true to print step-by-step diagnostics to the console.
    var debug = false
    private func dbg(_ s: String) { if debug { print("SCRAPER ⋯ \(s)") } }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<SpotifyScrapeResult, Error>?

    private var ordered: [SpotifyScrapedTrack] = []
    private var playlistName: String?
    private var playlistCoverURL: String?
    private var seen = Set<String>()
    private var expectedTotal = 0
    private var finished = false
    private var usedEmbedFallback = false
    private var playlistId = ""
    private var contentType: SpotifyContentType = .playlist
    private var timeoutTask: Task<Void, Never>?

    // MARK: - Entry point

    func scrape(playlistId: String) async throws -> SpotifyScrapeResult {
        self.playlistId = playlistId
        self.contentType = .playlist
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.startPlayer()
        }
    }

    func scrapeAlbum(albumId: String) async throws -> SpotifyScrapeResult {
        self.playlistId = albumId  // reuse the field for ID
        self.contentType = .album
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.startPlayer()
        }
    }

    // MARK: - Web-player path

    private func startPlayer() {
        let controller = WKUserContentController()
        controller.add(self, name: "spotify")
        controller.addUserScript(
            WKUserScript(source: Self.injectedJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.customUserAgent = desktopUA
        wv.alpha = 0.01
        attachOffscreen(wv)
        self.webView = wv

        if contentType == .playlist {
            if let url = URL(string: "https://open.spotify.com/playlist/\(playlistId)") {
                dbg("loading player \(url.absoluteString)")
                wv.load(URLRequest(url: url))
            }
        } else {
            // For albums, use embed for more reliable data extraction
            usedEmbedFallback = true
            if let url = URL(string: "https://open.spotify.com/embed/album/\(playlistId)") {
                dbg("loading embed album \(url.absoluteString)")
                wv.load(URLRequest(url: url))
            }
            // Schedule direct read for embed album
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.readEmbed()
            }
        }

        // Overall safety net: if the player path stalls, fall back / finish.
        // For albums we wait a bit longer because their data can load more lazily.
        let timeoutNs: UInt64 = (contentType == .album) ? 55_000_000_000 : 45_000_000_000
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard let self, !self.finished else { return }
            self.dbg("timeout fired; ordered=\(self.ordered.count)")
            if self.ordered.isEmpty { self.tryEmbedFallback() }
            else { self.finish() }
        }
    }

    /// WebKit's background JS timers are more reliable when the view is in a
    /// window, so park it offscreen at 1×1 instead of leaving it detached.
    private func attachOffscreen(_ wv: WKWebView) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        if let window = scene?.windows.first {
            window.addSubview(wv)
        }
    }

    // MARK: - JS → native messages

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }

        switch type {
        case "dbg":
            if let msg = dict["msg"] as? String { dbg("js: \(msg)") }
        case "meta":
            if let total = dict["total"] as? Int, total > 0 { expectedTotal = total }
            dbg("meta total=\(expectedTotal)")
        case "page":
            if let payload = dict["payload"] as? String {
                let before = ordered.count
                ingest(payload)
                dbg("page +\(ordered.count - before) (total so far \(ordered.count)/\(expectedTotal))")
            }
        case "complete":
            dbg("complete; ordered=\(ordered.count)")
            finish()
        case "empty", "error":
            dbg("\(type) received; ordered=\(ordered.count) → \(ordered.isEmpty ? "embed fallback" : "finish")")
            if ordered.isEmpty { tryEmbedFallback() } else { finish() }
        default:
            break
        }
    }

    private func ingest(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }

        if expectedTotal == 0, let total = Self.findTotal(obj) { expectedTotal = total }

        if playlistName == nil || playlistCoverURL == nil {
            let meta = Self.extractMeta(obj)
            if playlistName == nil { playlistName = meta.name }
            if playlistCoverURL == nil { playlistCoverURL = meta.cover }
        }

        for t in Self.extractTracks(obj) {
            let key = t.uri.isEmpty ? "\(t.title)|\(t.artist)|\(Int(t.durationSec))" : t.uri
            if seen.insert(key).inserted { ordered.append(t) }
        }

        if expectedTotal > 0, ordered.count >= expectedTotal { finish() }
    }

    // MARK: - Embed fallback (__NEXT_DATA__)

    private func tryEmbedFallback() {
        guard !usedEmbedFallback, !finished else {
            if !finished { finish() }
            return
        }
        usedEmbedFallback = true
        dbg("→ embed fallback")
        teardownWebView()

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                           configuration: WKWebViewConfiguration())
        wv.customUserAgent = desktopUA
        wv.alpha = 0.01
        attachOffscreen(wv)
        self.webView = wv

        let embedPath = contentType == .playlist ? "playlist" : "album"
        if let url = URL(string: "https://open.spotify.com/embed/\(embedPath)/\(playlistId)") {
            wv.load(URLRequest(url: url))
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000) // give embed a bit more time
            await self?.readEmbed()
        }
    }

    private func readEmbed() async {
        guard !finished, let wv = webView else {
            if !finished { finish() }
            return
        }
        let js = "var e=document.getElementById('__NEXT_DATA__'); e ? e.textContent : ''"
        let result = try? await wv.evaluateJavaScript(js)
        let s = (result as? String) ?? ""
        dbg("embed __NEXT_DATA__ length=\(s.count)")
        if !s.isEmpty,
           let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            let embedTracks = Self.extractEmbedTracks(obj)
            dbg("embed parsed \(embedTracks.count) tracks")
            for t in embedTracks {
                let key = t.uri.isEmpty ? "\(t.title)|\(t.artist)" : t.uri
                if seen.insert(key).inserted { ordered.append(t) }
            }
            let meta = Self.extractEmbedMeta(obj)
            if playlistName == nil { playlistName = meta.name }
            if playlistCoverURL == nil { playlistCoverURL = meta.cover }
        }
        finish()
    }

    // MARK: - Completion

    private func finish() {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        teardownWebView()
        let result = SpotifyScrapeResult(name: playlistName,
                                         coverURL: playlistCoverURL,
                                         tracks: ordered)
        dbg("finish name=\(playlistName ?? "nil") cover=\(playlistCoverURL != nil) tracks=\(ordered.count)")
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func teardownWebView() {
        webView?.stopLoading()
        let ucc = webView?.configuration.userContentController
        ucc?.removeAllUserScripts()
        ucc?.removeScriptMessageHandler(forName: "spotify")
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: - JSON extraction (pathfinder)

    static func extractTracks(_ root: Any) -> [SpotifyScrapedTrack] {
        var out: [SpotifyScrapedTrack] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                // Support Playlist tracks, Album tracks, and generic track objects
                let tn = d["__typename"] as? String
                if tn == "Track" || tn == "AlbumTrack" || tn?.hasSuffix("Track") == true {
                    if let t = parseTrack(d) { out.append(t) }
                } else if let track = d["track"] as? [String: Any], let t = parseTrack(track) {
                    out.append(t)
                } else if let track = d["item"] as? [String: Any], let t = parseTrack(track) {
                    out.append(t)
                } else if let t = parseTrack(d) {  // last resort if it looks like a track
                    // only if it has name + artists to avoid false positives
                    if d["name"] != nil && (d["artists"] != nil || d["artist"] != nil) {
                        out.append(t)
                    }
                }
                for (_, v) in d { walk(v) }
            } else if let a = node as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(root)
        return out
    }

    /// Pull the playlist's own name + cover from a pathfinder response. The
    /// playlist node is the dict whose `__typename` is `Playlist` (it also
    /// carries the `name`, `images`/`coverArt` we want — Track nodes have a
    /// `name` too, so we must key off the typename).
    static func extractMeta(_ root: Any) -> (name: String?, cover: String?) {
        var name: String? = nil
        var cover: String? = nil
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let tn = d["__typename"] as? String,
                   tn == "Playlist" || tn == "PlaylistV2" || tn == "PseudoPlaylist" || tn == "Album" {
                    if name == nil, let n = d["name"] as? String, !n.isEmpty { name = n }
                    if cover == nil, let c = coverFrom(d) { cover = c }
                }
                for (_, v) in d { walk(v) }
            } else if let a = node as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(root)
        return (name, cover)
    }

    /// Largest-resolution image URL from an `images.items[].sources[]` or a
    /// `coverArt.sources[]` shape.
    private static func coverFrom(_ d: [String: Any]) -> String? {
        func best(_ sources: [[String: Any]]) -> String? {
            let scored = sources.compactMap { s -> (Int, String)? in
                guard let u = s["url"] as? String, !u.isEmpty else { return nil }
                let w = (s["width"] as? Int) ?? (s["width"] as? Double).map(Int.init) ?? 0
                return (w, u)
            }
            return scored.max(by: { $0.0 < $1.0 })?.1
        }
        if let images = d["images"] as? [String: Any],
           let items = images["items"] as? [[String: Any]],
           let first = items.first,
           let sources = first["sources"] as? [[String: Any]],
           let url = best(sources) { return url }
        if let coverArt = d["coverArt"] as? [String: Any],
           let sources = coverArt["sources"] as? [[String: Any]],
           let url = best(sources) { return url }
        return nil
    }

    private static func parseTrack(_ d: [String: Any]) -> SpotifyScrapedTrack? {
        guard let title = d["name"] as? String, !title.isEmpty else { return nil }
        let uri = (d["uri"] as? String) ?? ""

        var durSec = 0.0
        if let td = d["trackDuration"] as? [String: Any] {
            if let ms = td["totalMilliseconds"] as? Double, ms.isFinite {
                durSec = ms / 1000
            } else if let ms = td["totalMilliseconds"] as? Int {
                durSec = Double(ms) / 1000
            }
        }
        if !durSec.isFinite { durSec = 0.0 }

        var artist = ""
        if let artists = d["artists"] as? [String: Any],
           let items = artists["items"] as? [[String: Any]] {
            let names = items.compactMap { ($0["profile"] as? [String: Any])?["name"] as? String }
            artist = names.joined(separator: ", ")
        }

        return SpotifyScrapedTrack(uri: uri, title: title, artist: artist, durationSec: durSec)
    }

    private static func findTotal(_ root: Any) -> Int? {
        func intVal(_ v: Any?) -> Int? {
            if let n = v as? Int { return n }
            if let n = v as? Double { return Int(n) }
            return nil
        }
        // The track-list node looks like `{ items: [...], totalCount: 340 }`.
        // Prefer the totalCount sitting next to an `items` array — other
        // totalCounts (followers, sub-lists) can be misleadingly small.
        var best: Int? = nil
        func walk(_ node: Any, requireItems: Bool) {
            if let d = node as? [String: Any] {
                if let t = intVal(d["totalCount"]), !requireItems || d["items"] is [Any] {
                    if best == nil || t > best! { best = t }
                }
                for (_, v) in d { walk(v, requireItems: requireItems) }
            } else if let a = node as? [Any] {
                for v in a { walk(v, requireItems: requireItems) }
            }
        }
        walk(root, requireItems: true)
        if best != nil { return best }
        walk(root, requireItems: false)   // fallback: largest totalCount anywhere
        return best
    }

    // MARK: - JSON extraction (embed __NEXT_DATA__)

    static func extractEmbedTracks(_ root: Any) -> [SpotifyScrapedTrack] {
        var out: [SpotifyScrapedTrack] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let list = d["trackList"] as? [[String: Any]] {
                    for item in list {
                        guard let title = item["title"] as? String, !title.isEmpty else { continue }
                        let uri = (item["uri"] as? String) ?? ""
                        let artist = (item["subtitle"] as? String) ?? (item["artist"] as? String) ?? ""
                        var dur = 0.0
                        if let ms = item["duration"] as? Double, ms.isFinite { dur = ms / 1000 }
                        else if let ms = item["duration"] as? Int { dur = Double(ms) / 1000 }
                        else if let ms = item["trackDuration"] as? Double, ms.isFinite { dur = ms / 1000 }
                        if !dur.isFinite { dur = 0.0 }
                        out.append(SpotifyScrapedTrack(uri: uri, title: title, artist: artist, durationSec: dur))
                    }
                }
                for (_, v) in d { walk(v) }
            } else if let a = node as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(root)
        return out
    }

    /// Name + cover from the embed `__NEXT_DATA__` — the "entity" dict carries
    /// `name`, `coverArt`/`images`, and `trackList` together.
    static func extractEmbedMeta(_ root: Any) -> (name: String?, cover: String?) {
        var name: String? = nil
        var cover: String? = nil
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if d["trackList"] is [Any] || d["coverArt"] != nil || d["tracks"] != nil {
                    if name == nil, let n = d["name"] as? String, !n.isEmpty { name = n }
                    if cover == nil, let c = coverFrom(d) { cover = c }
                }
                for (_, v) in d { walk(v) }
            } else if let a = node as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(root)
        return (name, cover)
    }

    // MARK: - Injected JavaScript

    private static let injectedJS = """
    "use strict";
    (function () {
      var TEMPLATE = null;
      var started = false;

      function post(obj) {
        try { window.webkit.messageHandlers.spotify.postMessage(obj); } catch (e) {}
      }

      function headersToObj(h) {
        var o = {};
        if (!h) return o;
        if (typeof h.forEach === "function") { h.forEach(function (v, k) { o[k] = v; }); }
        else if (typeof h === "object") { for (var k in h) { o[k] = h[k]; } }
        return o;
      }

      function dbg(msg) { post({ type: "dbg", msg: String(msg) }); }

      function isPathfinder(url) {
        return String(url || "").indexOf("pathfinder") !== -1;
      }

      function opNameOf(url, body) {
        try {
          var u = new URL(String(url));
          var op = u.searchParams.get("operationName");
          if (op) return op;
        } catch (e) {}
        if (body) {
          var m = String(body).match(/"operationName"\\s*:\\s*"([^"]+)"/);
          if (m) return m[1];
        }
        return "";
      }

      function findTotal(root) {
        var best = 0;
        (function walk(n) {
          if (Array.isArray(n)) { for (var i = 0; i < n.length; i++) walk(n[i]); }
          else if (n && typeof n === "object") {
            if (Array.isArray(n.items) && typeof n.totalCount === "number" && n.totalCount > best) best = n.totalCount;
            for (var k in n) walk(n[k]);
          }
        })(root);
        if (best > 0) return best;
        (function walk2(n) {
          if (Array.isArray(n)) { for (var i = 0; i < n.length; i++) walk2(n[i]); }
          else if (n && typeof n === "object") {
            if (typeof n.totalCount === "number" && n.totalCount > best) best = n.totalCount;
            for (var k in n) walk2(n[k]);
          }
        })(root);
        return best;
      }

      function countTracks(node) {
        var c = 0;
        (function walk(n) {
          if (Array.isArray(n)) { for (var i = 0; i < n.length; i++) walk(n[i]); }
          else if (n && typeof n === "object") {
            if (n.__typename === "Track" || n.__typename === "AlbumTrack" || (n.__typename && n.__typename.endsWith("Track"))) c++;
            // Also count generic track shapes often present in album responses
            else if (n.name && (n.artists || n.artist || n.track)) c++;
            for (var k in n) walk(n[k]);
          }
        })(node);
        return c;
      }

      function buildRequest(template, offset, limit) {
        var method = (template.method || "GET").toUpperCase();
        if (method === "POST" && template.body) {
          var b = JSON.parse(template.body);
          var v = b.variables || b;
          v.offset = offset; v.limit = limit;
          return { url: template.url,
                   init: { method: "POST", headers: template.headers,
                           body: JSON.stringify(b), credentials: "include" } };
        }
        var url = new URL(template.url);
        var vs = url.searchParams.get("variables");
        var vv = vs ? JSON.parse(vs) : {};
        vv.offset = offset; vv.limit = limit;
        url.searchParams.set("variables", JSON.stringify(vv));
        return { url: url.toString(),
                 init: { method: "GET", headers: template.headers, credentials: "include" } };
      }

      async function paginate(firstJson, firstCount) {
        if (started) return; started = true;
        var total = findTotal(firstJson) || 0;
        post({ type: "meta", total: total });
        dbg("paginate start total=" + total + " firstCount=" + firstCount);

        var limit = 100;
        var off = firstCount > 0 ? firstCount : 0;   // first page already ingested
        if (total > 0 && off >= total) { post({ type: "complete" }); return; }

        while (true) {
          try {
            var rq = buildRequest(TEMPLATE, off, limit);
            var resp = await fetch(rq.url, rq.init);
            var txt = await resp.text();
            var n = countTracks(JSON.parse(txt));
            dbg("page off=" + off + " n=" + n + " len=" + txt.length);
            post({ type: "page", payload: txt });
            if (n === 0) break;
            off += n;                       // advance by what we actually got
            if (total > 0 && off >= total) break;
            if (off > 10000) break;         // hard safety cap
          } catch (e) { dbg("page error " + e); break; }
        }
        post({ type: "complete" });
      }

      // Inspect a captured pathfinder response; adopt it as the paging template
      // the first time we see one that actually carries tracks.
      function consider(url, method, headers, body, text) {
        if (!text) return;
        var op = opNameOf(url, body);
        var json; try { json = JSON.parse(text); } catch (e) { return; }
        var n = countTracks(json);
        var tot = findTotal(json);
        dbg("PF op=" + op + " tracks=" + n + " total=" + tot + " len=" + text.length);
        if (TEMPLATE || n === 0) return;          // need a track-bearing response
        TEMPLATE = { url: String(url), method: method || "GET",
                     headers: headers || {}, body: body ? String(body) : null };
        dbg("TEMPLATE op=" + op + " " + TEMPLATE.method + " " + TEMPLATE.url.slice(0, 160));
        post({ type: "page", payload: text });    // ingest first page
        paginate(json, n);
      }

      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = (typeof input === "string") ? input : (input && input.url);
        var body = init && init.body;
        var p = origFetch.apply(this, arguments);
        try {
          if (isPathfinder(url) && !TEMPLATE) {
            p.then(function (resp) {
              try {
                resp.clone().text().then(function (t) {
                  consider(url, (init && init.method) || "GET",
                           headersToObj(init && init.headers), body, t);
                });
              } catch (e) {}
            });
          }
        } catch (e) {}
        return p;
      };

      var OrigOpen = XMLHttpRequest.prototype.open;
      var OrigSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) {
        this.__url = u; this.__method = m;
        return OrigOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (b) {
        var self = this;
        this.addEventListener("load", function () {
          try {
            if (isPathfinder(self.__url) && !TEMPLATE) {
              consider(self.__url, self.__method || "GET", {}, b, self.responseText || "");
            }
          } catch (e) {}
        });
        return OrigSend.apply(this, arguments);
      };

      // Nothing usable captured in time → let native fall back to the embed.
      // Increased to give the modern Spotify web player more time to init pathfinder requests.
      setTimeout(function () { if (!TEMPLATE) post({ type: "empty" }); }, 18000);

      // Extra safety: for album pages, force extraction from common globals (NEXT_DATA, apollo, etc.)
      // This helps when pathfinder interception misses album-specific responses.
      setTimeout(function() {
        try {
          var candidates = [window.__NEXT_DATA__, window.__APOLLO_STATE__, window.__SPOTIFY__];
          for (var i = 0; i < candidates.length; i++) {
            var data = candidates[i];
            if (data && countTracks(data) > 0) {
              post({ type: "page", payload: JSON.stringify(data) });
              break;
            }
          }
        } catch(e) {}
      }, 7000);
    })();
    """
}
