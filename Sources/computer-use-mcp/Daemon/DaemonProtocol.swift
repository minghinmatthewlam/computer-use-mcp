// Wire protocol between serve shims and the engine daemon: newline-delimited
// JSON over a unix domain socket. One connection per agent session; the
// connection is the session identity for app leases.

import Foundation
import MCP
#if os(macOS)
import Security
#else
import Glibc
#endif

func daemonSocketPath() -> String {
    daemonRuntimePaths().socket
}

func daemonLockPath() -> String {
    daemonRuntimePaths().lock
}

func daemonLogPath() -> String {
    daemonRuntimePaths().log
}

func daemonSecretPath() -> String {
    daemonRuntimePaths().secret
}

func daemonRuntimePaths(createRuntimeDirectory: Bool = true) -> DaemonRuntimePaths {
    let directory = runtimeDirectoryURL(create: createRuntimeDirectory)
    return DaemonRuntimePaths(
        directory: directory.path,
        socket: directory.appendingPathComponent(DaemonPathComponent.socket).path,
        lock: directory.appendingPathComponent(DaemonPathComponent.lock).path,
        log: directory.appendingPathComponent(DaemonPathComponent.log).path,
        secret: directory.appendingPathComponent(DaemonPathComponent.secret).path
    )
}

func runtimeDirectory() -> URL {
    runtimeDirectoryURL(create: true)
}

struct DaemonRuntimePaths: Codable {
    let directory: String
    let socket: String
    let lock: String
    let log: String
    let secret: String
}

private func runtimeDirectoryURL(create: Bool) -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("computer-use-mcp", isDirectory: true)
    if create {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    return directory
}

private enum DaemonPathComponent {
    static let socket = "daemon.sock"
    static let lock = "daemon.lock"
    static let log = "daemon.log"
    static let secret = "daemon.secret"
}

struct DaemonRequest: Codable, Sendable {
    var id: Int
    /// "hello" (handshake), "shutdown", or a tool name.
    var method: String
    var arguments: [String: Value]? = nil
    /// Shim version, sent with "hello" so a stale daemon can be replaced.
    var version: String? = nil
    /// Shared local bearer token proving the client read the per-user daemon secret.
    var authToken: String? = nil
    /// Shim executable mtime, sent with "hello" (see executableBuildStamp).
    var buildStamp: Double? = nil
}

struct DaemonResponse: Codable, Sendable {
    var id: Int
    var isError: Bool? = nil
    var content: [DaemonContent]? = nil
    var _meta: Metadata? = nil
    var version: String? = nil
    /// Present and true only after the daemon accepted the auth token.
    var authenticated: Bool? = nil
    /// Daemon executable mtime (see executableBuildStamp).
    var buildStamp: Double? = nil
}

/// Whether a shim should keep this daemon ("newest build wins"). Same semantic
/// version and a daemon build stamp at least as new as the local binary.
func daemonHandshakeAccepts(
    replyVersion: String?,
    replyAuthenticated: Bool?,
    replyBuildStamp: Double?,
    localVersion: String,
    localBuildStamp: Double
) -> Bool {
    replyVersion == localVersion
        && replyAuthenticated == true
        && (replyBuildStamp ?? 0) >= localBuildStamp
}

/// Major version component (`"0.4.1"` → `"0"`), used to prefer same-major
/// handovers so an older CLI never retires a newer daemon across majors.
func daemonMajorVersion(_ version: String) -> String {
    String(version.split(separator: ".").first ?? Substring(version))
}

func daemonSameMajorVersion(_ lhs: String, _ rhs: String) -> Bool {
    daemonMajorVersion(lhs) == daemonMajorVersion(rhs)
}

/// Whether this client may ask the daemon to shut down. Only a strictly newer
/// local build (and preferably the same major version) may retire an older
/// daemon. Equal or older clients must defer.
func daemonClientShouldRequestShutdown(
    replyVersion: String?,
    replyBuildStamp: Double?,
    localVersion: String,
    localBuildStamp: Double
) -> Bool {
    let daemonStamp = replyBuildStamp ?? 0
    guard localBuildStamp > daemonStamp else { return false }
    // Legacy daemons omit buildStamp — a current client may retire them once.
    guard let replyVersion, replyBuildStamp != nil else { return true }
    return daemonSameMajorVersion(replyVersion, localVersion)
}

/// Whether the daemon should honor a shutdown request. The requester must prove
/// a strictly newer buildStamp; equal/older requesters are refused.
func daemonAllowsShutdown(requesterBuildStamp: Double?, daemonBuildStamp: Double) -> Bool {
    (requesterBuildStamp ?? 0) > daemonBuildStamp
}

/// Message when a client cannot accept the running daemon and must not kill it.
func daemonUpgradeRequiredMessage(daemonVersion: String, localVersion: String) -> String {
    "Engine daemon is newer (\(daemonVersion)); upgrade this CLI from \(localVersion) to match."
}

/// Default per-request RPC deadline (seconds). Generous enough for slow AX /
/// capture calls; override with `daemon_rpc_timeout` / COMPUTER_USE_MCP_DAEMON_RPC_TIMEOUT.
func daemonRPCTimeoutSeconds() -> Double {
    Config.double("daemon_rpc_timeout") ?? Double(DaemonProtocolLimits.defaultRPCTimeoutSeconds)
}

/// Tracks malformed newline frames against the shared budget. Returns true when
/// the connection should close (`count > maxFrames`).
struct DaemonMalformedFrameBudget: Equatable {
    private(set) var count = 0
    let maxFrames: Int

    init(maxFrames: Int = DaemonProtocolLimits.maxMalformedFrames) {
        self.maxFrames = maxFrames
    }

    mutating func record() -> Bool {
        count += 1
        return count > maxFrames
    }
}

/// In-flight RPC id table. Completing or failing one id never touches others;
/// `takeAll` is reserved for connection drop.
struct DaemonPendingRegistry<Handler> {
    private var handlers: [Int: Handler] = [:]

    var count: Int { handlers.count }
    var ids: Set<Int> { Set(handlers.keys) }

    mutating func store(id: Int, handler: Handler) {
        handlers[id] = handler
    }

    mutating func take(id: Int) -> Handler? {
        handlers.removeValue(forKey: id)
    }

    mutating func takeAll() -> [Handler] {
        let values = Array(handlers.values)
        handlers.removeAll()
        return values
    }
}

/// Per-connection session identity for app leases and the overlay cursor.
/// Set by the daemon around each tool Task; absent in no-daemon local dispatch.
enum DaemonSessionContext {
    @TaskLocal static var sessionID: Int32?
}

enum DaemonProtocolLimits {
    static let maxRequestFrameBytes = 1_048_576
    static let maxResponseFrameBytes = 32 * 1_048_576
    static let readChunkBytes = 64 * 1024
    static let maxMalformedFrames = 3
    static let maxUnauthenticatedFailures = 3
    static let authenticationTimeoutSeconds = 5
    static let maxConcurrentConnections = 64
    /// Default wall-clock wait for one daemon RPC reply (see daemonRPCTimeoutSeconds).
    static let defaultRPCTimeoutSeconds = 120
}

enum DaemonProtocolViolation: Error, Equatable {
    case frameTooLarge(maxBytes: Int)
}

enum DaemonDecodedFrame<Message> {
    case message(Message)
    case malformed
}

struct DaemonLineBuffer<Message: Decodable> {
    private var buffer = Data()
    private let maxFrameBytes: Int
    private let decoder: JSONDecoder

    init(maxFrameBytes: Int = DaemonProtocolLimits.maxRequestFrameBytes, decoder: JSONDecoder = JSONDecoder()) {
        self.maxFrameBytes = maxFrameBytes
        self.decoder = decoder
    }

    mutating func append<C: Collection>(contentsOf bytes: C) throws -> [DaemonDecodedFrame<Message>] where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [DaemonDecodedFrame<Message>] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            guard line.count <= maxFrameBytes else {
                throw DaemonProtocolViolation.frameTooLarge(maxBytes: maxFrameBytes)
            }
            buffer.removeSubrange(...newline)

            if let message = try? decoder.decode(Message.self, from: Data(line)) {
                frames.append(.message(message))
            } else {
                frames.append(.malformed)
            }
        }

        guard buffer.count <= maxFrameBytes else {
            throw DaemonProtocolViolation.frameTooLarge(maxBytes: maxFrameBytes)
        }
        return frames
    }
}

final class DaemonConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConnections: Int
    private var connections = 0

    init(maxConnections: Int) {
        self.maxConnections = maxConnections
    }

    func tryOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connections < maxConnections else {
            return false
        }
        connections += 1
        return true
    }

    func close() {
        lock.lock()
        connections = max(0, connections - 1)
        lock.unlock()
    }

    var currentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }
}

/// Tool.Content is not Codable in a stable wire shape; mirror the two kinds
/// this server produces.
struct DaemonContent: Codable, Sendable {
    var type: String  // "text" | "image"
    var text: String?
    var data: String?  // base64
    var mimeType: String?

    static func from(_ content: Tool.Content) -> DaemonContent {
        switch content {
        case .text(let text, _, _):
            return DaemonContent(type: "text", text: text)
        case .image(let data, let mimeType, _, _):
            return DaemonContent(type: "image", data: data, mimeType: mimeType)
        default:
            return DaemonContent(type: "text", text: "[unsupported content type]")
        }
    }

    var asToolContent: Tool.Content {
        if type == "image", let data {
            return .image(data: data, mimeType: mimeType ?? "image/png", annotations: nil, _meta: nil)
        }
        return .text(text: text ?? "", annotations: nil, _meta: nil)
    }
}

extension DaemonResponse {
    static func from(_ result: CallTool.Result, id: Int) -> DaemonResponse {
        DaemonResponse(id: id, isError: result.isError, content: result.content.map(DaemonContent.from), _meta: result._meta)
    }

    var asCallToolResult: CallTool.Result {
        .init(content: (content ?? []).map(\.asToolContent), isError: isError, _meta: _meta)
    }
}

/// Append one JSON line to a socket fd. Writes from concurrent responders are
/// serialized by the caller. Returns false when the peer is gone.
func writeJSONLine<T: Encodable>(_ value: T, to fd: Int32) -> Bool {
    guard var data = try? JSONEncoder().encode(value) else { return false }
    data.append(0x0A)
    return data.withUnsafeBytes { buffer in
        var sent = 0
        while sent < buffer.count {
            let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

enum DaemonAuthError: Error, CustomStringConvertible {
    case randomFailed
    case writeFailed(String)

    var description: String {
        switch self {
        case .randomFailed:
            return "Could not generate a daemon auth token."
        case .writeFailed(let path):
            return "Could not write daemon auth token at \(path)."
        }
    }
}

func daemonAuthToken() throws -> String {
    let path = daemonSecretPath()
    if let token = readDaemonAuthToken(path: path) {
        return token
    }

    let token = try generateDaemonAuthToken()
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if fd >= 0 {
        let data = Data((token + "\n").utf8)
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        close(fd)
        if wrote {
            return token
        }
        unlink(path)
        throw DaemonAuthError.writeFailed(path)
    }

    if errno == EEXIST, let token = readDaemonAuthToken(path: path) {
        return token
    }
    throw DaemonAuthError.writeFailed(path)
}

private func readDaemonAuthToken(path: String) -> String? {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

private func generateDaemonAuthToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    #if os(macOS)
    let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
        throw DaemonAuthError.randomFailed
    }
    #else
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: .min ... .max)
    }
    #endif
    return Data(bytes).base64EncodedString()
}

func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var mismatch = left.count ^ right.count
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? Int(left[index]) : 0
        let b = index < right.count ? Int(right[index]) : 0
        mismatch |= a ^ b
    }
    return mismatch == 0
}
