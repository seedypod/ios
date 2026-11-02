import Foundation
import Testing
@testable import Seedypod

/// Answers requests from a per-test handler, so the transport is tested against core's real wire format without a unit.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [String: (URLRequest) -> (Int, String)] = [:]
    nonisolated(unsafe) static var seen: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func session(_ id: String, handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        lock.withLock {
            handlers[id] = handler
            seen[id] = []
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub": id]
        return URLSession(configuration: config)
    }

    static func requests(_ id: String) -> [URLRequest] { lock.withLock { seen[id] ?? [] } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            req.httpBody = data
        }
        let handler = Self.lock.withLock { () -> ((URLRequest) -> (Int, String))? in
            Self.seen[id, default: []].append(req)
            return Self.handlers[id]
        }
        let (status, body) = handler?(req) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct CoreClientTests {
    let base = URL(string: "http://unit.local:3000")!

    @Test func queryWrapsInputInSuperJSONAndUnwrapsTheResult() async throws {
        let session = StubProtocol.session("query") { _ in
            (200, #"{"result":{"data":{"json":{"coreVersion":"1.4.0","coreHost":null,"halOnline":true,"system":null}}}}"#)
        }
        let info = try await CoreClient(baseURL: base, session: session).systemInfo()
        #expect(info.coreVersion == "1.4.0")
        #expect(info.halOnline)
        let req = try #require(StubProtocol.requests("query").first)
        #expect(req.url?.path == "/api/trpc/system.info")
        #expect(req.url?.query?.removingPercentEncoding == #"input={"json":{}}"#)
        #expect(req.value(forHTTPHeaderField: "X-API-Key") == nil)
    }

    @Test func mutationPostsJSONBodyAndSendsTheAPIKey() async throws {
        let session = StubProtocol.session("mutate") { _ in
            (200, #"{"result":{"data":{"json":{"on":true,"level":100,"since":"2026-11-01T00:00:00.000Z","fault":null,"remainingS":60}}}}"#)
        }
        let state = try await CoreClient(baseURL: base, apiKey: "s3cret", session: session).runPump(seconds: 60)
        #expect(state.on && state.remainingS == 60)
        let req = try #require(StubProtocol.requests("mutate").first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/trpc/pump.runOnce")
        #expect(req.value(forHTTPHeaderField: "X-API-Key") == "s3cret")
        let body = try #require(req.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["json"] as? [String: Any])?["durationS"] as? Int == 60)
    }

    @Test func homeBatchesEveryQueryAndToleratesOptionalFailures() async throws {
        let ok = { (json: String) in #"{"result":{"data":{"json":\#(json)}}}"# }
        let slots = [
            ok(#"[{"slot":1,"plant":"Arugula","plantedAt":"2026-10-14","status":"harvest","notes":"","updatedAt":"2026-11-01T00:00:00.000Z","statusSince":null,"lastHarvestAt":null}]"#),
            ok(#"{"cycle":{"id":"c","startedAt":"2026-10-14T00:00:00.000Z","endedAt":null,"stage":"vegetative","notes":"Autumn","issued":[]},"day":19}"#),
            ok(#"{"water_level_pct":{"ts":"2026-11-01T00:00:00.000Z","value":71,"unit":"%","quality":"good"}}"#),
            ok(#"{"on":true,"level":49,"since":"2026-11-01T00:00:00.000Z","fault":null,"remainingS":null}"#),
            ok("null"),
            ok("[]"),
            #"{"error":{"json":{"message":"no such procedure","code":-32004}}}"#,
            ok(#"[{"slot":1,"green":0.43,"verdict":"growing","slope":0.01,"samples":5,"recent":[0.4,0.43]}]"#),
            ok(#"{"source":"schedule","level":49,"leaseId":null,"manualUntil":null,"schedule":49}"#)
        ]
        let session = StubProtocol.session("batch") { _ in (207, "[\(slots.joined(separator: ","))]") }
        let home = try await CoreClient(baseURL: base, session: session).home()
        #expect(home.pods.first?.plant == "Arugula")
        #expect(home.grow.day == 19)
        #expect(home.reading(.waterLevelPct)?.value == 71)
        #expect(home.light?.level == 49)
        #expect(home.pump == nil)
        #expect(home.harvest.isEmpty)
        #expect(home.trends.first?.green == 0.43)
        #expect(home.lightOwner?.source == .schedule)

        let req = try #require(StubProtocol.requests("batch").first)
        #expect(req.url?.path == "/api/trpc/grow.pods,grow.current,sensors.latest,light.get,pump.get,alerts.list,grow.harvest,vision.podTrends,light.owner")
        let query = try #require(req.url?.query?.removingPercentEncoding)
        #expect(query.hasPrefix("batch=1&input="))
        #expect(query.contains(#""5":{"json":{"activeOnly":true}}"#))
    }

    @Test func requiredBatchFailureThrows() async {
        let session = StubProtocol.session("batch-fail") { _ in
            (207, "[" + Array(repeating: #"{"error":{"json":{"message":"db locked"}}}"#, count: 9).joined(separator: ",") + "]")
        }
        await #expect(throws: APIError.server(message: "db locked")) {
            _ = try await CoreClient(baseURL: base, session: session).home()
        }
    }

    @Test func surfacesTRPCErrorMessagesAndUnauthorized() async {
        let refused = StubProtocol.session("refused") { _ in
            (412, #"{"error":{"json":{"message":"dry-run interlock: tank empty","code":-32012}}}"#)
        }
        await #expect(throws: APIError.server(message: "dry-run interlock: tank empty")) {
            _ = try await CoreClient(baseURL: base, session: refused).runPump(seconds: 30)
        }
        let locked = StubProtocol.session("locked") { _ in (401, #"{"error":"unauthorized"}"#) }
        await #expect(throws: APIError.unauthorized) {
            _ = try await CoreClient(baseURL: base, session: locked).systemInfo()
        }
    }

    @Test func queryParamEscapesTheCharactersTRPCSplitsOn() throws {
        struct Input: Encodable { let q: String }
        let s = try CoreClient.queryParam(Input(q: "a&b=c+d?#"))
        #expect(!s.contains("&") && !s.contains("=") && !s.contains("+") && !s.contains("?") && !s.contains("#"))
        #expect(s.removingPercentEncoding == #"{"q":"a&b=c+d?#"}"#)
    }
}
