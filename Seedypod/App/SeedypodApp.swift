import SwiftUI

@main
struct SeedypodApp: App {
    @State private var connection = Connection()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .foregroundStyle(Theme.text1)
                .tint(Theme.podOK)
        }
    }
}

/// Connect first; once there's a unit (or the demo), Home.
struct RootView: View {
    @Environment(Connection.self) private var connection

    var body: some View {
        Group {
            if let api = connection.api {
                HomeView(store: HomeStore(api: api, stream: stream(for: connection.target)))
                    // A new unit or key is a new store, stream and all.
                    .id("\(String(describing: connection.target))|\(connection.apiKey)")
            } else {
                ConnectView()
            }
        }
        .background(Theme.app.ignoresSafeArea())
    }

    private func stream(for target: Connection.Target?) -> EventStream? {
        guard case .unit(let url)? = target else { return nil }
        return EventStream(baseURL: url, apiKey: connection.apiKey)
    }
}
