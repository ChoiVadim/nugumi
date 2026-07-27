import { defineTool } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { ToolName } from "./protocol.js";
import type { SidecarRuntime } from "./runtime.js";

export function createTools(runtime: SidecarRuntime) {
  const candidate = Type.Object({
    schemaVersion: Type.Literal(1),
    name: Type.String({ maxLength: 128 }),
    brief: Type.String({ maxLength: 1024 }),
    symbolName: Type.String({ maxLength: 128 }),
    source: Type.String({ maxLength: 65_536 }),
    fixtures: Type.Array(
      Type.Object({
        input: Type.String({ maxLength: 8192 }),
        expectedOutput: Type.String({ maxLength: 16_384 }),
      }),
      { minItems: 1, maxItems: 3 },
    ),
  });
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
        const result = await runtime.requestTool(definition.name, params, callID, signal);
        if (definition.name === "finish_candidate") runtime.attest(params, result);
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
  ];
}
