import SwiftData
import SwiftUI

/// Everything you decided, editable, before it's written to Spotify.
struct ReviewView: View {
    let playlist: PlaylistSummary

    @Environment(PlaylistService.self) private var service
    @Environment(\.modelContext) private var context
    @Query private var decisions: [Decision]
    @Query private var tracks: [TrackRecord]
    @State private var progress: (done: Int, total: Int)?
    @State private var showConfirm = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var backupFile: URL?
    @State private var backupProgress: (done: Int, total: Int)?

    init(playlist: PlaylistSummary) {
        self.playlist = playlist
        let playlistID = playlist.id
        _decisions = Query(filter: #Predicate<Decision> { $0.playlistID == playlistID }, sort: \Decision.decidedAt, order: .reverse)
        _tracks = Query(filter: #Predicate<TrackRecord> { $0.playlistID == playlistID })
    }

    private var removals: [Decision] {
        decisions.filter { $0.action.removesFromSource && !$0.removeApplied }
    }

    private var additionsByTarget: [(name: String, decisions: [Decision])] {
        Dictionary(grouping: decisions.filter(\.needsAdd)) { $0.targetPlaylistID ?? "" }
            .map { (name: $0.value.first?.targetPlaylistName ?? "Playlist", decisions: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private var pending: [Decision] { decisions.filter(\.isPending) }
    private var appliedCount: Int { decisions.filter { $0.action != .keep && $0.isFullyApplied }.count }
    private var duplicateRemovals: [Decision] { removals.filter { $0.occurrences > 1 } }
    private var isApplying: Bool { progress != nil }

    var body: some View {
        List {
            summarySection

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Text("Anything that already went through is saved. Tap Apply again to retry the rest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !duplicateRemovals.isEmpty {
                Section {
                    Label {
                        Text("\(duplicateRemovals.count) songs appear more than once. Removing them deletes every copy.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            backupSection

            ForEach(additionsByTarget, id: \.name) { group in
                Section("Add to \(group.name) (\(group.decisions.count))") {
                    ForEach(group.decisions) { decision in
                        DecisionRow(decision: decision)
                            .swipeActions { undoButton(decision) }
                    }
                }
            }

            if !removals.isEmpty {
                Section("Remove from \(playlist.name) (\(removals.count))") {
                    ForEach(removals) { decision in
                        DecisionRow(decision: decision)
                            .swipeActions {
                                undoButton(decision)
                                if decision.action == .remove {
                                    Button("Keep") { change(decision, to: .keep) }.tint(.green)
                                } else if !decision.addApplied {
                                    Button("Add only") { change(decision, to: .add) }.tint(.blue)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Apply \(pending.count) changes to Spotify?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Apply changes", role: .destructive) { Task { await apply() } }
        } message: {
            Text("\(removals.count) songs will be removed from \(playlist.name). Export a backup first if you haven't.")
        }
        .task {
            backupFile = try? BackupExporter.export(playlistID: playlist.id, name: playlist.name, tracks: tracks)
        }
        .interactiveDismissDisabled(isApplying)
        .navigationBarBackButtonHidden(isApplying)
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(removals.count) to remove from \(playlist.name)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Label("\(additionsByTarget.reduce(0) { $0 + $1.decisions.count }) to add to \(additionsByTarget.count) playlists", systemImage: "arrow.up.right.circle.fill")
                    .foregroundStyle(.blue)
                Label("\(decisions.filter { $0.action == .keep }.count) kept", systemImage: "heart.circle.fill")
                    .foregroundStyle(.green)
                if appliedCount > 0 {
                    Label("\(appliedCount) already applied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text("Applying… batch \(min(progress.done + 1, progress.total)) of \(progress.total)")
                }
            } else {
                Button {
                    showConfirm = true
                } label: {
                    Text(pending.isEmpty ? "Nothing to apply" : "Apply \(pending.count) changes")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pending.isEmpty)
            }

            if let resultMessage {
                Text(resultMessage).font(.footnote).foregroundStyle(.green)
            }
        }
    }

    private var backupSection: some View {
        Section {
            if let backupFile {
                ShareLink(item: backupFile) {
                    Label("Export track list (JSON)", systemImage: "square.and.arrow.up")
                }
            }
            if let backupProgress {
                ProgressView(value: Double(backupProgress.done), total: Double(max(backupProgress.total, 1))) {
                    Text("Copying to backup playlist…")
                }
            } else {
                Button {
                    Task { await createBackupPlaylist() }
                } label: {
                    Label("Copy everything to a backup playlist", systemImage: "doc.on.doc")
                }
                .disabled(tracks.isEmpty || isApplying)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Recommended before your first Apply. The backup playlist is private.")
        }
    }

    private func undoButton(_ decision: Decision) -> some View {
        Button("Undo", role: .destructive) {
            context.delete(decision)
            try? context.save()
        }
        .disabled(decision.addApplied || decision.removeApplied)
    }

    private func change(_ decision: Decision, to action: SwipeAction) {
        decision.action = action
        if !action.addsToTarget {
            decision.targetPlaylistID = nil
            decision.targetPlaylistName = nil
        }
        try? context.save()
    }

    private func apply() async {
        errorMessage = nil
        resultMessage = nil
        let count = pending.count
        progress = (0, 0)
        defer { progress = nil }
        do {
            try await service.apply(pending, sourcePlaylistID: playlist.id, context: context) { done, total in
                progress = (done, total)
            }
            resultMessage = "Done! \(count) changes applied to Spotify."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createBackupPlaylist() async {
        errorMessage = nil
        backupProgress = (0, 0)
        defer { backupProgress = nil }
        do {
            let backup = try await service.createBackupPlaylist(of: playlist.name, tracks: tracks) { done, total in
                backupProgress = (done, total)
            }
            resultMessage = "Backup saved as “\(backup.name)”."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DecisionRow: View {
    let decision: Decision

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: decision.artURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.trackName).lineLimit(1)
                Text(decision.artists).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if decision.action == .move, let target = decision.targetPlaylistName {
                    Text("Moving to \(target)").font(.caption).foregroundStyle(.blue)
                }
            }
            Spacer()
            if decision.occurrences > 1 {
                Text("×\(decision.occurrences)").font(.caption.bold()).foregroundStyle(.orange)
            }
            if decision.addApplied {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Added")
            }
        }
    }
}
