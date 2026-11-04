import Foundation

public enum NotebookTemplate {
    /// Starter source for a new notebook. Valid marimo file format.
    public static let source = """
    import marimo

    app = marimo.App()


    @app.cell
    def _():
        import marimo as mo
        return (mo,)


    @app.cell
    def _(mo):
        mo.md("# New notebook")
        return


    if __name__ == "__main__":
        app.run()

    """
}

public enum NotebookFilesError: LocalizedError {
    case destinationExists(URL)
    public var errorDescription: String? {
        switch self { case .destinationExists(let url): return "\(url.lastPathComponent) already exists." }
    }
}

public struct NotebookFiles: Sendable {
    public let untitledDirectory: URL
    public init(untitledDirectory: URL) { self.untitledDirectory = untitledDirectory }

    /// Creates the next free `Untitled-N.py` in the managed folder, pre-filled with the template.
    public func createUntitled() throws -> URL {
        try FileManager.default.createDirectory(at: untitledDirectory, withIntermediateDirectories: true)
        var n = 1
        while true {
            let url = untitledDirectory.appending(path: "Untitled-\(n).py")
            if !FileManager.default.fileExists(atPath: url.path) {
                try NotebookTemplate.source.write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            n += 1
        }
    }

    public func isUntitled(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == untitledDirectory.standardizedFileURL.path
    }

    /// True if an untitled notebook differs from the pristine template (so closing should prompt).
    public func hasContent(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            != NotebookTemplate.source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Forces a `.py` extension, which marimo requires.
    public static func normalizedDestination(_ url: URL) -> URL {
        url.pathExtension.lowercased() == "py" ? url : url.appendingPathExtension("py")
    }

    /// Copies `source` to `destination`; removes the source afterwards only if it is a managed untitled file.
    @discardableResult
    public func saveAs(source: URL, destination: URL, overwrite: Bool = false) throws -> URL {
        let dest = Self.normalizedDestination(destination)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            guard overwrite else { throw NotebookFilesError.destinationExists(dest) }
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
        if isUntitled(source) { try? fm.removeItem(at: source) }
        return dest
    }
}

/// Persists which notebooks were open so tabs restore on relaunch.
public struct SessionStore: Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var files: [String]
        public var selected: String?
        public init(files: [String] = [], selected: String? = nil) { self.files = files; self.selected = selected }
    }
    private let url: URL
    public init(url: URL) { self.url = url }

    public func save(_ state: State) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }

    /// Loads the saved state, dropping files that no longer exist.
    public func load() -> State {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        let existing = s.files.filter { FileManager.default.fileExists(atPath: $0) }
        return State(files: existing, selected: s.selected.flatMap { existing.contains($0) ? $0 : nil })
    }
}
