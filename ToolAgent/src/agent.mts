import { createBridgeProvider } from "./model-bridge.js";
import { createLiveActionSource } from "./live-provider.js";
import { buildDefinition, runSidecar } from "./session.js";

await runSidecar(
  buildDefinition((runtime) =>
    createBridgeProvider(
      createLiveActionSource(
        {
          request: (context, signal) => runtime.requestModel(context, signal),
        },
        (error) => runtime.rejectModelAction(error),
        (text) => runtime.rejectFinalText(text),
      ),
    ),
  ),
);
