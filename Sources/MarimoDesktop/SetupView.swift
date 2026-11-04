import SwiftUI
import MarimoCore

/// First-run screen: explains what is happening and shows install progress.
struct SetupView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "leaf.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
            switch model.environmentStatus {
            case .failed(let message):
                Text("Setup failed").font(.title2.bold())
                ScrollView { Text(message).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160).padding(10).background(.quaternary, in: .rect(cornerRadius: 12))
                Button("Retry") { Task { await model.install() } }.buttonStyle(.borderedProminent)
            default:
                Text("Setting up Marimo").font(.title2.bold())
                Text("Creating a private Python environment — one time only.").foregroundStyle(.secondary)
                ProgressView().controlSize(.large)
                if case .installing(let step) = model.environmentStatus { Text(step).font(.callout) }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.setupLog.joined(separator: "\n")).font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading).id("end")
                    }
                    .onChange(of: model.setupLog.count) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .frame(maxHeight: 140).padding(10).background(.quaternary, in: .rect(cornerRadius: 12))
            }
        }
        .padding(32).frame(maxWidth: 520)
    }
}
