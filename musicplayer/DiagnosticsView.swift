import SwiftUI

// Settings → Support & Debug → "PoToken Diagnostics". Renders the in-app
// DiagnosticsLog ring buffer with Copy / Clear, so the 🔑 / 🔴 / 🟢 lines can be
// read and shared without tethering to Xcode.
struct DiagnosticsView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private let log = DiagnosticsLog.shared

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(theme.line)
            if log.entries.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(theme.palette.bg.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Text("PoToken Diagnostics")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(theme.ink)

            Spacer()

            Button {
                UIPasteboard.general.string = log.exportText
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Text(copied ? "Copied ✓" : "Copy")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)

            Button { log.clear() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(theme.ink3)
            Text("No events yet")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.ink3)
            Text("Play a track — mint, attempt, and retry events show here.")
                .font(.system(size: 12))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(log.entries) { entry in
                        Text(entry.line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: entry.text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: log.entries.count) { _, _ in
                if let last = log.entries.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(for text: String) -> Color {
        if text.contains("🔴") || text.contains("✗") || text.contains("failed") { return .red }
        if text.contains("🟢") || text.contains("✓") { return theme.accent }
        if text.contains("🟡") || text.contains("🔁") { return .orange }
        if text.contains("🔑") { return theme.ink }
        return theme.ink2
    }
}
