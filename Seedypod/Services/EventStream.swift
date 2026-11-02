import Foundation

/// Core's raw event stream over WebSocket (`/api/ws`, ADR-0015): a `hello` frame
/// with the HAL snapshot, then one CoreEvent per mutation, HAL event or schedule
/// firing. Home only needs to know *that* something changed, so frames are
/// reduced to their `kind`. The receive loop follows sleepypod/ios's
/// `SensorStreamService`, retargeted per ADR-0017.
final class EventStream: Sendable {
    private let url: URL
    private let apiKey: String?

    init?(baseURL: URL, apiKey: String?) {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = "/api/ws"
        guard let url = parts.url else { return nil }
        self.url = url
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
    }

    /// Kinds of frames as they arrive, reconnecting with backoff until the consumer stops iterating.
    func kinds() -> AsyncStream<String> {
        let url = url
        let apiKey = apiKey
        return AsyncStream { continuation in
            let task = Task {
                var delay: Duration = .seconds(1)
                while !Task.isCancelled {
                    var request = URLRequest(url: url)
                    if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
                    let socket = URLSession.shared.webSocketTask(with: request)
                    socket.resume()
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            delay = .seconds(1)
                            if let kind = Self.kind(of: message) { continuation.yield(kind) }
                        }
                    } catch {
                        Log.stream.info("event stream closed: \(error.localizedDescription)")
                    }
                    socket.cancel(with: .goingAway, reason: nil)
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(30))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func kind(of message: URLSessionWebSocketTask.Message) -> String? {
        let data: Data? = switch message {
        case .string(let s): s.data(using: .utf8)
        case .data(let d): d
        @unknown default: nil
        }
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["kind"] as? String
    }
}
