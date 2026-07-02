# YouTube PO Token — Resilience & Refresh Hardening

Companion to [`POTOKEN.md`](POTOKEN.md). That doc explains *how the token is
minted and consumed*; this one explains *how we keep it alive and recover when it
dies*.

**Status:** Implemented, builds clean.
**Files:** `PoTokenMinter.swift`, `SessionBootstrap.swift`, `YouTubeSession.swift`,
`InnerTubeAPI.swift`

---

## Why — PO tokens are short-lived and fragile

A working token is not permanent. It stops working for four distinct reasons:

| # | Failure mode | What happens |
|---|---|---|
| 1 | **Token expiry** | YouTube invalidates a token after ~12–24 h (sometimes less). |
| 2 | **visitorData mismatch** | The token is minted for one `visitorData` but the request sends another → rejected. |
| 3 | **Session drift** | Cookies / STS / network fingerprint change overnight, so an old token no longer matches the session. |
| 4 | **Mint timing** | If the background refresh silently fails or the minter never ran, playback runs with a **stale or missing** token. |

The original build minted once + re-minted on a fixed 20-min timer. That's fine
while the app stays open, but it has no notion of *token age*, no recovery when a
token is **rejected mid-playback**, and it hammers a full WebView mint every 20
minutes forever. This pass fixes all three.

---

## Strategy — own the token's lifecycle

1. **Track age.** Every mint is stamped with `mintedAt`; the minter caches the
   last good token.
2. **Reuse when fresh, re-mint when stale.** `ensureValidToken()` returns the
   cache if it's younger than `staleAfter` (3 h), else it mints. Cheap on the hot
   path, proactive before expiry.
3. **Recover on rejection.** When the ANDROID client rejects a token
   (403 / non-200), force a fresh mint and **retry that client once** with the new
   token before falling through to `ANDROID_VR`.
4. **Bind strictly to visitorData.** The `(token, visitorData)` pair travels
   together through every retry, so a refreshed token never gets sent with the
   wrong `visitorData`.
5. **Survive bad mints.** Try several evergreen seed videos; on total failure keep
   the previous token rather than dropping to `nil`.
6. **Warm, don't hammer.** A 30-min timer calls `ensureValidToken()`, which only
   actually re-mints once the token is genuinely stale.

---

## The code

### 1 — Token + expiry + cache (`PoTokenMinter.swift`)

```swift
/// A PO token, the visitorData it is bound to, and when it was minted.
struct Minted {
    let value: String
    let visitorData: String
    let mintedAt: Date
    var age: TimeInterval { Date().timeIntervalSince(mintedAt) }
}

/// Re-mint proactively once a cached token is older than this. Kept well under
/// YouTube's ~12–24 h invalidation window so we never hand out a near-dead one.
private static let staleAfter: TimeInterval = 3 * 3600

/// Last successfully minted token (with the visitorData it's bound to).
private(set) var current: Minted?
```

### 2 — `ensureValidToken` + seed-list retry

```swift
/// Returns a valid token, re-minting only when we don't have one, the cached
/// one has aged past `staleAfter`, or `force` is set. Cheap on the common path.
func ensureValidToken(force: Bool = false) async -> Minted? {
    if !force, let c = current, c.age < Self.staleAfter {
        print("🔑 [PoToken] reuse cached (age \(Int(c.age))s, vd \(c.visitorData.prefix(10))…)")
        return c
    }
    if force { print("🔑 [PoToken] force re-mint requested") }
    return await mintWithRetry()
}

/// Evergreen, non-age-gated seeds. "Me at the zoo" (the first YouTube video) is
/// primary — it will never be removed and isn't age-restricted. The rest are
/// fallbacks tried in order if a mint attempt fails.
private static let seedVideoIds = ["jNQXAC9IVRw", "dQw4w9WgXcQ", "aqz-KE-bpKQ"]

/// Try each seed until one yields a token — a transient failure or a momentarily
/// bad seed shouldn't kill the whole mint.
private func mintWithRetry() async -> Minted? {
    for (i, seed) in Self.seedVideoIds.enumerated() {
        if let m = await mintOnce(seedVideoId: seed) {
            current = m
            print("🔑 [PoToken] minted ✓ (seed \(i + 1)/\(Self.seedVideoIds.count), vd \(m.visitorData.prefix(10))…)")
            return m
        }
        print("🔑 [PoToken] seed \(i + 1)/\(Self.seedVideoIds.count) (\(seed)) failed, trying next…")
    }
    print("🔑 [PoToken] all seeds failed ✗ (keeping \(current == nil ? "no" : "previous") token)")
    return current   // fall back to the last good token rather than nil-ing it
}
```

`mintOnce(seedVideoId:)` is the original WebView harvest (document-start
`fetch`/XHR hook + resource-timing sweep + nudge the muted video to `play()`),
now parameterised by seed and stamping `mintedAt: Date()`.

### 3 — Bootstrap, keep-warm, and force-refresh (`SessionBootstrap.swift`)

```swift
// After visitorData lands, mint once in the background (playback never waits).
private func mintPoTokenIfNeeded(visitorData vd: String) {
    guard poToken == nil else { return }
    let gen = bootstrapGeneration
    Task { [weak self] in
        let minted = await PoTokenMinter.shared.ensureValidToken()
        guard let self, let minted, self.bootstrapGeneration == gen else { return }
        self.poToken = minted.value
        self.poTokenVisitorData = minted.visitorData
        print("🔑 [PoToken] bound to session ✓ (mint vd \(minted.visitorData == vd ? "matches" : "differs"), age \(Int(minted.age))s)")
        self.schedulePoTokenRefresh()
    }
}

// Warm the token. ensureValidToken only re-mints once it's actually stale, so
// most 30-min ticks are a cheap no-op that just re-syncs the stored pair.
private func schedulePoTokenRefresh() {
    poTokenRefreshTask?.cancel()
    let gen = bootstrapGeneration
    poTokenRefreshTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30 * 60))
            guard let self, !Task.isCancelled, self.bootstrapGeneration == gen else { return }
            if let minted = await PoTokenMinter.shared.ensureValidToken(), self.bootstrapGeneration == gen {
                self.poToken = minted.value
                self.poTokenVisitorData = minted.visitorData
                print("🔑 [PoToken] periodic check ✓ (age \(Int(minted.age))s)")
            }
        }
    }
}

/// Force a fresh token now and adopt it — called by InnerTube when the ANDROID
/// client rejects the current token mid-playback (likely stale).
func refreshPoTokenNow() async -> (token: String, visitorData: String)? {
    guard let minted = await PoTokenMinter.shared.ensureValidToken(force: true) else { return nil }
    poToken = minted.value
    poTokenVisitorData = minted.visitorData
    print("🔑 [PoToken] force-refreshed ✓ (age \(Int(minted.age))s)")
    return (minted.value, minted.visitorData)
}
```

### 4 — Carry a refreshed token coherently (`YouTubeSession.swift`)

```swift
/// A copy carrying a freshly-minted PO token + its bound visitorData — used to
/// retry a pot client after the previous token was rejected.
nonisolated func withPoToken(_ token: String, visitorData boundVD: String) -> YouTubeSessionContext {
    YouTubeSessionContext(
        visitorData: visitorData, cookieHeader: cookieHeader, sapisid: sapisid,
        poToken: token, poTokenVisitorData: boundVD,
        dataSyncId: dataSyncId, clientVersion: clientVersion,
        signatureTimestamp: signatureTimestamp, appInstallData: appInstallData,
        coldConfigData: coldConfigData, coldHashData: coldHashData, hotHashData: hotHashData,
        deviceExperimentId: deviceExperimentId, rolloutToken: rolloutToken,
        clickTrackingParams: clickTrackingParams
    )
}
```

### 5 — Refresh-and-retry in the client cascade (`InnerTubeAPI.swift`)

```swift
var sessionCtx = ctx   // may adopt a refreshed pot token mid-cascade
enum Outcome { case ideal(Resolved); case fallback(Resolved); case failed }

func attempt(_ client: InnerTubeClient, _ c: YouTubeSessionContext) async -> Outcome { … }

for client in order {
    let cfg = client.config
    if cfg.requiresPoToken && sessionCtx.poToken == nil { continue }

    var outcome = await attempt(client, sessionCtx)

    // A pot client that failed with a token attached usually means the token was
    // rejected (stale/mismatched). Force one fresh mint and retry this client once
    // with it before falling through to ANDROID_VR.
    if case .failed = outcome, client.usesGvsPoToken, sessionCtx.poToken != nil {
        if let fresh = await SessionBootstrap.shared.refreshPoTokenNow() {
            sessionCtx = sessionCtx.withPoToken(fresh.token, visitorData: fresh.visitorData)
            print("🔁 [InnerTube/\(cfg.clientName)] retrying with refreshed poToken")
            outcome = await attempt(client, sessionCtx)
        }
    }

    switch outcome {
    case .ideal(let r):    return r
    case .fallback(let r): /* remember muxed/audio fallback */ break
    case .failed:          break
    }
}
```

Because `sessionCtx` is reassigned, a token refreshed for ANDROID is also used by
the next pot client (MWEB) in the same cascade.

---

## Failure mode → mitigation

| Failure | Mitigation |
|---|---|
| Token expiry | 3 h proactive staleness re-mint + force-refresh on rejection |
| visitorData mismatch | `(token, visitorData)` pair kept together; retry uses `withPoToken` |
| Session drift | On a 403, we re-mint against the *current* session and retry |
| Mint failed / never ran | Seed-list retry; keep last good token; VR fallback still plays |

---

## Design decisions (and why we deviated from the naïve version)

- **One retry with a *fresh* token, not 2–3 blind retries.** Retrying with the
  *same* rejected token can't succeed — the fix is a new token, so a single retry
  after a force-refresh is both sufficient and fast.
- **30-min check + 3 h staleness, not a 20-min hammer.** Loading a YouTube watch
  page in a hidden WebView every 20 minutes forever is wasteful and more
  fingerprintable. On-demand freshness (at point of use) + proactive staleness
  keeps the token valid with far fewer mints.
- **"Me at the zoo" as the primary seed.** The very first YouTube video: never
  removed, not age-gated. Rickroll + Big Buck Bunny are fallbacks.
- **Keep the last good token on total mint failure** instead of nil-ing it — a
  brief network blip shouldn't strip a still-valid token.

**Tradeoff:** the force-refresh + retry does a live re-mint (~a few seconds) on
the **rare** rejection path. It's bounded to once, and `ANDROID_VR` still catches
playback if it fails — everyday playback uses the cached token with zero delay.

---

## Log signatures

Healthy reuse:
```
🔑 [PoToken] reuse cached (age 512s, vd Cgs1aUx0bk…)
🟢 [InnerTube/ANDROID] picked itag=18 ratebypass=true
```

Recovery from a rejected token:
```
🔑 [InnerTube/ANDROID] attempt poToken=✓ vd=pot
🔴 [InnerTube/ANDROID] /player HTTP 403 (pot✓, vd=pot, N bytes)
🔑 [PoToken] force re-mint requested
🔑 [PoToken] minted ✓ (seed 1/3, vd Cgs1aUx0bk…)
🔁 [InnerTube/ANDROID] retrying with refreshed poToken
🟢 [InnerTube/ANDROID] picked itag=18 ratebypass=true
```

Periodic keep-warm:
```
🔑 [PoToken] periodic check ✓ (age 1804s)      ← every ~30 min, re-mints only if >3 h
```

---

## Tuning knobs

| Constant | File | Default | Effect |
|---|---|---|---|
| `staleAfter` | `PoTokenMinter` | `3 * 3600` | how old a cached token gets before proactive re-mint |
| refresh interval | `SessionBootstrap` | `30 * 60` | how often the keep-warm timer checks staleness |
| `seedVideoIds` | `PoTokenMinter` | 3 IDs | seed videos tried in order when minting |
| retry count | `InnerTubeAPI` | 1 | force-refresh retries per pot client before VR |
