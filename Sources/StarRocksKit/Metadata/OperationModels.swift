import Foundation

/// A client session on the FE (`SHOW FULL PROCESSLIST`).
public struct SessionProcess: Sendable, Hashable, Identifiable {
    public var connectionID: UInt32
    public var user: String?
    public var host: String?
    public var database: String?
    public var command: String?
    public var timeSeconds: Int64?
    public var state: String?
    public var statement: String?
    public var queryID: String?
    public var catalog: String?
    public var warehouse: String?
    public var frontend: String?
    public var isPending: Bool?

    /// Connection ids are only unique per frontend.
    public var id: String { "\(frontend ?? ""):\(connectionID)" }

    public init?(record: Record) {
        guard let id = record.int("Id").flatMap({ UInt32(exactly: $0) }) else { return nil }
        connectionID = id
        user = record.text("User")
        host = record.text("Host")
        database = record.text("Db")
        command = record.text("Command")
        timeSeconds = record.int("Time")
        state = record.text("State")
        statement = record.text("Info")
        queryID = record.text("QueryId")
        catalog = record.text("Catalog")
        warehouse = record.text("Warehouse")
        frontend = record.text("ServerName")
        isPending = record.bool("IsPending")
    }

    /// A statement is executing (not idle, not our own processlist probe).
    public var isRunningStatement: Bool {
        guard command?.lowercased() == "query", let statement, !statement.isEmpty else { return false }
        return !statement.lowercased().hasPrefix("show full processlist")
    }
}

/// A load job (Broker Load, INSERT, Spark Load, …) from `information_schema.loads` or `SHOW LOAD`.
public struct LoadJob: Sendable, Hashable, Identifiable {
    public var jobID: String
    public var label: String
    public var database: String?
    public var table: String?
    public var user: String?
    public var state: String
    public var progress: String?
    public var type: String?
    public var priority: String?
    public var scanRows: Int64?
    public var filteredRows: Int64?
    public var sinkRows: Int64?
    public var createTime: String?
    public var startTime: String?
    public var finishTime: String?
    public var errorMessage: String?
    public var trackingSQL: String?
    public var warehouse: String?

    public var id: String { jobID + label }

    public init(record: Record, database fallbackDatabase: String? = nil) {
        jobID = record.text("JOB_ID", "ID", "JobId") ?? ""
        label = record.text("LABEL", "Label") ?? ""
        database = record.text("DB_NAME") ?? fallbackDatabase
        table = record.text("TABLE_NAME")
        user = record.text("USER")
        state = record.text("STATE", "State") ?? "UNKNOWN"
        progress = record.text("PROGRESS", "Progress")
        type = record.text("TYPE", "Type")
        priority = record.text("PRIORITY", "Priority")
        scanRows = record.int("SCAN_ROWS", "ScanRows")
        filteredRows = record.int("FILTERED_ROWS", "FilteredRows")
        sinkRows = record.int("SINK_ROWS", "SinkRows")
        createTime = record.text("CREATE_TIME", "CreateTime")
        startTime = record.text("LOAD_START_TIME", "LoadStartTime")
        finishTime = record.text("LOAD_FINISH_TIME", "LoadFinishTime")
        errorMessage = record.text("ERROR_MSG", "ErrorMsg")
        trackingSQL = record.text("TRACKING_SQL", "TrackingSQL")
        warehouse = record.text("WAREHOUSE", "Warehouse")
    }

    public var isActive: Bool {
        ["PENDING", "QUEUEING", "LOADING", "ETL", "PREPARED", "COMMITTED"].contains(state.uppercased())
    }
}

/// A routine load (Kafka/Pulsar) job.
public struct RoutineLoadJob: Sendable, Hashable, Identifiable {
    public var jobID: String
    public var name: String
    public var database: String?
    public var table: String?
    public var state: String
    public var dataSourceType: String?
    public var createTime: String?
    public var pauseTime: String?
    public var endTime: String?
    public var currentTaskCount: Int64?
    public var statistic: String?
    public var progress: String?
    public var reasonOfStateChanged: String?
    public var errorLogURLs: String?
    public var otherMessage: String?

    public var id: String { jobID + name }

    public init(record: Record) {
        jobID = record.text("Id", "ID") ?? ""
        name = record.text("Name", "NAME") ?? ""
        database = record.text("DbName", "DB_NAME")
        table = record.text("TableName", "TABLE_NAME")
        state = record.text("State", "STATE") ?? "UNKNOWN"
        dataSourceType = record.text("DataSourceType", "DATA_SOURCE_TYPE")
        createTime = record.text("CreateTime", "CREATE_TIME")
        pauseTime = record.text("PauseTime", "PAUSE_TIME")
        endTime = record.text("EndTime", "END_TIME")
        currentTaskCount = record.int("CurrentTaskNum", "CURRENT_TASK_NUM")
        statistic = record.text("Statistic", "STATISTICS")
        progress = record.text("Progress", "PROGRESS")
        reasonOfStateChanged = record.text("ReasonOfStateChanged", "REASON_OF_STATE_CHANGED")
        errorLogURLs = record.text("ErrorLogUrls", "ERROR_LOG_URLS")
        otherMessage = record.text("OtherMsg", "OTHER_MSG")
    }

    public var isRunning: Bool { state.uppercased() == "RUNNING" || state.uppercased() == "NEED_SCHEDULE" }
    public var isPaused: Bool { state.uppercased() == "PAUSED" }
    public var isFinished: Bool { ["STOPPED", "CANCELLED"].contains(state.uppercased()) }
}

public enum RoutineLoadAction: String, Sendable, CaseIterable {
    case pause = "PAUSE"
    case resume = "RESUME"
    case stop = "STOP"
}

/// A schema change / rollup (sync MV) / optimize job.
public struct AlterJob: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case column = "COLUMN"
        case rollup = "ROLLUP"
        case optimize = "OPTIMIZE"

        public var displayName: String {
            switch self {
            case .column: "Schema change"
            case .rollup: "Rollup / sync MV"
            case .optimize: "Optimize"
            }
        }
    }

    public var kind: Kind
    public var jobID: String
    public var table: String
    public var database: String
    public var indexName: String?
    public var createTime: String?
    public var finishTime: String?
    public var state: String
    public var message: String?
    public var progress: String?

    public var id: String { kind.rawValue + jobID }

    public init(kind: Kind, database: String, record: Record) {
        self.kind = kind
        self.database = database
        jobID = record.text("JobId") ?? ""
        table = record.text("TableName") ?? ""
        indexName = record.text("IndexName", "RollupIndexName")
        createTime = record.text("CreateTime")
        finishTime = record.text("FinishTime", "FinishedTime")
        state = record.text("State") ?? "UNKNOWN"
        message = record.text("Msg")
        progress = record.text("Progress")
    }

    public var isActive: Bool { !["FINISHED", "CANCELLED"].contains(state.uppercased()) }
}

/// A FE, BE or CN node. All reported fields are kept for the detail view (columns differ by version).
public struct ClusterNode: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, CaseIterable {
        case frontend = "FE"
        case backend = "BE"
        case computeNode = "CN"
    }

    public var role: Role
    public var nodeID: String
    public var host: String
    public var isAlive: Bool
    public var version: String?
    public var lastHeartbeat: String?
    public var errorMessage: String?
    /// FE: LEADER / FOLLOWER / OBSERVER.
    public var feRole: String?
    public var tabletCount: Int64?
    public var dataUsed: Int64?
    public var totalCapacity: Int64?
    public var usedPercent: Double?
    public var cpuCores: Int64?
    public var cpuUsedPercent: Double?
    public var memoryUsedPercent: Double?
    public var runningQueries: Int64?
    public var fields: [Field]

    public struct Field: Sendable, Hashable {
        public var name: String
        public var value: String
    }

    public var id: String { role.rawValue + nodeID }

    public init(role: Role, record: Record) {
        self.role = role
        nodeID = record.text("BackendId", "ComputeNodeId", "Name", "Id") ?? "?"
        host = record.text("IP", "Host") ?? "?"
        isAlive = record.bool("Alive") ?? false
        version = record.text("Version")
        lastHeartbeat = record.text("LastHeartbeat")
        errorMessage = record.text("ErrMsg")
        feRole = record.text("Role")
        tabletCount = record.int("TabletNum")
        dataUsed = ByteSize.parse(record.text("DataUsedCapacity"))
        totalCapacity = ByteSize.parse(record.text("TotalCapacity"))
        usedPercent = record.text("UsedPct").flatMap(TextValueParsing.percent)
        cpuCores = record.int("CpuCores")
        cpuUsedPercent = record.text("CpuUsedPct").flatMap(TextValueParsing.percent)
        memoryUsedPercent = record.text("MemUsedPct").flatMap(TextValueParsing.percent)
        runningQueries = record.int("NumRunningQueries")
        fields = zip(record.lookupNames, record.values).map { Field(name: $0, value: $1 ?? "NULL") }
    }
}

/// Snapshot of everything currently executing on the cluster.
public struct ActivitySnapshot: Sendable {
    public var queries: [SessionProcess] = []
    public var loads: [LoadJob] = []
    public var taskRuns: [TaskRun] = []
    public var routineLoads: [RoutineLoadJob] = []
    public var alterJobs: [AlterJob] = []
    /// Sections that could not be loaded (usually privileges), with the reason.
    public var unavailable: [String: String] = [:]
    public var takenAt = Date()

    public init() {}

    public var totalActive: Int { queries.count + loads.count + taskRuns.count + routineLoads.count + alterJobs.count }
}
