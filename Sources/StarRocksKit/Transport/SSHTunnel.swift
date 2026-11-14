import Darwin
import Foundation
import os

public struct SSHTunnelConfiguration: Sendable, Codable, Equatable, Hashable {
    public enum Authentication: String, Sendable, Codable, CaseIterable {
        /// ssh-agent / ~/.ssh/config defaults.
        case agent
        case password
        case privateKey
    }

    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication
    public var privateKeyPath: String?

    public init(host: String, port: Int = 22, username: String, authentication: Authentication, privateKeyPath: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.privateKeyPath = privateKeyPath
    }
}

/// Local port forward through the system OpenSSH client (`/usr/bin/ssh -N -L`).
///
/// Using the system client means `~/.ssh/config`, known_hosts, ssh-agent and hardware keys all work
/// exactly as in Terminal. Passwords/passphrases are answered through `SSH_ASKPASS` by a helper
/// script that reads a 0600 temporary file, deleted as soon as the tunnel is established.
public final class SSHTunnel: Sendable {
    public let localPort: Int
    public let remote: Endpoint
    private let process: OSAllocatedUnfairLock<Process?>

    /// Every running tunnel process, so they can be stopped synchronously when the app quits.
    private static let registry = OSAllocatedUnfairLock<[Int32: Process]>(uncheckedState: [:])

    /// Supervises ssh: forwards its arguments, kills it when the app process disappears (even after a
    /// crash) or when the wrapper itself is terminated, and exits with ssh's status.
    static let watchdogScript = """
    /usr/bin/ssh "$@" &
    ssh_pid=$!
    trap 'kill "$ssh_pid" 2>/dev/null; exit 0' TERM INT HUP
    while kill -0 "$CCINNSR_PARENT_PID" 2>/dev/null && kill -0 "$ssh_pid" 2>/dev/null; do sleep 1; done
    kill "$ssh_pid" 2>/dev/null
    wait "$ssh_pid"
    """

    private init(localPort: Int, remote: Endpoint, process: Process) {
        self.localPort = localPort
        self.remote = remote
        self.process = OSAllocatedUnfairLock(uncheckedState: process)
        let pid = process.processIdentifier
        Self.registry.withLockUnchecked { $0[pid] = process }
    }

    deinit {
        close()
    }

    public var localAddress: Endpoint { Endpoint(host: "127.0.0.1", port: localPort) }

    public var isRunning: Bool {
        process.withLockUnchecked { $0?.isRunning ?? false }
    }

    public func close() {
        let running = process.withLockUnchecked { current -> Process? in
            defer { current = nil }
            return current
        }
        guard let running else { return }
        Self.registry.withLockUnchecked { _ = $0.removeValue(forKey: running.processIdentifier) }
        if running.isRunning { running.terminate() }
    }

    /// Stops every tunnel immediately (call from `applicationWillTerminate`).
    public static func terminateAll() {
        let processes = registry.withLockUnchecked { all -> [Process] in
            defer { all.removeAll() }
            return Array(all.values)
        }
        for process in processes where process.isRunning { process.terminate() }
    }

    /// Starts ssh and waits until the forwarded port accepts connections.
    public static func open(configuration: SSHTunnelConfiguration, secret: String?, remote: Endpoint,
                            timeout: Double = 20) async throws -> SSHTunnel {
        let localPort = try freeLocalPort()
        let arguments = try arguments(for: configuration, localPort: localPort, remote: remote, connectTimeout: Int(timeout))
        let askPass = try AskPassHelper.shared.path()
        // The secret is handed to askpass through a 0600 file that is deleted as soon as the tunnel is
        // up (or failed), instead of living in the environment of the long-running ssh processes.
        let secretFile = try AskPassHelper.shared.writeSecret(configuration.authentication == .agent ? nil : secret)
        defer { AskPassHelper.shared.removeSecret(secretFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdogScript, "ccinnstarrocks-ssh"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askPass
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment["CCINNSR_ASKPASS_FILE"] = secretFile.path
        environment["CCINNSR_PARENT_PID"] = String(getpid())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // Drain stderr continuously: an undrained pipe would block ssh (and every forwarded connection).
        let stderr = Pipe()
        let collector = StderrCollector()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw StarRocksError(.sshTunnel, "Could not start /usr/bin/ssh: \(error.localizedDescription)")
        }
        let tunnel = SSHTunnel(localPort: localPort, remote: remote, process: process)

        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                // Give the readability handler a moment to deliver the final bytes.
                try? await Task.sleep(for: .milliseconds(100))
                tunnel.close()
                throw StarRocksError(.sshTunnel, describeFailure(collector.text, configuration: configuration))
            }
            if canConnect(port: localPort) { return tunnel }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                tunnel.close()
                throw StarRocksError.cancelled()
            }
        }
        tunnel.close()
        throw StarRocksError(.sshTunnel, "Timed out establishing the SSH tunnel through \(configuration.host)")
    }

    // MARK: Helpers

    static func arguments(for configuration: SSHTunnelConfiguration, localPort: Int, remote: Endpoint,
                          connectTimeout: Int = 15) throws -> [String] {
        let host = configuration.host.trimmingCharacters(in: .whitespaces)
        let user = configuration.username.trimmingCharacters(in: .whitespaces)
        guard isSafeToken(host) else { throw StarRocksError(.sshTunnel, "Invalid SSH host '\(configuration.host)'") }
        guard user.isEmpty || isSafeToken(user) else { throw StarRocksError(.sshTunnel, "Invalid SSH user name '\(configuration.username)'") }
        guard (1...65535).contains(configuration.port) else { throw StarRocksError(.sshTunnel, "Invalid SSH port \(configuration.port)") }
        guard isSafeToken(remote.host) else { throw StarRocksError(.sshTunnel, "Invalid StarRocks host '\(remote.host)'") }

        let remoteHost = remote.isIPv6 ? "[\(remote.host)]" : remote.host
        var arguments = [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(max(1, connectTimeout))",
            "-o", "NumberOfPasswordPrompts=1",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remote.port)",
            "-p", String(configuration.port),
        ]
        switch configuration.authentication {
        case .agent:
            // Never answer password prompts with a stored secret in agent mode.
            arguments += ["-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no"]
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        case .privateKey:
            guard let path = configuration.privateKeyPath, !path.isEmpty else {
                throw StarRocksError(.sshTunnel, "Choose a private key file for the SSH tunnel")
            }
            // Only public-key auth: a rejected key must not fall back to sending the passphrase as a password.
            arguments += ["-i", (path as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes",
                          "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
                          "-o", "KbdInteractiveAuthentication=no"]
        }
        arguments.append(user.isEmpty ? host : "\(user)@\(host)")
        return arguments
    }

    /// Hosts and user names must not look like options and must not contain whitespace or control characters.
    private static func isSafeToken(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("-") && !token.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 } == true })
    }

    static func describeFailure(_ output: String, configuration: SSHTunnelConfiguration) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("Warning: Permanently added") && !$0.isEmpty }
        let detail = lines.last ?? "ssh exited unexpectedly"
        return "SSH tunnel through \(configuration.host):\(configuration.port) failed: \(detail)"
    }

    /// Asks the kernel for an unused port on the loopback interface.
    static func freeLocalPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StarRocksError(.sshTunnel, "Could not allocate a local port") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw StarRocksError(.sshTunnel, "Could not allocate a local port") }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw StarRocksError(.sshTunnel, "Could not allocate a local port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// Keeps the most recent stderr output of ssh (bounded) for error messages.
final class StderrCollector: Sendable {
    private static let limit = 16 * 1024
    private let buffer = OSAllocatedUnfairLock(initialState: Data())

    func append(_ data: Data) {
        buffer.withLock { buffer in
            buffer.append(data)
            if buffer.count > Self.limit { buffer = Data(buffer.suffix(Self.limit)) }
        }
    }

    var text: String { String(decoding: buffer.withLock { $0 }, as: UTF8.self) }
}

/// Writes (once per process) a tiny askpass script that prints the secret file named in the
/// environment, and manages the short-lived 0600 secret files.
final class AskPassHelper: Sendable {
    static let shared = AskPassHelper()
    private let cached = OSAllocatedUnfairLock<URL?>(initialState: nil)

    private func directory() throws -> URL {
        if let existing = cached.withLock({ $0 }), FileManager.default.fileExists(atPath: existing.path) { return existing }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnstarrocks-askpass-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        cached.withLock { $0 = directory }
        return directory
    }

    func path() throws -> String {
        let script = try directory().appendingPathComponent("askpass.sh")
        if FileManager.default.isExecutableFile(atPath: script.path) { return script.path }
        let contents = "#!/bin/sh\n[ -r \"$CCINNSR_ASKPASS_FILE\" ] && cat \"$CCINNSR_ASKPASS_FILE\"\necho\n"
        try Data(contents.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script.path
    }

    /// Creates a 0600 file holding `secret` (empty when nil).
    func writeSecret(_ secret: String?) throws -> URL {
        let file = try directory().appendingPathComponent("secret-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: Data((secret ?? "").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw StarRocksError(.sshTunnel, "Could not prepare the SSH credentials")
        }
        return file
    }

    func removeSecret(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}
