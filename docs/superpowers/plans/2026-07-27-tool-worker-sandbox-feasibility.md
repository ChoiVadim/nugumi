# Tool Worker Sandbox Feasibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove, from a packaged Nugumi app on the current arm64 Mac, that an embedded App-Sandboxed XPC worker can run a bundled exact Python runtime and pure-wheel dependency while denying host filesystem and raw-network access, bounding the process, and killing its descendants.

**Architecture:** A small shared Swift module defines a `Data`-only XPC protocol and typed probe report. The main app hosts an allowlisted HTTPS fixture proxy; a separately signed App-Sandboxed XPC service launches the bundled Python probe through a C boundary that creates a process group and applies resource limits. A developer-only launch argument drives the complete packaged gate without exposing unfinished UI or routing normal tools through the worker.

**Tech Stack:** Swift 6 package in Swift 5 language mode, Foundation `NSXPCConnection`, XCTest, a small Darwin C spawn shim, CPython 3.12.11, uv 0.11.26, idna 3.10.

**Spec:** `docs/superpowers/specs/2026-07-27-autonomous-tool-builder-design.md`

## Global Constraints

- This plan proves the current arm64 packaged vertical only. It must not claim the full Phase 0 release gate until the same artifact passes on x86_64.
- Do not connect the existing `ToolRunner` or autonomous repair loop to the worker yet.
- Do not add Pi or Node in this plan.
- The worker has `com.apple.security.app-sandbox = true` and no network entitlement.
- The main app may fetch only the exact probe origin `https://example.com:443`; redirects and all other origins fail closed.
- Bundled runtime versions are exact: CPython `3.12.11`, uv `0.11.26`, idna `3.10`.
- Probe hard limits: 5 seconds wall clock, 2 seconds CPU, 256 MiB address space, 4 MiB file size, 64 KiB retained stdout, 64 KiB retained stderr.
- No inherited environment reaches Python. Its environment contains only `HOME`, `PATH`, `LANG`, `PYTHONNOUSERSITE`, and `PYTHONDONTWRITEBYTECODE`.
- The probe report contains booleans and version strings only. It never stores home paths, response bodies, stdout, stderr, or credentials.
- Preserve every pre-existing staged and unstaged user change. Each commit uses an explicit pathspec.
- Baseline is `swift test`: 212 tests executed, 1 skipped, 0 failures on 2026-07-27.

---

### Task 1: Typed XPC contract

**Files:**

- Create: `Sources/NugumiToolIPC/ToolWorkerProtocol.swift`
- Create: `Tests/NugumiToolIPCTests/ToolWorkerProtocolTests.swift`
- Modify: `Package.swift`

**Interfaces:**

- Produces `NugumiToolWorkerProtocol.runProbe(_:withReply:)`.
- Produces `NugumiToolWorkerProtocol.cancelProbe(_:withReply:)`.
- Produces `NugumiToolWorkerHostProtocol.fetchProbeFixture(_:withReply:)`.
- Produces Codable `SandboxProbeRequest`, `SandboxProbeResult`, and `SandboxProbeLimits`.

- [ ] **Step 1: Add the failing protocol round-trip test**

Create `Tests/NugumiToolIPCTests/ToolWorkerProtocolTests.swift`:

```swift
import XCTest
@testable import NugumiToolIPC

final class ToolWorkerProtocolTests: XCTestCase {
    func testProbeRequestRoundTripsWithoutHostPathsInResult() throws {
        // Given
        let request = SandboxProbeRequest(
            runID: UUID(),
            deniedReadPath: "/Users/example/private.txt",
            deniedWritePath: "/Users/example/outside.txt",
            limits: .feasibility
        )

        // When
        let decoded = try JSONDecoder().decode(
            SandboxProbeRequest.self,
            from: JSONEncoder().encode(request)
        )

        // Then
        XCTAssertEqual(decoded, request)
    }

    func testGatePassRequiresEveryBoundaryCheck() {
        // Given
        var result = SandboxProbeResult.passingFixture

        // When
        result.rawNetworkDenied = false

        // Then
        XCTAssertFalse(result.gatePassed)
    }
}
```

- [ ] **Step 2: Run the test and confirm red**

Run:

```bash
swift test --filter ToolWorkerProtocolTests
```

Expected: package planning fails because `NugumiToolIPC` and its test target do not exist.

- [ ] **Step 3: Add the IPC and test targets**

In `Package.swift`, add the library dependency to the main executable and these targets:

```swift
.target(name: "NugumiToolIPC"),
.testTarget(
    name: "NugumiToolIPCTests",
    dependencies: ["NugumiToolIPC"]
),
```

Add `"NugumiToolIPC"` to the `Nugumi` executable target dependencies.

- [ ] **Step 4: Implement the complete typed contract**

Create `Sources/NugumiToolIPC/ToolWorkerProtocol.swift`:

```swift
import Foundation

@objc public protocol NugumiToolWorkerProtocol {
    func runProbe(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
    func cancelProbe(_ runID: String, withReply reply: @escaping (Bool) -> Void)
}

@objc public protocol NugumiToolWorkerHostProtocol {
    func fetchProbeFixture(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
}

public struct SandboxProbeLimits: Codable, Equatable, Sendable {
    public let wallSeconds: Int
    public let cpuSeconds: Int
    public let addressSpaceBytes: UInt64
    public let fileBytes: UInt64
    public let stdoutBytes: Int
    public let stderrBytes: Int

    public init(
        wallSeconds: Int,
        cpuSeconds: Int,
        addressSpaceBytes: UInt64,
        fileBytes: UInt64,
        stdoutBytes: Int,
        stderrBytes: Int
    ) {
        self.wallSeconds = wallSeconds
        self.cpuSeconds = cpuSeconds
        self.addressSpaceBytes = addressSpaceBytes
        self.fileBytes = fileBytes
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
    }

    public static let feasibility = Self(
        wallSeconds: 5,
        cpuSeconds: 2,
        addressSpaceBytes: 256 * 1_024 * 1_024,
        fileBytes: 4 * 1_024 * 1_024,
        stdoutBytes: 64 * 1_024,
        stderrBytes: 64 * 1_024
    )
}

public struct SandboxProbeRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let deniedReadPath: String
    public let deniedWritePath: String
    public let limits: SandboxProbeLimits

    public init(
        runID: UUID,
        deniedReadPath: String,
        deniedWritePath: String,
        limits: SandboxProbeLimits
    ) {
        self.runID = runID
        self.deniedReadPath = deniedReadPath
        self.deniedWritePath = deniedWritePath
        self.limits = limits
    }
}

public struct ProbeFixtureRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let url: URL

    public init(runID: UUID, url: URL) {
        self.runID = runID
        self.url = url
    }
}

public struct ProbeFixtureResponse: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let statusCode: Int?
    public let body: Data

    public init(accepted: Bool, statusCode: Int?, body: Data) {
        self.accepted = accepted
        self.statusCode = statusCode
        self.body = body
    }
}

public struct SandboxProbeResult: Codable, Equatable, Sendable {
    public let runID: UUID
    public let pythonVersion: String
    public let dependencyVersion: String
    public let workspaceWriteSucceeded: Bool
    public let hostReadDenied: Bool
    public let hostWriteDenied: Bool
    public var rawNetworkDenied: Bool
    public let mediatedNetworkSucceeded: Bool
    public let stdoutBounded: Bool
    public let stderrBounded: Bool
    public let timedOutProcessGroupTerminated: Bool

    public init(
        runID: UUID,
        pythonVersion: String,
        dependencyVersion: String,
        workspaceWriteSucceeded: Bool,
        hostReadDenied: Bool,
        hostWriteDenied: Bool,
        rawNetworkDenied: Bool,
        mediatedNetworkSucceeded: Bool,
        stdoutBounded: Bool,
        stderrBounded: Bool,
        timedOutProcessGroupTerminated: Bool
    ) {
        self.runID = runID
        self.pythonVersion = pythonVersion
        self.dependencyVersion = dependencyVersion
        self.workspaceWriteSucceeded = workspaceWriteSucceeded
        self.hostReadDenied = hostReadDenied
        self.hostWriteDenied = hostWriteDenied
        self.rawNetworkDenied = rawNetworkDenied
        self.mediatedNetworkSucceeded = mediatedNetworkSucceeded
        self.stdoutBounded = stdoutBounded
        self.stderrBounded = stderrBounded
        self.timedOutProcessGroupTerminated = timedOutProcessGroupTerminated
    }

    public var gatePassed: Bool {
        workspaceWriteSucceeded
            && hostReadDenied
            && hostWriteDenied
            && rawNetworkDenied
            && mediatedNetworkSucceeded
            && stdoutBounded
            && stderrBounded
            && timedOutProcessGroupTerminated
            && pythonVersion == "3.12.11"
            && dependencyVersion == "3.10"
    }

    public static let passingFixture = Self(
        runID: UUID(),
        pythonVersion: "3.12.11",
        dependencyVersion: "3.10",
        workspaceWriteSucceeded: true,
        hostReadDenied: true,
        hostWriteDenied: true,
        rawNetworkDenied: true,
        mediatedNetworkSucceeded: true,
        stdoutBounded: true,
        stderrBounded: true,
        timedOutProcessGroupTerminated: true
    )
}

public enum SandboxProbeFailureCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case hostProxyRejected
    case runtimeMissing
    case launchFailed
    case invalidProbeOutput
    case cancelled
}

public struct SandboxProbeFailure: Codable, Equatable, Sendable {
    public let runID: UUID?
    public let code: SandboxProbeFailureCode

    public init(runID: UUID?, code: SandboxProbeFailureCode) {
        self.runID = runID
        self.code = code
    }
}

public enum SandboxProbeReply: Codable, Equatable, Sendable {
    case success(SandboxProbeResult)
    case failure(SandboxProbeFailure)
}

public struct SandboxProbeGateReport: Codable, Equatable, Sendable {
    public let gatePassed: Bool
    public let result: SandboxProbeResult

    public init(result: SandboxProbeResult) {
        self.gatePassed = result.gatePassed
        self.result = result
    }
}
```

- [ ] **Step 5: Run the focused test**

Run: `swift test --filter ToolWorkerProtocolTests`

Expected: 2 tests pass.

- [ ] **Step 6: Commit only Task 1**

```bash
git add -- Package.swift Sources/NugumiToolIPC Tests/NugumiToolIPCTests
git commit --only -m "Add typed tool worker IPC contract" -- \
  Package.swift Sources/NugumiToolIPC Tests/NugumiToolIPCTests
```

---

### Task 2: Bounded process boundary

**Files:**

- Create: `Sources/CToolSandbox/include/CToolSandbox.h`
- Create: `Sources/CToolSandbox/CToolSandbox.c`
- Create: `Sources/NugumiToolWorkerCore/BoundedProcess.swift`
- Create: `Tests/NugumiToolWorkerCoreTests/BoundedProcessTests.swift`
- Modify: `Package.swift`

**Interfaces:**

- C produces `nugumi_spawn_limited(...) -> pid_t` and `nugumi_kill_process_group(pid_t)`.
- Swift produces `BoundedProcess.run(_:) async -> BoundedProcessResult`.
- Swift produces `BoundedProcess.cancel(runID:)`.

- [ ] **Step 1: Write red tests for caps and descendant cancellation**

Create `Tests/NugumiToolWorkerCoreTests/BoundedProcessTests.swift` with two
Given/When/Then tests:

```swift
import Foundation
import XCTest
@testable import NugumiToolWorkerCore
import NugumiToolIPC

final class BoundedProcessTests: XCTestCase {
    func testOutputIsCappedWhilePipeStillDrains() async throws {
        // Given
        let command = BoundedCommand(
            runID: UUID(),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 131072"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["HOME": FileManager.default.temporaryDirectory.path],
            limits: .feasibility
        )

        // When
        let result = try await BoundedProcess().run(command)

        // Then
        XCTAssertEqual(result.stdout.count, SandboxProbeLimits.feasibility.stdoutBytes)
        XCTAssertTrue(result.stdoutWasTruncated)
    }

    func testTimeoutKillsSpawnedChild() async throws {
        // Given
        let command = BoundedCommand(
            runID: UUID(),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 60 & child=$!; echo $child; wait"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["HOME": FileManager.default.temporaryDirectory.path],
            limits: SandboxProbeLimits(
                wallSeconds: 1,
                cpuSeconds: 2,
                addressSpaceBytes: 256 * 1_024 * 1_024,
                fileBytes: 4 * 1_024 * 1_024,
                stdoutBytes: 64 * 1_024,
                stderrBytes: 64 * 1_024
            )
        )

        // When
        let result = try await BoundedProcess().run(command)

        // Then
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.processGroupTerminated)
    }
}
```

- [ ] **Step 2: Run and confirm red**

Run: `swift test --filter BoundedProcessTests`

Expected: compile failure because `NugumiToolWorkerCore` is missing.

- [ ] **Step 3: Add C and Swift targets**

Add to `Package.swift`:

```swift
.target(
    name: "CToolSandbox",
    path: "Sources/CToolSandbox",
    publicHeadersPath: "include"
),
.target(
    name: "NugumiToolWorkerCore",
    dependencies: ["CToolSandbox", "NugumiToolIPC"]
),
.testTarget(
    name: "NugumiToolWorkerCoreTests",
    dependencies: ["NugumiToolWorkerCore", "NugumiToolIPC"]
),
```

- [ ] **Step 4: Implement the C boundary**

`CToolSandbox.h` declares a spawn call that receives null-terminated argv/envp,
working directory, pipe descriptors, and exact limits. `CToolSandbox.c` must:

```c
pid_t pid = fork();
if (pid == 0) {
    setpgid(0, 0);
    setrlimit(RLIMIT_CPU, &cpu_limit);
    setrlimit(RLIMIT_AS, &memory_limit);
    setrlimit(RLIMIT_FSIZE, &file_limit);
    dup2(stdout_fd, STDOUT_FILENO);
    dup2(stderr_fd, STDERR_FILENO);
    chdir(working_directory);
    execve(executable, argv, envp);
    _exit(127);
}
setpgid(pid, pid);
return pid;
```

`nugumi_kill_process_group` sends `SIGTERM`, waits 250 ms through
`nanosleep`, then sends `SIGKILL` to `-pid`. It never accepts PID `<= 1`.
Every failed syscall returns a negative errno; it must not call `abort`.

- [ ] **Step 5: Implement `BoundedProcess`**

`BoundedProcess.run` must:

1. Build null-terminated UTF-8 argv/envp arrays.
2. Create stdout/stderr pipes.
3. Call `nugumi_spawn_limited`.
4. Drain both pipes to EOF while retaining only their configured prefixes.
5. Race `waitpid` against the wall deadline without blocking the main actor.
6. On timeout or task cancellation, call `nugumi_kill_process_group`.
7. Reap the leader and verify `kill(-pid, 0)` returns `ESRCH`.
8. Return:

```swift
struct BoundedProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let stdoutWasTruncated: Bool
    let stderrWasTruncated: Bool
    let timedOut: Bool
    let processGroupTerminated: Bool
}

enum BoundedProcessError: Error, Equatable {
    case spawn(errno: Int32)
    case cancelled
}
```

Keep the file below 250 pure lines. Put argv/envp pointer conversion in
`Sources/NugumiToolWorkerCore/CStringVector.swift` if the limit would be crossed.

- [ ] **Step 6: Run focused tests**

Run: `swift test --filter BoundedProcessTests`

Expected: all tests pass and complete in under 5 seconds.

- [ ] **Step 7: Commit only Task 2**

```bash
git add -- Package.swift Sources/CToolSandbox Sources/NugumiToolWorkerCore \
  Tests/NugumiToolWorkerCoreTests
git commit --only -m "Add bounded sandbox process boundary" -- \
  Package.swift Sources/CToolSandbox Sources/NugumiToolWorkerCore \
  Tests/NugumiToolWorkerCoreTests
```

---

### Task 3: App-Sandboxed XPC probe service

**Files:**

- Create: `Sources/NugumiToolWorker/main.swift`
- Create: `Sources/NugumiToolWorker/ToolWorkerService.swift`
- Create: `Sources/NugumiToolWorkerCore/SandboxProbe.swift`
- Create: `Sources/NugumiToolWorker/Resources/tool_worker_probe.py`
- Create: `Resources/NugumiToolWorker-Info.plist`
- Create: `Resources/NugumiToolWorker.entitlements`
- Create: `Tests/NugumiToolWorkerCoreTests/SandboxProbeTests.swift`
- Modify: `Package.swift`

**Interfaces:**

- XPC service implements `NugumiToolWorkerProtocol`.
- `SandboxProbe` consumes the fixed bundled Python/runtime paths and returns `SandboxProbeResult`.
- Worker calls the exported `NugumiToolWorkerHostProtocol` only for the mediated fixture.

- [ ] **Step 1: Write red probe-validation tests**

Add tests that prove:

- a report with any failed boundary boolean does not pass;
- a runtime reporting Python other than `3.12.11` does not pass;
- a dependency reporting idna other than `3.10` does not pass;
- the sanitized environment has exactly the six allowlisted keys.

Run: `swift test --filter SandboxProbeTests`

Expected: failure because `SandboxProbe` does not exist.

- [ ] **Step 2: Add the worker executable**

Add this product beside the existing `Nugumi` product:

```swift
.executable(name: "NugumiToolWorker", targets: ["NugumiToolWorker"]),
```

Add this target:

```swift
.executableTarget(
    name: "NugumiToolWorker",
    dependencies: ["NugumiToolIPC", "NugumiToolWorkerCore"],
    resources: [.copy("Resources/tool_worker_probe.py")]
),
```

The entrypoint is exactly:

```swift
import Foundation
import NugumiToolWorkerCore

let delegate = ToolWorkerListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
```

The delegate sets:

```swift
connection.exportedInterface = NSXPCInterface(with: NugumiToolWorkerProtocol.self)
connection.exportedObject = ToolWorkerService(connection: connection)
connection.remoteObjectInterface = NSXPCInterface(with: NugumiToolWorkerHostProtocol.self)
```

- [ ] **Step 3: Implement the trusted Python probe**

`tool_worker_probe.py` accepts five arguments: mode, site-packages path,
mediated-fixture path, denied-read path, denied-write path.

Normal mode must:

```python
sys.path.insert(0, site_packages)
import idna

workspace_write_succeeded = write_inside_workspace()
host_read_denied = permission_error_when_reading(denied_read_path)
host_write_denied = permission_error_when_writing(denied_write_path)
raw_network_denied = os_error_when_connecting("example.com", 443)
mediated_network_succeeded = Path(mediated_fixture).read_bytes().startswith(b"<!doctype html>")
```

It prints one JSON object containing only those booleans,
`platform.python_version()`, and `idna.__version__`.

Timeout mode starts one Python child that sleeps for 60 seconds, prints its PID,
flushes stdout, and sleeps for 60 seconds itself. The worker runs this mode with
a one-second wall limit and checks that the process group is gone.

- [ ] **Step 4: Implement `SandboxProbe` and XPC service**

The service:

1. Decodes `SandboxProbeRequest`.
2. Requests exactly `https://example.com/` through the host XPC object.
3. Writes the returned fixture into its fresh container temp directory.
4. Runs normal mode through `BoundedProcess`.
5. Runs timeout mode through `BoundedProcess`.
6. Decodes the normal JSON and combines it with cap/timeout evidence.
7. Encodes `SandboxProbeReply.success` or `SandboxProbeReply.failure`.
8. Tracks active processes by `runID`; `cancelProbe` kills and removes one run.

No code path constructs a `URLSession`, socket, shell command, or inherited
environment inside the worker.

- [ ] **Step 5: Add the XPC metadata**

`Resources/NugumiToolWorker.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
</dict>
</plist>
```

`Resources/NugumiToolWorker-Info.plist` sets:

```xml
<key>CFBundleIdentifier</key>
<string>com.nugumi.app.tool-worker</string>
<key>CFBundleExecutable</key>
<string>NugumiToolWorker</string>
<key>CFBundlePackageType</key>
<string>XPC!</string>
<key>XPCService</key>
<dict>
  <key>RunLoopType</key>
  <string>dispatch_main</string>
</dict>
```

- [ ] **Step 6: Run worker-core tests**

Run:

```bash
swift test --filter NugumiToolWorkerCoreTests
swift build --product NugumiToolWorker
```

Expected: tests pass; worker executable builds.

- [ ] **Step 7: Commit only Task 3**

```bash
git add -- Package.swift Sources/NugumiToolWorker Sources/NugumiToolWorkerCore \
  Resources/NugumiToolWorker-Info.plist Resources/NugumiToolWorker.entitlements \
  Tests/NugumiToolWorkerCoreTests
git commit --only -m "Add sandboxed XPC tool worker probe" -- \
  Package.swift Sources/NugumiToolWorker Sources/NugumiToolWorkerCore \
  Resources/NugumiToolWorker-Info.plist Resources/NugumiToolWorker.entitlements \
  Tests/NugumiToolWorkerCoreTests
```

---

### Task 4: Host proxy and developer probe mode

**Files:**

- Create: `Sources/Nugumi/Tools/ToolWorkerClient.swift`
- Create: `Sources/Nugumi/Tools/ToolWorkerProbeMode.swift`
- Create: `Tests/NugumiTests/ToolWorkerProbeModeTests.swift`
- Modify: `Sources/Nugumi/App/NugumiApp.swift`

**Interfaces:**

- `ToolWorkerClient.runProbe() async throws -> SandboxProbeResult`.
- `ToolWorkerProbeMode.parse(arguments:) -> ToolWorkerProbeMode?`.
- `ProbeFixtureProxy` accepts only the exact HTTPS probe origin.

- [ ] **Step 1: Write red parser and proxy-policy tests**

Tests cover:

```swift
XCTAssertNil(ToolWorkerProbeMode.parse(arguments: ["Nugumi"]))
XCTAssertEqual(
    ToolWorkerProbeMode.parse(arguments: ["Nugumi", "--tool-worker-probe", "--report", "/tmp/report.json"])?.reportPath,
    "/tmp/report.json"
)
XCTAssertTrue(ProbeFixturePolicy.accepts(URL(string: "https://example.com/")!))
XCTAssertFalse(ProbeFixturePolicy.accepts(URL(string: "http://example.com/")!))
XCTAssertFalse(ProbeFixturePolicy.accepts(URL(string: "https://example.com.evil.test/")!))
XCTAssertFalse(ProbeFixturePolicy.accepts(URL(string: "https://example.com:444/")!))
```

Run: `swift test --filter ToolWorkerProbeModeTests`

Expected: compile failure because the types do not exist.

- [ ] **Step 2: Implement client, policy, and proxy**

`ProbeFixturePolicy.accepts` requires scheme `https`, host `example.com`, port
nil or 443, path `/`, no query, no fragment, and no user info.

`ProbeFixtureProxy` uses an ephemeral `URLSessionConfiguration` with cookies,
credentials, cache, and redirects disabled. It caps the body at 64 KiB and
returns only status 200. Redirect delegate callbacks cancel the task.

`ToolWorkerClient` configures both sides of `NSXPCConnection`:

```swift
let connection = NSXPCConnection(serviceName: "com.nugumi.app.tool-worker")
connection.remoteObjectInterface = NSXPCInterface(with: NugumiToolWorkerProtocol.self)
connection.exportedInterface = NSXPCInterface(with: NugumiToolWorkerHostProtocol.self)
connection.exportedObject = ProbeFixtureProxy()
connection.resume()
```

It converts the reply callback with `withCheckedThrowingContinuation`, rejects
decode failure, and invalidates the connection after completion. Before sending
the request, the host creates a random read sentinel and a non-existent write
target under `NugumiPaths.root/ToolWorkerGate/<run-id>/`; both are removed after
the reply. Because the XPC service has its own sandbox container, it must be
unable to read the existing sentinel or create the sibling target. The paths are
never copied into the persisted report.

- [ ] **Step 3: Implement developer launch mode**

At the top of `applicationDidFinishLaunching`, after setting dark appearance:

```swift
if let probeMode = ToolWorkerProbeMode.parse(arguments: ProcessInfo.processInfo.arguments) {
    Task { @MainActor in
        let status = await ToolWorkerClient.runAndWriteReport(to: probeMode.reportURL)
        Darwin.exit(status)
    }
    return
}
```

`runAndWriteReport` wraps success in `SandboxProbeGateReport`, writes atomically
with sorted JSON keys, and returns `0` only when `gatePassed == true`; otherwise
it writes `SandboxProbeReply.failure` and returns `1`.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test --filter ToolWorkerProbeModeTests
swift test
```

Expected: focused tests pass; full suite remains green.

- [ ] **Step 5: Commit only Task 4**

```bash
git add -- Sources/Nugumi/Tools/ToolWorkerClient.swift \
  Sources/Nugumi/Tools/ToolWorkerProbeMode.swift \
  Sources/Nugumi/App/NugumiApp.swift \
  Tests/NugumiTests/ToolWorkerProbeModeTests.swift
git commit --only -m "Add packaged tool worker probe mode" -- \
  Sources/Nugumi/Tools/ToolWorkerClient.swift \
  Sources/Nugumi/Tools/ToolWorkerProbeMode.swift \
  Sources/Nugumi/App/NugumiApp.swift \
  Tests/NugumiTests/ToolWorkerProbeModeTests.swift
```

---

### Task 5: Exact runtime packaging and packaged gate

**Files:**

- Create: `Scripts/prepare-tool-worker-runtime.sh`
- Create: `Scripts/test-tool-worker-gate.sh`
- Modify: `Scripts/build-app-bundle.sh`
- Modify: `.gitignore`

**Interfaces:**

- Prepared runtime: `.build/tool-worker-runtime/arm64/`.
- Embedded XPC: `dist/Nugumi.app/Contents/XPCServices/NugumiToolWorker.xpc`.
- Gate report: `.build/tool-worker-gate/report.json`.

- [ ] **Step 1: Write the failing packaged-gate script**

`Scripts/test-tool-worker-gate.sh` must:

```bash
UNIVERSAL=0 ./Scripts/build-app-bundle.sh
codesign --verify --deep --strict --verbose=4 dist/Nugumi.app
report="$PWD/.build/tool-worker-gate/report.json"
mkdir -p "$(dirname "$report")"
dist/Nugumi.app/Contents/MacOS/Nugumi \
  --tool-worker-probe \
  --report "$report"
test "$(plutil -extract gatePassed raw -o - "$report")" = "true"
```

Run it before packaging changes.

Expected: fail because the XPC service is not embedded.

- [ ] **Step 2: Prepare the exact build-time runtime**

`Scripts/prepare-tool-worker-runtime.sh`:

1. Requires `uv 0.11.26`; a different version exits non-zero.
2. Sets `UV_PYTHON_INSTALL_DIR=.build/tool-worker-runtime/arm64/python`.
3. Runs `uv python install 3.12.11`.
4. Resolves that exact interpreter with `uv python find 3.12.11`.
5. Installs `idna==3.10` into `site-packages` using
   `uv pip install --no-build --no-deps --target`.
6. Verifies Python prints exactly `3.12.11` and idna prints exactly `3.10`.
7. Writes `runtime.json` with versions, architecture, and SHA-256 values for
   the interpreter and installed wheel metadata.

The script never reads or copies a Python from `/opt/homebrew`, `/usr/local`, or
the user's default `PATH`.

- [ ] **Step 3: Embed and sign the XPC service**

Update `Scripts/build-app-bundle.sh` to:

1. Build `NugumiToolWorker` for the same architecture as Nugumi.
2. Run `prepare-tool-worker-runtime.sh`.
3. Create:

```text
Contents/XPCServices/NugumiToolWorker.xpc/Contents/
  Info.plist
  MacOS/NugumiToolWorker
  Resources/Runtime/python/
  Resources/Runtime/site-packages/
  Resources/Runtime/runtime.json
  Resources/NugumiToolWorker_NugumiToolWorker.bundle/
```

4. Copy `Resources/NugumiToolWorker-Info.plist`.
5. Sign every Mach-O file in `Resources/Runtime` deepest-first with the same
   identity and hardened runtime.
6. Sign `NugumiToolWorker.xpc` with
   `Resources/NugumiToolWorker.entitlements`.
7. Continue the existing Sparkle and outer-app signing order.
8. Fail if `codesign -d --entitlements :-` does not show
   `com.apple.security.app-sandbox` for the XPC bundle.

- [ ] **Step 4: Ignore only generated runtime artifacts**

Add:

```gitignore
.build/tool-worker-runtime/
.build/tool-worker-gate/
```

Do not ignore any source, manifest, test, or report under `docs/`.

- [ ] **Step 5: Run the complete packaged gate**

Run:

```bash
./Scripts/test-tool-worker-gate.sh
lipo -archs dist/Nugumi.app/Contents/XPCServices/NugumiToolWorker.xpc/Contents/MacOS/NugumiToolWorker
codesign -d --entitlements :- \
  dist/Nugumi.app/Contents/XPCServices/NugumiToolWorker.xpc
```

Expected on this Mac:

- gate report has `gatePassed = true`;
- Python is `3.12.11`;
- idna is `3.10`;
- host read/write are denied;
- raw network is denied;
- mediated network succeeds;
- timeout kills the whole process group;
- retained stdout/stderr remain within 64 KiB;
- XPC worker contains the `arm64` slice;
- XPC entitlements contain App Sandbox and no network client entitlement.

- [ ] **Step 6: Run final automated verification**

Run:

```bash
swift test
swift build
codesign --verify --deep --strict --verbose=4 dist/Nugumi.app
```

Expected: all commands exit 0.

- [ ] **Step 7: Record the architecture limitation**

Create the next plan only after this arm64 gate is green. The full Phase 0 gate
remains blocked on an equivalent x86_64 packaged run; inspecting a universal
slice alone does not count as runtime proof.

- [ ] **Step 8: Commit only Task 5**

```bash
git add -- .gitignore Scripts/prepare-tool-worker-runtime.sh \
  Scripts/test-tool-worker-gate.sh Scripts/build-app-bundle.sh
git commit --only -m "Package and verify sandboxed tool worker" -- \
  .gitignore Scripts/prepare-tool-worker-runtime.sh \
  Scripts/test-tool-worker-gate.sh Scripts/build-app-bundle.sh
```

---

## Manual QA

1. Quit every running Nugumi copy.
2. Run `./Scripts/test-tool-worker-gate.sh`.
3. Open `.build/tool-worker-gate/report.json`.
4. Confirm it contains only version strings, booleans, `runID`, and
   `gatePassed`; no filesystem paths or fetched body.
5. Launch `open dist/Nugumi.app` normally.
6. Confirm Nugumi opens without the probe mode, the existing Ring remains
   unchanged, and existing prompt/native/Python tools have not been migrated or
   executed.
7. Re-run the packaged gate twice and confirm each run has a different `runID`
   and leaves no `NugumiToolWorker` or probe Python process.

## Stop Condition

This plan is complete only when the packaged arm64 gate report is true, the
full Swift suite/build are green, codesign verification passes, no worker child
survives, and normal Nugumi launch behavior is unchanged. Do not start the Pi
agent-loop plan before this condition holds.
