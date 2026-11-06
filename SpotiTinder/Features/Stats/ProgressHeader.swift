import SwiftUI

struct ProgressHeader: View {
    let model: SwipeViewModel

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(model.reviewedInScope) / \(model.totalInScope)")
                    .font(.headline.monospacedDigit())
                Spacer()
                HStack(spacing: 12) {
                    count(.keep, "heart.fill", .green)
                    count(.remove, "xmark", .red)
                    countMoved
                }
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
            }
            ProgressView(value: Double(model.reviewedInScope), total: Double(max(model.totalInScope, 1)))
        }
    }

    private func count(_ action: SwipeAction, _ symbol: String, _ color: Color) -> some View {
        Label("\(model.counts[action] ?? 0)", systemImage: symbol)
            .foregroundStyle(color)
    }

    private var countMoved: some View {
        Label("\((model.counts[.add] ?? 0) + (model.counts[.move] ?? 0))", systemImage: "arrow.up.right")
            .foregroundStyle(.blue)
    }
}
