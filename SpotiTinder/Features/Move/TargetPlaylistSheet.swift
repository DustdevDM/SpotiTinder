import SwiftUI

/// Swipe-up target picker: choose (or create) a playlist and whether to add or move.
struct TargetPlaylistSheet: View {
    let sourcePlaylistID: String
    /// Shown as the sheet title: the song name, or e.g. "All 12 songs by Artist".
    let title: String
    let onSelect: (PlaylistSummary, SwipeAction) -> Void

    @Environment(PlaylistService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @AppStorage("targetMode") private var modeRaw = SwipeAction.add.rawValue
    @AppStorage("recentTargets") private var recentRaw = ""
    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var mode: SwipeAction { SwipeAction(rawValue: modeRaw) ?? .add }
    private var recentIDs: [String] { recentRaw.split(separator: ",").map(String.init) }

    private var candidates: [PlaylistSummary] {
        service.ownedPlaylists.filter { $0.id != sourcePlaylistID }
    }

    private var recent: [PlaylistSummary] {
        recentIDs.compactMap { id in candidates.first { $0.id == id } }
    }

    private var others: [PlaylistSummary] {
        candidates.filter { !recentIDs.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mode", selection: $modeRaw) {
                        Text("Add").tag(SwipeAction.add.rawValue)
                        Text("Move").tag(SwipeAction.move.rawValue)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(mode == .move
                         ? "The song goes to the chosen playlist and is removed from this one when you apply."
                         : "The song goes to the chosen playlist and also stays in this one.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        newName = ""
                        showNewPlaylist = true
                    } label: {
                        Label(isCreating ? "Creating…" : "New playlist…", systemImage: "plus.circle.fill")
                    }
                    .disabled(isCreating)
                }

                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { row($0) }
                    }
                }
                Section("Your playlists") {
                    ForEach(others) { row($0) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New playlist", isPresented: $showNewPlaylist) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It's created as a private playlist right away.")
            }
            .task {
                if service.playlists.isEmpty { try? await service.loadLibrary() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ playlist: PlaylistSummary) -> some View {
        Button {
            select(playlist)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: playlist.images.best(minWidth: 100), size: 40)
                VStack(alignment: .leading) {
                    Text(playlist.name)
                        .foregroundStyle(.primary)
                    Text("\(playlist.trackCount) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            select(try await service.createPlaylist(name: name))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ playlist: PlaylistSummary) {
        recentRaw = ([playlist.id] + recentIDs.filter { $0 != playlist.id }).prefix(5).joined(separator: ",")
        onSelect(playlist, mode)
        dismiss()
    }
}
