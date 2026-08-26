import {
  InMemoryCredentialStore,
  type Model,
  type Provider,
} from "@earendil-works/pi-ai";
import {
  createAgentSession,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { createInterface, type Interface } from "node:readline";
import {
  encodeEnvelope,
  parseInbound,
  parseToolResponse,
  ProtocolError,
  type Inbound,
  type RunInbound,
  type StartPayload,
  type ToolName,
} from "./protocol.js";
import { SidecarRuntime, type SessionInbound } from "./runtime.js";
import { createTools } from "./tools.js";

type ProviderBundle = {
  readonly provider: Provider<string>;
  readonly model: Model<string>;
};

/// Everything that differs between a tool *build* session and an agent tool's
/// *run* session. The Pi wiring below — hermetic model runtime, no built-in
/// tools, no extensions, no network — is identical for both and deliberately
/// lives in exactly one place, so a run session cannot accidentally be granted
/// something a build session was carefully denied.
export type SidecarDefinition<TStart> = {
  readonly parseLine: (line: string) => {
    readonly runID: string;
    readonly message: Inbound | RunInbound;
  };
  readonly parseResponse: (name: string, payload: unknown) => unknown;
  readonly systemPrompt: string;
  readonly makeTools: (
    runtime: SidecarRuntime,
  ) => ReturnType<typeof createTools>;
  readonly initialPrompt: (start: TStart) => string;
  readonly makeProvider: (runtime: SidecarRuntime) => ProviderBundle;
};

export function makeInitialPrompt(start: StartPayload): string {
  return JSON.stringify({
    operation: start.operation ?? "create",
    instruction: start.description,
    currentTool: start.currentTool,
    failure: start.failure,
  });
}

export const buildSystemPrompt =
  "Build and verify one complete Gizmate tool using only the five available tools. For Create, Edit, and Fix, ask every short clarification you need in one ask_user call before the first candidate write. Ask which input the gizmo reads and where its result should go whenever the request does not already say, since users rarely know those are choices, and otherwise ask only when a missing fact materially changes executable behavior and cannot be inferred safely. Never ask for confirmation or preferences. Preserve behavior the user did not ask to change. Change kind only when the requested behavior genuinely needs a different tool type.";

export function buildDefinition(
  makeProvider: (runtime: SidecarRuntime) => ProviderBundle,
): SidecarDefinition<StartPayload> {
  return {
    parseLine: parseInbound,
    parseResponse: (name, payload) =>
      parseToolResponse(name as ToolName, payload),
    systemPrompt: buildSystemPrompt,
    makeTools: createTools,
    initialPrompt: makeInitialPrompt,
    makeProvider,
  };
}

/// A start frame the schema rejects arrives before a runtime exists, so no
/// object owns a runID to answer with, and the sidecar used to die without a
/// frame — which the host can only report as "the agent stopped without
/// producing an answer", for a tool a trial had just passed. Salvage the
/// envelope's own runID and say what was wrong; only a line too mangled to
/// carry one stays silent.
function emitOrphanFailure(line: string, error: unknown): void {
  try {
    const runID = (JSON.parse(line) as { runID?: unknown }).runID;
    if (typeof runID !== "string") return;
    process.stdout.write(
      encodeEnvelope(runID, "failed", {
        code: "invalidProtocol",
        message: error instanceof Error ? error.message : "invalid start",
      }),
    );
  } catch {
    // Not even JSON: there is no address to answer to.
  }
}

export async function runSidecar<TStart>(
  definition: SidecarDefinition<TStart>,
): Promise<void> {
  let runtime: SidecarRuntime | undefined;
  let input: Interface | undefined;
  let timeout: NodeJS.Timeout | undefined;
  try {
    input = createInterface({
      input: process.stdin,
      crlfDelay: Number.POSITIVE_INFINITY,
    });
    const iterator = input[Symbol.asyncIterator]();
    const first = await iterator.next();
    if (first.done) throw new ProtocolError("invalidProtocol", "missing start");
    let parsed: ReturnType<typeof definition.parseLine>;
    try {
      parsed = definition.parseLine(first.value);
    } catch (error) {
      emitOrphanFailure(first.value, error);
      throw error;
    }
    if (parsed.message.type !== "start")
      throw new ProtocolError("invalidProtocol", "first message must be start");
    const start = parsed.message.payload as unknown as TStart & {
      readonly budgets: StartPayload["budgets"];
    };
    runtime = new SidecarRuntime(
      parsed.runID,
      start,
      undefined,
      definition.parseResponse,
    );
    const activeRuntime = runtime;
    const pump = (async () => {
      for await (const line of iterator) {
        const next = definition.parseLine(line);
        if (
          next.runID !== activeRuntime.runID ||
          next.message.type === "start"
        ) {
          throw new ProtocolError("invalidProtocol", "invalid run message");
        }
        activeRuntime.receive(next.message as SessionInbound);
      }
    })();
    void pump.catch((error: unknown) => {
      activeRuntime.fail(
        "invalidProtocol",
        error instanceof Error ? error.message : "input failure",
      );
    });
    timeout = setTimeout(
      () => activeRuntime.abortController.abort("deadlineExceeded"),
      activeRuntime.start.budgets.durationSeconds * 1000,
    );
    const bundle = definition.makeProvider(activeRuntime);
    const modelRuntime = await ModelRuntime.create({
      credentials: new InMemoryCredentialStore(),
      modelsPath: null,
      allowModelNetwork: false,
    });
    modelRuntime.registerNativeProvider(bundle.provider);
    const settings = SettingsManager.inMemory({
      compaction: { enabled: false },
    });
    const loader = new DefaultResourceLoader({
      cwd: "/",
      agentDir: "/",
      settingsManager: settings,
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
      systemPrompt: definition.systemPrompt,
    });
    await loader.reload();
    const tools = definition.makeTools(activeRuntime);
    const { session } = await createAgentSession({
      cwd: "/",
      modelRuntime,
      model: bundle.model,
      noTools: "builtin",
      tools: tools.map((item) => item.name),
      customTools: tools,
      resourceLoader: loader,
      settingsManager: settings,
      sessionManager: SessionManager.inMemory("/"),
    });
    activeRuntime.abortController.signal.addEventListener(
      "abort",
      () => void session.abort(),
      { once: true },
    );
    activeRuntime.emit("state", { state: "understanding" });
    const prompt = session.prompt(definition.initialPrompt(start), {
      expandPromptTemplates: false,
    });
    await Promise.race([prompt, activeRuntime.waitForFailure()]);
    if (activeRuntime.hasFailed) {
      void prompt.catch(() => {});
      void session.abort().catch(() => {});
      session.dispose();
      return;
    }
    await prompt;
    session.dispose();
    activeRuntime.complete();
  } catch (error) {
    const code =
      error instanceof ProtocolError && error.code === "invalidModelAction"
        ? "invalidModelAction"
        : runtime?.abortController.signal.aborted
          ? "cancelled"
          : error instanceof ProtocolError && error.message.includes("budget")
            ? "budgetExhausted"
            : "invalidProtocol";
    runtime?.fail(
      code,
      error instanceof Error ? error.message : "sidecar failure",
    );
    if (runtime === undefined) process.exitCode = 1;
  } finally {
    if (timeout !== undefined) clearTimeout(timeout);
    input?.close();
    process.stdin.pause();
  }
}
