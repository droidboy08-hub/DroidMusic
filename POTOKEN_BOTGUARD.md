# PO Token via BotGuard — Research & Implementation

**Date:** 2026-07-02
**Files:** `musicplayer/PoTokenMinter.swift`, `musicplayer/SessionBootstrap.swift`, `musicplayer/InnerTubeAPI.swift`
**Status:** Implemented & verified (`🟢 [InnerTube/ANDROID] picked itag=18`)
**References studied:** [NewPipe](https://github.com/TeamNewPipe/NewPipe) `app/src/main/java/org/schabi/newpipe/util/potoken/*`, [yt-dlp](https://github.com/yt-dlp/yt-dlp) `yt_dlp/extractor/youtube/pot/`, [bgutils-js](https://github.com/LuanRT/BgUtils)

---

## 1. What a PO token is

A **Proof-of-Origin (PO) token** is a session-bound attestation YouTube requires on
streaming requests to prove the client is a "real" origin and not a bot. Without
it, most InnerTube clients (`ANDROID`, `MWEB`, `WEB*`) return non-playable
responses or throttled/expiring stream URLs. `ANDROID_VR` is currently exempt,
which is why it's our zero-token fallback.

The token is produced by **BotGuard** — Google's attestation VM
(`jnn-pa.googleapis.com` / `youtube.com/api/jnn/*`) that runs a challenge program
in a JS engine and emits a signed token bound to a **visitorData** identity.

Where it's consumed:
- InnerTube `/player` request body → `serviceIntegrityDimensions.poToken`
- The streaming (`videoplayback`) URL → `&pot=<token>` (GVS token)

---

## 2. The dead-end approach we abandoned

Our first minter loaded a real YouTube **watch page** in a hidden `WKWebView`,
played the seed video muted, and scraped `pot=` off the outgoing requests.

Why it failed on iOS:
- **Hidden/detached `WKWebView` suspends its media pipeline** → the seed never
  buffered (`readyState=0`) → no requests → no token. Attaching it to the window
  fixed playback but caused an **audible video leak** (Rick Astley on launch).
- **iOS routes `<video>` media through the native AVFoundation stack**, which is
  invisible to JS `fetch`/XHR hooks *and* to `performance` resource-timing. The
  GVS `pot=` on the media URL is therefore **unobservable** from the page on iOS.
- The mobile watch page **server-injects `ytInitialPlayerResponse`** and makes
  **zero** client `/player` calls (`plReq=0`), so no request body carried a pot.
- The desktop UA path *did* work intermittently but was slow (~30 s, needed 3
  seed videos) and still played audio.

Verdict: scraping a playing video is the wrong tool. Both NewPipe and yt-dlp
never play a video — they run BotGuard **directly**.

---

## 3. The implemented approach — BotGuard direct

No video, no watch page, no audio, no window attachment. A tiny local HTML page
holds only the BotGuard interpreter; all networking is done natively.

```
┌─ Native (Swift, URLSession) ──────────────────────────────────────────┐
│ 1. POST youtube.com/api/jnn/v1/Create      body ["<requestKey>"]        │
│    headers: Content-Type application/json+protobuf,                     │
│             x-goog-api-key, x-user-agent grpc-web-javascript/0.1        │
│    → BotGuard challenge (scrambled)                                     │
└────────────────────────────────────────────────────────────────────────┘
┌─ WebView JS (callAsyncJavaScript, awaits the promise) ─────────────────┐
│ 2. runBotGuard(challenge)                                               │
│    → { botguardResponse, webPoSignalOutput }                           │
└────────────────────────────────────────────────────────────────────────┘
┌─ Native ──────────────────────────────────────────────────────────────┐
│ 3. POST /api/jnn/v1/GenerateIT  body ["<requestKey>","<botguardResp>"] │
│    → { integrityToken, ttlSeconds }                                     │
└────────────────────────────────────────────────────────────────────────┘
┌─ WebView JS ──────────────────────────────────────────────────────────┐
│ 4. obtainPoToken(webPoSignalOutput, integrityToken, u8(visitorData))   │
│    → Uint8Array → base64url → THE POT                                   │
└────────────────────────────────────────────────────────────────────────┘
```

**Why `callAsyncJavaScript`:** unlike `evaluateJavaScript`, it awaits JS promises
natively, so `await runBotGuard(...)` returns the resolved result directly — no
message-handler round trips. Args are passed as typed values (byte arrays →
`new Uint8Array(...)`), avoiding string-escaping bugs.

### Constants (public BotGuard values)
| Name | Value |
|---|---|
| `apiKey` | `AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw` |
| `requestKey` | `O43z0dpjhgX20SCx4KAo` |
| User-Agent | Chrome 131 on Windows |
| Create | `https://www.youtube.com/api/jnn/v1/Create` |
| GenerateIT | `https://www.youtube.com/api/jnn/v1/GenerateIT` |

### The interpreter (`loadBotGuard` / `snapshot` / `runBotGuard` / `obtainPoToken`)
Embedded as a Swift string, loaded via `loadHTMLString(baseURL: youtube.com)`.
Uses `globalThis` (not `this`) so it's strict-mode-safe. `runBotGuard` evals the
challenge's interpreter JS (`new Function(js)()`), loads the VM, takes a snapshot;
`obtainPoToken` calls the minter returned by `webPoSignalOutput[0](integrityToken)`.

---

## 4. Token lifecycle & future-proofing ⭐

This is the part that keeps it working over time. **Two tiers:**

### Tier 1 — Attestation (expensive, ~once per 6 h)
`Create → runBotGuard → GenerateIT` yields an **integrityToken** with a stated
TTL. Observed reality (from both references):

- GenerateIT states the TTL as roughly **12 hours** (43200 s).
- yt-dlp conservatively caps reuse at **6 hours** (`webpo_cachespec.py` →
  `default_ttl=21600`).
- NewPipe reads the real TTL and subtracts a **10-minute safety margin**
  (`expiry = now + (ttl - 600)`), so it never hands out a near-dead token.

Our implementation combines both:
```
reuse = max( min(ttl - 600, 21600), 300 )   // 10-min margin, cap 6h, floor 5m
attestationExpiry = now + reuse
```

### Tier 2 — Minting (cheap, on demand)
While the integrityToken is valid, `obtainPoToken(identifier)` is **pure JS, no
network**, and can be run for any identifier repeatedly. So generating/refreshing
the actual pot is essentially free until the attestation expires.

### Refresh strategy
| Trigger | Action |
|---|---|
| Cold start (no token) | Attest once, mint, bind to session |
| Cached token still valid | Reuse (no attestation, no mint) |
| 30-min background loop | `ensureValidToken()` — re-attests only if past `attestationExpiry` |
| Attestation expired | Re-run tiers 1+2 |
| **ANDROID rejects mid-playback** | `refreshPoTokenNow(force:)` → forced re-attest + retry (InnerTubeAPI) |
| App backgrounded / WebView lost | Next call re-attests from scratch |

### Binding (why it validates now)
The pot is bound to a **visitorData**. Previously the minter had its *own*
visitorData (`vd differs`), so the token didn't match our InnerTube requests.
Now `ensureValidToken(visitorData:)` binds to the **exact visitorData
SessionBootstrap holds**, and InnerTube sends that same `poTokenVisitorData` for
pot-requiring clients (`InnerTubeAPI.effectiveVisitorData`). No mismatch possible.

yt-dlp's cache key confirms the binding dimensions: `cb` (content binding =
visitorData when `bind_to_visitor_id=true`), `cbt` (type), plus IP / proxy /
source-address. Since we're a single on-device client, visitorData is the only
one that varies.

---

## 5. Client strategy (unchanged, still correct)

Playback order (`InnerTubeAPI.playbackClientOrder`) is event-driven, not
time-based:

1. **Cold start, no token** → `ANDROID_VR` plays instantly (needs no pot).
2. **Background mint lands a token** → next song prefers `ANDROID` (more robust
   long-term; plays kids content; avoids VR SABR risk), `VR` stays right behind.
3. **Any ANDROID failure** → force re-mint + retry, else fall through to `VR`.

`VR` is never removed, so playback is never blocked while a token mints.

---

## 6. iOS-specific gotchas (recorded so we don't rediscover them)

- A hidden/detached `WKWebView` **suspends media** — irrelevant now (no media),
  but it's why the old approach failed.
- `<video>` network traffic is **invisible to JS** on iOS — never rely on
  scraping media URLs for a pot on this platform.
- `callAsyncJavaScript` requires the code to run in a consistent `contentWorld`
  (`.page`) so `globalThis.integrityToken` / `webPoSignalOutput` persist between
  calls.
- YouTube's base64 is url-safe with `.` as padding: decode via
  `-→+ _→/ .→=`; encode the pot via `+→- /→_` (padding kept).

---

## 7. Files

| File | Role |
|---|---|
| `PoTokenMinter.swift` | BotGuard engine: interpreter HTML, 2 POSTs, parse/encode helpers, lifecycle/caching |
| `SessionBootstrap.swift` | Mints on bootstrap bound to session visitorData; 30-min refresh; force-refresh |
| `InnerTubeAPI.swift` | Sends `poToken` in body + `&pot=` on stream URL; `poTokenVisitorData` for pot clients; mid-playback retry |
| `DiagnosticsLog.swift` / `DiagnosticsView.swift` | On-device log buffer (Settings → Diagnostics) mirroring the `🔑`/`🟢` lines |
