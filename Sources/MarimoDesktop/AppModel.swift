import SwiftUI
import Observation
import MarimoCore

/// Root application state. Views read it; only it mutates environment state.
@Observable @MainActor
final class AppModel {
    var environmentStatus: EnvironmentStatus = .unknown
    var setupLog: [String] = []
    var setupStep = ""
    var sessions: [NotebookSession] = []
    var selectedID: UUID?

    let paths: AppPaths
    let environment: PythonEnvironment
    let pidRegistry: PIDRegistry
    let registryStore: EnvironmentRegistryStore
    var registry: EnvironmentRegistry

    init(paths: AppPaths = .standard) {
        self.paths = paths
        self.environment = PythonEnvironment(paths: paths)
        self.pidRegistry = PIDRegistry(url: paths.pidFile)
        self.registryStore = EnvironmentRegistryStore(paths: paths)
        self.registry = EnvironmentRegistryStore(paths: paths).load()
    }

    var isReady: Bool { if case .ready = environmentStatus { return true }; return false }

    /// Reaps orphans from a previous crash, then verifies (or builds) the environment.
    func bootstrap() async {
        try? paths.createDirectories()
        pidRegistry.reap(isMarimo: PIDRegistry.systemIsMarimo, terminate: PIDRegistry.systemTerminate)
        environmentStatus = await environment.currentStatus()
        if environmentStatus == .missing { await install() }
        if isReady && sessions.isEmpty { restoreSession() }
    }

    func install(upgrade: Bool = false, extraPackages: [String] = []) async {
        environmentStatus = .installing(step: "Preparing…")
        setupLog = []
        do {
            try await environment.install(extraPackages: extraPackages, upgrade: upgrade) { [weak self] step, line in
                Task { @MainActor in
                    guard let self else { return }
                    if !step.isEmpty { self.setupStep = step; self.environmentStatus = .installing(step: step) }
                    if !line.isEmpty { self.setupLog.append(line); if self.setupLog.count > 300 { self.setupLog.removeFirst(100) } }
                }
            }
            environmentStatus = await environment.currentStatus()
            if environmentStatus == .missing { environmentStatus = .failed("Marimo could not be imported after install.") }
            else if sessions.isEmpty { restoreSession() }
        } catch {
            environmentStatus = .failed(error.localizedDescription)
        }
    }

    /// Deletes the venv and builds it again. Open notebooks are restarted afterwards.
    func rebuildEnvironment() async {
        let open = sessions.filter { $0.environment.isDefault }
        open.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: paths.venv)
        await install()
        if isReady { open.filter { $0.environment.isDefault }.forEach { $0.start(registry: pidRegistry) } }
    }
}
