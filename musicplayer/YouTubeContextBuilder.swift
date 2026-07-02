import Foundation

// MARK: - Demus-captured IOS /player body builder
// Source: music.youtube.com_06-29-2026-18-14-19.proxymanlogv2 (Demus/3, video a5RhLw9SqJE)
//
// Demus spoofs IOS clientName but sends a web-hybrid context (Safari, DESKTOP platform,
// configInfo blobs, adSignalsInfo, rich playbackContext). visitorData was empty in capture.

// `nonisolated`: compile-time constants read by the nonisolated `iosPlayerBody`
// builder (default main-actor isolation would otherwise pin them to the main actor).
nonisolated struct DemusIOSCapture {
    static let clientVersion = "20.25.4"
    static let userAgent = "com.google.ios.youtube/20.25.4 (iPhone17,1; U; CPU iOS 18_5 like Mac OS X)"
    static let deviceModel = "iPhone17,1"
    static let signatureTimestamp = 20173

    static let appInstallData = "CKumor8GEIPuzhwQ4tSuBRD8ss4cENfBsQUQiafOHBCK7f8SEOHssAUQ6-j-EhC52c4cELjkzhwQn8vOHBCdprAFEJmNsQUQh6zOHBCa584cEMn4_xIQts3OHBCe284cEMnmsAUQvbauBRC36v4SELPpzhwQo-_OHBDxnLAFEK3yzhwQjcywBRCd0LAFENvazhwQvO_OHBCU_rAFEInorgUQiOOvBRDv2c4cEJn0zhwQlPyvBRDevM4cELvZzhwQppqwBRC9mbAFEMn3rwUQ9vzOHBDN0bEFEJiy_xIQp5nOHBCRjP8SEOTn_xIQiIewBRDL0bEFEO3ezhwQibDOHBCT2c4cEN_YzhwQ44O4IhCv884cEIHNzhwQ8OLOHBDs3c4cENuvrwUQmZixBRDg3M4cEODNsQUQ-KuxBRD2q7AFENPhrwUQzN-uBRCEvc4cEODg_xIQlPnOHBC9irAFEOPvzhwQxfvOHBDw_v8SKihDQU1TR0JVVG9MMndETXpKX3d1UDlBN3Ytd2I1N0FQWDNBVWRCdz09"
    static let coldConfigData = "CKumor8GEO-6rQUQvbauBRDi1K4FEL2KsAUQ8ZywBRCd0LAFEM_SsAUQ4_iwBRCZnLEFEKS-sQUQ0r-xBRDXwbEFEJLUsQUQp5nOHBDNpM4cEImnzhwQ9rLOHBD8ss4cEOTHzhwQn8vOHBC2zc4cEN_YzhwQ4NzOHBDs3c4cEO_ezhwQkeDOHBDL5M4cEKjpzhwQs-nOHBCW6s4cENTrzhwQg-7OHBCs7s4cEOruzhwQo-_OHBDj784cEKnzzhwQr_POHBDE884cEObzzhwQmfTOHBDi9M4cEJT5zhwQgPrOHBDF-84cEPb8zhwaMkFPakZveDB5QzhoYkdMcTN6TlpuNnBIOXd5V2lGQTJvVTdPVU44QlhlZXBTaGtwMWd3IjJBT2pGb3gzVndDcUVwblRhSHZaUE9JdDQzOW95LXZNRW1Yd2FQcXZENDZhWFZsUjRxUSp8Q0FNU1dBMGp1TjIzQXQ0VXpnMlhINmdxdFFTOUZmMER1c2ViRUtFUTloR3FGUGtEa1E2RUF1c0NGVGVac2JjZmhhUUZtcnNHXzFtNGdBSUU1UVN0cndiakVhZ1YzMXVLNEFhNGJONTZoMW9Gc1NqdktLcEs4b2tHeXk0PQ%3D%3D"
    static let coldHashData = "CKumor8GEhQxNTQ5NDU0ODUwOTYxODYyNTU2MRirpqK_BjIyQU9qRm94MHlDOGhiR0xxM3pOWm42cEg5d3lXaUZBMm9VN09VTjhCWGVlcFNoa3AxZ3c6MkFPakZveDNWd0NxRXBuVGFIdlpQT0l0NDM5b3ktdk1FbVh3YVBxdkQ0NmFYVmxSNHFRQnxDQU1TV0EwanVOMjNBdDRVemcyWEg2Z3F0UVM5RmYwRHVzZWJFS0VROWhHcUZQa0RrUTZFQXVzQ0ZUZVpzYmNmaGFRRm1yc0dfMW00Z0FJRTVRU3Ryd2JqRWFnVjMxdUs0QWE0Yk41Nmgxb0ZzU2p2S0twSzhva0d5eTQ9"
    static let hotHashData = "CKumor8GEhQxMzEzNDE1NDE5NDQ0MzI1MTIwMhirpqK_BiiU5PwSKKXQ_RIonpH-EijIyv4SKLfq_hIowIP_EiiRjP8SKLWj_xIomLL_EiiK7f8SKNru_xIou_X_EijJ-P8SKIn8_xIo5Pz_Eijf_f8SKPD-_xIyMkFPakZveDB5QzhoYkdMcTN6TlpuNnBIOXd5V2lGQTJvVTdPVU44QlhlZXBTaGtwMWd3OjJBT2pGb3gzVndDcUVwblRhSHZaUE9JdDQzOW95LXZNRW1Yd2FQcXZENDZhWFZsUjRxUUIsQ0FNU0hRME1vdGY2RmE3QkJwTk44Z29WQ2QzUHdnekdwLTBMMk0wSnBjQUY%3D"
    static let deviceExperimentId = "ChxOelE0TnpNNU5qRTVOVE16TXpFNU9Ea3pPQT09EKumor8GGKumor8G"
    static let rolloutToken = "CJGH5eL5sdefYRDO0eCWoK2KAxjY9JOev7CMAw%3D%3D"
    static let clickTrackingParams = "CEoQvU4YACITCIirpf_IsIwDFS9UegUd4vgbbjIJZW5kc2NyZWVuSPeCu8L87pyNIZoBBQgCEPgd"
}

enum YouTubeContextBuilder {
    /// Demus-style IOS /player POST body. Pass harvested session values when available.
    /// `nonisolated`: pure builder over a value-type session, called from the
    /// InnerTube resolver's off-main context.
    nonisolated static func iosPlayerBody(
        videoId: String,
        session: YouTubeSessionContext,
        refererVideoId: String? = nil
    ) -> [String: Any] {
        let watchPath = "/watch?v=\(videoId)"
        let originalUrl = "https://www.youtube.com\(watchPath)"
        let sigTs = session.signatureTimestamp ?? DemusIOSCapture.signatureTimestamp

        let client: [String: Any] = [
            "clientVersion": DemusIOSCapture.clientVersion,
            "clientName": "IOS",
            "userAgent": DemusIOSCapture.userAgent,
            "deviceModel": DemusIOSCapture.deviceModel,
            "visitorData": session.visitorData,
            "originalUrl": originalUrl,
            "screenPixelDensity": 2,
            "platform": "DESKTOP",
            "clientFormFactor": "UNKNOWN_FORM_FACTOR",
            "configInfo": [
                "appInstallData": session.appInstallData ?? DemusIOSCapture.appInstallData,
                "coldConfigData": session.coldConfigData ?? DemusIOSCapture.coldConfigData,
                "coldHashData": session.coldHashData ?? DemusIOSCapture.coldHashData,
                "hotHashData": session.hotHashData ?? DemusIOSCapture.hotHashData,
            ],
            "screenDensityFloat": 2,
            "userInterfaceTheme": "USER_INTERFACE_THEME_DARK",
            "timeZone": TimeZone.current.identifier,
            "browserName": "Safari",
            "browserVersion": "18.3",
            "acceptHeader": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "deviceExperimentId": session.deviceExperimentId ?? DemusIOSCapture.deviceExperimentId,
            "rolloutToken": session.rolloutToken ?? DemusIOSCapture.rolloutToken,
            "screenWidthPoints": 512,
            "screenHeightPoints": 864,
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            "clientScreen": "WATCH",
            "mainAppWebInfo": [
                "graftUrl": watchPath,
                "webDisplayMode": "WEB_DISPLAY_MODE_BROWSER",
                "isWebNativeShareAvailable": true,
            ],
        ]

        let context: [String: Any] = [
            "client": client,
            "user": ["lockedSafetyMode": false],
            "request": [
                "useSsl": true,
                "internalExperimentFlags": [] as [Any],
                "consistencyTokenJars": [] as [Any],
            ],
            "clickTracking": [
                "clickTrackingParams": session.clickTrackingParams ?? DemusIOSCapture.clickTrackingParams,
            ],
            "adSignalsInfo": ["params": adSignalsParams()],
        ]

        var contentPlayback: [String: Any] = [
            "currentUrl": watchPath,
            "vis": 0,
            "splay": false,
            "autoCaptionsDefaultOn": false,
            "autonavState": "STATE_OFF",
            "html5Preference": "HTML5_PREF_WANTS",
            "signatureTimestamp": sigTs,
            "lactMilliseconds": "1",
            "watchAmbientModeContext": [
                "hasShownAmbientMode": true,
                "watchAmbientModeEnabled": true,
            ],
        ]
        if let ref = refererVideoId {
            contentPlayback["referer"] = "https://www.youtube.com/watch?v=\(ref)"
        }

        return [
            "context": context,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "videoId": videoId,
            "playbackContext": ["contentPlaybackContext": contentPlayback],
        ]
    }

    nonisolated private static func adSignalsParams() -> [[String: String]] {
        let now = String(Int64(Date().timeIntervalSince1970 * 1000))
        let tz = String(TimeZone.current.secondsFromGMT() / 60)
        return [
            ["key": "dt", "value": now],
            ["key": "flash", "value": "0"],
            ["key": "frm", "value": "0"],
            ["key": "u_tz", "value": tz],
            ["key": "u_his", "value": "25"],
            ["key": "u_h", "value": "982"],
            ["key": "u_w", "value": "1512"],
            ["key": "u_ah", "value": "944"],
            ["key": "u_aw", "value": "1512"],
            ["key": "u_cd", "value": "24"],
            ["key": "bc", "value": "31"],
            ["key": "bih", "value": "848"],
            ["key": "biw", "value": "496"],
            ["key": "brdim", "value": "0,38,0,38,1512,38,1445,944,512,864"],
            ["key": "vis", "value": "1"],
            ["key": "wgl", "value": "true"],
            ["key": "ca_type", "value": "image"],
        ]
    }
}
