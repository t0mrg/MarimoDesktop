import Testing
import Foundation
@testable import MarimoCore

private func paths() -> AppPaths { AppPaths(root: URL(filePath: "/tmp/md-registry-test")) }

@Test func registryStartsWithDefaultEnvironment() {
    let r = EnvironmentRegistry(paths: paths())
    #expect(r.environments.count == 1 && r.defaultEnvironment.isDefault)
    #expect(r.defaultEnvironment.path == paths().venv.path)
    #expect(r.environment(for: URL(filePath: "/x/a.py")).id == r.defaultID)
}

@Test func addValidatesNames() throws {
    var r = EnvironmentRegistry(paths: paths())
    try r.add(name: "Data Science", kind: .managed, path: "/e/ds")
    #expect(throws: EnvironmentRegistryError.duplicateName("data science")) { try r.add(name: "data science", kind: .managed, path: "/e/x") }
    #expect(throws: EnvironmentRegistryError.invalidName) { try r.add(name: "  ", kind: .managed, path: "/e/x") }
    #expect(throws: EnvironmentRegistryError.invalidName) { try r.add(name: "bad/name", kind: .managed, path: "/e/x") }
    #expect(throws: EnvironmentRegistryError.invalidName) { try r.add(name: String(repeating: "a", count: 41), kind: .managed, path: "/e/x") }
    #expect(r.environments.count == 2)
}

@Test func assignmentsFallBackAndArePurgedOnRemove() throws {
    var r = EnvironmentRegistry(paths: paths())
    let ds = try r.add(name: "ds", kind: .linked, path: "/e/ds")
    let file = URL(filePath: "/work/nb.py")
    r.assign(file, to: ds.id)
    #expect(r.environment(for: file).id == ds.id)
    r.assign(file, to: UUID())                       // unknown id is ignored
    #expect(r.environment(for: file).id == ds.id)
    try r.remove(ds.id)
    #expect(r.environment(for: file).id == r.defaultID && r.assignments.isEmpty)
}

@Test func defaultCannotBeRemovedUntilAnotherIsDefault() throws {
    var r = EnvironmentRegistry(paths: paths())
    #expect(throws: EnvironmentRegistryError.cannotRemoveDefault) { try r.remove(PythonEnvironmentInfo.defaultID) }
    let e = try r.add(name: "e", kind: .managed, path: "/e/e")
    try r.setDefault(e.id)
    #expect(throws: EnvironmentRegistryError.cannotRemoveDefault) { try r.remove(e.id) }   // now the default
    #expect(throws: EnvironmentRegistryError.cannotRemoveDefault) { try r.remove(PythonEnvironmentInfo.defaultID) } // built-in stays
    #expect(r.defaultEnvironment.id == e.id)
}

@Test func renameKeepsUniqueness() throws {
    var r = EnvironmentRegistry(paths: paths())
    let a = try r.add(name: "a", kind: .managed, path: "/e/a")
    try r.add(name: "b", kind: .managed, path: "/e/b")
    try r.rename(a.id, to: "A")                      // same entry, case change is fine
    #expect(throws: EnvironmentRegistryError.duplicateName("b")) { try r.rename(a.id, to: "b") }
    #expect(r.environment(id: a.id)?.name == "A")
}

@Test func storeRoundTripsAndRepairsMissingDefault() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let p = AppPaths(root: dir)
    let store = EnvironmentRegistryStore(paths: p)
    #expect(store.load() == EnvironmentRegistry(paths: p))        // nothing saved yet
    var r = store.load()
    let e = try r.add(name: "x", kind: .linked, path: "/e/x")
    r.assign(URL(filePath: "/w/a.py"), to: e.id)
    store.save(r)
    #expect(store.load() == r)
    try "{\"environments\":[],\"defaultID\":\"\(UUID())\",\"assignments\":{}}".write(to: p.registryFile, atomically: true, encoding: .utf8)
    #expect(store.load().defaultEnvironment.isDefault)            // corrupt/incomplete file is repaired
}

@Test func slugsAreDirectorySafe() {
    #expect(EnvironmentRegistry.slug("Data Science!") == "data-science")
    #expect(EnvironmentRegistry.slug("../etc") == "etc")
    #expect(EnvironmentRegistry.slug("***") == "env")
}

@Test func createManagedBuildsVenvThenInstallsMarimoAndExtras() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appending(path: "bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin.appending(path: "uv").path, contents: Data(), attributes: [.posixPermissions: 0o755])
    let runner = FakeRunner()
    let env = PythonEnvironment(paths: AppPaths(root: dir.appending(path: "app")), runner: runner, searchDirectories: [bin.path])
    let root = try await env.createManaged(name: "My Env", packages: ["pandas"], progress: { _, _ in })
    #expect(root.lastPathComponent == "my-env" && root.deletingLastPathComponent().lastPathComponent == "envs")
    #expect(runner.calls[0].args == ["venv", root.path])
    #expect(runner.calls[1].args.suffix(2) == ["marimo", "pandas"] && runner.calls[1].args.contains(root.appending(path: "bin/python").path))
}

@Test func createManagedCleansUpOnFailure() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appending(path: "bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin.appending(path: "uv").path, contents: Data(), attributes: [.posixPermissions: 0o755])
    let runner = FakeRunner(); runner.statuses = [0, 1]    // venv ok, install fails
    let paths = AppPaths(root: dir.appending(path: "app"))
    let env = PythonEnvironment(paths: paths, runner: runner, searchDirectories: [bin.path])
    await #expect(throws: EnvironmentError.self) { _ = try await env.createManaged(name: "bad", progress: { _, _ in }) }
    #expect(!FileManager.default.fileExists(atPath: paths.envsDirectory.appending(path: "bad").path))
}

@Test func inspectReportsMissingPython() async {
    let env = PythonEnvironment(paths: AppPaths(root: tempDir()), runner: FakeRunner(), searchDirectories: [])
    let health = await env.inspect(PythonEnvironmentInfo(name: "n", kind: .linked, path: "/nonexistent/env"))
    if case .invalid = health {} else { Issue.record("expected invalid, got \(health)") }
}

@Test func linkingSamePathTwiceIsRejected() throws {
    var r = EnvironmentRegistry(paths: paths())
    try r.add(name: "one", kind: .linked, path: "/e/one")
    #expect(throws: EnvironmentRegistryError.alreadyLinked("one")) { try r.add(name: "two", kind: .linked, path: "/e/one") }
}

@Test func deleteManagedOnlyTouchesOwnEnvsFolder() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let p = AppPaths(root: dir.appending(path: "app")); try p.createDirectories()
    let py = PythonEnvironment(paths: p, runner: FakeRunner(), searchDirectories: [])
    let inside = p.envsDirectory.appending(path: "x"); try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try py.deleteManaged(.init(name: "x", kind: .managed, path: inside.path))
    #expect(!FileManager.default.fileExists(atPath: inside.path))
    let outside = dir.appending(path: "user-env"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    #expect(throws: EnvironmentError.self) { try py.deleteManaged(.init(name: "u", kind: .managed, path: outside.path)) }
    #expect(throws: EnvironmentError.self) { try py.deleteManaged(.init(name: "u", kind: .linked, path: inside.path)) }
    #expect(throws: EnvironmentError.self) { try py.deleteManaged(py.defaultInfo) }
    #expect(FileManager.default.fileExists(atPath: outside.path))
}
