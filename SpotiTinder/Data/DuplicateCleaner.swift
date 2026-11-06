import Foundation
import SwiftData

/// Re-inserts still owed after the duplicates were removed. Saved before anything is deleted,
/// so if the app is closed or the network drops halfway, the next run puts every song back.
struct DuplicateCleanupJob: Codable {
    struct Entry: Codable {
        let uri: String
        /// Index in the final, de-duplicated playlist.
        let position: Int
    }

    var entries: [Entry]
    var removed = false

    private static func key(_ playlistID: String) -> String { "dedupeJob.\(playlistID)" }

    static func load(_ playlistID: String) -> DuplicateCleanupJob? {
        UserDefaults.standard.data(forKey: key(playlistID)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save(_ playlistID: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(playlistID))
    }

    static func clear(_ playlistID: String) {
        UserDefaults.standard.removeObject(forKey: key(playlistID))
    }
}

extension PlaylistService {
    /// Collapses every song that appears more than once to a single copy at its first position.
    ///
    /// Spotify can only remove *all* copies of a song, so each duplicated song is removed and then
    /// re-inserted once where its first copy was. Spotify then shows today as its "date added";
    /// the app keeps showing the original date. Returns how many songs were cleaned up.
    @discardableResult
    func removeDuplicateCopies(
        in playlist: PlaylistSummary,
        context: ModelContext,
        progress: (_ done: Int, _ total: Int) -> Void
    ) async throws -> Int {
        let playlistID = playlist.id
        var job: DuplicateCleanupJob
        if let pending = DuplicateCleanupJob.load(playlistID) {
            job = pending
        } else {
            guard let planned = try await planCleanup(playlistID) else { return 0 }
            job = planned
            job.save(playlistID)
        }
        let cleanedCount = job.entries.count

        let removeBatches = job.removed ? [] : job.entries.map(\.uri).chunked(into: Self.batchSize)
        let insertRuns = Self.consecutiveRuns(job.entries)
        let total = removeBatches.count + insertRuns.count
        var done = 0
        progress(done, total)

        for batch in removeBatches {
            try await removeTracks(batch, from: playlistID)
            done += 1
            progress(done, total)
        }
        job.removed = true
        job.save(playlistID)

        // Inserting in ascending position order keeps every later position valid.
        for run in insertRuns {
            try await addTracks(run.map(\.uri), to: playlistID, at: run[0].position)
            job.entries.removeFirst(run.count)
            job.save(playlistID)
            done += 1
            progress(done, total)
        }
        DuplicateCleanupJob.clear(playlistID)

        let refreshed = try await self.playlist(playlistID)
        try await syncTracks(for: refreshed, into: context, force: true)
        return cleanedCount
    }

    /// Works out the final order (each song once, at its first position) from a fresh download.
    private func planCleanup(_ playlistID: String) async throws -> DuplicateCleanupJob? {
        let items = try await playlistItems(playlistID)
        // Episodes and unreadable items still take up a position, so keep a placeholder for them.
        let ids = items.enumerated().map { index, item in item.track?.uri ?? "other-\(index)" }
        var counts: [String: Int] = [:]
        ids.forEach { counts[$0, default: 0] += 1 }
        let duplicated = Set(ids.filter { counts[$0, default: 0] > 1 && $0.hasPrefix("spotify:track:") })
        guard !duplicated.isEmpty else { return nil }

        var seen = Set<String>()
        let finalOrder = ids.filter { !duplicated.contains($0) || seen.insert($0).inserted }
        let entries = finalOrder.enumerated()
            .filter { duplicated.contains($0.element) }
            .map { DuplicateCleanupJob.Entry(uri: $0.element, position: $0.offset) }
        return DuplicateCleanupJob(entries: entries)
    }

    /// Groups entries with back-to-back positions so they go back in one request.
    private static func consecutiveRuns(_ entries: [DuplicateCleanupJob.Entry]) -> [[DuplicateCleanupJob.Entry]] {
        var runs: [[DuplicateCleanupJob.Entry]] = []
        for entry in entries {
            if let last = runs.last?.last, last.position + 1 == entry.position, runs[runs.count - 1].count < batchSize {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
        return runs
    }
}
