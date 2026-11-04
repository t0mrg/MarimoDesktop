import SwiftUI
import AppKit
import MarimoCore

/// Native variable browser fed by the kiosk mirror of the active notebook.
struct VariablesView: View {
    let session: NotebookSession?
    @State private var query = ""

    private var filtered: [Variable] {
        let all = session?.variables ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.datatype ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter variables", text: $query).textFieldStyle(.plain)
            }
            .padding(8).glassEffect(.regular, in: .rect(cornerRadius: 10)).padding(10)

            if session == nil {
                placeholder("No notebook open", "Open a notebook to see its variables.")
            } else if filtered.isEmpty {
                placeholder(query.isEmpty ? "No variables yet" : "No matches",
                            query.isEmpty ? "Run a cell and its variables will appear here." : "Try a different filter.")
            } else {
                List(filtered) { v in
                    VariableRow(variable: v, cellLabel: cellLabel(v))
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Variables")
    }

    private func cellLabel(_ v: Variable) -> String? {
        guard let id = v.declaredBy.first, let n = session?.variableTable.cellNumber(id) else { return nil }
        return "Cell \(n)"
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "curlybraces", description: Text(detail))
    }
}

struct VariableRow: View {
    let variable: Variable
    let cellLabel: String?
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(variable.value ?? variable.name, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(variable.name).font(.body.monospaced().weight(.semibold))
                    if let t = variable.datatype {
                        Text(t).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: .capsule)
                    }
                    Spacer()
                    if copied { Label("Copied", systemImage: "checkmark").font(.caption).foregroundStyle(.green) }
                    else if let cellLabel { Text(cellLabel).font(.caption).foregroundStyle(.secondary) }
                }
                if let value = variable.value {
                    Text(value).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Click to copy the value")
        .accessibilityLabel("\(variable.name), \(variable.datatype ?? "unknown type")")
    }
}
