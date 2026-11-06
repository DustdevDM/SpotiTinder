import SwiftData
import SwiftUI

struct SwipeDeckView: View {
    let playlist: PlaylistSummary

    @Environment(\.modelContext) private var context
    @Environment(PlayerController.self) private var player
    @State private var model: SwipeViewModel?
    @State private var dragOffset: CGSize = .zero
    @State private var isFlyingOut = false
    @State private var showTargetSheet = false
    /// Set when the target sheet was opened for "all songs by this artist" instead of one card.
    @State private var targetBatch: [TrackRecord]?
    @State private var showResetConfirm = false

    private let swipeThreshold: CGFloat = 110

    var body: some View {
        Group {
            if let model {
                deck(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil {
                model = SwipeViewModel(playlistID: playlist.id, context: context)
            } else {
                // Coming back from Review: decisions may have been edited there.
                model?.reload()
            }
        }
        .onDisappear { player.pause() }
    }

    @ViewBuilder
    private func deck(_ model: SwipeViewModel) -> some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            ProgressHeader(model: model)

            if model.currentArtistTracks.count > 1 {
                artistBar(model)
            }

            ZStack {
                if model.queue.isEmpty {
                    finished(model)
                } else {
                    ForEach(Array(model.queue.prefix(3).enumerated()).reversed(), id: \.element.key) { index, track in
                        let isTop = index == 0
                        TrackCardView(track: track)
                            .overlay { if isTop { SwipeStamp(offset: dragOffset) } }
                            .scaleEffect(isTop ? 1 : 1 - CGFloat(index) * 0.04)
                            .offset(y: isTop ? 0 : CGFloat(index) * 10)
                            .offset(isTop ? dragOffset : .zero)
                            .rotationEffect(.degrees(isTop ? Double(dragOffset.width / 20) : 0))
                            .allowsHitTesting(isTop)
                            .gesture(dragGesture(model))
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if let message = player.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            controls(model)
        }
        .padding()
        .sensoryFeedback(.impact(weight: .medium), trigger: model.history.count)
        .onChange(of: model.current?.uri, initial: true) {
            if player.autoplay, let track = model.current { player.play(track) }
        }
        .sheet(isPresented: $showTargetSheet, onDismiss: { targetBatch = nil }) {
            if let batch = targetBatch {
                TargetPlaylistSheet(sourcePlaylistID: playlist.id, title: "All \(batch.count) songs by \(batch[0].artistKey)") { target, action in
                    withAnimation(.spring) { model.decide(batch, action, target: target) }
                }
            } else if let track = model.current {
                TargetPlaylistSheet(sourcePlaylistID: playlist.id, title: track.name) { target, action in
                    swipe(action, target: target)
                }
            }
        }
        .confirmationDialog("Start over?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Start a new round", role: .destructive) {
                withAnimation { model.resetProgress() }
            }
        } message: {
            Text(resetMessage(model))
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { optionsMenu(model) }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.review(playlist)) {
                    Label("Review", systemImage: "checklist")
                }
            }
        }
    }

    /// "Artist · 12 songs left" with actions that decide all of them at once.
    private func artistBar(_ model: SwipeViewModel) -> some View {
        let tracks = model.currentArtistTracks
        let artist = tracks[0].artistKey
        return HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.secondary)
            Text("\(artist) · \(tracks.count) songs left")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Keep all \(tracks.count)", systemImage: "heart.fill") {
                    withAnimation(.spring) { model.decide(tracks, .keep) }
                }
                Button("Add or move all \(tracks.count)…", systemImage: "arrow.up.right") {
                    targetBatch = tracks
                    showTargetSheet = true
                }
                Button("Remove all \(tracks.count)", systemImage: "xmark", role: .destructive) {
                    withAnimation(.spring) { model.decide(tracks, .remove) }
                }
            } label: {
                Text("Decide all")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(isFlyingOut)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private func resetMessage(_ model: SwipeViewModel) -> String {
        let pending = (try? context.fetch(FetchDescriptor<Decision>()))?
            .filter { $0.playlistID == playlist.id && $0.isPending }.count ?? 0
        let base = "Every song in \(playlist.name) comes back into the deck. Songs already removed on Spotify stay removed."
        return pending == 0 ? base : base + " Your \(pending) changes that haven't been applied yet will be discarded."
    }

    private func controls(_ model: SwipeViewModel) -> some View {
        HStack(spacing: 18) {
            CircleButton(symbol: "arrow.uturn.backward", color: .yellow, size: 48) { model.undo() }
                .disabled(!model.canUndo)
            CircleButton(symbol: "xmark", color: .red, size: 66) { swipe(.remove) }
            CircleButton(symbol: "arrow.up.right", color: .blue, size: 52) { showTargetSheet = true }
            CircleButton(symbol: "heart.fill", color: .green, size: 66) { swipe(.keep) }
            CircleButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", color: .primary, size: 48) {
                player.togglePlayPause(model.current)
            }
            .contextMenu {
                if let track = model.current {
                    Button("Play from the start", systemImage: "backward.end.fill") { player.play(track, fromStart: true) }
                }
            }
        }
        .disabled(model.current == nil || isFlyingOut)
    }

    private func finished(_ model: SwipeViewModel) -> some View {
        ContentUnavailableView {
            Label("All done", systemImage: "checkmark.seal.fill")
        } description: {
            Text(model.yearFilter == nil
                 ? "You've been through every song. Review your changes to apply them to Spotify."
                 : "No songs left from \(String(model.yearFilter!)).")
        } actions: {
            NavigationLink("Review changes", value: Route.review(playlist))
                .buttonStyle(.borderedProminent)
            Button("Start a new round") { showResetConfirm = true }
        }
    }

    private func optionsMenu(_ model: SwipeViewModel) -> some View {
        @Bindable var model = model
        @Bindable var player = player
        return Menu {
            Picker("Order", selection: $model.order) {
                ForEach(DeckOrder.allCases) { Text($0.title).tag($0) }
            }
            Picker("Year added", selection: $model.yearFilter) {
                Text("All years").tag(Int?.none)
                ForEach(model.availableYears, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
            }
            .pickerStyle(.menu)
            Section {
                Button("Start over…", systemImage: "arrow.counterclockwise") { showResetConfirm = true }
            }
            Section("Playback") {
                Toggle("Autoplay", isOn: $player.autoplay)
                Picker("Start at", selection: $player.startFraction) {
                    Text("Beginning").tag(0.0)
                    Text("20%").tag(0.2)
                    Text("30%").tag(0.3)
                    Text("50%").tag(0.5)
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
    }

    private func dragGesture(_ model: SwipeViewModel) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isFlyingOut else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isFlyingOut else { return }
                let translation = value.translation
                let predicted = value.predictedEndTranslation
                if abs(translation.width) >= abs(translation.height) {
                    if translation.width > swipeThreshold || predicted.width > swipeThreshold * 3 {
                        return swipe(.keep)
                    }
                    if translation.width < -swipeThreshold || predicted.width < -swipeThreshold * 3 {
                        return swipe(.remove)
                    }
                } else if translation.height < -swipeThreshold || predicted.height < -swipeThreshold * 3 {
                    withAnimation(.spring) { dragOffset = .zero }
                    showTargetSheet = true
                    return
                }
                withAnimation(.spring) { dragOffset = .zero }
            }
    }

    private func swipe(_ action: SwipeAction, target: PlaylistSummary? = nil) {
        guard let model, let track = model.current, !isFlyingOut else { return }
        isFlyingOut = true
        let exit = switch action {
        case .keep: CGSize(width: 700, height: dragOffset.height)
        case .remove: CGSize(width: -700, height: dragOffset.height)
        case .add, .move: CGSize(width: 0, height: -1000)
        }
        withAnimation(.easeIn(duration: 0.22)) { dragOffset = exit }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            model.decide(track, action, target: target)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dragOffset = .zero }
            isFlyingOut = false
        }
    }
}

private struct CircleButton: View {
    let symbol: String
    let color: Color
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(Color(.secondarySystemBackground), in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }
}
