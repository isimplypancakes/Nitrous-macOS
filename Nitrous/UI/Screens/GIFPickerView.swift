import SwiftUI

/// The GIF picker popover: Trending / Favorites. Data comes from Klipy's
/// public v2 API — the same provider Discord's picker serves, reached directly
/// because Discord's internal `/gif-picker/*` endpoints now 404. Klipy needs a
/// per-app key (free at partner.klipy.com); it's stored per-user in
/// UserDefaults. Favorites are kept locally. Tapping a GIF downloads it and
/// sends it as a message upload.
struct GIFPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: Channel

    /// Stored in UserDefaults; DiscordREST reads it for `v2/featured`/`v2/search`.
    @AppStorage("klipyAPIKey") private var klipyKey = ""
    @State private var klipyKeyDraft = ""

    private enum Tab: String, CaseIterable {
        case trending = "Trending"
        case favorites = "Favorites"
    }

    @State private var tab: Tab = .trending
    @State private var query = ""
    @State private var results: [GIFItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    private var shown: [GIFItem] {
        guard tab == .favorites else { return results }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.favoriteGIFs }
        return model.favoriteGIFs.filter { ($0.title ?? "").localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search GIFs…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button {
                    query = ""
                    Task { await refresh() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }

            if hasKey {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                keyBar
            }

            ScrollView {
                if !hasKey {
                    VStack(spacing: 8) {
                        Image(systemName: "key.horizontal")
                            .font(.title).foregroundStyle(.secondary)
                        Text("GIFs come from Klipy, which needs an API key to browse.")
                            .font(.subheadline)
                        Link("Create a free key at partner.klipy.com",
                             destination: URL(string: "https://partner.klipy.com")!)
                            .font(.subheadline)
                        Text("Paste it above and hit Save.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 40)
                } else if let errorText, results.isEmpty && tab == .trending {
                    errorState(errorText)
                } else if tab == .favorites, let favError = model.favoritesLoadError, shown.isEmpty {
                    errorState(favError)
                } else if shown.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(shown) { gif in
                            cell(gif)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 420, height: 400)
        .onChange(of: tab) { _, _ in
            Task { await refresh() }
            Task { await model.reloadFavorites() }
        }
        .onChange(of: query) { _, _ in debounceSearch() }
        .task {
            Task { await model.reloadFavorites() }
            await refresh()
        }
    }

    private var hasKey: Bool {
        !klipyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var keyBar: some View {
        HStack(spacing: 8) {
            TextField("Klipy API key", text: $klipyKeyDraft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .help("Get a free key at partner.klipy.com")
            Button("Save") {
                klipyKey = klipyKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await refresh() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(klipyKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func errorState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.title).foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await refresh() } }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: tab == .favorites ? "star" : "magnifyingglass")
                .font(.title).foregroundStyle(.secondary)
            Text(emptyText)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
    }

    private var emptyText: String {
        if tab == .favorites {
            return model.favoriteGIFs.isEmpty
                ? "No favorites yet — hover a GIF and tap the star."
                : "No favorites match “\(query)”."
        }
        if loading { return "Loading…" }
        return query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Nothing to show."
            : "No GIFs found for “\(query)”."
    }

    private func cell(_ gif: GIFItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.sendGIF(item: gif, in: channel.id)
                dismiss()
            } label: {
                GIFThumb(url: gif.previewURL ?? gif.gifURL)
                    .frame(width: 132, height: 150)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(gif.title ?? "Send GIF")

            let fav = model.isFavorite(gif)
            Button {
                withAnimation(.snappy(duration: 0.18)) { model.toggleFavorite(gif) }
            } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(fav ? .yellow : .secondary)
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .help(fav ? "Remove favorite" : "Favorite")
        }
    }

    private func debounceSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            if tab == .favorites { return }
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        guard let rest = model.restClient else {
            errorText = "Not connected."
            return
        }
        guard tab != .favorites else { return }
        loading = true
        errorText = nil
        let q = query.trimmingCharacters(in: .whitespaces)
        do {
            results = q.isEmpty ? try await rest.gifTrending() : try await rest.gifSearch(q)
            if results.isEmpty { errorText = "No GIFs found." }
        } catch let error as DiscordAPIError {
            results = []
            errorText = error.message ?? error.localizedDescription
        } catch {
            results = []
            errorText = error.localizedDescription
        }
        loading = false
    }
}