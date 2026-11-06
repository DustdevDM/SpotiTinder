import Foundation

/// Finds the same song saved more than once as different Spotify tracks:
/// single vs. album version, "2011 Remaster", deluxe editions, "feat." credits and so on.
enum DuplicateFinder {
    struct Group: Identifiable {
        /// The normalized "artist|title" both versions share.
        let id: String
        /// Oldest added first.
        let tracks: [TrackRecord]
    }

    /// Words that mark a version suffix rather than a different song. Live, acoustic and remix
    /// versions are deliberately not in here: those are usually different recordings.
    private static let versionWords = [
        "remaster", "version", "edit", "mono", "stereo", "feat", "ft.", "with ", "deluxe", "bonus",
        "single", "explicit", "clean", "anniversary", "original", "album", "from ",
    ]

    /// After " - ", anything counts as version info (remasters, soundtrack names, …)
    /// unless it names a different recording.
    private static let differentRecordingWords: Set<String> = [
        "live", "acoustic", "remix", "remixed", "mix", "instrumental", "demo", "karaoke", "cover",
        "unplugged", "reprise", "interlude", "part", "pt", "session", "sessions", "orchestral", "piano",
    ]

    static func versionGroups(in tracks: [TrackRecord], ignoring ignored: Set<String>) -> [Group] {
        Dictionary(grouping: tracks) { matchKey(artist: $0.artistKey, title: $0.name) }
            .filter { $0.value.count > 1 && !ignored.contains($0.key) }
            .map { Group(id: $0.key, tracks: $0.value.sorted(by: oldestFirst)) }
            .sorted { $0.tracks[0].name.localizedCaseInsensitiveCompare($1.tracks[0].name) == .orderedAscending }
    }

    static func matchKey(artist: String, title: String) -> String {
        "\(simplified(artist))|\(simplified(strippingVersionInfo(title)))"
    }

    /// "Song (feat. X) - Remastered 2011" → "song". Keeps parts like "(Part 2)" that change the song.
    static func strippingVersionInfo(_ title: String) -> String {
        var result = title.lowercased()
        if let dash = result.range(of: " - ") {
            let suffixWords = result[dash.upperBound...].split { !$0.isLetter && !$0.isNumber }.map(String.init)
            if differentRecordingWords.isDisjoint(with: suffixWords) {
                result = String(result[..<dash.lowerBound])
            }
        }
        result = result.replacing(#/\s*[\(\[]([^\)\]]*)[\)\]]/#) { match in
            let inside = String(match.output.1)
            return versionWords.contains(where: inside.contains) ? "" : String(match.output.0)
        }
        return result
    }

    /// Lowercase, no accents, letters and digits only, single spaces.
    private static func simplified(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func oldestFirst(_ a: TrackRecord, _ b: TrackRecord) -> Bool {
        (a.addedAt ?? .distantFuture, a.position) < (b.addedAt ?? .distantFuture, b.position)
    }

    // MARK: "Not duplicates" choices, remembered per playlist

    private static func ignoredKey(_ playlistID: String) -> String { "ignoredDuplicates.\(playlistID)" }

    static func ignoredGroups(for playlistID: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: ignoredKey(playlistID)) ?? [])
    }

    static func setIgnoredGroups(_ ids: Set<String>, for playlistID: String) {
        UserDefaults.standard.set(Array(ids), forKey: ignoredKey(playlistID))
    }
}
