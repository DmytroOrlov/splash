# Contract: Native Control, Status and Protocol Context Semantics

Covers 003 FR-002, FR-007, FR-019, FR-020, FR-022, FR-023, FR-024; constitution III, VI, VII, VIII, XII. Referenced from `plan.md` workstreams D/F and `data-model.md` §3, §7.

## Current upstream facts (baseline; must be preserved), with provenance

All rows below are `[U]` — verified at clean HEAD `a8a74e6`. Items that only appear in the conflicted working tree are labelled `[D]` and are **not** baseline facts.

| Fact | Provenance | Source |
|---|---|---|
| Wire framing: `kProtocolVersion = 11`, `kFrameHeaderBytes = 16` | `[U]` | `runtime/engine/Protocol.hpp:21,24`; `server/protocol.py:18,21` |
| Status schema version 6 | `[U]` | `runtime/engine/Protocol.hpp:25`; `server/protocol.py:22`; pinned in `dev/tests/engine/status_golden.json`, `dev/tests/server/test_status_contract.py`, `dev/tests/native_peer.py` |
| `ReadyEvent { maxConcurrentRequests, maxContextTokens, vision }`; one per process generation; the server rejects a second announcement | `[U]` | `runtime/engine/Protocol.hpp:239-246`; `server/protocol.py:319` |
| `StartEvent { requestId, lane, matchedPromptTokens }` — no capacity field; the frame is packed/unpacked by position | `[U]` | `runtime/engine/Protocol.hpp:253-259`; `server/protocol.py:327` + `_START` pack/unpack |
| Consumers of `ReadyEvent.max_context_tokens` (one value used for ceiling, validation, relaunch and the frontend serving limit) | `[U]` | `server/server.py:1817` (relaunch argv), `:1834-1836` (validation), `:1841` (`effective_context = readiness.max_context_tokens` → `Frontend`), `server/runtime.py:1183-1187` (cross-relaunch equality), `server/frontend.py` |
| Historical in-band capacity telemetry: `StartEvent.capacityTokens` (with a different frame layout: `cacheDisposition`, `slotIndex`) | `[S3]` | `f9f4eb3a:runtime/engine/Protocol.hpp:265-273`; `f9f4eb3a:server/protocol.py:289,940-942,1594` |
| Native CLI parsing owned by `NativeArguments` / `parseNativeArguments` | `[U]` | `runtime/engine/NativeArguments.hpp:23,88` |
| Native loop/control path: `FdTransport::run/controlNotifier`, `Bootstrap::controlPass/statusJson/sampleThermalState`, `NativeRuntime::receive/finishInput/tick/runControl/flushRestorePoints/announceReady` | `[U]` | `runtime/engine/FdTransport.hpp`, `Bootstrap.hpp:145,152,165` |
| Python child handling is generation-aware with relaunch on failure: `MultiplexedRuntime`, `GenerationRequest`, `RuntimeCall.generation`, `_ready_message`, `relaunch_command(ReadyEvent)`, `_StatusWaiter` | `[U]` | `server/runtime.py:146,167,174,445,481-483,413` |
| Python readiness folding: `NativeBackend.is_ready/refusal/_recover/_relaunch/_ensure_recovery_locked/status_snapshot` | `[U]` | `server/backend.py:543,524,476,510,453` |
| Frontend uses one `max_context` value for budgeting **and** context-length errors | `[U]` | `server/frontend.py:242,296,403,405,707,708,773,774,1216,1217,1218` |
| Shared serve options in `server/serve_options.py`; public CLI chain `install/launcher.py::serve/parse_args` | `[U]` | `server/serve_options.py:93,235`; `install/launcher.py:228,416` |
| Idle-sleep assertion and holding-requests wiring in the native entry point | `[U]` | `runtime/main.mm:107-111`, `NativeLoopConfig::holdingRequests` |
| `NativeAdmissionGate`, lifecycle status types, `RuntimeBootstrapTestAccess`, model-less start and suspend/recovery pumps | `[D]` | working tree only — absent at HEAD; re-derived as `[P]` with their own tests |

## Lifecycle/status surface (proposed completion of an in-tree draft)

`LifecyclePower`, `LifecycleState { Ready, Draining, Suspended, Recovering, RecoveryFailed, Shutdown }`, `LifecycleStatusSnapshot`, `validLifecycleStatus` and the fail-closed emission checks exist in the working tree only because stage 3 auto-merged (`runtime/engine/Status.hpp`, `Status.cpp:285-360`). They must be re-verified against schema 6 rather than assumed correct.

```cpp
// [D→P] observation, never execution:
[[nodiscard]] LifecycleStatusSnapshot lifecycleStatus() const;   // detached, mutex-guarded copy
[[nodiscard]] ResourceSnapshot detachedResourceSnapshot() const; // retained graph after release
bool observePower(LifecyclePower);      // records + wakes; new revision only on change
bool publishLifecycleStatus(LifecycleStatusSnapshot);            // revision-fenced
```

Rules carried by the interface:
- Power callbacks **record and wake only**; `RuntimeBootstrap` applies policy on the native owner/safe-point thread (constitution III).
- Registration precedes the synchronous initial sample; a callback racing ahead of the sample is newer information and is not overwritten by a late `recordInitial()` (`runtime/engine/PowerSource.hpp::PendingPowerObservation` — stage-3-only file, re-anchored onto upstream `Status.hpp`).
- Unknown power is not AC: it closes inference readiness and cannot authorize recovery or native admission.
- Duplicate observations of the same power are harmless.

## Context semantics: three values, one undecided telemetry mechanism

| Value | Meaning and source | Surfaces | Stability |
|---|---|---|---|
| configured ceiling | static pre-residency configuration | `ReadyEvent.maxContextTokens`, `/v1/models` | fixed for the whole generation |
| effective serving context | the currently **published** `Engine` only | lifecycle status `effective_context_tokens` | changes only through a fenced recovery publication |
| per-request capacity | the capacity of the exact `Engine` that served the request | request telemetry | **approved: in-band `StartEvent.capacityTokens` field with a coordinated `PROTOCOL_VERSION` bump (U-05)** |

**Reconciling the `ReadyEvent` meaning shift.** At HEAD one value does all three jobs: `server/server.py:1841` assigns `effective_context = readiness.max_context_tokens` and hands it to `Frontend`, which uses it both as a budget and as the `ContextLengthError` threshold (`server/frontend.py:403-405,707-708,773-774,1216-1218`). Under 001's contract that same wire value is the ceiling, so the migration must split the consumers rather than rename the field:

| Consumer | Required behaviour after migration |
|---|---|
| `server/server.py:1834-1836` | keep validating against configuration (a ceiling check stays valid) |
| `server/server.py:1841` → `Frontend` | **split**: ceiling stays for capacity/`/v1/models`/`max_model_len`; request-limit decisions take the status-borne effective value |
| `server/server.py:1817` relaunch argv | keep the relaunch-context semantics upstream feeds `RuntimeResourcesConfig::relaunchContext`; Battery recovery is **not** a relaunch, so this path stays untouched |
| `server/runtime.py:1183-1187` | cross-relaunch equality on the static tuple remains valid, since the tuple is static by definition |

**Per-request capacity contract (U-05 — approved: in-band field).** The contract is settled by the authoritative `REBASE_HEAD` commit message: `StartEvent capacityTokens` is per-request telemetry that must follow the currently published `Engine`, and `Engine` adoption updates the shell's request-telemetry context only after that exact `Engine` is published. Implementation therefore **carries capacity in-band on `StartEvent`** (as stage 3 did), which changes a fixed packed frame on both codecs and forces the coordinated `PROTOCOL_VERSION` bump defined by D-12 rule 3. Deriving request capacity from the status-borne effective value read at request-issue time is **rejected** — it does not establish the original `StartEvent` contract and risks attributing the wrong capacity across recovery transitions. Inventing a parallel telemetry channel outside both codecs remains rejected. The coordinated change preserves the upstream 16-byte frame header and every existing event field/behaviour; the historical 24-byte header, v7 framing and `cacheDisposition`/`slotIndex` fields are not restored. The change is a wire/protocol bump only: the JSON status-schema axis is untouched (no `kStatusSchemaVersion` bump for optional fields). The test is unchanged: recovery resolves a smaller context, and the attributed capacity follows the published Engine, never the ceiling. Until that extension and its test land, Gate 12 remains unpassed.

Fail-closed rules present in the auto-merged status path and to be re-verified (they are `[D]`, not upstream guarantees): inference-ready status requires a valid published lifecycle context, requires `effectiveContextTokens == core.maximumContextTokens` when inference-ready, and requires physical model health. Missing or inconsistent inference-ready data must fail closed, never fall back to an older plausible value (FR-023).

## Readiness invariants

1. Exactly one `ReadyEvent` per process generation; Battery never replaces the child and never emits a second announcement; `inference_ready` may toggle repeatedly inside a generation (FR-022, 002 FR-011/SC-006).
2. No second "recovery ready" handshake: dynamic lifecycle state belongs to status (constitution III, IX).
3. Control readiness, process aliveness, inference readiness and model residency are four distinct booleans; they must not collapse.
4. Passive reads: `/ready`, `/status`, `/health`, `/metrics`, `/v1/models` must not load weights, rebuild `RuntimeResources`, publish an `Engine`, call `wait_ready()`, replace the child, or open admission (FR-007, SC-011).
5. Status describes physical ownership, not inferred from lifecycle strings (FR-019).

## Python-side contract

- Python readiness is a **fail-closed prefilter** over the native gate; the `[P]` native admission gate is the correctness boundary (FR-024).
- No unsolicited lifecycle push, no busy polling, no second handshake: bounded freshness with one passive refresh when lifecycle state is expired or missing; suspended generations are refreshed at the same bounded rate so ordinary traffic discovers recovery.
- **Three ordering domains** (constitution VI, research D-14). A completion is applied only when its tuple is strictly greater than the last applied one:

  | Domain | Orders | Source |
  |---|---|---|
  | `processGeneration` | status across child replacement | `[U]` `server/runtime.py` `RuntimeCall.generation` |
  | `lifecycleRevision` | status across power-revised intents inside one generation | `[P]` revision counter owned by `RuntimeBootstrap` |
  | `observationSequence` | lifecycle phases **within one revision** | `[P]` monotonic per-generation counter published by the native lifecycle owner at every lifecycle publication, carried as an additive status field |

- Why the third domain is required: one Battery revision spans `Draining → Suspended`, one AC revision spans `Recovering → Ready`, and the newer-AC reconciliation moves `Draining → Suspended` without a new revision. A revision-only rule treats those phases as equal, so an older snapshot could overwrite a newer one. **HTTP completion order is transport order and is never treated as observation order.**
- Compatibility allowance (not a substitute): if the producer publishes no `observationSequence` (older native build), Python may fall back to its own status-request issue sequence, provided a native-side test asserts that a later-issued request never receives an older snapshot.
- Never call `wait_ready()` merely because `inference_ready` became false.

## Compatibility rule for wire and schema change (research D-12)

Two independent axes; neither implies the other.

- **Status schema axis** (`kStatusSchemaVersion`): bump only when an existing JSON field's name, type, unit or semantics changes. Purely additive optional fields neither require nor forbid a bump, given tolerant absence handling both directions and simultaneous updates to `dev/tests/engine/status_golden.json`, `dev/tests/server/test_status_contract.py`, `server/metrics.py`'s `PROMETHEUS_SERIES` and `dev/tests/native_peer.py`.
- **Wire protocol axis** (`PROTOCOL_VERSION`, native and Python): bump whenever a message's binary layout changes — including any field added to or removed from a fixed packed frame such as `StartEvent` — and the bump must land simultaneously in the native codec, the Python codec, validators, `protocol_golden.txt`, `status_golden.json` and `native_peer.py`. A bump is permitted by FR-020 and is neither forbidden nor adopted in advance; the numeral 11 has no special protection. What is preserved unconditionally is the **16-byte framing** and the existing event functionality (one readiness announcement per generation, child relaunch on failure).
- The historical patch's 24-byte header, its v7-era framing and its status schema 5 are not migrated; its `StartEvent` field set is treated as stage-3 evidence, not as an obligation to restore.

## Verification obligations

| Gate | Proof | Seam (provenance) | Status |
|---|---|---|---|
| 12 — static ceiling vs effective context | recovery resolves a smaller context; ceiling and effective stay distinct; request capacity follows the published Engine via the approved in-band `StartEvent.capacityTokens` field; inconsistent inference-ready data fails closed | `[U]` `runtime_status_test.cpp`, `status_golden.json`, `test_status_contract.py`; `[P→approved]` in-band `StartEvent` capacity field + `protocol_golden.txt` | **U-05 approved; gate unpassed until the coordinated extension and its deterministic test land** |
| SC-003 — one announcement per generation | AC→Battery→AC emits zero additional announcements and zero child replacements | `dev/tests/server/test_runtime.py` fakes | owed in WS F |
| 11 — Python ordering, including **same-revision** ordering | old-generation completion discarded; lower revision ignored; **two completions with the same generation and same revision arriving in reverse observation order must not regress lifecycle state**; status reads cause no residency work | `dev/tests/server/test_runtime.py` + `[P]` `observationSequence` fixture | owed in WS F |
| FR-020 — upstream behaviour unchanged | existing event functionality incl. rejection of a second per-generation readiness and child relaunch on failure | `test_protocol_python.py`, `test_crash_trace.py`, `protocol_test.cpp` golden vectors | owed in WS A/F (baseline from the clean commit per D-15) |
