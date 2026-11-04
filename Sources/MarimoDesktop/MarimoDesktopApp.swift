import SwiftUI
import MarimoCore

@main
struct MarimoDesktopApp: App {
    var body: some Scene {
        WindowGroup("Marimo Desktop") {
            Text("Marimo Desktop \(MarimoCoreInfo.version)")
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
