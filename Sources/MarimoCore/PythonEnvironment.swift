import Foundation

public enum EnvironmentError: LocalizedError, Equatable {
    case noPythonOrUV
    case commandFailed(step: String, status: Int32, tail: String)
    case notAnEnvironment(String)

    public var errorDescription: String? {
        switch self {
        case .noPythonOrUV:
            return "Neither uv nor Python 3 could be found. Install uv (brew install uv) or Python 3.9+, then retry."
        case let .commandFailed(step, status, tail):
            return "\(step) failed (exit \(status)).\n\(tail)"
        case .notAnEnvironment(let path):
            return "“\(path)” doesn't look like a Python environment (no bin/python)."
        }
    }
}

/// What the app found on this Mac to build venvs with.
public struct Tooling: Equatable, Sendable {
    public var uv: URL?
    public var python: URL?
    public init(uv: URL? = nil, python: URL? = nil) { self.uv = uv; self.python = python }
    public var isUsable: Bool { uv != nil || python != nil }
}

public enum EnvironmentStatus: Equatable, Sendable {
    case unknown
    case missing
    case installing(step: String)
    case ready(marimoVersion: String)
    case failed(String)
}

/// Result of inspecting one environment.
public enum EnvironmentHealth: Equatable, Sendable {
    case invalid(String)
    case noMarimo(pythonVersion: String)
    case ready(pythonVersion: String, marimoVersion: String)
}

/// Locates uv/python, creates venvs, inspects environments and installs marimo.
public struct PythonEnvironment: Sendable {
    public let paths: AppPaths
    public let runner: ProcessRunner
    private let searchDirectories: [String]

    public init(paths: AppPaths = .standard, runner: ProcessRunner = SystemProcessRunner(),
                searchDirectories: [String]? = nil) {
        self.paths = paths
        self.runner = runner
        let home = NSHomeDirectory()
        self.searchDirectories = searchDirectories ?? [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin",
            "\(home)/.pyenv/shims",
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    /// The built-in environment (the original `venv`).
    public var defaultInfo: PythonEnvironmentInfo {
        PythonEnvironmentInfo(id: PythonEnvironmentInfo.defaultID, name: "Default", kind: .managed, path: paths.venv.path)
    }

    /// GUI apps get a minimal PATH, so search well-known locations explicitly.
    public func locateTooling() -> Tooling {
        let fm = FileManager.default
        func find(_ name: String) -> URL? {
            for dir in searchDirectories {
                let candidate = URL(filePath: dir).appending(path: name)
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            return nil
        }
        var python = find("python3")
        // /usr/bin/python3 is a stub that pops an installer dialog unless the CLT are present.
        if python == nil, fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3") {
            python = URL(filePath: "/usr/bin/python3")
        }
        return Tooling(uv: find("uv"), python: python)
    }

    /// Runs the environment's own Python to learn its version and whether marimo imports.
    public func inspect(_ env: PythonEnvironmentInfo) async -> EnvironmentHealth {
        guard FileManager.default.isExecutableFile(atPath: env.python.path) else {
            return .invalid("No Python found at \(env.python.path)")
        }
        let out = LogBuffer()
        let script = "import sys\nprint(sys.version.split()[0])\ntry:\n    import marimo\n    print(marimo.__version__)\nexcept Exception:\n    print('')"
        let code = try? await runner.run(env.python, arguments: ["-c", script], environment: cleanEnvironment(),
                                         workingDirectory: nil, onLine: { out.append($0) })
        let lines = out.all.map { $0.trimmingCharacters(in: .whitespaces) }
        guard code == 0, lines.count >= 2 else { return .invalid("Python at \(env.python.path) could not be run.\n\(out.tail(5))") }
        let python = lines[lines.count - 2], marimo = lines[lines.count - 1]
        return marimo.isEmpty ? .noMarimo(pythonVersion: python) : .ready(pythonVersion: python, marimoVersion: marimo)
    }

    /// Returns `.ready` if the default venv exists and can import marimo.
    public func currentStatus() async -> EnvironmentStatus {
        guard FileManager.default.isExecutableFile(atPath: paths.venvPython.path) else { return .missing }
        if case let .ready(_, marimo) = await inspect(defaultInfo) { return .ready(marimoVersion: marimo) }
        return .missing
    }

    /// Creates a bare venv at `root` using uv (preferred) or the system Python.
    public func createVenv(at root: URL, log: LogBuffer, onLine: @escaping @Sendable (String) -> Void) async throws {
        let tooling = locateTooling()
        guard tooling.isUsable else { throw EnvironmentError.noPythonOrUV }
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (exe, args): (URL, [String]) = tooling.uv.map { ($0, ["venv", root.path]) } ?? (tooling.python!, ["-m", "venv", root.path])
        let status = try await runner.run(exe, arguments: args, environment: cleanEnvironment(), workingDirectory: nil, onLine: onLine)
        if status != 0 { throw EnvironmentError.commandFailed(step: "Creating environment", status: status, tail: log.tail()) }
    }

    /// Creates a managed environment folder under `envs/` containing marimo plus any extra specs.
    public func createManaged(name: String, packages: [String] = [],
                              progress: @escaping @Sendable (String, String) -> Void) async throws -> URL {
        try paths.createDirectories()
        var root = paths.envsDirectory.appending(path: EnvironmentRegistry.slug(name), directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: root.path) {
            root = paths.envsDirectory.appending(path: "\(EnvironmentRegistry.slug(name))-\(n)", directoryHint: .isDirectory); n += 1
        }
        let log = LogBuffer()
        progress("Creating environment…", "")
        do {
            try await createVenv(at: root, log: log, onLine: { log.append($0); progress("", $0) })
            let info = PythonEnvironmentInfo(name: name, kind: .managed, path: root.path)
            progress("Installing Marimo…", "")
            try await installPackages(["marimo"] + packages, into: info, upgrade: false, log: log, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: root)   // never leave a half-built environment behind
            throw error
        }
        return root
    }

    /// Installs packages through `PackageManager`, so command construction lives in one place.
    public func installPackages(_ specs: [String], into env: PythonEnvironmentInfo, upgrade: Bool, log: LogBuffer,
                                progress: @escaping @Sendable (String, String) -> Void) async throws {
        let manager = PackageManager(environment: env, tooling: locateTooling(), runner: runner)
        do {
            try await manager.install(specs.joined(separator: " "), upgrade: upgrade) { log.append($0); progress("", $0) }
        } catch PackageError.failed(let step, let status, let tail) {
            throw EnvironmentError.commandFailed(step: step, status: status, tail: tail)
        }
    }

    /// Creates the default venv if needed, then installs/upgrades marimo plus any extra packages into it.
    public func install(extraPackages: [String] = [], upgrade: Bool = false,
                        progress: @escaping @Sendable (String, String) -> Void) async throws {
        guard locateTooling().isUsable else { throw EnvironmentError.noPythonOrUV }
        try paths.createDirectories()
        let log = LogBuffer()
        if !FileManager.default.isExecutableFile(atPath: paths.venvPython.path) {
            progress("Creating private Python environment…", "")
            try await createVenv(at: paths.venv, log: log, onLine: { log.append($0); progress("", $0) })
        }
        progress("Installing Marimo…", "")
        try await installPackages(["marimo"] + extraPackages, into: defaultInfo, upgrade: upgrade, log: log, progress: progress)
    }

    /// Deletes a managed environment's folder. Refuses anything that is not inside our own `envs/` directory.
    public func deleteManaged(_ env: PythonEnvironmentInfo) throws {
        let root = env.root.standardizedFileURL
        let allowed = paths.envsDirectory.standardizedFileURL.path + "/"
        guard env.kind == .managed, !env.isDefault, root.path.hasPrefix(allowed) else { throw EnvironmentError.notAnEnvironment(env.path) }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    /// Strips variables that would make Python/uv target some other environment.
    func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH", "CONDA_PREFIX", "CONDA_DEFAULT_ENV"] { env[key] = nil }
        env["PATH"] = (searchDirectories + ["/usr/bin", "/bin"]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }
}
