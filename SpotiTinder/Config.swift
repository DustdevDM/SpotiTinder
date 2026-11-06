import Foundation

enum Config {
    static let clientID = "581aac33e0534563a955b7bf7b0e37f2"
    static let callbackScheme = "spotitinder"
    static let redirectURI = "\(callbackScheme)://callback"

    static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-private",
        "playlist-modify-public",
        "app-remote-control",
        "user-modify-playback-state",
        "user-read-playback-state",
        "user-library-read",
        "user-library-modify",
    ]
}
