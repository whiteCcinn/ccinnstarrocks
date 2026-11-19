import Darwin
import Foundation
import os
import Testing
@testable import CcinnStarRocksKit

private func folder(_ configText: String? = nil) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sr-git-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
    if let configText { try Data(configText.utf8).write(to: url.appendingPathComponent(".git/config")) }
    return url
}

/// `body` on a thread of its own; `.timedOut` when it has not returned after `seconds` (a blocking read would hang the test).
private enum Outcome: Equatable { case returned(String?), timedOut }

private func outcome(within seconds: Double, _ body: @escaping @Sendable () -> String?) async -> Outcome {
    await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Outcome, Never>?>(initialState: continuation)
        let finish = { @Sendable (result: Outcome) -> Void in
            pending.withLock { (waiting: inout CheckedContinuation<Outcome, Never>?) -> Void in
                waiting?.resume(returning: result)
                waiting = nil
            }
        }
        Thread { finish(.returned(body())) }.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(.timedOut) }
    }
}

@Suite("Knowledge: a project's git remote")
struct KnowledgeGitRemoteTests {
    @Test func theOriginURLIsReadWithoutCredentials() throws {
        let checkout = try folder("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://user:secret@github.com/acme/api.git\n")
        defer { try? FileManager.default.removeItem(at: checkout) }
        #expect(KnowledgeMCP.gitRemote(of: checkout.path) == "https://github.com/acme/api.git")
    }

    // `link_project` takes a path from an AI session: a checkout's .git/config may be anything.
    @Test func onlyABoundedRegularFileIsRead() async throws {
        let fifo = try folder()
        defer { try? FileManager.default.removeItem(at: fifo) }
        #expect(mkfifo(fifo.appendingPathComponent(".git/config").path, 0o600) == 0)
        let path = fifo.path
        #expect(await outcome(within: 5) { KnowledgeMCP.gitRemote(of: path) } == .returned(nil), "a FIFO is not read (it would block)")

        let link = try folder()
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(atPath: link.appendingPathComponent(".git/config").path, withDestinationPath: "/dev/zero")
        let linkPath = link.path
        #expect(await outcome(within: 5) { KnowledgeMCP.gitRemote(of: linkPath) } == .returned(nil), "a link to a device is not followed")

        let huge = try folder(String(repeating: "#", count: 200_000) + "\n[remote \"origin\"]\n\turl = https://github.com/acme/api.git\n")
        defer { try? FileManager.default.removeItem(at: huge) }
        #expect(KnowledgeMCP.gitRemote(of: huge.path) == nil, "an oversized config is not read")
    }
}
