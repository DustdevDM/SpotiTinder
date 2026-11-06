import SwiftUI

/// Pick the playlist to clean up. Only playlists you own can be edited.
struct SourcePlaylistView: View {
    @Environment(SpotifyAuth.self) private var auth
    @Environment(PlaylistService.self) private var service
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var owned: [PlaylistSummary] {
        service.ownedPlaylists.sorted { $0.trackCount > $1.trackCount }
    }

    private var followed: [PlaylistSummary] {
        service.playlists.filter { $0.owner.id != service.user?.id }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            Section("Your playlists") {
                likedSongsRow
                ForEach(owned) { playlist in
                    NavigationLink(value: playlist) {
                        PlaylistRow(playlist: playlist)
                    }
                }
            }
            if !followed.isEmpty {
                Section {
                    ForEach(followed) { playlist in
                        PlaylistRow(playlist: playlist).opacity(0.5)
                    }
                } header: {
                    Text("Followed")
                } footer: {
                    Text("Spotify only lets the owner remove songs, so followed playlists can't be cleaned up.")
                }
            }
        }
        .overlay {
            if isLoading && service.playlists.isEmpty { ProgressView() }
        }
        .navigationTitle("Pick a playlist")
        .navigationDestination(for: PlaylistSummary.self) { playlist in
            PlaylistOverviewView(playlist: playlist)
        }
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .swipe(let playlist): SwipeDeckView(playlist: playlist)
            case .review(let playlist): ReviewView(playlist: playlist)
            case .duplicates(let playlist): DuplicatesView(playlist: playlist)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let name = service.user?.displayName { Text("Logged in as \(name)") }
                    Button("Log out", role: .destructive) { auth.logout() }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var likedSongsRow: some View {
        if let liked = service.likedSongs {
            NavigationLink(value: liked) {
                PlaylistRow(playlist: liked)
            }
        } else if service.user != nil {
            Button {
                auth.logout()
            } label: {
                HStack(spacing: 12) {
                    LikedSongsArtwork(size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Liked Songs").font(.headline).foregroundStyle(.primary)
                        Text(auth.hasScope("user-library-read")
                             ? "Couldn't load: \(service.likedSongsError ?? "unknown error")"
                             : "Tap to log in again and allow access")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(auth.hasScope("user-library-read"))
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await service.loadLibrary()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PlaylistRow: View {
    let playlist: PlaylistSummary

    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtwork(playlist: playlist, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.headline).lineLimit(1)
                Text("\(playlist.trackCount) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Every screen pushed below a playlist, so the whole stack uses value-based navigation.
enum Route: Hashable {
    case swipe(PlaylistSummary)
    case review(PlaylistSummary)
    case duplicates(PlaylistSummary)
}

struct PlaylistArtwork: View {
    let playlist: PlaylistSummary
    let size: CGFloat

    var body: some View {
        if playlist.isLikedSongs {
            LikedSongsArtwork(size: size)
        } else {
            ArtworkView(url: playlist.images.best(minWidth: Int(size * 3)), size: size)
        }
    }
}

struct LikedSongsArtwork: View {
    let size: CGFloat

    var body: some View {
        LinearGradient(colors: [.indigo, .purple, .teal.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 8))
    }
}

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
    }
}
