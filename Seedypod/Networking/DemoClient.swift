import Foundation

/// An in-memory tower for trying the app without a unit. It mirrors core's
/// `SEED_DEMO` seed (src/demo/seed.ts): day 19 of "Autumn greens + herbs",
/// 24 of 30 pods planted, six ready, one yellowing kale.
actor DemoClient: SeedypodAPI {
    private static let plants = ["Butterhead Lettuce", "Genovese Basil", "Arugula", "Red Russian Kale", "Cherry Tomato", "Thai Basil", "Mint", "Swiss Chard", "Bok Choy", "Jalapeño", "Cilantro", "Dill"]

    private let started: Date
    private var pods: [Pod]
    private var light: ActuatorState
    private var pump: ActuatorState
    private var pumpUntil: Date?
    private var manualUntil: Date?
    private var alerts: [CoreAlert]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        let t = now()
        started = t.addingTimeInterval(-19 * 86_400)
        let stamp = ISO.string(t)
        let planted = String(ISO.string(started).prefix(10))
        pods = (1...30).map { slot in
            guard slot <= 24 else {
                return Pod(slot: slot, plant: nil, plantedAt: nil, status: .empty, notes: "", updatedAt: stamp, statusSince: nil, lastHarvestAt: nil)
            }
            let status: PodStatus = slot == 9 ? .attention : slot <= 6 ? .harvest : .growing
            return Pod(slot: slot, plant: Self.plants[(slot * 7) % Self.plants.count], plantedAt: planted, status: status,
                       notes: slot == 9 ? "Yellowing lower leaves — check nutrients" : "", updatedAt: stamp, statusSince: stamp, lastHarvestAt: nil)
        }
        light = ActuatorState(on: true, level: 85, since: stamp)
        pump = ActuatorState(on: false, level: 0, since: stamp)
        alerts = [CoreAlert(id: 1, kind: "reminder_nutrients", active: true, detail: "Add nutrients (every 7 days)",
                            raisedAt: ISO.string(t.addingTimeInterval(-7200)), clearedAt: nil, acknowledgedAt: nil, dismissedAt: nil)]
    }

    func systemInfo() async throws -> SystemInfo {
        SystemInfo(coreVersion: "demo", coreHost: nil, halOnline: true,
                   system: .init(unitId: "demo", model: "Gardyn Home 3.0 (demo)", board: nil, halVersion: "demo",
                                 caps: .init(sensors: ["air_temp", "humidity", "water_level_pct", "water_distance", "pump_w"], actuators: ["light", "pump"], cameras: ["upper", "lower"])))
    }

    func home() async throws -> HomeSnapshot {
        let t = now()
        settlePump(t)
        let stamp = ISO.string(t)
        // A slow daily rhythm, so the readings move a little between refreshes.
        let hour = Calendar.current.component(.hour, from: t)
        let phase = sin(Double(hour - 6) / 24 * .pi * 2)
        let sensors: [String: Reading] = [
            "air_temp": Reading(ts: stamp, value: (22 + 2.2 * phase).rounded(to: 1), unit: "°C"),
            "humidity": Reading(ts: stamp, value: (50 - 6 * phase).rounded(to: 0), unit: "%"),
            "water_level_pct": Reading(ts: stamp, value: 71, unit: "%"),
            "water_distance": Reading(ts: stamp, value: 9.4, unit: "cm"),
            "pump_w": Reading(ts: stamp, value: pump.on ? 3.1 : 0, unit: "W")
        ]
        let day = (t.timeIntervalSince(started) / 86_400).rounded(.down)
        return HomeSnapshot(
            pods: pods,
            grow: GrowCurrent(cycle: GrowCycle(id: "demo", startedAt: ISO.string(started), endedAt: nil, stage: "vegetative", notes: "Autumn greens + herbs"), day: day),
            sensors: sensors,
            light: light,
            pump: pump,
            alerts: alerts.filter(\.active),
            harvest: pods.compactMap { outlook($0, t) },
            trends: pods.filter { $0.plant != nil }.map { PodTrend(slot: $0.slot, green: cover($0.slot), verdict: .growing, recent: []) },
            lightOwner: LightOwner(source: manualUntil.map { $0 > t } == true ? .manual : .schedule, level: light.level, manualUntil: manualUntil.map(ISO.string))
        )
    }

    func setLight(on: Bool?, level: Double?) async throws -> ActuatorState {
        let t = now()
        let next = on == false ? 0 : level ?? (light.level > 0 ? light.level : 100)
        light = ActuatorState(on: next > 0, level: next, since: ISO.string(t))
        manualUntil = t.addingTimeInterval(30 * 60)
        return light
    }

    func resumeLight() async throws -> LightOwner {
        manualUntil = nil
        light = ActuatorState(on: true, level: 85, since: ISO.string(now()))
        return LightOwner(source: .schedule, level: 85, manualUntil: nil)
    }

    func runPump(seconds: Int) async throws -> ActuatorState {
        let t = now()
        let bounded = min(seconds, 600)
        pumpUntil = t.addingTimeInterval(Double(bounded))
        pump = ActuatorState(on: true, level: 100, since: ISO.string(t), remainingS: bounded)
        return pump
    }

    func stopPump() async throws -> ActuatorState {
        pumpUntil = nil
        pump = ActuatorState(on: false, level: 0, since: ISO.string(now()))
        return pump
    }

    func markHarvested(slot: Int) async throws -> Pod {
        try update(slot) { old, stamp in
            Pod(slot: old.slot, plant: old.plant, plantedAt: old.plantedAt, status: .growing, notes: old.notes, updatedAt: stamp, statusSince: stamp, lastHarvestAt: stamp)
        }
    }

    func setPodStatus(slot: Int, status: PodStatus) async throws -> Pod {
        try update(slot) { old, stamp in
            Pod(slot: old.slot, plant: old.plant, plantedAt: old.plantedAt, status: status, notes: status == .attention ? old.notes : "", updatedAt: stamp, statusSince: stamp, lastHarvestAt: old.lastHarvestAt)
        }
    }

    func acknowledgeAlert(id: Int) async throws {
        alerts = alerts.map { a in
            guard a.id == id else { return a }
            let stamp = ISO.string(now())
            return CoreAlert(id: a.id, kind: a.kind, active: false, detail: a.detail, raisedAt: a.raisedAt, clearedAt: stamp, acknowledgedAt: stamp, dismissedAt: nil)
        }
    }

    // MARK: - Helpers

    private func update(_ slot: Int, _ change: (Pod, String) -> Pod) throws -> Pod {
        guard let i = pods.firstIndex(where: { $0.slot == slot }) else { throw APIError.server(message: "no pod \(slot)") }
        pods[i] = change(pods[i], ISO.string(now()))
        return pods[i]
    }

    private func settlePump(_ t: Date) {
        guard let until = pumpUntil else { return }
        if until <= t {
            pumpUntil = nil
            pump = ActuatorState(on: false, level: 0, since: ISO.string(until))
        } else {
            pump.remainingS = Int(until.timeIntervalSince(t).rounded(.up))
        }
    }

    /// Leaf cover by slot: the ready six above the 40 % target, the rest climbing towards it.
    private func cover(_ slot: Int) -> Double {
        slot <= 6 ? 0.42 + Double(slot % 3) * 0.04 : 0.18 + Double((slot * 5) % 7) * 0.025
    }

    private func outlook(_ pod: Pod, _ t: Date) -> HarvestOutlook? {
        guard let plant = pod.plant, pod.status != .empty else { return nil }
        let age = t.timeIntervalSince(started) / 86_400
        let c = cover(pod.slot)
        let ready = pod.status == .harvest
        let soon = !ready && c > 0.3
        let daysToReady = ready ? 0 : max(1, (0.4 - c) / 0.02)
        return HarvestOutlook(
            slot: pod.slot, plant: plant, state: ready ? .ready : soon ? .soon : .growing, ageDays: age, cover: c, targetCover: 0.4,
            window: HarvestWindow(start: 18, end: 25, source: .camera), daysToReady: daysToReady, daysLeft: ready ? 25 - age : nil,
            reason: ready ? "Best within \(Int((25 - age).rounded())) d. Leaf cover \(Int(c * 100))%, above the 40% target." : "Leaf cover \(Int(c * 100))%, behind the 40% target."
        )
    }
}

extension Double {
    func rounded(to places: Int) -> Double {
        let m = pow(10, Double(places))
        return (self * m).rounded() / m
    }
}
