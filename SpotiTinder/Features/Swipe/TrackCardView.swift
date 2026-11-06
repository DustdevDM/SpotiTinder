import SwiftUI

struct TrackCardView: View {
    let track: TrackRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fills the card's full width and whatever height is left; the cover is cropped to fit.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    AsyncImage(url: track.artURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 64))
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .clipped()
            .overlay(alignment: .topTrailing) {
                if track.occurrences > 1 {
                    Text("Duplicate ×\(track.occurrences)")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .font(.title2.bold())
                    .lineLimit(2)
                Text(track.artists)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(track.releaseYear.map { "\(track.album) · \(String($0))" } ?? track.album)
                    .lineLimit(1)
                    .font(.subheadline)
                .foregroundStyle(.secondary)
                if let addedAt = track.addedAt {
                    Label {
                        Text("Added \(addedAt, format: .dateTime.day().month(.abbreviated).year())")
                    } icon: {
                        Image(systemName: "calendar.badge.plus")
                    }
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }
}

/// The KEEP / NOPE / MOVE stamp that fades in while dragging.
struct SwipeStamp: View {
    let offset: CGSize

    private var stamp: (text: String, color: Color, alignment: Alignment, strength: Double)? {
        let horizontal = abs(offset.width) >= abs(offset.height)
        if horizontal, offset.width > 20 { return ("KEEP", .green, .topLeading, offset.width / 110) }
        if horizontal, offset.width < -20 { return ("NOPE", .red, .topTrailing, -offset.width / 110) }
        if !horizontal, offset.height < -20 { return ("MOVE", .blue, .bottom, -offset.height / 110) }
        return nil
    }

    var body: some View {
        if let stamp {
            Text(stamp.text)
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(stamp.color)
                .padding(.horizontal, 12)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(stamp.color, lineWidth: 4))
                .rotationEffect(.degrees(stamp.alignment == .topLeading ? -15 : stamp.alignment == .topTrailing ? 15 : 0))
                .padding(28)
                .opacity(min(stamp.strength, 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stamp.alignment)
                .allowsHitTesting(false)
        }
    }
}
