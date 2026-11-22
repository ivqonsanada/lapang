import LapangCore
import SwiftUI

/// Rule 5: the two commands, shown as they will run, each with a checkbox.
struct CacheSheet: View {
    let caches: [PackageCache]

    @Environment(LapangModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String>
    @State private var running: String?
    @State private var outcomes: [String: LapangModel.CleanOutcome] = [:]
    @State private var finished = false

    init(caches: [PackageCache]) {
        self.caches = caches
        _chosen = State(initialValue: Set(caches.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clean package caches?")
                    .font(.title2.weight(.semibold))
                Text("They refill themselves: the next install downloads what it needs again. Pruning a large pnpm store takes a few minutes.")
                    .font(.callout)
                    .foregroundStyle(.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(caches) { cache in
                row(cache)
            }
            HStack {
                Spacer()
                if finished {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(running != nil)
                    Button(action: start) {
                        Text(chosen.count == 1 ? "Run 1 Command" : "Run \(chosen.count) Commands")
                    }
                    .disabled(chosen.isEmpty || running != nil)
                }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(running != nil)
    }

    /// The whole row is the checkbox's label, so clicking the command ticks it.
    private func row(_ cache: PackageCache) -> some View {
        Toggle(isOn: Binding(
            get: { chosen.contains(cache.id) },
            set: { on in
                if on { chosen.insert(cache.id) } else { chosen.remove(cache.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cache.commandLine)
                        .font(.body.monospaced())
                    if let version = cache.version {
                        Text("with pnpm \(version)")
                            .font(.callout)
                            .foregroundStyle(.muted)
                    }
                }
                Text(explanation(cache))
                    .font(.callout)
                    .foregroundStyle(.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if running == cache.id {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Running…")
                    }
                    .font(.callout)
                    .foregroundStyle(.muted)
                } else if let outcome = outcomes[cache.id] {
                    result(outcome)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(running != nil || finished)
    }

    private func explanation(_ cache: PackageCache) -> String {
        let place = Format.path(cache.folder, home: model.places.home)
        switch cache.kind {
        case .pnpm: return "Removes packages no project on this Mac uses any more. Store: \(Format.bytes(cache.bytes)) in \(place)."
        case .npm: return "Empties npm's download cache. Cache: \(Format.bytes(cache.bytes)) in \(place)."
        }
    }

    private func result(_ outcome: LapangModel.CleanOutcome) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if outcome.succeeded {
                Text(outcome.freed.map { "Done, \(Format.bytes($0)) freed." } ?? "Done.")
                    .font(.callout.weight(.semibold))
            } else {
                Text("Did not finish.")
                    .font(.callout.weight(.semibold))
            }
            if !outcome.output.isEmpty {
                Text(outcome.output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.muted)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 2)
    }

    private func start() {
        let order = caches.filter { chosen.contains($0.id) }
        Task {
            for cache in order {
                running = cache.id
                outcomes[cache.id] = await model.clean(cache)
            }
            running = nil
            finished = true
            model.cleaningFinished()
        }
    }
}
