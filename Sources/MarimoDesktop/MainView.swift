import SwiftUI
import MarimoCore

struct MainView: View {
    @Bindable var model: AppModel
    @AppStorage("showInspector") private var showInspector = true

    @State private var git = GitModel()
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            GitView(git: git).navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: { detail }
        .task(id: model.selectedSession?.file) { await git.setDirectory(model.selectedSession?.file.deletingLastPathComponent()) }
        .task {   // pick up saves and external commits without user action (FR-GIT-8)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); await git.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await git.refresh() }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if !model.sessions.isEmpty { TabBar(model: model) }
            ZStack {
                if model.sessions.isEmpty {
                    WelcomeView(model: model)
                } else if let session = model.selectedSession {
                    SessionContent(session: session, model: model).id(session.id)
                }
            }
        }
        .background(.background)
        .inspector(isPresented: $showInspector) {
            VariablesView(session: model.selectedSession).inspectorColumnWidth(min: 240, ideal: 300, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EnvironmentPicker(model: model) }
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Label("Variables", systemImage: "sidebar.trailing") }
                    .help("Show or hide the variable browser (⌥⌘I)").keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

struct SessionContent: View {
    let session: NotebookSession
    let model: AppModel
    var body: some View {
        switch session.state {
        case .starting:
            VStack(spacing: 12) { ProgressView(); Text("Starting \(session.title)…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running:
            WebNotebookView(webView: session.webView)
                .overlay(alignment: .top) { if session.needsRestart { RestartBanner(session: session, model: model) } }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text("Couldn't run \(session.title)").font(.title3.bold())
                ScrollView { Text(message).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180).padding(10).background(.quaternary, in: .rect(cornerRadius: 12))
                Button("Retry") { session.start(registry: model.pidRegistry) }.buttonStyle(.borderedProminent)
            }
            .padding(32).frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TabBar: View {
    @Bindable var model: AppModel
    var body: some View {
        GlassEffectContainer(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sessions) { session in
                        TabItem(session: session, selected: session.id == model.selectedID,
                                select: { model.selectedID = session.id },
                                close: { Task { await model.close(session) } })
                    }
                    Button { model.newNotebook() } label: { Image(systemName: "plus") }
                        .buttonStyle(.glass).accessibilityLabel("New Notebook")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
    }
}

struct TabItem: View {
    let session: NotebookSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            Text(session.title).lineLimit(1).font(.callout.weight(selected ? .semibold : .regular))
            Button(action: close) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.plain).opacity(hovering || selected ? 1 : 0)
                .accessibilityLabel("Close \(session.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(session.file.path)
    }

    @ViewBuilder private var statusDot: some View {
        switch session.state {
        case .starting: ProgressView().controlSize(.mini)
        case .running: Circle().fill(.green).frame(width: 7, height: 7)
        case .failed: Circle().fill(.red).frame(width: 7, height: 7)
        }
    }
}

struct WelcomeView: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "leaf.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Marimo Desktop").font(.largeTitle.bold())
            HStack(spacing: 12) {
                Button { model.newNotebook() } label: { Label("New Notebook", systemImage: "plus") }
                    .buttonStyle(.glassProminent)
                Button { model.showOpenPanel() } label: { Label("Open…", systemImage: "folder") }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
            let recents = Array(NSDocumentController.shared.recentDocumentURLs.prefix(6))
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.headline).foregroundStyle(.secondary)
                    ForEach(recents, id: \.self) { url in
                        Button { model.open(url) } label: {
                            Label(url.lastPathComponent, systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RestartBanner: View {
    let session: NotebookSession
    let model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("Packages changed in “\(session.environment.name)”. Restart to apply.").font(.callout)
            Button("Restart") { session.restart(registry: model.pidRegistry) }.buttonStyle(.glassProminent)
            Button { session.needsRestart = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule).padding(.top, 10)
    }
}

/// Per-notebook environment menu in the toolbar.
struct EnvironmentPicker: View {
    let model: AppModel
    var body: some View {
        Menu {
            ForEach(model.registry.environments) { env in
                Button { model.assign(env, to: model.selectedSession) } label: {
                    if env.id == model.selectedSession?.environment.id { Label(env.name, systemImage: "checkmark") } else { Text(env.name) }
                }
            }
            Divider()
            SettingsLink { Text("Manage Environments…") }
        } label: {
            Label(model.selectedSession?.environment.name ?? "Environment", systemImage: "shippingbox")
        }
        .disabled(model.selectedSession == nil)
        .help("Python environment for this notebook")
    }
}
