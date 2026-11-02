import RealityKit
import Testing
@testable import Seedypod

@Suite struct TowerLayoutTests {
    @Test func homeIsThreeColumnsOfTenAndStudioTwoOfEight() {
        let home = TowerShape(podCount: 30)
        #expect(home.columns == 3 && home.rows == 10)
        #expect(home.columnX == [-0.2, 0, 0.2])
        #expect(abs(home.height - (0.3 + 0.12 + 10 * 0.115)) < 0.0001)
        let studio = TowerShape(podCount: 16)
        #expect(studio.columns == 2 && studio.rows == 8)
    }

    @Test func slotsCountAcrossThenDownAndAlternateSides() {
        let places = PodPlace.all(podCount: 30)
        #expect(places.count == 30)
        #expect(places[0].slot == 1 && places[0].row == 0 && places[0].column == 0 && places[0].side == 1)
        #expect(places[3].row == 1 && places[3].column == 0 && places[3].side == -1)
        // Pods 1–15 are the upper half (the upper camera's), as core's analysis assumes.
        #expect(places[14].position.y > places[15].position.y)
        #expect(places[0].position.y > places[29].position.y)
    }

    @Test func plantScaleAndFormFollowCoreTowerLayout() {
        #expect(PlantGrowth.scale(.empty, green: 0.5, ageDays: 10) == 0)
        #expect(PlantGrowth.scale(.seeded, green: nil, ageDays: nil) == 0.25)
        #expect(abs(PlantGrowth.scale(.growing, green: 0.3, ageDays: nil) - 0.68) < 0.0001)
        #expect(PlantGrowth.scale(.growing, green: 2, ageDays: nil) == 1)
        #expect(PlantGrowth.scale(.harvest, green: nil, ageDays: nil) == 0.95)
        #expect(abs(PlantGrowth.scale(.growing, green: nil, ageDays: 35) - 0.95) < 0.0001)
        #expect(PlantGrowth.scale(.growing, green: nil, ageDays: nil) == 0.55)
        #expect(PlantGrowth.form(.empty, scale: 0) == PlantForm.none)
        #expect(PlantGrowth.form(.seeded, scale: 0.25) == .sprout)
        #expect(PlantGrowth.form(.growing, scale: 0.5) == .young)
        #expect(PlantGrowth.form(.attention, scale: 0.7) == .bush)
        #expect(PlantGrowth.form(.harvest, scale: 0.95) == .full)
    }
}

@MainActor @Suite struct TowerSceneTests {
    @Test func cropsMatchByNameMostSpecificFirst() {
        #expect(PlantKit.crop(for: "Thai Basil").stem != PlantKit.crop(for: "Genovese Basil").stem)
        #expect(PlantKit.crop(for: "Red Russian Kale").habit == .upright)
        #expect(PlantKit.crop(for: "Cherry Tomato").fruit != nil)
        #expect(PlantKit.crop(for: "Dill").habit == .feathery)
        #expect(PlantKit.crop(for: "Something new").habit == .rosette)
        #expect(PlantKit.crop(for: nil).habit == .rosette)
    }

    @Test func picksResolveToTheirPodOrPart() throws {
        let scene = TowerScene(podCount: 30, palette: .dark)
        let pods = scene.root.children.filter { $0.components[PodComponent.self] != nil }
        #expect(pods.count == 30)
        let seven = try #require(pods.first { $0.components[PodComponent.self]?.slot == 7 })
        // A tap lands on a cup or leaf deep in the pod; it still means the pod.
        let cup = try #require(seven.children.first)
        #expect(TowerScene.target(of: cup) == .pod(7))
        let parts = scene.root.children.compactMap { $0.components[PartComponent.self]?.part }
        #expect(parts.filter { $0 == .light }.count == 2)
        #expect(parts.contains(.tank))
        #expect(TowerScene.target(of: scene.root) == nil)
        #expect(scene.anchor(slot: 7) != nil)
        #expect(scene.anchor(slot: 31) == nil)
    }

    @Test func updateGrowsPlantsOnlyWherePlantedAndRebuildsOnChange() async throws {
        let home = try await DemoClient().home()
        let scene = TowerScene(podCount: 30, palette: .dark)
        var state = TowerState(pods: TowerPod.join(home), waterPct: 71, lightLevel: 85, pumpOn: true, selected: 2)
        scene.update(state)
        // A pod is its cup, collar and plant holder, in that order.
        func plant(_ slot: Int) -> Entity? {
            scene.root.children.first { $0.components[PodComponent.self]?.slot == slot }?.children[2]
        }
        #expect(plant(1)?.children.isEmpty == false)
        #expect(plant(30)?.children.isEmpty != false)
        let before = plant(1)?.children.first
        state.selected = nil
        scene.update(state)
        #expect(plant(1)?.children.first === before)
        state.pods[0] = TowerPod(slot: 1, status: .empty, plant: nil)
        scene.update(state)
        #expect(plant(1)?.children.isEmpty != false)
        for _ in 0..<60 { scene.tick(1 / 60) }
        scene.recolor(.light)
    }
}
