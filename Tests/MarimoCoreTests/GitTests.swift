import Testing
import Foundation
@testable import MarimoCore

@Test func parsesStatusFixture() {
    let raw = "# branch.oid abc\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
        + "1 M. N... 100644 100644 100644 aaa bbb staged.py\0"
        + "1 .M N... 100644 100644 100644 aaa bbb with space.py\0"
        + "1 MM N... 100644 100644 100644 aaa bbb both.py\0"
        + "2 R. N... 100644 100644 100644 aaa bbb R100 new.py\0old.py\0"
        + "u UU N... 100644 100644 100644 100644 a b c conflict.py\0"
        + "? new file.py\0"
    let s = GitParser.parseStatus(raw)
    #expect(s.branch == "main" && s.upstream == "origin/main" && s.ahead == 2 && s.behind == 1)
    #expect(s.staged.map(\.path) == ["staged.py", "both.py", "new.py"])
    #expect(s.staged.last?.originalPath == "old.py" && s.staged.last?.code == "R")
    #expect(s.unstaged.map(\.path) == ["with space.py", "both.py"])
    #expect(s.untracked.map(\.path) == ["new file.py"])
    #expect(s.conflicted.map(\.path) == ["conflict.py"])
}

@Test func parsesLogFixture() {
    let raw = "abc123\u{1f}Ann\u{1f}2026-11-04T10:00:00Z\u{1f}First\u{1e}def456\u{1f}Bob\u{1f}2026-11-03T09:30:00+01:00\u{1f}Second, with comma\u{1e}"
    let log = GitParser.parseLog(raw)
    #expect(log.map(\.subject) == ["First", "Second, with comma"])
    #expect(log[0].shortHash == "abc123" && log[1].author == "Bob")
}

private func makeClient() -> (GitClient, URL) {
    let dir = tempDir()
    let env = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    return (GitClient(directory: dir, extraEnvironment: env), dir)
}

@Test func fullWorkflowAgainstRealRepo() async throws {
    let (git, dir) = makeClient(); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!(await git.isRepository()))
    await #expect(throws: GitError.notARepository) { _ = try await git.status() }
    try await git.initialize()
    #expect(await git.isRepository())
    #expect(try await git.log().isEmpty)

    try "print(1)\n".write(to: dir.appending(path: "a b.py"), atomically: true, encoding: .utf8)
    var s = try await git.status()
    #expect(s.untracked.map(\.path) == ["a b.py"] && s.branch == "main")
    let diff = try await git.diff(for: s.untracked[0], staged: false)
    #expect(diff.contains("+print(1)"))

    try await git.stage(["a b.py"])
    s = try await git.status()
    #expect(s.staged.map(\.code) == ["A"] && s.untracked.isEmpty)
    try await git.unstage(["a b.py"])                      // exercises the no-HEAD path
    #expect(try await git.status().untracked.count == 1)
    try await git.stage(["a b.py"])
    try await git.commit(message: "first")
    #expect(try await git.status().isClean)
    #expect(try await git.log().map(\.subject) == ["first"])

    try "print(2)\n".write(to: dir.appending(path: "a b.py"), atomically: true, encoding: .utf8)
    s = try await git.status()
    #expect(s.unstaged.map(\.code) == ["M"])
    #expect(try await git.diff(for: s.unstaged[0], staged: false).contains("+print(2)"))
    try await git.stage(["a b.py"])
    #expect(try await git.diff(for: try await git.status().staged[0], staged: true).contains("+print(2)"))
    try await git.unstage(["a b.py"])                      // with HEAD
    try await git.discard(try await git.status().unstaged[0])
    #expect(try await git.status().isClean)

    try await git.run(["branch", "feature"])
    try await git.switchBranch("feature")
    #expect(try await git.status().branch == "feature")
    #expect(try await git.branches().sorted() == ["feature", "main"])
}

@Test func commitWithNothingStagedReportsError() async throws {
    let (git, dir) = makeClient(); defer { try? FileManager.default.removeItem(at: dir) }
    try await git.initialize()
    await #expect(throws: GitError.self) { try await git.commit(message: "x") }
}
