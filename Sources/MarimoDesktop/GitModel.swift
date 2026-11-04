import SwiftUI
import Observation
import MarimoCore

/// Drives the Git sidebar for whichever notebook is active.
@Observable @MainActor
final class GitModel {
    enum RepoState: Equatable { case none, notRepository, repository }

    var state: RepoState = .none
    var status = GitStatus()
    var history: [GitCommit] = []
    var branches: [String] = []
    var commitMessage = ""
    var busy = false
    var output = ""            // last pull/push output or error text
    var errorText: String?
    var diffTitle = ""
    var diffText: String?

    private var client: GitClient?
    private(set) var directory: URL?

    /// Points the panel at a folder (the active notebook's directory) and reloads.
    func setDirectory(_ url: URL?) async {
        guard url != directory else { return }
        directory = url
        client = url.map { GitClient(directory: $0) }
        await refresh()
    }

    func refresh() async {
        guard let client else { state = .none; return }
        guard await client.isRepository() else { state = .notRepository; status = GitStatus(); history = []; return }
        do {
            async let s = client.status(), h = client.log(), b = client.branches()
            (status, history, branches) = try await (s, h, b)
            state = .repository
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    private func perform(_ work: (GitClient) async throws -> String?) async {
        guard let client, !busy else { return }
        busy = true; defer { busy = false }
        do { output = try await work(client) ?? ""; errorText = nil } catch { errorText = error.localizedDescription }
        await refresh()
    }

    func initialize() async { await perform { try await $0.initialize(); return nil } }
    func stage(_ c: GitFileChange) async { await perform { try await $0.stage([c.path]); return nil } }
    func unstage(_ c: GitFileChange) async { await perform { try await $0.unstage([c.path]); return nil } }
    func stageAll() async { await perform { try await $0.stageAll(); return nil } }
    func unstageAll() async { let paths = status.staged.map(\.path); await perform { try await $0.unstage(paths); return nil } }
    func discard(_ c: GitFileChange) async { await perform { try await $0.discard(c); return nil } }
    func switchBranch(_ name: String) async { await perform { try await $0.switchBranch(name); return nil } }
    func pull() async { await perform { try await $0.pull() } }
    func push() async { await perform { try await $0.push() } }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        await perform { try await $0.commit(message: message); return nil }
        if errorText == nil { commitMessage = "" }
    }

    func showDiff(_ c: GitFileChange, staged: Bool) async {
        guard let client else { return }
        diffTitle = c.path
        do {
            let text = try await client.diff(for: c, staged: staged)
            diffText = text.isEmpty ? "(no textual changes)" : text
        } catch { diffText = error.localizedDescription }
    }
}
