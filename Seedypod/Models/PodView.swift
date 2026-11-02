import Foundation

/// A pod as Home draws it: its row from `grow.pods` joined with its leaf-cover
/// trend and harvest outlook. Ported from core's towerLayout.ts so the app and
/// the web UI call every pod the same thing.
struct TowerPod: Equatable, Sendable, Identifiable {
    let slot: Int
    let status: PodStatus
    let plant: String?
    var green: Double?
    var ageDays: Double?
    var notes: String = ""
    var statusSince: String?
    var harvest: HarvestOutlook?
    var id: Int { slot }

    var shown: PodShown {
        if status == .attention { return .attention }
        if status == .empty { return .empty }
        if status == .harvest || harvest?.state == .ready { return .ready }
        if harvest?.state == .soon { return .soon }
        return status == .seeded ? .seeded : .growing
    }

    static func join(_ snapshot: HomeSnapshot, now: Date = Date()) -> [TowerPod] {
        let trends = Dictionary(snapshot.trends.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        let outlook = Dictionary(snapshot.harvest.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        return snapshot.pods.map { p in
            TowerPod(slot: p.slot, status: p.status, plant: p.plant, green: trends[p.slot]?.green, ageDays: ageDays(p.plantedAt, now: now),
                     notes: p.notes, statusSince: p.statusSince, harvest: outlook[p.slot])
        }
    }

    static func ageDays(_ plantedAt: String?, now: Date = Date()) -> Double? {
        guard let t = ISO.date(plantedAt) else { return nil }
        return max(0, now.timeIntervalSince(t) / 86_400)
    }
}

/// What a pod shows as, most urgent first.
enum PodShown: String, CaseIterable, Sendable {
    case attention, ready, soon, growing, seeded, empty

    var label: String {
        switch self {
        case .attention: "Needs attention"
        case .ready: "Ready to harvest"
        case .soon: "Harvest soon"
        case .growing: "Growing"
        case .seeded: "Seeded"
        case .empty: "Empty"
        }
    }
}

/// Home's counts over the tower, each with the states it takes in, so they add up to every pod.
enum PodCount: CaseIterable {
    case growing, ready, attention, empty

    var label: String {
        switch self {
        case .growing: "growing"
        case .ready: "ready"
        case .attention: "attention"
        case .empty: "empty"
        }
    }

    var takes: [PodShown] {
        switch self {
        case .growing: [.growing, .soon, .seeded]
        case .ready: [.ready]
        case .attention: [.attention]
        case .empty: [.empty]
        }
    }

    static func counts(_ pods: [TowerPod]) -> [PodCount: Int] {
        var out: [PodCount: Int] = [:]
        for c in allCases { out[c] = pods.filter { c.takes.contains($0.shown) }.count }
        return out
    }
}

enum Format {
    /// "25.5°", "71%", "9.4 cm": a reading with its unit, as the web's withUnit.
    static func reading(_ r: Reading?, digits: Int = 1) -> String {
        guard let r else { return "—" }
        let v = r.value.formatted(.number.precision(.fractionLength(0...digits)))
        switch r.unit {
        case "%", "°C", "°F": return r.unit == "%" ? "\(v)%" : "\(v)°"
        case "": return v
        default: return "\(v) \(r.unit)"
        }
    }

    /// "now", "5 h", "2 d": how long since an ISO time.
    static func heldFor(_ since: String?, now: Date = Date()) -> String? {
        guard let t = ISO.date(since) else { return nil }
        let h = now.timeIntervalSince(t) / 3600
        return h < 1 ? "now" : h < 24 ? "\(Int(h)) h" : "\(Int(h / 24)) d"
    }

    static func time(_ iso: String?) -> String? {
        ISO.date(iso)?.formatted(date: .omitted, time: .shortened)
    }
}
