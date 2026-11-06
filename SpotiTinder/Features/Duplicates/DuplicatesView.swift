import SwiftData
import SwiftUI

/// Finds the same song saved more than once, as different releases or as exact copies.
/// Versions you don't keep are marked for removal and go through Review → Apply like swipes.
struct DuplicatesView: View {
    let playlist: PlaylistSummary

    @Environment(PlaylistService.self) private var service
    @Environment(PlayerController.self) private var player
    @Environment(\.modelContext) private var context
    @Query private var tracks: [TrackRecord]
    @Query private var decisions: [Decision]
    /// Group ID → key of the track picked to keep. Defaults to the oldest added.
    @State private var keepers: [String: String] = [:]
    @State private var ignored: Set<String> = []
    @State private var showKeepOldestConfirm = false
    @State private var showExactCopiesConfirm = false
    @State private var exactCopiesProgress: (done: Int, total: Int)?
    @State private var message: String?
    @State private var errorMessage: String?

    init(playlist: PlaylistSummary) {
        self.playlist = playlist
        let playlistID = playlist.id
        _tracks = Query(filter: #Predicate<TrackRecord> { $0.playlistID == playlistID })
        _decisions = Query(filter: #Predicate<Decision> { $0.playlistID == playlistID })
    }

    private var groups: [DuplicateFinder.Group] {
        DuplicateFinder.versionGroups(in: tracks, ignoring: ignored)
    }

    private var decisionsByURI: [String: Decision] {
        Dictionary(decisions.map { ($0.trackURI, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var unresolvedGroups: [DuplicateFinder.Group] {
        let decisionsByURI = decisionsByURI
        return groups.filter { !isResolved($0, decisionsByURI) }
    }

    private var exactCopySongs: [TrackRecord] { tracks.filter { $0.occurrences > 1 } }
    private var extraCopies: Int { exactCopySongs.reduce(0) { $0 + $1.occurrences - 1 } }
    private var hasUnfinishedExactCleanup: Bool { DuplicateCleanupJob.load(playlist.id) != nil }
    private var showsExactCopies: Bool {
        !playlist.isLikedSongs && (!exactCopySongs.isEmpty || hasUnfinishedExactCleanup)
    }

    var body: some View {
        let decisionsByURI = decisionsByURI
        let groups = groups
        let unresolved = groups.filter { !isResolved($0, decisionsByURI) }

        List {
            Section {
                Text("Songs that are on here more than once, e.g. as a single and on the album, or as a remaster. Pick the version to keep; the others are marked for removal and only change on Spotify when you tap Apply in Review.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if unresolved.count > 1 {
                    Button("Keep the oldest of all \(unresolved.count)", systemImage: "wand.and.stars") {
                        showKeepOldestConfirm = true
                    }
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
            if let message {
                Section { Text(message).foregroundStyle(.green) }
            }

            if showsExactCopies {
                exactCopiesSection
            }

            ForEach(groups) { group in
                groupSection(group, decisionsByURI)
            }
        }
        .overlay {
            if groups.isEmpty && !showsExactCopies {
                ContentUnavailableView(
                    "No duplicates found",
                    systemImage: "checkmark.seal",
                    description: Text("No song is on \(playlist.name) more than once.")
                )
            }
        }
        .navigationTitle("Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !ignored.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Show \(ignored.count) hidden groups", systemImage: "eye") {
                            ignored = []
                            DuplicateFinder.setIgnoredGroups([], for: playlist.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("Keep the oldest version?", isPresented: $showKeepOldestConfirm, titleVisibility: .visible) {
            Button("Keep oldest, mark the others") {
                for group in unresolvedGroups { removeOthers(in: group, keeping: group.tracks[0]) }
            }
        } message: {
            Text("For each of the \(unresolvedGroups.count) songs, the version you added first is kept and the others are marked for removal. You can still change this in Review.")
        }
        .confirmationDialog("Remove extra copies?", isPresented: $showExactCopiesConfirm, titleVisibility: .visible) {
            Button(extraCopies == 1 ? "Remove 1 extra copy" : "Remove \(extraCopies) extra copies") { Task { await removeExactCopies() } }
        } message: {
            Text("Each of the \(exactCopySongs.count) songs stays once, where its first copy was. This changes the playlist on Spotify right away. Spotify will show today as the song's “date added”, but this app keeps showing the original date.")
        }
        .onAppear { ignored = DuplicateFinder.ignoredGroups(for: playlist.id) }
        .onDisappear { player.pause() }
    }

    // MARK: Same song, different releases

    private func groupSection(_ group: DuplicateFinder.Group, _ decisionsByURI: [String: Decision]) -> some View {
        let resolved = isResolved(group, decisionsByURI)
        let keeper = keeper(of: group, decisionsByURI)
        return Section {
            ForEach(group.tracks) { track in
                let marked = isMarked(track, decisionsByURI)
                Button {
                    keepers[group.id] = track.key
                } label: {
                    VersionRow(
                        track: track,
                        isKeeper: !resolved && track.key == keeper.key,
                        isMarked: marked,
                        isPlaying: player.isPlaying && player.currentURI == track.uri,
                        play: { togglePlay(track) }
                    )
                }
                .buttonStyle(.plain)
                .disabled(resolved)
            }

            if resolved {
                Button("Undo", systemImage: "arrow.uturn.backward") { undo(group, decisionsByURI) }
                    .disabled(group.tracks.contains { decisionsByURI[$0.uri]?.removeApplied == true })
            } else {
                HStack {
                    Button(group.tracks.count == 2 ? "Remove the other" : "Remove the other \(group.tracks.count - 1)") {
                        removeOthers(in: group, keeping: keeper)
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Not duplicates") { ignore(group) }
                        .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("\(group.tracks[0].name) · \(group.tracks[0].artistKey)")
        }
    }

    private func isMarked(_ track: TrackRecord, _ decisionsByURI: [String: Decision]) -> Bool {
        decisionsByURI[track.uri]?.action.removesFromSource == true
    }

    /// Resolved once at most one version is left unmarked.
    private func isResolved(_ group: DuplicateFinder.Group, _ decisionsByURI: [String: Decision]) -> Bool {
        group.tracks.filter { !isMarked($0, decisionsByURI) }.count <= 1
    }

    private func keeper(of group: DuplicateFinder.Group, _ decisionsByURI: [String: Decision]) -> TrackRecord {
        if let key = keepers[group.id], let track = group.tracks.first(where: { $0.key == key }) { return track }
        return group.tracks.first { !isMarked($0, decisionsByURI) } ?? group.tracks[0]
    }

    private func removeOthers(in group: DuplicateFinder.Group, keeping keeper: TrackRecord) {
        for track in group.tracks {
            if track.key == keeper.key {
                // The kept version may have been swiped away earlier; take that back.
                if let decision = decisionsByURI[track.uri], decision.action.removesFromSource,
                   !decision.addApplied, !decision.removeApplied {
                    context.delete(decision)
                }
            } else if !isMarked(track, decisionsByURI) {
                Decision.upsert(track, .remove, in: context)
            }
        }
        try? context.save()
    }

    private func undo(_ group: DuplicateFinder.Group, _ decisionsByURI: [String: Decision]) {
        for track in group.tracks {
            if let decision = decisionsByURI[track.uri], decision.action == .remove, !decision.removeApplied {
                context.delete(decision)
            }
        }
        try? context.save()
    }

    private func ignore(_ group: DuplicateFinder.Group) {
        withAnimation { _ = ignored.insert(group.id) }
        DuplicateFinder.setIgnoredGroups(ignored, for: playlist.id)
    }

    private func togglePlay(_ track: TrackRecord) {
        if player.currentURI == track.uri {
            player.togglePlayPause(track)
        } else {
            player.play(track, fromStart: true)
        }
    }

    // MARK: Exact copies of the same Spotify track

    private var exactCopiesSection: some View {
        Section {
            if !exactCopySongs.isEmpty {
                Text(exactCopySongs.count == 1
                     ? "1 song is the exact same Spotify track added more than once (\(extraCopies) extra \(extraCopies == 1 ? "copy" : "copies"))."
                     : "\(exactCopySongs.count) songs are the exact same Spotify track added more than once (\(extraCopies) extra copies).")
                    .font(.subheadline)
            }
            if let exactCopiesProgress {
                ProgressView(value: Double(exactCopiesProgress.done), total: Double(max(exactCopiesProgress.total, 1))) {
                    Text("Removing extra copies…")
                }
            } else if hasUnfinishedExactCleanup {
                Button("Finish removing extra copies", systemImage: "arrow.clockwise") {
                    Task { await removeExactCopies() }
                }
            } else {
                Button("Remove extra copies", systemImage: "square.on.square") { showExactCopiesConfirm = true }
            }
        } header: {
            Text("Exact copies")
        }
    }

    private func removeExactCopies() async {
        errorMessage = nil
        message = nil
        exactCopiesProgress = (0, 0)
        defer { exactCopiesProgress = nil }
        do {
            let cleaned = try await service.removeDuplicateCopies(in: playlist, context: context) { done, total in
                exactCopiesProgress = (done, total)
            }
            message = cleaned == 0 ? "No exact copies found on Spotify." : "Done! \(cleaned) songs now appear only once."
        } catch {
            errorMessage = "Stopped: \(error.localizedDescription). Tap “Finish removing extra copies” to continue, so no song is lost."
        }
    }
}

private struct VersionRow: View {
    let track: TrackRecord
    let isKeeper: Bool
    let isMarked: Bool
    let isPlaying: Bool
    let play: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isKeeper ? "checkmark.circle.fill" : isMarked ? "xmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isKeeper ? Color.green : isMarked ? Color.red : Color.secondary)
            ArtworkView(url: track.artURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .strikethrough(isMarked)
                    .lineLimit(2)
                Text(track.releaseYear.map { "\(track.album) · \(String($0))" } ?? track.album)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let addedAt = track.addedAt {
                        Text("Added \(addedAt, format: .dateTime.month(.abbreviated).year())")
                    }
                    Text(Duration.milliseconds(track.durationMs), format: .time(pattern: .minuteSecond))
                    if isMarked { Text("· marked for removal").foregroundStyle(.red) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: play) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPlaying ? "Pause" : "Play this version")
        }
        .contentShape(Rectangle())
    }
}
