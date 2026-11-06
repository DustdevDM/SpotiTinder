import SwiftData
import SwiftUI

@main
struct SpotiTinderApp: App {
    @State private var auth: SpotifyAuth
    @State private var service: PlaylistService
    @State private var player: PlayerController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let auth = SpotifyAuth()
        let service = PlaylistService(client: SpotifyClient(auth: auth))
        _auth = State(initialValue: auth)
        _service = State(initialValue: service)
        _player = State(initialValue: PlayerController(auth: auth, service: service))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(service)
                .environment(player)
                .onOpenURL { player.handle($0) }
        }
        .modelContainer(for: [TrackRecord.self, CleanupSession.self, Decision.self])
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: player.sceneDidEnterBackground()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(SpotifyAuth.self) private var auth

    var body: some View {
        #if DEBUG
        if DemoData.isEnabled {
            DemoRootView()
        } else {
            content
        }
        #else
        content
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if auth.isLoggedIn {
            NavigationStack {
                SourcePlaylistView()
            }
        } else {
            LoginView()
        }
    }
}
