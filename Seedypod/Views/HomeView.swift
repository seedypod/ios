import SwiftUI

/// Home: the tower across the screen, the cycle's day and pod counts over its
/// top, the readings along the bottom, and the picked pod's card above them.
/// Light, water, alerts and settings open as sheets.
struct HomeView: View {
    @Environment(Connection.self) private var connection
    @Environment(\.scenePhase) private var scenePhase
    @State var store: HomeStore
    @State private var selected: Int?
    @State private var panel: Panel?

    enum Panel: String, Identifiable {
        case light, water, alerts, settings, pods
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
                // Phone-width on an iPad, so the card and readings don't stretch across the tower.
                Group {
                    if let pick = pods.first(where: { $0.slot == selected }) {
                        PodCard(pod: pick, store: store) { selected = nil }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    ReadingsBar(snapshot: snapshot) { panel = $0 }
                }
                .frame(maxWidth: 520)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(.snappy, value: selected)

            if store.loading { ProgressView().controlSize(.large) }
        }
        .task { await store.run() }
        // Back from the background: catch up now rather than at the next event or poll.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .sheet(item: $panel) { p in
            Group {
                switch p {
                case .light: LightPanel(store: store)
                case .water: WaterPanel(store: store)
                case .alerts: AlertsPanel(store: store)
                case .settings: SettingsView(system: store.system)
                case .pods: PodList(pods: pods) { slot in
                    panel = nil
                    selected = slot
                }
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
                Button { panel = .pods } label: {
                    Image(systemName: "list.bullet").foregroundStyle(Theme.text2)
                }
                .accessibilityLabel("All pods")
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

/// Every pod by what it needs, most urgent first: the way to find one by name, and to reach pods with VoiceOver.
struct PodList: View {
    let pods: [TowerPod]
    let pick: (Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(PodShown.allCases, id: \.self) { shown in
                    let group = pods.filter { $0.shown == shown }
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { pod in
                                Button { pick(pod.slot) } label: { row(pod) }
                                    .listRowBackground(Theme.app)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Circle().fill(shown.color).frame(width: 7, height: 7)
                                Text("\(shown.label) · \(group.count)")
                            }
                            .font(Theme.mono(11))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Pods")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ pod: TowerPod) -> some View {
        HStack(spacing: 12) {
            Text("\(pod.slot)")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.text3)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(pod.plant ?? "Empty").foregroundStyle(pod.plant == nil ? Theme.text3 : Theme.text1)
                if let detail = detail(pod) {
                    Text(detail).font(.caption).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.text3)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pod \(pod.slot), \(pod.plant ?? "empty"), \(pod.shown.label)")
    }

    private func detail(_ pod: TowerPod) -> String? {
        switch pod.shown {
        case .attention: return pod.notes.isEmpty ? nil : pod.notes
        case .empty: return nil
        default:
            let age = pod.ageDays.map { "day \(Int($0))" }
            let due = pod.harvest?.daysToReady.flatMap { $0 > 0 ? "harvest in ~\(max(1, Int($0.rounded()))) d" : nil }
            return [age, due].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
