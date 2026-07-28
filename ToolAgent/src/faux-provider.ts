import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type Context,
  type Message,
  type ToolResultMessage,
} from "@earendil-works/pi-ai";

const badCandidate = {
  schemaVersion: 1,
  kind: "python",
  name: "Uppercase",
  brief: "Uppercases copied text",
  symbolName: "textformat",
  input: "clipboardText",
  output: "clipboard",
  trigger: "always",
  hosts: [],
  extensions: [],
  source: "import sys\nprint(sys.argv[1])\n",
  fixtures: [{ input: "hello", expectedOutput: "HELLO" }],
  timeoutSeconds: 30,
  declaresNetwork: false,
} as const;

const repairedCandidate = {
  ...badCandidate,
  source: "import sys\nprint(sys.argv[1].upper())\n",
} as const;

function call(name: string, arguments_: Record<string, unknown>) {
  return fauxToolCall(name, arguments_, { id: crypto.randomUUID() });
}

function toolResults(messages: readonly Message[]): readonly ToolResultMessage[] {
  return messages.filter((message): message is ToolResultMessage => message.role === "toolResult");
}

function resultPayload(result: ToolResultMessage): {
  readonly name: string;
  readonly payload: Record<string, unknown>;
} {
  const text = result.content.find((content) => content.type === "text");
  if (text?.type !== "text") throw new Error("missing faux tool result");
  const decoded: unknown = JSON.parse(text.text);
  if (
    typeof decoded !== "object" ||
    decoded === null ||
    !("name" in decoded) ||
    typeof decoded.name !== "string" ||
    !("payload" in decoded) ||
    typeof decoded.payload !== "object" ||
    decoded.payload === null
  ) {
    throw new Error("invalid faux tool result");
  }
  return { name: decoded.name, payload: Object.fromEntries(Object.entries(decoded.payload)) };
}

function requiredString(payload: Record<string, unknown>, key: string): string {
  const value = payload[key];
  if (typeof value !== "string") throw new Error(`missing ${key}`);
  return value;
}

function requiredFingerprint(payload: Record<string, unknown>): { readonly value: string } {
  const value = payload["fingerprint"];
  if (
    typeof value !== "object" ||
    value === null ||
    !("value" in value) ||
    typeof value.value !== "string"
  ) {
    throw new Error("missing fingerprint");
  }
  return { value: value.value };
}

export function createScriptedFauxProvider(onTurn: () => void) {
  const faux = fauxProvider({ provider: "nugumi-gate", api: "nugumi-gate-v1" });
  const response = (context: Context) => {
      onTurn();
      const results = toolResults(context.messages);
      if (results.length === 0) {
        return fauxAssistantMessage(call("read_build_context", {}), {
          stopReason: "toolUse",
        });
      }
      const lastResult = results.at(-1);
      if (lastResult === undefined) throw new Error("missing faux tool result");
      const last = resultPayload(lastResult);
      const writes = results.filter((result) => result.toolName === "write_candidate").length;
      if (last.name === "read_build_context") {
        return fauxAssistantMessage(
          call("write_candidate", { candidate: badCandidate }),
          { stopReason: "toolUse" },
        );
      }
      if (last.name === "write_candidate") {
        return fauxAssistantMessage(
          call("run_validation", {
            candidateID: requiredString(last.payload, "candidateID"),
          }),
          { stopReason: "toolUse" },
        );
      }
      if (last.name === "run_validation" && writes === 1) {
        const detail = JSON.stringify(last.payload);
        if (
          !detail.includes("wrongOutput") ||
          !detail.includes("HELLO") ||
          !detail.includes("hello")
        ) {
          throw new Error("repair context omitted structured validation detail");
        }
        return fauxAssistantMessage(
          call("write_candidate", { candidate: repairedCandidate }),
          { stopReason: "toolUse" },
        );
      }
      if (last.name === "run_validation") {
        return fauxAssistantMessage(
          call("finish_candidate", {
            candidateID: requiredString(last.payload, "candidateID"),
            fingerprint: requiredFingerprint(last.payload),
          }),
          { stopReason: "toolUse" },
        );
      }
      return fauxAssistantMessage("candidate attested");
    };
  faux.setResponses(Array.from({ length: 8 }, () => response));
  return faux;
}
