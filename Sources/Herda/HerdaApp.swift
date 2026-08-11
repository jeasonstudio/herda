import SwiftUI

@main
struct HerdaApp: App {
    var body: some Scene {
        // No titlebar: the theme's own background runs to the top edge, and the
        // sidebar keeps the top-left clear for the traffic lights.
        WindowGroup("Herda") {
            ContentView()
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
    }
}
