import UIKit
import CoreHaptics

// MARK: - Haptic feedback
//
// Central place for tactile feedback. Prefer the semantic events (e.g.
// `Haptics.playlistCreated()`) at call sites so they read as intent.
//
// System `UIImpactFeedbackGenerator` taps are fixed-length transients — they
// can't be made longer. For a slightly longer buzz we use Core Haptics with a
// *continuous* event whose `duration` we control, falling back to a soft impact
// when Core Haptics isn't available.
@MainActor
enum Haptics {

    // MARK: Core Haptics engine

    private static let engine: CHHapticEngine? = {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true            // sleeps when idle; start() wakes it
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            try engine.start()
            return engine
        } catch {
            return nil
        }
    }()

    // MARK: Primitives

    /// A physical "tap" — fixed length. `.light` / `.medium` / `.heavy` / `.soft` / `.rigid`.
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    /// System success / warning / error notification pattern.
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    /// A short *continuous* buzz of the given `duration` — longer than a tap.
    /// `intensity` (0–1) is strength, `sharpness` (0–1) is crisp↔round. Falls back
    /// to a soft impact if Core Haptics is unavailable or errors.
    static func pulse(duration: TimeInterval = 0.12, intensity: Float = 0.6, sharpness: Float = 0.5) {
        guard let engine else { impact(.soft); return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: 0,
                duration: duration
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()                              // no-op if already running
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            impact(.soft)
        }
    }

    // MARK: Semantic events (routed through the longer Core Haptics pulse)

    /// A playlist was successfully created — a firmer, slightly longer confirmation.
    static func playlistCreated() { pulse(duration: 0.16, intensity: 0.9, sharpness: 0.45) }

    /// An item was chosen from the kebab (track ellipsis) menu.
    static func menuSelection() { pulse(duration: 0.11, intensity: 0.55, sharpness: 0.6) }

    /// The like button was toggled.
    static func likeToggled() { pulse(duration: 0.12, intensity: 0.6, sharpness: 0.5) }

    /// A song was added into a playlist.
    static func addedToPlaylist() { pulse(duration: 0.12, intensity: 0.6, sharpness: 0.5) }
}
