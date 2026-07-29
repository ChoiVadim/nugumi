import { defineTool } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { LIMITS, ProtocolError, type RunToolName } from "./protocol.js";
import type { SidecarRuntime } from "./runtime.js";

/// The two tools an agent tool has while it runs.
///
/// Two, not twenty. Everything an agent might reach for — an HTTP API, the
/// user's files, a command-line program, another Python library — it reaches
/// through `run_python`, so a catalog of named capabilities would only be a
/// second, worse spelling of things it can already do. Capabilities get added
/// when a real tool is blocked without one, not in anticipation.
export function createAgentTools(runtime: SidecarRuntime) {
  const call = async (
    name: RunToolName,
    params: Record<string, unknown>,
    callID: string,
    signal: AbortSignal | undefined,
  ) => {
    const result = await runtime.requestTool(name, params, callID, signal);
    if (name === "finish") runtime.finishWith(params);
    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify({ name, payload: result }),
        },
      ],
      details: {},
    };
  };

  return [
    defineTool({
      name: "run_python",
      label: "run_python",
      description:
        "Run a Python script and read back its exit code, stdout and stderr.",
      executionMode: "sequential",
      parameters: Type.Object({
        source: Type.String({ maxLength: 65_536 }),
        purpose: Type.String({ maxLength: 512 }),
      }),
      execute: async (callID, params, signal) => {
        const source = params["source"];
        if (typeof source !== "string" || source.length === 0) {
          throw new ProtocolError("invalidProtocol", "run_python needs source");
        }
        return call("run_python", params, callID, signal);
      },
    }),
    defineTool({
      name: "finish",
      label: "finish",
      description:
        "End the run and hand this text back to the user as the tool's result.",
      executionMode: "sequential",
      parameters: Type.Object({
        text: Type.String({ maxLength: LIMITS.agentResultBytes }),
      }),
      execute: async (callID, params, signal) => {
        const text = params["text"];
        // Checked here as well as in the schema because `finishWith` is what
        // makes `complete()` willing to report success: a run that "finished"
        // with nothing would end as a completed tool that produced no answer,
        // which reads to the user as the tool silently doing nothing.
        if (typeof text !== "string" || text.length === 0) {
          throw new ProtocolError("invalidProtocol", "finish needs text");
        }
        return call("finish", params, callID, signal);
      },
    }),
  ];
}
