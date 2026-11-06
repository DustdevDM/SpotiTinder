import Foundation
import SwiftData

/// One unique track in a cached playlist. Duplicates are folded into `occurrences`,
/// because Spotify's remove-by-URI deletes every copy at once.
@Model
final class TrackRecord {
    @Attribute(.unique) var key: String
    var playlistID: String
    var uri: String
    var name: String
    var artists: String
    /// First credited artist, used to group the deck by artist.
    var primaryArtist: String = ""
    var album: String
    var artURL: URL?
    var releaseYear: Int?
    var addedAt: Date?
    var position: Int
    var durationMs: Int
    var occurrences: Int

    init(playlistID: String, track: Track, addedAt: Date?, position: Int) {
        key = Self.key(playlistID: playlistID, uri: track.uri)
        self.playlistID = playlistID
        uri = track.uri
        name = ""
        artists = ""
        album = ""
        self.position = position
        durationMs = 0
        occurrences = 1
        update(from: track, addedAt: addedAt, position: position)
    }

    func update(from track: Track, addedAt: Date?, position: Int) {
        name = track.name
        artists = track.artists.map(\.name).joined(separator: ", ")
        primaryArtist = track.artists.first?.name ?? "Unknown artist"
        album = track.album.name
        artURL = track.album.images?.best(minWidth: 600)
        releaseYear = track.releaseYear
        // Keep the earliest date seen: re-adding a song (e.g. during duplicate cleanup)
        // gives it a new date on Spotify, but the card should still show when you first added it.
        if let addedAt {
            self.addedAt = min(self.addedAt ?? addedAt, addedAt)
        }
        self.position = position
        durationMs = track.durationMs
        occurrences = 1
    }

    var artistKey: String { primaryArtist.isEmpty ? artists : primaryArtist }

    static func key(playlistID: String, uri: String) -> String {
        "\(playlistID)|\(uri)"
    }
}
