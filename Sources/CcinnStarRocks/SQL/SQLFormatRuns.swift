import CcinnStarRocksKit
import Foundation
import Observation

/// A tab's Format SQL runs: at most one at a time, formatted off the main actor, made obsolete by a newer run or by a
/// real edit, and a short notice in the status bar whenever a run changes nothing.
@MainActor
@Observable
final class SQLFormatRuns {
    private(set) var isRunning = false
    /// Why the last run changed nothing; cleared after a few seconds.
    private(set) var notice: String?
    @ObservationIgnored private var job: Task<SQLFormatEdit?, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// Runs `work` off the main actor (it may check `Task.isCancelled`), then `apply` on the main actor with its result,
    /// unless the run was cancelled meanwhile. Cancels a run still in flight.
    func start(_ work: @escaping @Sendable () -> SQLFormatEdit?, apply: @escaping @MainActor (SQLFormatEdit?) -> Void) {
        cancel()
        let job = Task.detached(priority: .userInitiated) { work() }
        self.job = job
        isRunning = true
        task = Task { [weak self] in
            let edit = await job.value
            guard !Task.isCancelled, let self else { return }
            self.job = nil
            self.task = nil
            self.isRunning = false
            apply(edit)
        }
    }

    func cancel() {
        job?.cancel()
        task?.cancel()
        job = nil
        task = nil
        isRunning = false
    }

    /// The editor text was assigned. Only a real change makes a running format obsolete: re-assigning the same text
    /// (a deferred report of pending edits) is not an edit.
    func textChanged(from old: String, to new: String) {
        guard isRunning, old != new else { return }
        cancel()
        note("Format SQL skipped: the text changed")
    }

    func note(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
