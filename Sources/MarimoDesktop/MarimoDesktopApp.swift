import SwiftUI
import AppKit
import MarimoCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var model: AppModel?
    /// Files delivered by Finder before the model exists (cold launch via "Open With").
    nonisolated(unsafe) static var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let model = Self.model, model.isReady { urls.forEach { model.open($0) } } else { Self.pendingURLs += urls }
        }
    }
    /// Stops AppKit synthesising a File ▸ New on launch; we show a welcome screen instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.stopAll() }
    }
}

@main
struct MarimoDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Marimo Desktop", id: "main") {
            Group {
                if model.isReady { MainView(model: model) } else { SetupView(model: model) }
            }
            .frame(minWidth: 900, minHeight: 600)
            .task {
                AppDelegate.model = model
                await model.bootstrap()
                AppDelegate.pendingURLs.forEach { model.open($0) }
                AppDelegate.pendingURLs = []
            }
        }
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Notebook") { model.newNotebook() }.keyboardShortcut("n")
            Button("Open…") { model.showOpenPanel() }.keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { model.open(url) }
                }
                Divider()
                Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { if let s = model.selectedSession { Task { await model.close(s) } } }
                .keyboardShortcut("w").disabled(model.selectedSession == nil)
            Divider()
            Button("Save") { Task { await model.saveSelected() } }
                .keyboardShortcut("s").disabled(model.selectedSession == nil)
            Button("Save As…") { Task { await model.saveSelectedAs() } }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.selectedSession == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show Next Tab") { model.selectNext(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { model.selectNext(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
