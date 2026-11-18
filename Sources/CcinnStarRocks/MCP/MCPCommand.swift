import CcinnStarRocksKit
import Darwin
import Foundation
import StarRocksKit

/// `CcinnStarRocks mcp [--profile <name|id>] [--read-only]` — a headless MCP server on stdio.
/// Only protocol messages are written to stdout; diagnostics go to stderr.
enum MCPCommand {
    static let usage = """
    Usage: CcinnStarRocks mcp [--profile <name|id>] [--read-only]

    Runs a Model Context Protocol server on stdin/stdout so AI clients (Claude Code, Codex,
    Claude Desktop, …) can use the connections you enabled for AI access in CcinnStarRocks.

      --profile <name|id>   Connection used when a tool call does not name one.
      --read-only           Treat every connection as read-only, even if read-write is allowed.

    Example (Claude Code):
      claude mcp add ccinnstarrocks -- "\(executablePath)" mcp
    """

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "CcinnStarRocks"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static func run(arguments: [String]) -> Never {
        var profile: String?
        var readOnly = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--profile":
                guard index + 1 < arguments.count else { fail("--profile needs a connection name or id") }
                profile = arguments[index + 1]
                index += 1
            case "--read-only":
                readOnly = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                fail("unknown option \(arguments[index])\n\n\(usage)")
            }
            index += 1
        }

        signal(SIGPIPE, SIG_IGN)
        let repository = ProfileRepository()
        let profiles: [ConnectionProfile]
        do {
            profiles = try repository.load()
        } catch {
            fail("could not read saved connections: \(error.localizedDescription)")
        }
        let resolver = MCPProfileResolver(profiles: profiles, defaultProfile: profile, forceReadOnly: readOnly)
        if let profile, (try? resolver.resolve(profile)) == nil {
            log("warning: connection “\(profile)” is unknown or not enabled for AI access")
        }
        log("CcinnStarRocks MCP server \(version): \(resolver.enabledProfiles.count) connection(s) enabled for AI access")

        let registry = MCPClientRegistry { profile in
            let password = repository.password(for: profile) ?? ""
            let sshSecret = profile.ssh != nil ? repository.sshSecret(for: profile) : nil
            return try await ClientOpener.open(profile: profile, password: password, sshSecret: sshSecret, poolSize: 3, forAI: true)
        }
        let provider = StarRocksMCPTools(resolver: resolver, registry: registry,
                                         audit: MCPAuditLog(directory: ProfileRepository.defaultDirectory))
        let output = StandardOutput()
        let server = MCPServer(info: MCPServerInfo(name: "ccinnstarrocks", title: "CcinnStarRocks", version: version, instructions: instructions),
                               provider: provider, send: { await output.write($0) })

        let lines = StandardInputLines.stream()
        Task {
            for await event in lines {
                switch event {
                case let .line(line):
                    await server.receive(line)
                case .oversized:
                    await output.write(JSONValue.object(["jsonrpc": "2.0", "id": .null,
                                                         "error": ["code": -32600, "message": "Message exceeds the 4 MB limit"]]).serialized())
                }
            }
            // stdin closed: the client went away.
            await server.shutdown()
            await registry.closeAll()
            SSHTunnel.terminateAll()
            exit(0)
        }
        for terminating in [SIGTERM, SIGINT] {
            signal(terminating, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: terminating, queue: .main)
            source.setEventHandler {
                SSHTunnel.terminateAll()
                exit(0)
            }
            source.resume()
            SignalSources.retain(source)
        }
        dispatchMain()
    }

    static let instructions = """
    CcinnStarRocks gives you access to the StarRocks clusters the user enabled for AI access. \
    Start with list_connections, then explore with list_databases, list_tables (shows which objects are tables, \
    async or sync materialized views, views or external tables) and describe_table. StarRocks-specific insights: \
    get_partitions, analyze_tablet_skew, get_materialized_view, get_running_tasks and list_cluster_nodes. \
    run_query executes one read-only statement (SELECT/WITH/SHOW/DESC/EXPLAIN); results are limited to 200 rows by default \
    (max 1000) and about 256 KB, so aggregate in SQL instead of fetching raw rows. Statements time out after 30 s by default. \
    execute_statement (writes) exists only for connections with read-write access.
    """

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        log("error: \(message)")
        exit(64)
    }
}

/// Keeps signal sources alive for the life of the process.
private enum SignalSources {
    nonisolated(unsafe) private static var sources: [any DispatchSourceSignal] = []
    static func retain(_ source: any DispatchSourceSignal) { sources.append(source) }
}

/// Serializes protocol output so concurrent responses never interleave.
private actor StandardOutput {
    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            // The client closed the pipe; nothing more can be delivered.
            exit(0)
        }
    }
}

/// Reads stdin on a dedicated thread (blocking reads) and frames it into lines.
private enum StandardInputLines {
    static func stream() -> AsyncStream<LineFramer.Event> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread {
                var framer = LineFramer(maxLineBytes: 4 * 1024 * 1024)
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    for event in framer.append(Array(buffer[0..<count])) { continuation.yield(event) }
                }
                continuation.finish()
            }
            thread.name = "mcp-stdin"
            thread.start()
        }
    }
}
