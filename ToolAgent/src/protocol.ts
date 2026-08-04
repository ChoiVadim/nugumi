import { z } from "zod";

export const LIMITS = {
  frameBytes: 1_048_576,
  transcriptBytes: 512 * 1024,
  descriptionBytes: 8 * 1024,
  modelTextBytes: 512 * 1024,
  safeMessageBytes: 1024,
  askUserBytes: 1024,
  nameBytes: 128,
  briefBytes: 1024,
  symbolBytes: 128,
  promptBytes: 16 * 1024,
  targetBytes: 8 * 1024,
  sourceBytes: 64 * 1024,
  fixtureInputBytes: 8 * 1024,
  fixtureOutputBytes: 16 * 1024,
  diagnosticBytes: 16 * 1024,
  filterCount: 16,
  filterValueBytes: 255,
  // Mirrors ToolAgentProtocolLimitsV1.maximumSecretName*.
  secretNameCount: 8,
  secretNameBytes: 64,
  // Mirrors ToolAgentProtocolLimitsV1.maximumOption*.
  optionBytes: 64,
  optionCount: 5,
  // Mirrors ToolAgentLayoutV1.maximumEmptyBytes and .maximumDepth.
  layoutEmptyBytes: 120,
  layoutMaxDepth: 3,
  // An agent tool's own input, and the answer it finishes with. The answer is
  // roomier than a build session's finalText because it *is* the tool's output:
  // it lands in the result panel or on the clipboard.
  agentInputBytes: 64 * 1024,
  agentResultBytes: 32 * 1024,
} as const;

export const TOOL_NAMES = [
  "read_build_context",
  "write_candidate",
  "run_validation",
  "finish_candidate",
  "ask_user",
] as const;

export type ToolName = (typeof TOOL_NAMES)[number];

/// The tools an *agent tool* has while it runs, as opposed to the five a build
/// session has. Deliberately two: everything an agent might want to reach — the
/// network, the user's files, a subprocess — it reaches through Python, so a
/// larger catalog would buy reach it already has.
export const RUN_TOOL_NAMES = ["run_python", "finish"] as const;

export type RunToolName = (typeof RUN_TOOL_NAMES)[number];

const byteString = (maximum: number, allowEmpty = false) =>
  z
    .string()
    .refine(
      (value) =>
        (allowEmpty || value.length > 0) && Buffer.byteLength(value) <= maximum,
      "string exceeds UTF-8 byte limit",
    );

const uuid = z.string().uuid();
const fingerprint = z
  .object({ value: z.string().regex(/^[a-f0-9]{64}$/) })
  .strict();
const budgets = z
  .object({
    // Mirrors ToolAgentBudgetsV1.preview. A repair budget the turn budget
    // cannot pay for is not a repair budget.
    modelTurns: z.number().int().min(1).max(12),
    toolCalls: z.number().int().min(1).max(32),
    repairs: z.number().int().min(0).max(3),
    durationSeconds: z.number().int().min(1).max(900),
  })
  .strict();

const commonCandidate = {
  schemaVersion: z.literal(1),
  name: byteString(LIMITS.nameBytes),
  brief: byteString(LIMITS.briefBytes),
  symbolName: byteString(LIMITS.symbolBytes),
  input: z.enum([
    "selection",
    "ask",
    "dictation",
    "files",
    "screenshot",
    "screenshotText",
    "drawnScreen",
    "none",
  ]),
  output: z.enum([
    "panel",
    "replace",
    "clipboard",
    "files",
    "notify",
    "notes",
    "speak",
    "annotate",
    "surface",
  ]),
  trigger: z.enum(["always", "selection", "files"]),
  hosts: z.array(byteString(LIMITS.filterValueBytes)).max(LIMITS.filterCount),
  extensions: z
    .array(byteString(LIMITS.filterValueBytes))
    .max(LIMITS.filterCount),
  // Variants the gizmo offers, drawn as a second orbit behind its Ring button.
  // Optional rather than defaulted to []: the host re-encodes a candidate and
  // compares byte for byte, so a key the model did not write must not appear.
  // `.min(2)` is why this cannot carry a `.default([])` the way secretNames
  // does — one option is not a choice, and an empty default would fail it.
  options: z
    .array(byteString(LIMITS.optionBytes))
    .min(2)
    .max(LIMITS.optionCount)
    .optional(),
} as const;

const promptCandidate = z
  .object({
    ...commonCandidate,
    kind: z.literal("prompt"),
    // No narrowing: a prompt tool takes whatever it is handed and its answer
    // goes wherever the user asked. A second list here is a second thing to
    // forget, and forgetting it rejects a candidate the prompt asked for.
    trigger: z.enum(["always", "selection"]),
    prompt: byteString(LIMITS.promptBytes),
    appliesTargetLanguage: z.boolean(),
  })
  .strict();

const nativeCandidate = z
  .object({
    ...commonCandidate,
    kind: z.literal("native"),
    output: z.enum(["replace", "clipboard", "notify", "notes", "speak"]),
    nativeAction: z.enum([
      "openApp",
      "openAppFullScreen",
      "sendTextToApp",
      "revealInFinder",
      "openURL",
      "runShortcut",
      "saveToNote",
    ]),
    target: byteString(LIMITS.targetBytes, true),
  })
  .strict();

// Mirrors ToolAgentLayoutV1: four node shapes, discriminated on `node`, each
// `.strict()` so an extra key is rejected here rather than left for the host's
// stricter Swift decode to catch. Only a `.python` candidate carries one — a
// surface is a script's stdout rendered as rows, and nothing else builds rows.
//
// A modifier's regex is anchored at both ends and demands at least one
// character after its `$` — `file:$` alone is not a key, the same way
// `ToolAgentLayoutIconV1`'s `strippingKeyed` throws on it. `z.lazy` has no
// notion of its own nesting depth, so `ToolAgentLayoutV1.maximumDepth` is
// enforced separately below, by walking the parsed tree in `candidateSchema`'s
// `superRefine`.
const layoutNode: z.ZodType<unknown> = z.lazy(() =>
  z.discriminatedUnion("node", [
    z
      .object({
        node: z.literal("grid"),
        cell: layoutNode,
        minimumWidth: z.number().int().min(48).max(400),
        empty: byteString(LIMITS.layoutEmptyBytes),
      })
      .strict(),
    z
      .object({
        node: z.literal("list"),
        row: layoutNode,
        empty: byteString(LIMITS.layoutEmptyBytes),
      })
      .strict(),
    z
      .object({
        node: z.literal("card"),
        title: z.string(),
        subtitle: z.string().optional(),
        icon: z
          .string()
          .regex(/^(file:\$.+|symbol:.*)$/)
          .optional(),
        drag: z
          .string()
          .regex(/^(file|text):\$.+$/)
          .optional(),
        tap: z
          .string()
          .regex(/^(open|reveal):\$.+$/)
          .optional(),
      })
      .strict(),
    z.object({ node: z.literal("text"), value: z.string() }).strict(),
  ]),
);

// Walks an already-parsed layout node the same way
// `ToolAgentLayoutV1.depth`/`.isRepeater` walk the decoded Swift enum. `value`
// is `unknown` rather than the lazy schema's inferred type because
// `z.ZodType<unknown>` cannot express the discriminated union recursively;
// the shape is guaranteed by `layoutNode` having already parsed it.
function layoutNodeKind(value: unknown): unknown {
  return typeof value === "object" && value !== null
    ? (value as { node?: unknown }).node
    : undefined;
}

function layoutDepth(value: unknown): number {
  const kind = layoutNodeKind(value);
  if (kind === "grid")
    return 1 + layoutDepth((value as { cell: unknown }).cell);
  if (kind === "list") return 1 + layoutDepth((value as { row: unknown }).row);
  return 1;
}

function layoutIsRepeater(value: unknown): boolean {
  const kind = layoutNodeKind(value);
  return kind === "grid" || kind === "list";
}

// Mirrors ToolAgentLayoutV1.containsNestedRepeater. A repeater's own cell has
// no second collection to iterate — the rows a script prints are flat — so a
// grid or list nested inside another repeater's cell is legal by depth and
// meaningless anyway. Rejecting it here keeps the two sides agreeing on
// exactly the same candidates, the same way layoutDepth/layoutIsRepeater do.
function layoutContainsNestedRepeater(value: unknown): boolean {
  const kind = layoutNodeKind(value);
  if (kind === "grid") {
    const cell = (value as { cell: unknown }).cell;
    return layoutIsRepeater(cell) || layoutContainsNestedRepeater(cell);
  }
  if (kind === "list") {
    const row = (value as { row: unknown }).row;
    return layoutIsRepeater(row) || layoutContainsNestedRepeater(row);
  }
  return false;
}

const pythonCandidate = z
  .object({
    ...commonCandidate,
    kind: z.literal("python"),
    source: byteString(LIMITS.sourceBytes),
    // Present exactly when output is "surface" — enforced by the candidate's
    // own superRefine below, the same way outputDirectory is enforced for
    // "files". What a surface draws, mirroring ToolAgentCandidateV1.layout.
    layout: layoutNode.optional(),
    // Zero fixtures means "running this would do something to the user's data".
    // A fixture without expectedOutput means "run it, but its output is not a
    // fixed string". Both are how a tool that does real work gets validated at
    // all. `input` allows empty here — the candidate-level superRefine below
    // is what actually requires it non-empty, and only when the candidate's
    // own input isn't "none": a "none"-input tool (a surface among them) has
    // nothing to give a fixture, so an empty string is the honest value, not
    // a missing one.
    fixtures: z
      .array(
        z
          .object({
            input: byteString(LIMITS.fixtureInputBytes, true),
            expectedOutput: byteString(
              LIMITS.fixtureOutputBytes,
              true,
            ).optional(),
          })
          .strict(),
      )
      .max(3),
    outputDirectory: byteString(LIMITS.targetBytes).optional(),
    timeoutSeconds: z.number().int().min(5).max(1800),
    declaresNetwork: z.boolean(),
    // Names of the user's stored secrets this tool reads from its environment.
    // Names only — the host never sends a value across this protocol.
    secretNames: z
      .array(byteString(LIMITS.secretNameBytes))
      .max(LIMITS.secretNameCount)
      .default([]),
  })
  .strict();

const agentCandidate = z
  .object({
    ...commonCandidate,
    kind: z.literal("agent"),
    output: z.enum([
      "panel",
      "replace",
      "clipboard",
      "notify",
      "notes",
      "speak",
      "annotate",
    ]),
    prompt: byteString(LIMITS.promptBytes),
    // At most one, and never with an expectedOutput: an agent's answer is not
    // predictable, so a fixture is the input a harmless trial run should use,
    // and none at all means running it for real would do something to the
    // user's data or to the outside world. `input` allows empty for the same
    // "none" reason pythonCandidate's does.
    fixtures: z
      .array(
        z
          .object({ input: byteString(LIMITS.fixtureInputBytes, true) })
          .strict(),
      )
      .max(1)
      .default([]),
    maxSteps: z.number().int().min(1).max(24),
    timeoutSeconds: z.number().int().min(15).max(900),
    secretNames: z
      .array(byteString(LIMITS.secretNameBytes))
      .max(LIMITS.secretNameCount)
      .default([]),
  })
  .strict();

export const candidateSchema = z
  .discriminatedUnion("kind", [
    promptCandidate,
    nativeCandidate,
    pythonCandidate,
    agentCandidate,
  ])
  .superRefine((candidate, context) => {
    if (candidate.trigger === "selection" && candidate.input !== "selection") {
      context.addIssue({
        code: "custom",
        message: "selection trigger needs selection input",
      });
    }
    if (candidate.trigger === "files" && candidate.input !== "files") {
      context.addIssue({
        code: "custom",
        message: "files trigger needs files input",
      });
    }
    if (
      candidate.kind === "native" &&
      candidate.nativeAction !== "revealInFinder" &&
      candidate.nativeAction !== "saveToNote" &&
      candidate.target.length === 0
    ) {
      context.addIssue({
        code: "custom",
        message: "native action target is required",
      });
    }
    if (
      candidate.kind === "python" &&
      candidate.output === "files" &&
      candidate.outputDirectory === undefined
    ) {
      context.addIssue({
        code: "custom",
        message: "files output needs outputDirectory",
      });
    }
    // Mirrors ToolAgentCandidateV1.validate's fixture rule: "none" is the one
    // input a fixture cannot supply a real value for, so an empty string is
    // the honest fixture there, not a missing one. Every other input keeps
    // requiring a real value — an empty fixture proves nothing for a tool
    // that actually reads its argument.
    if (
      (candidate.kind === "python" || candidate.kind === "agent") &&
      candidate.input !== "none" &&
      candidate.fixtures.some((fixture) => fixture.input.length === 0)
    ) {
      context.addIssue({
        code: "custom",
        message: "a fixture needs a real input unless the candidate takes none",
      });
    }
    // Mirrors ToolAgentCandidateV1.validate's surface rule: a surface is
    // drawn by a script's stdout, never runs on demand, and is handed nothing
    // to act on. Any other output must carry no layout at all — the field
    // exists only to answer "what does the surface draw".
    if (candidate.output === "surface") {
      if (candidate.kind !== "python") {
        context.addIssue({
          code: "custom",
          message: "only a python candidate can be a surface",
        });
      } else if (
        candidate.layout === undefined ||
        !layoutIsRepeater(candidate.layout) ||
        layoutDepth(candidate.layout) > LIMITS.layoutMaxDepth
      ) {
        context.addIssue({
          code: "custom",
          message: "a surface needs a layout whose root repeats",
        });
      } else if (layoutContainsNestedRepeater(candidate.layout)) {
        context.addIssue({
          code: "custom",
          message: "a surface's layout may not repeat below its root",
        });
      }
      if (candidate.input !== "none" || candidate.trigger !== "always") {
        context.addIssue({
          code: "custom",
          message: "a surface takes no input and always applies",
        });
      }
    } else if (candidate.kind === "python" && candidate.layout !== undefined) {
      context.addIssue({
        code: "custom",
        message: "layout is only for a surface",
      });
    }
  });

export type Candidate = z.infer<typeof candidateSchema>;

const commonInstalledTool = {
  name: byteString(LIMITS.nameBytes),
  brief: byteString(LIMITS.briefBytes, true),
  symbolName: byteString(LIMITS.symbolBytes),
  input: z.enum([
    "selection",
    "ask",
    "dictation",
    "files",
    "screenshot",
    "screenshotText",
    "drawnScreen",
    "none",
  ]),
  output: z.enum([
    "panel",
    "replace",
    "clipboard",
    "files",
    "notify",
    "notes",
    "speak",
    "annotate",
    "surface",
  ]),
  trigger: z.enum(["always", "selection", "files"]),
  hosts: z.array(byteString(LIMITS.filterValueBytes)).max(LIMITS.filterCount),
  extensions: z
    .array(byteString(LIMITS.filterValueBytes))
    .max(LIMITS.filterCount),
  // Variants the gizmo offers, carried into an edit session so a rename does
  // not silently strip them. Optional and bounded exactly as on a candidate:
  // the host re-encodes and compares byte for byte, and one option is not a
  // choice.
  options: z
    .array(byteString(LIMITS.optionBytes))
    .min(2)
    .max(LIMITS.optionCount)
    .optional(),
} as const;

const installedPromptTool = z
  .object({
    ...commonInstalledTool,
    kind: z.literal("prompt"),
    // No narrowing: a prompt tool takes whatever it is handed and its answer
    // goes wherever the user asked. A second list here is a second thing to
    // forget, and forgetting it rejects a candidate the prompt asked for.
    trigger: z.enum(["always", "selection"]),
    prompt: byteString(LIMITS.promptBytes),
    appliesTargetLanguage: z.boolean(),
  })
  .strict();

const installedNativeTool = z
  .object({
    ...commonInstalledTool,
    kind: z.literal("native"),
    output: z.enum(["replace", "clipboard", "notify", "notes", "speak"]),
    nativeAction: z.enum([
      "openApp",
      "openAppFullScreen",
      "sendTextToApp",
      "revealInFinder",
      "openURL",
      "runShortcut",
      "saveToNote",
    ]),
    target: byteString(LIMITS.targetBytes, true),
  })
  .strict();

const installedPythonTool = z
  .object({
    ...commonInstalledTool,
    kind: z.literal("python"),
    source: byteString(LIMITS.sourceBytes),
    // Present exactly when output is "surface", same as on the candidate —
    // what an existing surface gizmo already draws, carried into an edit so
    // Pi can see it rather than invent a new one from scratch.
    layout: layoutNode.optional(),
    outputDirectory: byteString(LIMITS.targetBytes).optional(),
    timeoutSeconds: z.number().int().min(5).max(1800),
    declaresNetwork: z.boolean(),
    // Names of the user's stored secrets this tool reads from its environment.
    // Names only — the host never sends a value across this protocol.
    secretNames: z
      .array(byteString(LIMITS.secretNameBytes))
      .max(LIMITS.secretNameCount)
      .default([]),
  })
  .strict();

const installedAgentTool = z
  .object({
    ...commonInstalledTool,
    kind: z.literal("agent"),
    output: z.enum([
      "panel",
      "replace",
      "clipboard",
      "notify",
      "notes",
      "speak",
      "annotate",
    ]),
    prompt: byteString(LIMITS.promptBytes),
    maxSteps: z.number().int().min(1).max(24),
    timeoutSeconds: z.number().int().min(15).max(900),
    secretNames: z
      .array(byteString(LIMITS.secretNameBytes))
      .max(LIMITS.secretNameCount)
      .default([]),
  })
  .strict();

export const installedToolSchema = z
  .discriminatedUnion("kind", [
    installedPromptTool,
    installedNativeTool,
    installedPythonTool,
    installedAgentTool,
  ])
  .superRefine((tool, context) => {
    if (tool.trigger === "selection" && tool.input !== "selection") {
      context.addIssue({
        code: "custom",
        message: "selection trigger needs selection input",
      });
    }
    if (tool.trigger === "files" && tool.input !== "files") {
      context.addIssue({
        code: "custom",
        message: "files trigger needs files input",
      });
    }
    if (
      tool.kind === "native" &&
      tool.nativeAction !== "revealInFinder" &&
      tool.nativeAction !== "saveToNote" &&
      tool.target.length === 0
    ) {
      context.addIssue({
        code: "custom",
        message: "native action target is required",
      });
    }
    if (
      tool.kind === "python" &&
      tool.output === "files" &&
      tool.outputDirectory === undefined
    ) {
      context.addIssue({
        code: "custom",
        message: "files output needs outputDirectory",
      });
    }
  });

export type InstalledTool = z.infer<typeof installedToolSchema>;

export const askUserRequestSchema = z
  .object({ question: byteString(LIMITS.askUserBytes) })
  .strict();

export const toolResponsePayloadSchemas = {
  read_build_context: z
    .object({
      remaining: z
        .object({
          modelTurns: z.number().int().min(0),
          toolCalls: z.number().int().min(0),
          repairs: z.number().int().min(0),
        })
        .strict(),
      // Which secrets the user has stored. Names only, never values.
      secretNames: z
        .array(byteString(LIMITS.secretNameBytes))
        .max(LIMITS.secretNameCount)
        .default([]),
    })
    .strict(),
  write_candidate: z.object({ candidateID: uuid, fingerprint }).strict(),
  run_validation: z
    .object({
      candidateID: uuid,
      fingerprint,
      outcome: z.enum(["passed", "failed"]),
      assurance: z.enum(["verified", "smoke", "unverified"]),
      failure: z
        .enum([
          "invalidCandidate",
          "syntaxError",
          "runtimeError",
          "invalidOutput",
          "wrongOutput",
          "timedOut",
          "outputLimit",
          "cancelled",
          "workerFailure",
        ])
        .optional(),
      fixtureIndex: z.number().int().min(0).max(2).optional(),
      expectedOutput: byteString(LIMITS.diagnosticBytes, true).optional(),
      actualOutput: byteString(LIMITS.diagnosticBytes, true).optional(),
      stderrDetail: byteString(LIMITS.diagnosticBytes, true).optional(),
      exitCode: z.number().int().optional(),
      terminationSignal: z.number().int().optional(),
      stdoutWasTruncated: z.boolean().optional(),
      stderrWasTruncated: z.boolean().optional(),
      durationMilliseconds: z.number().int().min(0).max(600_000).optional(),
      passingFingerprint: fingerprint.optional(),
    })
    .strict()
    .refine(
      (value) =>
        (value.outcome === "passed" && value.failure === undefined) ||
        (value.outcome === "failed" && value.failure !== undefined),
      "validation outcome and failure disagree",
    ),
  finish_candidate: z
    .object({
      candidateID: uuid,
      fingerprint,
    })
    .strict(),
  ask_user: z.object({ answer: byteString(LIMITS.askUserBytes) }).strict(),
} as const;

const modelResult = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("text"),
      text: byteString(LIMITS.modelTextBytes),
    })
    .strict(),
  z
    .object({
      kind: z.literal("error"),
      error: z.enum([
        "invalidProtocol",
        "invalidModelAction",
        "cancelled",
        "budgetExhausted",
        "workerFailure",
      ]),
    })
    .strict(),
]);

const inboundSchemas = {
  start: z
    .object({
      operation: z.enum(["create", "edit", "fix"]).default("create"),
      description: byteString(LIMITS.safeMessageBytes),
      budgets,
      currentTool: installedToolSchema.optional(),
      failure: byteString(LIMITS.diagnosticBytes).optional(),
    })
    .strict()
    .superRefine((value, context) => {
      if (
        value.operation === "create" &&
        (value.currentTool !== undefined || value.failure !== undefined)
      ) {
        context.addIssue({
          code: "custom",
          message: "create does not accept current tool or failure",
        });
      }
      if (value.operation === "edit" && value.currentTool === undefined) {
        context.addIssue({
          code: "custom",
          message: "edit requires current tool",
        });
      }
      if (value.operation === "edit" && value.failure !== undefined) {
        context.addIssue({
          code: "custom",
          message: "edit does not accept failure",
        });
      }
      if (value.operation === "fix" && value.currentTool === undefined) {
        context.addIssue({
          code: "custom",
          message: "fix requires current tool",
        });
      }
      if (value.operation === "fix" && value.failure === undefined) {
        context.addIssue({ code: "custom", message: "fix requires failure" });
      }
    }),
  modelResponse: z.object({ requestID: uuid, result: modelResult }).strict(),
  toolResponse: z
    .object({
      callID: uuid,
      result: z
        .object({ name: z.enum(TOOL_NAMES), payload: z.unknown() })
        .strict(),
    })
    .strict(),
  cancel: z
    .object({ reason: z.enum(["userRequested", "deadlineExceeded"]) })
    .strict(),
} as const;

/// Starting an *agent tool* run. Its own schema rather than a variant of the
/// build start: a build is described by a request sentence, while a run carries
/// a frozen instruction plus whatever the ring handed the tool, and the two have
/// nothing in common but their budgets.
export const runStartSchema = z
  .object({
    instruction: byteString(LIMITS.promptBytes),
    input: byteString(LIMITS.agentInputBytes, true),
    budgets,
    // Names only. The values are already in the environment of every process
    // the host runs for this agent; they never travel over this protocol.
    secretNames: z
      .array(byteString(LIMITS.secretNameBytes))
      .max(LIMITS.secretNameCount)
      .default([]),
  })
  .strict();

const runInboundSchemas = {
  start: runStartSchema,
  modelResponse: inboundSchemas.modelResponse,
  toolResponse: z
    .object({
      callID: uuid,
      result: z
        .object({ name: z.enum(RUN_TOOL_NAMES), payload: z.unknown() })
        .strict(),
    })
    .strict(),
  cancel: inboundSchemas.cancel,
} as const;

export type RunStartPayload = z.output<typeof runStartSchema>;

export type RunInbound =
  | { readonly type: "start"; readonly payload: RunStartPayload }
  | {
      readonly type: "modelResponse";
      readonly payload: z.infer<typeof inboundSchemas.modelResponse>;
    }
  | {
      readonly type: "toolResponse";
      readonly payload: z.infer<(typeof runInboundSchemas)["toolResponse"]>;
    }
  | {
      readonly type: "cancel";
      readonly payload: z.infer<typeof inboundSchemas.cancel>;
    };

/** Allows legacy in-process callers to omit operation; parsed wire input is
 * normalized to create by the Zod default below. */
export type StartPayload = z.input<(typeof inboundSchemas)["start"]>;
type ParsedStartPayload = z.output<(typeof inboundSchemas)["start"]>;

export type Inbound =
  | { readonly type: "start"; readonly payload: ParsedStartPayload }
  | {
      readonly type: "modelResponse";
      readonly payload: z.infer<typeof inboundSchemas.modelResponse>;
    }
  | {
      readonly type: "toolResponse";
      readonly payload: z.infer<typeof inboundSchemas.toolResponse>;
    }
  | {
      readonly type: "cancel";
      readonly payload: z.infer<typeof inboundSchemas.cancel>;
    };

export type Envelope<TPayload> = {
  readonly version: 1;
  readonly runID: string;
  readonly type: string;
  readonly payload: TPayload;
};

export class ProtocolError extends Error {
  public constructor(
    public readonly code: "invalidProtocol" | "invalidModelAction",
    message: string,
  ) {
    super(message);
    this.name = "ProtocolError";
  }
}

function rejectDuplicateKeys(text: string): void {
  const stack: Array<{
    readonly kind: "object" | "array";
    readonly keys: Set<string>;
    expectingKey: boolean;
  }> = [];
  let index = 0;
  while (index < text.length) {
    const character = text[index];
    if (character === '"') {
      const start = index;
      index += 1;
      while (index < text.length) {
        if (text[index] === "\\") index += 2;
        else if (text[index] === '"') break;
        else index += 1;
      }
      if (index >= text.length)
        throw new ProtocolError("invalidProtocol", "malformed JSON");
      const top = stack.at(-1);
      if (top?.kind === "object" && top.expectingKey) {
        const key = JSON.parse(text.slice(start, index + 1));
        if (typeof key !== "string" || top.keys.has(key)) {
          throw new ProtocolError("invalidProtocol", "duplicate JSON key");
        }
        top.keys.add(key);
        top.expectingKey = false;
      }
    } else if (character === "{") {
      stack.push({
        kind: "object",
        keys: new Set<string>(),
        expectingKey: true,
      });
    } else if (character === "[") {
      stack.push({
        kind: "array",
        keys: new Set<string>(),
        expectingKey: false,
      });
    } else if (character === "}" || character === "]") {
      stack.pop();
    } else if (character === ",") {
      const top = stack.at(-1);
      if (top?.kind === "object") top.expectingKey = true;
    }
    index += 1;
  }
}

/// Frame size, duplicate-key rejection and the strict envelope, shared by both
/// session kinds. Only the per-type payload schema differs between them, so this
/// stays the single place those checks live.
function decodeEnvelope(line: string): {
  readonly runID: string;
  readonly type: "start" | "modelResponse" | "toolResponse" | "cancel";
  readonly payload: unknown;
} {
  if (Buffer.byteLength(line) > LIMITS.frameBytes) {
    throw new ProtocolError("invalidProtocol", "frame too large");
  }
  rejectDuplicateKeys(line);
  let decoded: unknown;
  try {
    decoded = JSON.parse(line);
  } catch (error) {
    if (error instanceof SyntaxError)
      throw new ProtocolError("invalidProtocol", "malformed JSON");
    throw error;
  }
  const envelope = z
    .object({
      version: z.literal(1),
      runID: uuid,
      type: z.enum(["start", "modelResponse", "toolResponse", "cancel"]),
      payload: z.unknown(),
    })
    .strict()
    .safeParse(decoded);
  if (!envelope.success)
    throw new ProtocolError("invalidProtocol", "invalid envelope");
  return envelope.data;
}

export function parseInbound(line: string): {
  readonly runID: string;
  readonly message: Inbound;
} {
  const { runID, type, payload } = decodeEnvelope(line);
  const parsed = inboundSchemas[type].safeParse(payload);
  if (!parsed.success)
    throw new ProtocolError("invalidProtocol", `invalid ${type} payload`);
  return { runID, message: { type, payload: parsed.data } as Inbound };
}

export function parseRunInbound(line: string): {
  readonly runID: string;
  readonly message: RunInbound;
} {
  const { runID, type, payload } = decodeEnvelope(line);
  const parsed = runInboundSchemas[type].safeParse(payload);
  if (!parsed.success)
    throw new ProtocolError("invalidProtocol", `invalid ${type} payload`);
  return { runID, message: { type, payload: parsed.data } as RunInbound };
}

export function encodeEnvelope<TPayload>(
  runID: string,
  type: string,
  payload: TPayload,
): string {
  const line = JSON.stringify({ version: 1, runID, type, payload });
  if (Buffer.byteLength(line) > LIMITS.frameBytes) {
    throw new ProtocolError("invalidProtocol", "outbound frame too large");
  }
  return `${line}\n`;
}

export function parseToolResponse(name: ToolName, payload: unknown): unknown {
  const parsed = toolResponsePayloadSchemas[name].safeParse(payload);
  if (!parsed.success)
    throw new ProtocolError("invalidProtocol", `invalid ${name} response`);
  return parsed.data;
}

/// What the host sends back to an agent tool's two tools.
///
/// `run_python` reports the run the way a shell would — exit code, both streams,
/// what it wrote — rather than a pass/fail verdict, because the agent is the one
/// deciding what the result means. `finish` only acknowledges.
export const runToolResponsePayloadSchemas = {
  run_python: z
    .object({
      exitCode: z.number().int(),
      stdout: byteString(LIMITS.agentResultBytes, true),
      stderr: byteString(LIMITS.agentResultBytes, true),
      truncated: z.boolean().default(false),
      producedFiles: z
        .array(byteString(LIMITS.targetBytes))
        .max(64)
        .default([]),
    })
    .strict(),
  finish: z.object({ accepted: z.literal(true) }).strict(),
} as const;

export function parseRunToolResponse(
  name: RunToolName,
  payload: unknown,
): unknown {
  const parsed = runToolResponsePayloadSchemas[name].safeParse(payload);
  if (!parsed.success)
    throw new ProtocolError("invalidProtocol", `invalid ${name} response`);
  return parsed.data;
}

export function parseAskUserRequest(
  payload: unknown,
): z.infer<typeof askUserRequestSchema> {
  const parsed = askUserRequestSchema.safeParse(payload);
  if (!parsed.success)
    throw new ProtocolError("invalidProtocol", "invalid ask_user request");
  return parsed.data;
}

export function parseStrictJson(text: string): unknown {
  rejectDuplicateKeys(text);
  try {
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof SyntaxError)
      throw new ProtocolError("invalidModelAction", "malformed action");
    throw error;
  }
}
