import SwiftUI
import WebKit
import Observation
import MarimoCore

/// One open notebook tab: owns its marimo server process and its web view.
@Observable @MainActor
final class NotebookSession: Identifiable {
    enum State: Equatable { case starting, running, failed(String) }

    let id = UUID()
    private(set) var file: URL
    private(set) var state: State = .starting
    private(set) var server: MarimoServer?
    let webView: WKWebView
    private let navigationDelegate = NavigationGuard()
    private var startTask: Task<Void, Never>?
    private var mirror: VariableMirror?
    private(set) var variables: [Variable] = []
    private(set) var variableTable = VariableTable()
    var log: [String] { server?.log.all ?? [] }

    var title: String { file.deletingPathExtension().lastPathComponent }

    init(file: URL) {
        self.file = file
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.navigationDelegate = navigationDelegate
        navigationDelegate.onFinish = { [weak self] in self?.startMirror() }
        webView.setValue(false, forKey: "drawsBackground")
    }

    func start(paths: AppPaths, registry: PIDRegistry) {
        state = .starting
        stopMirror()
        variables = []
        startTask?.cancel()
        let file = file
        startTask = Task { [weak self] in
            do {
                let server = try await MarimoServer.launch(file: file, paths: paths, registry: registry)
                guard let self, !Task.isCancelled else { server.terminate(); return }
                self.server = server
                self.navigationDelegate.allowedPort = server.port
                server.onExit { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.state == .running else { return }
                        self.state = .failed("Marimo stopped unexpectedly (status \(status)).\n\(server.log.tail())")
                    }
                }
                self.state = .running
                self.webView.load(URLRequest(url: server.url))
            } catch is CancellationError {
                return
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-points this tab at another file (after Save As): stop the old server, start a new one.
    func switchFile(to url: URL, paths: AppPaths, registry: PIDRegistry) {
        stop()
        file = url
        start(paths: paths, registry: registry)
    }

    /// Starts mirroring once the web view has loaded, so the primary session exists first.
    private func startMirror() {
        guard let server, mirror == nil else { return }
        let mirror = VariableMirror(port: server.port, file: file) { [weak self] vars, table in
            Task { @MainActor in self?.variables = vars; self?.variableTable = table }
        }
        self.mirror = mirror
        mirror.start()
    }

    private func stopMirror() { mirror?.stop(); mirror = nil }

    func stop() {
        stopMirror()
        startTask?.cancel()
        server?.terminate()
        server = nil
    }

    func stopAndWait() { stopMirror(); startTask?.cancel(); server?.terminateAndWait() }

    /// Asks marimo's own frontend to save (⌘S). It owns the unsaved cell edits.
    func requestSave() async {
        let js = "document.dispatchEvent(new KeyboardEvent('keydown',{key:'s',code:'KeyS',metaKey:true,bubbles:true,cancelable:true}));"
        _ = try? await webView.evaluateJavaScript(js)
        try? await Task.sleep(for: .milliseconds(800))   // let the save round-trip finish
    }
}

/// Keeps the web view on its own loopback origin; everything else opens in the default browser.
final class NavigationGuard: NSObject, WKNavigationDelegate {
    nonisolated(unsafe) var allowedPort: Int = 0
    nonisolated(unsafe) var onFinish: (@MainActor () -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { onFinish?() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let local = (url.host == "127.0.0.1" || url.host == "localhost") && url.port == allowedPort
        if local || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
            decisionHandler(.allow)
        } else {
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}

struct WebNotebookView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
