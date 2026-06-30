import Foundation
import AVFoundation
import UniformTypeIdentifiers

// MARK: - AVAssetResourceLoader proxy
//
// AVPlayer's own CoreMedia HTTP requests get 403 from googlevideo, but plain
// URLSession requests to the SAME url return 206 (proven by the UA probe). So
// we hand AVPlayer a custom-scheme URL, intercept every loading request, and
// satisfy it with URLSession — which the server accepts.
//
// The asset's resourceLoader holds this delegate WEAKLY, so MusicPlayer must
// retain it for the lifetime of the AVPlayerItem.
final class StreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "ytstream"

    private let realURL: URL
    private let headers: [String: String]
    private let session: URLSession

    // Content info known up-front from the URL query (no round-trip needed).
    private let contentLength: Int64?
    private let contentTypeUTI: String?

    init(realURL: URL, headers: [String: String]) {
        self.realURL = realURL
        self.headers = headers
        self.session = URLSession(configuration: .default)

        let comps = URLComponents(url: realURL, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
        self.contentLength = q("clen").flatMap { Int64($0) }
        // Default to the MP4 container UTI (covers itag 18 video AND m4a audio);
        // the response's own Content-Type overrides this when present.
        self.contentTypeUTI = q("mime").flatMap { UTType(mimeType: $0)?.identifier } ?? "public.mpeg-4"
        super.init()
    }

    /// Build the custom-scheme URL AVURLAsset should be created with.
    static func proxyURL(for realURL: URL) -> URL {
        var comps = URLComponents(url: realURL, resolvingAgainstBaseURL: false)
        comps?.scheme = scheme
        return comps?.url ?? realURL
    }

    // We feed AVPlayer in bounded chunks via the HTTP `Range` header. On a
    // ratebypass URL (itag 18) the server returns 206 + `Content-Range:
    // bytes A-B/TOTAL`, which gives us the authoritative total size and lets
    // every offset load. (A non-ratebypass URL — itag 140 — is n-throttled and
    // 403s past ~1 MB regardless of header vs query param; that needs an nsig
    // solver, out of scope here.)
    private static let chunkSize: Int64 = 1_048_576

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let dr = loadingRequest.dataRequest else {
            // Content-info only: a tiny ranged GET reads the headers.
            streamChunk(loadingRequest, cur: 0, end: 1, isFirst: true)
            return true
        }
        let start = dr.requestedOffset
        let end: Int64 = dr.requestsAllDataToEndOfResource
            ? (contentLength ?? Int64.max / 2) - 1
            : start + Int64(dr.requestedLength) - 1
        streamChunk(loadingRequest, cur: start, end: end, isFirst: true)
        return true
    }

    /// Fetch [cur, min(cur+chunk, end)] via URLSession, feed it to AVPlayer,
    /// then recurse for the next chunk until the requested range is satisfied.
    private func streamChunk(_ lr: AVAssetResourceLoadingRequest, cur: Int64, end: Int64, isFirst: Bool) {
        if lr.isCancelled { return }
        if cur > end { lr.finishLoading(); return }

        let chunkEnd = min(cur + Self.chunkSize - 1, end)
        var request = URLRequest(url: realURL)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=\(cur)-\(chunkEnd)", forHTTPHeaderField: "Range")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if lr.isCancelled { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1

            if let error = error { lr.finishLoading(with: error); return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(code),
                  let data = data, !data.isEmpty else {
                lr.finishLoading(with: NSError(domain: "AryaMusix", code: code,
                    userInfo: [NSLocalizedDescriptionKey: "Stream HTTP \(code)"]))
                return
            }

            if let info = lr.contentInformationRequest {
                info.isByteRangeAccessSupported = true
                if let mt = http.mimeType, let uti = UTType(mimeType: mt)?.identifier {
                    info.contentType = uti
                } else {
                    info.contentType = self.contentTypeUTI
                }
                if let total = self.totalLength(from: http) { info.contentLength = total }
            }

            lr.dataRequest?.respond(with: data)
            let next = cur + Int64(data.count)
            if next > end {
                lr.finishLoading()
            } else {
                self.streamChunk(lr, cur: next, end: end, isFirst: false)
            }
        }.resume()
    }

    /// Total resource length from Content-Range ("bytes 0-1/3577499"), else the URL's `clen`.
    /// Deliberately does NOT fall back to `expectedContentLength`: on a 206 that's the
    /// chunk size, and on the 2-byte probe it's 2 — either would tell AVPlayer the file
    /// is tiny and trigger a spurious "Cannot Open / media may be damaged".
    private func totalLength(from http: HTTPURLResponse) -> Int64? {
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.range(of: "/"),
           let total = Int64(cr[slash.upperBound...].trimmingCharacters(in: .whitespaces)) {
            return total
        }
        return contentLength
    }
}
