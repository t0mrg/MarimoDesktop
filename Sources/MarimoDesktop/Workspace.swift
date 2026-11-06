import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation
import MarimoCore

/// Tab management and file operations. Extends AppModel's responsibilities without bloating it.
extension AppModel {
    var selectedSession: NotebookSession? { sessions.first { $0.id == selectedID } }
    var notebookFiles: NotebookFiles { NotebookFiles(untitledDirectory: paths.untitledDirectory) }
    private var store: SessionStore { SessionStore(url: paths.sessionFile) }

    func restoreSession() {
        let state = store.load()
        for path in state.files { _ = open(URL(filePath: path), remember: false) }
        if let sel = state.selected, let s = sessions.first(where: { $0.file.path == sel }) { selectedID = s.id }
        persist()
    }

    func persist() {
        store.save(.init(files: sessions.map(\.file.path), selected: selectedSession?.file.path))
    }

    @discardableResult
    func open(_ url: URL, remember: Bool = true) -> NotebookSession? {
        let url = url.standardizedFileURL
        guard isReady else { return nil }
        if let existing = sessions.first(where: { $0.file == url }) { selectedID = existing.id; return existing }
        let session = NotebookSession(file: url, environment: registry.environment(for: url))
        sessions.append(session)
        selectedID = session.id
        session.start(registry: pidRegistry)
        if remember { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        persist()
        return session
    }

    func newNotebook() {
        guard isReady else { return }
        do { open(try notebookFiles.createUntitled(), remember: false) }
        catch { present(error, title: "Couldn't create notebook") }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pythonScript]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose Marimo notebooks (.py) to open"
        if panel.runModal() == .OK { panel.urls.forEach { open($0) } }
    }

    func saveSelected() async { await selectedSession?.requestSave() }

    func saveSelectedAs() async {
        guard let session = selectedSession else { return }
        await session.requestSave()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pythonScript]
        panel.nameFieldStringValue = session.file.lastPathComponent
        panel.directoryURL = notebookFiles.isUntitled(session.file)
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            : session.file.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            let dest = try notebookFiles.saveAs(source: session.file, destination: target, overwrite: true) // panel already confirmed overwrite
            registry.assign(dest, to: session.environment.id); saveRegistry()   // keep the environment across Save As
            session.switchFile(to: dest, registry: pidRegistry)
            NSDocumentController.shared.noteNewRecentDocumentURL(dest)
            persist()
        } catch { present(error, title: "Save As failed") }
    }

    /// Closes a tab. Untitled notebooks with content prompt first, since they have no real home yet.
    func close(_ session: NotebookSession) async {
        if notebookFiles.isUntitled(session.file) {
            await session.requestSave()
            if notebookFiles.hasContent(session.file) {
                let alert = NSAlert()
                alert.messageText = "Save “\(session.title)” before closing?"
                alert.informativeText = "This notebook hasn't been saved to a location yet."
                alert.addButton(withTitle: "Save As…")
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    selectedID = session.id
                    await saveSelectedAs()
                    if notebookFiles.isUntitled(session.file) { return }   // user cancelled the panel
                    return                                                  // tab was re-pointed; keep it open
                case .alertSecondButtonReturn: try? FileManager.default.removeItem(at: session.file)
                default: return
                }
            } else { try? FileManager.default.removeItem(at: session.file) }
        } else {
            await session.requestSave()
        }
        session.stop()
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions.remove(at: i)
            if selectedID == session.id { selectedID = sessions.indices.contains(i) ? sessions[i].id : sessions.last?.id }
        }
        persist()
    }

    func selectNext(_ delta: Int) {
        guard !sessions.isEmpty, let i = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = sessions[(i + delta + sessions.count) % sessions.count].id
    }

    func stopAll() { sessions.forEach { $0.stopAndWait() } }

    func present(_ error: Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
