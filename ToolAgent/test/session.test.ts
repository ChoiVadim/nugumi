import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { parseModelAction } from "../dist/model-bridge.js";
import { parseInbound } from "../dist/protocol.js";
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
const fixStart = {
  ...start,
  payload: {
    ...start.payload,
    operation: "fix",
    description: "Repair this tool without changing its intended behavior.",
    currentTool: {
      kind: "python",
      name: "Uppercase",
      brief: "Uppercases selected text",
      symbolName: "textformat",
      input: "selection",
      output: "clipboard",
      trigger: "always",
      hosts: [],
      extensions: [],
      source: "import sys\nprint(sys.argv[1])\n",
      timeoutSeconds: 30,
      declaresNetwork: false,
    },
    failure: "Expected HELLO but received hello.",
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

function launch(
  binary: "agent.mjs" | "gate.mjs",
  environment: NodeJS.ProcessEnv = process.env,
) {
  const child = spawn(process.execPath, [`dist/${binary}`], {
    cwd: new URL("..", import.meta.url),
    env: environment,
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
  closeInput = true,
): Promise<{
  readonly output: string;
  readonly stderr: string;
  readonly exitCode: number | null;
}> {
  const output: string[] = [];
  const errors: Buffer[] = [];
  child.stderr.on("data", (chunk: Buffer) => errors.push(chunk));
  const lines = createInterface({
    input: child.stdout,
    crlfDelay: Number.POSITIVE_INFINITY,
  });
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
  return {
    output: output.join("\n"),
    stderr: Buffer.concat(errors).toString(),
    exitCode,
  };
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
  const callID = text(envelope["callID"]).toUpperCase();
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
    const candidateID =
      state.writes === 1 ? firstCandidateID : secondCandidateID;
    const fingerprint =
      state.writes === 1 ? firstFingerprint : secondFingerprint;
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
              assurance: "verified",
              failure: "wrongOutput",
              expectedOutput: "HELLO",
              actualOutput: "hello",
            }
          : {
              candidateID,
              fingerprint: secondFingerprint,
              outcome: "passed",
              assurance: "verified",
              passingFingerprint: secondFingerprint,
            },
      },
    });
  } else {
    send(child, "toolResponse", {
      callID,
      result: {
        name,
        payload: {
          candidateID: secondCandidateID,
          fingerprint: secondFingerprint,
        },
      },
    });
  }
}

test("model action contract accepts every runnable candidate shape and rejects invalid outputs", () => {
  const action = (candidate: JsonObject) =>
    JSON.stringify({
      version: 1,
      action: "toolCall",
      name: "write_candidate",
      arguments: { candidate },
    });
  const common = {
    schemaVersion: 1,
    name: "Contract test",
    brief: "Exercises the shared candidate contract.",
    symbolName: "curlybraces",
    input: "selection",
    output: "clipboard",
    trigger: "always",
    hosts: [],
    extensions: [],
  };
  const python = {
    ...common,
    kind: "python",
    source: "print('OK')",
    fixtures: [{ input: "ok", expectedOutput: "OK" }],
    timeoutSeconds: 30,
    declaresNetwork: false,
  };
  const downloader = {
    ...common,
    kind: "python",
    name: "Download Video",
    brief: "Downloads one social video.",
    symbolName: "arrow.down.circle",
    input: "ask",
    output: "files",
    trigger: "always",
    hosts: ["instagram.com", "tiktok.com", "youtube.com", "youtu.be"],
    extensions: [],
    source: [
      "# /// script",
      '# requires-python = ">=3.12"',
      '# dependencies = ["yt-dlp==2026.3.17"]',
      "# ///",
      "import sys",
      "import yt_dlp",
      "url = sys.argv[1]",
      'with yt_dlp.YoutubeDL({"noplaylist": True}) as downloader:',
      "    downloader.download([url])",
      'print("Downloaded video")',
    ].join("\n"),
    fixtures: [
      {
        input: "https://nugumi.invalid/fixture/video.mp4",
        expectedOutput: "Downloaded video",
      },
    ],
    outputDirectory: "~/Downloads",
    timeoutSeconds: 30,
    declaresNetwork: true,
  };
  const selectedLinkDownloader = {
    ...downloader,
    input: "selection",
    trigger: "selection",
    hosts: [],
  };
  const selectedOpenURL = {
    ...common,
    kind: "native",
    name: "Open Selected Link",
    brief: "Opens the selected link in the default browser.",
    symbolName: "link",
    input: "selection",
    output: "notify",
    trigger: "selection",
    hosts: [],
    extensions: [],
    nativeAction: "openURL",
    target: "{input}",
  };

  assert.doesNotThrow(() => parseModelAction(action(python)));
  // A tool whose output cannot be predicted, and one that must not be run at
  // all, are both first-class candidates now. Requiring an exact expected
  // string is what confined the agent to pure text transforms.
  assert.doesNotThrow(() =>
    parseModelAction(action({ ...python, fixtures: [{ input: "ok" }] })),
  );
  assert.doesNotThrow(() =>
    parseModelAction(action({ ...python, fixtures: [] })),
  );
  assert.doesNotThrow(() =>
    parseModelAction(
      action({
        ...python,
        source: [
          "# /// script",
          '# dependencies = ["httpx==0.28.1"]',
          "# ///",
          "import httpx",
        ].join("\n"),
        declaresNetwork: true,
        fixtures: [{ input: "https://example.com" }],
      }),
    ),
  );
  assert.throws(
    () =>
      parseModelAction(
        action({
          ...python,
          fixtures: [{ input: "ok", expectedOutput: "OK", extra: 1 }],
        }),
      ),
    /invalid tool arguments/,
  );
  assert.doesNotThrow(() => parseModelAction(action(downloader)));
  assert.doesNotThrow(() => parseModelAction(action(selectedLinkDownloader)));
  assert.doesNotThrow(() => parseModelAction(action(selectedOpenURL)));
  assert.throws(
    () =>
      parseModelAction(
        action({
          ...common,
          kind: "native",
          output: "panel",
          nativeAction: "openURL",
          target: "{input}",
        }),
      ),
    /invalid tool arguments/,
  );
  assert.throws(
    () =>
      parseModelAction(
        action({ ...python, output: "files", outputDirectory: "" }),
      ),
    /invalid tool arguments/,
  );
  assert.throws(
    () => parseModelAction(action({ ...python, outputDirectory: null })),
    /invalid tool arguments/,
  );
  assert.throws(
    () =>
      parseModelAction(
        action({
          ...python,
          output: "files",
          outputDirectory: "x".repeat(8_193),
        }),
      ),
    /invalid tool arguments/,
  );
  assert.doesNotThrow(() =>
    parseModelAction(action({ ...python, options: ["360p", "480p", "720p"] })),
  );
  assert.throws(
    () => parseModelAction(action({ ...python, options: ["720p"] })),
    /invalid tool arguments/,
  );
  assert.throws(
    () =>
      parseModelAction(
        action({ ...python, options: ["a", "b", "c", "d", "e", "f"] }),
      ),
    /invalid tool arguments/,
  );
  assert.throws(
    () =>
      parseModelAction(action({ ...python, options: ["a", "x".repeat(65)] })),
    /invalid tool arguments/,
  );
});

test("a surface candidate's layout is validated by the sidecar schema, matching ToolAgentCandidateV1.validate", () => {
  const action = (candidate: JsonObject) =>
    JSON.stringify({
      version: 1,
      action: "toolCall",
      name: "write_candidate",
      arguments: { candidate },
    });
  const validLayout = {
    node: "grid",
    minimumWidth: 96,
    empty: "Nothing in Downloads",
    cell: {
      node: "card",
      title: "$name",
      subtitle: "$size",
      icon: "file:$path",
      drag: "file:$path",
      tap: "reveal:$path",
    },
  };
  const surface = {
    schemaVersion: 1,
    name: "Downloads",
    brief: "Shows my downloads.",
    symbolName: "tray",
    input: "none",
    output: "surface",
    trigger: "always",
    hosts: [],
    extensions: [],
    kind: "python",
    source: "print('{\"rows\":[]}')",
    fixtures: [],
    timeoutSeconds: 30,
    declaresNetwork: false,
    layout: validLayout,
  };

  assert.doesNotThrow(() => parseModelAction(action(surface)));

  // The rule this task exists to add: a surface with no layout at all is
  // rejected by the sidecar, not just discovered later by the host.
  const { layout: _omitted, ...surfaceWithoutLayout } = surface;
  assert.throws(
    () => parseModelAction(action(surfaceWithoutLayout)),
    /invalid tool arguments/,
  );
  // A layout whose root does not repeat has nowhere for rows to go.
  assert.throws(
    () =>
      parseModelAction(
        action({ ...surface, layout: { node: "text", value: "$name" } }),
      ),
    /invalid tool arguments/,
  );
  // A layout on a non-surface output, and a surface on a non-python kind, are
  // each the other half of the same coupling.
  assert.throws(
    () => parseModelAction(action({ ...surface, output: "clipboard" })),
    /invalid tool arguments/,
  );
  assert.throws(
    () =>
      parseModelAction(
        action({
          ...surface,
          kind: "prompt",
          prompt: "list files",
          appliesTargetLanguage: false,
        }),
      ),
    /invalid tool arguments/,
  );
  // Deeper than ToolAgentLayoutV1.maximumDepth — z.lazy has no depth of its
  // own, so this is the case that motivated walking the parsed tree by hand.
  assert.throws(
    () =>
      parseModelAction(
        action({
          ...surface,
          layout: {
            node: "grid",
            minimumWidth: 96,
            empty: "x",
            cell: {
              node: "list",
              empty: "x",
              row: {
                node: "list",
                empty: "x",
                row: { node: "text", value: "x" },
              },
            },
          },
        }),
      ),
    /invalid tool arguments/,
  );
  // A modifier with nothing after its `$` is not a binding.
  assert.throws(
    () =>
      parseModelAction(
        action({
          ...surface,
          layout: {
            ...validLayout,
            cell: { ...validLayout.cell, drag: "file:$" },
          },
        }),
      ),
    /invalid tool arguments/,
  );
});

test("an edit session's current tool carries its options, bounded the same way a candidate's are", () => {
  const editWithOptions = {
    version: 1,
    runID,
    type: "start",
    payload: {
      operation: "edit",
      description: "Add more resolutions.",
      budgets: start.payload.budgets,
      currentTool: {
        ...fixStart.payload.currentTool,
        options: ["360p", "480p", "720p"],
      },
    },
  };

  assert.doesNotThrow(() => parseInbound(JSON.stringify(editWithOptions)));
  assert.throws(
    () =>
      parseInbound(
        JSON.stringify({
          ...editWithOptions,
          payload: {
            ...editWithOptions.payload,
            currentTool: {
              ...editWithOptions.payload.currentTool,
              options: ["720p"],
            },
          },
        }),
      ),
    /invalid start payload/,
  );
});

test("first terminal wins when failure reaches an attested runtime before completion", () => {
  // Given
  const output: string[] = [];
  const runtime = new SidecarRuntime(runID, start.payload, (line) =>
    output.push(line),
  );
  const attestation = {
    candidateID: secondCandidateID,
    fingerprint: secondFingerprint,
  };
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
  const result = await drive(
    child,
    (message) => respondToGate(child, message, state),
    false,
  );

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
  const result = await drive(
    child,
    (message) => {
      if (message["type"] !== "modelRequest") return;
      send(child, "modelResponse", {
        requestID: "66666666-6666-4666-8666-666666666666",
        result: {
          kind: "text",
          text: '{"version":1,"action":"finalText","text":"x"}',
        },
      });
    },
    false,
  );

  // Then
  assert.equal(result.exitCode, 0);
  assert.match(result.output, /"type":"failed"/);
  assert.equal(child.killed, false);
});

test("model bridge error preserves its public failure code", async () => {
  // Given
  const child = launch("agent.mjs");
  child.stdin.write(`${JSON.stringify(start)}\n`);

  // When
  const result = await drive(child, (message) => {
    if (message["type"] !== "modelRequest") return;
    const payload = object(message["payload"]);
    send(child, "modelResponse", {
      requestID: text(payload["requestID"]),
      result: { kind: "error", error: "invalidModelAction" },
    });
  });

  // Then
  assert.equal(result.output.match(/"type":"failed"/g)?.length, 1);
  assert.match(result.output, /"code":"invalidModelAction"/);
  assert.doesNotMatch(result.output, /"code":"invalidProtocol"/);
});

test("live Pi fix session gives the model the current tool and exact failure", async () => {
  // Given
  const child = launch("agent.mjs");
  let modelTurns = 0;
  child.stdin.write(`${JSON.stringify(fixStart)}\n`);

  // When
  const result = await drive(child, (message) => {
    if (message["type"] !== "modelRequest") return;
    modelTurns += 1;
    const payload = object(message["payload"]);
    const user = text(payload["user"]);
    const system = text(payload["system"]);
    const context = object(JSON.parse(user));
    assert.ok(Array.isArray(context["messages"]));
    const firstMessage = object(context["messages"][0]);
    assert.ok(Array.isArray(firstMessage["content"]));
    const firstContent = object(firstMessage["content"][0]);
    const initialRequest = object(JSON.parse(text(firstContent["text"])));
    assert.equal(initialRequest["operation"], "fix");
    assert.equal(
      initialRequest["instruction"],
      "Repair this tool without changing its intended behavior.",
    );
    assert.equal(
      object(initialRequest["currentTool"])["source"],
      "import sys\nprint(sys.argv[1])\n",
    );
    assert.equal(
      initialRequest["failure"],
      "Expected HELLO but received hello.",
    );
    assert.match(system, /preserve behavior.*did not ask to change/i);
    send(child, "modelResponse", {
      requestID: text(payload["requestID"]),
      result: {
        kind: "text",
        text: '{"version":1,"action":"finalText","text":"context observed"}',
      },
    });
  });

  // Then
  assert.equal(modelTurns, 1);
  assert.match(result.output, /"type":"failed"/);
  assert.equal(result.stderr, "");
});

test("real Pi gate repairs wrong output with detail before exact finish attestation", async () => {
  // Given
  const child = launch("gate.mjs", {
    ...process.env,
    OPENAI_API_KEY: "credential-sentinel",
  });
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
      const candidateID =
        writeCount === 1 ? firstCandidateID : secondCandidateID;
      const fingerprint =
        writeCount === 1 ? firstFingerprint : secondFingerprint;
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
                assurance: "verified",
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
                assurance: "verified",
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
          payload: {
            candidateID: secondCandidateID,
            fingerprint: secondFingerprint,
          },
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

test("live bridge serializes five tools and prior structured validation detail", async () => {
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
        [
          "read_build_context",
          "write_candidate",
          "run_validation",
          "finish_candidate",
          "ask_user",
        ],
      );
      assert.ok(
        tools.every((tool) => object(tool)["executionMode"] === "sequential"),
      );
      const system = text(payload["system"]);
      assert.doesNotMatch(system, /\/Users\//);
      assert.match(system, /every response must be exactly one/);
      assert.match(system, /run_validation/);
      assert.match(system, /any PyPI dependency, the network/);
      assert.match(system, /UNSUPPORTED:/);
      assert.match(
        system,
        /request that fits a prompt tool or any closed native action must\s+never return UNSUPPORTED/,
      );
      assert.match(
        system,
        /To open the input link unchanged, set target to exactly\s+"\{input\}"/,
      );
      assert.match(
        system,
        /selected or highlighted text, use input "selection", trigger\s+"selection", output "notify", hosts \[\], and extensions \[\]/,
      );
      assert.match(system, /openURL is a\s+complete supported native action/);
      assert.match(
        system,
        /UNSUPPORTED is a last resort and never a keyword filter/,
      );
      assert.match(
        system,
        /Words such as Python,\s+script, URL, browser, network, dependency, package, subprocess, and download\s+must not cause a refusal/,
      );
      assert.match(system, /repair from its diagnostics instead of giving up/);
      assert.match(system, /There is no allowlist and no offline restriction/);
      assert.match(system, /на выделение линки будет открывать ее в браузере/);
      assert.match(system, /"nativeAction":"openURL","target":"\{input\}"/);
      assert.match(
        system,
        /Do not ask which browser and never return UNSUPPORTED for this request/,
      );
      // How a candidate earns each assurance grade. Getting these three cases
      // across is the whole reason a tool that touches the world can exist.
      assert.match(
        system,
        /One fixture with expectedOutput, when the same input always produces the same\s+output/,
      );
      assert.match(
        system,
        /One fixture without expectedOutput, when running it proves something real/,
      );
      assert.match(
        system,
        /No fixtures at all, when running the script would do something to the user's\s+data/,
      );
      assert.match(
        system,
        /Never invent a fixture whose only purpose is to pass/,
      );
      assert.match(
        system,
        /write results into the current working directory with\s+relative paths/,
      );
      assert.match(
        system,
        /Printing success\s+without writing a file fails validation/,
      );
      // The hardcoded video-downloader profile and the offline restriction it
      // existed to work around are both gone; nothing may quietly reintroduce
      // either as a special case.
      assert.doesNotMatch(
        system,
        /yt-dlp|nugumi\.invalid|standard library only|Downloaded video/,
      );
      assert.match(system, /Never invent candidate IDs or fingerprints/);
      if (modelTurn === 4) {
        const transcript = text(payload["user"]);
        assert.match(transcript, /wrongOutput/);
        assert.match(transcript, /HELLO/);
        assert.match(transcript, /hello/);
      }
      const actions = [
        {
          version: 1,
          action: "toolCall",
          name: "read_build_context",
          arguments: {},
        },
        {
          version: 1,
          action: "toolCall",
          name: "write_candidate",
          arguments: {
            candidate: {
              schemaVersion: 1,
              kind: "python",
              name: "Uppercase",
              brief: "Uppercases text",
              symbolName: "textformat",
              input: "selection",
              output: "clipboard",
              trigger: "always",
              hosts: [],
              extensions: [],
              source: "import sys\nprint(sys.argv[1])\n",
              fixtures: [{ input: "hello", expectedOutput: "HELLO" }],
              timeoutSeconds: 30,
              declaresNetwork: false,
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
        requestID: text(payload["requestID"]).toUpperCase(),
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
        result: {
          name,
          payload: { remaining: { modelTurns: 7, toolCalls: 31, repairs: 3 } },
        },
      });
    } else if (name === "write_candidate") {
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: {
            candidateID: latestCandidateID,
            fingerprint: firstFingerprint,
          },
        },
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
            assurance: "verified",
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
  assert.doesNotMatch(
    result.output,
    /"name":"bash"|"name":"read"|"name":"write"/,
  );
});

test("same live Pi edit session receives exact clarification answer before writing", async () => {
  // Given
  const child = launch("agent.mjs");
  const exactAnswer = "Notes — Personal";
  const editStart = {
    ...start,
    payload: {
      ...start.payload,
      operation: "edit",
      description: "Send selected text to the right Notes app.",
      currentTool: {
        kind: "prompt",
        name: "Rewrite",
        brief: "",
        symbolName: "pencil",
        input: "selection",
        output: "panel",
        trigger: "selection",
        hosts: [],
        extensions: [],
        prompt: "Rewrite this text.",
        appliesTargetLanguage: true,
      },
    },
  };
  let modelTurn = 0;
  let wroteCandidate = false;
  child.stdin.write(`${JSON.stringify(editStart)}\n`);

  // When
  const result = await drive(child, (message) => {
    const payload = object(message["payload"]);
    if (message["type"] === "modelRequest") {
      modelTurn += 1;
      if (modelTurn === 1) {
        const system = text(payload["system"]);
        assert.match(system, /Create, Edit, and Fix/);
        assert.doesNotMatch(
          system,
          /For Create only|Never call ask_user for edit or fix/,
        );
      }
      if (modelTurn === 2) {
        const context = object(JSON.parse(text(payload["user"])));
        const transcript = JSON.stringify(context["messages"]);
        assert.match(transcript, new RegExp(exactAnswer));
        assert.match(transcript, /ask_user/);
      }
      const actions = [
        {
          version: 1,
          action: "toolCall",
          name: "ask_user",
          arguments: {
            question: "Which app should receive the selected text?",
          },
        },
        {
          version: 1,
          action: "toolCall",
          name: "write_candidate",
          arguments: {
            candidate: {
              schemaVersion: 1,
              kind: "native",
              name: "Send To Notes",
              brief: "Sends selected text to the chosen Notes app.",
              symbolName: "doc.text",
              input: "selection",
              output: "notify",
              trigger: "selection",
              hosts: [],
              extensions: [],
              nativeAction: "sendTextToApp",
              target: exactAnswer,
            },
          },
        },
        { version: 1, action: "finalText", text: "candidate captured" },
      ];
      send(child, "modelResponse", {
        requestID: text(payload["requestID"]),
        result: { kind: "text", text: JSON.stringify(actions[modelTurn - 1]) },
      });
      return;
    }
    if (message["type"] !== "toolRequest") return;
    const request = object(payload["request"]);
    const name = text(request["name"]);
    const callID = text(payload["callID"]);
    if (name === "ask_user") {
      assert.equal(
        object(request["payload"])["question"],
        "Which app should receive the selected text?",
      );
      send(child, "toolResponse", {
        callID,
        result: { name, payload: { answer: exactAnswer } },
      });
    } else {
      assert.equal(name, "write_candidate");
      const candidate = object(object(request["payload"])["candidate"]);
      assert.equal(candidate["target"], exactAnswer);
      wroteCandidate = true;
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: {
            candidateID: firstCandidateID,
            fingerprint: firstFingerprint,
          },
        },
      });
    }
  });

  // Then
  assert.equal(modelTurn, 3);
  assert.equal(wroteCandidate, true);
  assert.match(result.output, /"code":"invalidCandidate"/);
});

test("live Pi session accepts and attests a native Notes candidate", async () => {
  // A Python-only candidate schema would reject the second model action.
  const child = launch("agent.mjs");
  const nativeStart = {
    ...start,
    payload: {
      ...start.payload,
      description: "я хочу выделить ссылку и сохранить её в заметки",
    },
  };
  let modelTurn = 0;
  let writtenKind = "";
  child.stdin.write(`${JSON.stringify(nativeStart)}\n`);

  const result = await drive(child, (message) => {
    const payload = object(message["payload"]);
    if (message["type"] === "modelRequest") {
      modelTurn += 1;
      const actions = [
        {
          version: 1,
          action: "toolCall",
          name: "read_build_context",
          arguments: {},
        },
        {
          version: 1,
          action: "toolCall",
          name: "write_candidate",
          arguments: {
            candidate: {
              schemaVersion: 1,
              kind: "native",
              name: "Save To Notes",
              brief: "Sends selected text to Notes.",
              symbolName: "doc.text",
              input: "selection",
              output: "notify",
              trigger: "selection",
              hosts: [],
              extensions: [],
              nativeAction: "sendTextToApp",
              target: "Notes",
            },
          },
        },
        {
          version: 1,
          action: "toolCall",
          name: "run_validation",
          arguments: { candidateID: firstCandidateID },
        },
        {
          version: 1,
          action: "toolCall",
          name: "finish_candidate",
          arguments: {
            candidateID: firstCandidateID,
            fingerprint: firstFingerprint,
          },
        },
        { version: 1, action: "finalText", text: "candidate ready" },
      ];
      send(child, "modelResponse", {
        requestID: text(payload["requestID"]),
        result: { kind: "text", text: JSON.stringify(actions[modelTurn - 1]) },
      });
      return;
    }
    if (message["type"] !== "toolRequest") return;
    const request = object(payload["request"]);
    const requestPayload = object(request["payload"]);
    const name = text(request["name"]);
    const callID = text(payload["callID"]);
    if (name === "read_build_context") {
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: { remaining: { modelTurns: 7, toolCalls: 31, repairs: 3 } },
        },
      });
    } else if (name === "write_candidate") {
      writtenKind = text(object(requestPayload["candidate"])["kind"]);
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: {
            candidateID: firstCandidateID,
            fingerprint: firstFingerprint,
          },
        },
      });
    } else if (name === "run_validation") {
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: {
            candidateID: firstCandidateID,
            fingerprint: firstFingerprint,
            outcome: "passed",
            assurance: "verified",
            passingFingerprint: firstFingerprint,
          },
        },
      });
    } else {
      send(child, "toolResponse", {
        callID,
        result: {
          name,
          payload: {
            candidateID: firstCandidateID,
            fingerprint: firstFingerprint,
          },
        },
      });
    }
  });

  assert.equal(writtenKind, "native");
  assert.equal(modelTurn, 5);
  assert.match(result.output, /"type":"completed"/);
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
      result: {
        kind: "text",
        text: '{"version":1,"action":"finalText","text":"x"}',
      },
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
      payload: {
        ...start.payload,
        budgets: { ...start.payload.budgets, modelTurns: 1 },
      },
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
  unknownType.stdin.end(
    `${JSON.stringify({ ...start, type: "runtimeMode" })}\n`,
  );
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
    files.map((file) =>
      readFile(new URL(`../dist/${file}`, import.meta.url), "utf8"),
    ),
  );

  // Then
  assert.ok(sources.every((source) => !source.includes("faux-provider")));
  assert.ok(
    sources.every((source) => !source.includes("createScriptedFauxProvider")),
  );
});
