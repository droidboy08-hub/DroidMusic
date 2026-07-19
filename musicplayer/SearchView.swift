import SwiftUI

struct SearchView: View {
    @Environment(ThemeState.self) private var theme
    @Environment(PlayerState.self) private var player
    @Environment(SettingsState.self) private var settings
    @State private var query: String = ""
    @State private var results: [Track] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var showAddToPlaylist = false
    @State private var selectedTrack: Track? = nil
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().overlay(theme.line)

            if query.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !player.recentSearches.isEmpty { historyList }
                        Color.clear.frame(height: 56)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    isSearchFieldFocused = false
                }
            } else if isSearching {
                Spacer()
                ProgressView()
                    .tint(theme.accent)
                Spacer()
            } else if let error = searchError {
                emptyState(icon: "exclamationmark.circle", primary: "Search failed", secondary: error)
                    .onTapGesture {
                        isSearchFieldFocused = false
                    }
            } else if results.isEmpty {
                emptyState(icon: "magnifyingglass", primary: "No results for \"\(query)\"", secondary: "Try a different search term.")
                    .onTapGesture {
                        isSearchFieldFocused = false
                    }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, track in
                            trackRow(track: track, isLast: idx == results.count - 1)
                        }
                        Color.clear.frame(height: 56)
                    }
                    .padding(.horizontal, 22)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    isSearchFieldFocused = false
                }
            }
        }
        .background(theme.palette.bg)
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = selectedTrack {
                AddToPlaylistView(track: track)
                    .environment(theme)
                    .environment(player)
            }
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchError = nil
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                results = []
                isSearching = false
                return
            }
            isSearching = true
            let source = settings.searchSource
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let tracks = try await DemusNetwork.shared.search(query: newValue, source: source)
                    let ranked = SearchRanking.rank(tracks, query: newValue)
                    await MainActor.run {
                        self.player.recordSearch(newValue)
                        self.results = ranked
                        self.isSearching = false
                    }
                } catch {
                    await MainActor.run {
                        self.searchError = error.localizedDescription
                        self.isSearching = false
                    }
                }
            }
        }
        .onChange(of: player.pendingSearch) { _, term in
            if let term, !term.isEmpty {
                query = term
                player.pendingSearch = nil
            }
        }
        .onAppear {
            if let term = player.pendingSearch, !term.isEmpty {
                query = term
                player.pendingSearch = nil
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(theme.ink3)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Songs, artists, albums...")
                        .font(.system(size: 17))
                        .foregroundStyle(theme.ink3)
                }
                TextField("", text: $query)
                    .font(.system(size: 17))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .focused($isSearchFieldFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        isSearchFieldFocused = false
                    }
            }
            .frame(maxWidth: .infinity)

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(theme.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var historyList: some View {
        LazyVStack(spacing: 0) {
            HStack {
                Text("Recent searches")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                    .kerning(1.4)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    player.clearRecentSearches()
                } label: {
                    Text("Clear")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.ink3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ForEach(Array(player.recentSearches.enumerated()), id: \.element) { idx, item in
                historyRow(item: item, isLast: idx == player.recentSearches.count - 1)
            }
        }
    }

    private func historyRow(item: String, isLast: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                selectRecentSearch(item)
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17))
                        .foregroundStyle(theme.ink3)
                        .frame(width: 22)

                    Text(item)
                        .font(.system(size: 15.5))
                        .foregroundStyle(theme.ink)
                        .padding(.leading, 14)

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button {
                player.removeRecentSearch(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            Button {
                selectRecentSearch(item)
            } label: {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(theme.lineSoft).frame(height: 1) }
        }
    }

    private func trackRow(track: Track, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                isSearchFieldFocused = false
                player.play(track: track, queue: results)
            } label: {
                HStack(spacing: 12) {
                    ThumbnailView(url: track.thumbnailURL, seed: track.seed, cornerRadius: 8)
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.ink3)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if !track.duration.isEmpty {
                Text(track.duration)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(theme.ink3)
            }

            TrackMenu(track: track)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(theme.lineSoft).frame(height: 1) }
        }
    }

    private func selectRecentSearch(_ item: String) {
        isSearchFieldFocused = false
        query = item
    }

    private func emptyState(icon: String, primary: String, secondary: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(theme.ink3)
            Text(primary)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text(secondary)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
