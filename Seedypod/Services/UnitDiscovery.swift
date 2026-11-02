import Foundation
import Network
import Observation

/// Finds seedypod units on the LAN. Core advertises `_seedypod._tcp` on its HTTP
/// port with TXT `id` (unit), `v` (core version) and `auth` (`1` when an API key is
/// set), per seedypod/core ADR-0017. The browse pattern follows sleepypod/ios's
/// `PodDiscovery`; a found service is resolved to a host and port by connecting to it.
@MainActor
@Observable
final class UnitDiscovery {
    struct Unit: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let txt: TXT
        fileprivate let endpoint: NWEndpoint
    }

    struct TXT: Equatable, Sendable {
        var unitID: String?
        var version: String?
        var needsKey = false

        init(_ entries: [String: String]) {
            unitID = entries["id"]
            version = entries["v"]
            needsKey = entries["auth"] == "1"
        }
    }

    enum State: Equatable {
        case idle, searching, denied, failed
    }

    private(set) var units: [Unit] = []
    private(set) var state: State = .idle
    private var browser: NWBrowser?

    func start() {
        stop()
        state = .searching
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_seedypod._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in self?.handle(s) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.unit(from:)).sorted { $0.name < $1.name }
            Task { @MainActor in self?.units = found }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        if state == .searching { state = .idle }
    }

    private func handle(_ s: NWBrowser.State) {
        switch s {
        case .waiting(let error), .failed(let error):
            // kDNSServiceErr_PolicyDenied: Local Network access is off for this app.
            if error == .dns(-65570) { state = .denied } else if case .failed = s { state = .failed }
        case .ready: state = .searching
        default: break
        }
    }

    nonisolated private static func unit(from result: NWBrowser.Result) -> Unit? {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
        var entries: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            for (key, entry) in record.dictionary { entries[key] = entry }
        }
        return Unit(id: "\(name).\(type)\(domain)", name: name, txt: TXT(entries), endpoint: result.endpoint)
    }

    /// The base URL for a found unit: connects once to learn the address and port the service resolved to.
    func resolve(_ unit: Unit) async -> URL? {
        let connection = NWConnection(to: unit.endpoint, using: .tcp)
        let url: URL? = await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var resolved: URL?
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        resolved = Self.url(host: host, port: port.rawValue)
                    }
                    if once.fire() { continuation.resume(returning: resolved) }
                    connection.cancel()
                case .failed, .cancelled:
                    if once.fire() { continuation.resume(returning: nil) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if once.fire() { continuation.resume(returning: nil) }
                connection.cancel()
            }
        }
        return url
    }

    nonisolated static func url(host: NWEndpoint.Host, port: UInt16) -> URL? {
        var text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a):
            // Drop the scope ("%en0"): URL can't carry it, and the LAN address works without it.
            text = "[\(String(describing: a).split(separator: "%").first ?? "")]"
        case .name(let n, _): text = n
        @unknown default: return nil
        }
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        return URL(string: "http://\(text):\(port)")
    }
}

/// Resumes a continuation exactly once across racing callbacks.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
