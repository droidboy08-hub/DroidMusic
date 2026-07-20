import Foundation
import Observation

enum StreamingQuality: String, CaseIterable, Codable {
    case low = "Low"
    case normal = "Normal"
    case high = "High"
}

// MARK: - Persisted user settings
//
// These mirror the toggles/segments in `SettingsView`. Previously they lived
// as @State inside the view, so every dismiss reset them; now they survive
// app launches via PersistenceStore. didSet on each field saves on mutation;
// init() loads back the last value.
//
// NOTE: most of these don't yet drive playback behavior — they're the
// surface UI from the settings sheet. Wiring them into real effects
// (e.g. gapless playback, crossfade, normalize) is a follow-up.
@Observable
final class SettingsState {
    // Search backend (YouTube Music WEB_REMIX vs official Data API v3).
    // Default = YouTube Music: works with no API key out of the box.
    var searchSource: SearchSource = .youtubeMusic {
        didSet { PersistenceStore.save(searchSource, for: .searchSource) }
    }

    // Playback
    var streamingQuality: StreamingQuality = .high {
        didSet { PersistenceStore.save(streamingQuality, for: .streamingQuality) }
    }
    var crossfade: Double = 6 {
        didSet { PersistenceStore.save(crossfade, for: .crossfade) }
    }
    var gapless: Bool = true {
        didSet { PersistenceStore.save(gapless, for: .gapless) }
    }
    var normalize: Bool = true {
        didSet { PersistenceStore.save(normalize, for: .normalize) }
    }

    // Downloads
    var downloadQuality: String = "Normal" {
        didSet { PersistenceStore.save(downloadQuality, for: .downloadQuality) }
    }
    var wifiOnly: Bool = true {
        didSet { PersistenceStore.save(wifiOnly, for: .wifiOnly) }
    }

    // Appearance
    var appTheme: String = "System" {
        didSet { PersistenceStore.save(appTheme, for: .appTheme) }
    }
    var animations: Bool = true {
        didSet { PersistenceStore.save(animations, for: .animations) }
    }
    var lyrics: Bool = true {
        didSet { PersistenceStore.save(lyrics, for: .lyrics) }
    }

    // Switches the mini player between the classic pill (off, default) and the
    // redesigned NewMiniPlayerView (on).
    var newMiniPlayer: Bool = false {
        didSet { PersistenceStore.save(newMiniPlayer, for: .newMiniPlayer) }
    }

    init() {
        if let v = PersistenceStore.load(.searchSource, as: SearchSource.self) { searchSource = v }
        if let v = PersistenceStore.load(.streamingQuality, as: StreamingQuality.self) {
            streamingQuality = v
        } else if let legacy = PersistenceStore.load(.streamingQuality, as: String.self) {
            streamingQuality = StreamingQuality(rawValue: legacy) ?? .high
        }
        if let v = PersistenceStore.load(.crossfade, as: Double.self) { crossfade = v }
        if let v = PersistenceStore.load(.gapless, as: Bool.self) { gapless = v }
        if let v = PersistenceStore.load(.normalize, as: Bool.self) { normalize = v }
        if let v = PersistenceStore.load(.downloadQuality, as: String.self) { downloadQuality = v }
        if let v = PersistenceStore.load(.wifiOnly, as: Bool.self) { wifiOnly = v }
        if let v = PersistenceStore.load(.appTheme, as: String.self) { appTheme = v }
        if appTheme == "Black" { appTheme = "System" }   // migrate old saved value
        if let v = PersistenceStore.load(.animations, as: Bool.self) { animations = v }
        if let v = PersistenceStore.load(.lyrics, as: Bool.self) { lyrics = v }
        if let v = PersistenceStore.load(.newMiniPlayer, as: Bool.self) { newMiniPlayer = v }
    }
}
