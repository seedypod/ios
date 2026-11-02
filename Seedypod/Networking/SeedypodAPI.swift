import Foundation

/// What the app asks of a seedypod unit. `CoreClient` talks to a real core over tRPC;
/// `DemoClient` is an in-memory tower for trying the app without one.
protocol SeedypodAPI: Sendable {
    func systemInfo() async throws -> SystemInfo
    func home() async throws -> HomeSnapshot

    func setLight(on: Bool?, level: Double?) async throws -> ActuatorState
    /// Ends a manual hold and hands the light back to Autopilot or the schedule.
    func resumeLight() async throws -> LightOwner
    func runPump(seconds: Int) async throws -> ActuatorState
    func stopPump() async throws -> ActuatorState

    func markHarvested(slot: Int) async throws -> Pod
    func setPodStatus(slot: Int, status: PodStatus) async throws -> Pod
    func acknowledgeAlert(id: Int) async throws
}

enum APIError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case unauthorized
    case invalidResponse(statusCode: Int)
    case decodingFailed(String)
    case network(String)
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "That address isn't a valid URL."
        case .unauthorized: "The unit wants an API key. Add it in Settings."
        case .invalidResponse(let code): "The unit answered with HTTP \(code)."
        case .decodingFailed(let detail): "The unit's answer didn't parse: \(detail)"
        case .network(let detail): "Couldn't reach the unit: \(detail)"
        case .server(let message): message
        }
    }
}
