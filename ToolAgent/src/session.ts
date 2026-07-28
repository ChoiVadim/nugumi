import { InMemoryCredentialStore, type Model, type Provider } from "@earendil-works/pi-ai";
import {
  createAgentSession,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { createInterface, type Interface } from "node:readline";
import {
  parseInbound,
  ProtocolError,
  type StartPayload,
} from "./protocol.js";
import { SidecarRuntime } from "./runtime.js";
import { createTools } from "./tools.js";

type ProviderBundle = {
  readonly provider: Provider<string>;
  readonly model: Model<string>;
};

export function makeInitialPrompt(start: StartPayload): string {
  return JSON.stringify({
    operation: start.operation ?? "create",
    instruction: start.description,
    currentTool: start.currentTool,
    failure: start.failure,
  });
}

export async function runSidecar(
  makeProvider: (runtime: SidecarRuntime) => ProviderBundle,
): Promise<void> {
  let runtime: SidecarRuntime | undefined;
  let input: Interface | undefined;
  let timeout: NodeJS.Timeout | undefined;
  try {
    input = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY });
    const iterator = input[Symbol.asyncIterator]();
    const first = await iterator.next();
    if (first.done) throw new ProtocolError("invalidProtocol", "missing start");
    const parsed = parseInbound(first.value);
    if (parsed.message.type !== "start") throw new ProtocolError("invalidProtocol", "first message must be start");
    runtime = new SidecarRuntime(parsed.runID, parsed.message.payload);
    const activeRuntime = runtime;
    const pump = (async () => {
      for await (const line of iterator) {
        const next = parseInbound(line);
        if (next.runID !== activeRuntime.runID || next.message.type === "start") {
          throw new ProtocolError("invalidProtocol", "invalid run message");
        }
        activeRuntime.receive(next.message);
      }
    })();
    void pump.catch((error: unknown) => {
      activeRuntime.fail("invalidProtocol", error instanceof Error ? error.message : "input failure");
    });
    timeout = setTimeout(
      () => activeRuntime.abortController.abort("deadlineExceeded"),
      activeRuntime.start.budgets.durationSeconds * 1000,
    );
    const bundle = makeProvider(activeRuntime);
    const modelRuntime = await ModelRuntime.create({
      credentials: new InMemoryCredentialStore(),
      modelsPath: null,
      allowModelNetwork: false,
    });
    modelRuntime.registerNativeProvider(bundle.provider);
    const settings = SettingsManager.inMemory({ compaction: { enabled: false } });
    const loader = new DefaultResourceLoader({
      cwd: "/",
      agentDir: "/",
      settingsManager: settings,
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
      systemPrompt:
        "Build and verify one complete Nugumi tool using only the five available tools. For Create, Edit, and Fix, ask up to three short clarifications before the first candidate write only when a missing fact materially changes executable behavior and cannot be inferred safely. Never ask for confirmation or preferences. Preserve behavior the user did not ask to change. Change kind only when the requested behavior genuinely needs a different tool type.",
    });
    await loader.reload();
    const tools = createTools(activeRuntime);
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
    const prompt = session.prompt(makeInitialPrompt(activeRuntime.start), {
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
    runtime?.fail(code, error instanceof Error ? error.message : "sidecar failure");
    if (runtime === undefined) process.exitCode = 1;
  } finally {
    if (timeout !== undefined) clearTimeout(timeout);
    input?.close();
    process.stdin.pause();
  }
}
