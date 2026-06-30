	import Foundation

// MARK: - Data models
nonisolated struct Track: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let artist: String
    let seed: Int
    var explicit: Bool
    var duration: String
    var videoId: String?
    var thumbnailURL: String?

    init(id: UUID = UUID(), title: String, artist: String, seed: Int = 0,
         explicit: Bool = false, duration: String = "",
         videoId: String? = nil, thumbnailURL: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.seed = seed
        self.explicit = explicit
        self.duration = duration
        self.videoId = videoId
        self.thumbnailURL = thumbnailURL
    }
}

struct Playlist: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let author: String
    var tracks: [Track]
    var coverURL: String?
    var lastPlayedAt: Date?

    init(id: UUID = UUID(), title: String, author: String, tracks: [Track] = [], coverURL: String? = nil, lastPlayedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.tracks = tracks
        self.coverURL = coverURL
        self.lastPlayedAt = lastPlayedAt
    }
    
    // Legacy support for sample data
    init(id: UUID = UUID(), title: String, author: String, seeds: [Int]) {
        self.id = id
        self.title = title
        self.author = author
        self.tracks = seeds.map { Track(title: "Song \($0)", artist: "Artist \($0)", seed: $0, duration: "3:45") }
        self.lastPlayedAt = nil
    }
}

struct Artist: Identifiable {
    let id: UUID
    let name: String
    let seed: Int
    let trackCount: Int

    init(id: UUID = UUID(), name: String, seed: Int, trackCount: Int) {
        self.id = id
        self.name = name
        self.seed = seed
        self.trackCount = trackCount
    }
}

struct Album: Identifiable {
    let id: UUID
    let title: String
    let artist: String
    let seed: Int
    let year: Int
    let trackCount: Int

    init(id: UUID = UUID(), title: String, artist: String, seed: Int, year: Int, trackCount: Int) {
        self.id = id
        self.title = title
        self.artist = artist
        self.seed = seed
        self.year = year
        self.trackCount = trackCount
    }
}

struct Genre: Identifiable {
    let id: UUID
    let name: String
    let colorHex: String

    init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

struct LyricsLine: Identifiable {
    let id: UUID
    let text: String
    let isChorus: Bool

    init(id: UUID = UUID(), text: String, isChorus: Bool = false) {
        self.id = id
        self.text = text
        self.isChorus = isChorus
    }
}

struct FeaturedItem: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let tracks: [Track]

    init(id: UUID = UUID(), title: String, subtitle: String, tracks: [Track] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tracks = tracks
    }

    // Legacy support
    init(id: UUID = UUID(), title: String, subtitle: String, seeds: [Int]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tracks = seeds.map { Track(title: "Song \($0)", artist: "Artist \($0)", seed: $0) }
    }
}

// MARK: - Static data (genres only — all song/artist/album data comes from real sources)
enum SampleData {
    static let recentTracks: [Track] = [
        Track(title: "Midnight City", artist: "M83", seed: 101, duration: "4:03"),
        Track(title: "Starboy", artist: "The Weeknd", seed: 102, duration: "3:50"),
        Track(title: "Levitating", artist: "Dua Lipa", seed: 103, duration: "3:23"),
        Track(title: "Blinding Lights", artist: "The Weeknd", seed: 104, duration: "3:20")
    ]
    static let suggestions: [Track] = [
        Track(title: "Save Your Tears", artist: "The Weeknd", seed: 201, duration: "3:35"),
        Track(title: "Good 4 U", artist: "Olivia Rodrigo", seed: 202, duration: "2:58"),
        Track(title: "Kiss Me More", artist: "Doja Cat", seed: 203, duration: "3:28")
    ]
    static let communityPlaylists: [Playlist] = [
        Playlist(title: "Late Night Lo-Fi", author: "Auria Editor", seeds: [301, 302, 303, 304]),
        Playlist(title: "Summer Vibes", author: "Music Lover", seeds: [401, 402, 403, 404]),
        Playlist(title: "Deep Focus", author: "Study Buddy", seeds: [501, 502, 503, 504])
    ]
    static let searchHistory: [String] = ["The Weeknd", "Lo-fi Hip Hop", "Jazz Classics"]
    static let artists: [Artist] = [
        Artist(name: "The Weeknd", seed: 601, trackCount: 42),
        Artist(name: "Dua Lipa", seed: 602, trackCount: 28),
        Artist(name: "M83", seed: 603, trackCount: 15)
    ]
    static let albums: [Album] = [
        Album(title: "After Hours", artist: "The Weeknd", seed: 701, year: 2020, trackCount: 14),
        Album(title: "Future Nostalgia", artist: "Dua Lipa", seed: 702, year: 2020, trackCount: 11)
    ]
    static let lyrics: [LyricsLine] = []
    static let featured: [FeaturedItem] = [
        FeaturedItem(title: "The Midnight Collection", subtitle: "Editor's Choice", seeds: [801, 802, 803, 804]),
        FeaturedItem(title: "Golden Hour Jazz", subtitle: "Curated for You", seeds: [901, 902, 903, 904])
    ]
    static let quickPicks: [Track] = [
        Track(title: "Heat Waves", artist: "Glass Animals", seed: 1001, duration: "3:58"),
        Track(title: "Stay", artist: "The Kid LAROI", seed: 1002, duration: "2:21"),
        Track(title: "Bad Habits", artist: "Ed Sheeran", seed: 1003, duration: "3:51"),
        Track(title: "Peaches", artist: "Justin Bieber", seed: 1004, duration: "3:18")
    ]
    static let charts: [Track] = []

    // Library smart collections
    struct LibraryTile {
        let label: String
        let icon: String
        let count: String
    }
    static let libraryTiles: [LibraryTile] = [
        LibraryTile(label: "Liked",      icon: "heart",             count: "0 tracks"),
        LibraryTile(label: "Import", icon: "arrow.down.circle", count: "0 tracks"),
    ]

    // Real genre categories used for Browse / Explore
    static let genres: [Genre] = [
        Genre(name: "Lo-Fi",        colorHex: "#5C7A6E"),
        Genre(name: "Indie",        colorHex: "#8A5C3A"),
        Genre(name: "Jazz",         colorHex: "#3A5C8A"),
        Genre(name: "Hip-Hop",      colorHex: "#6A3A8A"),
        Genre(name: "Ambient",      colorHex: "#3A7A6A"),
        Genre(name: "Electronic",   colorHex: "#8A3A5C"),
        Genre(name: "Acoustic",     colorHex: "#7A6A3A"),
        Genre(name: "R&B",          colorHex: "#5C3A8A"),
        Genre(name: "Classical",    colorHex: "#3A5C5C"),
        Genre(name: "Pop",          colorHex: "#8A5C5C"),
    ]
}
