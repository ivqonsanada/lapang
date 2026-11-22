import LapangCore
import SwiftUI

struct MainView: View {
    @Environment(LapangModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                SpaceHeader()
                LeftoversSection(review: { model.reviewing = $0 }, cleanCaches: { model.cleaningCaches = true })
                GrowthSection()
                Footer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 80)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 580, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        // The one glass surface: a control floating over the content while a
        // scan runs, where Liquid Glass belongs (the toolbar is glass already).
        .overlay(alignment: .bottom) {
            if model.isScanning {
                ScanBar()
                    .padding(.bottom, 18)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.isScanning)
        .toolbar {
            ToolbarItem {
                Button {
                    model.scanAll()
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(model.isScanning)
                .help("Measure everything again (⌘R)")
            }
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Idle times and log age (⌘,)")
            }
        }
        .sheet(item: $model.reviewing) { rule in
            ReviewSheet(rule: rule, items: model.report(rule)?.cleanable ?? [])
        }
        .sheet(isPresented: $model.cleaningCaches) {
            CacheSheet(caches: model.caches.value ?? [])
        }
        .task { model.start() }
    }
}

/// The floating scan status, on Liquid Glass.
struct ScanBar: View {
    @Environment(LapangModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(model.scanStatus)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            Button("Stop") { model.stopScan() }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop scanning (⌘.)")
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 460)
    }
}

/// Rows on one solid rounded surface with hairline separators, the way
/// System Settings groups them.
struct GroupedRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, 58)
                    }
                    row
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
}

struct SectionHeading: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(note)
                .font(.callout)
                .foregroundStyle(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Footer: View {
    @Environment(LapangModel.self) private var model

    var body: some View {
        HStack {
            if let lastScan = model.lastScan {
                Text("Last scan \(Format.when(lastScan))")
            }
            Spacer()
            Button("Show Deletion Log") {
                model.reveal(model.places.deletionLog)
            }
            .disabled(!model.deletionLogExists)
            .help(model.deletionLogExists
                ? "~/Library/Logs/Lapang/deleted.log, one line per folder"
                : "Nothing has been deleted yet")
        }
        .font(.callout)
        .foregroundStyle(.muted)
    }
}
