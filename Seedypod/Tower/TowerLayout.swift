import Foundation

/// Where each pod sits on the tower, ported from core's towerLayout.ts so the
/// app and the web UI build the same tower. A Gardyn Home holds 30 pods on three
/// columns of 10; a Studio 16 on two columns of 8. Slots count across then down
/// from the top, and pods alternate left and right of their column's spine.
/// Units are metres, roughly to scale.
struct TowerShape: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let height: Float
    let width: Float
    /// Top of the base, where the columns start.
    let baseTop: Float
    /// Gap between rows.
    let pitch: Float
    let columnX: [Float]

    init(podCount: Int) {
        columns = podCount > 16 ? 3 : 2
        rows = Int((Double(podCount) / Double(columns)).rounded(.up))
        baseTop = 0.3
        pitch = 0.115
        height = baseTop + 0.12 + Float(rows) * pitch
        let spacing: Float = 0.2
        let columns = columns
        columnX = (0..<columns).map { (Float($0) - Float(columns - 1) / 2) * spacing }
        width = spacing * Float(columns) + 0.12
    }
}

struct PodPlace: Equatable, Sendable {
    let slot: Int
    let column: Int
    /// 0 is the top row.
    let row: Int
    /// Which side of the column's spine the pod leans out to.
    let side: Float
    let position: SIMD3<Float>

    static func all(podCount: Int) -> [PodPlace] {
        let shape = TowerShape(podCount: podCount)
        return (0..<podCount).map { i in
            let row = i / shape.columns
            let column = i % shape.columns
            // Every column starts on the right and alternates, as Gardyn's light-zone diagrams draw them.
            let side: Float = row % 2 == 0 ? 1 : -1
            return PodPlace(slot: i + 1, column: column, row: row, side: side,
                            position: [shape.columnX[column] + side * 0.035, shape.height - 0.12 - Float(row) * shape.pitch, 0.06])
        }
    }
}

enum PlantForm: String, Sendable {
    case none, sprout, young, bush, full

    /// The size each stage's model is built at, on plantScale's 0–1; a measured plant scales a little either side of it.
    var builtScale: Float {
        switch self {
        case .none: 1
        case .sprout: 0.25
        case .young: 0.45
        case .bush: 0.75
        case .full: 0.95
        }
    }
}

enum PlantGrowth {
    /// Days a leafy green or herb takes from planting to its first harvest, roughly.
    static let daysToHarvest: Double = 35

    /// Plant size, 0 (nothing) to 1 (full): the analysers' green fraction when
    /// there is one, else days since planting, else a size by status.
    static func scale(_ status: PodStatus, green: Double?, ageDays: Double?) -> Float {
        switch status {
        case .empty: return 0
        case .seeded: return 0.25
        default: break
        }
        if let g = green, g.isFinite { return Float(max(0.3, min(1, 0.35 + g * 1.1))) }
        if status == .harvest { return 0.95 }
        if let a = ageDays, a.isFinite { return Float(max(0.3, min(1, 0.3 + (a / daysToHarvest) * 0.65))) }
        return 0.55
    }

    /// Two seed leaves, a few leaves, a bush, a full head ready to cut.
    static func form(_ status: PodStatus, scale: Float) -> PlantForm {
        switch status {
        case .empty: .none
        case .seeded: .sprout
        case .harvest: .full
        default: scale < 0.6 ? .young : .bush
        }
    }
}
