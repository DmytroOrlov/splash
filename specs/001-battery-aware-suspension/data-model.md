# Lifecycle Data Model

This describes the feature's runtime information and ownership boundaries. It is not a database schema.

## PowerIntent

| Field | Meaning |
|---|---|
| `source` | `ac`, `battery`, or `unknown` from the thin native observer. |
| `revision` | Monotonically increasing owner revision for a changed authoritative observation; duplicate observations do not advance it. |
| `observed_at` | Detached observation timestamp for diagnostics only. |

**Owner**: the single lifecycle authority inside `RuntimeBootstrap`. The IOKit adapter reports values and does not own policy.

## ControlReadiness

| Field | Meaning |
|---|---|
| `control_ready` | True after the one-shot handshake for the current native process generation. Concretely this is the **existing wire `ReadyEvent`**, redefined to mean control/generation readiness rather than "warmed inference is ready". Stays true while the child is healthy, including during `draining`, `suspended`, `recovering`, and `recovery_failed`. |
| `generation` | The `MultiplexedRuntime` generation the handshake belongs to. Only EOF, process exit, or protocol failure advances it. |

**Owner**: the native startup handshake path (`NativeRuntime`/`RuntimeBootstrap` startup), completed once per generation.

**Invariants**:

- Exactly one readiness handshake per native process generation; never re-emitted for suspend or recovery. There is no second `ReadyEvent` later in the same generation and no separate optional "model `ReadyEvent`".
- Completes the startup attempt and suppresses ordinary startup timeout/relaunch for an intentionally model-less child.
- Carries/exposes only pre-residency static capability information: configured/descriptor context ceiling (not the memory-plan-resolved effective context), static concurrency capability, feature bits/vision capability derivable from descriptor or configuration, and engine/generation identity — for building the HTTP/frontend control plane.
- Does not imply `inference_ready`, and its absence does not imply a stale generation.
- A new generation always starts with `control_ready=false` and cold recovery.

## InferenceReadiness

Separate from `ControlReadiness`. It is a dynamic lifecycle value that may transition `false -> true -> false -> true` within a single generation:

| Step | `control_ready` | `inference_ready` | New generation? |
|---|---:|---:|---:|
| Startup on battery | true | false | no |
| AC recovery succeeds | true | true | no |
| Battery suspension | true | false | no |
| Later AC recovery | true | true | no |
| Actual child failure | false -> true (new handshake) | false (cold) | yes |

**Owner**: `RuntimeBootstrap`, exposed only through detached lifecycle/status state.

**Delivery**: read on demand through the existing status request/response surface (`StatusRequestFrame` -> `StatusJsonEvent`), never as an unsolicited push. Python consumers (`can_submit()`, `is_ready()`, HTTP `/ready`) reach it through a bounded status-refresh path triggered from the cached lifecycle value, so a cached false or stale snapshot cannot leave Python permanently closed after native AC recovery. Refresh is passive while model-less (no process start/replace, no restore), is not mandated per request, and is never authoritative for correctness against a closed native gate.

## InferenceLifecycle

| Field | Meaning |
|---|---|
| `state` | `ready`, `draining`, `suspended`, `recovering`, `recovery_failed`, or `shutdown`. |
| `intent_revision` | Revision that the current transition is serving. |
| `inference_ready` | True only when a usable candidate `Engine`/runtime is published and current intent authorizes serving. |
| `control_ready` | Mirror of `ControlReadiness.control_ready` for status convenience; one-shot per generation. |
| `model_resident` | True only while target/draft package, runtime objects, and `Engine` remain published. |
| `effective_context_tokens` | Memory-planning-resolved serving context; null/absent until a recovery resolves it; published or updated before `inference_ready` becomes true and used by admission. |
| `configured_context_ceiling` | Detached configured/descriptor context ceiling, available before weight loading. |
| `last_error` | Detached error code/message for failed suspend or recovery; absent on success. |
| `transition_id` | Optional internal identifier for one transition attempt, used to bind completion to its captured intent revision. |

**Invariants**:

- Only `ready` has admission open.
- `draining`, `suspended`, `recovering`, `recovery_failed`, and `shutdown` reject new inference with explicit unavailable/not-ready behavior, never warmup wording.
- `suspended` is published only after release proof for the residency stratum (`Engine`, `RuntimeModel`, `ModelPackage`).
- A transition completion may publish only if its captured revision remains current.
- Status reads return detached values and never cause a transition, restart the child, load a model, or destroy/unpin warm-state backing.
- `inference_ready=false` never implies a stale generation.
- A cached false or stale `inference_ready` in Python must not leave admission permanently closed after native AC recovery: consumers use a bounded status-refresh path to rediscover it. A stale `true` is never authoritative; the native gate still rejects after battery closure.
- An inconsistent or unsafe `effective_context_tokens` fails closed: `inference_ready` stays false and admission stays closed.
- Context drift alone never advances the generation.

## ResourceOwnershipStrata

Two semantic strata; ownership decisions always name one of them.

**Retainable / base** — survives a normal `ready` -> `suspended` transition:

- backend and accounting required by retained state
- `Cache` / `StateCache`
- KV pool/backing/tier
- `StateStorage` required by retained `CompositeState`
- `SlotFile` workers/backings
- detached `ModelDescriptor`/configuration and cache identity
- detached status/resource snapshots

On cold startup on battery, even this stratum need not exist until the first AC load, because no reusable warm state exists yet.

**Residency** — destroyed at suspension, rebuilt only inside a private recovery candidate:

- `ModelPackage` target/draft/vision weights
- `model::RuntimeModel`
- execution arenas/continuations
- `Engine`
- model-derived callbacks/factories that retain residency

## AdmittedInference

An inference request crosses final admission when native `NativeRuntime::handleRequest()` consults the bootstrap-owned lifecycle gate immediately before `Engine::submit()` and inserts the request. Thereafter its request map entry, `Scheduler` phase, cache leases, model lane/state resources, payload, and any pending `ModelBatchTicket` remain protected until the existing completion/cancellation boundary. A queued or waiting-resource request already admitted is part of the drain; a frame processed after gate closure is rejected. While no `Engine` is published, `NativeRuntime` inference methods reject explicitly as unavailable/not-ready; protocol, status, and control paths remain operational.

## ReusableInferenceState

The currently reusable pair is content-addressed target KV prefix data in `Cache` plus a `CompositeState` attached through `StateCache`. For Qwen hybrid models the composite state contains target recurrent/GDN state and draft-context state, with logical target/draft lengths and an exact `CompositeStateLayout`.

| Storage form | Current owner/lifetime | Suspension treatment |
|---|---|---|
| Active request lane | `RuntimeModel` and `StateStorage`; tied to request/ticket | Drain to terminal boundary; do not preserve as a live request. |
| RAM `CompositeState` | `StateCache` entry; owns private buffers and a shared `QwenBufferPool`/Metal state objects | Prefer complete disk materialization then release the RAM handle. If no disk tier exists, retain only a bounded candidate while deliberately keeping/accounting its state-pool and backend owners. |
| Disk `CompositeState` | `StateCache` entry with `SlotFile`/`Slot` backing and stored layout/lengths | Retain while the same `SlotFile` worker/backing and process remain alive; immutable source stays retryable through candidate attempts. |
| RAM KV pages | `Cache`/`KvPool`/`PageStorage`; bound to same Metal backend | Retain only as the base cache graph requires; report its footprint separately from released weights/runtime. |
| Disk KV pages | `KvPageTier`, `SlotFile`, `KvPool` metadata | Process-local only; keep the worker/backing and compatible cache metadata alive, or drop and recover cold. |

## RecoveryCandidate

Private unpublished objects: the required resource graph when it does not already exist, a freshly loaded `ModelPackage`, `RuntimeModel`, target/draft/vision wrappers, execution arenas, a newly constructed `Engine`, and validation results. Candidate flow is:

1. Load using saved immutable `ModelDescriptor`/configuration.
2. Recompute `RuntimeCacheIdentity`; compare saved identity and retained descriptor/KV/state layout.
3. Restore immutable retained composite state using existing state restore path.
4. Resolve the effective serving context through memory planning and validate it.
5. If any warm step fails, leave source cache entry/backing intact and retry cold.
6. Publish the candidate `Engine` and open admission only after **all** of: warm restore succeeded or cold recovery succeeded; runtime is usable; captured lifecycle revision is still current; latest power intent authorizes serving; effective context is consistent and safe.
7. Publishing sets `inference_ready=true` inside the existing generation, with no new readiness handshake and no new generation.

A stale candidate (superseded revision or power intent) is destroyed without damaging retained retryable state.

## ResourceSnapshot

Detached native status data, servable without an `Engine`. It carries backend allocation totals, `control_ready`, `inference_ready`, `lifecycle.state`/`power`/`revision`, `model_resident`, effective and configured context values when known, model package/runtime resident flag/bytes where provable, retained cache/KV/state byte totals, and failure reason. Existing seams include `MetalBackend::memoryStats()`, `RuntimeModel::actualRuntimeMemory()`, `StateStorage::actualAllocatedBytes()`, `CacheSnapshot`, and `MemoryGovernor::snapshot()`. Model-derived runtime telemetry (batch/scheduler/model telemetry) is reported as unavailable when residency is absent, never stale-as-live. No snapshot may retain a model/runtime/`Engine` pointer, and taking one never triggers load, restore, or restart.
