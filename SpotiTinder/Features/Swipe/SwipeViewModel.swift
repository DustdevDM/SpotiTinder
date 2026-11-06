import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class SwipeViewModel {
    let playlistID: String
    private let context: ModelContext

    /// Undecided tracks in deck order; the first one is the top card.
    private(set) var queue: [TrackRecord] = []
    /// Decision keys made in this session, most recent last, for undo.
    /// Each entry is one swipe, or one "decide all songs by this artist" batch.
    private(set) var history: [[String]] = []
    private(set) var counts: [SwipeAction: Int] = [:]
    private(set) var reviewedInScope = 0
    private(set) var totalInScope = 0
    private(set) var availableYears: [Int] = []

    var order: DeckOrder {
        didSet { saveOrder(); reload() }
    }
    /// Only show tracks added in this year.
    var yearFilter: Int? {
        didSet { reload() }
    }

    var current: TrackRecord? { queue.first }

    /// Undecided songs in the deck by the current card's artist, current card included.
    var currentArtistTracks: [TrackRecord] {
        guard let artist = current?.artistKey else { return [] }
        return queue.filter { $0.artistKey == artist }
    }
    var canUndo: Bool { !history.isEmpty }

    init(playlistID: String, context: ModelContext) {
        self.playlistID = playlistID
        self.context = context
        let session = try? context.fetch(FetchDescriptor<CleanupSession>(
            predicate: #Predicate { $0.playlistID == playlistID }
        )).first
        order = session?.order ?? .oldestFirst
        reload()
    }

    func reload() {
        let playlistID = playlistID
        let tracks = (try? context.fetch(FetchDescriptor<TrackRecord>(
            predicate: #Predicate { $0.playlistID == playlistID }
        ))) ?? []
        let decisions = (try? context.fetch(Self.decisionsDescriptor(playlistID))) ?? []
        let decided = Set(decisions.map(\.trackURI))

        counts = Dictionary(grouping: decisions, by: \.action).mapValues(\.count)
        availableYears = Set(tracks.compactMap(\.addedYear)).sorted()

        let inScope = yearFilter.map { year in tracks.filter { $0.addedYear == year } } ?? tracks
        totalInScope = inScope.count
        reviewedInScope = inScope.filter { decided.contains($0.uri) }.count

        let remaining = inScope.filter { !decided.contains($0.uri) }
        switch order {
        case .oldestFirst: queue = remaining.sorted(by: Self.addedAscending)
        case .newestFirst: queue = remaining.sorted(by: Self.addedAscending).reversed()
        case .byArtist:
            // Artists with the most songs first, so the big batches come early.
            let songCounts = Dictionary(grouping: remaining, by: \.artistKey).mapValues(\.count)
            queue = remaining.sorted { a, b in
                let countA = songCounts[a.artistKey] ?? 0
                let countB = songCounts[b.artistKey] ?? 0
                if countA != countB { return countA > countB }
                if a.artistKey != b.artistKey {
                    return a.artistKey.localizedCaseInsensitiveCompare(b.artistKey) == .orderedAscending
                }
                return Self.addedAscending(a, b)
            }
        case .shuffle: queue = remaining.shuffled()
        }
    }

    func decide(_ track: TrackRecord, _ action: SwipeAction, target: PlaylistSummary? = nil) {
        decide([track], action, target: target)
    }

    /// Applies one decision to several songs at once; a single undo reverts them all.
    func decide(_ tracks: [TrackRecord], _ action: SwipeAction, target: PlaylistSummary? = nil) {
        guard !tracks.isEmpty else { return }
        for track in tracks { record(track, action, target: target) }
        try? context.save()
        history.append(tracks.map(\.key))
        let keys = Set(tracks.map(\.key))
        queue.removeAll { keys.contains($0.key) }
    }

    private func record(_ track: TrackRecord, _ action: SwipeAction, target: PlaylistSummary?) {
        Decision.upsert(track, action, target: target, in: context)
        counts[action, default: 0] += 1
        reviewedInScope += 1
    }

    /// Reverses the most recent swipe (or artist batch) from this session and puts its cards back on top.
    func undo() {
        guard let keys = history.popLast() else { return }
        var restored: [TrackRecord] = []
        for key in keys {
            guard let decision = decision(for: key), !decision.addApplied, !decision.removeApplied else { continue }
            counts[decision.action, default: 1] -= 1
            reviewedInScope -= 1
            context.delete(decision)
            if let track = try? context.fetch(FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.key == key })).first {
                restored.append(track)
            }
        }
        try? context.save()
        queue.insert(contentsOf: restored, at: 0)
    }

    /// Starts a fresh round: forgets every swipe for this playlist.
    func resetProgress() {
        ProgressReset.reset(playlistID: playlistID, context: context)
        history = []
        reload()
    }

    private func decision(for key: String) -> Decision? {
        try? context.fetch(FetchDescriptor<Decision>(predicate: #Predicate { $0.key == key })).first
    }

    private func saveOrder() {
        let playlistID = playlistID
        let session = try? context.fetch(FetchDescriptor<CleanupSession>(
            predicate: #Predicate { $0.playlistID == playlistID }
        )).first
        session?.order = order
        try? context.save()
    }

    private static func decisionsDescriptor(_ playlistID: String) -> FetchDescriptor<Decision> {
        FetchDescriptor<Decision>(predicate: #Predicate { $0.playlistID == playlistID })
    }

    private static func addedAscending(_ a: TrackRecord, _ b: TrackRecord) -> Bool {
        switch (a.addedAt, b.addedAt) {
        case let (lhs?, rhs?) where lhs != rhs: lhs < rhs
        case (nil, _?): true
        case (_?, nil): false
        default: a.position < b.position
        }
    }
}

extension TrackRecord {
    var addedYear: Int? { addedAt.map { Calendar.current.component(.year, from: $0) } }
}
