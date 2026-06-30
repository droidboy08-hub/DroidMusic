import SwiftUI
import Observation

// MARK: - Hex colour initialiser
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Background palette  [bg, bgSoft, surface, surfaceWarm]
struct AuriaPalette: Equatable {
    let bg: Color
    let bgSoft: Color
    let surface: Color
    let surfaceWarm: Color
    let isDark: Bool

    static let bone = AuriaPalette(
        bg: Color(hex: "#F9F6F0"), bgSoft: Color(hex: "#F2EDE4"),
        surface: Color(hex: "#FFFFFF"), surfaceWarm: Color(hex: "#F4EFE1"),
        isDark: false
    )
    static let sand = AuriaPalette(
        bg: Color(hex: "#EFE6D2"), bgSoft: Color(hex: "#E9DDBF"),
        surface: Color(hex: "#F8F1E0"), surfaceWarm: Color(hex: "#E0D3B5"),
        isDark: false
    )
    static let mist = AuriaPalette(
        bg: Color(hex: "#ECEBE6"), bgSoft: Color(hex: "#E4E2DA"),
        surface: Color(hex: "#F6F5F1"), surfaceWarm: Color(hex: "#DAD7CB"),
        isDark: false
    )
    static let inkDark = AuriaPalette(
        bg: Color(hex: "#1B1815"), bgSoft: Color(hex: "#23201C"),
        surface: Color(hex: "#2A2722"), surfaceWarm: Color(hex: "#332F28"),
        isDark: true
    )

    static let all: [AuriaPalette] = [.bone, .sand, .mist, .inkDark]
    static let names = ["Bone", "Sand", "Mist", "Ink"]
}

// MARK: - Tab indicator style
enum TabIndicatorStyle: String, CaseIterable, Codable {
    case topTick = "Top tick"
    case underline = "Underline"
}

// MARK: - Observable theme state
@Observable
final class ThemeState {
    // Persisted across launches. didSet fires for every mutation (incl. ones
    // from views setting `theme.paletteIndex = i`) so saves stay in sync.
    var paletteIndex: Int = 0 {
        didSet { PersistenceStore.save(paletteIndex, for: .paletteIndex) }
    }
    var accentIndex: Int = 2 {   // default: indigo
        didSet { PersistenceStore.save(accentIndex, for: .accentIndex) }
    }
    var displayFontIndex: Int = 3 {
        didSet { PersistenceStore.save(displayFontIndex, for: .displayFontIndex) }
    }
    var showMiniPlayer: Bool = true {
        didSet { PersistenceStore.save(showMiniPlayer, for: .showMiniPlayer) }
    }
    var tabStyle: TabIndicatorStyle = .topTick {
        didSet { PersistenceStore.save(tabStyle, for: .tabStyle) }
    }
    private(set) var usesDarkAppearance = false

    init() {
        // Property observers don't fire during init — safe to hydrate.
        if let v = PersistenceStore.load(.paletteIndex, as: Int.self),
           AuriaPalette.all.indices.contains(v) {
            paletteIndex = v
        }
        if let v = PersistenceStore.load(.accentIndex, as: Int.self),
           accentColors.indices.contains(v) {
            accentIndex = v
        }
        if let v = PersistenceStore.load(.displayFontIndex, as: Int.self),
           displayFontNames.indices.contains(v) {
            displayFontIndex = v
        }
        if let v = PersistenceStore.load(.showMiniPlayer, as: Bool.self) { showMiniPlayer = v }
        if let v = PersistenceStore.load(.tabStyle, as: TabIndicatorStyle.self) { tabStyle = v }
    }

    let accentColors: [Color] = [
        Color(hex: "#C8501B"),   // Rust
        Color(hex: "#3D4A35"),   // Moss
        Color(hex: "#2A5C8A"),   // Indigo
        Color(hex: "#9A2A4B"),   // Plum
        Color(hex: "#7C5E2A"),   // Ochre
        Color(hex: "#13110E"),   // Ink
    ]
    let accentNames = ["Rust", "Moss", "Indigo", "Plum", "Ochre", "Ink"]
    let displayFontNames = [
        "Instrument Serif", "DM Serif Display",
        "Playfair Display", "Cormorant Garamond", "Fraunces",
    ]

    var palette: AuriaPalette {
        if usesDarkAppearance {
            return .inkDark
        }

        let selected = AuriaPalette.all[paletteIndex]
        return selected.isDark ? .bone : selected
    }
    var accent: Color { accentColors[accentIndex] }
    var displayFontName: String { displayFontNames[displayFontIndex] }

    // Derived ink colours — adapt to dark palette
    var ink: Color  { palette.isDark ? Color(hex: "#F2ECDF") : Color(hex: "#13110E") }
    var ink2: Color { palette.isDark ? Color(hex: "#C4BCA8") : Color(hex: "#4A4438") }
    var ink3: Color { Color(hex: "#8A8273") }
    var line: Color { ink.opacity(0.10) }
    var lineSoft: Color { ink.opacity(0.06) }

    func updateAppearance(appTheme: String, systemColorScheme: ColorScheme) {
        switch appTheme {
        case "Light":
            usesDarkAppearance = false
        case "Dark":
            usesDarkAppearance = true
        default:
            usesDarkAppearance = systemColorScheme == .dark
        }
    }

    // Serif display font
    func displayFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let base = Font.custom(displayFontName, size: size)
        // Applying .weight(.regular) sets the descriptor weight trait to 0.0,
        // which CoreText can't apply to some serif faces (e.g. Cormorant
        // Garamond) and spams "Unable to update Font Descriptor's weight"
        // warnings. It's a no-op anyway, so only override for non-regular.
        return weight == .regular ? base : base.weight(weight)
    }

    func editorialFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // DM Serif Display ships a single weight; applying any Font.Weight just spams
        // CoreText "Unable to update Font Descriptor's weight" warnings without
        // changing the render (it has no bolder face), so we never apply one.
        Font.custom("DM Serif Display", size: size)
    }
}
