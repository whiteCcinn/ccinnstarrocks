import Foundation

public struct MCPServerInfo: Sendable {
    public var name: String
    public var title: String
    public var version: String
    public var instructions: String

    public init(name: String, title: String, version: String, instructions: String) {
        self.name = name
        self.title = title
        self.version = version
        self.instructions = instructions
    }
}

/// A tool definition advertised through `tools/list`.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool,
                destructive: Bool = false, idempotent: Bool = true) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
    }

    var definition: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent),
                "openWorldHint": false,
            ],
        ]
    }
}

/// Outcome of a tool call. Failures are reported to the model as `isError` results.
public struct MCPToolResult: Sendable {
    public var payload: JSONValue
    public var isError: Bool

    public static func success(_ payload: JSONValue) -> MCPToolResult { MCPToolResult(payload: payload, isError: false) }
    public static func failure(_ message: String) -> MCPToolResult { MCPToolResult(payload: .string(message), isError: true) }
}

public protocol MCPToolProvider: Sendable {
    func tools() async -> [MCPTool]
    func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult
    /// A call with what the server knows about the client; defaults to `call(name:arguments:)`.
    func call(name: String, arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult
    /// Prompt templates the client may offer its user (e.g. as slash commands); none by default.
    func prompts() async -> [MCPPrompt]
    /// The text of a prompt with its arguments filled in.
    func prompt(name: String, arguments: [String: String]) async throws -> MCPPromptText
}

extension MCPToolProvider {
    public func call(name: String, arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        await call(name: name, arguments: arguments)
    }

    public func prompts() async -> [MCPPrompt] { [] }

    public func prompt(name: String, arguments: [String: String]) async throws -> MCPPromptText {
        throw MCPToolError("Unknown prompt “\(name)”.")
    }
}

/// What the server knows about the calling client.
public struct MCPCallContext: Sendable, Equatable {
    /// `clientInfo.name` from `initialize` (e.g. `claude-code`), for attribution in knowledge and the audit log.
    public var clientName: String?

    public init(clientName: String? = nil) {
        self.clientName = clientName
    }
}

/// A prompt template (MCP `prompts/list`).
public struct MCPPrompt: Sendable, Equatable {
    public struct Argument: Sendable, Equatable {
        public var name: String
        public var description: String
        public var required: Bool

        public init(name: String, description: String, required: Bool) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]

    public init(name: String, title: String, description: String, arguments: [Argument]) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }

    var definition: JSONValue {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "arguments": .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] })]
    }
}

/// A filled-in prompt (MCP `prompts/get`): one user message.
public struct MCPPromptText: Sendable, Equatable {
    public var description: String
    public var text: String

    public init(description: String, text: String) {
        self.description = description
        self.text = text
    }
}

/// MCP protocol handling (JSON-RPC 2.0) independent of the transport. Requests are handled
/// concurrently; `tools/call` runs in its own task and can be cancelled by the client.
public actor MCPServer {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let latestProtocolVersion = "2025-06-18"

    private let info: MCPServerInfo
    private let provider: any MCPToolProvider
    private let send: @Sendable (String) async -> Void
    private var protocolVersion = MCPServer.latestProtocolVersion
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var clientName: String?
    private var cancelled: Set<String> = []

    public init(info: MCPServerInfo, provider: any MCPToolProvider, send: @escaping @Sendable (String) async -> Void) {
        self.info = info
        self.provider = provider
        self.send = send
    }

    /// Handles one framed message.
    public func receive(_ line: String) async {
        let message: JSONValue
        do {
            message = try JSONValue.parse(line)
        } catch {
            await sendError(id: .null, code: -32700, message: "Parse error: \(error)")
            return
        }
        guard case let .object(members) = message else {
            await sendError(id: .null, code: -32600, message: "Invalid request: expected a JSON-RPC object (batches are not supported)")
            return
        }
        let id = members["id"]
        guard let method = members["method"]?.stringValue else {
            // Responses to server-initiated requests (none are sent) are ignored.
            if id == nil || members["result"] != nil || members["error"] != nil { return }
            await sendError(id: id ?? .null, code: -32600, message: "Invalid request: missing method")
            return
        }
        let params = members["params"]?.objectValue ?? [:]
        guard let id, id != .null else {
            await handleNotification(method, params: params)
            return
        }
        await handleRequest(id: id, method: method, params: params)
    }

    /// Waits until every in-flight tool call has finished.
    public func waitForIdle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    /// Cancels every in-flight call (used when stdin closes).
    public func shutdown() async {
        for (key, task) in inFlight {
            cancelled.insert(key)
            task.cancel()
        }
        await waitForIdle()
    }

    // MARK: Dispatch

    private func handleNotification(_ method: String, params: [String: JSONValue]) async {
        switch method {
        case "notifications/cancelled":
            guard let requestID = params["requestId"] else { return }
            let key = requestID.serialized()
            guard let task = inFlight[key] else { return }
            cancelled.insert(key)
            task.cancel()
        default:
            return // notifications/initialized and unknown notifications need no reaction
        }
    }

    private func handleRequest(id: JSONValue, method: String, params: [String: JSONValue]) async {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.latestProtocolVersion
            protocolVersion = Self.supportedProtocolVersions.contains(requested) ? requested : Self.latestProtocolVersion
            if let name = params["clientInfo"]?.objectValue?["name"]?.stringValue {
                clientName = String(name.unicodeScalars.filter { $0.properties.generalCategory != .control }.prefix(64))
            }
            var capabilities: [String: JSONValue] = ["tools": ["listChanged": false]]
            if await !provider.prompts().isEmpty { capabilities["prompts"] = ["listChanged": false] }
            await sendResult(id: id, [
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(capabilities),
                "serverInfo": ["name": .string(info.name), "title": .string(info.title), "version": .string(info.version)],
                "instructions": .string(info.instructions),
            ])
        case "ping":
            await sendResult(id: id, .object([:]))
        case "tools/list":
            let tools = await provider.tools()
            await sendResult(id: id, ["tools": .array(tools.map(\.definition))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                await sendError(id: id, code: -32602, message: "Invalid params: tools/call requires a tool name")
                return
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case let .object(members)?: arguments = members
            default:
                await sendError(id: id, code: -32602, message: "Invalid params: arguments must be an object")
                return
            }
            let key = id.serialized()
            guard inFlight[key] == nil else {
                await sendError(id: id, code: -32600, message: "Invalid request: duplicate request id")
                return
            }
            let provider = provider
            let context = MCPCallContext(clientName: clientName)
            inFlight[key] = Task {
                let result = await provider.call(name: name, arguments: arguments, context: context)
                await self.finishCall(key: key, id: id, result: result)
            }
        case "resources/list":
            await sendResult(id: id, ["resources": []])
        case "resources/templates/list":
            await sendResult(id: id, ["resourceTemplates": []])
        case "prompts/list":
            let prompts = await provider.prompts()
            await sendResult(id: id, ["prompts": .array(prompts.map(\.definition))])
        case "prompts/get":
            guard let name = params["name"]?.stringValue else {
                await sendError(id: id, code: -32602, message: "Invalid params: prompts/get requires a prompt name")
                return
            }
            var arguments: [String: String] = [:]
            for (key, value) in params["arguments"]?.objectValue ?? [:] {
                if let text = value.stringValue { arguments[key] = text }
            }
            do {
                let prompt = try await provider.prompt(name: name, arguments: arguments)
                await sendResult(id: id, ["description": .string(prompt.description),
                                          "messages": [["role": "user", "content": ["type": "text", "text": .string(prompt.text)]]]])
            } catch let error as MCPToolError {
                await sendError(id: id, code: -32602, message: error.message)
            } catch {
                await sendError(id: id, code: -32603, message: error.localizedDescription)
            }
        default:
            await sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func finishCall(key: String, id: JSONValue, result: MCPToolResult) async {
        inFlight[key] = nil
        if cancelled.remove(key) != nil { return } // the client no longer expects a response
        let text = result.payload.stringValue ?? result.payload.serialized()
        var response: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(result.isError),
        ]
        if !result.isError, protocolVersion >= "2025-06-18", case .object = result.payload {
            response["structuredContent"] = result.payload
        }
        await sendResult(id: id, .object(response))
    }

    // MARK: Output

    private func sendResult(id: JSONValue, _ result: JSONValue) async {
        await send(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).serialized())
    }

    private func sendError(id: JSONValue, code: Int64, message: String) async {
        await send(JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]).serialized())
    }
}
