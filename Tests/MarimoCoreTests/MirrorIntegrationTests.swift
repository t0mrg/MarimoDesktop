import Testing
import Foundation
@testable import MarimoCore

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

/// Plays the web view's role (primary session), runs a cell, and expects the mirror to see the variables.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MARIMO_INTEGRATION"] == "1"))
func mirrorSeesVariablesFromLiveNotebook() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let paths = AppPaths(root: dir)
    let pyenv = PythonEnvironment(paths: paths)
    try await pyenv.install(progress: { _, _ in })
    let nb = dir.appending(path: "nb.py")
    try """
    import marimo
    app = marimo.App()

    @app.cell
    def _():
        answer = 42
        return (answer,)
    """.write(to: nb, atomically: true, encoding: .utf8)
    let server = try await MarimoServer.launch(file: nb, environment: pyenv.defaultInfo, registry: nil)
    defer { server.terminateAndWait() }

    // Primary client first, as the real web view would be.
    let primary = URLSession.shared.webSocketTask(with: VariableMirror.websocketURL(port: server.port, file: nb, sessionID: "primary-test")!.removingKiosk())
    primary.resume()
    var cellID = ""
    for _ in 0..<20 {
        if case .string(let s) = try await primary.receive(), s.contains("\"kernel-ready\"") {
            let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
            cellID = ((obj["data"] as! [String: Any])["cell_ids"] as! [String])[0]; break
        }
    }
    #expect(!cellID.isEmpty)

    let latest = Box<[Variable]>([])
    let mirror = VariableMirror(port: server.port, file: nb) { vars, _ in latest.set(vars) }
    mirror.start(); defer { mirror.stop() }
    try await Task.sleep(for: .seconds(1.5))

    let token = try #require(await server.fetchServerToken())
    var req = URLRequest(url: server.url.appending(path: "api/kernel/run"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("primary-test", forHTTPHeaderField: "Marimo-Session-Id")
    req.setValue(token, forHTTPHeaderField: "Marimo-Server-Token")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["cellIds": [cellID], "codes": ["answer = 42"]])
    _ = try await URLSession.shared.data(for: req)

    for _ in 0..<40 where latest.get().first?.value == nil { try await Task.sleep(for: .milliseconds(250)) }
    let v = try #require(latest.get().first)
    #expect(v.name == "answer" && v.value == "42" && v.datatype == "int")
    primary.cancel()
}

extension URL {
    func removingKiosk() -> URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        c.queryItems = c.queryItems?.filter { $0.name != "kiosk" }
        return c.url!
    }
}
