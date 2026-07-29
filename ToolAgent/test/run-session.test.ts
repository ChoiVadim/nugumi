import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { test } from "node:test";

/// End-to-end cover for the agent-tool *run* sidecar: the host drives it with
/// canned model actions and checks it asks for the right things and finishes
/// with an answer. No model, no Swift — just the protocol both ends have to
/// agree on, which is exactly the seam a unit test on either side cannot reach.

const runID = "44444444-4444-4444-8444-444444444444";

const start = {
  version: 1,
  runID,
  type: "start",
  payload: {
    instruction: "Say how many words the input has.",
    input: "one two three",
    budgets: {
      modelTurns: 8,
      toolCalls: 8,
      repairs: 0,
      durationSeconds: 60,
    },
    secretNames: ["OPENAI_API_KEY"],
  },
};

type JsonObject = Record<string, unknown>;

function object(value: unknown): JsonObject {
  if (typeof value !== "object" || value === null) {
    throw new TypeError("expected object");
  }
  return Object.fromEntries(Object.entries(value));
}

function launch() {
  const child = spawn(process.execPath, ["dist/run.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 8_000);
  child.once("exit", () => clearTimeout(timeout));
  return child;
}

function send(
  child: ChildProcessWithoutNullStreams,
  type: string,
  payload: JsonObject,
): void {
  child.stdin.write(
    `${JSON.stringify({ version: 1, runID, type, payload })}\n`,
  );
}

async function drive(
  child: ChildProcessWithoutNullStreams,
  onMessage: (message: JsonObject) => void,
): Promise<{ readonly output: string; readonly exitCode: number | null }> {
  const output: string[] = [];
  const lines = createInterface({
    input: child.stdout,
    crlfDelay: Number.POSITIVE_INFINITY,
  });
  for await (const line of lines) {
    output.push(line);
    const message = object(JSON.parse(line));
    onMessage(message);
    if (message["type"] === "completed" || message["type"] === "failed") {
      child.stdin.end();
    }
  }
  const [exitCode] = await once(child, "exit");
  return { output: output.join("\n"), exitCode };
}

function action(value: unknown): string {
  return JSON.stringify(value);
}

test("a run writes a script, reads its output, and finishes with an answer", async () => {
  const child = launch();
  child.stdin.write(`${JSON.stringify(start)}\n`);

  const toolCalls: string[] = [];
  let modelTurns = 0;
  let sawInstruction = false;
  let sawSecretName = false;

  const { output } = await drive(child, (message) => {
    if (message["type"] === "modelRequest") {
      const payload = object(message["payload"]);
      const user = String(payload["user"]);
      // The instruction and the input reach the model, and the secret's *name*
      // does — its value must never appear anywhere in this protocol.
      if (user.includes("Say how many words")) sawInstruction = true;
      if (user.includes("OPENAI_API_KEY")) sawSecretName = true;

      modelTurns += 1;
      const text =
        modelTurns === 1
          ? action({
              version: 1,
              action: "toolCall",
              name: "run_python",
              arguments: {
                source: "import sys\nprint(len(sys.argv))\n",
                purpose: "count the words",
              },
            })
          : modelTurns === 2
            ? action({
                version: 1,
                action: "toolCall",
                name: "finish",
                arguments: { text: "Three words." },
              })
            : action({ version: 1, action: "finalText", text: "done" });
      send(child, "modelResponse", {
        requestID: payload["requestID"],
        result: { kind: "text", text },
      });
      return;
    }
    if (message["type"] === "toolRequest") {
      const envelope = object(message["payload"]);
      const request = object(envelope["request"]);
      const name = String(request["name"]);
      toolCalls.push(name);
      send(child, "toolResponse", {
        callID: envelope["callID"],
        result:
          name === "run_python"
            ? {
                name,
                payload: {
                  exitCode: 0,
                  stdout: "3\n",
                  stderr: "",
                  truncated: false,
                  producedFiles: [],
                },
              }
            : { name, payload: { accepted: true } },
      });
    }
  });

  assert.ok(sawInstruction, "the model was given the tool's instruction");
  assert.ok(sawSecretName, "the model was told which secrets exist");
  assert.deepEqual(toolCalls, ["run_python", "finish"]);
  assert.match(output, /"type":"completed"/);
  assert.match(output, /Three words\./);
});

/// A run that stops talking without calling finish must not look successful:
/// the host has no answer to show, and reporting completion would surface an
/// empty result as if the tool had done its job.
test("a run that never calls finish fails instead of completing", async () => {
  const child = launch();
  child.stdin.write(`${JSON.stringify(start)}\n`);

  const { output } = await drive(child, (message) => {
    if (message["type"] !== "modelRequest") return;
    const payload = object(message["payload"]);
    send(child, "modelResponse", {
      requestID: payload["requestID"],
      result: {
        kind: "text",
        text: action({ version: 1, action: "finalText", text: "done" }),
      },
    });
  });

  assert.match(output, /"type":"failed"/);
  assert.doesNotMatch(output, /"type":"completed"/);
});

/// The build session's five tools must not be reachable from a run. If they
/// were, an agent tool could write and attest a *new tool* while pretending to
/// answer a question.
test("build-session tools are not callable from a run", async () => {
  const child = launch();
  child.stdin.write(`${JSON.stringify(start)}\n`);

  const { output } = await drive(child, (message) => {
    if (message["type"] !== "modelRequest") return;
    const payload = object(message["payload"]);
    send(child, "modelResponse", {
      requestID: payload["requestID"],
      result: {
        kind: "text",
        text: action({
          version: 1,
          action: "toolCall",
          name: "read_build_context",
          arguments: {},
        }),
      },
    });
  });

  assert.match(output, /"code":"invalidModelAction"/);
  assert.doesNotMatch(output, /read_build_context/);
});
