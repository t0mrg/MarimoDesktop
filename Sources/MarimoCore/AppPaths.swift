import Foundation

/// Filesystem locations used by the app. Injectable so tests can use a temp directory.
public struct AppPaths: Sendable {
    public let root: URL
    public var venv: URL { root.appending(path: "venv", directoryHint: .isDirectory) }
    public var venvPython: URL { venv.appending(path: "bin/python") }
    public var marimoExecutable: URL { venv.appending(path: "bin/marimo") }
    public var pidFile: URL { root.appending(path: "pids.json") }
    public var untitledDirectory: URL { root.appending(path: "Untitled", directoryHint: .isDirectory) }
    public var sessionFile: URL { root.appending(path: "session.json") }

    public init(root: URL) { self.root = root }

    public static var standard: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appending(path: "MarimoDesktop", directoryHint: .isDirectory))
    }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untitledDirectory, withIntermediateDirectories: true)
    }
}
