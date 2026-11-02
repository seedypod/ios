import RealityKit
import SwiftUI

/// Camera, picking and pinned overlays for the tower. Holds the scene across
/// SwiftUI updates and publishes where the pods that carry a marker sit on screen.
@MainActor
@Observable
final class TowerModel {
    /// Where the camera orbits from, after core's towerRenderer VIEW (drag to turn, pinch to zoom).
    struct View: Equatable {
        // Further back than the web's 3.9 m: a phone is tall and narrow, and Home's header and readings cover its ends.
        static let initial = View(azimuth: -18 * .pi / 180, elevation: 9 * .pi / 180, distance: 4.6)
        var azimuth: Float
        var elevation: Float
        var distance: Float

        func clamped() -> View {
            View(azimuth: max(-70 * .pi / 180, min(70 * .pi / 180, azimuth)),
                 elevation: max(-5 * .pi / 180, min(40 * .pi / 180, elevation)),
                 distance: max(1.6, min(6, distance)))
        }
    }

    @ObservationIgnored let scene: TowerScene
    @ObservationIgnored let world = Entity()
    @ObservationIgnored private let camera = PerspectiveCamera()
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var content: RealityViewCameraContent?
    @ObservationIgnored var view = View.initial {
        didSet { placeCamera() }
    }
    @ObservationIgnored var dragStart: View?

    /// Screen points of the pinned pods' collars, whole points so a still frame doesn't re-render.
    private(set) var anchors: [Int: CGPoint] = [:]
    @ObservationIgnored var pinned: [Int] = []

    init(podCount: Int, palette: TowerPalette) {
        scene = TowerScene(podCount: podCount, palette: palette)
        world.addChild(scene.root)

        camera.camera.fieldOfViewInDegrees = 32
        camera.camera.near = 0.05
        camera.camera.far = 20
        world.addChild(camera)

        // Soft studio lighting: a warm key from the front right that casts shadows, a cool fill from the left.
        let key = DirectionalLight()
        key.light.color = UIColor(hex: 0xFFF6EA)
        key.light.intensity = 2600
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 6, depthBias: 2)
        key.look(at: [0, scene.shape.height * 0.4, 0], from: [1.5, 3, 2.2], relativeTo: nil)
        world.addChild(key)
        let fill = DirectionalLight()
        fill.light.color = UIColor(hex: 0xDFE8FF)
        fill.light.intensity = 900
        fill.look(at: [0, scene.shape.height * 0.5, 0], from: [-2, 1.5, 1], relativeTo: nil)
        world.addChild(fill)
        placeCamera()
    }

    private func placeCamera() {
        let v = view
        // Aim above the tower's middle, so it sits lower on screen, clear of the header.
        let lookY = scene.shape.height * 0.5 + 0.18
        let ground = v.distance * cos(v.elevation)
        camera.look(at: [0, lookY, 0], from: [ground * sin(v.azimuth), lookY + v.distance * sin(v.elevation), ground * cos(v.azimuth)], relativeTo: nil)
    }

    func attach(_ content: RealityViewCameraContent) {
        self.content = content
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.frame(Float(event.deltaTime))
            }
        }
    }

    private func frame(_ dt: Float) {
        scene.tick(min(0.1, dt))
        guard let content else { return }
        var next: [Int: CGPoint] = [:]
        for slot in pinned {
            guard let world = scene.anchor(slot: slot), let p = content.project(point: world, to: .local) else { continue }
            next[slot] = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        }
        if next != anchors { anchors = next }
    }
}

/// The tower in 3D across Home. Drag to turn it, pinch to zoom, double-tap to
/// reset; tap a pod to pick it, or the light bars or tank to open their panel.
/// Pods that want doing something about carry a flag; the picked pod a ring.
struct TowerView: View {
    let pods: [TowerPod]
    let waterPct: Double?
    let lightLevel: Double
    let pumpOn: Bool
    @Binding var selected: Int?
    let onPart: (TowerPart) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var model: TowerModel

    init(pods: [TowerPod], waterPct: Double?, lightLevel: Double, pumpOn: Bool, selected: Binding<Int?>, onPart: @escaping (TowerPart) -> Void) {
        self.pods = pods
        self.waterPct = waterPct
        self.lightLevel = lightLevel
        self.pumpOn = pumpOn
        _selected = selected
        self.onPart = onPart
        _model = State(initialValue: TowerModel(podCount: max(pods.count, 30), palette: .dark))
    }

    private var flagged: [TowerPod] { pods.filter { $0.shown == .attention || $0.shown == .ready } }

    var body: some View {
        RealityView { content in
            content.add(model.world)
            model.attach(content)
        } update: { _ in
            model.pinned = Array(Set(flagged.map(\.slot) + [selected].compactMap { $0 }))
            model.scene.update(TowerState(pods: pods, waterPct: waterPct, lightLevel: lightLevel, pumpOn: pumpOn, selected: selected))
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    switch TowerScene.target(of: value.entity) {
                    case .pod(let slot): selected = selected == slot ? nil : slot
                    case .part(let part): onPart(part)
                    case nil: selected = nil
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { g in
                    let start = model.dragStart ?? model.view
                    model.dragStart = start
                    var v = start
                    v.azimuth -= Float(g.translation.width) * 0.008
                    v.elevation += Float(g.translation.height) * 0.004
                    model.view = v.clamped()
                }
                .onEnded { _ in model.dragStart = nil }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { g in
                    let start = model.dragStart ?? model.view
                    model.dragStart = start
                    var v = start
                    v.distance /= Float(g.magnification)
                    model.view = v.clamped()
                }
                .onEnded { _ in model.dragStart = nil }
        )
        .onTapGesture(count: 2) {
            withAnimation(.snappy) { model.view = .initial }
        }
        .overlay { markers.allowsHitTesting(true) }
        .onChange(of: scheme, initial: true) { _, s in
            model.scene.recolor(s == .light ? .light : .dark)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tower in 3D")
    }

    /// Flags on the pods to harvest or see to, and a ring on the picked one, following them as the tower turns.
    private var markers: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(flagged) { pod in
                if let at = model.anchors[pod.slot] {
                    Button { selected = selected == pod.slot ? nil : pod.slot } label: {
                        Image(systemName: pod.shown == .ready ? "scissors" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.inverse)
                            .frame(width: 22, height: 22)
                            .background(pod.shown.color, in: .circle)
                            .overlay(Circle().strokeBorder(Theme.app, lineWidth: 2))
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .position(x: at.x + 18, y: at.y - 18)
                    .accessibilityLabel("Pod \(pod.slot): \(pod.plant ?? "empty"), \(pod.shown.label)")
                }
            }
            if let slot = selected, let at = model.anchors[slot] {
                ZStack {
                    Circle().strokeBorder(Theme.text1, lineWidth: 1.5).frame(width: 22, height: 22)
                    Circle().fill(Theme.text1).frame(width: 6, height: 6)
                }
                .position(at)
                .allowsHitTesting(false)
            }
        }
    }
}
