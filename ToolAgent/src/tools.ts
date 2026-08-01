import { defineTool } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { ProtocolError, type ToolName } from "./protocol.js";
import type { SidecarRuntime } from "./runtime.js";

function requestPayload(
  name: ToolName,
  params: Record<string, unknown>,
): Record<string, unknown> {
  if (name !== "ask_user") return params;
  const question = params["question"];
  if (
    Object.keys(params).length !== 1 ||
    typeof question !== "string" ||
    question.length === 0 ||
    Buffer.byteLength(question) > 1_024
  ) {
    throw new ProtocolError("invalidProtocol", "invalid ask_user request");
  }
  return params;
}

export function createTools(runtime: SidecarRuntime) {
  const commonCandidate = {
    schemaVersion: Type.Literal(1),
    name: Type.String({ maxLength: 128 }),
    brief: Type.String({ maxLength: 1024 }),
    symbolName: Type.String({ maxLength: 128 }),
    input: Type.Union([
      Type.Literal("selection"),
      Type.Literal("ask"),
      Type.Literal("dictation"),
      Type.Literal("clipboardText"),
      Type.Literal("clipboardURL"),
      Type.Literal("files"),
      Type.Literal("screenshot"),
      Type.Literal("screenshotText"),
      Type.Literal("none"),
    ]),
    output: Type.Union([
      Type.Literal("panel"),
      Type.Literal("replace"),
      Type.Literal("clipboard"),
      Type.Literal("files"),
      Type.Literal("notify"),
      Type.Literal("notes"),
    ]),
    trigger: Type.Union([
      Type.Literal("always"),
      Type.Literal("selection"),
      Type.Literal("link"),
      Type.Literal("files"),
    ]),
    hosts: Type.Array(Type.String({ maxLength: 255 }), { maxItems: 16 }),
    extensions: Type.Array(Type.String({ maxLength: 255 }), { maxItems: 16 }),
  } as const;
  const candidate = Type.Union([
    Type.Object({
      ...commonCandidate,
      kind: Type.Literal("prompt"),
      input: Type.Union([
        Type.Literal("selection"),
        Type.Literal("ask"),
        Type.Literal("dictation"),
        Type.Literal("screenshotText"),
      ]),
      output: Type.Union([
        Type.Literal("panel"),
        Type.Literal("replace"),
        Type.Literal("clipboard"),
        Type.Literal("notes"),
      ]),
      trigger: Type.Union([Type.Literal("always"), Type.Literal("selection")]),
      prompt: Type.String({ maxLength: 16_384 }),
      appliesTargetLanguage: Type.Boolean(),
    }),
    Type.Object({
      ...commonCandidate,
      kind: Type.Literal("native"),
      output: Type.Union([
        Type.Literal("replace"),
        Type.Literal("clipboard"),
        Type.Literal("notify"),
      ]),
      nativeAction: Type.Union([
        Type.Literal("openApp"),
        Type.Literal("openAppFullScreen"),
        Type.Literal("sendTextToApp"),
        Type.Literal("revealInFinder"),
        Type.Literal("openURL"),
        Type.Literal("runShortcut"),
        Type.Literal("saveToNote"),
      ]),
      target: Type.String({ maxLength: 8192 }),
    }),
    Type.Object({
      ...commonCandidate,
      kind: Type.Literal("python"),
      source: Type.String({ maxLength: 65_536 }),
      fixtures: Type.Array(
        Type.Object({
          input: Type.String({ maxLength: 8192 }),
          expectedOutput: Type.Optional(Type.String({ maxLength: 16_384 })),
        }),
        { minItems: 0, maxItems: 3 },
      ),
      outputDirectory: Type.Optional(Type.String({ maxLength: 8192 })),
      timeoutSeconds: Type.Integer({ minimum: 5, maximum: 1800 }),
      declaresNetwork: Type.Boolean(),
      // Optional, not required-and-empty: most tools need no credential at all,
      // and making every candidate carry `secretNames: []` would break every
      // shape the model already knows how to write.
      secretNames: Type.Optional(
        Type.Array(Type.String({ maxLength: 64 }), { maxItems: 8 }),
      ),
    }),
    Type.Object({
      ...commonCandidate,
      kind: Type.Literal("agent"),
      output: Type.Union([
        Type.Literal("panel"),
        Type.Literal("replace"),
        Type.Literal("clipboard"),
        Type.Literal("notify"),
        Type.Literal("notes"),
      ]),
      prompt: Type.String({ maxLength: 16_384 }),
      // At most one, with no expectedOutput: an agent's answer is not
      // predictable, so the fixture is the input a harmless trial run should
      // use, and none at all means running it for real would do something the
      // user did not ask for yet.
      fixtures: Type.Array(
        Type.Object({ input: Type.String({ maxLength: 8192 }) }),
        { minItems: 0, maxItems: 1 },
      ),
      maxSteps: Type.Integer({ minimum: 1, maximum: 24 }),
      timeoutSeconds: Type.Integer({ minimum: 15, maximum: 900 }),
      secretNames: Type.Optional(
        Type.Array(Type.String({ maxLength: 64 }), { maxItems: 8 }),
      ),
    }),
  ]);
  const tool = <T extends ReturnType<typeof Type.Object>>(definition: {
    readonly name: ToolName;
    readonly description: string;
    readonly parameters: T;
  }) =>
    defineTool({
      ...definition,
      label: definition.name,
      executionMode: "sequential",
      execute: async (callID, params, signal) => {
        const result = await runtime.requestTool(
          definition.name,
          requestPayload(definition.name, params),
          callID,
          signal,
        );
        if (definition.name === "finish_candidate")
          runtime.attest(params, result);
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({ name: definition.name, payload: result }),
            },
          ],
          details: {},
        };
      },
    });
  return [
    tool({
      name: "read_build_context",
      description: "Read bounded build context.",
      parameters: Type.Object({}),
    }),
    tool({
      name: "write_candidate",
      description: "Submit an immutable candidate.",
      parameters: Type.Object({ candidate }),
    }),
    tool({
      name: "run_validation",
      description: "Ask the host to validate a candidate.",
      parameters: Type.Object({ candidateID: Type.String({ format: "uuid" }) }),
    }),
    tool({
      name: "finish_candidate",
      description: "Finish an exactly attested candidate.",
      parameters: Type.Object({
        candidateID: Type.String({ format: "uuid" }),
        fingerprint: Type.Object({
          value: Type.String({ pattern: "^[a-f0-9]{64}$" }),
        }),
      }),
    }),
    tool({
      name: "ask_user",
      description: "Ask one bounded clarification question.",
      parameters: Type.Object({
        question: Type.String({ minLength: 1, maxLength: 1_024 }),
      }),
    }),
  ];
}
