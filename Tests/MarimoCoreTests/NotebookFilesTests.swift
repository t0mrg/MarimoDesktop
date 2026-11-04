import Testing
import Foundation
@testable import MarimoCore

@Test func untitledNamesIncrementAndUseTemplate() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let files = NotebookFiles(untitledDirectory: dir.appending(path: "U"))
    let a = try files.createUntitled(), b = try files.createUntitled()
    #expect(a.lastPathComponent == "Untitled-1.py" && b.lastPathComponent == "Untitled-2.py")
    #expect(files.isUntitled(a))
    #expect(!files.hasContent(a))
    try "x = 1".write(to: a, atomically: true, encoding: .utf8)
    #expect(files.hasContent(a))
}

@Test func saveAsCopiesAndRemovesManagedSource() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let files = NotebookFiles(untitledDirectory: dir.appending(path: "U"))
    let src = try files.createUntitled()
    let dest = try files.saveAs(source: src, destination: dir.appending(path: "mine"))
    #expect(dest.lastPathComponent == "mine.py")
    #expect(FileManager.default.fileExists(atPath: dest.path))
    #expect(!FileManager.default.fileExists(atPath: src.path))
}

@Test func saveAsKeepsRegularSourceAndRefusesOverwrite() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let files = NotebookFiles(untitledDirectory: dir.appending(path: "U"))
    let src = dir.appending(path: "a.py"); try "a".write(to: src, atomically: true, encoding: .utf8)
    let dst = dir.appending(path: "b.py"); try "b".write(to: dst, atomically: true, encoding: .utf8)
    #expect(throws: NotebookFilesError.self) { try files.saveAs(source: src, destination: dst) }
    try files.saveAs(source: src, destination: dst, overwrite: true)
    #expect(try String(contentsOf: dst, encoding: .utf8) == "a")
    #expect(FileManager.default.fileExists(atPath: src.path))
}

@Test func sessionStoreDropsMissingFiles() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let real = dir.appending(path: "r.py"); try "r".write(to: real, atomically: true, encoding: .utf8)
    let store = SessionStore(url: dir.appending(path: "s.json"))
    store.save(.init(files: [real.path, "/nope/x.py"], selected: "/nope/x.py"))
    #expect(store.load() == .init(files: [real.path], selected: nil))
}
