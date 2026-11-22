import LapangCore
import SwiftUI

/// Watch only: folders that took more than 1 GB in a day. A list, not
/// cards, because each finding is one path and one number.
struct GrowthSection: View {
    @Environment(LapangModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Grew in the last day",
                note: "Folders where more than 1 GB was written in the last 24 hours. Lapang only points at these; it deletes nothing here."
            )
            GroupedRows {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let slot = model.growth
        if let error = slot.error {
            message("Could not finish looking: \(error)") {
                Button("Try Again") { model.scanGrowth() }
            }
        } else if let found = slot.value {
            if slot.running, let root = model.growthRoot {
                progress("Looking again in \(Format.path(root, home: model.places.home))…")
            }
            if found.isEmpty {
                message("No folder took more than 1 GB in the last day.") { EmptyView() }
            } else {
                ForEach(found) { growth in
                    GrowthRow(growth: growth)
                }
            }
        } else if slot.running {
            progress(model.growthRoot.map { "Looking in \(Format.path($0, home: model.places.home))…" } ?? "Looking…")
        } else {
            message("Not scanned. Use Scan Again to look.") { EmptyView() }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.muted)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }

    private func message<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .foregroundStyle(.muted)
            Spacer()
            action()
        }
        .font(.callout)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }
}

struct GrowthRow: View {
    let growth: Growth
    @Environment(LapangModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 18))
                .foregroundStyle(.muted)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(growth.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text(growth.spreadOut
                    ? "\(Format.path(growth.url, home: model.places.home)), spread over its other folders"
                    : Format.path(growth.url.deletingLastPathComponent(), home: model.places.home))
                    .font(.callout)
                    .foregroundStyle(.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(growth.bytes))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("written in a day")
                    .font(.callout)
                    .foregroundStyle(.muted)
            }
            Button("Show in Finder") { model.reveal(growth.url) }
                .accessibilityLabel("Show \(growth.url.lastPathComponent) in Finder")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }
}
