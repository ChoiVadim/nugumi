import { z } from "zod";

export const LIMITS = {
  frameBytes: 1_048_576,
  transcriptBytes: 512 * 1024,
  descriptionBytes: 8 * 1024,
  modelTextBytes: 512 * 1024,
  safeMessageBytes: 1024,
  nameBytes: 128,
  briefBytes: 1024,
  symbolBytes: 128,
  sourceBytes: 64 * 1024,
  fixtureInputBytes: 8 * 1024,
  fixtureOutputBytes: 16 * 1024,
  diagnosticBytes: 16 * 1024,
} as const;

export const TOOL_NAMES = [
  "read_build_context",
  "write_candidate",
  "run_validation",
  "finish_candidate",
] as const;

export type ToolName = (typeof TOOL_NAMES)[number];

const byteString = (maximum: number, allowEmpty = false) =>
  z.string().refine(
    (value) => (allowEmpty || value.length > 0) && Buffer.byteLength(value) <= maximum,
    "string exceeds UTF-8 byte limit",
  );

const uuid = z.string().uuid();
const fingerprint = z.object({ value: z.string().regex(/^[a-f0-9]{64}$/) }).strict();
const budgets = z
  .object({
    modelTurns: z.number().int().min(1).max(8),
    toolCalls: z.number().int().min(1).max(32),
    repairs: z.number().int().min(0).max(3),
    durationSeconds: z.number().int().min(1).max(600),
  })
  .strict();

export const candidateSchema = z
  .object({
    schemaVersion: z.literal(1),
    name: byteString(LIMITS.nameBytes),
    brief: byteString(LIMITS.briefBytes),
    symbolName: byteString(LIMITS.symbolBytes),
    source: byteString(LIMITS.sourceBytes),
    fixtures: z
      .array(
        z
          .object({
            input: byteString(LIMITS.fixtureInputBytes),
            expectedOutput: byteString(LIMITS.fixtureOutputBytes, true),
          })
          .strict(),
      )
      .min(1)
      .max(3),
  })
  .strict();

export type Candidate = z.infer<typeof candidateSchema>;

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
    })
    .strict(),
  write_candidate: z.object({ candidateID: uuid, fingerprint }).strict(),
  run_validation: z
    .object({
      candidateID: uuid,
      fingerprint,
      outcome: z.enum(["passed", "failed"]),
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
} as const;

const modelResult = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("text"), text: byteString(LIMITS.modelTextBytes) }).strict(),
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
  start: z.object({ description: byteString(LIMITS.descriptionBytes), budgets }).strict(),
  modelResponse: z.object({ requestID: uuid, result: modelResult }).strict(),
  toolResponse: z
    .object({
      callID: uuid,
      result: z.object({ name: z.enum(TOOL_NAMES), payload: z.unknown() }).strict(),
    })
    .strict(),
  cancel: z.object({ reason: z.enum(["userRequested", "deadlineExceeded"]) }).strict(),
} as const;

export type StartPayload = z.infer<(typeof inboundSchemas)["start"]>;

export type Inbound =
  | { readonly type: "start"; readonly payload: StartPayload }
  | { readonly type: "modelResponse"; readonly payload: z.infer<typeof inboundSchemas.modelResponse> }
  | { readonly type: "toolResponse"; readonly payload: z.infer<typeof inboundSchemas.toolResponse> }
  | { readonly type: "cancel"; readonly payload: z.infer<typeof inboundSchemas.cancel> };

export type Envelope<TPayload> = {
  readonly version: 1;
  readonly runID: string;
  readonly type: string;
  readonly payload: TPayload;
};

export class ProtocolError extends Error {
  public constructor(public readonly code: "invalidProtocol" | "invalidModelAction", message: string) {
    super(message);
    this.name = "ProtocolError";
  }
}

function rejectDuplicateKeys(text: string): void {
  const stack: Array<{ readonly kind: "object" | "array"; readonly keys: Set<string>; expectingKey: boolean }> = [];
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
      if (index >= text.length) throw new ProtocolError("invalidProtocol", "malformed JSON");
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
      stack.push({ kind: "object", keys: new Set<string>(), expectingKey: true });
    } else if (character === "[") {
      stack.push({ kind: "array", keys: new Set<string>(), expectingKey: false });
    } else if (character === "}" || character === "]") {
      stack.pop();
    } else if (character === ",") {
      const top = stack.at(-1);
      if (top?.kind === "object") top.expectingKey = true;
    }
    index += 1;
  }
}

export function parseInbound(line: string): { readonly runID: string; readonly message: Inbound } {
  if (Buffer.byteLength(line) > LIMITS.frameBytes) {
    throw new ProtocolError("invalidProtocol", "frame too large");
  }
  rejectDuplicateKeys(line);
  let decoded: unknown;
  try {
    decoded = JSON.parse(line);
  } catch (error) {
    if (error instanceof SyntaxError) throw new ProtocolError("invalidProtocol", "malformed JSON");
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
  if (!envelope.success) throw new ProtocolError("invalidProtocol", "invalid envelope");
  const { runID, type, payload } = envelope.data;
  const parsed = inboundSchemas[type].safeParse(payload);
  if (!parsed.success) throw new ProtocolError("invalidProtocol", `invalid ${type} payload`);
  return { runID, message: { type, payload: parsed.data } as Inbound };
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
  if (!parsed.success) throw new ProtocolError("invalidProtocol", `invalid ${name} response`);
  return parsed.data;
}

export function parseStrictJson(text: string): unknown {
  rejectDuplicateKeys(text);
  try {
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof SyntaxError) throw new ProtocolError("invalidModelAction", "malformed action");
    throw error;
  }
}
