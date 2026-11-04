import SwiftUI
import MarimoCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var packages = ""
    @State private var working = false

    var body: some View {
        Form {
            Section("Python environment") {
                LabeledContent("Marimo") {
                    if case .ready(let v) = model.environmentStatus { Text(v).monospaced() } else { Text("Not installed").foregroundStyle(.secondary) }
                }
                LabeledContent("Location") { Text(model.paths.venv.path).font(.caption).textSelection(.enabled).lineLimit(2) }
                HStack {
                    Button("Update Marimo") { run { await model.install(upgrade: true) } }
                    Button("Rebuild Environment", role: .destructive) { run { await model.rebuildEnvironment() } }
                    if working { ProgressView().controlSize(.small) }
                }
                .disabled(working)
            }
            Section("Extra packages") {
                TextField("e.g. pandas numpy altair", text: $packages)
                Button("Install") {
                    let list = packages.split(separator: " ").map(String.init)
                    run { await model.install(extraPackages: list); packages = "" }
                }.disabled(packages.trimmingCharacters(in: .whitespaces).isEmpty || working)
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
        .formStyle(.grouped).frame(width: 520, height: 460)
    }

    private func run(_ work: @escaping () async -> Void) {
        working = true
        Task { await work(); working = false }
    }
}
