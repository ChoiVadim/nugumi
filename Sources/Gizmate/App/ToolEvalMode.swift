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
    var usesNotes: Bool?
    var minimumAssurance: ToolAgentAssuranceV1?
    /// How many options the finished gizmo must carry. The point of the case is
    /// that the model reached for options unprompted, so this asserts the count,
    /// not the labels — pinning "360p" would be pinning one right answer.
    var minimumOptions: Int?
    /// A ceiling on how many options the finished gizmo may carry. `0` is the
    /// meaningful value: it pins a control case as proof that the axis-of-choice
    /// rule did not make every gizmo grow buttons.
    var maximumOptions: Int?
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
            maximumOptions: 0,
            liveInput: "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
        ),
        ToolEvalCase(
            name: "python-download-youtube-quality",
            request: "скачивать видео с youtube по ссылке, которую я вставлю, "
                + "и чтобы я мог выбрать 360p, 480p или 720p",
            kind: .python,
            input: .ask,
            output: .files,
            declaresNetwork: true,
            minimumAssurance: .smoke,
            minimumOptions: 3,
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
        // The readings half of a surface, as opposed to the files half the
        // downloads case in `resultSweep` already covers. Written as a person
        // would ask, naming neither "list" nor "details" nor "meter": the
        // point is whether the capability description makes the model reach
        // for a list of rows with several lines and a bar when the request is
        // about numbers, rather than a grid of squares. A recipe naming those
        // fields would grade the prompt instead of the builder.
        // A gizmo whose whole subject is what the user has already saved: no
        // input to hand it, the notes context is the material. Grades whether
        // the capability description makes the model reach for input "none"
        // plus usesNotes, rather than demanding a selection it will never get.
        // `ToolInput.none` spelled out — a bare `.none` in this position is
        // `Optional.none` and asserts nothing.
        ToolEvalCase(
            name: "prompt-none-notes-digest",
            request: "сделай кнопку, которая соберёт всё из моих заметок "
                + "в короткую сводку",
            kind: .prompt,
            input: ToolInput.none,
            usesNotes: true
        ),
        ToolEvalCase(
            name: "surface-machine-readings",
            request: "хочу видеть сбоку экрана как загружен мой мак: процессор, "
                + "память и диск, с разбивкой по каждому и полоской заполнения",
            kind: .python,
            input: ToolInput.none,
            output: .surface
        ),
    ] + inputSweep + resultSweep

    /// One case per input, written the way somebody would ask for a tool that
    /// happens to need it — never by naming the input.
    ///
    /// The sweep exists because the same defect has now shipped twice: a new
    /// input reaches the enum, the sidecar schema and the capability
    /// description, and misses one hand-written allowlist deep in the host.
    /// Nothing fails until a user asks for exactly that tool and is told "the
    /// model returned an invalid agent action", which names neither the field
    /// nor the value. A case here fails on the first run instead.
    ///
    /// `Scripts/tool-eval.sh input` runs just these.
    static let inputSweep: [ToolEvalCase] = [
        ToolEvalCase(
            name: "input-dictation-note",
            request: "хочу надиктовать мысль голосом и получить из неё аккуратно "
                + "написанный абзац",
            kind: .prompt,
            input: .dictation
        ),
        ToolEvalCase(
            name: "input-screenshot-text-explain",
            request: "объясни мне текст ошибки который висит на экране — "
                + "выделить его мышкой нельзя",
            kind: .prompt,
            input: .screenshotText
        ),
        ToolEvalCase(
            name: "input-screenshot-look",
            request: "хочу выделить кусок экрана и спросить что там происходит "
                + "на картинке",
            kind: .prompt,
            input: .screenshot
        ),
        ToolEvalCase(
            name: "input-screenshot-process",
            request: "вырезать кусок экрана и сохранить его как чёрно-белый png",
            kind: .python,
            input: .screenshot,
            output: .files
        ),
        ToolEvalCase(
            name: "input-drawn-screen-explain",
            request: "хочу обвести что-то на экране и получить объяснение "
                + "что именно я обвёл",
            kind: .prompt,
            input: .drawnScreen
        ),
        ToolEvalCase(
            name: "input-files-rename",
            request: "переименовать выбранные в Finder фотографии по дате съёмки",
            kind: .python,
            input: .files
        ),
        // Names an app macOS ships, and that is not decoration. The first draft
        // asked for Spotify and failed on a machine without it — the model
        // chose `native` correctly, the host rejected the candidate with "No
        // installed macOS application named Spotify was found", and the model
        // repaired the only way that diagnostic allows: by writing Python. So
        // the case graded the dev machine's app inventory rather than the
        // builder, and it graded it as a prompt problem.
        // Safari rather than a localised name: `installedApplicationExists`
        // resolves a bundle file name, so "Календарь" would be refused on the
        // very machine that has Calendar.app installed.
        ToolEvalCase(
            name: "input-none-open-safari",
            request: "открывать Safari на весь экран одной кнопкой",
            kind: .native,
            // Spelled out, because `input` is an Optional and `.none` there is
            // `Optional.none` — the case would compile, assert nothing, and read
            // as covered.
            input: ToolInput.none
        ),
    ]

    /// One case per result, same rule: the request describes where the answer
    /// should end up, never the name of the setting.
    ///
    /// `Scripts/tool-eval.sh result` runs just these.
    static let resultSweep: [ToolEvalCase] = [
        ToolEvalCase(
            name: "result-panel-explain",
            request: "объясни выделенный термин простыми словами, "
                + "чтобы я мог потом переспросить",
            kind: .prompt,
            input: .selection,
            output: .panel
        ),
        ToolEvalCase(
            name: "result-replace-grammar",
            request: "исправляй грамматику прямо в тексте который я выделил, "
                + "без всяких окон",
            kind: .prompt,
            input: .selection,
            output: .replace
        ),
        ToolEvalCase(
            name: "result-clipboard-headline",
            request: "сделай из выделенного текста короткий заголовок "
                + "и положи его в буфер обмена",
            kind: .prompt,
            input: .selection,
            output: .clipboard
        ),
        ToolEvalCase(
            name: "result-notify-site-up",
            request: "проверь отвечает ли сайт по выделенной ссылке и просто "
                + "скажи мне да или нет, окно не открывай",
            input: .selection,
            output: .notify,
            declaresNetwork: true
        ),
        ToolEvalCase(
            name: "result-notes-keep-summary",
            request: "пересказывай выделенное в паре предложений и сохраняй "
                + "это в заметки",
            kind: .prompt,
            input: .selection,
            output: .notes
        ),
        ToolEvalCase(
            name: "result-speak-summary",
            request: "перескажи выделенное в двух предложениях и прочитай "
                + "мне вслух, показывать ничего не надо",
            kind: .prompt,
            input: .selection,
            output: .speak
        ),
        ToolEvalCase(
            name: "result-annotate-point",
            request: "хочу обвести область на экране и чтобы мне показали "
                + "прямо на экране куда нажимать дальше",
            kind: .prompt,
            output: .annotate
        ),
        ToolEvalCase(
            name: "result-surface-downloads",
            request: "хочу видеть свои загрузки сбоку экрана, "
                + "чтобы перетаскивать файлы оттуда в другие приложения",
            kind: .python,
            // Qualified: bare `.none` resolves to `Optional<ToolInput>.none`
            // (unset) here, not the `ToolInput.none` case — same trap as the
            // download-tool case above.
            input: ToolInput.none,
            output: .surface
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
    /// What a `.prompt` or `.agent` gizmo was actually built to say.
    ///
    /// `source` covers the two kinds whose behavior is a script. Without this
    /// the other two report only their shape, so "the case passed" and "the
    /// gizmo says something sensible" could not be told apart by reading the
    /// report — which is the one thing the report is for.
    let prompt: String?
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
        let scope = ModelUseScope.deep
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
                onStatus: { statuses.append($0) },
                clarification: { request in
                    // A headless user who never answers. The builder is told to
                    // ask which input a gizmo reads and where its result goes
                    // whenever the request does not say, so the default handler
                    // — which refuses — would fail every case here on a question
                    // that is working as designed. Empty answers mean "you
                    // decide", so the sweeps still grade the model's own read of
                    // the sentence, which is the thing they were written to
                    // measure.
                    statuses.append("asked \(request.questions.count) question(s)")
                    return try .init(
                        answers: Array(repeating: "", count: request.questions.count)
                    )
                }
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
            prompt: generated?.tool.prompt.isEmpty == false ? generated?.tool.prompt : nil,
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
        check("usesNotes", testCase.usesNotes, generated.tool.usesNotes)
        if let minimum = testCase.minimumOptions, generated.tool.options.count < minimum {
            failures.append(
                "options: expected at least \(minimum), got \(generated.tool.options.count)"
            )
        }
        if let maximum = testCase.maximumOptions, generated.tool.options.count > maximum {
            failures.append(
                "options: expected at most \(maximum), got \(generated.tool.options.count)"
            )
        }
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
