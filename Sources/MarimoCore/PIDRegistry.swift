import Foundation

/// Records spawned server PIDs on disk so a crashed app can reap orphans on next launch.
public final class PIDRegistry: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func load() -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }
    public func add(_ pid: Int32) { mutate { if !$0.contains(pid) { $0.append(pid) } } }
    public func remove(_ pid: Int32) { mutate { $0.removeAll { $0 == pid } } }

    /// Terminates leftover processes that are still marimo servers. Returns the PIDs terminated.
    @discardableResult
    public func reap(isMarimo: (Int32) -> Bool, terminate: (Int32) -> Void) -> [Int32] {
        let stale = load()
        var killed: [Int32] = []
        for pid in stale where isMarimo(pid) { terminate(pid); killed.append(pid) }
        lock.lock(); write([]); lock.unlock()
        return killed
    }

    private func mutate(_ change: (inout [Int32]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var pids = read(); change(&pids); write(pids)
    }
    private func read() -> [Int32] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Int32].self, from: data)) ?? []
    }
    private func write(_ pids: [Int32]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pids) { try? data.write(to: url, options: .atomic) }
    }

    /// Real-system helpers used by the app.
    public static func systemIsMarimo(_ pid: Int32) -> Bool {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").contains("marimo")
    }
    public static func systemTerminate(_ pid: Int32) { kill(pid, SIGTERM) }
}
