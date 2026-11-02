import Foundation
import Network
import Testing
@testable import Seedypod

@Suite struct ConnectionTests {
    @Test(arguments: [
        ("192.168.1.20", "http://192.168.1.20:3000"),
        ("gardyn.local:8080", "http://gardyn.local:8080"),
        (" http://gardyn.local/ ", "http://gardyn.local:3000"),
        ("https://garden.example.com", "https://garden.example.com"),
        ("http://10.0.0.5:3000/api/trpc?x=1", "http://10.0.0.5:3000")
    ])
    func baseURLFromTypedAddress(typed: String, expected: String) {
        #expect(Connection.baseURL(from: typed)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://gardyn.local", "http://"])
    func rejectsWhatIsNotAnAddress(typed: String) {
        #expect(Connection.baseURL(from: typed) == nil)
    }

    @MainActor @Test func remembersTheUnitAndForgetsItOnDisconnect() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID())"))
        let keychain = KeyStore(service: "test.\(UUID())")
        let c = Connection(defaults: defaults, keychain: keychain)
        #expect(c.api == nil)
        c.connect(URL(string: "http://10.0.0.5:3000")!, name: "Kitchen")
        #expect(c.api is CoreClient)
        let again = Connection(defaults: defaults, keychain: keychain)
        #expect(again.target == .unit(URL(string: "http://10.0.0.5:3000")!))
        #expect(again.name == "Kitchen")
        again.startDemo()
        #expect(Connection(defaults: defaults, keychain: keychain).isDemo)
        again.disconnect()
        #expect(Connection(defaults: defaults, keychain: keychain).target == nil)
    }
}

@Suite struct DiscoveryTests {
    @Test func readsCoreTXTRecord() {
        let txt = UnitDiscovery.TXT(["id": "gardyn-1", "v": "1.5.0", "auth": "1"])
        #expect(txt.unitID == "gardyn-1")
        #expect(txt.version == "1.5.0")
        #expect(txt.needsKey)
        #expect(!UnitDiscovery.TXT(["auth": "0"]).needsKey)
    }

    @Test func buildsBaseURLFromResolvedEndpoint() {
        #expect(UnitDiscovery.url(host: .ipv4(IPv4Address("192.168.1.20")!), port: 3000)?.absoluteString == "http://192.168.1.20:3000")
        #expect(UnitDiscovery.url(host: .name("gardyn.local", nil), port: 3001)?.absoluteString == "http://gardyn.local:3001")
        #expect(UnitDiscovery.url(host: .ipv6(IPv6Address("fe80::1%en0")!), port: 3000)?.host() == "fe80::1")
    }
}

@Suite struct EventStreamTests {
    @Test func targetsCoreWebSocket() throws {
        let stream = try #require(EventStream(baseURL: URL(string: "http://10.0.0.5:3000")!, apiKey: nil))
        _ = stream
        #expect(EventStream.kind(of: .string(#"{"kind":"hello","snapshot":{},"version":"1.4.0"}"#)) == "hello")
        #expect(EventStream.kind(of: .data(Data(#"{"kind":"mutation","path":"pods"}"#.utf8))) == "mutation")
        #expect(EventStream.kind(of: .string("not json")) == nil)
    }
}

@Suite struct PodTests {
    private func pod(_ slot: Int, _ status: PodStatus, plant: String? = "Basil", plantedAt: String? = "2026-10-13") -> Pod {
        Pod(slot: slot, plant: plant, plantedAt: plantedAt, status: status, notes: "", updatedAt: "2026-11-01T00:00:00.000Z", statusSince: nil, lastHarvestAt: nil)
    }

    private func outlook(_ slot: Int, _ state: HarvestOutlook.State) -> HarvestOutlook {
        HarvestOutlook(slot: slot, plant: "Basil", state: state, ageDays: 19, cover: 0.4, targetCover: 0.4, window: nil, daysToReady: 0, daysLeft: nil, reason: "")
    }

    @Test func shownPutsAttentionFirstAndLetsTheOutlookPromote() {
        #expect(TowerPod(slot: 1, status: .attention, plant: "Kale", harvest: outlook(1, .ready)).shown == .attention)
        #expect(TowerPod(slot: 1, status: .growing, plant: "Kale", harvest: outlook(1, .ready)).shown == .ready)
        #expect(TowerPod(slot: 1, status: .growing, plant: "Kale", harvest: outlook(1, .soon)).shown == .soon)
        #expect(TowerPod(slot: 1, status: .seeded, plant: "Kale").shown == .seeded)
        #expect(TowerPod(slot: 1, status: .empty, plant: nil, harvest: outlook(1, .ready)).shown == .empty)
    }

    @Test func joinAddsTrendOutlookAndAgeAndCountsAddUp() throws {
        let now = try #require(ISO.date("2026-11-01T00:00:00.000Z"))
        let snapshot = HomeSnapshot(
            pods: [pod(1, .growing), pod(2, .harvest), pod(3, .attention), pod(4, .empty, plant: nil, plantedAt: nil), pod(5, .seeded)],
            grow: GrowCurrent(cycle: nil, day: nil), sensors: [:], light: nil, pump: nil, alerts: [],
            harvest: [outlook(1, .soon)], trends: [PodTrend(slot: 1, green: 0.3, verdict: .growing, recent: [])]
        )
        let pods = TowerPod.join(snapshot, now: now)
        #expect(pods[0].green == 0.3)
        #expect(pods[0].shown == .soon)
        #expect(pods[0].ageDays.map { Int($0.rounded()) } == 19)
        #expect(pods[3].ageDays == nil)
        let counts = PodCount.counts(pods)
        #expect(counts == [.growing: 2, .ready: 1, .attention: 1, .empty: 1])
        #expect(counts.values.reduce(0, +) == pods.count)
    }

    @Test func formatsReadingsAndDurations() throws {
        #expect(Format.reading(Reading(ts: "", value: 25.54, unit: "°C")) == "25.5°")
        #expect(Format.reading(Reading(ts: "", value: 71, unit: "%"), digits: 0) == "71%")
        #expect(Format.reading(Reading(ts: "", value: 9.4, unit: "cm")) == "9.4 cm")
        #expect(Format.reading(nil) == "—")
        let now = try #require(ISO.date("2026-11-03T00:00:00Z"))
        #expect(Format.heldFor("2026-11-02T23:30:00Z", now: now) == "now")
        #expect(Format.heldFor("2026-11-02T19:00:00Z", now: now) == "5 h")
        #expect(Format.heldFor("2026-11-01T00:00:00.000Z", now: now) == "2 d")
        #expect(Format.heldFor(nil, now: now) == nil)
    }
}

@Suite struct DemoClientTests {
    @Test func seedsCoreDemoTower() async throws {
        let home = try await DemoClient().home()
        #expect(home.pods.count == 30)
        #expect(home.pods.filter { $0.plant != nil }.count == 24)
        #expect(home.grow.day == 19)
        let counts = PodCount.counts(TowerPod.join(home))
        #expect(counts[.ready] == 6)
        #expect(counts[.attention] == 1)
        #expect(counts[.empty] == 6)
    }

    @Test func actionsChangeWhatHomeShows() async throws {
        let demo = DemoClient()
        _ = try await demo.markHarvested(slot: 1)
        _ = try await demo.setPodStatus(slot: 9, status: .growing)
        _ = try await demo.setLight(on: false, level: nil)
        _ = try await demo.runPump(seconds: 30)
        let alert = try #require(try await demo.home().alerts.first)
        try await demo.acknowledgeAlert(id: alert.id)
        let home = try await demo.home()
        #expect(home.pods[0].status == .growing && home.pods[0].lastHarvestAt != nil)
        #expect(home.pods[8].status == .growing)
        #expect(home.light?.on == false)
        #expect(home.lightOwner?.source == .manual)
        #expect(home.pump?.on == true)
        #expect(home.alerts.isEmpty)
        _ = try await demo.resumeLight()
        _ = try await demo.stopPump()
        let after = try await demo.home()
        #expect(after.lightOwner?.source == .schedule)
        #expect(after.pump?.on == false)
        await #expect(throws: APIError.self) { _ = try await demo.markHarvested(slot: 99) }
    }

    @Test func pumpRunEndsOnItsOwn() async throws {
        let clock = Clock()
        let demo = DemoClient(now: { clock.now })
        _ = try await demo.runPump(seconds: 30)
        clock.advance(10)
        #expect(try await demo.home().pump?.remainingS == 20)
        clock.advance(25)
        #expect(try await demo.home().pump?.on == false)
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_793_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }
}

@MainActor @Suite struct HomeStoreTests {
    @Test func refreshLoadsAndActionsRefresh() async {
        let store = HomeStore(api: DemoClient())
        await store.refresh()
        #expect(store.snapshot?.pods.count == 30)
        #expect(store.error == nil)
        await store.runPump(seconds: 30)
        #expect(store.snapshot?.pump?.on == true)
        await store.markHarvested(99)
        #expect(store.actionError != nil)
    }

    @Test func refreshReportsUnreachableUnit() async {
        let session = StubProtocol.session("down") { _ in (503, "{}") }
        let store = HomeStore(api: CoreClient(baseURL: URL(string: "http://x.local:3000")!, session: session))
        await store.refresh()
        #expect(store.error == .invalidResponse(statusCode: 503))
        #expect(store.snapshot == nil)
    }
}
