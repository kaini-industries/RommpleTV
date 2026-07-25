import SwiftUI
import RommpleTVKit

@main
struct RommpleTVApp: App {
    @State private var config: RommConfig?

    init() {
        #if DEBUG
        if UITestScenario.selected(from: CommandLine.arguments) != nil {
            // The fixture route reads no stored configuration and seeds none, so
            // a UI-test process has no server address and no token in it at all.
            _config = State(initialValue: nil)
            return
        }
        #endif
        _config = State(initialValue: ConfigStore.loadOrSeedFromBakedDefaults())
    }

    var body: some Scene {
        WindowGroup { root }
    }

    /// The fixture route exists only in a debug build and only when the process
    /// was launched with an explicit `-ui-test-scenario <name>` argument. A
    /// release build has no branch here at all.
    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if let scenario = UITestScenario.selected(from: CommandLine.arguments) {
            UITestScenarioView(scenario: scenario)
        } else {
            library
        }
        #else
        library
        #endif
    }

    @ViewBuilder
    private var library: some View {
        if let config {
            PlatformListView(client: RommClient(config: config), onReset: {
                ConfigStore.reset()
                self.config = nil
            })
        } else {
            SetupView { self.config = ConfigStore.load() }
        }
    }
}
