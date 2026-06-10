# Cloud Model Discovery — Design

**Date:** 2026-06-10
**Status:** Approved

## Problem

The model picker's cloud sections (OpenAI / Anthropic / Google) come from the
hardcoded `LLMModel.all` list in `Sources/Nugumi/App.swift`. The list goes
stale in both directions: new models never appear until an app release, and
retired model ids keep being offered and then 404 at translation time.

The codebase already solves this for two other backends — Ollama
(`OllamaModelCache`, fed by `/api/tags`) and ChatGPT-subscription Codex
(`CodexModelCache` + `CodexModelDiscovery`) — using the same pattern:
**live fetch → UserDefaults cache → curated fallback**. This design extends
that pattern to the three API-key providers.

## Decisions (made with the user)

1. **Curated + discovered merge** (not fully dynamic, not top-N): the
   hardcoded list stays as fallback and as the source of pretty names/tier
   hints; discovered models confirm or extend it.
2. **Refresh on key entry + app launch** (no manual refresh menu item).

## Components

### 1. `CloudModelCache`

Thread-safe per-provider cache of discovered model ids, placed next to
`CodexModelCache` in App.swift.

- Storage: `UserDefaults` key `cloud.discoveredModels.<provider rawValue>.v1`
  (one string array per provider).
- Concurrency: `NSLock` + in-memory memo, same shape as `CodexModelCache`.
- `discovered(for provider: CloudProvider) -> [String]?` — `nil` when no
  successful fetch has ever happened for that provider (distinguishes
  "never fetched" from "fetched, empty"). Persisted state implies fetched.
- `update(provider:ids:)` — persists, updates memo, posts
  `.cloudModelsUpdated` notification (new `Notification.Name`, mirrored on
  the existing `.codexModelsUpdated` wiring so the model menu rebuilds).
- Only `.openAI`, `.anthropic`, `.gemini` participate; `.openAICodex` keeps
  its own existing cache.

### 2. `CloudModelDiscovery` — parsing + family filters

Pure parsing functions (testable without network) plus a best-effort
`refreshFromAPI(provider:)`.

Response shapes:

- **OpenAI** `GET /v1/models` → `{"data": [{"id": "..."}]}`.
  Keep ids matching prefix `gpt-5`; drop ids containing any of
  `-audio`, `-realtime`, `-search`, `-tts`, `-transcribe`, `-image`,
  `-codex` (those are non-chat or Codex-only variants).
- **Anthropic** `GET /v1/models` (headers `x-api-key` +
  `anthropic-version: 2023-06-01`) →
  `{"data": [{"id": "...", "display_name": "..."}]}`.
  Keep ids with prefix `claude-`. The returned `display_name` is used as the
  ready-made pretty name for non-curated entries.
- **Gemini** `GET /v1beta/openai/models` →
  `{"data": [{"id": "models/gemini-..."}]}`.
  Strip the `models/` prefix, keep ids with prefix `gemini-`; drop ids
  containing `embedding`, `tts`, `image`, `live`, `audio`.

`refreshFromAPI(provider:)`: reads the key from `KeychainStore`; no key →
no-op. Network/HTTP/parse failure → cache untouched (same best-effort
contract as `CodexModelDiscovery.refreshFromAPI`). Empty parse result →
cache untouched (defensive: a provider returning an unrecognized payload
must not wipe the picker down to nothing).

### 3. Merge into the picker — `LLMModel.cloudModels(for:)`

Replaces direct uses of `LLMModel.models(for:)` where the picker builds
provider sections. Semantics:

- **Never fetched** (`discovered == nil`): return the curated list as today.
- **Fetched:**
  - Curated entries come first, in `all` order, keeping their hand-written
    display names and tier hints ("fast", "flagship", …).
  - A curated entry whose id is absent from the discovered list is
    **hidden** (the provider retired it; offering it would 404 at runtime).
  - Discovered ids not matching any curated id are appended after the
    curated block, newest-looking first (descending id sort within the
    provider), with:
    - `displayName`/`shortName` generated from the id
      (`claude-opus-4-8` → "Claude Opus 4.8", `gpt-5.6` → "GPT-5.6",
      `gemini-3.0-pro` → "Gemini 3.0 Pro"); Anthropic uses the API's
      `display_name` when present.
    - `supportsImages: true` optimistically — same trade-off as
      `makeCodexModel` (the backend rejects images for text-only models;
      hiding usable models is worse).
- `LLMModel.option(id:)` gains a resolution step for discovered cloud ids
  (mirroring how discovered Ollama models resolve), so selection persists
  across launches and backend dispatch finds the model.

Anthropic id ↔ curated id matching must tolerate the dated-suffix
convention: curated `claude-haiku-4-5-20251001` matches a discovered id
that is equal OR differs only by the trailing `-YYYYMMDD` date stamp.

### 4. Refresh triggers

- **Key entry:** `APIKeyValidator.validate` already GETs
  `provider.modelsURL` and discards the body. On HTTP 200 it now hands the
  body to `CloudModelDiscovery` for parse+cache. Zero extra requests.
- **App launch:** in `applicationDidFinishLaunching`, fire a detached
  best-effort `refreshFromAPI(provider:)` for each of the three providers
  that has a key in `KeychainStore`.

### 5. Out of scope

- `ModelUseScope.defaultModelID`'s hardcoded `"gpt-5.5"` default stays:
  it is a default _selection_, not a list, and `LLMModel.option(id:)`
  already degrades gracefully.
- No manual "Refresh models" menu item.
- No changes to Ollama or Codex discovery.
- `.openAICodex` is excluded from `CloudModelCache`.

## Error handling

- All fetches are best-effort: any failure (no key, network, non-200,
  parse error, empty result) leaves the existing cache and therefore the
  picker untouched.
- The curated list is the permanent floor: a user who never gets a
  successful fetch sees exactly today's behavior.

## Testing

Extend `Tests/NugumiTests/ModelRoutingTests.swift` (or a sibling) with
pure-parsing tests — no network:

1. OpenAI fixture: chat models kept, `whisper-1`/`tts-1`/`dall-e-3`/
   `text-embedding-*`/`gpt-5.3-codex`/`gpt-5.4-audio` dropped.
2. Anthropic fixture: `claude-*` kept with `display_name` carried through.
3. Gemini fixture: `models/` prefix stripped, embedding/tts/live variants
   dropped.
4. Merge: curated id present in fetch → keeps curated pretty name; curated
   id absent → hidden; new id → appended with generated name.
5. Anthropic dated-suffix matching (`claude-haiku-4-5-20251001` ≈
   `claude-haiku-4-5`).
6. Never-fetched state returns the curated list unchanged.
7. Name generation from raw ids for all three providers.
