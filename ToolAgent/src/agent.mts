import { createBridgeProvider } from "./model-bridge.js";
import { createLiveActionSource } from "./live-provider.js";
import { runSidecar } from "./session.js";

await runSidecar((runtime) =>
  createBridgeProvider(
    createLiveActionSource({
      request: (context, signal) => runtime.requestModel(context, signal),
    }, (error) => runtime.rejectModelAction(error), (text) => runtime.rejectFinalText(text)),
  ),
);
