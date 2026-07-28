import Darwin
import Foundation

struct ToolRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// Files the script left in its working directory, already moved to the
    /// tool's output folder when it declared one.
    let producedFiles: [URL]

    var isSuccess: Bool { exitCode == 0 }

    /// What a text-output tool shows: stdout, or stderr when the script printed
    /// nothing but talked on the error channel.
    var text: String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? stderr.trimmingCharacters(in: .whitespacesAndNewlines) : out
    }
}

enum ToolRunError: LocalizedError {
    case uvMissing
    case scriptMissing
    case noInput(ToolInput)
    case timedOut(seconds: Int)
    case stopped
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .uvMissing:
            return "The uv runtime isn't installed yet. Open Ring ▸ the tool's editor to set it up."
        case .scriptMissing:
            return "This tool has no script yet."
        case .noInput(let input):
            switch input {
            case .selection: return "Select some text first."
            case .clipboardText: return "Copy some text first."
            case .clipboardURL: return "Copy a link first."
            case .files: return "Copy one or more files in Finder first."
            case .none: return nil
            }
        case .timedOut(let seconds):
            return "The tool ran longer than \(seconds)s and was stopped. Anything it had written was discarded."
        case .stopped:
            return "Stopped. Anything the tool had written was discarded."
        case .launchFailed(let detail):
            return "Couldn't start the tool: \(detail)"
        }
    }
}

/// Runs a `.python` tool: one PEP 723 script, executed by uv in a throwaway
/// working directory.
///
/// **Security posture, stated plainly.** A child process of a non-sandboxed app is
/// not contained — a tool's declared network use and output folder are shown to
/// the user as information, not enforced as a boundary. What actually protects
/// the user here is that the script is visible and approved before its first run
/// (see `ToolApprovals`), that every run gets a fresh empty directory, and that
/// the run is time-limited. Real containment (`sandbox-exec`) is a follow-up.
enum ToolRunner {
    /// Grace period between SIGTERM and SIGKILL on a timeout.
    private static let killGrace: TimeInterval = 2

    /// - Parameter deliverOutputs: whether a `files` tool's output is moved into
    ///   the folder it declared. False during candidate validation, which runs
    ///   the same script for the same reasons but must not drop anything into
    ///   the user's Downloads on the way to deciding whether it works.
    static func run(
        tool: GizmateTool,
        script: String,
        arguments: [String],
        uv: URL,
        deliverOutputs: Bool = true,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ToolRunResult {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolRunError.scriptMissing
        }

        let workDir = try GizmatePaths.makeRunDirectory()
        let scriptURL = workDir.appending(path: ToolsStore.scriptName, directoryHint: .notDirectory)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let before = contents(of: workDir)

        let result: RawResult
        do {
            result = try await execute(
                uv: uv,
                scriptURL: scriptURL,
                arguments: arguments,
                workDir: workDir,
                timeout: max(5, tool.timeoutSeconds),
                onOutput: onOutput
            )
        } catch {
            // A stopped run's half-written output is not something to keep — and a
            // tool that got as far as gigabytes before the limit hit must not leave
            // them sitting in /var/folders.
            try? FileManager.default.removeItem(at: workDir)
            throw error
        }

        // Anything new in the working directory is the script's output. Compared
        // by path so a script that rewrites its own input is not treated as a
        // producer.
        let produced = contents(of: workDir)
            .subtracting(before)
            .subtracting([scriptURL.standardizedFileURL])
            .sorted { $0.path < $1.path }

        let delivered = tool.output == .files && deliverOutputs
            ? move(produced, to: tool.resolvedOutputDirectory)
            : produced

        // Keep the directory when files stayed behind in it, so nothing the user
        // might want is deleted out from under them.
        if delivered.allSatisfy({ !$0.path.hasPrefix(workDir.path) }) {
            try? FileManager.default.removeItem(at: workDir)
        }

        return ToolRunResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            producedFiles: delivered
        )
    }

    // MARK: - Process

    private struct RawResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func execute(
        uv: URL,
        scriptURL: URL,
        arguments: [String],
        workDir: URL,
        timeout: Int,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> RawResult {
        let process = Process()
        process.executableURL = uv
        // `--no-project` keeps a pyproject.toml that happens to sit above the temp
        // directory from being picked up; `--script` forces PEP 723 inline
        // metadata, so the script's own dependency header is what gets resolved.
        process.arguments = ["run", "--no-project", "--script", scriptURL.path] + arguments
        process.currentDirectoryURL = workDir
        process.environment = UVBootstrap.environment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ToolRunError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes as data arrives: a script that writes more than a pipe
        // buffer would otherwise deadlock, and a long-running tool needs to show
        // its progress rather than sit behind a silent spinner.
        let stdoutSink = OutputSink(onChunk: onOutput)
        let stderrSink = OutputSink(onChunk: onOutput)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutSink.absorb(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrSink.absorb(handle.availableData)
        }

        // Poll rather than race a termination handler against a sleep: one loop
        // covers the deadline and Stop with no continuation to resume twice, and
        // 200 ms of latency on a process that runs for seconds is nothing.
        let deadline = Date().addingTimeInterval(Double(timeout))
        var stopReason: ToolRunError?
        while process.isRunning {
            if Task.isCancelled {
                await killTree(process)
                stopReason = .stopped
                break
            }
            if Date() >= deadline {
                await killTree(process)
                stopReason = .timedOut(seconds: timeout)
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Stop the handlers, then pick up whatever was still buffered in the pipe
        // after the process died.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        stdoutSink.absorb((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
        stderrSink.absorb((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())

        if let stopReason { throw stopReason }
        return RawResult(
            exitCode: process.terminationStatus,
            stdout: stdoutSink.text,
            stderr: stderrSink.text
        )
    }

    /// Kills the process **and everything it spawned**.
    ///
    /// Signalling uv alone is not enough: uv launches the interpreter as a child,
    /// and killing the parent reparents that child to launchd, where it happily
    /// keeps working. A yt-dlp pointed at a YouTube radio mix will download
    /// gigabytes that way. The descendant list is therefore collected *before* any
    /// signal is sent, and killed leaves-first.
    private static func killTree(_ process: Process) async {
        let root = process.processIdentifier
        let tree = descendants(of: root) + [root]

        for pid in tree { kill(pid, SIGTERM) }
        try? await Task.sleep(nanoseconds: UInt64(killGrace * 1_000_000_000))
        for pid in tree { kill(pid, SIGKILL) }
    }

    /// Every descendant of `pid`, deepest first, from the kernel's process table.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        let table = processTable()
        var result: [pid_t] = []
        var frontier = [pid]
        // The table is a snapshot, so this terminates even if it somehow held a
        // parent cycle; each level only looks at pids it hasn't seen.
        var seen: Set<pid_t> = [pid]
        while !frontier.isEmpty {
            let children = table
                .filter { frontier.contains($0.parent) && seen.insert($0.pid).inserted }
                .map(\.pid)
            guard !children.isEmpty else { break }
            result.append(contentsOf: children)
            frontier = children
        }
        return result.reversed()
    }

    private static func processTable() -> [(pid: pid_t, parent: pid_t)] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &entries, &size, nil, 0) == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        return entries.prefix(count).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
    }

    /// Accumulates one stream and forwards each chunk. The readability handler
    /// fires on a background queue, so the buffer is lock-guarded.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let onChunk: (@Sendable (String) -> Void)?

        init(onChunk: (@Sendable (String) -> Void)?) {
            self.onChunk = onChunk
        }

        func absorb(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            lock.unlock()
            if let onChunk, let chunk = String(data: data, encoding: .utf8) {
                onChunk(chunk)
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: buffer, encoding: .utf8) ?? ""
        }
    }

    // MARK: - Files

    private static func contents(of directory: URL) -> Set<URL> {
        let fm = FileManager.default
        guard let entries = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return Set(entries.compactMap { ($0 as? URL)?.standardizedFileURL })
    }

    /// Moves results into the tool's folder, never overwriting: a clash becomes
    /// `name-2.ext`. Returns the final locations (the originals when there's no
    /// destination, or when a move fails).
    private static func move(_ files: [URL], to destination: URL?) -> [URL] {
        guard let destination else { return files }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        return files.map { source in
            var target = destination.appending(path: source.lastPathComponent)
            var counter = 2
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            while fm.fileExists(atPath: target.path) {
                let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                target = destination.appending(path: name)
                counter += 1
            }
            do {
                try fm.moveItem(at: source, to: target)
                return target
            } catch {
                return source
            }
        }
    }
}
