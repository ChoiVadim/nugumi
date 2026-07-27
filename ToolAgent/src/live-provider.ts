import type { Context } from "@earendil-works/pi-ai";
import {
  parseModelAction,
  serializeContext,
  type ActionSource,
  type ModelAction,
} from "./model-bridge.js";

export interface LiveModelTransport {
  request(
    context: { readonly system: string; readonly user: string },
    signal: AbortSignal | undefined,
  ): Promise<string>;
}

export function createLiveActionSource(
  transport: LiveModelTransport,
  onActionError: (error: Error) => void,
  onFinalText: (text: string) => void,
): ActionSource {
  return {
    next: async (
      context: Context,
      signal: AbortSignal | undefined,
    ): Promise<ModelAction> => {
      try {
        const action = parseModelAction(await transport.request(serializeContext(context), signal));
        if (action.action === "finalText") onFinalText(action.text);
        return action;
      } catch (error) {
        const typedError = error instanceof Error ? error : new Error("model action failure");
        onActionError(typedError);
        throw typedError;
      }
    },
  };
}
