import SwiftUI
import MarimoCore

@main
struct MarimoDesktopApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Marimo Desktop") {
            Group {
                if model.isReady {
                    Text("Marimo ready").font(.title)   // replaced by the tab UI in Stage 3
                } else {
                    SetupView(model: model)
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .task { await model.bootstrap() }
        }
    }
}
