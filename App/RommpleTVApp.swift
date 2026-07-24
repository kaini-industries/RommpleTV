import SwiftUI
import RommpleTVKit

@main
struct RommpleTVApp: App {
    @State private var config = ConfigStore.load()
    var body: some Scene {
        WindowGroup {
            Group {
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
    }
}
