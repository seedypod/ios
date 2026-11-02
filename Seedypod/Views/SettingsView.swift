import SwiftUI

/// The unit, the connection and its key, and a way back to the connect screen.
struct SettingsView: View {
    @Environment(Connection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    let system: SystemInfo?
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Unit") {
                    row("Name", connection.name ?? "—")
                    switch connection.target {
                    case .unit(let url): row("Address", url.absoluteString)
                    case .demo: row("Address", "Demo on this phone")
                    case nil: EmptyView()
                    }
                    if let hal = system?.system {
                        row("Model", hal.model)
                        if let board = hal.board { row("Board", board) }
                        row("Unit ID", hal.unitId)
                        row("HAL", hal.halVersion)
                    }
                    if let system {
                        row("Core", system.coreVersion)
                        row("Hardware daemon", system.halOnline ? "online" : "offline")
                    }
                }

                if !connection.isDemo {
                    Section {
                        SecureField("API key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.mono(15))
                            .onSubmit { connection.apiKey = key }
                        Button("Save key") { connection.apiKey = key }
                            .disabled(key == connection.apiKey)
                    } header: {
                        Text("API key")
                    } footer: {
                        Text("Only needed when the unit has one set under Settings › Security on its web UI. It's kept in this iPhone's Keychain.")
                    }
                }

                Section {
                    Button(connection.isDemo ? "Leave the demo" : "Connect to another unit", role: .destructive) {
                        dismiss()
                        connection.disconnect()
                    }
                }

                Section {
                    Link("seedypod docs", destination: URL(string: "https://seedypod.github.io")!)
                    Link("Source (AGPL-3.0)", destination: URL(string: "https://github.com/seedypod/ios")!)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.app)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { key = connection.apiKey }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.text2)
                .textSelection(.enabled)
        }
    }
}
