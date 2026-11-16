import Foundation
import Testing
@testable import CcinnStarRocksKit

@Suite("Window requests")
struct WindowRequestTests {
    @Test func everyRequestOpensItsOwnWindow() {
        let profile = UUID()
        // SwiftUI brings an existing window to the front when the value is equal, so two requests for the same
        // connection must differ.
        #expect(WindowRequest(profileID: profile) != WindowRequest(profileID: profile))
        #expect(WindowRequest(profileID: profile).profileID == profile)
    }

    @Test func roundTripsThroughCodable() throws {
        let request = WindowRequest(profileID: UUID())
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func decodesWithoutTheNonce() throws {
        let profile = UUID()
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"profileID":"\#(profile.uuidString)"}"#.utf8))
        #expect(decoded.profileID == profile)
    }
}
