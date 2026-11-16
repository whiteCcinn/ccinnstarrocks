import Foundation
import Testing
@testable import CcinnStarRocksKit

@MainActor
@Suite("Window handoff")
struct WindowHandoffTests {
    @Test func aPayloadIsTakenExactlyOnce() {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(profileID: UUID(), payload: "secret")
        #expect(handoff.take(request) == "secret")
        #expect(handoff.take(request) == nil, "a second window must not reuse the connection")
        #expect(handoff.pendingCount == 0)
    }

    @Test func restoredRequestsCarryNothing() {
        // A request decoded after a relaunch (window restoration) was not created by this process.
        let handoff = WindowHandoff<String>()
        #expect(handoff.take(WindowRequest(profileID: UUID())) == nil)
    }

    @Test func requestsForTheSameProfileAreIndependent() {
        let handoff = WindowHandoff<String>()
        let profile = UUID()
        let first = handoff.request(profileID: profile, payload: "a")
        let second = handoff.request(profileID: profile, payload: "b")
        #expect(first != second)
        #expect(first.profileID == profile && second.profileID == profile)
        #expect(handoff.take(second) == "b")
        #expect(handoff.take(first) == "a")
    }
}
