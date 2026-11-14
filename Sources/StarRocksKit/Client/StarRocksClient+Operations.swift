import Foundation

/// Cluster operations: sessions, loads, routine loads, schema changes, nodes, and an activity snapshot.
extension StarRocksClient {
    public func processList() async throws -> [SessionProcess] {
        try await execute("SHOW FULL PROCESSLIST").records.compactMap(SessionProcess.init(record:))
    }

    /// Load jobs, newest first. Uses `information_schema.loads`, falling back to `SHOW LOAD` per database.
    public func loads(database: String? = nil, activeOnly: Bool = false, limit: Int = 500) async throws -> [LoadJob] {
        var predicates: [String] = []
        if let database { predicates.append("DB_NAME = \(SQLText.literal(database))") }
        if activeOnly { predicates.append("STATE NOT IN ('FINISHED', 'CANCELLED')") }
        var sql = "SELECT * FROM information_schema.loads"
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        sql += " ORDER BY CREATE_TIME DESC LIMIT \(max(1, min(limit, 10_000)))"
        do {
            return try await execute(sql).records.map { LoadJob(record: $0) }
        } catch let error as StarRocksError where error.kind == .server {
            guard let database else { throw error }
            let jobs = try await execute("SHOW LOAD FROM \(SQLText.quoteIdentifier(database))").records.map { LoadJob(record: $0, database: database) }
            return (activeOnly ? jobs.filter(\.isActive) : jobs).reversed().prefix(limit).map { $0 }
        }
    }

    public func cancelLoad(database: String, label: String) async throws {
        _ = try await execute("CANCEL LOAD FROM \(SQLText.quoteIdentifier(database)) WHERE LABEL = \(SQLText.literal(label))")
    }

    /// Routine load jobs (including stopped ones). `information_schema.routine_load_jobs` covers all
    /// databases; `SHOW ALL ROUTINE LOAD` is the per-database fallback.
    public func routineLoads(database: String? = nil) async throws -> [RoutineLoadJob] {
        var sql = "SELECT * FROM information_schema.routine_load_jobs"
        if let database { sql += " WHERE DB_NAME = \(SQLText.literal(database))" }
        do {
            return try await execute(sql).records.map(RoutineLoadJob.init(record:))
        } catch let error as StarRocksError where error.kind == .server {
            guard let database else { throw error }
            return try await execute("SHOW ALL ROUTINE LOAD FROM \(SQLText.quoteIdentifier(database))").records.map(RoutineLoadJob.init(record:))
        }
    }

    public func perform(_ action: RoutineLoadAction, routineLoad name: String, database: String) async throws {
        _ = try await execute("\(action.rawValue) ROUTINE LOAD FOR \(SQLText.qualified(database, name))")
    }

    public func alterJobs(database: String, kinds: [AlterJob.Kind] = AlterJob.Kind.allCases) async throws -> [AlterJob] {
        let target = SQLText.quoteIdentifier(database)
        var jobs: [AlterJob] = []
        var firstError: (any Error)?
        for kind in kinds {
            try Task.checkCancellation()
            do {
                let result = try await execute("SHOW ALTER TABLE \(kind.rawValue) FROM \(target)")
                jobs += result.records.map { AlterJob(kind: kind, database: database, record: $0) }
            } catch let error as StarRocksError where error.kind == .server {
                // e.g. OPTIMIZE jobs are unknown on older versions
                firstError = firstError ?? error
            }
        }
        if jobs.isEmpty, let firstError, kinds.count == 1 { throw firstError }
        return jobs.sorted { ($0.createTime ?? "") > ($1.createTime ?? "") }
    }

    public func cancelAlterJob(_ job: AlterJob) async throws {
        _ = try await execute("CANCEL ALTER TABLE \(job.kind.rawValue) FROM \(SQLText.qualified(job.database, job.table))")
    }

    public func nodes() async throws -> [ClusterNode] {
        async let frontends = tolerant("SHOW FRONTENDS")
        async let backends = tolerant("SHOW BACKENDS")
        async let computeNodes = tolerant("SHOW COMPUTE NODES")
        let (fe, be, cn) = try await (frontends, backends, computeNodes)
        guard fe != nil || be != nil || cn != nil else {
            throw StarRocksError(.server, "Listing cluster nodes requires the cluster_admin or root role")
        }
        return (fe?.records.map { ClusterNode(role: .frontend, record: $0) } ?? [])
            + (be?.records.map { ClusterNode(role: .backend, record: $0) } ?? [])
            + (cn?.records.map { ClusterNode(role: .computeNode, record: $0) } ?? [])
    }

    /// Everything currently executing: statements, loads, MV/task runs, routine loads, schema changes.
    /// Sections the user may not see are reported in `unavailable` instead of failing the snapshot.
    public func activity(databases: [String]) async -> ActivitySnapshot {
        let internalIDs = await pool.connectionIDs
        async let processes = Self.capture {
            try await self.processList().filter { $0.isRunningStatement && !internalIDs.contains($0.connectionID) }
        }
        async let loads = Self.capture { try await self.loads(activeOnly: true, limit: 500) }
        async let runs = Self.capture { try await self.taskRuns(states: ["RUNNING", "PENDING"], limit: 500) }
        async let routine = Self.capture { try await self.routineLoads().filter { !$0.isFinished } }
        async let alters = Self.capture {
            var jobs: [AlterJob] = []
            for database in databases.prefix(64) {
                try Task.checkCancellation()
                do {
                    jobs += try await self.alterJobs(database: database).filter(\.isActive)
                } catch let error as StarRocksError where error.kind == .server {
                    continue // no privilege on this database
                }
            }
            return jobs
        }

        var snapshot = ActivitySnapshot()
        switch await processes {
        case let .success(value): snapshot.queries = value
        case let .failure(error): snapshot.unavailable["Queries"] = error.message
        }
        switch await loads {
        case let .success(value): snapshot.loads = value
        case let .failure(error): snapshot.unavailable["Loads"] = error.message
        }
        switch await runs {
        case let .success(value): snapshot.taskRuns = value
        case let .failure(error): snapshot.unavailable["Task runs"] = error.message
        }
        switch await routine {
        case let .success(value): snapshot.routineLoads = value
        case let .failure(error): snapshot.unavailable["Routine loads"] = error.message
        }
        switch await alters {
        case let .success(value): snapshot.alterJobs = value
        case let .failure(error): snapshot.unavailable["Schema changes"] = error.message
        }
        snapshot.takenAt = Date()
        return snapshot
    }

    private static func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, StarRocksError> {
        do {
            return .success(try await body())
        } catch let error as StarRocksError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(StarRocksError.cancelled())
        } catch {
            return .failure(StarRocksError(.network, error.localizedDescription))
        }
    }
}
