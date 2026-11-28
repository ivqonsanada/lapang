import LapangCore
import SwiftUI

struct LeftoversSection: View {
    let review: (RuleID) -> Void
    let cleanCaches: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Leftovers",
                note: "Nothing is deleted until you review the list and confirm it."
            )
            // Four peers with one layout: the number is what differs between
            // them, so it is the largest type in each row.
            GroupedRows {
                ForEach(RuleID.allCases) { rule in
                    RuleRow(rule: rule) { review(rule) }
                }
                CachesRow(clean: cleanCaches)
            }
        }
    }
}

/// The shared row shape: icon, title, one plain line, a status line, and on
/// the right the size and the Review button.
struct LeftoverRow<Status: View, Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var status: Status
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.muted)
                .frame(width: 28, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.muted)
                    .fixedSize(horizontal: false, vertical: true)
                status
                    .font(.callout)
                    .foregroundStyle(.muted)
                    .padding(.top, 2)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                trailing
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .contentShape(.rect)
    }
}

struct RuleRow: View {
    let rule: RuleID
    let review: () -> Void
    @Environment(LapangModel.self) private var model

    private var slot: Slot<RuleReport> { model.rules[rule] ?? Slot() }

    var body: some View {
        LeftoverRow(symbol: rule.symbol, title: rule.title, detail: rule.detail) {
            status
        } trailing: {
            trailing
        }
        .onHover { inside in
            model.preview = inside ? (slot.value?.cleanableBytes ?? 0) : 0
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = slot.error {
            HStack(spacing: 8) {
                Text("Could not scan: \(error)")
                Button("Try Again") { model.scan(rule) }
                    .controlSize(.small)
            }
        } else if let report = slot.value {
            if report.items.isEmpty {
                Text(rule.emptyText)
            } else {
                summary(report)
            }
        } else if slot.running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Measuring…")
            }
        } else {
            Text("Not scanned. Use Scan Again to measure.")
        }
    }

    private func summary(_ report: RuleReport) -> Text {
        let (one, many) = rule.noun
        var count = Format.count(report.items.count, one, many)
        if rule == .repeatedCopies, let biggest = report.families.first {
            // Which script left them is easiest to tell from the name.
            let groups = report.families.count
            let family = Format.shown(Families.display(biggest.key))
            count += groups == 1 ? ", all \(family)" : " in \(groups) groups, the largest \(family)"
        }
        var tail = ""
        if report.inUse > 0 { tail += " · \(report.inUse.formatted()) changed recently, kept" }
        if report.unreadable > 0 { tail += " · \(report.unreadable.formatted()) unreadable" }
        if report.newInLastDay > 0 {
            // New ones in a day are how a leak shows, so they read louder.
            let new = Text("\(report.newInLastDay.formatted()) new in the last day")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            return Text("\(count) · \(new)\(tail)")
        }
        return Text(count + tail)
    }

    @ViewBuilder
    private var trailing: some View {
        if let report = slot.value, !report.items.isEmpty {
            // Idle folders can weigh nothing (empty, or clones of a file kept
            // elsewhere) and still be worth clearing out.
            Text(report.cleanable.isEmpty ? "All recent" : Format.bytes(report.cleanableBytes))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(report.cleanable.isEmpty ? AnyShapeStyle(.muted) : AnyShapeStyle(.primary))
            Button("Review…", action: review)
                .disabled(report.cleanable.isEmpty)
                .help(report.cleanable.isEmpty
                    ? "Everything here changed recently, so it stays"
                    : "See each folder before anything is deleted")
                .accessibilityLabel("Review \(rule.title)")
        }
    }
}

struct CachesRow: View {
    let clean: () -> Void
    @Environment(LapangModel.self) private var model

    var body: some View {
        LeftoverRow(
            symbol: "shippingbox",
            title: "Package caches",
            detail: "pnpm's stores (one per pnpm version) and npm's download cache. They refill on the next install."
        ) {
            status
        } trailing: {
            if let caches = model.caches.value, !caches.isEmpty {
                Text(Format.bytes(caches.reduce(0) { $0 + $1.bytes }))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Button("Review…", action: clean)
                    .help("See the commands before they run")
                    .accessibilityLabel("Review package caches")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let slot = model.caches
        if let error = slot.error {
            HStack(spacing: 8) {
                Text("Could not read your shell's PATH: \(error)")
                Button("Try Again") { model.scanCaches() }
                    .controlSize(.small)
            }
        } else if let caches = slot.value {
            if caches.isEmpty {
                Text("Neither pnpm nor npm was found on your shell's PATH.")
            } else {
                Text(caches.map { "\($0.name) \(Format.bytes($0.bytes))" }.joined(separator: " · ")
                    + ". What pnpm frees is known only after it runs.")
            }
        } else if slot.running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Measuring…")
            }
        } else {
            Text("Not scanned. Use Scan Again to measure.")
        }
    }
}
