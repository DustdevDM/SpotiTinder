#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// Launch with `-demo` to open the swipe deck with fake songs, without logging in.
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static let playlist: PlaylistSummary = {
        let json = #"{"id":"demo","name":"10 Years of Bangers","images":[],"owner":{"id":"me"},"snapshot_id":"demo","items":{"total":6}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(PlaylistSummary.self, from: Data(json.utf8))
    }()

    @MainActor
    static func seed(_ context: ModelContext) {
        guard (try? context.fetchCount(FetchDescriptor<TrackRecord>())) == 0 else { return }
        let songs = [
            ("Midnight Drive", "The Neon Lights", "Afterglow", "2012-06-01", "2015-03-04T12:00:00Z"),
            ("Paper Planes Again", "Juniper & The Sea", "Tides", "2014-01-10", "2016-07-21T12:00:00Z"),
            ("Glass Hearts", "Velvet Static", "Static Bloom", "2016-09-09", "2017-11-02T12:00:00Z"),
            ("Summer in Reverse", "Northbound", "Compass", "2018-05-05", "2019-06-15T12:00:00Z"),
            ("Low Tide Lullaby", "Marlowe", "Harbor", "2020-02-02", "2021-01-01T12:00:00Z"),
            ("Electric Avenue Café", "Polaroid Kids", "Snapshots", "2022-08-08", "2024-04-04T12:00:00Z"),
            // Same songs as other releases, for the Duplicates screen.
            ("Midnight Drive - Single Version", "The Neon Lights", "Midnight Drive", "2012-03-01", "2018-02-02T12:00:00Z"),
            ("Glass Hearts (Deluxe Edition) - 2021 Remaster", "Velvet Static", "Static Bloom (Deluxe)", "2021-01-01", "2022-05-05T12:00:00Z"),
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for (index, song) in songs.enumerated() {
            let json = """
            {"uri":"spotify:track:demo\(index)","name":"\(song.0)","duration_ms":210000,
             "artists":[{"name":"\(song.1)"}],"album":{"name":"\(song.2)","release_date":"\(song.3)","images":[]}}
            """
            let track = try! decoder.decode(Track.self, from: Data(json.utf8))
            let record = TrackRecord(playlistID: "demo", track: track, addedAt: try? Date(song.4, strategy: .iso8601), position: index)
            if index == 2 { record.occurrences = 2 }
            context.insert(record)
        }
        // `-demoBig` adds a playlist-sized load: 1,330 more songs, most of them already decided.
        if ProcessInfo.processInfo.arguments.contains("-demoBig") {
            let actions: [SwipeAction] = [.keep, .remove, .move, .keep, .add]
            for index in songs.count..<1336 {
                let json = #"{"uri":"spotify:track:big\#(index)","name":"Song \#(index)","duration_ms":200000,"artists":[{"name":"Artist \#(index % 97)"}],"album":{"name":"Album","release_date":"2015","images":[]}}"#
                let track = try! decoder.decode(Track.self, from: Data(json.utf8))
                let record = TrackRecord(playlistID: "demo", track: track, addedAt: Date(timeIntervalSince1970: 1_400_000_000 + Double(index) * 200_000), position: index)
                context.insert(record)
                if index < 900 {
                    let target = actions[index % 5].addsToTarget ? playlist : nil
                    context.insert(Decision(track: record, action: actions[index % 5], target: target))
                }
            }
        }
        let session = CleanupSession(playlistID: "demo", name: playlist.name, snapshotID: "demo")
        if ProcessInfo.processInfo.arguments.contains("-demoByArtist") { session.order = .byArtist }
        context.insert(session)
        try? context.save()
    }
}

struct DemoRootView: View {
    @Environment(\.modelContext) private var context
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            Text("Demo")
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .swipe(let playlist): SwipeDeckView(playlist: playlist)
                    case .review(let playlist): ReviewView(playlist: playlist)
                    case .duplicates(let playlist): DuplicatesView(playlist: playlist)
                    }
                }
        }
        .task {
            DemoData.seed(context)
            path = ProcessInfo.processInfo.arguments.contains("-demoDuplicates")
                ? [.duplicates(DemoData.playlist)]
                : [.swipe(DemoData.playlist)]
            // `-demoReview` also opens Review from the deck, like tapping the toolbar button.
            if ProcessInfo.processInfo.arguments.contains("-demoReview") {
                try? await Task.sleep(for: .seconds(2))
                path.append(.review(DemoData.playlist))
            }
        }
    }
}
#endif
