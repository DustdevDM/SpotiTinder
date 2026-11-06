import Foundation
import SwiftData

enum DeckOrder: String, CaseIterable, Identifiable {
    case oldestFirst, newestFirst, byArtist, shuffle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oldestFirst: "Oldest added first"
        case .newestFirst: "Newest added first"
        case .byArtist: "Grouped by artist"
        case .shuffle: "Shuffle"
        }
    }
}

enum ProgressReset {
    /// Forgets every swipe for a playlist so the next round starts from the first song.
    /// Unapplied changes are discarded too; songs already removed on Spotify stay removed.
    static func reset(playlistID: String, context: ModelContext) {
        try? context.delete(model: Decision.self, where: #Predicate { $0.playlistID == playlistID })
        try? context.save()
    }
}

/// Cleanup state for one source playlist.
@Model
final class CleanupSession {
    @Attribute(.unique) var playlistID: String
    var name: String
    var snapshotID: String
    var lastSynced: Date
    var orderRaw: String

    var order: DeckOrder {
        get { DeckOrder(rawValue: orderRaw) ?? .oldestFirst }
        set { orderRaw = newValue.rawValue }
    }

    init(playlistID: String, name: String, snapshotID: String) {
        self.playlistID = playlistID
        self.name = name
        self.snapshotID = snapshotID
        lastSynced = .now
        orderRaw = DeckOrder.oldestFirst.rawValue
    }
}
