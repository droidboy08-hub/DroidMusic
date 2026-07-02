import Foundation
import WebKit
import CommonCrypto

// MARK: - Coherent YouTube session (visitorData + cookies + poToken)
//
// Detection triggers when visitorData, cookies, and poToken don't match.
// Everything here is harvested from the same WKWebView session.

struct YouTubeSessionContext {
    let visitorData: String
    let cookieHeader: String?
    let sapisid: String?
    let poToken: String?
    /// The visitorData the PO token is bound to — pot-requiring clients must send
    /// this (not `visitorData`) so the token validates. nil when no token.
    let poTokenVisitorData: String?
    let dataSyncId: String?
    let clientVersion: String?
    /// Player STS — used in playbackContext.signatureTimestamp (Demus sends ~20173, not 0).
    let signatureTimestamp: Int?
    let appInstallData: String?
    let coldConfigData: String?
    let coldHashData: String?
    let hotHashData: String?
    let deviceExperimentId: String?
    let rolloutToken: String?
    let clickTrackingParams: String?

    nonisolated var isAuthenticated: Bool { sapisid != nil && cookieHeader != nil }

    nonisolated func authorizationHeader(origin: String) -> String? {
        guard let sapisid else { return nil }
        return YouTubeSession.sapisidHash(sapisid: sapisid, origin: origin)
    }

    /// A copy carrying a freshly-minted PO token + its bound visitorData — used to
    /// retry a pot client after the previous token was rejected.
    nonisolated func withPoToken(_ token: String, visitorData boundVD: String) -> YouTubeSessionContext {
        YouTubeSessionContext(
            visitorData: visitorData,
            cookieHeader: cookieHeader,
            sapisid: sapisid,
            poToken: token,
            poTokenVisitorData: boundVD,
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
}

enum YouTubeSession {
    /// Build a session context from the warmed WebView + shared cookie store.
    @MainActor
    static func build() async -> YouTubeSessionContext? {
        guard let snapshot = await SessionBootstrap.shared.sessionSnapshot() else { return nil }

        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }

        let relevant = cookies.filter {
            $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
        }
        let header = relevant.isEmpty
            ? nil
            : relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let sapisid = relevant.first(where: { $0.name == "__Secure-3PAPISID" })?.value
            ?? relevant.first(where: { $0.name == "SAPISID" })?.value

        return YouTubeSessionContext(
            visitorData: snapshot.visitorData,
            cookieHeader: header,
            sapisid: sapisid,
            poToken: snapshot.poToken,
            poTokenVisitorData: snapshot.poTokenVisitorData,
            dataSyncId: snapshot.dataSyncId,
            clientVersion: snapshot.clientVersion,
            signatureTimestamp: snapshot.signatureTimestamp,
            appInstallData: snapshot.appInstallData,
            coldConfigData: snapshot.coldConfigData,
            coldHashData: snapshot.coldHashData,
            hotHashData: snapshot.hotHashData,
            deviceExperimentId: snapshot.deviceExperimentId,
            rolloutToken: snapshot.rolloutToken,
            clickTrackingParams: snapshot.clickTrackingParams
        )
    }

    /// SAPISIDHASH — required for cookie-authenticated InnerTube calls.
    /// Marked nonisolated so it can be called from any actor (it's pure CPU work).
    nonisolated static func sapisidHash(sapisid: String, origin: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let input = "\(ts) \(sapisid) \(origin)"
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        input.withCString { ptr in
            _ = CC_SHA1(ptr, CC_LONG(strlen(ptr)), &digest)
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }
}