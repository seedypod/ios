import Foundation
import OSLog

/// tRPC client for seedypod core.
///
/// The transport (queries, mutations, batching, retry, error decoding) is ported
/// from sleepypod/ios's `SleepypodCoreClient` per seedypod/core ADR-0017: core mounts
/// the same `@hono/trpc-server` at `/api/trpc` with the superjson transformer, so
/// inputs travel as `{"json": …}` and results come back as `{"result":{"data":{"json": …}}}`.
/// The only addition is the optional `X-API-Key` header (ADR-0012).
final class CoreClient: SeedypodAPI {
    let baseURL: URL
    private let apiKey: String?
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(baseURL: URL, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.session = session
    }

    // MARK: - SeedypodAPI

    func systemInfo() async throws -> SystemInfo {
        try await query("system.info")
    }

    func home() async throws -> HomeSnapshot {
        let slots = try await batchQuery([
            .init("grow.pods"),
            .init("grow.current"),
            .init("sensors.latest"),
            .init("light.get"),
            .init("pump.get"),
            .init("alerts.list", ActiveOnly(activeOnly: true)),
            .init("grow.harvest"),
            .init("vision.podTrends"),
            .init("light.owner")
        ])
        return HomeSnapshot(
            pods: try decode([Pod].self, slots[0]),
            grow: try decode(GrowCurrent.self, slots[1]),
            sensors: try decode([String: Reading].self, slots[2]),
            light: try decode(ActuatorState?.self, slots[3]),
            pump: try decode(ActuatorState?.self, slots[4]),
            alerts: try decode([CoreAlert].self, slots[5]),
            harvest: (try? decode([HarvestOutlook].self, slots[6])) ?? [],
            trends: (try? decode([PodTrend].self, slots[7])) ?? [],
            lightOwner: try? decode(LightOwner.self, slots[8])
        )
    }

    func setLight(on: Bool?, level: Double?) async throws -> ActuatorState {
        try await mutate("light.set", LightInput(on: on, level: level))
    }

    func resumeLight() async throws -> LightOwner {
        try await mutate("light.resume", Empty())
    }

    func runPump(seconds: Int) async throws -> ActuatorState {
        try await mutate("pump.runOnce", PumpRun(durationS: seconds))
    }

    func stopPump() async throws -> ActuatorState {
        try await mutate("pump.stop", Empty())
    }

    func markHarvested(slot: Int) async throws -> Pod {
        try await mutate("grow.markHarvested", Slot(slot: slot))
    }

    func updatePod(slot: Int, _ patch: PodPatch) async throws -> Pod {
        try await mutate("grow.updatePod", PodUpdate(slot: slot, patch: patch))
    }

    func acknowledgeAlert(id: Int) async throws {
        let _: CoreAlert? = try await mutate("alerts.acknowledge", AlertID(id: id))
    }

    // MARK: - Inputs

    struct Empty: Encodable, Sendable {}
    private struct ActiveOnly: Encodable, Sendable { let activeOnly: Bool }
    private struct LightInput: Encodable, Sendable { let on: Bool?; let level: Double? }
    private struct PumpRun: Encodable, Sendable { let durationS: Int }
    private struct Slot: Encodable, Sendable { let slot: Int }
    struct PodUpdate: Encodable, Sendable {
        let slot: Int
        let patch: PodPatch
        enum Keys: String, CodingKey { case slot, plant, plantedAt, status, notes }

        // Synthesised Encodable drops nils; core needs an explicit null to clear a plant.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(slot, forKey: .slot)
            if let plant = patch.plant { try c.encode(plant, forKey: .plant) }
            if let plantedAt = patch.plantedAt { try c.encode(plantedAt, forKey: .plantedAt) }
            try c.encodeIfPresent(patch.status, forKey: .status)
            try c.encodeIfPresent(patch.notes, forKey: .notes)
        }
    }
    private struct AlertID: Encodable, Sendable { let id: Int }

    // MARK: - tRPC Transport

    /// `{"json": input}`: superjson's envelope for plain JSON values.
    private struct SuperJSON<T: Encodable>: Encodable { let json: T }

    struct BatchCall: Sendable {
        let procedure: String
        let input: any Encodable & Sendable
        init(_ procedure: String, _ input: any Encodable & Sendable = Empty()) {
            self.procedure = procedure
            self.input = input
        }
    }

    private struct AnyInput: Encodable {
        let wrapped: any Encodable
        func encode(to encoder: any Encoder) throws { try wrapped.encode(to: encoder) }
    }

    /// GET /api/trpc/{procedure}?input={"json":…}
    func query<T: Decodable>(_ procedure: String, _ input: some Encodable & Sendable = Empty()) async throws -> T {
        let payload = try Self.queryParam(SuperJSON(json: input))
        guard let url = URL(string: "\(baseURL.absoluteString)/api/trpc/\(procedure)?input=\(payload)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let data = try await send(request, procedure: procedure)
        return try decodeEnvelope(data)
    }

    /// POST /api/trpc/{procedure} with body {"json":…}
    func mutate<T: Decodable>(_ procedure: String, _ input: some Encodable & Sendable) async throws -> T {
        guard let url = URL(string: "\(baseURL.absoluteString)/api/trpc/\(procedure)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(SuperJSON(json: input))
        let data = try await send(request, procedure: procedure)
        return try decodeEnvelope(data)
    }

    /// Batched queries in one request, as @trpc/client's httpBatchLink sends them:
    /// GET /api/trpc/a,b,c?batch=1&input={"0":{"json":…},"1":…}. Each slot comes back as
    /// the raw JSON of its result, or the error the server gave for that call alone.
    func batchQuery(_ calls: [BatchCall]) async throws -> [Result<Data, APIError>] {
        guard !calls.isEmpty else { return [] }
        var inputs: [String: SuperJSON<AnyInput>] = [:]
        for (i, call) in calls.enumerated() { inputs[String(i)] = SuperJSON(json: AnyInput(wrapped: call.input)) }
        let procedures = calls.map(\.procedure).joined(separator: ",")
        let payload = try Self.queryParam(inputs)
        guard let url = URL(string: "\(baseURL.absoluteString)/api/trpc/\(procedures)?batch=1&input=\(payload)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        // A batch answers 207 when some calls failed; the slots say which.
        let data = try await send(request, procedure: procedures, accept: 207)

        guard let slots = try? JSONSerialization.jsonObject(with: data) as? [Any], slots.count == calls.count else {
            throw APIError.decodingFailed("expected \(calls.count) batch results")
        }
        return slots.map { slot in
            guard let obj = slot as? [String: Any] else { return .failure(.decodingFailed("batch slot")) }
            if let err = obj["error"] as? [String: Any] {
                return .failure(.server(message: Self.message(in: err) ?? "tRPC error"))
            }
            guard let result = obj["result"] as? [String: Any],
                  let body = result["data"] as? [String: Any] else {
                return .failure(.decodingFailed("batch slot has no result"))
            }
            // A null result (light.get on a unit without a light) has no "json" key's value to serialise.
            let json = body["json"] ?? NSNull()
            guard let bytes = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]) else {
                return .failure(.decodingFailed("batch slot json"))
            }
            return .success(bytes)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ slot: Result<Data, APIError>) throws -> T {
        let data = try slot.get()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed("\(T.self): \(error)")
        }
    }

    private struct Envelope<R: Decodable>: Decodable {
        struct Result: Decodable { let data: Wrapper }
        struct Wrapper: Decodable { let json: R }
        let result: Result
    }

    private func decodeEnvelope<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(Envelope<T>.self, from: data).result.data.json
        } catch {
            Log.network.error("decode failed: \(error)")
            throw APIError.decodingFailed("\(T.self): \(error)")
        }
    }

    /// Percent-encodes JSON for a query string, including the characters URLQueryAllowed leaves alone but tRPC's parser splits on.
    static func queryParam(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        return json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? json
    }

    private func send(_ request: URLRequest, procedure: String, accept extra: Int? = nil) async throws -> Data {
        var request = request
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse(statusCode: 0) }
        if (200...299).contains(http.statusCode) || http.statusCode == extra { return data }
        if http.statusCode == 401 { throw APIError.unauthorized }
        Log.network.error("HTTP \(http.statusCode) \(procedure)")
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = envelope["error"] as? [String: Any],
           let message = Self.message(in: err) {
            throw APIError.server(message: message)
        }
        throw APIError.invalidResponse(statusCode: http.statusCode)
    }

    private static func message(in error: [String: Any]) -> String? {
        (error["json"] as? [String: Any])?["message"] as? String ?? error["message"] as? String
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where request.httpMethod == "GET" && Self.isTransient(error) {
            // A pooled keep-alive connection the unit already closed fails once; queries are safe to resend.
            do {
                return try await session.data(for: request)
            } catch {
                throw APIError.network(error.localizedDescription)
            }
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    static func isTransient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code)
    }
}

enum Log {
    static let network = Logger(subsystem: "com.jonathanng.seedypod", category: "network")
    static let discovery = Logger(subsystem: "com.jonathanng.seedypod", category: "discovery")
    static let stream = Logger(subsystem: "com.jonathanng.seedypod", category: "stream")
}
