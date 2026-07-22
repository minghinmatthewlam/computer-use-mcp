// `daemon` — the shared engine process.
//
// Exactly one daemon serves all agent sessions of a user (flock singleton,
// like the overlay helper). It owns accessibility, screen capture, input
// delivery, and the agent cursor; serve shims connect over a unix socket and
// forward tool calls. One engine process means sessions cannot collide on
// shared system services, and per-app leases (AppLeases) keep two sessions
// from interleaving actions inside the same app.

import Foundation
import MCP
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private let daemonConnectionLimiter = DaemonConnectionLimiter(maxConnections: DaemonProtocolLimits.maxConcurrentConnections)

func runDaemon() async -> Never {
    // Singleton: hold the lock for the daemon's lifetime; the kernel releases
    // it on exit or crash. A concurrently spawned daemon defers to the
    // incumbent.
    let lockFD = open(daemonLockPath(), O_CREAT | O_WRONLY, 0o644)
    if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        exit(0)
    }

    let authToken: String
    do {
        authToken = try daemonAuthToken()
    } catch {
        daemonLog("daemon auth setup failed: \(error)")
        exit(1)
    }

    let listenFD = bindDaemonSocket()
    DaemonState.shared.setListenFD(listenFD)
    daemonLog("daemon \(version) listening (pid \(ProcessInfo.processInfo.processIdentifier))")

    // Accept loop on its own thread (accept(2) blocks); each connection gets
    // a reader thread; each request runs as a Task through the shared
    // dispatch funnel.
    let thread = Thread {
        while true {
            let connectionFD = accept(listenFD, nil, nil)
            if connectionFD < 0 {
                if DaemonState.shared.isDraining { return }
                continue
            }
            guard isTrustedPeer(connectionFD) else {
                daemonLog("rejected daemon connection from untrusted peer")
                close(connectionFD)
                continue
            }
            guard daemonConnectionLimiter.tryOpen() else {
                daemonLog("rejected daemon connection: connection cap reached")
                close(connectionFD)
                continue
            }
            DaemonState.shared.connectionOpened()
            Thread.detachNewThread {
                let connectionTasks = DaemonConnectionTasks()
                defer {
                    connectionTasks.cancelAll()
                    Task {
                        await AppLeases.shared.dropLeases(session: connectionFD)
                        await AgentCursor.shared.dropSession(connectionFD)
                    }
                    DaemonState.shared.connectionClosed()
                    daemonConnectionLimiter.close()
                }
                serveConnection(
                    fd: connectionFD, authToken: authToken, connectionTasks: connectionTasks
                )
            }
        }
    }
    thread.start()

    scheduleIdleExit()
    // Park the main task; all work happens on connection threads and Tasks.
    while true {
        try? await Task.sleep(for: .seconds(3600))
    }
}

private func bindDaemonSocket() -> Int32 {
    let path = daemonSocketPath()
    unlink(path)  // stale socket from a dead daemon; the lock arbitrates liveness
    #if os(Linux)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { fatalError("daemon: socket() failed: \(errno)") }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bound = path.withCString { cPath -> Bool in
        withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            guard strlen(cPath) < sunPath.count else { return false }
            strcpy(sunPath.baseAddress!.assumingMemoryBound(to: CChar.self), cPath)
            return true
        }
    }
    guard bound else { fatalError("daemon: socket path too long: \(path)") }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, size)
        }
    }
    guard result == 0, listen(fd, 16) == 0 else {
        fatalError("daemon: bind/listen failed on \(path): \(errno)")
    }
    return fd
}

private func isTrustedPeer(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else {
        return false
    }
    return uid == geteuid()
}

private func serveConnection(fd: Int32, authToken: String, connectionTasks: DaemonConnectionTasks) {
    defer { close(fd) }
    let authenticationDeadline = Date().addingTimeInterval(
        TimeInterval(DaemonProtocolLimits.authenticationTimeoutSeconds)
    )
    // Serializes response writes from concurrently completing tool Tasks.
    let writeLock = NSLock()
    let authorization = DaemonConnectionAuthorization()
    var frames = DaemonLineBuffer<DaemonRequest>()
    var chunk = [UInt8](repeating: 0, count: DaemonProtocolLimits.readChunkBytes)

    while true {
        if !authorization.isAuthenticated {
            let remaining = authenticationDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                daemonLog("closing daemon connection after authentication timeout")
                return
            }
            setReadTimeout(fd, seconds: max(1, Int(ceil(remaining))))
        }

        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }

        do {
            for frame in try frames.append(contentsOf: chunk[0..<n]) {
                switch frame {
                case .message(let request):
                    let wasAuthenticated = authorization.isAuthenticated
                    let action = handle(
                        request: request,
                        fd: fd,
                        writeLock: writeLock,
                        authToken: authToken,
                        authorization: authorization,
                        connectionTasks: connectionTasks
                    )
                    if !wasAuthenticated && authorization.isAuthenticated {
                        clearReadTimeout(fd)
                    }
                    if action == .close {
                        return
                    }
                case .malformed:
                    if authorization.recordMalformedFrame(maxFrames: DaemonProtocolLimits.maxMalformedFrames) {
                        daemonLog("closing daemon connection after malformed frame budget was exhausted")
                        return
                    }
                    if authorization.recordUnauthenticatedFailure(maxFailures: DaemonProtocolLimits.maxUnauthenticatedFailures) {
                        daemonLog("closing daemon connection after unauthenticated request budget was exhausted")
                        return
                    }
                }
            }
        } catch DaemonProtocolViolation.frameTooLarge(let maxBytes) {
            daemonLog("closing daemon connection after frame exceeded \(maxBytes) bytes")
            return
        } catch {
            daemonLog("closing daemon connection after protocol parse failure: \(error)")
            return
        }
    }
}

final class DaemonConnectionAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var authenticated = false
    private var malformedFrames = 0
    private var unauthenticatedFailures = 0

    func markAuthenticated() {
        lock.lock()
        authenticated = true
        malformedFrames = 0
        unauthenticatedFailures = 0
        lock.unlock()
    }

    var isAuthenticated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticated
    }

    func recordMalformedFrame(maxFrames: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        malformedFrames += 1
        return malformedFrames > maxFrames
    }

    func recordUnauthenticatedFailure(maxFailures: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !authenticated else {
            return false
        }
        unauthenticatedFailures += 1
        return unauthenticatedFailures > maxFailures
    }
}

/// Per-connection in-flight tool Tasks. Cancelled when the client disconnects
/// so mutating input work observes Task.isCancelled and stops.
final class DaemonConnectionTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Void, Never>] = [:]

    func add(_ task: Task<Void, Never>, id: Int) {
        lock.lock()
        tasks[id] = task
        lock.unlock()
    }

    func remove(id: Int) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let active = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        for task in active {
            task.cancel()
        }
    }
}

private enum DaemonConnectionAction: Equatable {
    case keepOpen
    case close
}

private func handle(
    request: DaemonRequest,
    fd: Int32,
    writeLock: NSLock,
    authToken: String,
    authorization: DaemonConnectionAuthorization,
    connectionTasks: DaemonConnectionTasks
) -> DaemonConnectionAction {
    func respond(_ response: DaemonResponse) {
        writeLock.lock()
        _ = writeJSONLine(response, to: fd)
        writeLock.unlock()
    }

    func unauthorized() -> DaemonConnectionAction {
        respond(
            DaemonResponse.from(
                codedErrorResult("Unauthorized daemon request.", code: .daemonUnauthorized),
                id: request.id
            ))
        if authorization.recordUnauthenticatedFailure(maxFailures: DaemonProtocolLimits.maxUnauthenticatedFailures) {
            daemonLog("closing daemon connection after unauthenticated request budget was exhausted")
            return .close
        }
        return .keepOpen
    }

    switch request.method {
    case "hello":
        guard let provided = request.authToken, constantTimeEqual(provided, authToken) else {
            return unauthorized()
        }
        authorization.markAuthenticated()
        respond(
            DaemonResponse(
                id: request.id, version: version, authenticated: true,
                buildStamp: executableBuildStamp
            ))
        return .keepOpen
    case "shutdown":
        guard authorization.isAuthenticated,
            let provided = request.authToken,
            constantTimeEqual(provided, authToken)
        else {
            return unauthorized()
        }
        guard daemonAllowsShutdown(
            requesterBuildStamp: request.buildStamp, daemonBuildStamp: executableBuildStamp
        ) else {
            daemonLog(
                "shutdown refused: requester buildStamp \(request.buildStamp ?? 0) is not newer than \(executableBuildStamp)"
            )
            respond(
                DaemonResponse.from(
                    codedErrorResult(
                        "Shutdown refused: requester build is not newer than this daemon.",
                        code: .daemonUnauthorized
                    ),
                    id: request.id
                ))
            return .keepOpen
        }
        daemonLog("shutdown requested by newer client (version handover)")
        respond(DaemonResponse(id: request.id))
        requestDaemonDrainAndExit()
        return .close
    default:
        guard authorization.isAuthenticated else {
            return unauthorized()
        }
        DaemonState.shared.noteActivity()
        let session = fd
        let task = Task {
            defer { connectionTasks.remove(id: request.id) }
            await DaemonSessionContext.$sessionID.withValue(session) {
                if let denial = await AppLeases.shared.check(
                    tool: request.method, arguments: request.arguments ?? [:], session: session
                ) {
                    respond(
                        DaemonResponse.from(
                            codedErrorResult(denial, code: .appLeaseHeld), id: request.id
                        ))
                    return
                }
                let result = await dispatchTool(name: request.method, arguments: request.arguments ?? [:])
                respond(DaemonResponse.from(result, id: request.id))
                DaemonState.shared.noteActivity()
            }
        }
        connectionTasks.add(task, id: request.id)
        return .keepOpen
    }
}

/// Stop accepting new clients and exit shortly so in-flight replies can flush.
/// Newer clients then spawn a fresh daemon.
private func requestDaemonDrainAndExit() {
    DaemonState.shared.beginDrain()
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.35)
        daemonLog("shutdown drain complete")
        exit(0)
    }
}

private func setReadTimeout(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    withUnsafePointer(to: &timeout) { pointer in
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
    }
}

private func clearReadTimeout(_ fd: Int32) {
    var timeout = timeval(tv_sec: 0, tv_usec: 0)
    withUnsafePointer(to: &timeout) { pointer in
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Connection count + last activity, for the idle self-exit. Class with a
/// lock (not an actor): it is touched from raw connection threads.
private final class DaemonState: @unchecked Sendable {
    static let shared = DaemonState()
    private let lock = NSLock()
    private var connections = 0
    private var lastActivity = Date()
    private var listenFD: Int32 = -1
    private var draining = false

    func setListenFD(_ fd: Int32) {
        lock.lock()
        listenFD = fd
        lock.unlock()
    }

    func beginDrain() {
        lock.lock()
        draining = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            // Unlink first so a replacement daemon can bind; then close so the
            // accept loop wakes and observes the drain flag.
            unlink(daemonSocketPath())
            close(fd)
        }
    }

    var isDraining: Bool {
        lock.lock()
        defer { lock.unlock() }
        return draining
    }

    func connectionOpened() {
        lock.lock()
        connections += 1
        lastActivity = Date()
        lock.unlock()
    }

    func connectionClosed() {
        lock.lock()
        connections -= 1
        lastActivity = Date()
        lock.unlock()
    }

    func noteActivity() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connections <= 0 && Date().timeIntervalSince(lastActivity) > 1800
    }
}

/// With no connected sessions for 30 minutes the daemon reaps itself; the
/// next session spawns a fresh one (which also picks up binary updates).
private func scheduleIdleExit() {
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 60)
            if DaemonState.shared.isIdle {
                daemonLog("idle exit")
                exit(0)
            }
        }
    }
}

func daemonLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: daemonLogPath()) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: daemonLogPath()))
    }
}
