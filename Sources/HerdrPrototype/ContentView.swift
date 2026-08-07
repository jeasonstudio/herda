import HerdrKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("herdr protocol v\(HerdrKit.protocolVersion)")
            .font(.system(.body, design: .monospaced))
    }
}
