import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Agent Notch") {
                Text("This scaffold launches the dynamic-notch shell with mock sessions.")
                Text("Harness adapters are specified in spec.md and are not implemented yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
