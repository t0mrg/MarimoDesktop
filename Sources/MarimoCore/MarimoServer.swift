import Foundation

public enum ServerError: LocalizedError {
    case exitedEarly(status: Int32, tail: String)
    case timedOut(tail: String)

    public var errorDescription: String? {
        switch self {
        case let .exitedEarly(status, tail): return "Marimo exited during startup (status \(status)).\n\(tail)"
        case let .timedOut(tail): return "Marimo did not become ready in time.\n\(tail)"
        }
    }
}

/// One `marimo edit` process serving a single notebook on a loopback port.
public final class MarimoServer: @unchecked Sendable {
    public let file: URL
    public let port: Int
    public let log = LogBuffer()
    private let process: Process
    private let registry: PIDRegistry?
    private let lock = NSLock()
    private var exitHandlers: [@Sendable (Int32) -> Void] = []
    private var exitStatus: Int32?

    public var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Command-line arguments for `marimo edit`. Exposed for testing.
    public static func arguments(file: URL, port: Int) -> [String] {
        ["edit", "--headless", "--no-token", "--host", "127.0.0.1", "--port", "\(port)",
         "--skip-update-check", "--no-sandbox", "--watch", file.path]
    }

    private init(file: URL, port: Int, process: Process, registry: PIDRegistry?) {
        self.file = file; self.port = port; self.process = process; self.registry = registry
    }

    /// Spawns marimo and waits until `/health` answers. Retries on port races.
    public static func launch(file: URL, paths: AppPaths, registry: PIDRegistry?,
                              readyTimeout: TimeInterval = 45) async throws -> MarimoServer {
        var lastError: Error = ServerError.timedOut(tail: "")
        for _ in 0..<3 {
            let port = try PortAllocator.freePort()
            let server = try start(file: file, port: port, paths: paths, registry: registry)
            do {
                try await server.waitUntilReady(timeout: readyTimeout)
                return server
            } catch {
                server.terminateAndWait()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }  // tab closed / app quitting mid-start
                lastError = error
                if case ServerError.timedOut = error { break }
            }
        }
        throw lastError
    }

    private static func start(file: URL, port: Int, paths: AppPaths, registry: PIDRegistry?) throws -> MarimoServer {
        let process = Process()
        process.executableURL = paths.marimoExecutable
        process.arguments = arguments(file: file, port: port)
        process.currentDirectoryURL = file.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        for key in ["VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH", "CONDA_PREFIX"] { env[key] = nil }
        env["PATH"] = paths.venv.appending(path: "bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let server = MarimoServer(file: file, port: port, process: process, registry: registry)
        let assembler = LineAssembler { [log = server.log] in log.append($0) }
        pipe.fileHandleForReading.readabilityHandler = { assembler.feed($0.availableData) }
        process.terminationHandler = { [weak server] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            assembler.feed(pipe.fileHandleForReading.readDataToEndOfFile())
            assembler.flush()
            server?.didExit(proc.terminationStatus)
        }
        try process.run()
        registry?.add(process.processIdentifier)
        return server
    }

    private func didExit(_ status: Int32) {
        registry?.remove(process.processIdentifier)
        lock.lock(); exitStatus = status; let handlers = exitHandlers; exitHandlers = []; lock.unlock()
        handlers.forEach { $0(status) }
    }

    /// Registers a callback for process exit (called immediately if already exited).
    public func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        if let status = exitStatus { lock.unlock(); handler(status); return }
        exitHandlers.append(handler); lock.unlock()
    }

    private var currentExitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return exitStatus }

    private func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let healthURL = url.appending(path: "health")
        while Date() < deadline {
            if let status = currentExitStatus { throw ServerError.exitedEarly(status: status, tail: log.tail()) }
            if let (_, response) = try? await URLSession.shared.data(from: healthURL),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ServerError.timedOut(tail: log.tail())
    }

    /// Marimo embeds a per-server API token in the index page; the API calls we make need it.
    public func fetchServerToken() async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return MarimoServer.parseToken(html: html)
    }

    public static func parseToken(html: String) -> String? {
        guard let r = html.range(of: #"serverToken"\s*:\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let match = String(html[r])
        return match.split(separator: "\"").dropFirst().last.map(String.init)
    }

    /// Graceful stop: SIGTERM, then SIGKILL after a grace period.
    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Blocking stop used at app quit.
    public func terminateAndWait() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
