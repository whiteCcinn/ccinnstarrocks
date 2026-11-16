import Foundation

/// Where a load job row came from.
public enum LoadSource: String, Sendable, Hashable {
    /// `information_schema.loads` (or `SHOW LOAD`): jobs the FE still keeps in memory.
    case live
    /// `_statistics_.loads_history`: jobs persisted after they left FE memory (StarRocks 3.3+).
    case history
}

/// What to look for in load jobs (design D1). The same filter yields the server-side predicates, so jobs
/// beyond the newest `limit` are found, and a client-side matcher with identical semantics.
public struct LoadFilter: Sendable, Hashable {
    public enum Field: String, Sendable, CaseIterable, Identifiable {
        case any, label, database, table, state, type, error, jobID, user

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .any: "Any field"
            case .label: "Label"
            case .database: "Database"
            case .table: "Table"
            case .state: "State"
            case .type: "Type"
            case .error: "Error message"
            case .jobID: "Job ID"
            case .user: "User"
            }
        }

        /// Column expressions searched for this field (`information_schema.loads` and `loads_history` agree).
        var columns: [String] {
            switch self {
            case .any: Field.allCases.filter { $0 != .any }.flatMap(\.columns)
            case .label: ["LABEL"]
            case .database: ["DB_NAME"]
            case .table: ["TABLE_NAME"]
            case .state: ["STATE"]
            case .type: ["TYPE"]
            case .error: ["ERROR_MSG"]
            case .jobID: ["CAST(ID AS VARCHAR)"]
            case .user: ["USER"]
            }
        }

        /// The job's values for this field, matching `columns`.
        func values(of job: LoadJob) -> [String?] {
            switch self {
            case .any: Field.allCases.filter { $0 != .any }.flatMap { $0.values(of: job) }
            case .label: [job.label]
            case .database: [job.database]
            case .table: [job.table]
            case .state: [job.state]
            case .type: [job.type]
            case .error: [job.errorMessage]
            case .jobID: [job.jobID]
            case .user: [job.user]
            }
        }
    }

    public enum StateFilter: String, Sendable, CaseIterable, Identifiable {
        case all, active, finished, cancelled

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .all: "All states"
            case .active: "Active"
            case .finished: "Finished"
            case .cancelled: "Cancelled"
            }
        }
    }

    /// Internal databases whose loads are hidden unless chosen explicitly (statistics jobs run every minute).
    public static let systemDatabases = ["_statistics_"]

    public var keyword: String
    public var field: Field
    /// `nil` = all user databases.
    public var database: String?
    /// Raw `TYPE` value such as `STREAM_LOAD`; `nil` = every type.
    public var type: String?
    public var state: StateFilter
    public var includeSystemDatabases: Bool
    public var limit: Int

    public init(keyword: String = "", field: Field = .any, database: String? = nil, type: String? = nil, state: StateFilter = .all,
                includeSystemDatabases: Bool = false, limit: Int = 500) {
        self.keyword = keyword
        self.field = field
        self.database = database
        self.type = type
        self.state = state
        self.includeSystemDatabases = includeSystemDatabases
        self.limit = limit
    }

    public var normalizedKeyword: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var clampedLimit: Int { max(1, min(limit, 10_000)) }

    /// Keyword and type predicates: the ones that may name a column an older version lacks (design D2).
    public var hasRefinements: Bool { !normalizedKeyword.isEmpty || type != nil }

    /// How much of the filter the server is asked to apply (design D2): everything, everything but the keyword and
    /// type, or only the state (StarRocks 3.1/3.2 name the database column `DATABASE_NAME` and lack `ID` and `USER`).
    public enum ServerScope: Sendable, CaseIterable {
        case full, base, stateOnly
    }

    public func predicates(includingRefinements: Bool = true) -> [String] {
        predicates(scope: includingRefinements ? .full : .base)
    }

    public func predicates(scope: ServerScope) -> [String] {
        var predicates: [String] = []
        if scope == .stateOnly {
            // Only STATE exists under the same name in every version.
        } else if let database {
            predicates.append("DB_NAME = \(SQLText.literal(database))")
        } else if !includeSystemDatabases {
            let names = Self.systemDatabases.map(SQLText.literal).joined(separator: ", ")
            predicates.append("(DB_NAME IS NULL OR DB_NAME NOT IN (\(names)))")
        }
        switch state {
        case .all: break
        case .active: predicates.append("STATE NOT IN ('FINISHED', 'CANCELLED')")
        case .finished: predicates.append("STATE = 'FINISHED'")
        case .cancelled: predicates.append("STATE = 'CANCELLED'")
        }
        guard scope == .full else { return predicates }
        if let type { predicates.append("TYPE = \(SQLText.literal(type))") }
        let keyword = normalizedKeyword
        if !keyword.isEmpty {
            // INSTR instead of LIKE: `%`, `_` and `\` in the keyword stay literal.
            let needle = "LOWER(\(SQLText.literal(keyword)))"
            let terms = field.columns.map { "INSTR(LOWER(\($0)), \(needle)) > 0" }
            predicates.append(terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " OR ") + ")")
        }
        return predicates
    }

    /// Newest-first query over `table` (`information_schema.loads` or `_statistics_.loads_history`).
    public func sql(from table: String, includingRefinements: Bool = true) -> String {
        sql(from: table, scope: includingRefinements ? .full : .base)
    }

    public func sql(from table: String, scope: ServerScope) -> String {
        let predicates = predicates(scope: scope)
        var sql = "SELECT * FROM \(table)"
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        return sql + " ORDER BY CREATE_TIME DESC LIMIT \(clampedLimit)"
    }

    /// Client-side equivalent of `predicates()`. Case-insensitive matching is a superset of the server's
    /// `LOWER`, so filtering server results again never drops a row the server matched.
    public func matches(_ job: LoadJob) -> Bool {
        if let database {
            guard job.database == database else { return false }
        } else if !includeSystemDatabases, let jobDatabase = job.database, Self.systemDatabases.contains(jobDatabase) {
            return false
        }
        let state = job.state.uppercased()
        switch self.state {
        case .all: break
        case .active: guard job.isActive else { return false }
        case .finished: guard state == "FINISHED" else { return false }
        case .cancelled: guard state == "CANCELLED" else { return false }
        }
        if let type, job.type?.caseInsensitiveCompare(type) != .orderedSame { return false }
        let keyword = normalizedKeyword
        guard !keyword.isEmpty else { return true }
        return field.values(of: job).contains { $0?.range(of: keyword, options: [.caseInsensitive]) != nil }
    }
}

/// Load jobs found by `StarRocksClient.searchLoads`.
public struct LoadSearchResult: Sendable {
    public var jobs: [LoadJob]
    /// A source returned `limit` rows, so older matches may exist.
    public var reachedLimit: Bool
    /// The server rejected the keyword/type predicates; they were applied to the newest jobs only.
    public var filteredOnClient: Bool
    /// Why `_statistics_.loads_history` could not be searched, when it was requested.
    public var historyError: String?

    public init(jobs: [LoadJob], reachedLimit: Bool, filteredOnClient: Bool = false, historyError: String? = nil) {
        self.jobs = jobs
        self.reachedLimit = reachedLimit
        self.filteredOnClient = filteredOnClient
        self.historyError = historyError
    }

    /// De-duplicates by job (live rows win over history), sorts newest first (stable) and cuts to `limit` (design D4).
    public static func merge(live: [LoadJob], history: [LoadJob], limit: Int) -> (jobs: [LoadJob], reachedLimit: Bool) {
        let limit = max(1, limit)
        var seen = Set<String>()
        var unique: [LoadJob] = []
        unique.reserveCapacity(live.count + history.count)
        for job in live + history where seen.insert(job.dedupeKey).inserted {
            unique.append(job)
        }
        let ordered = unique.enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element.createTime ?? "", rhs.element.createTime ?? "")
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
        let reached = live.count >= limit || history.count >= limit || ordered.count > limit
        return (Array(ordered.prefix(limit)), reached)
    }
}

extension LoadJob {
    /// Job ids are unique per cluster; jobs without one (some `SHOW LOAD` versions) are keyed by label.
    var dedupeKey: String { jobID.isEmpty ? "label:" + label : "id:" + jobID }
}
