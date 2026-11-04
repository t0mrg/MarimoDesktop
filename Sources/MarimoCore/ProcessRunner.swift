import Foundation

/// Thread-safe accumulator that turns arbitrary output chunks into whole lines.
final class LineAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private let emit: @Sendable (String) -> Void
    init(emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        partial += text
        var lines: [String] = []
        while let nl = partial.firstIndex(of: "\n") {
            lines.append(String(partial[..<nl]))
            partial = String(partial[partial.index(after: nl)...])
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func flush() {
        lock.lock(); let rest = partial; partial = ""; lock.unlock()
        if !rest.isEmpty { emit(rest) }
    }
}

/// Runs a command to completion, streaming merged stdout/stderr line by line.
public protocol ProcessRunner: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String]?,
             workingDirectory: URL?, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                    workingDirectory: URL? = nil,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let assembler = LineAssembler(emit: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in assembler.feed(handle.availableData) }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                assembler.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                assembler.flush()
                continuation.resume(returning: proc.terminationStatus)
            }
            do { try process.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Thread-safe bounded log used for diagnostics and error messages.
public final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity: Int
    public init(capacity: Int = 500) { self.capacity = capacity }

    public func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }
    public func tail(_ n: Int = 20) -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(n).joined(separator: "\n")
    }
    public var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
