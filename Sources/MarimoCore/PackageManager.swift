import Foundation

public struct InstalledPackage: Identifiable, Equatable, Sendable {
    public enum Installer: Sendable { case pip, conda }
    public var name: String
    public var version: String
    public var installer: Installer = .pip
    /// PEP 503-style normalised name, used as identity.
    public var id: String { PackageSpecs.normalize(name) }
    public var isMarimo: Bool { id == "marimo" }
    public var isRemovable: Bool { !isMarimo && installer == .pip }
    public init(name: String, version: String, installer: Installer = .pip) {
        self.name = name; self.version = version; self.installer = installer
    }
}

public enum PackageError: LocalizedError, Equatable {
    case noInstaller
    case invalidSpec(String)
    case protectedPackage(String)
    case failed(step: String, status: Int32, tail: String)
    case unreadableList

    public var errorDescription: String? {
        switch self {
        case .noInstaller: return "Neither uv nor pip is available for this environment."
        case .invalidSpec(let s): return "“\(s)” is not a valid package name. Options starting with “-” are not allowed."
        case .protectedPackage(let n): return "“\(n)” is required to run notebooks and can't be removed."
        case let .failed(step, status, tail): return "\(step) failed (exit \(status)).\n\(tail)"
        case .unreadableList: return "Couldn't read the package list for this environment."
        }
    }
}

public enum PackageSpecs {
    public static func normalize(_ name: String) -> String {
        name.lowercased().map { "_.".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
    }

    /// Splits user input into specs. Whitespace separates; commas also separate plain names
    /// (`pandas,numpy`) but not inside version constraints (`numpy>=2,<3`) or extras (`x[a,b]`).
    /// Rejects anything that looks like a pip option.
    public static func parse(_ input: String) throws -> [String] {
        var specs: [String] = []
        for token in input.split(whereSeparator: \.isWhitespace) {
            let t = String(token)
            let keepWhole = t.contains(where: { "<>=!~[".contains($0) })
            let parts = keepWhole ? [t] : t.split(separator: ",").map(String.init)
            for part in parts where !part.isEmpty {
                guard !part.hasPrefix("-"), !part.hasPrefix("@"), part.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
                else { throw PackageError.invalidSpec(part) }
                specs.append(part)
            }
        }
        return specs
    }
}

public enum CondaMeta {
    /// Normalised names of packages installed by conda, from `conda-meta/<name>-<version>-<build>.json`.
    public static func installedNames(root: URL) -> Set<String> {
        let dir = root.appending(path: "conda-meta")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".json") }.compactMap { file in
            let parts = file.dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            return PackageSpecs.normalize(parts.dropLast(2).joined(separator: "-"))
        })
    }
}

/// List/install/uninstall packages in one environment. uv is preferred for managed environments;
/// linked environments prefer their own pip (falling back to uv if pip is absent).
public struct PackageManager: Sendable {
    public let environment: PythonEnvironmentInfo
    public let tooling: Tooling
    public let runner: ProcessRunner

    public init(environment: PythonEnvironmentInfo, tooling: Tooling, runner: ProcessRunner = SystemProcessRunner()) {
        self.environment = environment; self.tooling = tooling; self.runner = runner
    }

    struct Command: Equatable { var executable: URL; var arguments: [String] }
    enum Operation { case list, install([String], upgrade: Bool), uninstall([String]) }

    private var py: String { environment.python.path }

    func pipCommand(_ op: Operation) -> Command {
        let base = ["-m", "pip"]
        switch op {
        case .list: return Command(executable: environment.python, arguments: base + ["list", "--format=json", "--disable-pip-version-check"])
        case let .install(specs, upgrade):
            return Command(executable: environment.python, arguments: base + ["install", "--disable-pip-version-check"] + (upgrade ? ["--upgrade"] : []) + specs)
        case .uninstall(let names): return Command(executable: environment.python, arguments: base + ["uninstall", "-y"] + names)
        }
    }

    func uvCommand(_ op: Operation) -> Command? {
        guard let uv = tooling.uv else { return nil }
        switch op {
        case .list: return Command(executable: uv, arguments: ["pip", "list", "--python", py, "--format", "json"])
        case let .install(specs, upgrade):
            return Command(executable: uv, arguments: ["pip", "install", "--python", py] + (upgrade ? ["--upgrade"] : []) + specs)
        case .uninstall(let names): return Command(executable: uv, arguments: ["pip", "uninstall", "--python", py] + names)
        }
    }

    /// Primary command first, with an optional fallback used only if the primary's tool is missing.
    func candidates(_ op: Operation) -> [Command] {
        let uv = uvCommand(op), pip = pipCommand(op)
        if environment.kind == .linked { return [pip] + (uv.map { [$0] } ?? []) }
        return uv.map { [$0, pip] } ?? [pip]
    }

    private func execute(_ op: Operation, step: String, onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        let log = LogBuffer()
        var last: PackageError = .noInstaller
        for command in candidates(op) {
            let status = try await runner.run(command.executable, arguments: command.arguments, environment: cleanEnvironment(),
                                              workingDirectory: nil, onLine: { log.append($0); onLine($0) })
            if status == 0 { return log.all.joined(separator: "\n") }
            let tail = log.tail()
            last = .failed(step: step, status: status, tail: tail)
            // Only move on to the fallback when the tool itself is missing, not when the install is rejected.
            guard tail.contains("No module named pip") else { throw last }
        }
        throw last
    }

    private func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH", "CONDA_PREFIX"] { env[key] = nil }
        env["PATH"] = environment.root.appending(path: "bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    public func list() async throws -> [InstalledPackage] {
        let output = try await execute(.list, step: "Listing packages", onLine: { _ in })
        var packages = try Self.parseList(output)
        if environment.isConda {
            let conda = CondaMeta.installedNames(root: environment.root)
            for i in packages.indices where conda.contains(packages[i].id) { packages[i].installer = .conda }
        }
        return packages
    }

    public func install(_ input: String, upgrade: Bool = false, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let specs = try PackageSpecs.parse(input)
        guard !specs.isEmpty else { return }
        _ = try await execute(.install(specs, upgrade: upgrade), step: "Installing packages", onLine: onLine)
    }

    public func uninstall(_ names: [String], onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let specs = try names.flatMap { try PackageSpecs.parse($0) }
        if let blocked = specs.first(where: { PackageSpecs.normalize($0) == "marimo" }) { throw PackageError.protectedPackage(blocked) }
        guard !specs.isEmpty else { return }
        _ = try await execute(.uninstall(specs), step: "Removing packages", onLine: onLine)
    }

    /// Reads `[{"name":…,"version":…}]` from pip/uv output. Warning lines (including "[notice]") may surround it,
    /// so try each line that starts the array before falling back to the whole text.
    public static func parseList(_ output: String) throws -> [InstalledPackage] {
        func decode(_ text: String) -> [InstalledPackage]? {
            guard let data = text.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            return rows.compactMap { row in
                guard let name = row["name"] as? String, let version = row["version"] as? String else { return nil }
                return InstalledPackage(name: name, version: version)
            }
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [InstalledPackage]?
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            if let r = decode(line) ?? decode(lines[i...].joined(separator: "\n")) { found = r; break }
        }
        guard let packages = found else { throw PackageError.unreadableList }
        return packages.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
