import {
  createAssistantMessageEventStream,
  createProvider,
  type AssistantMessage,
  type AssistantMessageEventStream,
  type Context,
  type Model,
  type Provider,
  type SimpleStreamOptions,
} from "@earendil-works/pi-ai";
import { z } from "zod";
import {
  candidateSchema,
  LIMITS,
  parseStrictJson,
  ProtocolError,
  TOOL_NAMES,
  type ToolName,
} from "./protocol.js";

const actionSchema = z.discriminatedUnion("action", [
  z
    .object({
      version: z.literal(1),
      action: z.literal("finalText"),
      text: z.string().refine((value) => Buffer.byteLength(value) <= LIMITS.safeMessageBytes),
    })
    .strict(),
  z
    .object({
      version: z.literal(1),
      action: z.literal("toolCall"),
      name: z.enum(TOOL_NAMES),
      arguments: z.unknown(),
    })
    .strict(),
]);

const argumentSchemas = {
  read_build_context: z.object({}).strict(),
  write_candidate: z.object({ candidate: candidateSchema }).strict(),
  run_validation: z.object({ candidateID: z.string().uuid() }).strict(),
  finish_candidate: z
    .object({
      candidateID: z.string().uuid(),
      fingerprint: z.object({ value: z.string().regex(/^[a-f0-9]{64}$/) }).strict(),
    })
    .strict(),
} as const;

export type ModelAction =
  | { readonly action: "finalText"; readonly text: string }
  | {
      readonly action: "toolCall";
      readonly name: ToolName;
      readonly arguments: Record<string, unknown>;
    };

export interface ActionSource {
  next(context: Context, signal: AbortSignal | undefined): Promise<ModelAction>;
}

export function parseModelAction(text: string): ModelAction {
  if (Buffer.byteLength(text) > LIMITS.modelTextBytes) {
    throw new ProtocolError("invalidModelAction", "model action too large");
  }
  let decoded: unknown;
  try {
    decoded = parseStrictJson(text);
  } catch (error) {
    if (error instanceof ProtocolError) {
      throw new ProtocolError("invalidModelAction", error.message);
    }
    throw error;
  }
  const parsed = actionSchema.safeParse(decoded);
  if (!parsed.success) throw new ProtocolError("invalidModelAction", "invalid model action");
  if (parsed.data.action === "finalText") {
    return { action: "finalText", text: parsed.data.text };
  }
  const argumentsResult = argumentSchemas[parsed.data.name].safeParse(parsed.data.arguments);
  if (!argumentsResult.success) {
    throw new ProtocolError("invalidModelAction", "invalid tool arguments");
  }
  return {
    action: "toolCall",
    name: parsed.data.name,
    arguments: argumentsResult.data,
  };
}

const zeroUsage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
} as const;

function assistantMessage(model: Model<string>, action: ModelAction): AssistantMessage {
  const content =
    action.action === "finalText"
      ? [{ type: "text", text: action.text } as const]
      : [
          {
            type: "toolCall",
            id: crypto.randomUUID(),
            name: action.name,
            arguments: action.arguments,
          } as const,
        ];
  return {
    role: "assistant",
    content,
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: zeroUsage,
    stopReason: action.action === "toolCall" ? "toolUse" : "stop",
    timestamp: Date.now(),
  };
}

function streamAction(
  source: ActionSource,
  model: Model<string>,
  context: Context,
  options: SimpleStreamOptions | undefined,
): AssistantMessageEventStream {
  const stream = createAssistantMessageEventStream();
  const initial = assistantMessage(model, { action: "finalText", text: "" });
  stream.push({ type: "start", partial: initial });
  void source
    .next(context, options?.signal)
    .then((action) => {
      const message = assistantMessage(model, action);
      stream.push({
        type: "done",
        reason: action.action === "toolCall" ? "toolUse" : "stop",
        message,
      });
      stream.end();
    })
    .catch((error: unknown) => {
      const message: AssistantMessage = {
        ...initial,
        stopReason: options?.signal?.aborted ? "aborted" : "error",
        errorMessage: error instanceof Error ? error.message : "provider failure",
      };
      stream.push({
        type: "error",
        reason: message.stopReason === "aborted" ? "aborted" : "error",
        error: message,
      });
      stream.end();
    });
  return stream;
}

export function createBridgeProvider(source: ActionSource): {
  readonly provider: Provider<string>;
  readonly model: Model<string>;
} {
  const model: Model<string> = {
    id: "nugumi-bridge-v1",
    name: "Nugumi Bridge",
    api: "nugumi-jsonl-v1",
    provider: "nugumi",
    baseUrl: "memory://nugumi",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128_000,
    maxTokens: 8_192,
  };
  const provider = createProvider({
    id: "nugumi",
    name: "Nugumi",
    auth: {
      apiKey: {
        name: "in-memory",
        resolve: async () => ({ auth: { apiKey: "in-memory" }, source: "in-memory" }),
      },
    },
    models: [model],
    api: {
      stream: (requestedModel, context, options) =>
        streamAction(source, requestedModel, context, options),
      streamSimple: (requestedModel, context, options) =>
        streamAction(source, requestedModel, context, options),
    },
  });
  return { provider, model };
}

export function serializeContext(context: Context): {
  readonly system: string;
  readonly user: string;
} {
  const system = context.systemPrompt ?? "";
  const user = JSON.stringify({ messages: context.messages, tools: context.tools ?? [] });
  if (
    Buffer.byteLength(system) + Buffer.byteLength(user) > LIMITS.transcriptBytes
  ) {
    throw new ProtocolError("invalidProtocol", "model context too large");
  }
  return { system, user };
}
