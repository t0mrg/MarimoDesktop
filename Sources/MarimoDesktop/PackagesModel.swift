import SwiftUI
import Observation
import MarimoCore

/// State for Settings ▸ Environments: the selected environment, its packages and any running operation.
@Observable @MainActor
final class PackagesModel {
    let app: AppModel
    var selectedID: UUID
    var packages: [InstalledPackage] = []
    var health: [UUID: EnvironmentHealth] = [:]
    var filter = ""
    var installText = ""
    var selection: Set<String> = []
    var loading = false
    var busy = false
    var busyTitle = ""
    var log: [String] = []
    var errorText: String?

    init(app: AppModel) { self.app = app; selectedID = app.registry.defaultID }

    var selected: PythonEnvironmentInfo { app.registry.environment(id: selectedID) ?? app.registry.defaultEnvironment }

    var visiblePackages: [InstalledPackage] {
        filter.isEmpty ? packages : packages.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var manager: PackageManager { PackageManager(environment: selected, tooling: app.environment.locateTooling()) }

    func select(_ id: UUID) async {
        selectedID = id; selection = []; filter = ""; errorText = nil; log = []
        await reload()
    }

    func reload() async {
        let env = selected
        loading = true; defer { loading = false }
        health[env.id] = await app.environment.inspect(env)
        if case .invalid = health[env.id] { packages = []; return }
        do { packages = try await PackageManager(environment: env, tooling: app.environment.locateTooling()).list(); errorText = nil }
        catch { packages = []; errorText = error.localizedDescription }
    }

    func refreshAllHealth() async {
        for env in app.registry.environments { health[env.id] = await app.environment.inspect(env) }
    }

    /// Runs a package operation with live log output, then refreshes the list and flags affected notebooks.
    private func run(_ title: String, _ work: @escaping @Sendable (PackageManager, @escaping @Sendable (String) -> Void) async throws -> Void) async {
        guard !busy else { return }
        busy = true; busyTitle = title; log = []; errorText = nil
        let env = selected, mgr = manager
        do {
            try await work(mgr) { [weak self] line in Task { @MainActor in self?.log.append(line) } }
            app.packagesChanged(in: env)
        } catch { errorText = error.localizedDescription }
        busy = false
        await reload()
    }

    var parsedInstall: Result<[String], PackageError> {
        do { return .success(try PackageSpecs.parse(installText)) } catch let e as PackageError { return .failure(e) } catch { return .failure(.unreadableList) }
    }
    var canInstall: Bool { if case .success(let s) = parsedInstall { return !s.isEmpty && !busy }; return false }

    func install() async {
        let text = installText
        await run("Installing…") { mgr, log in try await mgr.install(text, onLine: log) }
        if errorText == nil { installText = "" }
    }

    func uninstall(_ ids: Set<String>) async {
        let names = packages.filter { ids.contains($0.id) && $0.isRemovable }.map(\.name)
        guard !names.isEmpty else { return }
        await run("Removing…") { mgr, log in try await mgr.uninstall(names, onLine: log) }
        selection = []
    }

    func installMarimo() async { await run("Installing Marimo…") { mgr, log in try await mgr.install("marimo", onLine: log) } }
}
