import Foundation
import Observation

/// Every Web API path the app uses lives here.
@MainActor @Observable
final class PlaylistService {
    @ObservationIgnored let client: SpotifyClient

    private(set) var user: SpotifyUser?
    private(set) var playlists: [PlaylistSummary] = []
    /// Your Liked Songs as a pseudo-playlist, or nil if it couldn't be loaded.
    private(set) var likedSongs: PlaylistSummary?
    private(set) var likedSongsError: String?

    /// Only the owner can edit a playlist.
    var ownedPlaylists: [PlaylistSummary] {
        playlists.filter { $0.owner.id == user?.id }
    }

    init(client: SpotifyClient) {
        self.client = client
    }

    // MARK: Reading

    func loadLibrary() async throws {
        async let fetchedUser = currentUser()
        async let fetchedPlaylists = myPlaylists()
        (user, playlists) = try await (fetchedUser, fetchedPlaylists)
        do {
            likedSongs = try await likedSongsSummary()
            likedSongsError = nil
        } catch {
            likedSongs = nil
            likedSongsError = error.localizedDescription
        }
    }

    /// Liked Songs has no snapshot_id, so its size plus the newest "added" date stands in for one.
    func likedSongsSummary() async throws -> PlaylistSummary {
        let page: Paging<PlaylistItem> = try await client.get(client.url("me/tracks", query: ["limit": "1"]))
        let total = page.total ?? 0
        let newest = Int(page.items.first?.addedAt?.timeIntervalSince1970 ?? 0)
        return PlaylistSummary(
            id: PlaylistSummary.likedSongsID,
            name: "Liked Songs",
            images: [],
            owner: .init(id: user?.id ?? "", displayName: user?.displayName),
            snapshotId: "\(total)-\(newest)",
            trackCount: total
        )
    }

    func currentUser() async throws -> SpotifyUser {
        try await client.get(client.url("me"))
    }

    func myPlaylists() async throws -> [PlaylistSummary] {
        try await allPages(client.url("me/playlists", query: ["limit": "50"]))
    }

    func playlist(_ playlistID: String) async throws -> PlaylistSummary {
        if playlistID == PlaylistSummary.likedSongsID { return try await likedSongsSummary() }
        return try await client.get(client.url("playlists/\(playlistID)"))
    }

    func playlistItems(_ playlistID: String) async throws -> [PlaylistItem] {
        if playlistID == PlaylistSummary.likedSongsID {
            return try await allPages(client.url("me/tracks", query: ["limit": "50"]))
        }
        do {
            return try await allPages(client.url("playlists/\(playlistID)/items", query: ["limit": "100"]))
        } catch SpotifyAPIError.http(404, _) {
            // Older endpoint name, in case `/items` isn't available.
            return try await allPages(client.url("playlists/\(playlistID)/tracks", query: ["limit": "100"]))
        }
    }

    // MARK: Writing

    static let batchSize = 100

    func createPlaylist(name: String, description: String = "Made with SpotiTinder") async throws -> PlaylistSummary {
        struct Body: Encodable {
            let name: String
            let description: String
            let `public`: Bool
        }
        let body = Body(name: name, description: description, public: false)
        let created: PlaylistSummary
        do {
            created = try await client.request("POST", client.url("me/playlists"), body: body)
        } catch SpotifyAPIError.http(404, _) {
            // Older endpoint, in case `/me/playlists` doesn't accept POST.
            let userID = if let user { user.id } else { try await currentUser().id }
            created = try await client.request("POST", client.url("users/\(userID)/playlists"), body: body)
        }
        playlists.insert(created, at: 0)
        return created
    }

    /// Appends up to `batchSize` tracks to a playlist.
    /// Appends up to `batchSize` tracks, or inserts them at `position` (0-based) if given.
    func addTracks(_ uris: [String], to playlistID: String, at position: Int? = nil) async throws {
        struct Body: Encodable {
            let uris: [String]
            let position: Int?
        }
        let body = Body(uris: uris, position: position)
        do {
            try await client.perform("POST", client.url("playlists/\(playlistID)/items"), body: body)
        } catch SpotifyAPIError.http(404, _) {
            try await client.perform("POST", client.url("playlists/\(playlistID)/tracks"), body: body)
        }
    }

    /// Removes up to `batchSize` tracks (every occurrence of each URI) from a playlist.
    func removeTracks(_ uris: [String], from playlistID: String) async throws {
        if playlistID == PlaylistSummary.likedSongsID { return try await unlike(uris) }
        struct Ref: Encodable { let uri: String }
        struct ItemsBody: Encodable { let items: [Ref] }
        struct TracksBody: Encodable { let tracks: [Ref] }
        let refs = uris.map(Ref.init)
        do {
            try await client.perform("DELETE", client.url("playlists/\(playlistID)/items"), body: ItemsBody(items: refs))
        } catch SpotifyAPIError.http(let status, _) where status == 404 || status == 400 {
            try await client.perform("DELETE", client.url("playlists/\(playlistID)/tracks"), body: TracksBody(tracks: refs))
        }
    }

    /// Removes tracks from Liked Songs.
    private func unlike(_ uris: [String]) async throws {
        for chunk in uris.chunked(into: 40) {
            do {
                try await client.send("DELETE", client.url("me/library", query: ["uris": chunk.joined(separator: ",")]))
            } catch SpotifyAPIError.http(let status, _) where status == 404 || status == 400 {
                // Older endpoint, which takes bare track IDs.
                let ids = chunk.map { $0.replacingOccurrences(of: "spotify:track:", with: "") }
                try await client.send("DELETE", client.url("me/tracks", query: ["ids": ids.joined(separator: ",")]))
            }
        }
    }

    // MARK: Playback (needs an active Spotify device)

    func startPlayback(uri: String, positionMs: Int) async throws {
        struct Body: Encodable {
            let uris: [String]
            let positionMs: Int
        }
        try await client.perform("PUT", client.url("me/player/play"), body: Body(uris: [uri], positionMs: positionMs))
    }

    func resumePlayback() async throws {
        try await client.send("PUT", client.url("me/player/play"))
    }

    func pausePlayback() async throws {
        try await client.send("PUT", client.url("me/player/pause"))
    }

    private func allPages<Item: Decodable>(_ first: URL) async throws -> [Item] {
        var results: [Item] = []
        var next: URL? = first
        while let url = next {
            let page: Paging<Item> = try await client.get(url)
            results += page.items
            next = page.next
        }
        return results
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
