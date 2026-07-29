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
  askUserRequestSchema,
  candidateSchema,
  LIMITS,
  parseStrictJson,
  ProtocolError,
  RUN_TOOL_NAMES,
  TOOL_NAMES,
  type ToolName,
} from "./protocol.js";

const byteStringField = (maximum: number) =>
  z
    .string()
    .refine(
      (value) => value.length > 0 && Buffer.byteLength(value) <= maximum,
      "string exceeds UTF-8 byte limit",
    );

const makeActionSchema = <TName extends string>(
  names: readonly [TName, ...TName[]],
) =>
  z.discriminatedUnion("action", [
    z
      .object({
        version: z.literal(1),
        action: z.literal("finalText"),
        text: z
          .string()
          .refine(
            (value) => Buffer.byteLength(value) <= LIMITS.safeMessageBytes,
          ),
      })
      .strict(),
    z
      .object({
        version: z.literal(1),
        action: z.literal("toolCall"),
        name: z.enum(names),
        arguments: z.unknown(),
      })
      .strict(),
  ]);

const actionSchema = makeActionSchema(TOOL_NAMES);

const argumentSchemas = {
  ask_user: askUserRequestSchema,
  read_build_context: z.object({}).strict(),
  write_candidate: z.object({ candidate: candidateSchema }).strict(),
  run_validation: z.object({ candidateID: z.string().uuid() }).strict(),
  finish_candidate: z
    .object({
      candidateID: z.string().uuid(),
      fingerprint: z
        .object({ value: z.string().regex(/^[a-f0-9]{64}$/) })
        .strict(),
    })
    .strict(),
} as const;

const runArgumentSchemas = {
  run_python: z
    .object({
      source: byteStringField(LIMITS.sourceBytes),
      purpose: byteStringField(512),
    })
    .strict(),
  finish: z.object({ text: byteStringField(LIMITS.agentResultBytes) }).strict(),
} as const;

export type ModelAction<TName extends string = ToolName> =
  | { readonly action: "finalText"; readonly text: string }
  | {
      readonly action: "toolCall";
      readonly name: TName;
      readonly arguments: Record<string, unknown>;
    };

export interface ActionSource {
  /// Widened to any tool name: the bridge only forwards the name into an
  /// assistant message, and which names are legal was already decided by the
  /// action parser that produced this.
  next(
    context: Context,
    signal: AbortSignal | undefined,
  ): Promise<ModelAction<string>>;
}

const bridgeSystemPrompt = `
You are the model inside a bounded Pi tool-building agent. The host transports your native tool calls through strict JSON, so every response must be exactly one JSON object with no markdown fence and no text before or after it.

To call a tool, reply: {"version":1,"action":"toolCall","name":"TOOL_NAME","arguments":{...}}

After finish_candidate succeeds, end the session with:
{"version":1,"action":"finalText","text":"candidate ready"}

Choose prompt or a closed native action before deciding that a request is
unsupported. A request that fits a prompt tool or any closed native action must
never return UNSUPPORTED. Native candidates are validated structurally; do not
reject them merely because their runtime effect opens a browser, lets the
destination app use the network, reveals a file, or runs a named Shortcut.

For openURL, target is a URL template. The runtime replaces every "{input}" in
target with the selected or copied link and opens the result in the user's
default browser. To open the input link unchanged, set target to exactly
"{input}". For selected or highlighted text, use input "selection", trigger
"selection", output "notify", hosts [], and extensions []. For a copied link,
use input "clipboardURL", trigger "link", and output "notify". openURL is a
complete supported native action and does not require Python, a subprocess, or
preview-verifier browser automation.

A Python candidate may use any PyPI dependency, the network, the user's files,
and subprocesses. There is no allowlist and no offline restriction. Gizmate
validates a candidate by running it the same way the user's Mac will.

UNSUPPORTED is a last resort and never a keyword filter. Words such as Python,
script, URL, browser, network, dependency, package, subprocess, and download
must not cause a refusal: every one of those is supported. First map the
requested behavior to prompt, native, or Python, then build it. If validation
fails, repair from its diagnostics instead of giving up.

Refuse only when the request cannot be built at all: it needs an account or
credential Gizmate has no way to obtain, it needs hardware that is not present,
or it is not something one macOS tool can do. Before write_candidate, return:
{"version":1,"action":"finalText","text":"UNSUPPORTED: explain the exact limitation briefly in the user's language"}

The user message is a JSON serialization of the current Pi conversation and the five available tool schemas. Read the latest user or toolResult message before choosing the next action.

Required flow:
1. For Create, Edit, and Fix, call ask_user before the first write_candidate only when a missing fact would materially change the tool's behavior and cannot be inferred safely.
2. Call read_build_context.
3. Write one candidate with write_candidate.
4. Run that exact candidate with run_validation.
5. If validation fails, use its structured diagnostics to write a corrected candidate and validate again.
6. When validation passes, call finish_candidate with the exact candidateID and fingerprint returned by the host.
7. Only after finish_candidate succeeds, return finalText.

Use ask_user sparingly. Ask only a short question whose answer is necessary to choose executable behavior, such as the destination app when none was named.
Do not ask for confirmation, naming, icons, wording preferences, or facts you can infer from the request. The host enforces a three-question budget and permits questions only before the first candidate write.
After an answer, read its exact ask_user toolResult from this same conversation before writing the candidate.

Choose the candidate kind before writing it:
- prompt: meaning or writing work over text the user is looking at. Use input "selection", "screenshotText" when the request is about what is on screen rather than what is selected, or "ask" when the tool's subject is whatever the user types at the moment they run it; output "panel", "replace", or "clipboard"; trigger "always" or "selection". Include prompt and appliesTargetLanguage. Do not include Python/native fields.
- native: one closed macOS action. nativeAction is one of openApp, openAppFullScreen, sendTextToApp, revealInFinder, openURL, or runShortcut. Include target (empty only for revealInFinder). Do not include prompt/Python fields. Prefer native over Python whenever the catalog can express the job.
- python: when prompt/native cannot express the request, and the job is the same
  every time it runs. Include source, zero to three fixtures, timeoutSeconds,
  declaresNetwork, secretNames, and outputDirectory when output is "files".
- agent: when the job genuinely cannot be written down in advance, because what
  to do next depends on what the previous step found. At run time this writes and
  runs its own Python, step by step, until it has an answer. Include prompt (the
  instruction, written to the agent, not to the user), maxSteps, timeoutSeconds,
  secretNames, and zero or one fixture.

Prefer python over agent whenever python can express the job. An agent costs the
user a model call per step and its behavior is not reviewable before it runs, so
it is the right answer only for work that really does branch: "look at whatever
this file turns out to be and file it accordingly", "find which of these APIs is
up and use that one". A tool that always performs the same steps is a Python
tool even when those steps are many.

An agent candidate's fixture works like a Python one and is chosen the same way:
- One fixture, when a trial run is harmless. Its input is what the agent should
  be handed for that trial — a realistic sample of what the user will give it.
  Gizmate runs the agent once, with a smaller step budget, and requires it to
  reach an answer. Never give it an expectedOutput; an agent's wording is not
  predictable and the host rejects it.
- No fixture at all, when actually running the tool would do something to the
  user's data or to the outside world that they have not asked for yet: sending
  a message, publishing, deleting or overwriting files. Gizmate then accepts the
  candidate on its structure rather than doing that thing during a build.

read_build_context returns secretNames: the credentials the user has already
stored. A Python candidate may read any of them from its environment, for example
os.environ["OPENAI_API_KEY"], provided it also lists the ones it reads in its own
secretNames. A name that is not in that list is not present at run time. Never
invent a name that read_build_context did not return, and never write a key into
the source: there is no key to write, only the name of one. If the request needs
a credential the user has not stored, say so through ask_user rather than
guessing a name, and prefer failing with a clear message over a silent default.

The initial user message is structured JSON with operation and instruction. For edit and fix it also includes currentTool, and fix includes failure.
Return a complete replacement candidate, not a diff. Preserve behavior and fields the user did not ask to change. Change kind only when the instruction genuinely requires a different tool type.

Every candidate also includes schemaVersion 1, kind, name, brief, symbolName,
input, output, trigger, hosts, and extensions. Trigger "selection" requires
selection input; "link" requires clipboardURL; "files" requires files input.

The input "ask" is typed rather than read. When the tool runs, a text field opens
at the cursor and the tool is handed exactly what the user types, in the same
single argument a selection would arrive in. Choose it when the request has no
fixed subject — the user supplies one per run ("look something up", "write a
reply saying...", "convert whatever I tell you"). It requires trigger "always":
there is nothing to detect it by before the field is filled in.

Two more inputs are taken rather than read. When the tool runs, the user drags a
box over part of the screen, and that capture is the input:
- "screenshotText": the tool is handed the text Vision read out of the capture.
  Choose it when the request is about words the user can see but cannot select —
  a video, a game, an image, a PDF viewer, another app's UI.
- "screenshot": the tool is handed the filesystem path of the captured PNG.
  Choose it only when the tool needs the picture itself, for example to crop it,
  convert it, upload it, or read a barcode out of it. A tool that only wants the
  words wants "screenshotText".
Both require trigger "always" — there is nothing in the user's clipboard or
selection to detect them by. A Python candidate reads either one from sys.argv[1]
exactly like any other input; the path is a real file that exists for the length
of the run and is deleted afterwards, so copy it if the tool needs to keep it.
Fixtures for a "screenshot" tool cannot be written, because no PNG exists until
the user drags one: give such a candidate no fixtures.
Use a real SF Symbol from this safe shortlist: sparkles, text.alignleft,
text.quote, textformat, character.book.closed, lightbulb, brain,
magnifyingglass, curlybraces, list.bullet, tablecells, scissors, pencil,
envelope, paperplane, arrow.down.circle, folder, doc.on.doc, doc.richtext,
photo, film, music.note, camera, link, globe, doc.text, bookmark.

For Python candidates:
- Python 3.12, run by uv straight from the script's PEP 723 header.
- Declare every dependency you need in that header, by name only, for example
  dependencies = ["httpx"]. The resolver installs the current release. Do not
  pin a version you remember: your memory of it is older than what exists now,
  and for any package that tracks a moving target that ships a tool which is
  broken the day it is built. Pin only when the tool genuinely needs one
  specific version. An empty list is right when the standard library is enough.
  Gizmate resolves the header before running the script, so an invented package
  name fails the build and comes back to you.
- Read the input from sys.argv[1]. A "files" input tool gets one path per
  argument in sys.argv[1:].
- Print what the user should see to stdout.
- When output is "files", write results into the current working directory with
  relative paths and set outputDirectory to where they belong, for example
  "~/Downloads". Gizmate moves them there after a real run. Printing success
  without writing a file fails validation.

Fixtures decide how the candidate is validated, so choose deliberately:
- One fixture with expectedOutput, when the same input always produces the same
  output. Gizmate runs the script and compares stdout exactly.
- One fixture without expectedOutput, when running it proves something real but
  the output cannot be predicted — anything touching the network, the clock, or
  randomness. Gizmate runs the script and requires a clean exit, plus a real file
  when the tool declares a file output. Give it a genuine input: a working
  public URL, a realistic sample of the text the user described. Prefer the
  smallest real input that still proves the tool works.
- No fixtures at all, when running the script would do something to the user's
  data or to the outside world that they have not asked for yet: sending a
  message, publishing, deleting or overwriting their files. Gizmate then resolves
  the dependencies and compiles the source without executing it.
Decide this before the first write, from what the tool does — not from how
validation went. A failed check means the tool is wrong or the input was, so fix
one of them; removing the fixture is not a way past it and the host rejects it.
Never invent a fixture whose only purpose is to pass: a fixture with no
expectedOutput is better than a guessed expected string.

Example: "я хочу выделить ссылку и сохранить её в заметки" is a native
sendTextToApp candidate targeting "Notes", with selection input, notify output,
selection trigger, empty hosts/extensions, and symbolName "doc.text". It is not
a Python candidate.

Example: "на выделение линки будет открывать ее в браузере" is this complete
native candidate:
{"schemaVersion":1,"kind":"native","name":"Open Selected Link","brief":"Opens the selected link in the default browser.","symbolName":"link","input":"selection","output":"notify","trigger":"selection","hosts":[],"extensions":[],"nativeAction":"openURL","target":"{input}"}
Do not ask which browser and never return UNSUPPORTED for this request.

Never invent candidate IDs or fingerprints. Never call finish_candidate after a
failed validation. Before attestation, finalText is allowed only for the exact
UNSUPPORTED branch above.
`.trim();

function makeActionParser<TName extends string>(
  schema: ReturnType<typeof makeActionSchema<TName>>,
  schemas: Record<TName, z.ZodType>,
): (text: string) => ModelAction<TName> {
  return (text: string) => {
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
    const parsed = schema.safeParse(decoded);
    if (!parsed.success)
      throw new ProtocolError("invalidModelAction", "invalid model action");
    if (parsed.data.action === "finalText") {
      return { action: "finalText", text: parsed.data.text };
    }
    const argumentsResult = schemas[parsed.data.name].safeParse(
      parsed.data.arguments,
    );
    if (!argumentsResult.success) {
      throw new ProtocolError("invalidModelAction", "invalid tool arguments");
    }
    return {
      action: "toolCall",
      name: parsed.data.name,
      arguments: argumentsResult.data as Record<string, unknown>,
    };
  };
}

export const parseModelAction = makeActionParser(actionSchema, argumentSchemas);

/// The same strict JSON action protocol, over an agent tool's two-verb
/// vocabulary instead of a build session's five.
export const parseRunModelAction = makeActionParser(
  makeActionSchema(RUN_TOOL_NAMES),
  runArgumentSchemas,
);

const zeroUsage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
} as const;

function assistantMessage(
  model: Model<string>,
  action: ModelAction<string>,
): AssistantMessage {
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
        errorMessage:
          error instanceof Error ? error.message : "provider failure",
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
    name: "Gizmate Bridge",
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
    name: "Gizmate",
    auth: {
      apiKey: {
        name: "in-memory",
        resolve: async () => ({
          auth: { apiKey: "in-memory" },
          source: "in-memory",
        }),
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

export const runBridgeSystemPrompt = `
You are the model inside a Gizmate agent tool that is running right now for a user who pressed its button. The host transports your native tool calls through strict JSON, so every response must be exactly one JSON object with no markdown fence and no text before or after it.

To call a tool, reply: {"version":1,"action":"toolCall","name":"TOOL_NAME","arguments":{...}}
After finish succeeds, end the session with:
{"version":1,"action":"finalText","text":"done"}

You have exactly two tools.

run_python — write a complete Python 3.12 script and the host runs it, then hands
you back its exit code, stdout, stderr and any files it wrote. Arguments are
"source" and a short "purpose" saying what this step is for. This is your only
way to affect or observe anything: the network, the user's files, a command-line
program, a PyPI library. Declare dependencies in the script's PEP 723 header by
name only, for example dependencies = ["httpx"]. Each call is a fresh script in a
fresh empty directory — nothing carries over between calls except what you read
back and what you write into a path you chose deliberately. Print what you want
to see; you are reading the output, not the user.

finish — end the run and hand your answer to the user. The "text" argument is the
tool's entire result: it goes straight into a panel, the clipboard, or over the
user's selection, depending on how they configured the tool. Write the answer
itself, not a report about your work. No preamble, no "I ran a script and found",
no markdown headings unless the answer genuinely is a document.

You are working, not chatting. Do not ask questions — there is nobody to answer
them, and the run has a hard step budget. When something is ambiguous, make the
most useful assumption and say what you assumed in the finished text.

If a script fails, read its stderr and try a different approach. If you genuinely
cannot do the job — the site is down, the file is not what it claimed to be, a
credential is missing — call finish anyway and say plainly what stopped you. A
run that ends without finish shows the user an error with no explanation, which
is worse than an honest one.

Do not run a script for its own sake. If the input already answers the question,
call finish immediately. Every run_python call spends budget the user is waiting
on.

The user message is a JSON serialization of the current Pi conversation and the
two available tool schemas. Read the latest user or toolResult message before
choosing the next action.
`.trim();

export function serializeContext(
  context: Context,
  bridgePrompt: string = bridgeSystemPrompt,
): {
  readonly system: string;
  readonly user: string;
} {
  const sessionSystem = context.systemPrompt?.trim() ?? "";
  const system =
    sessionSystem.length > 0
      ? `${bridgePrompt}\n\nSession goal:\n${sessionSystem}`
      : bridgePrompt;
  const user = JSON.stringify({
    messages: context.messages,
    tools: context.tools ?? [],
  });
  if (
    Buffer.byteLength(system) + Buffer.byteLength(user) >
    LIMITS.transcriptBytes
  ) {
    throw new ProtocolError("invalidProtocol", "model context too large");
  }
  return { system, user };
}
