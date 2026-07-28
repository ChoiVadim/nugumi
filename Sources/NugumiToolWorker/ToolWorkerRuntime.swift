import Foundation
import NugumiToolWorkerCore

enum ToolWorkerRuntime {
    static func bundled() -> SandboxProbeRuntime? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }
        let workerBundleURL = resources.appendingPathComponent(
            "Nugumi_NugumiToolWorker.bundle",
            isDirectory: true
        )
        guard
            let workerResources = Bundle(url: workerBundleURL),
            let script = workerResources.url(
                forResource: "tool_worker_probe",
                withExtension: "py"
            ),
            script.standardizedFileURL == workerBundleURL
                .appendingPathComponent("tool_worker_probe.py")
                .standardizedFileURL,
            let values = try? script.resourceValues(
                forKeys: [.isRegularFileKey]
            ),
            values.isRegularFile == true
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
