import LapangCore
import SwiftUI

struct SettingsView: View {
    @Environment(LapangModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Stepper(value: hours(\.browserIdle), in: 1...72) {
                    Text("Test browser profiles: idle for \(Format.count(Int(model.settings.rules.browserIdle / 3600), "hour", "hours"))")
                }
                Stepper(value: hours(\.scratchIdle), in: 1...72) {
                    Text("Headless Chrome scratch: idle for \(Format.count(Int(model.settings.rules.scratchIdle / 3600), "hour", "hours"))")
                }
                Stepper(value: hours(\.copiesIdle), in: 1...72) {
                    Text("Repeated copies: idle for \(Format.count(Int(model.settings.rules.copiesIdle / 3600), "hour", "hours"))")
                }
            } header: {
                Text("Temp folders")
            }
            Section {
                Stepper(value: days(\.claudeTempIdle), in: 1...30) {
                    Text("Session temp: idle for \(Format.count(Int(model.settings.rules.claudeTempIdle / 86400), "day", "days"))")
                }
                Stepper(value: days(\.subagentAge), in: 1...90) {
                    Text("Subagent logs: older than \(Format.count(Int(model.settings.rules.subagentAge / 86400), "day", "days"))")
                }
            } header: {
                Text("Claude Code")
            }
            Section {
                Stepper(value: days(\.projectIdle), in: 1...90) {
                    Text("Dependencies and builds: idle for \(Format.count(Int(model.settings.rules.projectIdle / 86400), "day", "days"))")
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("A folder is offered for cleaning only when nothing inside it changed for this long. A change here applies to the last scan straight away.")
                    .foregroundStyle(.muted)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hours(_ key: WritableKeyPath<RuleSettings, TimeInterval>) -> Binding<Int> {
        Binding(
            get: { Int(model.settings.rules[keyPath: key] / 3600) },
            set: { model.settings.rules[keyPath: key] = TimeInterval($0) * 3600 }
        )
    }

    private func days(_ key: WritableKeyPath<RuleSettings, TimeInterval>) -> Binding<Int> {
        Binding(
            get: { Int(model.settings.rules[keyPath: key] / 86400) },
            set: { model.settings.rules[keyPath: key] = TimeInterval($0) * 86400 }
        )
    }
}
