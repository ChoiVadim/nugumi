import CToolSandbox
import Darwin
import Dispatch
import Foundation
import NugumiToolIPC

public struct BoundedCommand: Sendable {
    public let runID: UUID
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]
    public let limits: SandboxProbeLimits

    public init(
        runID: UUID,
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        limits: SandboxProbeLimits
    ) {
        self.runID = runID
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.limits = limits
    }
}

public struct BoundedProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool
    public let timedOut: Bool
    public let processGroupTerminated: Bool
    /// `false` when the platform rejects the requested `RLIMIT_AS` value.
    public let memoryLimitApplied: Bool
}

public enum BoundedProcessError: Error, Equatable, Sendable {
    case spawn(errno: Int32)
    case cancelled
}

public final class BoundedProcess: @unchecked Sendable {
    private struct ActiveRun {
        var pid: pid_t?
        var cancellationRequested = false
        var killClaimed = false
    }

    private let stateLock = NSLock()
    private var activeRuns: [UUID: ActiveRun] = [:]

    public init() {}

    public func run(_ command: BoundedCommand) async throws -> BoundedProcessResult {
        begin(runID: command.runID)
        var didFinish = false
        defer {
            if !didFinish {
                _ = finish(runID: command.runID)
            }
        }

        let result = try await withTaskCancellationHandler {
            try await runRegistered(command)
        } onCancel: {
            self.cancel(runID: command.runID)
        }

        let wasCancelled = finish(runID: command.runID)
        didFinish = true
        if wasCancelled || Task.isCancelled {
            throw BoundedProcessError.cancelled
        }
        return result
    }

    public func cancel(runID: UUID) {
        stateLock.lock()
        guard var run = activeRuns[runID] else {
            stateLock.unlock()
            return
        }
        run.cancellationRequested = true
        let pid = claimKill(&run)
        activeRuns[runID] = run
        stateLock.unlock()

        if let pid {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = nugumi_kill_process_group(pid)
            }
        }
    }

    private func runRegistered(_ command: BoundedCommand) async throws -> BoundedProcessResult {
        let stdoutPipe = try Self.makePipe()
        let stderrPipe: (read: Int32, write: Int32)
        do {
            stderrPipe = try Self.makePipe()
        } catch {
            Self.closePipe(stdoutPipe)
            throw error
        }

        let spawnResult: (pid: pid_t, memoryLimitApplied: Bool)
        do {
            spawnResult = try Self.spawn(
                command,
                stdoutFD: stdoutPipe.write,
                stderrFD: stderrPipe.write
            )
        } catch {
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw error
        }
        close(stdoutPipe.write)
        close(stderrPipe.write)
        let pid = spawnResult.pid

        if let pidToKill = attach(pid: pid, runID: command.runID) {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = nugumi_kill_process_group(pidToKill)
            }
        }

        let stdoutTask = Task.detached {
            Self.drain(fd: stdoutPipe.read, cap: command.limits.stdoutBytes)
        }
        let stderrTask = Task.detached {
            Self.drain(fd: stderrPipe.read, cap: command.limits.stderrBytes)
        }
        let waiter = ProcessWaiter()
        waiter.start(pid: pid)

        let seconds = max(0, command.limits.wallSeconds)
        let completed = await waiter.completes(by: .now() + .seconds(seconds))
        let timedOut = !completed
        if timedOut, let pidToKill = claimKill(runID: command.runID) {
            await Self.kill(pid: pidToKill)
        }
        let waitResult = await waiter.completion()

        if !Self.processGroupIsGone(pid), let pidToKill = claimKill(runID: command.runID) {
            await Self.kill(pid: pidToKill)
        }
        let processGroupTerminated = await Self.waitForProcessGroupToDisappear(pid)
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value

        return BoundedProcessResult(
            exitCode: Self.exitCode(from: waitResult),
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutWasTruncated: stdout.wasTruncated,
            stderrWasTruncated: stderr.wasTruncated,
            timedOut: timedOut,
            processGroupTerminated: processGroupTerminated,
            memoryLimitApplied: spawnResult.memoryLimitApplied
        )
    }

    private func begin(runID: UUID) {
        stateLock.lock()
        activeRuns[runID] = ActiveRun()
        stateLock.unlock()
    }

    private func attach(pid: pid_t, runID: UUID) -> pid_t? {
        stateLock.lock()
        guard var run = activeRuns[runID] else {
            stateLock.unlock()
            return pid
        }
        run.pid = pid
        let claimedPID = run.cancellationRequested ? claimKill(&run) : nil
        activeRuns[runID] = run
        stateLock.unlock()
        return claimedPID
    }

    private func claimKill(runID: UUID) -> pid_t? {
        stateLock.lock()
        guard var run = activeRuns[runID] else {
            stateLock.unlock()
            return nil
        }
        let pid = claimKill(&run)
        activeRuns[runID] = run
        stateLock.unlock()
        return pid
    }

    private func claimKill(_ run: inout ActiveRun) -> pid_t? {
        guard !run.killClaimed, let pid = run.pid else {
            return nil
        }
        run.killClaimed = true
        return pid
    }

    private func finish(runID: UUID) -> Bool {
        stateLock.lock()
        let cancelled = activeRuns.removeValue(forKey: runID)?.cancellationRequested ?? false
        stateLock.unlock()
        return cancelled
    }
}
