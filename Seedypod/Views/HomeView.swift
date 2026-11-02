import SwiftUI

/// Home: the tower across the screen, the cycle's day and pod counts over its
/// top, the readings along the bottom, and the picked pod's card above them.
/// Light, water, alerts and settings open as sheets.
struct HomeView: View {
    @Environment(Connection.self) private var connection
    @State var store: HomeStore
    @State private var selected: Int?
    @State private var panel: Panel?

    enum Panel: String, Identifiable {
        case light, water, alerts, settings
        var id: String { rawValue }
    }

    var body: some View {
        let snapshot = store.snapshot
        let pods = snapshot.map { TowerPod.join($0) } ?? []
        ZStack {
            Theme.app.ignoresSafeArea()
            if pods.isEmpty {
                Color.clear
            } else {
                TowerView(pods: pods, waterPct: snapshot?.reading(.waterLevelPct)?.value, lightLevel: snapshot?.light.map { $0.on ? $0.level : 0 } ?? 0,
                          pumpOn: snapshot?.pump?.on == true, selected: $selected) { part in
                    panel = part == .light ? .light : .water
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                header(snapshot, pods)
                Spacer(minLength: 0)
                if let pick = pods.first(where: { $0.slot == selected }) {
                    PodCard(pod: pick, store: store) { selected = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ReadingsBar(snapshot: snapshot) { panel = $0 }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(.snappy, value: selected)

            if store.loading { ProgressView().controlSize(.large) }
        }
        .task { await store.run() }
        .sheet(item: $panel) { p in
            Group {
                switch p {
                case .light: LightPanel(store: store)
                case .water: WaterPanel(store: store)
                case .alerts: AlertsPanel(store: store)
                case .settings: SettingsView(system: store.system)
                }
            }
            .presentationBackground(Theme.card)
            .presentationDetents(p == .settings ? [.large] : [.medium, .large])
        }
    }

    private func header(_ snapshot: HomeSnapshot?, _ pods: [TowerPod]) -> some View {
        let counts = PodCount.counts(pods)
        let cycle = snapshot?.grow.cycle
        let alerts = snapshot?.alerts.count ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(cycle != nil ? "Day \(Int(snapshot?.grow.day ?? 0))" : "No cycle")
                    .font(Theme.mono(28, .medium))
                Spacer()
                StatusPill(store: store, name: connection.name)
                Button { panel = .alerts } label: {
                    Image(systemName: alerts > 0 ? "bell.badge" : "bell")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.podAttention, Theme.text2)
                }
                .accessibilityLabel(alerts > 0 ? "\(alerts) alerts" : "Alerts")
                Button { panel = .settings } label: {
                    Image(systemName: "gearshape").foregroundStyle(Theme.text2)
                }
                .accessibilityLabel("Settings")
            }
            .font(.system(size: 18))
            if let cycle {
                Text([cycle.stage.capitalized, cycle.notes].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.text2)
            } else if snapshot != nil {
                Text("Start a cycle from the web UI's Grow page for thinning, harvest and nutrient reminders.")
                    .font(.footnote)
                    .foregroundStyle(Theme.text2)
            }
            HStack(spacing: 14) {
                ForEach(PodCount.allCases, id: \.self) { c in
                    HStack(spacing: 6) {
                        Circle().fill(c.color).frame(width: 7, height: 7)
                        Text("\(counts[c] ?? 0) \(c.label)")
                    }
                }
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.text2)
            if let error = store.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.podAttention)
            }
            if let failed = store.actionError {
                Label(failed, systemImage: "xmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(Theme.podAttention)
                    .onTapGesture { store.actionError = nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

/// The unit's name with a dot: green while core's event stream is live.
struct StatusPill: View {
    let store: HomeStore
    let name: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.error != nil ? Theme.podAttention : store.live ? Theme.podOK : Theme.text3)
                .frame(width: 7, height: 7)
            Text(name ?? "seedypod")
                .lineLimit(1)
        }
        .font(Theme.mono(11))
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.card.opacity(0.85), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.line1))
    }
}

extension PodCount {
    var color: Color {
        switch self {
        case .growing: Theme.podOK
        case .ready: Theme.podReady
        case .attention: Theme.podAttention
        case .empty: Theme.podEmpty
        }
    }
}

extension PodShown {
    var color: Color {
        switch self {
        case .attention: Theme.podAttention
        case .ready, .soon: Theme.podReady
        case .growing: Theme.podOK
        case .seeded: Theme.text3
        case .empty: Theme.podEmpty
        }
    }
}
