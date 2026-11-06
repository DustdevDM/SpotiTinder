import Foundation
import SwiftData

extension PlaylistService {
    /// Caches a playlist's tracks locally. Skips the download when Spotify's snapshot is unchanged.
    /// Swipe decisions are keyed by track URI, so re-syncing never loses them.
    func syncTracks(for playlist: PlaylistSummary, into context: ModelContext, force: Bool = false) async throws {
        let playlistID = playlist.id
        let session = try context.fetch(FetchDescriptor<CleanupSession>(
            predicate: #Predicate { $0.playlistID == playlistID }
        )).first

        // Records cached before `primaryArtist` existed need one fresh download to fill it in.
        let needsBackfill = ((try? context.fetchCount(FetchDescriptor<TrackRecord>(
            predicate: #Predicate { $0.playlistID == playlistID && $0.primaryArtist == "" }
        ))) ?? 0) > 0

        if !force, !needsBackfill, let session, session.snapshotID == playlist.snapshotId {
            session.name = playlist.name
            return
        }

        let items = try await playlistItems(playlistID)
        let existing = try context.fetch(FetchDescriptor<TrackRecord>(
            predicate: #Predicate { $0.playlistID == playlistID }
        ))
        var byURI = Dictionary(existing.map { ($0.uri, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()

        for (position, item) in items.enumerated() {
            guard !item.isLocal, let track = item.track, track.uri.hasPrefix("spotify:track:") else { continue }
            if seen.contains(track.uri) {
                byURI[track.uri]?.occurrences += 1
                continue
            }
            seen.insert(track.uri)
            if let record = byURI[track.uri] {
                record.update(from: track, addedAt: item.addedAt, position: position)
            } else {
                let record = TrackRecord(playlistID: playlistID, track: track, addedAt: item.addedAt, position: position)
                context.insert(record)
                byURI[track.uri] = record
            }
        }

        for record in existing where !seen.contains(record.uri) {
            context.delete(record)
        }

        if let session {
            session.name = playlist.name
            session.snapshotID = playlist.snapshotId
            session.lastSynced = .now
        } else {
            context.insert(CleanupSession(playlistID: playlistID, name: playlist.name, snapshotID: playlist.snapshotId))
        }
        try context.save()
    }
}
