import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { SidecarRuntime } from "../dist/runtime.js";

const runID = "11111111-1111-4111-8111-111111111111";
const firstCandidateID = "22222222-2222-4222-8222-222222222222";
const secondCandidateID = "33333333-3333-4333-8333-333333333333";
const firstFingerprint = { value: "a".repeat(64) };
const secondFingerprint = { value: "b".repeat(64) };
const start = {
  version: 1,
  runID,
  type: "start",
  payload: {
    description: "make a tool that uppercases text",
    budgets: { modelTurns: 8, toolCalls: 32, repairs: 3, durationSeconds: 600 },
  },
};

type JsonObject = Record<string, unknown>;

function object(value: unknown): JsonObject {
  if (typeof value !== "object" || value === null) {
    throw new TypeError("expected object");
  }
  return Object.fromEntries(Object.entries(value));
}

function text(value: unknown): string {
  assert.equal(typeof value, "string");
  return String(value);
}

function launch(binary: "agent.mjs" | "gate.mjs", environment: NodeJS.ProcessEnv = process.env) {
  const child = spawn(process.execPath, [`dist/${binary}`], {
    cwd: new URL("..", import.meta.url),
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 8_000);
  child.once("exit", () => clearTimeout(timeout));
  return child;
}

function send(child: ChildProcessWithoutNullStreams, type: string, payload: JsonObject): void {
  child.stdin.write(`${JSON.stringify({ version: 1, runID, type, payload })}\n`);
}

async function drive(
  child: ChildProcessWithoutNullStreams,
  onMessage: (message: JsonObject) => void,
  closeInput = true,
): Promise<{ readonly output: string; readonly stderr: string; readonly exitCode: number | null }> {
  const output: string[] = [];
  const errors: Buffer[] = [];
  child.stderr.on("data", (chunk: Buffer) => errors.push(chunk));
  const lines = createInterface({ input: child.stdout, crlfDelay: Number.POSITIVE_INFINITY });
  for await (const line of lines) {
    output.push(line);
    const message = object(JSON.parse(line));
    onMessage(message);
    if (
      closeInput &&
      (message["type"] === "completed" || message["type"] === "failed")
    ) {
      child.stdin.end();
    }
  }
  const [exitCode] = await once(child, "exit");
  return { output: output.join("\n"), stderr: Buffer.concat(errors).toString(), exitCode };
}

function respondToGate(
  child: ChildProcessWithoutNullStreams,
  message: JsonObject,
  state: { writes: number },
): void {
  if (message["type"] !== "toolRequest") return;
  const envelope = object(message["payload"]);
  const request = object(envelope["request"]);
  const name = text(request["name"]);
  const payload = object(request["payload"]);
  const callID = text(envelope["callID"]);
  if (name === "read_build_context") {
    send(child, "toolResponse", {
      callID,
      result: {
        name,
        payload: { remaining: { modelTurns: 7, toolCalls: 31, repairs: 3 } },
      },
    });
  } else if (name === "write_candidate") {
    state.writes += 1;
    const candidateID = state.writes === 1 ? firstCandidateID : secondCandidateID;
    const fingerprint = state.writes === 1 ? firstFingerprint : secondFingerprint;
    send(child, "toolResponse", {
      callID,
      result: { name, payload: { candidateID, fingerprint } },
    });
  } else if (name === "run_validation") {
    const candidateID = text(payload["candidateID"]);
    const failed = candidateID === firstCandidateID;
    send(child, "toolResponse", {
      callID,
      result: {
        name,
        payload: failed
          ? {
              candidateID,
              fingerprint: firstFingerprint,
              outcome: "failed",
              failure: "wrongOutput",
              expectedOutput: "HELLO",
              actualOutput: "hello",
            }
          : {
              candidateID,
              fingerprint: secondFingerprint,
              outcome: "passed",
              passingFingerprint: secondFingerprint,
            },
      },
    });
  } else {
    send(child, "toolResponse", {
      callID,
      result: {
        name,
        payload: { candidateID: secondCandidateID, fingerprint: secondFingerprint },
      },
    });
  }
}

test("first terminal wins when failure reaches an attested runtime before completion", () => {
  // Given
  const output: string[] = [];
  const runtime = new SidecarRuntime(runID, start.payload, (line) => output.push(line));
  const attestation = { candidateID: secondCandidateID, fingerprint: secondFingerprint };
  runtime.attest(attestation, attestation);

  // When
  runtime.fail("cancelled", "completion-boundary cancellation");
  runtime.complete();

  // Then
  assert.equal(output.length, 1);
  assert.match(output[0] ?? "", /"type":"failed"/);
  assert.doesNotMatch(output[0] ?? "", /"type":"completed"/);
});

test("completed sidecar exits while host keeps stdin open", async () => {
  // Given
  const child = launch("gate.mjs");
  const state = { writes: 0 };
  child.stdin.write(`${JSON.stringify(start)}\n`);

  // When
  const result = await drive(child, (message) => respondToGate(child, message, state), false);

  // Then
  assert.equal(result.exitCode, 0);
  assert.match(result.output, /"type":"completed"/);
  assert.equal(child.killed, false);
});

test("failed sidecar exits while host keeps stdin open", async () => {
  // Given
  const child = launch("agent.mjs");
  child.stdin.write(`${JSON.stringify(start)}\n`);

  // When
  const result = await drive(child, (message) => {
    if (message["type"] !== "modelRequest") return;
    send(child, "modelResponse", {
      requestID: "66666666-6666-4666-8666-666666666666",
      result: { kind: "text", text: '{"version":1,"action":"finalText","text":"x"}' },
    });
  }, false);

  // Then
  assert.equal(result.exitCode, 0);
  assert.match(result.output, /"type":"failed"/);
  assert.equal(child.killed, false);
});

test("real Pi gate repairs wrong output with detail before exact finish attestation", async () => {
  // Given
  const child = launch("gate.mjs", { ...process.env, OPENAI_API_KEY: "credential-sentinel" });
  const names: string[] = [];
  const sources: string[] = [];
  let writeCount = 0;
  let modelRequests = 0;
  child.stdin.write(`${JSON.stringify(start)}\n`);

  // When
  const result = await drive(child, (message) => {
    if (message["type"] === "modelRequest") modelRequests += 1;
    if (message["type"] !== "toolRequest") return;
    const envelope = object(message["payload"]);
    const request = object(envelope["request"]);
    const name = text(request["name"]);
    const payload = object(request["payload"]);
    names.push(name);
    const callID = text(envelope["callID"]);
    if (name === "read_build_context") {
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: { remaining: { modelTurns: 7, toolCalls: 31, repairs: 3 } },
        },
      });
    } else if (name === "write_candidate") {
      writeCount += 1;
      sources.push(text(object(payload["candidate"])["source"]));
      const candidateID = writeCount === 1 ? firstCandidateID : secondCandidateID;
      const fingerprint = writeCount === 1 ? firstFingerprint : secondFingerprint;
      send(child, "toolResponse", {
        callID,
        result: { name, payload: { candidateID, fingerprint } },
      });
    } else if (name === "run_validation") {
      const candidateID = text(payload["candidateID"]);
      const failed = candidateID === firstCandidateID;
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: failed
            ? {
                candidateID,
                fingerprint: firstFingerprint,
                outcome: "failed",
                failure: "wrongOutput",
                fixtureIndex: 0,
                expectedOutput: "HELLO",
                actualOutput: "hello",
                stderrDetail: "",
                stdoutWasTruncated: false,
                stderrWasTruncated: false,
                durationMilliseconds: 4,
              }
            : {
                candidateID,
                fingerprint: secondFingerprint,
                outcome: "passed",
                passingFingerprint: secondFingerprint,
                durationMilliseconds: 3,
              },
        },
      });
    } else {
      assert.equal(name, "finish_candidate");
      assert.equal(text(payload["candidateID"]), secondCandidateID);
      assert.deepEqual(payload["fingerprint"], secondFingerprint);
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: { candidateID: secondCandidateID, fingerprint: secondFingerprint },
        },
      });
    }
  });

  // Then
  assert.equal(result.exitCode, 0);
  assert.equal(modelRequests, 0);
  assert.deepEqual(names, [
    "read_build_context",
    "write_candidate",
    "run_validation",
    "write_candidate",
    "run_validation",
    "finish_candidate",
  ]);
  assert.match(sources[0] ?? "", /print\(sys\.argv\[1\]\)/);
  assert.match(sources[1] ?? "", /\.upper\(\)/);
  assert.match(result.output, /"type":"completed"/);
  assert.match(result.output, new RegExp(secondCandidateID));
  assert.doesNotMatch(result.output, /credential-sentinel/);
  assert.equal(result.stderr, "");
});

test("live bridge serializes four tools and prior structured validation detail", async () => {
  // Given
  const child = launch("agent.mjs");
  let modelTurn = 0;
  const latestCandidateID = firstCandidateID;
  child.stdin.write(`${JSON.stringify(start)}\n`);

  // When
  const result = await drive(child, (message) => {
    const kind = message["type"];
    const payload = object(message["payload"]);
    if (kind === "modelRequest") {
      modelTurn += 1;
      const context = object(JSON.parse(text(payload["user"])));
      const tools = toolArray(context);
      assert.deepEqual(
        tools.map((tool) => text(object(tool)["name"])),
        ["read_build_context", "write_candidate", "run_validation", "finish_candidate"],
      );
      assert.ok(tools.every((tool) => object(tool)["executionMode"] === "sequential"));
      assert.doesNotMatch(text(payload["system"]), /\/Users\//);
      if (modelTurn === 4) {
        const transcript = text(payload["user"]);
        assert.match(transcript, /wrongOutput/);
        assert.match(transcript, /HELLO/);
        assert.match(transcript, /hello/);
      }
      const actions = [
        { version: 1, action: "toolCall", name: "read_build_context", arguments: {} },
        {
          version: 1,
          action: "toolCall",
          name: "write_candidate",
          arguments: {
            candidate: {
              schemaVersion: 1,
              name: "Uppercase",
              brief: "Uppercases text",
              symbolName: "textformat",
              source: "import sys\nprint(sys.argv[1])\n",
              fixtures: [{ input: "hello", expectedOutput: "HELLO" }],
            },
          },
        },
        {
          version: 1,
          action: "toolCall",
          name: "run_validation",
          arguments: { candidateID: firstCandidateID },
        },
        { version: 1, action: "finalText", text: "repair detail observed" },
      ];
      send(child, "modelResponse", {
        requestID: text(payload["requestID"]),
        result: { kind: "text", text: JSON.stringify(actions[modelTurn - 1]) },
      });
      return;
    }
    if (kind !== "toolRequest") return;
    const request = object(payload["request"]);
    const name = text(request["name"]);
    const callID = text(payload["callID"]);
    if (name === "read_build_context") {
      send(child, "toolResponse", {
        callID,
        result: { name, payload: { remaining: { modelTurns: 7, toolCalls: 31, repairs: 3 } } },
      });
    } else if (name === "write_candidate") {
      send(child, "toolResponse", {
        callID,
        result: { name, payload: { candidateID: latestCandidateID, fingerprint: firstFingerprint } },
      });
    } else {
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: {
            candidateID: latestCandidateID,
            fingerprint: firstFingerprint,
            outcome: "failed",
            failure: "wrongOutput",
            expectedOutput: "HELLO",
            actualOutput: "hello",
          },
        },
      });
    }
  });

  // Then
  assert.equal(modelTurn, 4);
  assert.match(result.output, /"code":"invalidCandidate"/);
  assert.doesNotMatch(result.output, /"name":"bash"|"name":"read"|"name":"write"/);
});

function toolArray(context: JsonObject): unknown[] {
  const value = context["tools"];
  assert.ok(Array.isArray(value));
  return value;
}

test("malformed model action emits exactly one invalidModelAction terminal", async () => {
  // Given
  const child = launch("agent.mjs");
  child.stdin.write(`${JSON.stringify(start)}\n`);

  // When
  const result = await drive(child, (message) => {
    if (message["type"] !== "modelRequest") return;
    const payload = object(message["payload"]);
    send(child, "modelResponse", {
      requestID: text(payload["requestID"]),
      result: {
        kind: "text",
        text: '{"version":1,"version":1,"action":"finalText","text":"bad"}',
      },
    });
  });

  // Then
  assert.equal(result.output.match(/"type":"failed"/g)?.length, 1);
  assert.match(result.output, /"code":"invalidModelAction"/);
});

test("mismatched response ID fails closed", async () => {
  // Given
  const child = launch("agent.mjs");
  child.stdin.write(`${JSON.stringify(start)}\n`);

  // When
  const result = await drive(child, (message) => {
    if (message["type"] !== "modelRequest") return;
    send(child, "modelResponse", {
      requestID: "44444444-4444-4444-8444-444444444444",
      result: { kind: "text", text: '{"version":1,"action":"finalText","text":"x"}' },
    });
  });

  // Then
  assert.equal(result.output.match(/"type":"failed"/g)?.length, 1);
  assert.match(result.output, /mismatched model response ID/);
});

test("mismatched tool call ID fails closed", async () => {
  // Given
  const child = launch("agent.mjs");
  child.stdin.write(`${JSON.stringify(start)}\n`);

  // When
  const result = await drive(child, (message) => {
    const payload = object(message["payload"]);
    if (message["type"] === "modelRequest") {
      send(child, "modelResponse", {
        requestID: text(payload["requestID"]),
        result: {
          kind: "text",
          text: '{"version":1,"action":"toolCall","name":"read_build_context","arguments":{}}',
        },
      });
    } else if (message["type"] === "toolRequest") {
      send(child, "toolResponse", {
        callID: "55555555-5555-4555-8555-555555555555",
        result: {
          name: "read_build_context",
          payload: { remaining: { modelTurns: 7, toolCalls: 31, repairs: 3 } },
        },
      });
    }
  });

  // Then
  assert.equal(result.exitCode, 0);
  assert.equal(result.output.match(/"type":"failed"/g)?.length, 1);
  assert.match(result.output, /mismatched tool response ID/);
});

test("cancel and model budget exhaustion each emit one terminal", async () => {
  // Given
  const cancelled = launch("agent.mjs");
  cancelled.stdin.write(`${JSON.stringify(start)}\n`);
  const budgeted = launch("gate.mjs");
  budgeted.stdin.write(
    `${JSON.stringify({
      ...start,
      payload: { ...start.payload, budgets: { ...start.payload.budgets, modelTurns: 1 } },
    })}\n`,
  );

  // When
  const cancelResult = await drive(cancelled, (message) => {
    if (message["type"] === "modelRequest") {
      send(cancelled, "cancel", { reason: "userRequested" });
    }
  });
  const budgetResult = await drive(budgeted, (message) => {
    if (message["type"] !== "toolRequest") return;
    const payload = object(message["payload"]);
    const request = object(payload["request"]);
    send(budgeted, "toolResponse", {
      callID: text(payload["callID"]),
      result: {
        name: text(request["name"]),
        payload: { remaining: { modelTurns: 0, toolCalls: 31, repairs: 3 } },
      },
    });
  });

  // Then
  assert.equal(cancelResult.output.match(/"type":"failed"/g)?.length, 1);
  assert.match(cancelResult.output, /"code":"cancelled"/);
  assert.equal(budgetResult.output.match(/"type":"failed"/g)?.length, 1);
  assert.match(budgetResult.output, /"code":"budgetExhausted"/);
});

test("unknown version, type, duplicate key, and oversized input fail closed", async () => {
  // Given
  const unknown = launch("agent.mjs");
  const unknownType = launch("agent.mjs");
  const duplicate = launch("agent.mjs");
  const oversized = launch("agent.mjs");
  const unknownExitPromise = once(unknown, "exit");
  const unknownTypeExitPromise = once(unknownType, "exit");
  const duplicateExitPromise = once(duplicate, "exit");
  const oversizedExitPromise = once(oversized, "exit");

  // When
  unknown.stdin.end(`${JSON.stringify({ ...start, version: 2 })}\n`);
  unknownType.stdin.end(`${JSON.stringify({ ...start, type: "runtimeMode" })}\n`);
  duplicate.stdin.end(
    '{"version":1,"version":1,"runID":"11111111-1111-4111-8111-111111111111","type":"start","payload":{}}\n',
  );
  oversized.stdin.end(`${" ".repeat(1_048_577)}\n`);
  const [unknownExit] = await unknownExitPromise;
  const [unknownTypeExit] = await unknownTypeExitPromise;
  const [duplicateExit] = await duplicateExitPromise;
  const [oversizedExit] = await oversizedExitPromise;

  // Then
  assert.notEqual(unknownExit, 0);
  assert.notEqual(unknownTypeExit, 0);
  assert.notEqual(duplicateExit, 0);
  assert.notEqual(oversizedExit, 0);
});

test("live dependency graph cannot reach faux provider", async () => {
  // Given
  const files = [
    "agent.mjs",
    "live-provider.js",
    "model-bridge.js",
    "session.js",
    "runtime.js",
    "tools.js",
    "protocol.js",
  ];

  // When
  const sources = await Promise.all(
    files.map((file) => readFile(new URL(`../dist/${file}`, import.meta.url), "utf8")),
  );

  // Then
  assert.ok(sources.every((source) => !source.includes("faux-provider")));
  assert.ok(sources.every((source) => !source.includes("createScriptedFauxProvider")));
});
