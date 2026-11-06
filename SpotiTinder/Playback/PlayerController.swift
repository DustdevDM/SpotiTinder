import Foundation
import Observation
@preconcurrency import SpotifyiOS
import UIKit

/// Plays the current card through the Spotify app on this phone (App Remote).
///
/// 1. Connect to the Spotify app if it's running, and play there.
/// 2. If it isn't running, `authorizeAndPlayURI` opens Spotify, starts the song, and returns here.
///    This switch happens once, and the connection is then reused for later cards.
/// 3. Without the Spotify app (e.g. the simulator), fall back to the Web API on whatever device is active.
@MainActor @Observable
final class PlayerController: NSObject {
    private(set) var isPlaying = false
    private(set) var currentURI: String?
    private(set) var statusMessage: String?

    var autoplay: Bool {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }
    /// Where in the song to start, as a fraction of its length (0.3 usually lands near the chorus).
    var startFraction: Double {
        didSet { UserDefaults.standard.set(startFraction, forKey: "startFraction") }
    }

    @ObservationIgnored private let auth: SpotifyAuth
    @ObservationIgnored private let service: PlaylistService
    /// Song to start once App Remote connects after waking Spotify.
    @ObservationIgnored private var pending: (uri: String, positionMs: Int)?
    /// Token handed back by the Spotify app; preferred over the Web API token for App Remote.
    @ObservationIgnored private var remoteToken: String?
    @ObservationIgnored private var connectWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private lazy var appRemote: SPTAppRemote = {
        let configuration = SPTConfiguration(clientID: Config.clientID, redirectURL: URL(string: Config.redirectURI)!)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.delegate = self
        return remote
    }()

    private var isSpotifyInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "spotify:")!)
    }

    init(auth: SpotifyAuth, service: PlaylistService) {
        self.auth = auth
        self.service = service
        let defaults = UserDefaults.standard
        autoplay = defaults.object(forKey: "autoplay") as? Bool ?? true
        startFraction = defaults.object(forKey: "startFraction") as? Double ?? 0.3
    }

    func play(_ track: TrackRecord, fromStart: Bool = false) {
        let positionMs = fromStart ? 0 : Int(Double(track.durationMs) * startFraction)
        currentURI = track.uri
        Task { await play(uri: track.uri, positionMs: positionMs) }
    }

    /// Play/pause button. Starts `track` if it isn't the one loaded in Spotify.
    func togglePlayPause(_ track: TrackRecord?) {
        Task {
            if isPlaying {
                await pauseNow()
            } else if let track {
                if currentURI == track.uri, appRemote.isConnected, let player = appRemote.playerAPI {
                    player.resume(nil)
                    isPlaying = true
                } else {
                    play(track)
                }
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        Task { await pauseNow() }
    }

    /// Handles the redirect back from the Spotify app after `authorizeAndPlayURI`.
    func handle(_ url: URL) {
        guard let parameters = appRemote.authorizationParameters(from: url) else { return }
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            remoteToken = token
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
        } else if let message = parameters[SPTAppRemoteErrorDescriptionKey] {
            pending = nil
            statusMessage = message
        }
    }

    func sceneDidEnterBackground() {
        if appRemote.isConnected { appRemote.disconnect() }
    }

    private func play(uri: String, positionMs: Int) async {
        statusMessage = nil

        if await connectRemote(), let player = appRemote.playerAPI {
            playViaRemote(player, uri: uri, positionMs: positionMs)
            return
        }

        if isSpotifyInstalled {
            // Spotify isn't running: open it, start the song, and come back.
            pending = (uri, positionMs)
            if await !appRemote.authorizeAndPlayURI(uri) {
                pending = nil
                statusMessage = "Couldn't open Spotify. Open the Spotify app once, then tap play."
            }
            return
        }

        // No Spotify app on this device: use the Web API on whichever device is active.
        do {
            try await service.startPlayback(uri: uri, positionMs: positionMs)
            isPlaying = true
        } catch SpotifyAPIError.http(404, _) {
            statusMessage = "No Spotify device is active. Start Spotify somewhere and try again."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func pauseNow() async {
        if appRemote.isConnected, let player = appRemote.playerAPI {
            player.pause(nil)
        } else {
            try? await service.pausePlayback()
        }
        isPlaying = false
    }

    /// Connects App Remote if the Spotify app is running. Returns false if it can't connect.
    private func connectRemote() async -> Bool {
        if appRemote.isConnected { return true }
        guard isSpotifyInstalled else { return false }
        var token = remoteToken
        if token == nil { token = try? await auth.validAccessToken() }
        guard let token else { return false }
        if appRemote.isConnected { return true }

        let isFirstWaiter = connectWaiters.isEmpty
        return await withCheckedContinuation { continuation in
            connectWaiters.append(continuation)
            guard isFirstWaiter else { return }
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
            Task {
                try? await Task.sleep(for: .seconds(4))
                self.finishConnecting(false)
            }
        }
    }

    private func finishConnecting(_ connected: Bool) {
        let waiters = connectWaiters
        connectWaiters = []
        waiters.forEach { $0.resume(returning: connected) }
    }

    private func playViaRemote(_ player: SPTAppRemotePlayerAPI, uri: String, positionMs: Int) {
        player.play(uri) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.statusMessage = error.localizedDescription
                    return
                }
                self.isPlaying = true
                guard positionMs > 0 else { return }
                // Give Spotify a moment to load the track before seeking.
                try? await Task.sleep(for: .milliseconds(400))
                guard self.currentURI == uri else { return }
                self.appRemote.playerAPI?.seek(toPosition: positionMs, callback: nil)
            }
        }
    }
}

extension PlayerController: @preconcurrency SPTAppRemoteDelegate {
    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        statusMessage = nil
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: nil)
        finishConnecting(true)
        if let pending, let player = appRemote.playerAPI {
            // Back from waking Spotify: it started the song from the beginning, so jump to the start point.
            self.pending = nil
            playViaRemote(player, uri: pending.uri, positionMs: pending.positionMs)
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        finishConnecting(false)
        if pending != nil {
            pending = nil
            statusMessage = "Couldn't connect to Spotify: \(error?.localizedDescription ?? "unknown error")"
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        isPlaying = false
    }
}

extension PlayerController: @preconcurrency SPTAppRemotePlayerStateDelegate {
    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        isPlaying = !playerState.isPaused
    }
}
