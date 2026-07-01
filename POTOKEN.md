# YouTube PO Token — Implementation Guide (Auria / musicplayer)

**Status:** Working in this build. ANDROID InnerTube client plays with a real
WebPO token; ANDROID_VR remains the token-less fallback.
**Files:** `PoTokenMinter.swift` (new), `SessionBootstrap.swift`,
`YouTubeSession.swift`, `InnerTubeAPI.swift`

---

## TL;DR

Modern YouTube requires a **Proof-of-Origin (PO) token** on the `ANDROID` / `MWEB`
InnerTube clients. Without it the `/player` streaming URLs get `403`'d and the
plain `ANDROID` client returns a non-200 (`PlayerError.badResponse`, "error 2").

We don't reimplement BotGuard. We let **YouTube's own web player mint the token
inside a hidden `WKWebView`**, capture it off the player's network requests, bind
it to our session `visitorData`, and feed it to InnerTube — in the request body
*and* appended to the stream URL.

Data flow:

```
SessionBootstrap                PoTokenMinter                 InnerTubeAPI
(music.youtube.com WebView)     (m.youtube.com WebView)       (/player cascade)
        │                              │                            │
  harvest visitorData ───┐            │                            │
        │                └─ mint() ──▶ load watch page             │
        │                              run web player (BotGuard)   │
        │                              capture pot= + visitorData  │
        │           ◀── Minted(pot, visitorData) ─────────────────┘
   store poToken + poTokenVisitorData
        │
   Snapshot ─▶ YouTubeSessionContext ─▶ player():
                                          • body.serviceIntegrityDimensions.poToken
                                          • visitorData = poTokenVisitorData (pot clients)
                                          • stream URL += &pot=<token>
```

---

## 1. What a PO token is (and why the ANDROID client needed one)

A PO token is proof the request originates from a "real" client. YouTube's web
player generates it at runtime via **BotGuard** attestation (the
`jnn-pa.googleapis.com` service) and **appends it as `&pot=` to the
`videoplayback` requests** it makes at play time — it is *not* a page global and
it is *not* in `ytInitialPlayerResponse`.

Per yt-dlp's client policy table (`INNERTUBE_CLIENTS` in
`yt_dlp/extractor/youtube/_base.py`):

| Client | Streaming (GVS) PO token | Notes |
|---|---|---|
| `android_vr` | **not required** | why it works token-less; our fallback |
| `android` | **required** | needs `&pot=` on the URL |
| `mweb` / `web_music` | **required** | web-family |
| `ios` | required | (metadata-only here) |

Key fact that makes this feasible: a **WebPO token is bound to `visitorData`, not
to the client type** — so one WebPO token minted for our `visitorData` is
accepted by the `android` client too.

---

## 2. Getting the token — `PoTokenMinter.swift`

A hidden `WKWebView` loads a watch page for an evergreen seed video and lets the
web player mint a token. We capture it two ways (belt + suspenders):

1. A **document-start hook** wraps `fetch` / `XHR.open` / `sendBeacon` so any
   outgoing URL carrying `pot=` is recorded onto `window.__pot`.
2. A **resource-timing sweep** (`performance.getEntriesByType('resource')`) as a
   backup, which also catches media loaded via `video.src`.

We also read the page's `VISITOR_DATA` and return it *with* the token, so the
caller can use them as a coherent pair (the token is only valid for the exact
`visitorData` it was minted under).

```swift
@MainActor
final class PoTokenMinter: NSObject, WKNavigationDelegate {
    static let shared = PoTokenMinter()

    struct Minted { let value: String; let visitorData: String }

    private static let seedVideoId = "dQw4w9WgXcQ"   // evergreen, embeddable, not age-gated
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

    private let webView: WKWebView
    private var waiter: CheckedContinuation<Minted?, Never>?
    private var pollTask: Task<Void, Never>?

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []   // let the muted seed video autoplay
        let hook = WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(hook)
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
        pollTask?.cancel(); pollTask = nil
        if let pending = waiter { waiter = nil; pending.resume(returning: nil) }   // supersede in-flight
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
                    if let pot = await self.pollPot() { self.finish(pot); return }
                }
                self?.finish(nil)
            }
        }
        print(minted != nil ? "🔑 [PoToken] minted ✓" : "🔑 [PoToken] mint failed ✗")
        return minted
    }

    private func pollPot() async -> Minted? {
        // Nudge the (muted) player so it issues the videoplayback requests that carry
        // `pot=`, then read whatever the hook / resource-timing captured + visitorData.
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
                guard let dict = result as? [String: Any],
                      let pot = dict["pot"] as? String, !pot.isEmpty,
                      let vd = dict["visitorData"] as? String, !vd.isEmpty else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: Minted(value: pot, visitorData: vd))
            }
        }
    }

    private func finish(_ minted: Minted?) {
        pollTask?.cancel(); pollTask = nil
        webView.stopLoading()
        guard let w = waiter else { return }
        waiter = nil
        w.resume(returning: minted)
    }

    // WKNavigationDelegate failures resolve the waiter with nil (see source).
}
```

**Why capture from the network, not `ytInitialPlayerResponse`:** an earlier
attempt read `pot=` out of `ytInitialPlayerResponse.streamingData[].url` and it
was always empty — the web player appends `pot=` to the `videoplayback` request
*at play time*, so it only appears once the player actually starts buffering.
That's why we hook the network APIs and nudge the muted video to `play()`.

---

## 3. Minting + storing it — `SessionBootstrap.swift`

`SessionBootstrap` owns the session WebView (loads `music.youtube.com`, harvests
`visitorData`, cookies, STS). After `visitorData` lands, it kicks off the mint in
the background — **playback never waits on it** — and stores the token together
with the visitorData it's bound to.

```swift
private(set) var poToken: String?
/// The visitorData our PO token is bound to (from the minter's watch page; may
/// differ from `visitorData`). Pot-requiring clients must use this pairing.
private(set) var poTokenVisitorData: String?

private var poTokenRefreshTask: Task<Void, Never>?

// Called from webView(_:didFinish:) right after visitorData is harvested.
private func mintPoTokenIfNeeded(visitorData vd: String) {
    guard poToken == nil else { return }
    let gen = bootstrapGeneration
    Task { [weak self] in
        let minted = await PoTokenMinter.shared.mint()
        guard let self, let minted, self.bootstrapGeneration == gen else { return }
        self.poToken = minted.value
        self.poTokenVisitorData = minted.visitorData
        let same = minted.visitorData == vd
        print("🔑 [PoToken] bound to session ✓ (visitorData \(same ? "matches" : "differs"))")
        self.schedulePoTokenRefresh()
    }
}

/// PO tokens go stale, so re-mint every 20 min to keep the ANDROID/MWEB clients
/// supplied with a valid token. Reschedules itself; cancelled on `refresh()`.
private func schedulePoTokenRefresh() {
    poTokenRefreshTask?.cancel()
    let gen = bootstrapGeneration
    poTokenRefreshTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(20 * 60))
        guard let self, !Task.isCancelled, self.bootstrapGeneration == gen else { return }
        print("🔑 [PoToken] refreshing (periodic)…")
        if let minted = await PoTokenMinter.shared.mint(), self.bootstrapGeneration == gen {
            self.poToken = minted.value
            self.poTokenVisitorData = minted.visitorData
            print("🔑 [PoToken] refreshed ✓")
        } else {
            print("🔑 [PoToken] refresh failed ✗")
        }
        if self.bootstrapGeneration == gen { self.schedulePoTokenRefresh() }
    }
}
```

Both values are exposed on `Snapshot` and reset in `refresh()` (which also
cancels `poTokenRefreshTask`).

---

## 4. Carried in the session context — `YouTubeSession.swift`

```swift
struct YouTubeSessionContext {
    let visitorData: String
    let poToken: String?
    /// The visitorData the PO token is bound to — pot-requiring clients must send
    /// this (not `visitorData`) so the token validates. nil when no token.
    let poTokenVisitorData: String?
    // …cookies, sapisid, STS, etc.
}

// YouTubeSession.build() copies snapshot.poToken / snapshot.poTokenVisitorData in.
```

---

## 5. Consumed by InnerTube — `InnerTubeAPI.swift`

### 5a. Client order — ANDROID+pot preferred, VR fallback

```swift
private func playbackClientOrder(session ctx: YouTubeSessionContext) -> [InnerTubeClient] {
    var order: [InnerTubeClient] = []
    if ctx.poToken != nil { order.append(.android) }   // pot-backed primary
    order.append(.androidVR)                            // token-less fallback (itag18 ratebypass)
    if ctx.poToken != nil { order.append(.mweb) }
    if ctx.isAuthenticated { order.append(.webRemix) }
    order += [.androidMusic, .tvEmbedded]
    return order
}
```

On a **cold start** the token isn't minted yet, so `.android` is omitted and
track 1 plays via `.androidVR`. Once the token is bound, track 2+ go
`.android` first.

### 5b. Which clients need `&pot=` on the URL

```swift
// InnerTubeClient
var usesGvsPoToken: Bool {
    switch self {
    case .mweb, .android, .webRemix, .androidMusic: return true
    case .androidVR, .ios, .tvEmbedded: return false   // VR/TV never take a pot
    }
}
```

### 5c. In the `/player` request — body token + bound visitorData

```swift
// Pot-requiring clients must send the visitorData the token is bound to,
// else the pot is rejected. Others (notably ANDROID_VR) keep the session one.
let effectiveVisitorData = (client.usesGvsPoToken ? ctx.poTokenVisitorData : nil) ?? ctx.visitorData
clientDict["visitorData"] = effectiveVisitorData
// …
if let poToken = ctx.poToken {
    generic["serviceIntegrityDimensions"] = ["poToken": poToken]
}
// header matches the body:
request.setValue(effectiveVisitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
```

### 5d. On the stream URL — append `&pot=`

```swift
// In parseStreamFormats(…, poToken:) — append pot only for GVS-pot clients.
func withPot(_ urlStr: String) -> String {
    guard let poToken, client.usesGvsPoToken, !urlStr.contains("pot=") else { return urlStr }
    let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let encoded = poToken.addingPercentEncoding(withAllowedCharacters: unreserved) ?? poToken
    return urlStr + (urlStr.contains("?") ? "&" : "?") + "pot=" + encoded
}
// applied to the chosen itag-18 / audio URL before building `Resolved`.
```

### 5e. Diagnostics

```swift
// per attempt (GVS-pot clients):
🔑 [InnerTube/ANDROID] attempt poToken=✓ vd=pot
// on /player failure:
🔴 [InnerTube/ANDROID] /player HTTP 403 (pot✗, vd=session, N bytes)
```

Also `ANDROID` client version was bumped to **21.02.35** (matching yt-dlp); the
old `19.17.34` was itself a reason for non-200s.

---

## 6. Why it succeeds in this build

1. **We don't fight BotGuard** — YouTube's own web player mints the token; we just
   harvest it. No fragile attestation port.
2. **Right source** — we read `pot=` off the player's live `videoplayback`
   requests (network hook + resource-timing), where the token actually lives —
   not from page globals or `ytInitialPlayerResponse` (always empty).
3. **Coherent `(visitorData, pot)` pair** — a token is cryptographically bound to
   one exact `visitorData`. The minter runs on `m.youtube.com` and can produce a
   *different* `visitorData` than the session's `music.youtube.com` one, so we
   carry the minter's visitorData with the token and send **that** for the pot
   clients. No bind mismatch.
4. **ANDROID is a clean match** — the `android` client sends **no web cookies**,
   so its request is exactly `visitorData` + `pot`, both from the minter → the
   token validates.
5. **Token in both places** — `serviceIntegrityDimensions.poToken` in the body
   *and* `&pot=` on the stream URL (GVS policy needs the URL one).
6. **Fresh** — re-minted every 20 min so it never expires mid-session.
7. **Never breaks playback** — `ANDROID_VR` is always in the order as a token-less
   fallback returning itag18 + ratebypass, so if a mint fails or ANDROID is
   rejected, playback still lands.

---

## 7. Verifying in the logs

Healthy session (2nd track onward):

```
🔑 [PoToken] minting via watch page…
🔑 [PoToken] minted ✓
🔑 [PoToken] bound to session ✓ (visitorData differs)
🔑 [InnerTube/ANDROID] attempt poToken=✓ vd=pot
🟢 [InnerTube/ANDROID] picked itag=18 hasVideo=true ratebypass=true
…
🔑 [PoToken] refreshing (periodic)…      ← ~every 20 min
🔑 [PoToken] refreshed ✓
```

If you instead see `🔑 [PoToken] mint failed ✗` → `poToken=✗` → the run falls back
to `ANDROID_VR` (still plays). If you see `🔴 … /player HTTP 40x` the token was
attached but rejected (usually stale/mismatched) — the next refresh recovers it.

---

## 8. Notes / limitations

- Requires iOS 17+ APIs used elsewhere; the WebView/JS approach itself is broadly
  compatible.
- The seed video (`dQw4w9WgXcQ`) is only used to spin up the player; it's never
  shown or heard (hidden, muted, ~0 alpha).
- `ANDROID_VR` can't play "made for kids" videos and may go SABR-only on client
  versions > 1.65 — the main reason we prefer real `ANDROID` once a token exists.
- This is a **WebPO** token. It is *not* a DroidGuard/Play-Integrity token; it
  works for `android` here because YouTube accepts a visitorData-bound WebPO for
  that client (consistent with yt-dlp's behaviour).
