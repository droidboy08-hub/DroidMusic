import Foundation
import Observation

// MARK: - High-frequency playback UI state (isolated from PlayerState)
//
// Progress ticks live here so @Observable PlayerState mutations never invalidate
// scrolling tab lists. Only MiniProgressRing + NowPlayingView observe this.

@Observable
@MainActor
final class PlaybackProgress {
    var progress: Double = 0
    var totalSeconds: Int = 0

    var currentSeconds: Int {
        guard totalSeconds > 0 else { return 0 }
        return Int(Double(totalSeconds) * progress)
    }

    func reset() {
        progress = 0
        totalSeconds = 0
    }

    func formattedCurrent() -> String { formatTime(currentSeconds) }

    func formattedRemaining() -> String {
        guard totalSeconds > 0 else { return "0:00" }
        return "−\(formatTime(max(0, totalSeconds - currentSeconds)))"
    }

    private func formatTime(_ s: Int) -> String {
        "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}