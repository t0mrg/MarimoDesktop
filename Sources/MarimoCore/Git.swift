import Foundation

public struct GitFileChange: Identifiable, Equatable, Sendable {
    public var path: String
    public var originalPath: String?
    /// Single-letter porcelain code: M, A, D, R, C, ?, U
    public var code: Character
    public var id: String { "\(code)\(path)" }
}

public struct GitStatus: Equatable, Sendable {
    public var branch: String = ""
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var staged: [GitFileChange] = []
    public var unstaged: [GitFileChange] = []
    public var untracked: [GitFileChange] = []
    public var conflicted: [GitFileChange] = []
    public var isClean: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicted.isEmpty }
    public init() {}
}

public struct GitCommit: Identifiable, Equatable, Sendable {
    public var hash: String
    public var author: String
    public var date: Date
    public var subject: String
    public var id: String { hash }
    public var shortHash: String { String(hash.prefix(7)) }
}

public enum GitError: LocalizedError, Equatable {
    case notARepository
    case failed(command: String, status: Int32, message: String)
    public var errorDescription: String? {
        switch self {
        case .notARepository: return "This folder is not a Git repository."
        case let .failed(command, status, message):
            return "git \(command) failed (exit \(status)).\n\(message)"
        }
    }
}

public enum GitParser {
    /// Parses `git status --porcelain=v2 --branch -z`.
    public static func parseStatus(_ output: String) -> GitStatus {
        var status = GitStatus()
        let parts = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < parts.count {
            let entry = parts[i]; i += 1
            if entry.hasPrefix("# branch.head ") { status.branch = String(entry.dropFirst(14)) }
            else if entry.hasPrefix("# branch.upstream ") { status.upstream = String(entry.dropFirst(18)) }
            else if entry.hasPrefix("# branch.ab ") {
                let nums = entry.dropFirst(12).split(separator: " ")
                if nums.count == 2 { status.ahead = Int(nums[0].dropFirst()) ?? 0; status.behind = Int(nums[1].dropFirst()) ?? 0 }
            } else if entry.hasPrefix("1 ") {
                let f = entry.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if f.count == 9 { add(xy: String(f[1]), path: String(f[8]), orig: nil, to: &status) }
            } else if entry.hasPrefix("2 ") {
                let f = entry.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let orig = i < parts.count ? parts[i] : nil; i += 1
                if f.count == 10 { add(xy: String(f[1]), path: String(f[9]), orig: orig, to: &status) }
            } else if entry.hasPrefix("u ") {
                let f = entry.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if f.count == 11 { status.conflicted.append(.init(path: String(f[10]), originalPath: nil, code: "U")) }
            } else if entry.hasPrefix("? ") {
                status.untracked.append(.init(path: String(entry.dropFirst(2)), originalPath: nil, code: "?"))
            }
        }
        return status
    }

    private static func add(xy: String, path: String, orig: String?, to status: inout GitStatus) {
        let x = xy.first ?? ".", y = xy.last ?? "."
        if x != "." { status.staged.append(.init(path: path, originalPath: orig, code: x)) }
        if y != "." { status.unstaged.append(.init(path: path, originalPath: orig, code: y)) }
    }

    /// Parses output of `git log --pretty=format:%H%x1f%an%x1f%aI%x1f%s%x1e`.
    public static func parseLog(_ output: String) -> [GitCommit] {
        let iso = ISO8601DateFormatter()
        return output.split(separator: "\u{1e}").compactMap { record in
            let f = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard f.count == 4, let date = iso.date(from: f[2]) else { return nil }
            return GitCommit(hash: f[0], author: f[1], date: date, subject: f[3])
        }
    }
}

/// Thin async wrapper over the git CLI. Arguments are always passed as an array, never through a shell.
public struct GitClient: Sendable {
    public let directory: URL
    private let gitPath: String
    private let extraEnvironment: [String: String]

    public init(directory: URL, gitPath: String? = nil, extraEnvironment: [String: String] = [:]) {
        self.directory = directory
        self.gitPath = gitPath ?? ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
        self.extraEnvironment = extraEnvironment
    }

    struct Output { var status: Int32; var stdout: String; var stderr: String }

    func exec(_ args: [String]) async throws -> Output {
        let process = Process()
        process.executableURL = URL(filePath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"          // never hang waiting for credentials
        env["LC_ALL"] = "C"
        env.merge(extraEnvironment) { $1 }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        let outData = DataBox(), errData = DataBox()
        out.fileHandleForReading.readabilityHandler = { outData.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }
        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outData.append(out.fileHandleForReading.readDataToEndOfFile())
                errData.append(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: Output(status: p.terminationStatus, stdout: outData.string, stderr: errData.string))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    @discardableResult
    func run(_ args: [String], okStatuses: Set<Int32> = [0]) async throws -> String {
        let r = try await exec(args)
        guard okStatuses.contains(r.status) else {
            if r.stderr.contains("not a git repository") { throw GitError.notARepository }
            throw GitError.failed(command: args.first ?? "", status: r.status,
                                  message: (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout
    }

    public func isRepository() async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"]))?.hasPrefix("true") == true
    }
    public func initialize() async throws { try await run(["init", "-b", "main"]) }
    public func status() async throws -> GitStatus {
        GitParser.parseStatus(try await run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]))
    }
    public func log(limit: Int = 100) async throws -> [GitCommit] {
        // An empty repository has no HEAD; treat as no history.
        guard (try? await run(["rev-parse", "--verify", "HEAD"])) != nil else { return [] }
        return GitParser.parseLog(try await run(["log", "-n", "\(limit)", "--pretty=format:%H%x1f%an%x1f%aI%x1f%s%x1e"]))
    }
    public func branches() async throws -> [String] {
        try await run(["branch", "--format=%(refname:short)"]).split(separator: "\n").map(String.init)
    }
    public func switchBranch(_ name: String) async throws { try await run(["switch", name]) }

    public func stage(_ paths: [String]) async throws { try await run(["add", "--"] + paths) }
    public func stageAll() async throws { try await run(["add", "-A"]) }
    public func unstage(_ paths: [String]) async throws {
        if (try? await run(["rev-parse", "--verify", "HEAD"])) != nil { try await run(["restore", "--staged", "--"] + paths) }
        else { try await run(["rm", "--cached", "-r", "-q", "--"] + paths) }   // no commits yet
    }
    public func discard(_ change: GitFileChange) async throws {
        if change.code == "?" { try await run(["clean", "-f", "--", change.path]) }
        else { try await run(["restore", "--", change.path]) }
    }
    public func commit(message: String) async throws { try await run(["commit", "-m", message]) }
    public func pull() async throws -> String { try await run(["pull", "--ff-only"]) }
    public func push() async throws -> String {
        let r = try await exec(["push"])
        if r.status == 0 { return r.stderr + r.stdout }
        if r.stderr.contains("no upstream branch") { return try await run(["push", "-u", "origin", "HEAD"]) }
        throw GitError.failed(command: "push", status: r.status, message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Unified diff text for a change. Untracked files are diffed against /dev/null.
    public func diff(for change: GitFileChange, staged: Bool) async throws -> String {
        if change.code == "?" {
            return try await run(["diff", "--no-index", "--", "/dev/null", change.path], okStatuses: [0, 1])
        }
        return try await run(["diff"] + (staged ? ["--cached"] : []) + ["--", change.path])
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
