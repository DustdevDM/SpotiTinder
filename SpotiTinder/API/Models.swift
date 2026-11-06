import Foundation

// Spotify's 2026 Web API changes renamed some fields (playlist `tracks` -> `items`,
// playlist item `track` -> `item`), so decoding accepts both spellings.

struct Paging<Item: Decodable>: Decodable {
    let items: [Item]
    let next: URL?
    let total: Int?
}

struct SpotifyUser: Decodable {
    let id: String
    let displayName: String?
}

struct SpotifyImage: Decodable, Hashable {
    let url: URL
    let width: Int?
    let height: Int?
}

extension [SpotifyImage] {
    /// The smallest image at least `minWidth` wide, falling back to the largest.
    func best(minWidth: Int) -> URL? {
        let sorted = self.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return (sorted.first { ($0.width ?? 0) >= minWidth } ?? sorted.last)?.url
    }
}

struct PlaylistSummary: Decodable, Identifiable, Hashable {
    struct Owner: Decodable, Hashable {
        let id: String
        let displayName: String?
    }

    let id: String
    let name: String
    let images: [SpotifyImage]
    let owner: Owner
    let snapshotId: String
    let trackCount: Int

    /// Liked Songs isn't a real playlist in the Web API; the app treats it as one with this ID.
    static let likedSongsID = "liked-songs"
    var isLikedSongs: Bool { id == Self.likedSongsID }

    init(id: String, name: String, images: [SpotifyImage], owner: Owner, snapshotId: String, trackCount: Int) {
        self.id = id
        self.name = name
        self.images = images
        self.owner = owner
        self.snapshotId = snapshotId
        self.trackCount = trackCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, images, owner, snapshotId, items, tracks
    }

    private struct Total: Decodable { let total: Int }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        images = (try? container.decodeIfPresent([SpotifyImage].self, forKey: .images)) ?? []
        owner = try container.decode(Owner.self, forKey: .owner)
        snapshotId = try container.decode(String.self, forKey: .snapshotId)
        trackCount = (try? container.decodeIfPresent(Total.self, forKey: .items))?.total
            ?? (try? container.decodeIfPresent(Total.self, forKey: .tracks))?.total
            ?? 0
    }
}

struct PlaylistItem: Decodable {
    let addedAt: Date?
    let isLocal: Bool
    /// Nil for episodes, unavailable tracks, or anything that isn't a regular track.
    let track: Track?

    private enum CodingKeys: String, CodingKey {
        case addedAt, isLocal, item, track
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let addedAtString = try? container.decodeIfPresent(String.self, forKey: .addedAt)
        addedAt = addedAtString.flatMap { try? Date($0, strategy: .iso8601) }
        isLocal = (try? container.decodeIfPresent(Bool.self, forKey: .isLocal)) ?? false
        track = (try? container.decodeIfPresent(Track.self, forKey: .item))
            ?? (try? container.decodeIfPresent(Track.self, forKey: .track))
    }
}

struct Track: Decodable {
    struct Artist: Decodable { let name: String }
    struct Album: Decodable {
        let name: String
        let images: [SpotifyImage]?
        let releaseDate: String?
    }

    let uri: String
    let name: String
    let durationMs: Int
    let artists: [Artist]
    let album: Album

    var releaseYear: Int? { album.releaseDate.flatMap { Int($0.prefix(4)) } }
}
