import Foundation

public enum EnvironmentError: LocalizedError, Equatable {
    case noPythonOrUV
    case commandFailed(step: String, status: Int32, tail: String)

    public var errorDescription: String? {
        switch self {
        case .noPythonOrUV:
            return "Neither uv nor Python 3 could be found. Install uv (brew install uv) or Python 3.9+, then retry."
        case let .commandFailed(step, status, tail):
            return "\(step) failed (exit \(status)).\n\(tail)"
        }
    }
}

/// What the app found on this Mac to build the venv with.
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

/// Locates uv/python, creates the private venv and installs marimo.
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

    /// Returns `.ready` if the venv exists and can import marimo.
    public func currentStatus() async -> EnvironmentStatus {
        guard FileManager.default.isExecutableFile(atPath: paths.venvPython.path) else { return .missing }
        let out = LogBuffer()
        let code = try? await runner.run(
            paths.venvPython, arguments: ["-c", "import marimo; print(marimo.__version__)"],
            environment: cleanEnvironment(), workingDirectory: nil, onLine: { out.append($0) })
        guard code == 0, let version = out.all.last?.trimmingCharacters(in: .whitespaces), !version.isEmpty
        else { return .missing }
        return .ready(marimoVersion: version)
    }

    /// Creates the venv (if needed) and installs/upgrades marimo plus any extra packages.
    public func install(extraPackages: [String] = [], upgrade: Bool = false,
                        progress: @escaping @Sendable (String, String) -> Void) async throws {
        let tooling = locateTooling()
        guard tooling.isUsable else { throw EnvironmentError.noPythonOrUV }
        try paths.createDirectories()
        let log = LogBuffer()
        let emit: @Sendable (String) -> Void = { line in log.append(line); progress("", line) }
        let env = cleanEnvironment()

        if !FileManager.default.isExecutableFile(atPath: paths.venvPython.path) {
            progress("Creating private Python environment…", "")
            let (exe, args): (URL, [String]) = tooling.uv.map { ($0, ["venv", paths.venv.path]) }
                ?? (tooling.python!, ["-m", "venv", paths.venv.path])
            try check(await runner.run(exe, arguments: args, environment: env, workingDirectory: nil, onLine: emit),
                            step: "Creating environment", log: log)
        }
        progress("Installing Marimo…", "")
        let packages = ["marimo"] + extraPackages
        if let uv = tooling.uv {
            var args = ["pip", "install", "--python", paths.venvPython.path]
            if upgrade { args.append("--upgrade") }
            try check(await runner.run(uv, arguments: args + packages, environment: env, workingDirectory: nil, onLine: emit),
                            step: "Installing packages", log: log)
        } else {
            var args = ["-m", "pip", "install"]
            if upgrade { args.append("--upgrade") }
            try check(await runner.run(paths.venvPython, arguments: args + packages, environment: env,
                                       workingDirectory: nil, onLine: emit),
                            step: "Installing packages", log: log)
        }
    }

    /// Strips variables that would make Python/uv target some other environment.
    func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH", "CONDA_PREFIX", "CONDA_DEFAULT_ENV"] { env[key] = nil }
        env["PATH"] = (searchDirectories + ["/usr/bin", "/bin"]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private func check(_ status: Int32, step: String, log: LogBuffer) throws {
        if status != 0 { throw EnvironmentError.commandFailed(step: step, status: status, tail: log.tail()) }
    }
}
