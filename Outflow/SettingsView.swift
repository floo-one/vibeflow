import OutflowCore
import SwiftUI

/// T2 placeholder. The real tabs (General, Voices, Smart read, Per-app presets, Keys)
/// arrive in T9 per docs/designs/outflow-v1.md.
struct SettingsView: View {
    var body: some View {
        TabView {
            Form {
                LabeledContent("Version", value: OutflowCore.version)
                Text("Settings tabs arrive in T9.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 320)
    }
}
