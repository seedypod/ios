import SwiftUI

/// Light, tank and air along the bottom of Home, as the web sidebar's readings card. Light and tank open their panels.
struct ReadingsBar: View {
    let snapshot: HomeSnapshot?
    let open: (HomeView.Panel) -> Void

    var body: some View {
        let light = snapshot?.light
        let tank = snapshot?.reading(.waterLevelPct)
        HStack(spacing: 0) {
            Button { open(.light) } label: {
                meter("sun.max", "Light", light.map { $0.on ? "\(Int($0.level))%" : "off" } ?? "—", fill: light.map { $0.on ? $0.level / 100 : 0 }, tint: Theme.light)
            }
            Divider().frame(height: 34).overlay(Theme.line1)
            Button { open(.water) } label: {
                meter(snapshot?.pump?.on == true ? "drop.fill" : "drop", "Tank", Format.reading(tank, digits: 0), fill: tank.map { $0.value / 100 }, tint: Theme.water)
            }
            Divider().frame(height: 34).overlay(Theme.line1)
            meter("thermometer.medium", "Air", [Format.reading(snapshot?.reading(.airTemp)), Format.reading(snapshot?.reading(.humidity), digits: 0)].joined(separator: " · "), fill: nil, tint: Theme.text2)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
        .card()
    }

    private func meter(_ icon: String, _ label: String, _ value: String, fill: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(Theme.text2)
                Text(label).foregroundStyle(Theme.text2)
            }
            .font(Theme.mono(11))
            Text(value)
                .font(Theme.mono(15, .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { g in
                Capsule().fill(Theme.line1)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: g.size.width * max(0, min(1, fill ?? 0)))
                    }
                    .opacity(fill == nil ? 0 : 1)
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .contentShape(.rect)
    }
}

/// The picked pod (the web's Pod Card, layout 1b): what's in it, its state and
/// for how long, where it sits in its grow, why, and what to do about it.
struct PodCard: View {
    let pod: TowerPod
    let store: HomeStore
    let close: () -> Void

    var body: some View {
        let shown = pod.shown
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("POD \(pod.slot)")
                        .font(Theme.mono(11))
                        .tracking(0.6)
                        .foregroundStyle(Theme.text3)
                    Text(pod.plant ?? "Empty")
                        .font(.title3.weight(.medium))
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text3).padding(4)
                }
                .accessibilityLabel("Close pod \(pod.slot)")
            }
            HStack(spacing: 8) {
                Circle().fill(shown.color).frame(width: 7, height: 7)
                Text(shown.label).foregroundStyle(shown.color).fontWeight(.medium)
                if let timing { Text("· \(timing)").font(Theme.mono(11)).foregroundStyle(Theme.text3) }
            }
            .font(.footnote)

            if let w = pod.harvest?.window, let age = pod.ageDays, shown != .empty {
                Divider().overlay(Theme.line1)
                HarvestTimeline(window: w, age: age)
            }
            if let sentence {
                Text(sentence)
                    .font(.footnote)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions(shown)
        }
        .padding(16)
        .card()
    }

    private var timing: String? {
        let shown = pod.shown
        if shown == .growing || shown == .soon, let d = pod.harvest?.daysToReady, d > 0 {
            return "harvest in ~\(max(1, Int(d.rounded()))) d"
        }
        return shown == .empty ? nil : Format.heldFor(pod.statusSince)
    }

    private var sentence: String? {
        if pod.shown == .attention {
            let note = pod.notes.trimmingCharacters(in: .whitespaces)
            return note.isEmpty ? "Marked for attention." : note
        }
        let reason = pod.harvest?.reason ?? ""
        return reason.isEmpty ? nil : reason
    }

    @ViewBuilder private func actions(_ shown: PodShown) -> some View {
        switch shown {
        case .ready:
            Button {
                Task { await store.markHarvested(pod.slot) }
            } label: {
                Text("Mark harvested").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.podReady)
            .foregroundStyle(Theme.inverse)
        case .attention:
            Button {
                Task { await store.setPodStatus(pod.slot, .growing) }
            } label: {
                Text("It's fine now").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }
}

/// Seeded at the left, the harvest window shaded, a tick for today. A window the camera estimated reads "~".
struct HarvestTimeline: View {
    let window: HarvestWindow
    let age: Double

    var body: some View {
        let maxDay = Swift.max(window.end, age, 1)
        let about = window.source == .camera ? "~" : ""
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let x = { (d: Double) in g.size.width * Swift.max(0, Swift.min(d, maxDay)) / maxDay }
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line1).frame(height: 6)
                    Rectangle().fill(Theme.podOK.opacity(0.5)).frame(width: x(window.start), height: 6)
                    Rectangle().fill(Theme.podReady.opacity(0.4)).frame(width: x(window.end) - x(window.start), height: 6).offset(x: x(window.start))
                    Rectangle().fill(Theme.text1).frame(width: 2, height: 14).offset(x: x(age) - 1)
                }
                .clipShape(.rect(cornerRadius: 3))
            }
            .frame(height: 14)
            HStack {
                Text("seeded")
                Spacer()
                Text("\(about)\(Int(window.start.rounded())) d")
                Spacer()
                Text("\(about)\(Int(window.end.rounded())) d")
            }
            .font(Theme.mono(10))
            .foregroundStyle(Theme.text3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day \(Int(age)); harvest window \(about)\(Int(window.start.rounded()))–\(Int(window.end.rounded())) days")
    }
}

/// The grow light: on/off, brightness, and who's in charge of it.
struct LightPanel: View {
    let store: HomeStore
    @State private var level: Double = 0
    @State private var editing = false

    var body: some View {
        let light = store.snapshot?.light
        let owner = store.snapshot?.lightOwner
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(light.map { $0.on ? "\(Int($0.level))%" : "Off" } ?? "—")
                            .font(Theme.mono(40, .medium))
                        Text(ownerText(owner)).font(.footnote).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    Toggle("Light", isOn: Binding(get: { light?.on ?? false }, set: { on in Task { await store.setLight(on: on) } }))
                        .labelsHidden()
                        .tint(Theme.light)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("BRIGHTNESS").font(Theme.mono(11)).foregroundStyle(Theme.text3)
                    Slider(value: $level, in: 0...100, step: 1) { e in
                        editing = e
                        if !e { Task { await store.setLight(level: level) } }
                    }
                    .tint(Theme.light)
                }
                if owner?.source == .manual {
                    Button("Hand back to the schedule") { Task { await store.resumeLight() } }
                        .buttonStyle(.bordered)
                }
                Text("Changing the light here holds it for 30 minutes over Autopilot and the schedule.")
                    .font(.caption)
                    .foregroundStyle(Theme.text3)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Grow light")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { level = light?.level ?? 0 }
        .onChange(of: light?.level) { _, v in if !editing, let v { level = v } }
    }

    private func ownerText(_ owner: LightOwner?) -> String {
        switch owner?.source {
        case .manual: Format.time(owner?.manualUntil).map { "Held by you until \($0)" } ?? "Held by you"
        case .autopilot: "Set by Autopilot"
        case .schedule: "Following the schedule"
        case nil: "No schedule"
        }
    }
}

/// The tank and the pump: level, a bounded run, stop, and any fault.
struct WaterPanel: View {
    let store: HomeStore

    var body: some View {
        let s = store.snapshot
        let pump = s?.pump
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(Format.reading(s?.reading(.waterLevelPct), digits: 0)).font(Theme.mono(40, .medium))
                    Text("tank").foregroundStyle(Theme.text2)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    stat("Water distance", Format.reading(s?.reading(.waterDistance)))
                    stat("Pump power", Format.reading(s?.reading(.pumpW)))
                    if let ph = s?.reading(.ph) { stat("pH", Format.reading(ph, digits: 2)) }
                    if let ec = s?.reading(.ec) { stat("EC", Format.reading(ec, digits: 2)) }
                    if let wt = s?.reading(.waterTemp) { stat("Water temp", Format.reading(wt)) }
                }
                if let fault = pump?.fault {
                    Label("Pump fault: \(fault). Acknowledge it under Alerts to re-enable.", systemImage: "exclamationmark.octagon")
                        .font(.footnote)
                        .foregroundStyle(Theme.podAttention)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(pump?.on == true ? "PUMP RUNNING · \(pump?.remainingS.map { "\($0) s left" } ?? "")" : "RUN THE PUMP")
                        .font(Theme.mono(11))
                        .foregroundStyle(pump?.on == true ? Theme.water : Theme.text3)
                    if pump?.on == true {
                        Button(role: .destructive) { Task { await store.stopPump() } } label: {
                            Text("Stop").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        HStack {
                            ForEach([30, 60, 120], id: \.self) { secs in
                                Button { Task { await store.runPump(seconds: secs) } } label: {
                                    Text(secs < 60 ? "\(secs) s" : "\(secs / 60) min").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.water)
                            }
                        }
                        .disabled(pump?.fault != nil)
                    }
                }
                Text("Every run is bounded by the unit's max-run limit and its dry-run interlock.")
                    .font(.caption)
                    .foregroundStyle(Theme.text3)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Water")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.text3)
            Text(value).font(Theme.mono(17, .medium))
        }
    }
}

/// Active alerts; acknowledging a latched hardware fault clears it on the unit.
struct AlertsPanel: View {
    let store: HomeStore

    var body: some View {
        let alerts = store.snapshot?.alerts ?? []
        NavigationStack {
            List {
                if alerts.isEmpty {
                    ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle", description: Text("Alerts and reminders from the unit show up here."))
                        .listRowBackground(Color.clear)
                }
                ForEach(alerts) { alert in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(alert.detail).font(.body.weight(.medium))
                        HStack {
                            Text(alert.kind.replacingOccurrences(of: "_", with: " "))
                            if let held = Format.heldFor(alert.raisedAt) { Text("· \(held)") }
                        }
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text3)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button("Done") { Task { await store.acknowledge(alert) } }.tint(Theme.podOK)
                    }
                    .contextMenu {
                        Button("Acknowledge", systemImage: "checkmark") { Task { await store.acknowledge(alert) } }
                    }
                    .listRowBackground(Theme.app)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
