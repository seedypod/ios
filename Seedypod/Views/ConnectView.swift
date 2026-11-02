import SwiftUI

/// First run: units found on the network, an address to type, or the demo.
struct ConnectView: View {
    @Environment(Connection.self) private var connection
    @State private var discovery = UnitDiscovery()
    @State private var address = ""
    @State private var resolving: String?
    @State private var problem: String?
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.podOK)
                        .frame(width: 56, height: 56)
                        .background(Theme.active, in: .rect(cornerRadius: 14))
                    Text("seedypod")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Your Gardyn, run from your own network. Nothing goes through the cloud.")
                        .font(.callout)
                        .foregroundStyle(Theme.text2)
                }
                .padding(.top, 40)

                section("On this network") {
                    found
                }

                section("Or type its address") {
                    HStack(spacing: 10) {
                        TextField("192.168.1.20 or gardyn.local", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($typing)
                            .submitLabel(.go)
                            .onSubmit(connectTyped)
                            .font(Theme.mono(15))
                            .padding(12)
                            .background(Theme.app, in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line2))
                        Button("Connect", action: connectTyped)
                            .buttonStyle(.borderedProminent)
                            .disabled(Connection.baseURL(from: address) == nil)
                    }
                    Text("Core listens on port 3000 unless you changed it.")
                        .font(.caption)
                        .foregroundStyle(Theme.text3)
                }

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.podAttention)
                }

                Button {
                    connection.startDemo()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Gardyn? Try the demo")
                            .font(.headline)
                        Text("A simulated tower on day 19 of a grow, right on this phone.")
                            .font(.footnote)
                            .foregroundStyle(Theme.text2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .card()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("demo")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    @ViewBuilder private var found: some View {
        VStack(spacing: 0) {
            if discovery.units.isEmpty {
                HStack(spacing: 10) {
                    switch discovery.state {
                    case .denied:
                        Image(systemName: "wifi.exclamationmark")
                        Text("Turn on Local Network for seedypod in Settings › Privacy & Security.")
                    case .failed:
                        Image(systemName: "exclamationmark.triangle")
                        Text("Couldn't search the network.")
                        Spacer()
                        Button("Retry") { discovery.start() }
                    default:
                        ProgressView()
                        Text("Looking for units…")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            ForEach(discovery.units) { unit in
                Button {
                    Task { await pick(unit) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(unit.name).font(.body.weight(.medium))
                            Text([unit.txt.version.map { "core \($0)" }, unit.txt.needsKey ? "needs an API key" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        if resolving == unit.id { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(Theme.text3) }
                    }
                    .padding(16)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if unit != discovery.units.last { Divider().overlay(Theme.line1) }
            }
        }
        .card()
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Theme.mono(11, .medium))
                .tracking(0.8)
                .foregroundStyle(Theme.text3)
            content()
        }
    }

    private func pick(_ unit: UnitDiscovery.Unit) async {
        resolving = unit.id
        defer { resolving = nil }
        guard let url = await discovery.resolve(unit) else {
            problem = "Found \(unit.name) but couldn't reach it."
            return
        }
        problem = nil
        connection.connect(url, name: unit.name)
    }

    private func connectTyped() {
        guard let url = Connection.baseURL(from: address) else {
            problem = "That doesn't look like an address."
            return
        }
        typing = false
        Task {
            // Check it answers before leaving this screen, so a typo isn't a blank Home.
            do {
                _ = try await CoreClient(baseURL: url, apiKey: connection.apiKey).systemInfo()
                problem = nil
                connection.connect(url, name: url.host())
            } catch APIError.unauthorized {
                problem = nil
                connection.connect(url, name: url.host())
            } catch {
                problem = "No seedypod answered at \(url.host() ?? address): \(error.localizedDescription)"
            }
        }
    }
}
