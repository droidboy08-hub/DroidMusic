import Foundation

// MARK: - Persistence keys
//
// One source of truth for every UserDefaults key the app reads/writes, so
// renames and audits are easy.
enum PersistenceKey: String {
    // PlayerState
    case userPlaylists
    case likedTracks
    case recentSearches
    case exploreHistory
    case exploreRecommendations
    case recentPlaylistIDs
    case hiddenHomeCardIds
    case hiddenHomeSongIds

    // ThemeState
    case paletteIndex
    case accentIndex
    case displayFontIndex
    case showMiniPlayer
    case tabStyle

    // SettingsState
    case searchSource
    case streamingQuality
    case downloadQuality
    case appTheme
    case crossfade
    case gapless
    case normalize
    case wifiOnly
    case animations
    case lyrics
    case newMiniPlayer
}

// MARK: - Codable-backed UserDefaults facade
//
// Tiny namespace around `UserDefaults.standard` that JSON-encodes/decodes
// Codable values. UserDefaults is fine for the data volume here (a few
// playlists, a handful of liked tracks, a tab of settings) — small payloads,
// atomic writes, auto-backed-up with the rest of the app's preferences.
enum PersistenceStore {
    private static let defaults = UserDefaults.standard
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func load<T: Decodable>(_ key: PersistenceKey, as type: T.Type) -> T? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, for key: PersistenceKey) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }

    static func remove(_ key: PersistenceKey) {
        defaults.removeObject(forKey: key.rawValue)
    }
}
