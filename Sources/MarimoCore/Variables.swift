import Foundation

public struct Variable: Identifiable, Equatable, Sendable {
    public var name: String
    public var datatype: String?
    public var value: String?
    public var declaredBy: [String]
    public var usedBy: [String]
    public var id: String { name }
    public init(name: String, datatype: String? = nil, value: String? = nil, declaredBy: [String] = [], usedBy: [String] = []) {
        self.name = name; self.datatype = datatype; self.value = value; self.declaredBy = declaredBy; self.usedBy = usedBy
    }
}

/// Folds marimo kernel messages into a variable table. Pure and synchronous so it is easy to test.
public struct VariableTable: Sendable {
    public private(set) var variables: [String: Variable] = [:]
    public private(set) var cellOrder: [String] = []
    private var values: [String: (value: String?, datatype: String?)] = [:]

    public init() {}

    /// Sorted for display; underscore-prefixed (private) names last.
    public var sorted: [Variable] {
        variables.values.sorted {
            let a = $0.name.hasPrefix("_"), b = $1.name.hasPrefix("_")
            return a != b ? !a : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 1-based position of a cell in the notebook, for display ("Cell 3").
    public func cellNumber(_ id: String) -> Int? { cellOrder.firstIndex(of: id).map { $0 + 1 } }

    /// Returns true if the table changed.
    @discardableResult
    public mutating func apply(message: String) -> Bool {
        guard let data = message.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = root["op"] as? String else { return false }
        let payload = root["data"] as? [String: Any] ?? [:]
        switch op {
        case "kernel-ready":
            cellOrder = payload["cell_ids"] as? [String] ?? cellOrder
            return true
        case "variables":
            let list = payload["variables"] as? [[String: Any]] ?? []
            var next: [String: Variable] = [:]
            for item in list {
                guard let name = item["name"] as? String else { continue }
                let known = values[name]
                next[name] = Variable(name: name, datatype: known?.datatype, value: known?.value,
                                      declaredBy: item["declared_by"] as? [String] ?? [],
                                      usedBy: item["used_by"] as? [String] ?? [])
            }
            values = values.filter { next[$0.key] != nil }
            variables = next
            return true
        case "variable-values":
            let list = payload["variables"] as? [[String: Any]] ?? []
            for item in list {
                guard let name = item["name"] as? String else { continue }
                let entry = (value: item["value"] as? String, datatype: item["datatype"] as? String)
                values[name] = entry
                variables[name]?.value = entry.value
                variables[name]?.datatype = entry.datatype
            }
            return true
        default:
            return false
        }
    }
}

/// Joins a running notebook as a read-only "kiosk" client and reports its variables.
/// Kiosk mode is marimo's own mirroring feature, so nothing is injected into the kernel.
public final class VariableMirror: @unchecked Sendable {
    private let port: Int
    private let file: URL
    private let onUpdate: @Sendable ([Variable], VariableTable) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(port: Int, file: URL, onUpdate: @escaping @Sendable ([Variable], VariableTable) -> Void) {
        self.port = port; self.file = file; self.onUpdate = onUpdate
    }

    public static func websocketURL(port: Int, file: URL, sessionID: String) -> URL? {
        var c = URLComponents()
        c.scheme = "ws"; c.host = "127.0.0.1"; c.port = port; c.path = "/ws"
        c.queryItems = [.init(name: "session_id", value: sessionID), .init(name: "file", value: file.path),
                        .init(name: "kiosk", value: "true")]
        return c.url
    }

    /// Starts (or restarts) the connect-and-listen loop. The primary web view must connect first,
    /// so failures are retried quietly.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = Task { [port, file, onUpdate] in
            var table = VariableTable()
            while !Task.isCancelled {
                let sessionID = "md-kiosk-\(UUID().uuidString.prefix(8))"
                if let url = Self.websocketURL(port: port, file: file, sessionID: sessionID) {
                    let socket = URLSession.shared.webSocketTask(with: url)
                    socket.resume()
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            if case .string(let text) = message, table.apply(message: text) {
                                onUpdate(table.sorted, table)
                            }
                        }
                    } catch { /* closed or rejected: retry below */ }
                    socket.cancel(with: .goingAway, reason: nil)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        lock.lock(); task?.cancel(); task = nil; lock.unlock()
    }
}
