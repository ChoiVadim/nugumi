import Foundation
import GizmateToolAgentCore

/// A headless validation set for tool generation.
///
/// Generation is a model deciding, in one bounded session, what kind of tool a
/// sentence describes and then writing and repairing it. Nothing about that is
/// covered by unit tests: the protocol can be perfect while the agent still
/// cannot build the thing the user asked for. This runs real requests through
/// the real agent against the configured model, asserts the shape of what came
/// back, optionally runs the finished tool for real, and writes down every
/// candidate and diagnostic along the way so a failure can be explained rather
/// than guessed at.
///
/// The cases are deliberately written the way a user would type them, and the
/// suite must never be made to pass by teaching the system prompt a specific
/// answer — a recipe in the prompt proves the prompt can hold a recipe, not
/// that the agent can build tools.
struct ToolEvalCase {
    let name: String
    let request: String
    var kind: ToolKind?
    var input: ToolInput?
    var output: ToolOutput?
    var declaresNetwork: Bool?
    var minimumAssurance: ToolAgentAssuranceV1?
    /// When set, the finished tool is run for real on this argument. It has to
    /// exit cleanly, and produce a file if it declares a file output. This is
    /// the only assertion that proves the tool actually does its job.
    var liveInput: String?
}

enum ToolEvalSuite {
    static let all: [ToolEvalCase] = [
        ToolEvalCase(
            name: "prompt-humanize",
            request: "мне нужен tool который будет делать текст более человечным",
            kind: .prompt,
            input: .selection
        ),
        ToolEvalCase(
            name: "native-save-to-notes",
            request: "хочу выделить текст и сохранить его в заметки",
            kind: .native
        ),
        ToolEvalCase(
            name: "native-open-selected-link",
            request: "на выделенную ссылку открывать её в браузере",
            kind: .native
        ),
        ToolEvalCase(
            name: "python-slugify",
            request: "convert the selected text into a url slug",
            kind: .python,
            input: .selection,
            minimumAssurance: .verified,
            liveInput: "Привет Мир! Hello World"
        ),
        ToolEvalCase(
            name: "python-download-youtube",
            request: "скачивать видео с youtube по ссылке, которую я вставлю",
            kind: .python,
            input: .ask,
            output: .files,
            declaresNetwork: true,
            minimumAssurance: .smoke,
            liveInput: "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
        ),
        ToolEvalCase(
            name: "python-download-instagram-photo",
            request: "download the photo from an instagram link I paste in",
            kind: .python,
            output: .files,
            declaresNetwork: true
        ),
        // The two kinds most likely to be confused with each other. The first
        // has a fixed procedure and must stay a script even though it sounds
        // open-ended; the second genuinely branches on what it finds, and a
        // script cannot express it. If the agent gets these the wrong way round
        // the fix is in the capability description, never a recipe naming these
        // requests.
        ToolEvalCase(
            name: "python-not-agent-word-count",
            request: "посчитать сколько раз каждое слово встречается в выделенном тексте",
            kind: .python,
            input: .selection,
            minimumAssurance: .verified,
            liveInput: "one two two three three three"
        ),
        ToolEvalCase(
            name: "agent-triage-link",
            request: "посмотри на выделенную ссылку, пойми что это за страница "
                + "и в зависимости от этого дай мне или краткий пересказ, или "
                + "список ингредиентов, или расписание",
            kind: .agent,
            input: .selection
        ),
    ]
}

// MARK: - Report

struct ToolEvalAttemptSummary: Codable {
    let kind: String
    let outcome: String?
    let failure: String?
    let assurance: String?
    let detail: String?
    let source: String?
}

struct ToolEvalLiveRunSummary: Codable {
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let producedFiles: [String]
    let error: String?
}

struct ToolEvalCaseReport: Codable {
    let name: String
    let request: String
    let passed: Bool
    let failures: [String]
    let durationSeconds: Double
    let error: String?
    let kind: String?
    let input: String?
    let output: String?
    let declaresNetwork: Bool?
    let assurance: String?
    let source: String?
    let statuses: [String]
    let attempts: [ToolEvalAttemptSummary]
    let liveRun: ToolEvalLiveRunSummary?
}

struct ToolEvalReport: Codable {
    let schemaVersion: Int
    let model: String
    let passed: Int
    let total: Int
    let cases: [ToolEvalCaseReport]
}

// MARK: - Mode

struct ToolEvalMode: Equatable {
    let reportPath: String
    let filter: String?

    var reportURL: URL { URL(fileURLWithPath: reportPath) }

    static func parse(arguments: [String]) -> Self? {
        var report: String?
        var filter: String?
        var sawFlag = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--tool-eval":
                sawFlag = true
            case "--report" where index + 1 < arguments.count:
                index += 1
                report = arguments[index]
            case "--case" where index + 1 < arguments.count:
                index += 1
                filter = arguments[index]
            default:
                break
            }
            index += 1
        }
        guard sawFlag, let report, !report.isEmpty else { return nil }
        return Self(reportPath: report, filter: filter)
    }

    var cases: [ToolEvalCase] {
        guard let filter else { return ToolEvalSuite.all }
        return ToolEvalSuite.all.filter { $0.name.contains(filter) }
    }

    @MainActor
    func run() async -> Int32 {
        // Whatever the tool builder runs on, so the eval measures what ships.
        let scope = ModelUseScope.askGizmate
        let modelID = UserDefaults.standard
            .string(forKey: scope.defaultsKey)
            ?? scope.defaultModelID(legacySelectedModelID: nil)
        let backend = LLMBackendFactory.backend(for: modelID)
        let thinkingLevel = UserDefaults.standard
            .string(forKey: scope.thinkingDefaultsKey)
            .flatMap(ThinkingLevel.init(rawValue:))
            ?? scope.defaultThinkingLevel(legacyThinkingRawValue: nil)

        let bootstrap = UVBootstrap()
        if bootstrap.executable == nil {
            FileHandle.standardError.write(Data("installing uv…\n".utf8))
            await bootstrap.install()
        }
        guard let uv = bootstrap.executable else {
            FileHandle.standardError.write(Data("uv is unavailable\n".utf8))
            return 1
        }

        let selected = cases
        print("tool eval: \(selected.count) case(s), model \(modelID)")
        var reports: [ToolEvalCaseReport] = []
        for testCase in selected {
            let report = await evaluate(
                testCase,
                backend: backend,
                thinkingLevel: thinkingLevel,
                uv: uv
            )
            reports.append(report)
            print(Self.line(for: report))
        }

        let passed = reports.filter(\.passed).count
        let report = ToolEvalReport(
            schemaVersion: 1,
            model: modelID,
            passed: passed,
            total: reports.count,
            cases: reports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(report) {
            try? data.write(to: reportURL, options: .atomic)
        }
        print("tool eval: \(passed)/\(reports.count) passed → \(reportPath)")
        return passed == reports.count ? 0 : 1
    }

    private static func line(for report: ToolEvalCaseReport) -> String {
        let mark = report.passed ? "PASS" : "FAIL"
        let seconds = String(format: "%.0fs", report.durationSeconds)
        let detail = report.passed
            ? (report.assurance.map { " (\($0))" } ?? "")
            : " — " + (report.failures + [report.error].compactMap { $0 })
                .joined(separator: "; ")
        return "  \(mark) \(report.name) [\(seconds)]\(detail)"
    }

    @MainActor
    private func evaluate(
        _ testCase: ToolEvalCase,
        backend: any LLMBackend,
        thinkingLevel: ThinkingLevel,
        uv: URL
    ) async -> ToolEvalCaseReport {
        let started = Date()
        let runID = UUID()
        let statuses = StatusLog()

        var generated: GeneratedTool?
        var buildError: String?
        do {
            generated = try await ToolAgentLiveBuilder.build(
                description: testCase.request,
                backend: backend,
                thinkingLevel: thinkingLevel,
                uv: uv,
                runID: runID,
                onStatus: { statuses.append($0) }
            )
        } catch {
            buildError = error.localizedDescription
        }

        var failures: [String] = []
        var liveRun: ToolEvalLiveRunSummary?
        if let generated {
            failures = Self.assertions(testCase, generated: generated)
            if let liveInput = testCase.liveInput {
                let outcome = await Self.runForReal(generated, argument: liveInput, uv: uv)
                liveRun = outcome
                if let error = outcome.error {
                    failures.append("live run failed: \(error)")
                } else if outcome.exitCode != 0 {
                    failures.append(
                        "live run exited \(outcome.exitCode.map(String.init) ?? "?")"
                    )
                } else if generated.tool.output == .files, outcome.producedFiles.isEmpty {
                    failures.append("live run produced no file")
                }
            }
        } else {
            failures.append("no tool was built")
        }

        return ToolEvalCaseReport(
            name: testCase.name,
            request: testCase.request,
            passed: buildError == nil && failures.isEmpty,
            failures: failures,
            durationSeconds: Date().timeIntervalSince(started),
            error: buildError,
            kind: generated?.tool.kind.rawValue,
            input: generated?.tool.input.rawValue,
            output: generated?.tool.output.rawValue,
            declaresNetwork: generated?.tool.declaresNetwork,
            assurance: generated?.assurance.rawValue,
            source: generated?.script.isEmpty == false ? generated?.script : nil,
            statuses: statuses.values,
            attempts: await Self.attempts(runID: runID),
            liveRun: liveRun
        )
    }

    private static func assertions(
        _ testCase: ToolEvalCase,
        generated: GeneratedTool
    ) -> [String] {
        var failures: [String] = []
        func check<Value: Equatable>(
            _ label: String,
            _ expected: Value?,
            _ actual: Value
        ) {
            guard let expected, expected != actual else { return }
            failures.append("\(label): expected \(expected), got \(actual)")
        }
        check("kind", testCase.kind, generated.tool.kind)
        check("input", testCase.input, generated.tool.input)
        check("output", testCase.output, generated.tool.output)
        check("declaresNetwork", testCase.declaresNetwork, generated.tool.declaresNetwork)
        if let minimum = testCase.minimumAssurance,
           strength(generated.assurance) < strength(minimum) {
            failures.append(
                "assurance: expected at least \(minimum.rawValue), "
                    + "got \(generated.assurance.rawValue)"
            )
        }
        return failures
    }

    private static func strength(_ assurance: ToolAgentAssuranceV1) -> Int {
        switch assurance {
        case .unverified: return 0
        case .smoke: return 1
        case .verified: return 2
        }
    }

    /// Runs the finished tool the way the Ring would, but keeps its output in
    /// the throwaway directory instead of the user's folders.
    private static func runForReal(
        _ generated: GeneratedTool,
        argument: String,
        uv: URL
    ) async -> ToolEvalLiveRunSummary {
        guard generated.tool.kind == .python else {
            return ToolEvalLiveRunSummary(
                exitCode: 0,
                stdout: "",
                stderr: "",
                producedFiles: [],
                error: nil
            )
        }
        do {
            let result = try await ToolRunner.run(
                tool: generated.tool,
                script: generated.script,
                arguments: [argument],
                uv: uv,
                deliverOutputs: false
            )
            return ToolEvalLiveRunSummary(
                exitCode: result.exitCode,
                stdout: String(result.stdout.suffix(2_000)),
                stderr: String(result.stderr.suffix(4_000)),
                producedFiles: result.producedFiles.map(\.lastPathComponent),
                error: nil
            )
        } catch {
            return ToolEvalLiveRunSummary(
                exitCode: nil,
                stdout: "",
                stderr: "",
                producedFiles: [],
                error: error.localizedDescription
            )
        }
    }

    /// Every candidate this run wrote, with the diagnostic the model got back.
    /// Without it a failure is just "it didn't work".
    private static func attempts(runID: UUID) async -> [ToolEvalAttemptSummary] {
        guard let store = try? ToolBuildStore(directoryURL: GizmatePaths.toolAgentRuns),
              let record = try? await store.record(runID: runID) else {
            return []
        }
        return record.attempts.map { attempt in
            let validation = record.validations.first {
                $0.report.candidateID == attempt.candidateID
            }?.report
            return ToolEvalAttemptSummary(
                kind: attempt.candidate.kind.rawValue,
                outcome: validation.map { $0.outcome == .passed ? "passed" : "failed" },
                failure: validation?.failure?.rawValue,
                assurance: validation?.assurance.rawValue,
                detail: validation?.stderrDetail ?? validation?.actualOutput,
                source: attempt.candidate.source.isEmpty ? nil : attempt.candidate.source
            )
        }
    }
}

/// `onStatus` arrives from arbitrary tasks; the eval only reads it at the end.
private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.last != value else { return }
        storage.append(value)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
