# Context compatibility axes — clean upstream `a8a74e6`

## Actual upstream consumers of `ReadyEvent.maxContextTokens`

### Native producers and validators

- `a8a74e6:runtime/engine/Protocol.hpp:239` defines `ReadyEvent.maxContextTokens`.
- `a8a74e6:runtime/engine/Protocol.cpp:576-583` serializes it as the second `u32` of the Ready payload.
- `a8a74e6:runtime/engine/Protocol.cpp:421-426` validates that both Ready capacities are nonzero.
- `a8a74e6:runtime/engine/NativeRuntime.cpp:220-231` emits `config_.engine.maxContext` once after startup warmup/memory audit.
- `a8a74e6:runtime/engine/Bootstrap.mm:159-261` calls `announceReady()` only after warmup and memory audit; the startup context was selected/resolved earlier in `RuntimeBootstrap::start()`.

Clean upstream behavior: the process's startup context is also the context announced and consumed as the serving context.

### Python runtime/control generation

`a8a74e6:server/runtime.py`:

- Stores ReadyEvent in `_ready_message` and `_first_ready` around `:483-486`.
- Handles exactly one ReadyEvent per current generation and compares `max_context_tokens` against `_first_ready` at `:1163-1203`.
- Provides `readiness` property around `:544-545`.
- Rejects native events before ReadyEvent at `:1215`.
- Relaunch compatibility compares context/concurrency/vision domains and refuses a changed announced window at `:1196-1199`.

### Server startup and model catalog

`a8a74e6:server/server.py`:

- `:1816-1817` constructs the relaunch command with `first.max_context_tokens`, passing it as `relaunch_context`.
- `:1830` reads `runtime.readiness` after native startup.
- `:1833-1840` validates readiness context against either the explicit `--max-context` or the bounded automatic context range.
- `:1841` sets `effective_context = readiness.max_context_tokens`.
- `:1847` passes that same value into `Frontend` as `max_context`.
- `:595` reports `/v1/models` with `"context_length": self.app.max_context`.
- `:1867-1869` prints the startup context banner from `effective_context`.

### Frontend serving limits

`a8a74e6:server/frontend.py`:

- `:242` receives `max_context`; `:296` stores it as the single `self.max_context`.
- `:403-405` rejects tokenized input at or beyond `self.max_context` during prompt preparation.
- `:707-708` and `:773-774` raise `ContextLengthError` when prompt tokens exceed `self.max_context`.
- `:1216-1218` derives output budget and context-length errors from `self.max_context`.

Thus, clean upstream uses the ReadyEvent value as a single serving context: readiness announcement, frontend request limit, `/v1/models` reporting, startup banner, and relaunch context compatibility all consume the same value.

## Approved migration contract (not implemented here)

The approved 003 migration separates two concepts that clean upstream currently conflates:

1. **Static ceiling:** `ReadyEvent.maxContextTokens` becomes the configured/pre-residency ceiling, not necessarily the current effective served context after lifecycle transitions.
2. **Effective context:** request-limit and capacity telemetry must follow the exact published Engine through status/lifecycle compatibility; `StartEvent.capacityTokens` is the approved in-band per-request carrier (T042).

Current upstream evidence:

- There is no lifecycle revision, effective-context status source, or `StartEvent.capacityTokens` at `a8a74e6`.
- `Frontend.max_context` is assigned once at startup from readiness.
- `/v1/models` reports `Frontend.max_context`.
- Native ReadyEvent is emitted once per process/control generation and no second lifecycle-context announcement exists.

This distinction means T003 records upstream behavior only; it does not implement the split.

## Independent compatibility rules

### Wire protocol-version axis

Affected sources/constants:

- `a8a74e6:runtime/engine/Protocol.hpp:21`, `kProtocolVersion=11`
- `a8a74e6:server/protocol.py:18`, `PROTOCOL_VERSION=11`
- Frame header is 16 bytes: magic `"SPLH"`, protocol version `u16`, frame type `u16`, payload length `u64`.
- Native header check: `a8a74e6:runtime/engine/Protocol.cpp:1070-1071` treats a version mismatch as `UnsupportedVersion` / protocol-fatal.
- Python header check: `a8a74e6:server/protocol.py:1248` rejects a version mismatch.
- Test peer/header: `a8a74e6:dev/tests/native_peer.py:136` packs the header, and `:236` checks it.

Rule: any event payload layout change is a wire compatibility change. It must be coordinated across both codecs, native/Python validators, golden vectors, and the native peer fixture, and it requires a protocol-version increment. It must preserve the 16-byte header unless the framing itself is explicitly being migrated; the approved U-05 decision is an in-band event-field extension, not restoration of the historical 24-byte header/v7 framing.

### JSON status-schema axis

Affected sources/constants:

- `a8a74e6:runtime/engine/Protocol.hpp:25`, `kStatusSchemaVersion=6`
- `a8a74e6:server/protocol.py:22`, `STATUS_SCHEMA_VERSION=6`
- Native status document emits its own `schema_version`: `a8a74e6:runtime/engine/Status.cpp:321`.
- Python status ingestion validates JSON `schema_version` independently of frame decoding: `a8a74e6:server/backend.py:552`.
- Python fallback status uses the current schema version: `a8a74e6:server/backend.py:617`.

Rule: status JSON compatibility is independent of the wire protocol version. A status-schema bump is required only when the JSON document's required/field semantics are incompatible. Additive optional status fields do not by themselves force `kStatusSchemaVersion` to change; conversely, changing a binary event payload does not by itself force a status-schema change.

### Cross-axis rule

The approved migration permits coordinated changes on either axis where evidence requires it. Adoption must not be based merely on preserving `PROTOCOL_VERSION=11` or merely on adding JSON fields. A change is compatible only when the relevant codec pair, validators, fixtures, consumers, and tests are moved together for that axis.
