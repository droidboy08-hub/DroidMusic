import UIKit

// MARK: - Haptic feedback
//
// Central place for tactile feedback. Prefer the semantic events (e.g.
// `Haptics.playlistCreated()`) at call sites so they read as intent rather than
// raw generator styles — add a new case here for each new place we want a tap.
@MainActor
enum Haptics {

    // MARK: Primitives

    /// A physical "tap". `.light` / `.medium` (moderate) / `.heavy`, plus
    /// `.soft` / `.rigid`. `prepare()` warms the Taptic Engine so the hit lands
    /// with minimal latency.
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    /// System success / warning / error notification pattern.
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    // MARK: Semantic events

    /// A playlist was successfully created — a moderate confirmation tap.
    static func playlistCreated() {
        impact(.medium)
    }
}
