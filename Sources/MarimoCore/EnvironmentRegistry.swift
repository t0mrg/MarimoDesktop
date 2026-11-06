import Foundation

/// A Python environment Marimo can run in: created by the app (managed) or linked from elsewhere.
public struct PythonEnvironmentInfo: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case managed, linked }

    /// Stable id of the built-in environment (the original `venv`), so old installs need no migration.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var path: String

    public init(id: UUID = UUID(), name: String, kind: Kind, path: String) {
        self.id = id; self.name = name; self.kind = kind; self.path = path
    }

    public var root: URL { URL(filePath: path, directoryHint: .isDirectory) }
    public var python: URL { root.appending(path: "bin/python") }
    public var isConda: Bool { FileManager.default.fileExists(atPath: root.appending(path: "conda-meta").path) }
    public var isDefault: Bool { id == Self.defaultID }
}

public enum EnvironmentRegistryError: LocalizedError, Equatable {
    case invalidName, duplicateName(String), alreadyLinked(String), cannotRemoveDefault, notFound

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Names must be 1–40 characters: letters, digits, spaces, “-” or “_”."
        case .duplicateName(let n): return "An environment named “\(n)” already exists."
        case .alreadyLinked(let n): return "That folder is already in the list as “\(n)”."
        case .cannotRemoveDefault: return "The default environment can't be removed. Choose another default first."
        case .notFound: return "That environment no longer exists."
        }
    }
}

/// Named environments, the default, and which environment each notebook uses. Pure value type; persisted by the store.
public struct EnvironmentRegistry: Codable, Equatable, Sendable {
    public private(set) var environments: [PythonEnvironmentInfo]
    public private(set) var defaultID: UUID
    public private(set) var assignments: [String: UUID]

    public init(paths: AppPaths) {
        environments = [PythonEnvironmentInfo(id: PythonEnvironmentInfo.defaultID, name: "Default", kind: .managed,
                                              path: paths.venv.path)]
        defaultID = PythonEnvironmentInfo.defaultID
        assignments = [:]
    }

    public var defaultEnvironment: PythonEnvironmentInfo { environment(id: defaultID) ?? environments[0] }
    public func environment(id: UUID) -> PythonEnvironmentInfo? { environments.first { $0.id == id } }

    /// The environment for a notebook: its remembered assignment if that still exists, else the default.
    public func environment(for file: URL) -> PythonEnvironmentInfo {
        assignments[file.standardizedFileURL.path].flatMap(environment(id:)) ?? defaultEnvironment
    }

    public func validate(name: String, excluding id: UUID? = nil) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let ok = (1...40).contains(trimmed.count)
            && trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        guard ok else { throw EnvironmentRegistryError.invalidName }
        if environments.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw EnvironmentRegistryError.duplicateName(trimmed)
        }
    }

    @discardableResult
    public mutating func add(name: String, kind: PythonEnvironmentInfo.Kind, path: String) throws -> PythonEnvironmentInfo {
        try validate(name: name)
        if let existing = environments.first(where: { $0.path == path }) { throw EnvironmentRegistryError.alreadyLinked(existing.name) }
        let info = PythonEnvironmentInfo(name: name.trimmingCharacters(in: .whitespaces), kind: kind, path: path)
        environments.append(info)
        return info
    }

    public mutating func rename(_ id: UUID, to name: String) throws {
        guard let i = environments.firstIndex(where: { $0.id == id }) else { throw EnvironmentRegistryError.notFound }
        try validate(name: name, excluding: id)
        environments[i].name = name.trimmingCharacters(in: .whitespaces)
    }

    public mutating func setDefault(_ id: UUID) throws {
        guard environment(id: id) != nil else { throw EnvironmentRegistryError.notFound }
        defaultID = id
    }

    /// Removes the entry and any assignments to it (those notebooks fall back to the default).
    public mutating func remove(_ id: UUID) throws {
        guard id != defaultID, id != PythonEnvironmentInfo.defaultID else { throw EnvironmentRegistryError.cannotRemoveDefault }
        guard environment(id: id) != nil else { throw EnvironmentRegistryError.notFound }
        environments.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
    }

    public mutating func assign(_ file: URL, to id: UUID) {
        guard environment(id: id) != nil else { return }
        assignments[file.standardizedFileURL.path] = id
    }

    /// Directory-safe, lowercase form of an environment name.
    public static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "env" : collapsed
    }
}

public struct EnvironmentRegistryStore: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    /// Loads the registry, always guaranteeing the built-in default exists.
    public func load() -> EnvironmentRegistry {
        guard let data = try? Data(contentsOf: paths.registryFile),
              let registry = try? JSONDecoder().decode(EnvironmentRegistry.self, from: data),
              registry.environment(id: PythonEnvironmentInfo.defaultID) != nil,
              registry.environment(id: registry.defaultID) != nil
        else { return EnvironmentRegistry(paths: paths) }
        return registry
    }

    public func save(_ registry: EnvironmentRegistry) {
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(registry) { try? data.write(to: paths.registryFile, options: .atomic) }
    }
}
