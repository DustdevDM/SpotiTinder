import Foundation
import SwiftData

enum SwipeAction: String, Codable, CaseIterable {
    case keep, remove, add, move

    var removesFromSource: Bool { self == .remove || self == .move }
    var addsToTarget: Bool { self == .add || self == .move }
}

/// What you decided for one track. Stored locally until you apply it in Review.
/// Track details are copied in so the decision still displays after the track leaves the playlist.
@Model
final class Decision {
    @Attribute(.unique) var key: String
    var playlistID: String
    var trackURI: String
    var trackName: String
    var artists: String
    var artURL: URL?
    var occurrences: Int
    var actionRaw: String
    var targetPlaylistID: String?
    var targetPlaylistName: String?
    var decidedAt: Date
    var addApplied: Bool
    var removeApplied: Bool

    var action: SwipeAction {
        get { SwipeAction(rawValue: actionRaw) ?? .keep }
        set { actionRaw = newValue.rawValue }
    }

    var needsAdd: Bool { action.addsToTarget && !addApplied && targetPlaylistID != nil }
    /// A move only removes from the source once its add has succeeded, so the song is never lost.
    var needsRemove: Bool { action.removesFromSource && !removeApplied && (action == .remove || addApplied) }
    var isPending: Bool { needsAdd || needsRemove }
    var isFullyApplied: Bool {
        (!action.addsToTarget || addApplied) && (!action.removesFromSource || removeApplied)
    }

    init(track: TrackRecord, action: SwipeAction, target: PlaylistSummary? = nil) {
        key = track.key
        playlistID = track.playlistID
        trackURI = track.uri
        trackName = track.name
        artists = track.artists
        artURL = track.artURL
        occurrences = track.occurrences
        actionRaw = action.rawValue
        targetPlaylistID = target?.id
        targetPlaylistName = target?.name
        decidedAt = .now
        addApplied = false
        removeApplied = false
    }
}

extension Decision {
    /// Records (or replaces) the decision for one track. The caller saves the context.
    @discardableResult
    static func upsert(_ track: TrackRecord, _ action: SwipeAction, target: PlaylistSummary? = nil, in context: ModelContext) -> Decision {
        let key = track.key
        if let existing = try? context.fetch(FetchDescriptor<Decision>(predicate: #Predicate { $0.key == key })).first {
            existing.action = action
            existing.targetPlaylistID = target?.id
            existing.targetPlaylistName = target?.name
            existing.decidedAt = .now
            existing.addApplied = false
            existing.removeApplied = false
            return existing
        }
        let decision = Decision(track: track, action: action, target: target)
        context.insert(decision)
        return decision
    }
}
