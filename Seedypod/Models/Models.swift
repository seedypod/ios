import Foundation

// Wire types for seedypod core's tRPC router (src/server/routers/ in seedypod/core).
// Field names match the zod output schemas there; anything optional on the wire is optional here.

struct Reading: Codable, Sendable, Equatable {
    let ts: String
    let value: Double
    let unit: String
    var quality: String?
}

/// The sensors core knows about (`SensorId` in src/hardware/contract.ts).
enum SensorID: String, CaseIterable, Sendable {
    case airTemp = "air_temp"
    case humidity
    case pcbTemp = "pcb_temp"
    case waterDistance = "water_distance"
    case waterLevelPct = "water_level_pct"
    case pumpV = "pump_v"
    case pumpA = "pump_a"
    case pumpW = "pump_w"
    case ph
    case ec
    case waterTemp = "water_temp"
}

struct ActuatorState: Codable, Sendable, Equatable {
    let on: Bool
    /// 0–100
    let level: Double
    let since: String
    var fault: String?
    var remainingS: Int?
}

struct LightOwner: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable { case manual, autopilot, schedule }
    let source: Source?
    let level: Double?
    let manualUntil: String?
}

struct SystemInfo: Codable, Sendable, Equatable {
    struct Host: Codable, Sendable, Equatable {
        let hostname: String
        let arch: String
    }
    struct Hal: Codable, Sendable, Equatable {
        struct Caps: Codable, Sendable, Equatable {
            let sensors: [String]
            let actuators: [String]
            let cameras: [String]
        }
        let unitId: String
        let model: String
        var board: String?
        let halVersion: String
        let caps: Caps
    }
    let coreVersion: String
    let coreHost: Host?
    let halOnline: Bool
    let system: Hal?
}

enum PodStatus: String, Codable, Sendable, CaseIterable {
    case empty, seeded, growing, harvest, attention
}

struct Pod: Codable, Sendable, Equatable, Identifiable {
    let slot: Int
    let plant: String?
    let plantedAt: String?
    let status: PodStatus
    let notes: String
    let updatedAt: String
    let statusSince: String?
    let lastHarvestAt: String?
    var id: Int { slot }
}

struct GrowCycle: Codable, Sendable, Equatable {
    let id: String
    let startedAt: String
    let endedAt: String?
    let stage: String
    let notes: String
}

struct GrowCurrent: Codable, Sendable, Equatable {
    let cycle: GrowCycle?
    let day: Double?
}

struct HarvestWindow: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable { case profile, camera }
    let start: Double
    let end: Double
    let source: Source
}

struct HarvestOutlook: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case ready, soon, growing, unknown }
    let slot: Int
    let plant: String?
    let state: State
    let ageDays: Double?
    let cover: Double?
    let targetCover: Double
    let window: HarvestWindow?
    let daysToReady: Double?
    let daysLeft: Double?
    let reason: String
}

struct PodTrend: Codable, Sendable, Equatable {
    enum Verdict: String, Codable, Sendable { case growing, stalled, declining, unknown }
    let slot: Int
    let green: Double?
    let verdict: Verdict
    let recent: [Double]
}

struct CoreAlert: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let kind: String
    let active: Bool
    let detail: String
    let raisedAt: String
    let clearedAt: String?
    let acknowledgedAt: String?
    let dismissedAt: String?
}

/// Everything Home shows, fetched in one batched request.
struct HomeSnapshot: Sendable, Equatable {
    var pods: [Pod]
    var grow: GrowCurrent
    var sensors: [String: Reading]
    var light: ActuatorState?
    var pump: ActuatorState?
    var alerts: [CoreAlert]
    /// The rest are best effort: older cores or a missing analyser leave them empty.
    var harvest: [HarvestOutlook] = []
    var trends: [PodTrend] = []
    var lightOwner: LightOwner?

    func reading(_ id: SensorID) -> Reading? { sensors[id.rawValue] }
}

enum ISO {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    nonisolated(unsafe) private static let day: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    /// Parses core's timestamps: full ISO with or without fractions, or a bare `YYYY-MM-DD`.
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s) ?? day.date(from: s)
    }

    static func string(_ d: Date) -> String { fractional.string(from: d) }
}
