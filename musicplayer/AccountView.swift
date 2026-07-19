import SwiftUI

struct AccountView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(SettingsState.self) private var settings

    @State private var moreContent = true
    @State private var autoSync = true
    @State private var showSettings = false
    @State private var showLogin = false
    @State private var isSignedIn = false
    @State private var showTokenAlert = false
    @State private var sessionToken = "No active session"
    @State private var contentVisible = false   // content fades in after the window scales

    var body: some View {
        panel
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // The box (below) is always drawn so the springy scale animates a solid
        // empty shape; the content fades in as the window nears full size, and
        // hides instantly on close.
        .onChange(of: player.showAccount) { _, show in
            if show {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    if player.showAccount {
                        withAnimation(.easeOut(duration: 0.2)) { contentVisible = true }
                    }
                }
            } else {
                contentVisible = false
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView()
                .environment(theme)
                .environment(player)
                .environment(settings)
        }
        .sheet(isPresented: $showLogin) {
            YouTubeLoginView {
                isSignedIn = true
                showLogin = false
                Task { await YouTubeAccountSync.shared.sync(player: player) }
            }
        }
        .alert("Session Details", isPresented: $showTokenAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionToken)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            sheetHeader
            profileRow
            Spacer().frame(height: 14)
            optionRows
            Spacer().frame(height: 14)
            footerLinks
        }
        .padding(22)
        .frame(width: 360)
        // Content is gated on `contentVisible` — it's laid out (so the box gets the
        // right size) but invisible while the window scales, then fades in.
        .opacity(contentVisible ? 1 : 0)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.palette.bg)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.30), radius: 40, y: 12)
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(theme.ink)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: "person")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.bg)
                }

            Text("Account")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(theme.ink)
                .kerning(-0.2)

            Spacer()

            Button { player.showAccount = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 18)
    }

    private var profileRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(theme.palette.surfaceWarm)
                .frame(width: 44, height: 44)
                .overlay {
                    if let imgURL = player.ytProfileImageURL, let url = URL(string: imgURL) {
                        AsyncImage(url: url) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(theme.ink2)
                            }
                        }
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.ink2)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(isSignedIn ? (player.ytDisplayName ?? "YouTube User") : "Not signed in")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text(isSignedIn ? "Library synced" : "Sign in to sync your library")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3)
            }

            Spacer()

            Button {
                if isSignedIn {
                    isSignedIn = false
                } else {
                    showLogin = true
                }
            } label: {
                Text(isSignedIn ? "Sign out" : "Sign in")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(Capsule().strokeBorder(theme.ink, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var optionRows: some View {
        VStack(spacing: 8) {
            Button {
                if isSignedIn {
                    sessionToken = "YouTube Session Active (Cookies shared with engine)"
                } else {
                    sessionToken = "No active session. Please sign in to YouTube."
                }
                showTokenAlert = true
            } label: {
                accountOptionRow(
                    icon: "key",
                    label: "Show session status",
                    sub: "Tap to reveal",
                    toggle: nil
                )
            }
            .buttonStyle(.plain)

            accountOptionRow(
                icon: "arrow.clockwise",
                label: "More content",
                sub: "Include user uploads",
                toggle: $moreContent
            )
            accountOptionRow(
                icon: "arrow.clockwise",
                label: "Auto-sync library",
                sub: "Across devices",
                toggle: $autoSync
            )
        }
    }

    private func accountOptionRow(icon: String, label: String, sub: String, toggle: Binding<Bool>?) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.palette.surfaceWarm)
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.ink)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.ink3)
            }

            Spacer()

            if let toggle {
                AuriaToggle(isOn: toggle)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink3)
            }
        }
        .padding(14)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var footerLinks: some View {
        VStack(spacing: 0) {
            Divider().overlay(theme.line)
                .padding(.bottom, 12)

            footerLink(icon: "puzzlepiece", label: "Integrations") {
                sessionToken = "Third-party integrations (Piped, Invidious) are currently managed by the editorial engine."
                showTokenAlert = true
            }
            footerLink(icon: "gearshape", label: "Settings") {
                showSettings = true
            }
        }
    }

    private func footerLink(icon: String, label: String, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(theme.ink)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

import WebKit

struct YouTubeLoginView: View {
    @Environment(\.dismiss) private var dismiss
    var onLoginComplete: () -> Void

    var body: some View {
        NavigationView {
            YouTubeLoginWebView(onLoginComplete: onLoginComplete)
                .navigationTitle("Sign in to YouTube")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

struct YouTubeLoginWebView: UIViewRepresentable {
    let onLoginComplete: () -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        // Load YouTube Music directly — if not signed in it redirects to Google sign-in
        // and returns to music.youtube.com, so YTM session cookies are set from the start.
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: YouTubeLoginWebView
        var didComplete = false

        init(_ parent: YouTubeLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let host = webView.url?.host ?? ""

            // Detect successful sign-in: we're on music.youtube.com with auth cookies present
            if host.contains("music.youtube.com") && !didComplete {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    guard cookies.contains(where: { $0.name == "SID" || $0.name == "HSID" }) else { return }
                    print("✅ [Login] Signed in to YouTube Music — session ready")
                    DispatchQueue.main.async {
                        self.didComplete = true
                        self.parent.onLoginComplete()
                    }
                }
                return
            }
        }
    }
}
