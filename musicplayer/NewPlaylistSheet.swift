import SwiftUI

// MARK: - New Playlist sheet
//
// Rearranged layout (hero icon, "or" divider, Spotify import) presented in a
// standard system `.sheet` — the native drag/detent behaviour, no custom
// gestures.
struct NewPlaylistSheet: View {
    @Environment(ThemeState.self) private var theme

    @Binding var isPresented: Bool
    @Binding var name: String
    var onCreate: () -> Void
    var onSpotify: () -> Void

    @FocusState private var nameFocused: Bool

    private let spotifyGreen = Color(hex: "#1DB954")
    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            heroIcon
                .padding(.bottom, 22)
            nameField
                .padding(.bottom, 16)
            createButton
                .padding(.bottom, 18)
            dividerOr
                .padding(.bottom, 18)
            spotifyButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)   // space below the drag indicator before the header row
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(.system(size: 17))
                .foregroundStyle(theme.ink)
            Spacer()
        }
        // Title centered over the same row so it aligns with Cancel's baseline.
        .overlay {
            Text("New Playlist")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)
        }
        .padding(.bottom, 16)
    }

    private var heroIcon: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(theme.palette.surfaceWarm)
            .frame(width: 100, height: 100)
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(theme.ink2)
            }
            .shadow(color: theme.ink.opacity(0.08), radius: 12, y: 6)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playlist name")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .kerning(1.2)
                .textCase(.uppercase)
                .padding(.leading, 4)

            TextField("My Playlist", text: $name)
                .focused($nameFocused)
                .font(.system(size: 17))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .submitLabel(.done)
                .onSubmit { if canCreate { commitCreate() } }
                .padding(16)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
        }
    }

    private var createButton: some View {
        Button { commitCreate() } label: {
            Text("Create Playlist")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(canCreate ? theme.palette.bg : theme.ink.opacity(0.35))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(canCreate ? theme.ink : theme.ink.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
    }

    private var dividerOr: some View {
        HStack(spacing: 14) {
            Rectangle().fill(theme.line).frame(height: 1)
            Text("or")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.ink3)
                .textCase(.uppercase)
                .kerning(0.5)
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    private var spotifyButton: some View {
        SpotifyImportButton(green: spotifyGreen, restBar: theme.palette.bg) {
            dismiss()
            onSpotify()
        }
    }

    // MARK: Actions

    private func commitCreate() {
        guard canCreate else { return }
        onCreate()
        dismiss()
    }

    private func dismiss() {
        nameFocused = false
        isPresented = false
    }
}

// MARK: - Spotify import button (outlined green → solid green on press)

private struct SpotifyImportButton: View {
    let green: Color
    let restBar: Color        // colour of the logo's "notch" bars when at rest
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SpotifyMark(tint: pressed ? .white : green, bar: pressed ? green : restBar)
                    .frame(width: 22, height: 22)
                Text("Add from Spotify")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(pressed ? .white : green)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(pressed ? green : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(green, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressReportingStyle(pressed: $pressed))
    }
}

/// Forwards the button's pressed state up so the label can recolour on press.
private struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, p in pressed = p }
    }
}

/// The Spotify glyph: a filled disc with three upward-bowing sound-wave bars.
private struct SpotifyMark: View {
    let tint: Color
    let bar: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let lw = s * 0.085
            ZStack {
                Circle().fill(tint)
                arc(size: s, y: 0.40, halfWidth: 0.30, rise: 0.11, lineWidth: lw)
                arc(size: s, y: 0.545, halfWidth: 0.245, rise: 0.095, lineWidth: lw)
                arc(size: s, y: 0.675, halfWidth: 0.175, rise: 0.075, lineWidth: lw)
            }
            .frame(width: s, height: s)
        }
    }

    private func arc(size s: CGFloat, y: CGFloat, halfWidth: CGFloat, rise: CGFloat, lineWidth lw: CGFloat) -> some View {
        Path { p in
            let cx = s / 2
            let hw = s * halfWidth
            let yy = s * y
            p.move(to: CGPoint(x: cx - hw, y: yy))
            p.addQuadCurve(to: CGPoint(x: cx + hw, y: yy),
                           control: CGPoint(x: cx, y: yy - s * rise))
        }
        .stroke(bar, style: StrokeStyle(lineWidth: lw, lineCap: .round))
    }
}
