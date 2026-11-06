import SwiftUI
import AppKit
import MarimoCore

struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        TabView {
            EnvironmentsSettings(model: model, packages: PackagesModel(app: model))
                .tabItem { Label("Environments", systemImage: "shippingbox") }
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 860, height: 600)
    }
}

/// A text field whose example text is a faint prompt that disappears as soon as the user types (FR-UI-5).
struct PromptField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .labelsHidden().textFieldStyle(.roundedBorder).onSubmit(onSubmit)
    }
}

struct EnvironmentsSettings: View {
    @Bindable var model: AppModel
    @State var packages: PackagesModel
    @State private var showNew = false
    @State private var renaming: PythonEnvironmentInfo?
    @State private var renameText = ""
    @State private var confirmRemove: PythonEnvironmentInfo?
    @State private var confirmUninstall = false
    @State private var alertText: String?

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
            detail.frame(minWidth: 520)
        }
        .task { await packages.refreshAllHealth(); await packages.reload() }
        .sheet(isPresented: $showNew) { NewEnvironmentSheet(model: model, packages: packages, isPresented: $showNew) }
        .alert("Rename environment", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(confirmRemove.map { "Remove “\($0.name)”?" } ?? "", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button(confirmRemove?.kind == .managed ? "Delete Environment" : "Unlink", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmRemove?.kind == .managed ? "This deletes the environment and all packages installed in it."
                 : "The folder is not touched; it is only removed from this list.")
        }
        .alert("Problem", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK") {}
        } message: { Text(alertText ?? "") }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { Optional(packages.selectedID) }, set: { id in if let id { Task { await packages.select(id) } } })) {
                ForEach(model.registry.environments) { env in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(env.name).font(.body.weight(.medium))
                            if env.id == model.registry.defaultID { badge("default", .accentColor) }
                        }
                        HStack(spacing: 6) {
                            badge(env.kind == .managed ? "managed" : "linked", .secondary)
                            if env.isConda { badge("conda", .green) }
                            if case let .ready(py, _) = packages.health[env.id] { Text("Python \(py)").font(.caption).foregroundStyle(.secondary) }
                            if case .invalid = packages.health[env.id] { badge("missing", .red) }
                        }
                        let n = model.sessions(using: env).count
                        if n > 0 { Text("\(n) open notebook\(n == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 3).tag(env.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Menu {
                    Button("New Environment…") { showNew = true }
                    Button("Link Existing…") { link() }
                } label: { Label("Add", systemImage: "plus") }
                    .menuStyle(.button).buttonStyle(.glass)
                Spacer()
            }.padding(8)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: .capsule).foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    // MARK: detail

    private var detail: some View {
        let env = packages.selected
        return VStack(alignment: .leading, spacing: 12) {
            header(env)
            Divider()
            installRow(env)
            if let error = packages.errorText {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(6)
            }
            if packages.busy || !packages.log.isEmpty { logView }
            packageTable(env)
        }
        .padding(16)
    }

    @ViewBuilder private func header(_ env: PythonEnvironmentInfo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(env.name).font(.title2.bold())
                Text(env.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                switch packages.health[env.id] {
                case let .ready(py, marimo): Text("Python \(py) · Marimo \(marimo)").font(.caption)
                case .noMarimo:
                    HStack { Label("Marimo is not installed here", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                        Button("Install Marimo") { Task { await packages.installMarimo() } }.controlSize(.small) }
                case .invalid(let reason): Label(reason, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
                case nil: ProgressView().controlSize(.small)
                }
            }
            Spacer()
            Menu {
                Button("Set as Default") { act { try model.setDefaultEnvironment(env) } }.disabled(env.id == model.registry.defaultID)
                Button("Rename…") { renameText = env.name; renaming = env }.disabled(env.isDefault)
                Divider()
                Button(env.kind == .managed ? "Delete…" : "Unlink…", role: .destructive) { confirmRemove = env }
                    .disabled(env.id == model.registry.defaultID || env.isDefault)
            } label: { Label("Actions", systemImage: "ellipsis.circle") }
                .menuStyle(.button).buttonStyle(.glass)
        }
    }

    private func installRow(_ env: PythonEnvironmentInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                PromptField(prompt: "e.g. pandas numpy altair", text: $packages.installText) { if packages.canInstall { Task { await packages.install() } } }
                Button("Install") { Task { await packages.install() } }
                    .buttonStyle(.glassProminent).disabled(!packages.canInstall)
            }
            if case .failure(let e) = packages.parsedInstall, !packages.installText.isEmpty {
                Text(e.localizedDescription).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { if packages.busy { ProgressView().controlSize(.small); Text(packages.busyTitle).font(.callout) } }
            ScrollViewReader { proxy in
                ScrollView { Text(packages.log.suffix(200).joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).id("end") }
                    .onChange(of: packages.log.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(height: 80).padding(8).background(.quaternary, in: .rect(cornerRadius: 10))
        }
    }

    private func packageTable(_ env: PythonEnvironmentInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                PromptField(prompt: "Filter installed packages", text: $packages.filter)
                Text("\(packages.visiblePackages.count) of \(packages.packages.count)").font(.caption).foregroundStyle(.secondary)
                if packages.loading { ProgressView().controlSize(.small) }
                Button { Task { await packages.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("Reload packages")
            }
            Table(packages.visiblePackages, selection: $packages.selection) {
                TableColumn("Package") { p in
                    HStack(spacing: 6) {
                        Text(p.name)
                        if p.installer == .conda { Text("conda").font(.caption2).foregroundStyle(.green) }
                    }
                }
                TableColumn("Version") { p in Text(p.version).monospaced().foregroundStyle(.secondary) }.width(110)
                TableColumn("") { p in
                    Button { packages.selection = [p.id]; confirmUninstall = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(!p.isRemovable || packages.busy)
                        .help(p.isMarimo ? "Marimo is required and can't be removed"
                              : p.installer == .conda ? "Installed by conda; remove it with conda" : "Uninstall \(p.name)")
                        .accessibilityLabel("Uninstall \(p.name)")
                }.width(34)
            }
            .overlay { if packages.packages.isEmpty && !packages.loading { ContentUnavailableView("No packages", systemImage: "shippingbox") } }
            HStack {
                Spacer()
                Button("Uninstall Selected", role: .destructive) { confirmUninstall = true }
                    .disabled(packages.selection.isEmpty || packages.busy
                              || !packages.packages.contains { packages.selection.contains($0.id) && $0.isRemovable })
            }
        }
        .confirmationDialog(uninstallTitle, isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await packages.uninstall(packages.selection) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Notebooks using “\(env.name)” will offer to restart.") }
    }

    private var uninstallTitle: String {
        let names = packages.packages.filter { packages.selection.contains($0.id) && $0.isRemovable }.map(\.name)
        return names.count == 1 ? "Uninstall \(names[0])?" : "Uninstall \(names.count) packages?"
    }

    // MARK: actions

    private func act(_ work: () throws -> Void) { do { try work() } catch { alertText = error.localizedDescription } }

    private func rename() {
        guard let env = renaming else { return }
        act { try model.renameEnvironment(env, to: renameText) }
        renaming = nil
    }

    private func remove() {
        guard let env = confirmRemove else { return }
        confirmRemove = nil
        act { try model.removeEnvironment(env) }
        Task { await packages.select(model.registry.defaultID) }
    }

    private func link() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the folder of a Python environment (a venv, or a conda env such as …/envs/myenv)"
        panel.prompt = "Link"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { if let info = try await model.linkEnvironment(at: url) { await packages.refreshAllHealth(); await packages.select(info.id) } }
            catch { alertText = error.localizedDescription }
        }
    }
}

struct NewEnvironmentSheet: View {
    let model: AppModel
    let packages: PackagesModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var source: UUID?
    @State private var working = false
    @State private var step = ""
    @State private var log: [String] = []
    @State private var error: String?

    private var nameError: String? {
        guard !name.isEmpty else { return nil }
        do { try model.registry.validate(name: name); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Environment").font(.title2.bold())
            PromptField(prompt: "e.g. data-science", text: $name)
            if let nameError { Text(nameError).font(.caption).foregroundStyle(.red) }
            Picker("Copy packages from", selection: $source) {
                Text("None (Marimo only)").tag(UUID?.none)
                ForEach(model.registry.environments) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if working {
                HStack { ProgressView().controlSize(.small); Text(step) }
                Text(log.suffix(6).joined(separator: "\n")).font(.caption.monospaced()).lineLimit(6)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(8) }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.disabled(working)
                Button("Create") { create() }.buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || nameError != nil || working)
            }
        }
        .padding(20).frame(width: 440)
    }

    private func create() {
        working = true; error = nil
        let src = source.flatMap { model.registry.environment(id: $0) }
        Task {
            do {
                try await model.createEnvironment(name: name, copyFrom: src) { s, line in
                    Task { @MainActor in if !s.isEmpty { step = s }; if !line.isEmpty { log.append(line) } }
                }
                if let created = model.registry.environments.last { await packages.refreshAllHealth(); await packages.select(created.id) }
                isPresented = false
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var working = false

    var body: some View {
        Form {
            Section("Default environment") {
                LabeledContent("Marimo") {
                    if case .ready(let v) = model.environmentStatus { Text(v).monospaced() } else { Text("Not installed").foregroundStyle(.secondary) }
                }
                LabeledContent("Location") { Text(model.paths.venv.path).font(.caption).textSelection(.enabled).lineLimit(2) }
                HStack {
                    Button("Update Marimo") { run { await model.install(upgrade: true) } }
                    Button("Rebuild Default Environment", role: .destructive) { run { await model.rebuildEnvironment() } }
                    if working { ProgressView().controlSize(.small) }
                }.disabled(working)
                Text("Rebuilding deletes the Default environment's packages. Other environments are not touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tools") {
                let t = model.environment.locateTooling()
                LabeledContent("uv") { Text(t.uv?.path ?? "not found").font(.caption) }
                LabeledContent("python3") { Text(t.python?.path ?? "not found").font(.caption) }
            }
            if case .failed(let message) = model.environmentStatus {
                Section("Last error") { Text(message).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ work: @escaping () async -> Void) { working = true; Task { await work(); working = false } }
}
