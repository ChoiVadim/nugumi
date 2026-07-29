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
  /// An agent tool's run session speaks a different vocabulary to a build
  /// session, so it supplies its own bridge prompt and action parser. Both still
  /// go through this one transport, which is where a malformed action is turned
  /// into a terminal failure rather than a retry.
  bridgePrompt?: string,
  parseAction: (text: string) => ModelAction<string> = parseModelAction,
): ActionSource {
  return {
    next: async (
      context: Context,
      signal: AbortSignal | undefined,
    ): Promise<ModelAction<string>> => {
      try {
        const action = parseAction(
          await transport.request(
            serializeContext(context, bridgePrompt),
            signal,
          ),
        );
        if (action.action === "finalText") onFinalText(action.text);
        return action;
      } catch (error) {
        const typedError =
          error instanceof Error ? error : new Error("model action failure");
        onActionError(typedError);
        throw typedError;
      }
    },
  };
}
