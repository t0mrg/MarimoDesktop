import Testing
import Foundation
@testable import MarimoCore

/// Records invocations instead of running anything.
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable { let exe: String; let args: [String] }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var statuses: [Int32] = []
    var lines: [String] = []

    private func record(_ call: Call) -> Int {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call); return _calls.count - 1
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?,
             workingDirectory: URL?, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let index = record(Call(exe: executable.path, args: arguments))
        lines.forEach(onLine)
        return index < statuses.count ? statuses[index] : 0
    }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mdtest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func serverArgumentsAreLoopbackHeadless() {
    let args = MarimoServer.arguments(file: URL(filePath: "/tmp/a b.py"), port: 4321)
    #expect(args.starts(with: ["edit", "--headless", "--no-token"]))
    #expect(args.contains("127.0.0.1") && args.contains("4321"))
    #expect(args.last == "/tmp/a b.py")
}

@Test func parsesServerToken() {
    let html = #"<script>window.__MARIMO_MOUNT_CONFIG__ = {"serverToken": "abc-123_X", "x": 1}</script>"#
    #expect(MarimoServer.parseToken(html: html) == "abc-123_X")
    #expect(MarimoServer.parseToken(html: "<html></html>") == nil)
}

@Test func portAllocatorReturnsUsablePorts() throws {
    let a = try PortAllocator.freePort()
    #expect(a > 1024 && a < 65536)
}

@Test func pidRegistryRoundTripAndReap() {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let reg = PIDRegistry(url: dir.appending(path: "p.json"))
    reg.add(10); reg.add(11); reg.add(10); reg.remove(11); reg.add(12)
    #expect(reg.load() == [10, 12])
    nonisolated(unsafe) var killed: [Int32] = []
    let reaped = reg.reap(isMarimo: { $0 == 12 }, terminate: { killed.append($0) })
    #expect(reaped == [12] && killed == [12])
    #expect(reg.load().isEmpty)
}

@Test func installUsesUVWhenAvailable() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appending(path: "bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let uv = bin.appending(path: "uv"); FileManager.default.createFile(atPath: uv.path, contents: Data(), attributes: [.posixPermissions: 0o755])
    let runner = FakeRunner()
    let env = PythonEnvironment(paths: AppPaths(root: dir.appending(path: "app")), runner: runner, searchDirectories: [bin.path])
    try await env.install(progress: { _, _ in })
    #expect(runner.calls.count == 2)
    #expect(runner.calls[0].args.first == "venv")
    #expect(runner.calls[1].args.prefix(2) == ["pip", "install"] && runner.calls[1].args.last == "marimo")
}

@Test func installFailsWithoutTooling() async {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let env = PythonEnvironment(paths: AppPaths(root: dir), runner: FakeRunner(), searchDirectories: [dir.path])
    // No uv/python in the search dir; the /usr/bin stub is only added when CLT exist, so allow either outcome.
    if !env.locateTooling().isUsable {
        await #expect(throws: EnvironmentError.noPythonOrUV) { try await env.install(progress: { _, _ in }) }
    }
}

@Test func installReportsFailureTail() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appending(path: "bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin.appending(path: "uv").path, contents: Data(), attributes: [.posixPermissions: 0o755])
    let runner = FakeRunner(); runner.statuses = [1]; runner.lines = ["boom"]
    let env = PythonEnvironment(paths: AppPaths(root: dir.appending(path: "app")), runner: runner, searchDirectories: [bin.path])
    await #expect(throws: EnvironmentError.commandFailed(step: "Creating environment", status: 1, tail: "boom")) {
        try await env.install(progress: { _, _ in })
    }
}

/// Real end-to-end check; run with MARIMO_INTEGRATION=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MARIMO_INTEGRATION"] == "1"))
func realEnvironmentAndServer() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let paths = AppPaths(root: dir)
    let env = PythonEnvironment(paths: paths)
    try await env.install(progress: { _, _ in })
    guard case .ready = await env.currentStatus() else { Issue.record("not ready"); return }
    let nb = dir.appending(path: "t.py")
    let server = try await MarimoServer.launch(file: nb, paths: paths, registry: PIDRegistry(url: paths.pidFile))
    #expect(await server.fetchServerToken() != nil)
    server.terminateAndWait()
    #expect(!server.isRunning)
}
