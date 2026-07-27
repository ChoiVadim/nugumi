import {
  encodeEnvelope,
  parseToolResponse,
  ProtocolError,
  type Inbound,
  type StartPayload,
  type ToolName,
} from "./protocol.js";

type Pending =
  | {
      readonly kind: "model";
      readonly id: string;
      readonly resolve: (value: string) => void;
      readonly reject: (error: Error) => void;
    }
  | {
      readonly kind: "tool";
      readonly id: string;
      readonly name: ToolName;
      readonly resolve: (value: unknown) => void;
      readonly reject: (error: Error) => void;
    };

export class SidecarRuntime {
  readonly abortController = new AbortController();
  private pending: Pending | undefined;
  private terminal: "open" | "failed" | "completed" = "open";
  private failed = false;
  private resolveFailure: () => void = () => {};
  private readonly failure = new Promise<void>((resolve) => {
    this.resolveFailure = resolve;
  });
  private turns = 0;
  private calls = 0;
  private writes = 0;
  private finished:
    | { readonly candidateID: string; readonly fingerprint: { readonly value: string } }
    | undefined;

  public constructor(
    readonly runID: string,
    readonly start: StartPayload,
    private readonly output: (line: string) => void = (line) => process.stdout.write(line),
  ) {}

  public emit(type: string, payload: unknown): void {
    if (this.terminal === "open") this.output(encodeEnvelope(this.runID, type, payload));
  }

  public chargeTurn(): void {
    this.turns += 1;
    if (this.turns > this.start.budgets.modelTurns) {
      this.fail("budgetExhausted", "model turn budget exhausted");
      throw new ProtocolError("invalidProtocol", "model turn budget exhausted");
    }
  }

  private chargeTool(name: ToolName): void {
    this.calls += 1;
    if (this.calls > this.start.budgets.toolCalls) {
      this.fail("budgetExhausted", "tool call budget exhausted");
      throw new ProtocolError("invalidProtocol", "tool call budget exhausted");
    }
    if (name === "write_candidate") {
      this.writes += 1;
      if (this.writes - 1 > this.start.budgets.repairs) {
        this.fail("budgetExhausted", "repair budget exhausted");
        throw new ProtocolError("invalidProtocol", "repair budget exhausted");
      }
    }
  }

  public requestModel(
    context: { readonly system: string; readonly user: string },
    signal: AbortSignal | undefined,
  ): Promise<string> {
    this.chargeTurn();
    const requestID = crypto.randomUUID();
    this.emit("modelRequest", { requestID, system: context.system, user: context.user });
    return this.awaitResponse("model", requestID, undefined, signal);
  }

  public requestTool(
    name: ToolName,
    payload: Record<string, unknown>,
    callID: string,
    signal: AbortSignal | undefined,
  ): Promise<unknown> {
    this.chargeTool(name);
    this.emit("toolRequest", { callID, request: { name, payload } });
    return this.awaitResponse("tool", callID, name, signal);
  }

  private awaitResponse(
    kind: "model",
    id: string,
    name: undefined,
    signal: AbortSignal | undefined,
  ): Promise<string>;
  private awaitResponse(
    kind: "tool",
    id: string,
    name: ToolName,
    signal: AbortSignal | undefined,
  ): Promise<unknown>;
  private awaitResponse(
    kind: Pending["kind"],
    id: string,
    name: ToolName | undefined,
    signal: AbortSignal | undefined,
  ): Promise<unknown> {
    if (this.pending !== undefined) {
      return Promise.reject(new ProtocolError("invalidProtocol", "concurrent request"));
    }
    return new Promise((resolve, reject) => {
      const onAbort = () => reject(new ProtocolError("invalidProtocol", "cancelled"));
      signal?.addEventListener("abort", onAbort, { once: true });
      const guardedResolve = (value: unknown) => {
        signal?.removeEventListener("abort", onAbort);
        resolve(value);
      };
      const guardedReject = (error: Error) => {
        signal?.removeEventListener("abort", onAbort);
        reject(error);
      };
      this.pending =
        kind === "model"
          ? { kind, id, resolve: guardedResolve, reject: guardedReject }
          : { kind, id, name: name ?? "read_build_context", resolve: guardedResolve, reject: guardedReject };
    });
  }

  public receive(message: Exclude<Inbound, { readonly type: "start" }>): void {
    if (message.type === "cancel") {
      this.fail("cancelled", message.payload.reason);
      return;
    }
    const pending = this.pending;
    if (pending === undefined) throw new ProtocolError("invalidProtocol", "unexpected response");
    if (message.type === "modelResponse") {
      if (pending.kind !== "model" || message.payload.requestID !== pending.id) {
        throw new ProtocolError("invalidProtocol", "mismatched model response ID");
      }
      this.pending = undefined;
      if (message.payload.result.kind === "error") {
        pending.reject(new ProtocolError("invalidProtocol", "model bridge failed"));
      } else {
        pending.resolve(message.payload.result.text);
      }
      return;
    }
    if (
      pending.kind !== "tool" ||
      message.payload.callID !== pending.id ||
      message.payload.result.name !== pending.name
    ) {
      throw new ProtocolError("invalidProtocol", "mismatched tool response ID");
    }
    this.pending = undefined;
    pending.resolve(parseToolResponse(pending.name, message.payload.result.payload));
  }

  public attest(expected: unknown, value: unknown): void {
    if (
      typeof expected !== "object" ||
      expected === null ||
      typeof value !== "object" ||
      value === null
    ) {
      throw new ProtocolError("invalidProtocol", "invalid attestation");
    }
    if (
      !("candidateID" in value) ||
      typeof value.candidateID !== "string" ||
      !("fingerprint" in value) ||
      typeof value.fingerprint !== "object" ||
      value.fingerprint === null ||
      !("value" in value.fingerprint) ||
      typeof value.fingerprint.value !== "string"
    ) {
      throw new ProtocolError("invalidProtocol", "invalid attestation");
    }
    const exact =
      "candidateID" in expected &&
      expected.candidateID === value.candidateID &&
      "fingerprint" in expected &&
      typeof expected.fingerprint === "object" &&
      expected.fingerprint !== null &&
      "value" in expected.fingerprint &&
      expected.fingerprint.value === value.fingerprint.value;
    if (!exact) throw new ProtocolError("invalidProtocol", "attestation mismatch");
    this.finished = {
      candidateID: value.candidateID,
      fingerprint: { value: value.fingerprint.value },
    };
  }

  public rejectModelAction(error: Error): void {
    this.fail(
      error instanceof ProtocolError && error.code === "invalidModelAction"
        ? "invalidModelAction"
        : "invalidProtocol",
      error.message,
    );
  }

  public rejectFinalText(text: string): void {
    if (this.finished === undefined) this.fail("invalidCandidate", text);
  }

  public complete(): void {
    if (this.finished === undefined) {
      throw new ProtocolError("invalidProtocol", "session ended without attestation");
    }
    if (!this.transition("completed")) return;
    this.output(encodeEnvelope(this.runID, "completed", this.finished));
  }

  public get hasFailed(): boolean {
    return this.failed;
  }

  public waitForFailure(): Promise<void> {
    return this.failure;
  }

  public fail(code: string, message: string): void {
    if (!this.transition("failed")) return;
    this.failed = true;
    this.resolveFailure();
    this.abortController.abort(code);
    this.pending?.reject(new ProtocolError("invalidProtocol", message));
    this.pending = undefined;
    const safeMessage = Buffer.from(message).subarray(0, 1024).toString();
    this.output(encodeEnvelope(this.runID, "failed", { code, message: safeMessage }));
  }

  private transition(next: "failed" | "completed"): boolean {
    if (this.terminal !== "open") return false;
    this.terminal = next;
    return true;
  }
}
