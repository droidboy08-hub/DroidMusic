import Foundation

// MARK: - Search result ranking
//
// Re-ranks (and lightly de-junks) raw YouTube search results so the version the
// user actually wants floats to the top. Combines a fuzzy relevance score
// (phrase/prefix/token/edit-distance) with penalties for clutter the query
// didn't ask for (live / cover / reaction / 1-hour / slowed…), and a small
// preference for official-audio "Topic" channels and sane durations.
enum SearchRanking {

    // Almost never what someone searching for a song wants — dropped if the
    // result is also a poor fuzzy match.
    private static let hardJunk = ["reaction", "reacts", "tutorial", "how to play",
                                   "lesson", "karaoke", "1 hour", "hour loop", "10 hours"]
    // Legit sometimes, so only demoted (never dropped) when the query didn't ask.
    private static let softJunk = ["live", "cover", "remix", "instrumental", "slowed",
                                   "reverb", "sped up", "nightcore", "8d", "bass boosted",
                                   "loop", "mashup"]

    /// Re-rank `tracks` for `query`. Returns the same tracks, best-first, with
    /// clearly-irrelevant junk removed (never removes everything).
    static func rank(_ tracks: [Track], query: String) -> [Track] {
        let q = normalize(query)
        guard !q.isEmpty else { return tracks }
        let qTokens = q.split(separator: " ").map(String.init)

        let scored: [(track: Track, score: Double, drop: Bool)] = tracks.map { t in
            let title = normalize(t.title)
            let hay = normalize(t.title + " " + t.artist)
            let rel = relevance(query: q, qTokens: qTokens, candidate: hay)

            var s = rel
            var hardHit = false
            for w in hardJunk where title.contains(w) && !q.contains(w) { s -= 0.5; hardHit = true }
            for w in softJunk where title.contains(w) && !q.contains(w) { s -= 0.18 }

            if normalize(t.artist).hasSuffix("topic") { s += 0.25 }   // official audio
            if let secs = durationSeconds(t.duration) {
                if secs > 900 { s -= 0.3 }                            // >15 min → likely a mix/loop
                else if (60...600).contains(secs) { s += 0.05 }
            }

            return (t, s, hardHit && rel < 0.4)
        }

        let kept = scored.filter { !$0.drop }
        return (kept.isEmpty ? scored : kept).sorted { $0.score > $1.score }.map { $0.track }
    }

    // MARK: Relevance

    private static func relevance(query q: String, qTokens: [String], candidate hay: String) -> Double {
        guard !qTokens.isEmpty else { return 0 }
        var s = 0.0
        if hay.contains(q) { s += 0.5 }          // whole query phrase present
        if hay.hasPrefix(q) { s += 0.2 }
        let cTokens = hay.split(separator: " ").map(String.init)
        var matched = 0.0
        for qt in qTokens {
            if cTokens.contains(qt) { matched += 1 }
            else if cTokens.contains(where: { $0.hasPrefix(qt) || qt.hasPrefix($0) }) { matched += 0.8 }
            else if cTokens.contains(where: { editDistance($0, qt, limit: 1) <= 1 }) { matched += 0.6 }
        }
        s += (matched / Double(qTokens.count)) * 0.6
        return s
    }

    // MARK: Helpers

    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    private static func durationSeconds(_ d: String) -> Int? {
        let parts = d.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Bounded Levenshtein — early-outs once the distance exceeds `limit`.
    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, min(cur[j - 1] + 1, prev[j - 1] + cost))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
