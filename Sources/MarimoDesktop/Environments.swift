import SwiftUI
import AppKit
import MarimoCore

/// Environment management on the app model: assignment, creation, linking, removal.
extension AppModel {
    func saveRegistry() { registryStore.save(registry) }

    func sessions(using env: PythonEnvironmentInfo) -> [NotebookSession] { sessions.filter { $0.environment.id == env.id } }

    /// Picker action: remember the choice for this file and restart the notebook in the new environment.
    func assign(_ env: PythonEnvironmentInfo, to session: NotebookSession?) {
        guard let session, session.environment.id != env.id else { return }
        registry.assign(session.file, to: env.id)
        saveRegistry()
        session.switchEnvironment(to: env, registry: pidRegistry)
    }

    /// Package changes don't affect a running kernel, so flag it and let the user choose when to restart.
    func packagesChanged(in env: PythonEnvironmentInfo) {
        sessions(using: env).forEach { $0.needsRestart = true }
    }

    func createEnvironment(name: String, copyFrom source: PythonEnvironmentInfo?,
                           progress: @escaping @Sendable (String, String) -> Void) async throws {
        try registry.validate(name: name)
        var specs: [String] = []
        if let source {
            let list = try await PackageManager(environment: source, tooling: environment.locateTooling()).list()
            specs = list.filter { $0.isRemovable }.map { "\($0.name)==\($0.version)" }
        }
        let root = try await environment.createManaged(name: name, packages: specs, progress: progress)
        do { try registry.add(name: name, kind: .managed, path: root.path) }
        catch { try? environment.deleteManaged(.init(name: name, kind: .managed, path: root.path)); throw error }
        saveRegistry()
    }

    /// Links an existing venv/conda folder after checking it has a runnable Python.
    /// Returns nil if the user declined to install Marimo into it.
    @discardableResult
    func linkEnvironment(at folder: URL) async throws -> PythonEnvironmentInfo? {
        var name = folder.lastPathComponent
        if (try? registry.validate(name: name)) == nil { name = EnvironmentRegistry.slug(name) }
        var candidate = name, n = 2
        while (try? registry.validate(name: candidate)) == nil, n < 50 { candidate = "\(name)-\(n)"; n += 1 }
        let probe = PythonEnvironmentInfo(name: candidate, kind: .linked, path: folder.standardizedFileURL.path)
        switch await environment.inspect(probe) {
        case .invalid(let reason): throw EnvironmentError.notAnEnvironment(reason)
        case .noMarimo:
            let alert = NSAlert()
            alert.messageText = "Install Marimo into “\(folder.lastPathComponent)”?"
            alert.informativeText = "Marimo isn't installed in this environment. It will be installed with pip alongside your existing packages."
            alert.addButton(withTitle: "Install Marimo"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            try await environment.installPackages(["marimo"], into: probe, upgrade: false, log: LogBuffer(), progress: { _, _ in })
        case .ready: break
        }
        let info = try registry.add(name: candidate, kind: .linked, path: probe.path)
        saveRegistry()
        return info
    }

    func removeEnvironment(_ env: PythonEnvironmentInfo) throws {
        guard sessions(using: env).isEmpty else { throw EnvInUse(name: env.name) }
        try registry.remove(env.id)
        // Only managed environments are deleted; a linked one is merely unlinked.
        if env.kind == .managed { try environment.deleteManaged(env) }
        saveRegistry()
    }

    func renameEnvironment(_ env: PythonEnvironmentInfo, to name: String) throws {
        try registry.rename(env.id, to: name)
        saveRegistry()
        for s in sessions(using: env) { if let updated = registry.environment(id: env.id) { s.refreshEnvironmentInfo(updated) } }
    }

    func setDefaultEnvironment(_ env: PythonEnvironmentInfo) throws { try registry.setDefault(env.id); saveRegistry() }
}

struct EnvInUse: LocalizedError {
    let name: String
    var errorDescription: String? { "“\(name)” is used by an open notebook. Close those tabs or switch their environment first." }
}
