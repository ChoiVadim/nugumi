import CToolSandbox
import Darwin
import Dispatch
import Foundation

struct CapturedOutput: Sendable {
    let data: Data
    let wasTruncated: Bool
}

struct ProcessWaitResult: Sendable {
    let status: Int32
    let error: Int32?
}

final class ProcessWaiter: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var result = ProcessWaitResult(status: 0, error: ECHILD)

    func start(pid: pid_t) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var status: Int32 = 0
            var waitResult: pid_t
            repeat {
                waitResult = waitpid(pid, &status, 0)
            } while waitResult < 0 && errno == EINTR

            self.lock.lock()
            self.result = ProcessWaitResult(
                status: status,
                error: waitResult < 0 ? errno : nil
            )
            self.lock.unlock()
            self.group.leave()
        }
    }

    func completes(by deadline: DispatchTime) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.group.wait(timeout: deadline) == .success)
            }
        }
    }

    func completion() async -> ProcessWaitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.group.wait()
                self.lock.lock()
                let result = self.result
                self.lock.unlock()
                continuation.resume(returning: result)
            }
        }
    }
}

extension BoundedProcess {
    static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw BoundedProcessError.spawn(errno: errno)
        }
        for descriptor in descriptors where fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0 {
            let errorNumber = errno
            close(descriptors[0])
            close(descriptors[1])
            throw BoundedProcessError.spawn(errno: errorNumber)
        }
        return (descriptors[0], descriptors[1])
    }

    static func closePipe(_ pipe: (read: Int32, write: Int32)) {
        close(pipe.read)
        close(pipe.write)
    }

    static func spawn(
        _ command: BoundedCommand,
        stdoutFD: Int32,
        stderrFD: Int32
    ) throws -> (pid: pid_t, memoryLimitApplied: Bool) {
        let executable = command.executable.path
        let directory = command.workingDirectory.path
        guard
            !executable.utf8.contains(0),
            !directory.utf8.contains(0),
            command.limits.cpuSeconds >= 0
        else {
            throw BoundedProcessError.spawn(errno: EINVAL)
        }

        let argv: CStringVector
        let envp: CStringVector
        do {
            argv = try CStringVector([executable] + command.arguments)
            envp = try CStringVector(
                command.environment
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
            )
        } catch CStringVectorError.outOfMemory {
            throw BoundedProcessError.spawn(errno: ENOMEM)
        } catch {
            throw BoundedProcessError.spawn(errno: EINVAL)
        }

        var memoryLimitApplied: Int32 = 0
        let pid = executable.withCString { executablePointer in
            directory.withCString { directoryPointer in
                argv.withUnsafeMutablePointer { argvPointer in
                    envp.withUnsafeMutablePointer { envpPointer in
                        gizmate_spawn_limited(
                            executablePointer,
                            argvPointer,
                            envpPointer,
                            directoryPointer,
                            stdoutFD,
                            stderrFD,
                            UInt64(command.limits.cpuSeconds),
                            command.limits.addressSpaceBytes,
                            command.limits.fileBytes,
                            &memoryLimitApplied
                        )
                    }
                }
            }
        }
        guard pid > 1 else {
            let errorNumber = pid < 0 ? Int32(0) - Int32(pid) : Int32(ECHILD)
            throw BoundedProcessError.spawn(errno: errorNumber)
        }
        return (pid, memoryLimitApplied == 1)
    }

    static func drain(fd: Int32, cap: Int) -> CapturedOutput {
        defer { close(fd) }
        let safeCap = max(0, cap)
        var retained = Data()
        retained.reserveCapacity(safeCap)
        var wasTruncated = false
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(fd, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let remaining = max(0, safeCap - retained.count)
                let retainedCount = min(remaining, count)
                if retainedCount > 0 {
                    retained.append(contentsOf: buffer[0..<retainedCount])
                }
                wasTruncated = wasTruncated || count > retainedCount
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        return CapturedOutput(data: retained, wasTruncated: wasTruncated)
    }

    static func kill(pid: pid_t) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = gizmate_kill_process_group(pid)
                continuation.resume()
            }
        }
    }

    static func processGroupIsGone(_ pid: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(-pid, 0) < 0 && errno == ESRCH
    }

    static func waitForProcessGroupToDisappear(_ pid: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = DispatchTime.now() + .seconds(1)
                while !processGroupIsGone(pid) {
                    guard DispatchTime.now() < deadline else {
                        continuation.resume(returning: false)
                        return
                    }
                    usleep(1_000)
                }
                continuation.resume(returning: true)
            }
        }
    }

    static func exitCode(from result: ProcessWaitResult) -> Int32 {
        if let error = result.error {
            return Int32(0) - error
        }
        let signal = result.status & 0x7f
        if signal == 0 {
            return (result.status >> 8) & 0xff
        }
        if signal != 0x7f {
            return 128 + signal
        }
        return result.status
    }
}
