import CcinnStarRocksKit
import Foundation
import os
import StarRocksKit
import Testing
@testable import CcinnStarRocks

@Suite("Window session", .serialized)
@MainActor
struct WindowSessionTests {
    /// Review #9: a connect started while another is in flight cancels it, and the cancelled connect's late progress
    /// never replaces the new connect's status. The first opener reports only after the test releases it (once the
    /// second connect is reporting), so the order is fixed, not timed.
    @Test func aCancelledConnectNeverOverwritesTheNewConnectsStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(repository: ProfileRepository(directory: directory, secrets: InMemorySecretStore()))
        let release = OSAllocatedUnfairLock(initialState: false)
        let firstReported = OSAllocatedUnfairLock(initialState: false)
        let session = WindowSession()
        session.opener = { profile, _, _, progress in
            if profile.host == "first" {
                // Not cancellation-aware, like a TCP connect or an ssh handshake.
                while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
                progress("first: opening tunnel")
                firstReported.withLock { $0 = true }
            } else {
                progress("second: connecting")
            }
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        session.connect(profile: ConnectionProfile(name: "First", host: "first"), store: store, password: "")
        session.connect(profile: ConnectionProfile(name: "Second", host: "second"), store: store, password: "")
        func status() -> (String, String)? {
            if case let .connecting(name, status) = session.phase { return (name, status) }
            return nil
        }
        for _ in 0..<500 where status()?.1 != "second: connecting" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status()?.0 == "Second")
        #expect(status()?.1 == "second: connecting")
        release.withLock { $0 = true }
        for _ in 0..<500 where !firstReported.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(firstReported.withLock { $0 })
        // The late report hops to the main actor; give it every chance to land.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(status()?.0 == "Second")
        #expect(status()?.1 == "second: connecting")
        session.cancelConnecting()
        guard case .connections = session.phase else {
            Issue.record("expected the connection screen")
            return
        }
    }
}
