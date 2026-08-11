import SwiftUI

@main
struct HerdrPrototypeApp: App {
    var body: some Scene {
        // No titlebar: the theme's own background runs to the top edge, and the
        // sidebar keeps the top-left clear for the traffic lights.
        WindowGroup("Herdr") {
            ContentView()
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
    }
}
