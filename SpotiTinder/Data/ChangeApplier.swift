import Foundation
import SwiftData

extension PlaylistService {
    /// Writes pending decisions to Spotify in batches of 100.
    /// Additions run first, so a move only removes a song once it's safely in its new playlist.
    /// Each batch is marked applied as soon as it succeeds, so a failed run can simply be retried.
    func apply(
        _ decisions: [Decision],
        sourcePlaylistID: String,
        context: ModelContext,
        progress: (_ done: Int, _ total: Int) -> Void
    ) async throws {
        let additions = Dictionary(grouping: decisions.filter(\.needsAdd)) { $0.targetPlaylistID! }
        let addBatches = additions.flatMap { target, group in
            group.chunked(into: Self.batchSize).map { (target, $0) }
        }
        let expectedRemovals = decisions.filter { $0.action.removesFromSource && !$0.removeApplied }
        let total = addBatches.count + (expectedRemovals.count + Self.batchSize - 1) / Self.batchSize
        var done = 0
        progress(done, total)

        for (target, batch) in addBatches {
            try await addTracks(batch.map(\.trackURI), to: target)
            batch.forEach { $0.addApplied = true }
            try context.save()
            done += 1
            progress(done, total)
        }

        for batch in decisions.filter(\.needsRemove).chunked(into: Self.batchSize) {
            try await removeTracks(batch.map(\.trackURI), from: sourcePlaylistID)
            batch.forEach { $0.removeApplied = true }
            try context.save()
            done += 1
            progress(done, total)
        }

        // Pick up the new snapshot so the local cache matches Spotify again.
        let refreshed = try await playlist(sourcePlaylistID)
        try await syncTracks(for: refreshed, into: context, force: true)
    }

    /// Copies the whole playlist into a new private playlist, in its current order.
    func createBackupPlaylist(of name: String, tracks: [TrackRecord], progress: (_ done: Int, _ total: Int) -> Void) async throws -> PlaylistSummary {
        let date = Date.now.formatted(.iso8601.year().month().day())
        let backup = try await createPlaylist(name: "\(name) (backup \(date))", description: "Backup made by SpotiTinder before cleaning up \(name).")
        let uris = tracks.sorted { $0.position < $1.position }.flatMap { Array(repeating: $0.uri, count: $0.occurrences) }
        let batches = uris.chunked(into: Self.batchSize)
        for (index, batch) in batches.enumerated() {
            progress(index, batches.count)
            try await addTracks(batch, to: backup.id)
        }
        progress(batches.count, batches.count)
        return backup
    }
}

enum BackupExporter {
    private struct Entry: Encodable {
        let uri: String
        let name: String
        let artists: String
        let album: String
        let addedAt: Date?
        let occurrences: Int
    }

    private struct Backup: Encodable {
        let playlistID: String
        let playlistName: String
        let exportedAt: Date
        let tracks: [Entry]
    }

    /// Writes the cached track list to a JSON file you can share or save to Files.
    static func export(playlistID: String, name: String, tracks: [TrackRecord]) throws -> URL {
        let backup = Backup(
            playlistID: playlistID,
            playlistName: name,
            exportedAt: .now,
            tracks: tracks.sorted { $0.position < $1.position }.map {
                Entry(uri: $0.uri, name: $0.name, artists: $0.artists, album: $0.album, addedAt: $0.addedAt, occurrences: $0.occurrences)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let safeName = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let date = Date.now.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)-backup-\(date).json")
        try encoder.encode(backup).write(to: url)
        return url
    }
}
