import Foundation
import NugumiToolWorkerCore

enum ToolWorkerRuntime {
    static func bundled() -> SandboxProbeRuntime? {
        guard
            let resources = Bundle.main.resourceURL,
            let script = Bundle.module.url(
                forResource: "tool_worker_probe",
                withExtension: "py"
            )
        else {
            return nil
        }
        let runtime = resources.appendingPathComponent("Runtime", isDirectory: true)
        return SandboxProbeRuntime(
            pythonExecutable: runtime
                .appendingPathComponent("python", isDirectory: true)
                .appendingPathComponent(
                    "cpython-3.12.11-macos-aarch64-none",
                    isDirectory: true
                )
                .appendingPathComponent("bin/python3.12"),
            script: script,
            sitePackages: runtime.appendingPathComponent(
                "site-packages",
                isDirectory: true
            )
        )
    }
}
