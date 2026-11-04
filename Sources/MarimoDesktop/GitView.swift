import SwiftUI
import MarimoCore

struct GitView: View {
    @Bindable var git: GitModel
    @State private var tab = 0
    @State private var confirmDiscard: GitFileChange?

    var body: some View {
        VStack(spacing: 0) {
            switch git.state {
            case .none:
                ContentUnavailableView("No notebook", systemImage: "arrow.triangle.branch",
                                       description: Text("Open a notebook to see its Git status."))
            case .notRepository:
                ContentUnavailableView {
                    Label("Not a Git repository", systemImage: "arrow.triangle.branch")
                } description: {
                    Text(git.directory?.path ?? "").font(.caption).lineLimit(2)
                } actions: {
                    Button("Initialise Repository") { Task { await git.initialize() } }.buttonStyle(.glassProminent)
                }
            case .repository:
                header
                Picker("", selection: $tab) { Text("Changes").tag(0); Text("History").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.bottom, 8)
                if tab == 0 { changes } else { historyList }
            }
            if let error = git.errorText {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .navigationTitle("Git")
        .sheet(isPresented: Binding(get: { git.diffText != nil }, set: { if !$0 { git.diffText = nil } })) {
            DiffSheet(title: git.diffTitle, text: git.diffText ?? "") { git.diffText = nil }
        }
        .confirmationDialog("Discard changes to “\(confirmDiscard?.path ?? "")”?", isPresented: Binding(
            get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }), titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { if let c = confirmDiscard { Task { await git.discard(c) } } }
        } message: { Text("This cannot be undone.") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(git.branches, id: \.self) { b in
                    Button { Task { await git.switchBranch(b) } } label: {
                        if b == git.status.branch { Label(b, systemImage: "checkmark") } else { Text(b) }
                    }
                }
            } label: { Label(git.status.branch, systemImage: "arrow.triangle.branch").lineLimit(1) }
                .menuStyle(.button).buttonStyle(.glass)
            if git.status.ahead > 0 || git.status.behind > 0 {
                Text("↑\(git.status.ahead) ↓\(git.status.behind)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if git.busy { ProgressView().controlSize(.small) }
            Button { Task { await git.pull() } } label: { Image(systemName: "arrow.down.circle") }
                .help("Pull").accessibilityLabel("Pull")
            Button { Task { await git.push() } } label: { Image(systemName: "arrow.up.circle") }
                .help("Push").accessibilityLabel("Push")
            Button { Task { await git.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh").accessibilityLabel("Refresh")
        }
        .buttonStyle(.borderless).padding(10)
    }

    private var changes: some View {
        VStack(spacing: 0) {
            List {
                if !git.status.conflicted.isEmpty {
                    Section("Conflicts") { ForEach(git.status.conflicted) { row($0, staged: false) } }
                }
                Section {
                    ForEach(git.status.staged) { row($0, staged: true) }
                } header: {
                    HStack { Text("Staged"); Spacer(); if !git.status.staged.isEmpty { Button("Unstage All") { Task { await git.unstageAll() } }.font(.caption) } }
                }
                Section {
                    ForEach(git.status.unstaged) { row($0, staged: false) }
                    ForEach(git.status.untracked) { row($0, staged: false) }
                } header: {
                    HStack { Text("Changes"); Spacer(); if !(git.status.unstaged + git.status.untracked).isEmpty { Button("Stage All") { Task { await git.stageAll() } }.font(.caption) } }
                }
                if git.status.isClean {
                    Text("Working tree clean").foregroundStyle(.secondary).font(.callout)
                }
            }
            .listStyle(.sidebar)
            VStack(spacing: 8) {
                TextEditor(text: $git.commitMessage)
                    .font(.body).frame(height: 64).scrollContentBackground(.hidden).padding(6)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if git.commitMessage.isEmpty { Text("Commit message").foregroundStyle(.tertiary).padding(11).allowsHitTesting(false) }
                    }
                Button { Task { await git.commit() } } label: {
                    Text("Commit \(git.status.staged.count) file\(git.status.staged.count == 1 ? "" : "s")").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command)
                .disabled(git.status.staged.isEmpty || git.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || git.busy)
            }.padding(10)
        }
    }

    private func row(_ c: GitFileChange, staged: Bool) -> some View {
        HStack(spacing: 8) {
            Text(String(c.code)).font(.caption.monospaced().bold()).foregroundStyle(color(c.code)).frame(width: 14)
            Text((c.path as NSString).lastPathComponent).lineLimit(1)
            Text((c.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { Task { staged ? await git.unstage(c) : await git.stage(c) } } label: {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
            }.buttonStyle(.borderless).help(staged ? "Unstage" : "Stage")
                .accessibilityLabel(staged ? "Unstage \(c.path)" : "Stage \(c.path)")
        }
        .contentShape(.rect)
        .onTapGesture { Task { await git.showDiff(c, staged: staged) } }
        .contextMenu {
            Button("Show Diff") { Task { await git.showDiff(c, staged: staged) } }
            if !staged { Button("Discard Changes…", role: .destructive) { confirmDiscard = c } }
        }
    }

    private func color(_ code: Character) -> Color {
        switch code { case "A", "?": .green; case "D": .red; case "R", "C": .blue; case "U": .orange; default: .yellow }
    }

    private var historyList: some View {
        List(git.history) { c in
            VStack(alignment: .leading, spacing: 2) {
                Text(c.subject).lineLimit(2)
                HStack {
                    Text(c.shortHash).font(.caption.monospaced())
                    Text(c.author)
                    Spacer()
                    Text(c.date, style: .relative)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .overlay { if git.history.isEmpty { ContentUnavailableView("No commits yet", systemImage: "clock") } }
    }
}

struct DiffSheet: View {
    let title: String
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }.padding()
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line)).font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                            .background(background(line))
                    }
                }.textSelection(.enabled)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private func background(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return .green.opacity(0.18) }
        if line.hasPrefix("-") { return .red.opacity(0.18) }
        if line.hasPrefix("@@") { return .blue.opacity(0.15) }
        return .clear
    }
}
