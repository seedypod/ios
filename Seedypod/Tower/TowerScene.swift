import RealityKit
import UIKit

/// The pod a pickable entity belongs to.
struct PodComponent: Component {
    let slot: Int
}

/// Parts of the tower that open a control on Home.
enum TowerPart: String, Sendable {
    case light, tank
}

struct PartComponent: Component {
    let part: TowerPart
}

struct TowerPalette {
    let body: UIColor
    let trim: UIColor
    let cup: UIColor
    let water: UIColor
    let ledOn: UIColor
    let ledOff: UIColor
    let highlight: UIColor
    let status: [PodShown: UIColor]

    static let dark = TowerPalette(
        body: UIColor(hex: 0x2A271F), trim: UIColor(hex: 0x3A362D), cup: UIColor(hex: 0x1D1B15),
        water: UIColor(hex: 0x8FB4C4), ledOn: UIColor(hex: 0xFFF1DC), ledOff: UIColor(hex: 0x2A271F), highlight: UIColor(hex: 0xEFE8DA),
        status: [.empty: UIColor(hex: 0x3A362D), .seeded: UIColor(hex: 0x5B5548), .growing: UIColor(hex: 0x96BE8E), .soon: UIColor(hex: 0x96BE8E),
                 .ready: UIColor(hex: 0xE5BF6D), .attention: UIColor(hex: 0xE2805E)]
    )

    static let light = TowerPalette(
        body: UIColor(hex: 0xF1ECE1), trim: UIColor(hex: 0xD3CAB6), cup: UIColor(hex: 0xE2DBCB),
        water: UIColor(hex: 0x3F7489), ledOn: UIColor(hex: 0xFFF1DC), ledOff: UIColor(hex: 0xD3CAB6), highlight: UIColor(hex: 0x1C1A14),
        status: [.empty: UIColor(hex: 0xD3CAB6), .seeded: UIColor(hex: 0xB3AA96), .growing: UIColor(hex: 0x547E4B), .soon: UIColor(hex: 0x547E4B),
                 .ready: UIColor(hex: 0xA97416), .attention: UIColor(hex: 0xBA5530)]
    )
}

/// What the tower shows; `update` diffs against the last one.
struct TowerState: Equatable {
    var pods: [TowerPod] = []
    /// 0–100, or nil when there's no reading.
    var waterPct: Double?
    /// 0–100; 0 when the light is off.
    var lightLevel: Double = 0
    var pumpOn = false
    var selected: Int?
}

func pbr(_ color: UIColor, roughness: Float = 0.7, metallic: Float = 0.05) -> PhysicallyBasedMaterial {
    var m = PhysicallyBasedMaterial()
    m.baseColor = .init(tint: color)
    m.roughness = .init(floatLiteral: roughness)
    m.metallic = .init(floatLiteral: metallic)
    return m
}

/// The tower as RealityKit entities, after core's towerScene.ts (itself after
/// sleepypod's bed model): the base and tank with a window showing the water,
/// the pod columns, a tilted cup, status collar and plant per slot, and the two
/// light bars. A stylized model of the Gardyn's form, not its CAD. Camera and
/// gestures live in TowerView; this only builds and animates the scene.
@MainActor
final class TowerScene {
    let root = Entity()
    let shape: TowerShape
    private(set) var palette: TowerPalette

    private struct PodParts {
        let group: Entity
        let collar: ModelEntity
        let plant: Entity
        var built = ""
    }

    private var pods: [Int: PodParts] = [:]
    private var bodies: [ModelEntity] = []
    private var trims: [ModelEntity] = []
    private var cups: [ModelEntity] = []
    private var leds: [ModelEntity] = []
    private var flows: [ModelEntity] = []
    private let water: ModelEntity
    private let tankWindow: ModelEntity
    private let growLight = PointLight()
    private let kit = PlantKit()
    private let windowHeight: Float

    private var state = TowerState()
    // Animated: the tank eases to its level, the light fades like a dimmed LED driver, and the channels pulse while the pump runs.
    private var waterShown: Float?
    private var lightShown: Float?
    private var flowOpacity: Float = 0
    private var flowPhase: Float = 0

    init(podCount: Int, palette: TowerPalette) {
        self.palette = palette
        shape = TowerShape(podCount: podCount)
        root.name = "tower"
        let baseDepth: Float = 0.34
        let baseWidth = shape.width + 0.14
        windowHeight = shape.baseTop * 0.62

        // Base: the reservoir, with a window that shows the water level.
        let base = ModelEntity(mesh: .generateBox(width: baseWidth, height: shape.baseTop, depth: baseDepth, cornerRadius: 0.03), materials: [pbr(palette.body)])
        base.position.y = shape.baseTop / 2
        bodies.append(base)
        let lid = ModelEntity(mesh: .generateBox(width: baseWidth + 0.01, height: 0.02, depth: baseDepth + 0.01, cornerRadius: 0.008), materials: [pbr(palette.trim, roughness: 0.5)])
        lid.position.y = shape.baseTop
        trims.append(lid)
        tankWindow = ModelEntity(mesh: .generatePlane(width: 0.05, height: windowHeight), materials: [pbr(palette.cup, roughness: 0.3)])
        tankWindow.position = [baseWidth / 2 - 0.07, shape.baseTop * 0.5, baseDepth / 2 + 0.001]
        cups.append(tankWindow)
        water = ModelEntity(mesh: .generatePlane(width: 0.04, height: 1), materials: [Self.waterMaterial(palette.water)])
        water.position = [tankWindow.position.x, 0, baseDepth / 2 + 0.002]
        for e in [base, lid, tankWindow, water] { root.addChild(e) }
        base.components.set(PartComponent(part: .tank))
        base.components.set(CollisionComponent(shapes: [.generateBox(width: baseWidth, height: shape.baseTop, depth: baseDepth)]))
        base.components.set(InputTargetComponent())

        // The columns the pods hang on, each with a channel the water climbs while the pump runs.
        let columnHeight = shape.height - shape.baseTop
        for x in shape.columnX {
            let column = ModelEntity(mesh: .generateBox(width: 0.045, height: columnHeight, depth: 0.06, cornerRadius: 0.015), materials: [pbr(palette.body)])
            column.position = [x, shape.baseTop + columnHeight / 2, 0]
            bodies.append(column)
            let flow = ModelEntity(mesh: .generateCylinder(height: columnHeight, radius: 0.008), materials: [Self.flowMaterial(palette.water, opacity: 0)])
            flow.position = [x, shape.baseTop + columnHeight / 2, 0.034]
            flow.isEnabled = false
            flows.append(flow)
            let cap = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 0.03), materials: [pbr(palette.trim, roughness: 0.5)])
            cap.position = [x, shape.height + 0.01, 0]
            trims.append(cap)
            for e in [column, flow, cap] { root.addChild(e) }
        }

        // Pods: a tilted cup with a status collar, and the plant in it.
        let cupMesh = MeshResource.generateCylinder(height: 0.05, radius: 0.027)
        let collarMesh = MeshResource.generateCylinder(height: 0.01, radius: 0.034)
        for p in PodPlace.all(podCount: podCount) {
            let group = Entity()
            group.position = p.position
            // Lean out from the spine and towards the viewer, as the cups do on the bars.
            group.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0]) * simd_quatf(angle: -p.side * 0.35, axis: [0, 0, 1])
            let cup = ModelEntity(mesh: cupMesh, materials: [pbr(palette.cup)])
            cups.append(cup)
            let collar = ModelEntity(mesh: collarMesh, materials: [pbr(palette.status[.empty] ?? .gray)])
            collar.position.y = 0.025
            let plant = Entity()
            plant.position.y = 0.03
            group.addChild(cup)
            group.addChild(collar)
            group.addChild(plant)
            group.components.set(PodComponent(slot: p.slot))
            group.components.set(CollisionComponent(shapes: [ShapeResource.generateSphere(radius: 0.055).offsetBy(translation: [0, 0.04, 0])]))
            group.components.set(InputTargetComponent())
            root.addChild(group)
            pods[p.slot] = PodParts(group: group, collar: collar, plant: plant)
        }

        // Light bars on stalks either side, angled in towards the plants.
        let barHeight = columnHeight * 0.92
        for side: Float in [-1, 1] {
            let x = side * (baseWidth / 2 + 0.02)
            let stalk = ModelEntity(mesh: .generateCylinder(height: shape.height + 0.06, radius: 0.008), materials: [pbr(palette.trim, roughness: 0.5)])
            stalk.position = [x, (shape.height + 0.06) / 2, 0.16]
            trims.append(stalk)
            let housing = ModelEntity(mesh: .generateBox(width: 0.03, height: barHeight, depth: 0.03, cornerRadius: 0.01), materials: [pbr(palette.body)])
            housing.position = [x - side * 0.01, shape.baseTop + 0.04 + barHeight / 2, 0.16]
            housing.orientation = simd_quatf(angle: side * 0.5, axis: [0, 1, 0])
            bodies.append(housing)
            let led = ModelEntity(mesh: .generatePlane(width: 0.016, height: barHeight * 0.96), materials: [pbr(palette.ledOff)])
            led.position = [-side * 0.0151, 0, 0]
            led.orientation = simd_quatf(angle: -side * .pi / 2, axis: [0, 1, 0])
            housing.addChild(led)
            leds.append(led)
            housing.components.set(PartComponent(part: .light))
            housing.components.set(CollisionComponent(shapes: [.generateBox(width: 0.08, height: barHeight, depth: 0.08)]))
            housing.components.set(InputTargetComponent())
            root.addChild(stalk)
            root.addChild(housing)
        }
        // What the bars cast on the plants; it follows the light's level.
        growLight.light.color = palette.ledOn
        growLight.light.intensity = 0
        growLight.light.attenuationRadius = 1.6
        growLight.position = [0, shape.baseTop + columnHeight / 2, 0.45]
        root.addChild(growLight)
        setWater(0)
    }

    // MARK: - State

    func update(_ next: TowerState) {
        state = next
        let bySlot = Dictionary(next.pods.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        for (slot, var parts) in pods {
            let pod = bySlot[slot]
            let status = pod?.status ?? .empty
            let scale = PlantGrowth.scale(status, green: pod?.green, ageDays: pod?.ageDays)
            let form = PlantGrowth.form(status, scale: scale)
            let sick = status == .attention
            let key = "\(pod?.plant ?? "")|\(form.rawValue)|\(sick)"
            if key != parts.built {
                parts.plant.children.removeAll()
                if form != .none { parts.plant.addChild(kit.build(plant: pod?.plant, form: form, slot: slot, sick: sick)) }
                parts.built = key
                pods[slot] = parts
            }
            // Each stage's model is built to size; a measured plant grows a little either side of it.
            parts.plant.scale = .init(repeating: form == .none ? 1 : max(0.8, min(1.2, scale / form.builtScale)))
            paintCollar(parts.collar, shown: pod?.shown ?? .empty, focus: next.selected == slot)
        }
        // The first reading lands without easing in from empty.
        if waterShown == nil, let pct = next.waterPct {
            waterShown = Float(max(0, min(100, pct)) / 100)
            setWater(waterShown ?? 0)
        }
        if lightShown == nil {
            lightShown = Float(max(0, min(100, next.lightLevel)) / 100)
            setLight(lightShown ?? 0)
        }
    }

    private func paintCollar(_ collar: ModelEntity, shown: PodShown, focus: Bool) {
        let tint = palette.status[shown] ?? .gray
        var m = pbr(focus ? palette.highlight : tint, roughness: 0.4)
        m.emissiveColor = .init(color: tint)
        m.emissiveIntensity = focus ? 0.9 : shown == .attention ? 0.6 : shown == .ready ? 0.4 : 0.15
        collar.model?.materials = [m]
        collar.scale = .init(repeating: focus ? 1.25 : 1)
    }

    /// Advances the animations by `dt` seconds.
    func tick(_ dt: Float) {
        let waterTarget = state.waterPct.map { Float(max(0, min(100, $0)) / 100) } ?? 0
        let shown = waterShown ?? waterTarget
        if abs(shown - waterTarget) > 0.002 {
            waterShown = shown + (waterTarget - shown) * min(1, dt * 3)
            setWater(waterShown ?? 0)
        } else if waterShown != waterTarget {
            waterShown = waterTarget
            setWater(waterTarget)
        }

        let lightTarget = Float(max(0, min(100, state.lightLevel)) / 100)
        let light = lightShown ?? lightTarget
        if abs(light - lightTarget) > 0.003 {
            lightShown = light + (lightTarget - light) * min(1, dt * 2.5)
            setLight(lightShown ?? 0)
        } else if lightShown != lightTarget {
            lightShown = lightTarget
            setLight(lightTarget)
        }

        let flowTarget: Float = state.pumpOn ? 0.5 : 0
        if state.pumpOn || flowOpacity > 0.01 {
            flowOpacity += (flowTarget - flowOpacity) * min(1, dt * 1.5)
            if !state.pumpOn, flowOpacity <= 0.01 { flowOpacity = 0 }
            flowPhase += dt * 4
            // A soft swell, so the channel shimmers rather than strobes.
            let shimmer = flowOpacity * (0.75 + 0.25 * sin(flowPhase))
            for f in flows {
                f.isEnabled = flowOpacity > 0
                f.model?.materials = [Self.flowMaterial(palette.water, opacity: shimmer)]
            }
        }
    }

    private func setWater(_ level: Float) {
        water.isEnabled = level > 0.001
        let h = max(0.001, windowHeight * 0.96 * level)
        water.scale.y = h
        water.position.y = tankWindow.position.y - windowHeight * 0.48 + h / 2
    }

    private func setLight(_ level: Float) {
        let on = palette.ledOn
        for led in leds {
            var m = pbr(Self.mix(palette.ledOff, on, min(1, level * 4)))
            m.emissiveColor = .init(color: on)
            m.emissiveIntensity = level * 2.2
            led.model?.materials = [m]
        }
        growLight.light.intensity = level * 9000
    }

    func recolor(_ next: TowerPalette) {
        palette = next
        for e in bodies { e.model?.materials = [pbr(next.body)] }
        for e in trims { e.model?.materials = [pbr(next.trim, roughness: 0.5)] }
        for e in cups { e.model?.materials = [pbr(next.cup, roughness: 0.3)] }
        water.model?.materials = [Self.waterMaterial(next.water)]
        growLight.light.color = next.ledOn
        setLight(lightShown ?? 0)
        let current = state
        state = TowerState()
        update(current)
    }

    // MARK: - Picking and anchors

    /// The pod or part an entity (or one of its ancestors) belongs to.
    static func target(of entity: Entity) -> TowerTarget? {
        var e: Entity? = entity
        while let current = e {
            if let pod = current.components[PodComponent.self] { return .pod(pod.slot) }
            if let part = current.components[PartComponent.self] { return .part(part.part) }
            e = current.parent
        }
        return nil
    }

    /// Where a pod's collar sits in world space, for pinning a ring or flag to it.
    func anchor(slot: Int) -> SIMD3<Float>? {
        pods[slot]?.collar.position(relativeTo: nil)
    }

    // MARK: - Materials

    private static func waterMaterial(_ color: UIColor) -> PhysicallyBasedMaterial {
        var m = pbr(color, roughness: 0.2)
        m.emissiveColor = .init(color: color)
        m.emissiveIntensity = 0.25
        return m
    }

    private static func flowMaterial(_ color: UIColor, opacity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: color)
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }

    static func mix(_ a: UIColor, _ b: UIColor, _ t: Float) -> UIColor {
        var (ar, ag, ab, aa): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let t = CGFloat(t)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: aa + (ba - aa) * t)
    }
}

enum TowerTarget: Equatable, Sendable {
    case pod(Int)
    case part(TowerPart)
}
