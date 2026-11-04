import Testing
import Foundation
@testable import MarimoCore

// Fixtures captured from a live marimo 0.25.2 kiosk connection.
private let ready = #"{"op":"kernel-ready","data":{"op":"kernel-ready","cell_ids":["Hbol","Xyzw"],"codes":["a","b"]}}"#
private let vars = #"{"op":"variables","data":{"op":"variables","variables":[{"name":"name","declared_by":["Hbol"],"used_by":[]},{"name":"x","declared_by":["Hbol"],"used_by":["Xyzw"]}]}}"#
private let values = #"{"op":"variable-values","data":{"op":"variable-values","variables":[{"name":"name","value":"hello","datatype":"str"},{"name":"x","value":"42","datatype":"int"}]}}"#

@Test func tableCombinesDeclarationsAndValues() {
    var t = VariableTable()
    let a = t.apply(message: ready), b = t.apply(message: vars), c = t.apply(message: values)
    #expect(a && b && c)
    #expect(t.sorted.map(\.name) == ["name", "x"])
    let x = t.variables["x"]
    #expect(x?.value == "42" && x?.datatype == "int" && x?.usedBy == ["Xyzw"])
    #expect(t.cellNumber("Xyzw") == 2)
}

@Test func valuesArrivingBeforeDeclarationsAreKept() {
    var t = VariableTable()
    t.apply(message: values); t.apply(message: vars)
    #expect(t.variables["name"]?.value == "hello")
}

@Test func removedVariablesDisappear() {
    var t = VariableTable()
    t.apply(message: vars); t.apply(message: values)
    t.apply(message: #"{"op":"variables","data":{"variables":[{"name":"x","declared_by":["Hbol"],"used_by":[]}]}}"#)
    #expect(t.variables.keys.sorted() == ["x"])
}

@Test func ignoresUnrelatedAndMalformedMessages() {
    var t = VariableTable()
    let a = t.apply(message: #"{"op":"cell-op","data":{}}"#), b = t.apply(message: "not json")
    #expect(!a && !b)
}

@Test func privateNamesSortLast() {
    var t = VariableTable()
    t.apply(message: #"{"op":"variables","data":{"variables":[{"name":"_tmp"},{"name":"b"},{"name":"a"}]}}"#)
    #expect(t.sorted.map(\.name) == ["a", "b", "_tmp"])
}

@Test func websocketURLIsKioskAndEncoded() throws {
    let url = try #require(VariableMirror.websocketURL(port: 9, file: URL(filePath: "/tmp/my nb.py"), sessionID: "s"))
    #expect(url.absoluteString.contains("kiosk=true") && url.absoluteString.contains("my%20nb.py"))
}
