import Foundation
import Observation

// MARK: - On-device diagnostics buffer
//
// A small in-memory ring buffer of the app's PoToken / InnerTube playback events,
// mirrored from the console `print`s via `dlog(_:)`. Lets us read the same
// 🔑 / 🔴 / 🟢 lines inside the app (Settings → Diagnostics) and copy them out —
// no Xcode tether, and it survives long enough to spot over-time patterns
// (e.g. "mint only fails after backgrounding / on cellular / after N hours").
//
// Local only — nothing is ever sent off device.
@MainActor
@Observable
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let text: String

        var line: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return "\(f.string(from: time))  \(text)"
        }
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 400

    func record(_ text: String) {
        entries.append(Entry(time: Date(), text: text))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() { entries.removeAll() }

    /// The whole buffer as one copy-pasteable string.
    var exportText: String {
        entries.map(\.line).joined(separator: "\n")
    }
}

/// Log a line to BOTH the Xcode console and the in-app diagnostics buffer.
/// Use in place of `print(...)` for events worth seeing on-device.
///
/// `nonisolated` so it's callable from the InnerTube resolver's background/async
/// contexts (default main-actor isolation would otherwise pin it to the main
/// actor). `print` is thread-safe, and the buffer append hops to the main actor.
nonisolated func dlog(_ message: String) {
    print(message)
    Task { @MainActor in DiagnosticsLog.shared.record(message) }
}
