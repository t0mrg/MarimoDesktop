import Testing
import Foundation
@testable import MarimoCore

private let pipJSON = #"[{"name": "numpy", "version": "2.1.0"}, {"name": "Pandas", "version": "2.2.3"}, {"name": "marimo", "version": "0.25.2"}]"#

@Test func parsesPipAndUvListOutputWithNoise() throws {
    let noisy = "warning: something\n\(pipJSON)\n[notice] A new release of pip is available"
    let list = try PackageManager.parseList(noisy)
    #expect(list.map(\.name) == ["marimo", "numpy", "Pandas"])
    #expect(list.first { $0.id == "pandas" }?.version == "2.2.3")
    #expect(try PackageManager.parseList("[]").isEmpty)
    #expect(throws: PackageError.unreadableList) { try PackageManager.parseList("nothing here") }
}

@Test func marimoIsNotRemovable() {
    #expect(!InstalledPackage(name: "marimo", version: "1").isRemovable)
    #expect(InstalledPackage(name: "numpy", version: "1").isRemovable)
    #expect(!InstalledPackage(name: "numpy", version: "1", installer: .conda).isRemovable)
}

@Test func specParsingSplitsAndRejectsOptions() throws {
    #expect(try PackageSpecs.parse("pandas numpy") == ["pandas", "numpy"])
    #expect(try PackageSpecs.parse("pandas, numpy,altair") == ["pandas", "numpy", "altair"])
    #expect(try PackageSpecs.parse("numpy>=2,<3 scipy") == ["numpy>=2,<3", "scipy"])
    #expect(try PackageSpecs.parse("altair[all,extra]") == ["altair[all,extra]"])
    #expect(try PackageSpecs.parse("   ").isEmpty)
    #expect(throws: PackageError.invalidSpec("--index-url")) { try PackageSpecs.parse("pandas --index-url http://evil") }
    #expect(throws: PackageError.invalidSpec("-r")) { try PackageSpecs.parse("-r requirements.txt") }
    #expect(PackageSpecs.normalize("Scikit_Learn.X") == "scikit-learn-x")
}

private func makeManager(kind: PythonEnvironmentInfo.Kind, uv: Bool, runner: FakeRunner) -> PackageManager {
    let env = PythonEnvironmentInfo(name: "e", kind: kind, path: "/envs/e")
    return PackageManager(environment: env, tooling: Tooling(uv: uv ? URL(filePath: "/bin/uv") : nil, python: nil), runner: runner)
}

@Test func managedUsesUVWhenPresent() async throws {
    let runner = FakeRunner()
    let m = makeManager(kind: .managed, uv: true, runner: runner)
    try await m.install("pandas numpy")
    try await m.uninstall(["pandas"])
    #expect(runner.calls[0] == .init(exe: "/bin/uv", args: ["pip", "install", "--python", "/envs/e/bin/python", "pandas", "numpy"]))
    #expect(runner.calls[1] == .init(exe: "/bin/uv", args: ["pip", "uninstall", "--python", "/envs/e/bin/python", "pandas"]))
}

@Test func linkedPrefersPipAndPassesCleanArgs() async throws {
    let runner = FakeRunner()
    let m = makeManager(kind: .linked, uv: true, runner: runner)
    try await m.install("scikit-learn", upgrade: true)
    try await m.uninstall(["six"])
    #expect(runner.calls[0].exe == "/envs/e/bin/python")
    #expect(runner.calls[0].args == ["-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "scikit-learn"])
    #expect(runner.calls[1].args == ["-m", "pip", "uninstall", "-y", "six"])
}

@Test func linkedFallsBackToUVOnlyWhenPipIsMissing() async throws {
    let runner = FakeRunner(); runner.statuses = [1, 0]; runner.lines = ["/envs/e/bin/python: No module named pip"]
    let m = makeManager(kind: .linked, uv: true, runner: runner)
    try await m.install("six")
    #expect(runner.calls.count == 2 && runner.calls[1].exe == "/bin/uv")

    let rejecting = FakeRunner(); rejecting.statuses = [1, 0]; rejecting.lines = ["ERROR: No matching distribution"]
    let m2 = makeManager(kind: .linked, uv: true, runner: rejecting)
    await #expect(throws: PackageError.self) { try await m2.install("nonexistent-pkg") }
    #expect(rejecting.calls.count == 1)           // a real failure must not be retried with another tool
}

@Test func uninstallingMarimoIsRefusedWithoutRunningAnything() async {
    let runner = FakeRunner()
    let m = makeManager(kind: .managed, uv: true, runner: runner)
    await #expect(throws: PackageError.protectedPackage("Marimo")) { try await m.uninstall(["Marimo"]) }
    #expect(runner.calls.isEmpty)
}

@Test func installFailureCarriesLogTail() async {
    let runner = FakeRunner(); runner.statuses = [2]; runner.lines = ["boom"]
    let m = makeManager(kind: .managed, uv: true, runner: runner)
    await #expect(throws: PackageError.failed(step: "Installing packages", status: 2, tail: "boom")) { try await m.install("x") }
}

@Test func emptyInputRunsNothing() async throws {
    let runner = FakeRunner()
    try await makeManager(kind: .managed, uv: true, runner: runner).install("   ")
    #expect(runner.calls.isEmpty)
}

@Test func condaMetaNamesAreParsed() throws {
    let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
    let meta = root.appending(path: "conda-meta"); try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
    for f in ["numpy-2.1.0-py312h1234_0.json", "scikit-learn-1.5.0-py312_1.json", "history"] {
        FileManager.default.createFile(atPath: meta.appending(path: f).path, contents: Data())
    }
    #expect(CondaMeta.installedNames(root: root) == ["numpy", "scikit-learn"])
    #expect(PythonEnvironmentInfo(name: "c", kind: .linked, path: root.path).isConda)
}

/// Real lifecycle: create environment, install, list, uninstall. Needs network; run with MARIMO_INTEGRATION=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MARIMO_INTEGRATION"] == "1"))
func realPackageLifecycle() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let paths = AppPaths(root: dir)
    let py = PythonEnvironment(paths: paths)
    let root = try await py.createManaged(name: "it", progress: { _, _ in })
    let info = PythonEnvironmentInfo(name: "it", kind: .managed, path: root.path)
    guard case .ready = await py.inspect(info) else { Issue.record("env not ready"); return }
    let pm = PackageManager(environment: info, tooling: py.locateTooling())
    try await pm.install("six")
    let withSix = try await pm.list()
    #expect(withSix.contains { $0.id == "six" && !$0.version.isEmpty } && withSix.contains { $0.isMarimo })
    try await pm.uninstall(["six"])
    #expect(try await pm.list().contains { $0.id == "six" } == false)
    await #expect(throws: PackageError.self) { try await pm.uninstall(["marimo"]) }
}
