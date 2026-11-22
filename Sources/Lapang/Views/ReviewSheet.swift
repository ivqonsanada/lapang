import LapangCore
import SwiftUI

/// The only way anything is deleted: every item listed with its size and
/// idle time, a checkbox each, and one button that names the total.
struct ReviewSheet: View {
    let rule: RuleID
    /// The list as it was when the sheet opened; a rescan does not change it.
    let items: [Item]

    @Environment(LapangModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var stage = Stage.choosing
    @State private var done = 0
    @State private var work: Task<Void, Never>?

    enum Stage {
        case choosing, deleting, finished(DeletionResult)
    }

    init(rule: RuleID, items: [Item]) {
        self.rule = rule
        self.items = items
        _selected = State(initialValue: Set(items.map(\.id)))
    }

    private var selectedItems: [Item] { items.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch stage {
            case .choosing, .deleting:
                choosing
            case .finished(let result):
                FinishedView(rule: rule, result: result) { dismiss() }
            }
        }
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled(isDeleting)
    }

    private var isDeleting: Bool {
        if case .deleting = stage { return true }
        return false
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(rule.reviewTitle)
                    .font(.title2.weight(.semibold))
                Text("\(rule.idleText(model.settings.rules)) Each one is checked again right before it goes, and every deletion is written to ~/Library/Logs/Lapang/deleted.log.")
                    .font(.callout)
                    .foregroundStyle(.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            HStack {
                Toggle(isOn: Binding(
                    get: { selected.count == items.count && !items.isEmpty },
                    set: { all in selected = all ? Set(items.map(\.id)) : [] }
                )) {
                    Text("\(selected.count.formatted()) of \(Format.count(items.count, rule.noun.0, rule.noun.1)) selected")
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text("Largest first")
                    .foregroundStyle(.muted)
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .disabled(isDeleting)

            Divider()
            List(items) { item in
                ItemRow(item: item, isOn: Binding(
                    get: { selected.contains(item.id) },
                    set: { on in
                        if on { selected.insert(item.id) } else { selected.remove(item.id) }
                    }
                ))
            }
            .listStyle(.inset)
            .disabled(isDeleting)
            Divider()

            HStack(spacing: 12) {
                if isDeleting {
                    ProgressView(value: Double(done), total: Double(max(selectedItems.count, 1)))
                        .frame(width: 140)
                    Text("Deleting \(done.formatted()) of \(selectedItems.count.formatted())…")
                        .font(.callout)
                        .foregroundStyle(.muted)
                        .monospacedDigit()
                }
                Spacer()
                if isDeleting {
                    Button("Stop") { work?.cancel() }
                        .help("Stops after the folder being deleted now")
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(role: .destructive, action: start) {
                        Text("Delete \(Format.bytes(selectedBytes))")
                            .monospacedDigit()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func start() {
        let chosen = selectedItems
        stage = .deleting
        done = 0
        work = Task {
            let result = await model.delete(chosen) { count in
                Task { @MainActor in done = count }
            }
            stage = .finished(result)
        }
    }
}

struct ItemRow: View {
    let item: Item
    @Binding var isOn: Bool
    @Environment(LapangModel.self) private var model

    var body: some View {
        let lines = Format.lines(item, home: model.places.home)
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lines.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(lines.detail)
                        .font(.callout)
                        .foregroundStyle(.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.bytes(item.bytes))
                        .monospacedDigit()
                    Text("idle \(Format.duration(Date().timeIntervalSince(item.lastChange)))")
                        .font(.callout)
                        .foregroundStyle(.muted)
                }
            }
            .padding(.vertical, 3)
        }
        .toggleStyle(.checkbox)
        .contextMenu {
            Button("Show in Finder") { model.reveal(item.url) }
        }
    }
}

struct FinishedView: View {
    let rule: RuleID
    let result: DeletionResult
    let close: () -> Void
    @Environment(LapangModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.freedBytes > 0 ? "\(Format.bytes(result.freedBytes)) freed" : "Nothing was deleted")
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.muted)
            }
            if !result.skipped.isEmpty {
                Text("Kept")
                    .font(.headline)
                List(result.skipped, id: \.item.id) { skip in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.lines(skip.item, home: model.places.home).title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(skip.reason.summary)
                            .font(.callout)
                            .foregroundStyle(.muted)
                    }
                }
                .listStyle(.inset)
            } else {
                Spacer()
            }
            HStack {
                Button("Show Deletion Log") { model.reveal(model.places.deletionLog) }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var summary: String {
        let (one, many) = rule.noun
        var parts = ["Deleted \(Format.count(result.deleted.count, one, many))."]
        if !result.skipped.isEmpty {
            parts.append("\(Format.count(result.skipped.count, one, many)) kept, listed below.")
        }
        return parts.joined(separator: " ")
    }
}
