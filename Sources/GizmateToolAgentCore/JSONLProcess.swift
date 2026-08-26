import Darwin
import Foundation

public enum JSONLProcessError: Error, Equatable, Sendable {
    case launchFailed(Int32)
    case closed
    case concurrentReceive
    case unterminatedFrame
}

public struct ToolBuildProcessClientV1: Sendable {
    private let sendOperation: @Sendable (ToolAgentMessageV1) async throws -> Void
    private let receiveOperation: @Sendable () async throws -> ToolAgentMessageV1?
    private let cancelOperation: @Sendable () async -> Void
    private let finishOperation: @Sendable () async -> Void

    public init(
        send: @escaping @Sendable (ToolAgentMessageV1) async throws -> Void,
        receive: @escaping @Sendable () async throws -> ToolAgentMessageV1?,
        cancel: @escaping @Sendable () async -> Void,
        finish: @escaping @Sendable () async -> Void = {}
    ) {
        self.sendOperation = send
        self.receiveOperation = receive
        self.cancelOperation = cancel
        self.finishOperation = finish
    }

    public func send(_ message: ToolAgentMessageV1) async throws {
        try await sendOperation(message)
    }

    public func receive() async throws -> ToolAgentMessageV1? {
        try await receiveOperation()
    }

    public func cancel() async {
        await cancelOperation()
    }

    public func finish() async {
        await finishOperation()
    }
}

public actor JSONLProcess {
    private let processID: pid_t
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()
    private var isReceiving = false
    private var isCancelled = false
    private var isReaped = false

    private init(processID: pid_t, input: FileHandle, output: FileHandle) {
        self.processID = processID
        self.input = input
        self.output = output
    }

    public static func launch(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> JSONLProcess {
        var stdinPipe = [Int32](repeating: 0, count: 2)
        var stdoutPipe = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&stdinPipe) == 0 else { throw JSONLProcessError.launchFailed(errno) }
        guard Darwin.pipe(&stdoutPipe) == 0 else {
            close(stdinPipe[0]); close(stdinPipe[1])
            throw JSONLProcessError.launchFailed(errno)
        }

        do {
            let pid = try spawn(
                executableURL: executableURL,
                arguments: arguments,
                environment: sanitizedEnvironment(environment),
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe
            )
            close(stdinPipe[0])
            close(stdoutPipe[1])
            // A sidecar that hits its deadline (or dies on a terminal failure)
            // exits with the host possibly mid-write. Without this the kernel
            // answers that write with SIGPIPE and takes the whole app down —
            // not just the run. F_SETNOSIGPIPE scopes the opt-out to this one
            // descriptor; `sendLine`'s write then fails as a thrown EPIPE the
            // callers already handle as a failed run.
            _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)
            return JSONLProcess(
                processID: pid,
                input: FileHandle(fileDescriptor: stdinPipe[1], closeOnDealloc: true),
                output: FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
            )
        } catch {
            stdinPipe.forEach { close($0) }
            stdoutPipe.forEach { close($0) }
            throw error
        }
    }

    public nonisolated func client() -> ToolBuildProcessClientV1 {
        ToolBuildProcessClientV1(
            send: { [self] message in
                try await self.send(message)
            },
            receive: { [self] in
                return try await self.receive()
            },
            cancel: { [self] in
                await self.cancel()
            },
            finish: { [self] in
                await self.finish()
            }
        )
    }

    public func send(_ message: ToolAgentMessageV1) async throws {
        try await sendLine(ToolAgentJSONLCodecV1.encode(message))
    }

    public func receive() async throws -> ToolAgentMessageV1? {
        guard let line = try await receiveLine() else { return nil }
        return try ToolAgentJSONLCodecV1.decode(line)
    }

    /// Framing without a message type, for the agent-tool run protocol: same
    /// pipes, same newline framing, same size ceiling, a different vocabulary on
    /// top. Keeping this here rather than making the whole actor generic keeps
    /// one implementation of the parts that are easy to get wrong — the partial
    /// read loop, the frame limit, the reaping.
    public func sendLine(_ data: Data) async throws {
        guard !isCancelled else { throw JSONLProcessError.closed }
        let handle = input
        try await Task.detached {
            try handle.write(contentsOf: data)
        }.value
    }

    public func receiveLine() async throws -> Data? {
        guard !isReceiving else { throw JSONLProcessError.concurrentReceive }
        guard !isCancelled else { return nil }
        isReceiving = true
        defer { isReceiving = false }

        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let end = buffer.index(after: newline)
                let line = Data(buffer[..<end])
                buffer.removeSubrange(..<end)
                return line
            }
            guard buffer.count < ToolAgentProtocolLimitsV1.maximumFrameBytes else {
                throw ToolAgentProtocolErrorV1.frameTooLarge
            }
            let handle = output
            let chunk = await Task.detached {
                handle.availableData
            }.value
            guard !chunk.isEmpty else {
                guard buffer.isEmpty else { throw JSONLProcessError.unterminatedFrame }
                return nil
            }
            buffer.append(chunk)
        }
    }

    public func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        try? input.close()
        guard processID > 1 else { return }
        _ = Darwin.kill(-processID, SIGTERM)
        try? await Task.sleep(nanoseconds: 100_000_000)
        if Darwin.kill(processID, 0) == 0 {
            _ = Darwin.kill(-processID, SIGKILL)
        }
        await reap()
        try? output.close()
    }

    public func finish() async {
        guard !isReaped else { return }
        try? input.close()
        for _ in 0..<20 where Darwin.kill(processID, 0) == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if Darwin.kill(processID, 0) == 0 {
            _ = Darwin.kill(-processID, SIGKILL)
        }
        await reap()
        try? output.close()
    }

    public static func sanitizedEnvironment(_ supplied: [String: String]) -> [String: String] {
        let allowed = Set(["LANG", "LC_ALL", "TMPDIR"])
        var result = supplied.filter {
            allowed.contains($0.key)
                && !$0.value.contains("\0")
                && !$0.value.contains("\n")
                && $0.value.utf8.count <= 4_096
        }
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result["LANG"] = result["LANG"] ?? "en_US.UTF-8"
        return result
    }

    private func reap() async {
        guard !isReaped else { return }
        isReaped = true
        let pid = processID
        await Task.detached {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }.value
    }
}

private extension JSONLProcess {
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        stdinPipe: [Int32],
        stdoutPipe: [Int32]
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        for descriptor in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let argv = [executableURL.path] + arguments
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let status = withCStringArray(argv) { argvPointer in
            withCStringArray(env) { envPointer in
                posix_spawn(&pid, executableURL.path, &actions, &attributes, argvPointer, envPointer)
            }
        }
        guard status == 0 else { throw JSONLProcessError.launchFailed(status) }
        return pid
    }

    static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let allocated = strings.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var pointers = allocated + [nil]
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
