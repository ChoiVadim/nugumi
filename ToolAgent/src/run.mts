import { createAgentTools } from "./agent-tools.js";
import { createLiveActionSource } from "./live-provider.js";
import {
  createBridgeProvider,
  parseRunModelAction,
  runBridgeSystemPrompt,
} from "./model-bridge.js";
import {
  parseRunInbound,
  parseRunToolResponse,
  type RunStartPayload,
  type RunToolName,
} from "./protocol.js";
import { runSidecar } from "./session.js";

/// An agent tool's run, as opposed to a tool build. Same hermetic Pi session,
/// same JSONL transport, same model bridge — only the vocabulary and the goal
/// differ, which is exactly what `SidecarDefinition` exists to carry.
await runSidecar<RunStartPayload>({
  parseLine: parseRunInbound,
  parseResponse: (name, payload) =>
    parseRunToolResponse(name as RunToolName, payload),
  systemPrompt:
    "Carry out the user's instruction using run_python, then hand the answer back with finish. Do not ask questions; there is nobody to answer them.",
  makeTools: createAgentTools,
  initialPrompt: (start) =>
    JSON.stringify({
      instruction: start.instruction,
      input: start.input,
      // Names only. The values are already in the environment of every script
      // the host runs for this tool, so the model reads them from os.environ
      // without ever being shown one.
      availableSecrets: start.secretNames,
    }),
  makeProvider: (runtime) =>
    createBridgeProvider(
      createLiveActionSource(
        {
          request: (context, signal) => runtime.requestModel(context, signal),
        },
        (error) => runtime.rejectModelAction(error),
        (text) => runtime.rejectFinalText(text),
        runBridgeSystemPrompt,
        parseRunModelAction,
      ),
    ),
});
