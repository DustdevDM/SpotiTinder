import SwiftData
import SwiftUI

/// Loads and caches the chosen playlist, then shows what's in it before swiping.
struct PlaylistOverviewView: View {
    let playlist: PlaylistSummary

    @Environment(PlaylistService.self) private var service
    @Environment(\.modelContext) private var context
    @Query private var tracks: [TrackRecord]
    @Query private var decisions: [Decision]
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var showResetConfirm = false

    init(playlist: PlaylistSummary) {
        self.playlist = playlist
        let playlistID = playlist.id
        _tracks = Query(filter: #Predicate<TrackRecord> { $0.playlistID == playlistID }, sort: \TrackRecord.position)
        _decisions = Query(filter: #Predicate<Decision> { $0.playlistID == playlistID })
    }

    private var reviewedCount: Int {
        let decided = Set(decisions.map(\.trackURI))
        return tracks.filter { decided.contains($0.uri) }.count
    }

    private var pendingCount: Int { decisions.filter(\.isPending).count }

    /// Songs saved as several releases, plus exact copies of one track.
    private var duplicateCount: Int {
        let versionGroups = DuplicateFinder.versionGroups(in: tracks, ignoring: DuplicateFinder.ignoredGroups(for: playlist.id))
        return versionGroups.count + tracks.filter { $0.occurrences > 1 }.count
    }

    private var addedRange: String? {
        let years = tracks.compactMap(\.addedAt).map { Calendar.current.component(.year, from: $0) }
        guard let first = years.min(), let last = years.max() else { return nil }
        return first == last ? "\(first)" : "\(first) – \(last)"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    PlaylistArtwork(playlist: playlist, size: 160)
                    Text(playlist.name).font(.title2.bold()).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Label("\(tracks.count)", systemImage: "music.note.list")
                        if let addedRange { Label(addedRange, systemImage: "calendar") }
                        if duplicateCount > 0 {
                            Label("\(duplicateCount) dupes", systemImage: "square.on.square")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    if !tracks.isEmpty {
                        ProgressView(value: Double(reviewedCount), total: Double(tracks.count)) {
                            Text("\(reviewedCount) of \(tracks.count) reviewed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                NavigationLink(value: Route.duplicates(playlist)) {
                    HStack {
                        Label("Duplicates", systemImage: "square.on.square")
                        Spacer()
                        Text(duplicateCount == 0 ? "None found" : "\(duplicateCount) songs")
                            .foregroundStyle(duplicateCount == 0 ? Color.secondary : Color.orange)
                    }
                }
                .disabled(tracks.isEmpty)
            }

            Section("Songs") {
                ForEach(tracks) { track in
                    TrackRow(track: track)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                NavigationLink(value: Route.swipe(playlist)) {
                    Text(reviewedCount == 0 ? "Start swiping" : "Continue swiping")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)

                NavigationLink(value: Route.review(playlist)) {
                    Text(pendingCount == 0 ? "Review changes" : "Review \(pendingCount) pending changes")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
        .overlay {
            if isSyncing && tracks.isEmpty {
                ProgressView("Loading \(playlist.trackCount) songs…")
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Start over…", systemImage: "arrow.counterclockwise") { showResetConfirm = true }
                        .disabled(decisions.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Start over?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Start a new round", role: .destructive) {
                ProgressReset.reset(playlistID: playlist.id, context: context)
            }
        } message: {
            Text("All \(tracks.count) songs come back into the deck. Songs already removed on Spotify stay removed."
                 + (pendingCount > 0 ? " Your \(pendingCount) changes that haven't been applied yet will be discarded." : ""))
        }
        .task { await sync(force: false) }
        .refreshable { await sync(force: true) }
    }

    private func sync(force: Bool) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await service.syncTracks(for: playlist, into: context, force: force)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TrackRow: View {
    let track: TrackRecord

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).lineLimit(1)
                Text(track.artists).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if track.occurrences > 1 {
                Text("×\(track.occurrences)")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
            if let addedAt = track.addedAt {
                Text(addedAt, format: .dateTime.year().month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
