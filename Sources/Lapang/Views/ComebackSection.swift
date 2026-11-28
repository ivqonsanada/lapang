import LapangCore
import SwiftUI

/// The places the deletion log names, looked at again: what refilled since
/// the person last cleaned there, and how fast.
struct ComebackSection: View {
    @Environment(LapangModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                SectionHeading(
                    title: "Came back since you cleaned",
                    note: "Lapang learns from its deletion log where leftovers were, and looks there again every \(Format.duration(LapangModel.historyInterval)) while this window is open."
                )
                Spacer(minLength: 0)
                Button("Check Now") { model.checkHistory() }
                    .disabled(model.history.running)
                    .help("Look in every place you cleaned again")
            }
            GroupedRows {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let slot = model.history
        if let error = slot.error {
            message("Could not read the deletion log: \(error)") {
                Button("Try Again") { model.checkHistory() }
            }
        } else if let reports = slot.value {
            let places = reports.filter(\.folderExists)
            let refilled = places.filter { !$0.back.isEmpty }.sorted { $0.backBytes > $1.backBytes }
            let quiet = places.count - refilled.count
            if places.isEmpty {
                message("Nothing learned yet. After you delete leftovers, Lapang looks in those places again and lists here what came back.") { EmptyView() }
            } else if refilled.isEmpty {
                message("Nothing came back to the \(Format.count(places.count, "place", "places")) you cleaned.\(checked)") { EmptyView() }
            } else {
                ForEach(refilled) { report in
                    ComebackRow(report: report)
                }
                if quiet > 0 {
                    message("Nothing came back to \(Format.count(quiet, "other place", "other places")) you cleaned.\(checked)") { EmptyView() }
                }
            }
        } else if slot.running {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking in the places you cleaned…")
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.muted)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        } else {
            message("Not checked yet.") { EmptyView() }
        }
    }

    private var checked: String {
        model.historyChecked.map { " Checked \(Format.when($0))." } ?? ""
    }

    private func message<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .foregroundStyle(.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            action()
        }
        .font(.callout)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }
}

struct ComebackRow: View {
    let report: SpotReport
    @Environment(LapangModel.self) private var model

    private var spot: Spot { report.spot }

    var body: some View {
        LeftoverRow(
            symbol: spot.rule.symbol,
            title: spot.pattern.display,
            detail: "\(spot.rule.title) · \(Format.place(spot.folder, home: model.places.home))"
        ) {
            VStack(alignment: .leading, spacing: 3) {
                comeback
                Text(before)
                Button("Show in Finder") { model.reveal(spot.folder) }
                    .buttonStyle(.link)
                    // The row's status is muted; a link still reads as one.
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Show \(spot.pattern.display) in Finder")
            }
        } trailing: {
            Text(Format.bytes(report.backBytes))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Button("Review…") { model.reviewingSpot = report }
                .disabled(report.cleanable.isEmpty)
                .help(report.cleanable.isEmpty
                    ? "Everything here changed recently, so it stays"
                    : "See each folder before anything is deleted")
                .accessibilityLabel("Review \(spot.pattern.display)")
        }
        .onHover { inside in
            model.preview = inside ? report.cleanableBytes : 0
        }
    }

    private var before: String {
        let what = "Deleted here before: \(Format.count(spot.itemsDeleted, spot.rule.noun.0, spot.rule.noun.1)), \(Format.bytes(spot.bytesFreed))"
        return spot.cleanings > 1 ? "\(what), over \(spot.cleanings.formatted()) cleanings." : "\(what)."
    }

    /// How many came back and how fast: the line that gives a leak away.
    private var comeback: Text {
        let count = Text("\(Format.count(report.back.count, spot.rule.noun.0, spot.rule.noun.1)) since \(Format.when(spot.lastCleaned))")
        guard let perDay = report.bytesPerDay else { return count }
        let rate = Text("about \(Format.bytes(Int64(perDay))) a day")
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
        return Text("\(count) · \(rate)")
    }
}
