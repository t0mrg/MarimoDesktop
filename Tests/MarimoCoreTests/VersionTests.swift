import Testing
@testable import MarimoCore

@Test func versionIsSet() { #expect(!MarimoCoreInfo.version.isEmpty) }
