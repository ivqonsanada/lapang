import LapangCore
import SwiftUI

/// The focal point: free space as one large number, and the bar under it.
struct SpaceHeader: View {
    @Environment(LapangModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Free space")
                .font(.headline)
                .foregroundStyle(.muted)
            if let space = model.space {
                number(space)
                change(space)
                CapacityBar(space: space, preview: model.preview)
                    .frame(height: 12)
                    .padding(.top, 4)
                legend(space)
            } else if let error = model.spaceError {
                Text("Free space could not be read: \(error)")
                    .foregroundStyle(.muted)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 70, alignment: .leading)
            }
        }
    }

    private func number(_ space: VolumeSpace) -> some View {
        let gigabytes = Format.gigabytes(space.free)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Rounded figures for the one big number: calm, and they roll
            // digit by digit when a clean brings space back.
            Text(gigabytes, format: .number.precision(.fractionLength(1)))
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: gigabytes))
            Text("GB")
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(.muted)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.7), value: gigabytes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.bytes(space.free)) free")
    }

    @ViewBuilder
    private func change(_ space: VolumeSpace) -> some View {
        if model.preview > 0 {
            Text("\(Format.bytes(space.free + model.preview)) free after cleaning this")
                .font(.callout.weight(.medium))
        } else if let previous = model.previousScan {
            let delta = space.free - previous.free
            let since = Format.when(previous.date)
            Group {
                if abs(delta) < 100_000_000 {
                    Text("About the same as at the last scan (\(since))")
                } else if delta > 0 {
                    Text("\(Format.bytes(delta)) more than at the last scan (\(since))")
                } else {
                    Text("\(Format.bytes(-delta)) less than at the last scan (\(since))")
                }
            }
            .font(.callout)
            .foregroundStyle(.muted)
        }
    }

    private func legend(_ space: VolumeSpace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                Swatch(style: CapacityBar.usedStyle, label: "Used \(Format.bytes(space.used))")
                Swatch(style: CapacityBar.purgeableStyle, label: "Purgeable \(Format.bytes(space.purgeable))")
                Swatch(style: CapacityBar.unusedStyle, label: "Unused \(Format.bytes(space.freeStrict))")
                Spacer(minLength: 0)
                Text("of \(Format.bytes(space.total))")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.muted)
            Text("Free space counts purgeable space, as Finder does: macOS empties it when an app needs room. df shows only the unused part.")
                .font(.callout)
                .foregroundStyle(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Used, purgeable and unused space. The accent (green, for room) marks only
/// space that is or can become free, and, under the pointer, what a rule
/// would give back.
struct CapacityBar: View {
    let space: VolumeSpace
    let preview: Int64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let usedStyle = Color.primary.opacity(0.4)
    static let purgeableStyle = Color.green.opacity(0.4)
    static let unusedStyle = Color.green
    static let previewStyle = Color.green.opacity(0.7)

    var body: some View {
        GeometryReader { geometry in
            let previewBytes = min(preview, space.used)
            let parts: [(Color, Int64)] = [
                (Self.usedStyle, space.used - previewBytes),
                (Self.previewStyle, previewBytes),
                (Self.purgeableStyle, space.purgeable),
                (Self.unusedStyle, space.freeStrict),
            ]
            let gap = 2.0
            let shown = parts.filter { $0.1 > 0 }
            let room = max(0, geometry.size.width - gap * Double(max(shown.count - 1, 0)))
            let total = max(Double(shown.reduce(0) { $0 + $1.1 }), 1)
            HStack(spacing: gap) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.0)
                        .frame(width: Double(part.1) / total * room)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: space)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: preview)
        }
        .clipShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk: \(Format.bytes(space.used)) used, \(Format.bytes(space.purgeable)) purgeable, \(Format.bytes(space.freeStrict)) unused")
    }
}

struct Swatch: View {
    let style: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(style)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(label)
        }
    }
}
