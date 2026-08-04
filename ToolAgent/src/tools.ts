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

// Mirrors the recursive `layoutNode` in protocol.ts: four node kinds behind a
// `node` discriminator, with a grid or list's `cell`/`row` recursing into the
// same union. `Type.Cyclic`/`Type.This` are TypeBox's way to express that
// self-reference as JSON Schema (`$defs`/`$ref`) rather than the type-level
// `z.lazy` zod uses. This is what the model actually sees when it calls the
// tool, so it is the field's only teacher — the depth limit and the "no
// repeater inside a repeater" rule are enforced downstream, same as in
// protocol.ts, not by this shape.
const layoutNode = Type.Cyclic(
  {
    layoutNode: Type.Union([
      Type.Object({
        node: Type.Literal("grid"),
        cell: Type.This(),
        minimumWidth: Type.Integer({ minimum: 48, maximum: 400 }),
        empty: Type.String({ minLength: 1, maxLength: 120 }),
      }),
      Type.Object({
        node: Type.Literal("list"),
        row: Type.This(),
        empty: Type.String({ minLength: 1, maxLength: 120 }),
      }),
      Type.Object({
        node: Type.Literal("card"),
        title: Type.String(),
        subtitle: Type.Optional(Type.String()),
        icon: Type.Optional(
          Type.String({ pattern: "^(file:\\$.+|symbol:.*)$" }),
        ),
        drag: Type.Optional(Type.String({ pattern: "^(file|text):\\$.+$" })),
        tap: Type.Optional(Type.String({ pattern: "^(open|reveal):\\$.+$" })),
      }),
      Type.Object({ node: Type.Literal("text"), value: Type.String() }),
    ]),
  },
  "layoutNode",
);

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
      Type.Literal("files"),
      Type.Literal("screenshot"),
      Type.Literal("screenshotText"),
      Type.Literal("drawnScreen"),
      Type.Literal("none"),
    ]),
    output: Type.Union([
      Type.Literal("panel"),
      Type.Literal("replace"),
      Type.Literal("clipboard"),
      Type.Literal("files"),
      Type.Literal("notify"),
      Type.Literal("notes"),
      Type.Literal("speak"),
      Type.Literal("annotate"),
      Type.Literal("surface"),
    ]),
    trigger: Type.Union([
      Type.Literal("always"),
      Type.Literal("selection"),
      Type.Literal("files"),
    ]),
    hosts: Type.Array(Type.String({ maxLength: 255 }), { maxItems: 16 }),
    extensions: Type.Array(Type.String({ maxLength: 255 }), { maxItems: 16 }),
  } as const;
  const candidate = Type.Union([
    Type.Object({
      ...commonCandidate,
      kind: Type.Literal("prompt"),
      // Inherits commonCandidate's input and output on purpose. A narrower copy
      // here is a second list to keep in step, and the one time it fell behind
      // it rejected exactly the candidate the prompt had asked for.
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
        Type.Literal("notes"),
        Type.Literal("speak"),
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
      // Present exactly when output is "surface" — mirrors
      // ToolAgentCandidateV1.layout and protocol.ts's pythonCandidate.layout.
      layout: Type.Optional(layoutNode),
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
        Type.Literal("speak"),
        Type.Literal("annotate"),
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
