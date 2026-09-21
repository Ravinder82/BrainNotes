import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("AI") {
                    NavigationLink("AI Providers") {
                        SettingsView()
                    }
                }
                Section("Research") {
                    NavigationLink("Web Search & Data") {
                        WebToolsSettingsView()
                    }
                }
                Section("KeyVault") {
                    NavigationLink("Enter") {
                        PasswordsView()
                    }
                }
                Section("About") {
                    LabeledContent("App", value: "BrainNotes")
                    LabeledContent("Version", value: appVersion())
                }
            }
            .navigationTitle("Settings")
        }
    }
    
    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
