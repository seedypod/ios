import RealityKit
import UIKit

/// Stylized plants for the tower, one look per kind of crop, built at a stage:
/// two seed leaves, a few leaves, a bush, a full head ready to cut. A much
/// lighter take on core's plants/ catalog: leaves are flattened spheres fanned
/// round a stem, so every crop shares four meshes and a handful of materials.
@MainActor
final class PlantKit {
    enum Habit {
        /// Wide leaves in a loose head: lettuce.
        case rosette
        /// Long leaves standing up from the crown: kale, chard, bok choy, arugula.
        case upright
        /// Pairs of small leaves up a stem: basil, mint.
        case tiered
        /// Many fine leaflets: dill, cilantro.
        case feathery
        /// A leafy bush that sets fruit: tomato, pepper.
        case fruiting
    }

    struct Crop {
        let habit: Habit
        let leaf: UIColor
        let leafAlt: UIColor
        var stem: UIColor?
        var fruit: UIColor?
    }

    static let sickLeaf = UIColor(hex: 0xB8B04A)

    /// Matches by name, most specific first, so "Thai Basil" and "Swiss Chard" find their crop.
    static func crop(for plant: String?) -> Crop {
        let name = (plant ?? "").lowercased()
        let table: [(String, Crop)] = [
            ("lettuce", Crop(habit: .rosette, leaf: UIColor(hex: 0x8CC84B), leafAlt: UIColor(hex: 0xA6D96A))),
            ("kale", Crop(habit: .upright, leaf: UIColor(hex: 0x4F7F6A), leafAlt: UIColor(hex: 0x6B5A86), stem: UIColor(hex: 0x7A4F8C))),
            ("chard", Crop(habit: .upright, leaf: UIColor(hex: 0x2F7D3B), leafAlt: UIColor(hex: 0x3B8F46), stem: UIColor(hex: 0xC2364A))),
            ("bok choy", Crop(habit: .upright, leaf: UIColor(hex: 0x2E7A3A), leafAlt: UIColor(hex: 0x3F8C48), stem: UIColor(hex: 0xE4EFD8))),
            ("arugula", Crop(habit: .upright, leaf: UIColor(hex: 0x3C7A34), leafAlt: UIColor(hex: 0x4E8C3E))),
            ("spinach", Crop(habit: .rosette, leaf: UIColor(hex: 0x2F6E2E), leafAlt: UIColor(hex: 0x3D7F3A))),
            ("thai basil", Crop(habit: .tiered, leaf: UIColor(hex: 0x3F7A3A), leafAlt: UIColor(hex: 0x4C6B45), stem: UIColor(hex: 0x6E3F6E))),
            ("basil", Crop(habit: .tiered, leaf: UIColor(hex: 0x4FA34A), leafAlt: UIColor(hex: 0x5DB357), stem: UIColor(hex: 0x4F8A3F))),
            ("mint", Crop(habit: .tiered, leaf: UIColor(hex: 0x5DBB63), leafAlt: UIColor(hex: 0x6CC872), stem: UIColor(hex: 0x4C8A44))),
            ("dill", Crop(habit: .feathery, leaf: UIColor(hex: 0x6E9F5A), leafAlt: UIColor(hex: 0x7FAE69))),
            ("cilantro", Crop(habit: .feathery, leaf: UIColor(hex: 0x4E9A45), leafAlt: UIColor(hex: 0x5FAB52))),
            ("parsley", Crop(habit: .feathery, leaf: UIColor(hex: 0x3F8A3A), leafAlt: UIColor(hex: 0x4C9A45))),
            ("tomato", Crop(habit: .fruiting, leaf: UIColor(hex: 0x3F7F3A), leafAlt: UIColor(hex: 0x4D8F45), stem: UIColor(hex: 0x557A3A), fruit: UIColor(hex: 0xD8402E))),
            ("jalape", Crop(habit: .fruiting, leaf: UIColor(hex: 0x356F33), leafAlt: UIColor(hex: 0x427F3C), stem: UIColor(hex: 0x4F7036), fruit: UIColor(hex: 0x2F7A2A))),
            ("pepper", Crop(habit: .fruiting, leaf: UIColor(hex: 0x356F33), leafAlt: UIColor(hex: 0x427F3C), stem: UIColor(hex: 0x4F7036), fruit: UIColor(hex: 0xD03A2A))),
            ("strawberr", Crop(habit: .fruiting, leaf: UIColor(hex: 0x3D8040), leafAlt: UIColor(hex: 0x4A904B), fruit: UIColor(hex: 0xE0383E)))
        ]
        return table.first { name.contains($0.0) }?.1 ?? Crop(habit: .rosette, leaf: UIColor(hex: 0x50C878), leafAlt: UIColor(hex: 0x2F8F55))
    }

    private let leafMesh = MeshResource.generateSphere(radius: 0.5)
    private let stemMesh = MeshResource.generateCylinder(height: 1, radius: 0.5)
    private var materials: [String: PhysicallyBasedMaterial] = [:]

    private func material(_ color: UIColor, roughness: Float = 0.85) -> PhysicallyBasedMaterial {
        let key = "\(color.description)|\(roughness)"
        if let m = materials[key] { return m }
        let m = pbr(color, roughness: roughness, metallic: 0)
        materials[key] = m
        return m
    }

    /// A plant of `form`, at the scale `form.builtScale` stands for; `slot` varies the turn so neighbours don't match.
    func build(plant: String?, form: PlantForm, slot: Int, sick: Bool) -> Entity {
        let crop = Self.crop(for: plant)
        let root = Entity()
        root.name = "plant"
        let size = form.builtScale * 0.11
        let turn = Float(slot) * 2.399
        var leafIndex = 0
        // A plant that needs attention yellows: every other leaf turns.
        func leafColor() -> UIColor {
            defer { leafIndex += 1 }
            if sick, leafIndex % 2 == 0 { return Self.sickLeaf }
            return leafIndex % 3 == 0 ? crop.leafAlt : crop.leaf
        }

        if form == .sprout {
            for i in 0..<2 {
                addLeaf(to: root, yaw: turn + Float(i) * .pi, tilt: 0.5, length: 0.03, width: 0.55, height: 0.012, color: leafColor())
            }
            addStem(to: root, height: 0.014, radius: 0.0025, color: crop.leaf)
            return root
        }

        let count: Int = switch form {
        case .young: 5
        case .bush: 8
        default: 11
        }
        switch crop.habit {
        case .rosette:
            for i in 0..<count {
                let ring = Float(i) / Float(count)
                addLeaf(to: root, yaw: turn + Float(i) * 2.399, tilt: 0.45 + ring * 0.6, length: size * (0.75 + 0.35 * (1 - ring)), width: 0.85, height: 0, color: leafColor())
            }
        case .upright:
            for i in 0..<count {
                let yaw = turn + Float(i) * 2.399
                let length = size * (1.05 + 0.25 * sin(Float(i)))
                if let stem = crop.stem {
                    addLeaf(to: root, yaw: yaw, tilt: 1.2, length: length * 0.5, width: 0.18, height: 0, color: stem)
                }
                addLeaf(to: root, yaw: yaw, tilt: 1.15, length: length, width: 0.42, height: crop.stem == nil ? 0 : length * 0.18, color: leafColor())
            }
        case .tiered, .fruiting:
            let tiers = max(2, count / 2)
            let height = size * 1.1
            addStem(to: root, height: height, radius: 0.003, color: crop.stem ?? crop.leaf)
            for t in 0..<tiers {
                let y = height * (0.15 + 0.85 * Float(t) / Float(tiers))
                let leafLength = size * (crop.habit == .fruiting ? 0.6 : 0.5) * (1.1 - 0.5 * Float(t) / Float(tiers))
                for k in 0..<2 {
                    addLeaf(to: root, yaw: turn + Float(t) * 1.57 + Float(k) * .pi, tilt: 0.35, length: leafLength, width: 0.6, height: y, color: leafColor())
                }
            }
            addLeaf(to: root, yaw: turn, tilt: 1.4, length: size * 0.3, width: 0.6, height: height, color: leafColor())
            if crop.habit == .fruiting, let fruit = crop.fruit, form == .bush || form == .full {
                let n = form == .full ? 5 : 2
                for i in 0..<n {
                    let a = turn + Float(i) * 2.2
                    let r = size * 0.35
                    let ball = ModelEntity(mesh: leafMesh, materials: [material(fruit, roughness: 0.35)])
                    let d = size * (plant?.lowercased().contains("jalape") == true ? 0.16 : 0.22)
                    ball.scale = plant?.lowercased().contains("jalape") == true ? [d, d * 2.2, d] : [d, d, d]
                    ball.position = [cos(a) * r, height * (0.35 + 0.12 * Float(i % 3)), sin(a) * r]
                    root.addChild(ball)
                }
            }
        case .feathery:
            addStem(to: root, height: size * 0.5, radius: 0.0025, color: crop.leaf)
            for i in 0..<(count * 2) {
                addLeaf(to: root, yaw: turn + Float(i) * 2.399, tilt: 0.7 + 0.5 * Float(i % 3) / 3, length: size * (0.6 + 0.4 * Float(i % 4) / 4), width: 0.14, height: size * 0.1 * Float(i % 3), color: leafColor())
            }
        }
        return root
    }

    /// A leaf fanned out from the stem: turned `yaw` round it, raised `tilt` radians off flat, its base `height` up.
    private func addLeaf(to parent: Entity, yaw: Float, tilt: Float, length: Float, width: Float, height: Float, color: UIColor) {
        let pivot = Entity()
        pivot.position.y = height
        pivot.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -tilt, axis: [1, 0, 0])
        let leaf = ModelEntity(mesh: leafMesh, materials: [material(color)])
        leaf.scale = [length * width, max(0.0025, length * 0.07), length]
        leaf.position.z = length * 0.5
        pivot.addChild(leaf)
        parent.addChild(pivot)
    }

    private func addStem(to parent: Entity, height: Float, radius: Float, color: UIColor) {
        let stem = ModelEntity(mesh: stemMesh, materials: [material(color)])
        stem.scale = [radius * 2, height, radius * 2]
        stem.position.y = height / 2
        parent.addChild(stem)
    }
}
