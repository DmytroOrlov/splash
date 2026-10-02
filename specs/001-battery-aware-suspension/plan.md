# Implementation Plan: Battery-Aware Suspension and Recovery

**Branch**: `001-battery-aware-suspension` | **Date**: 2026-10-01 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-battery-aware-suspension/spec.md`

## Summary

Add one native lifecycle authority at the existing `RuntimeBootstrap` ownership boundary. It will serialize battery intent with native request admission, drain requests and command tickets, release the residency stratum (`Engine`, `model::RuntimeModel`, and the target/draft `ModelPackage`), and retain the process-local cache/backing graph needed for a proven warm recovery. `FdTransport` and `NativeRuntime` remain long-lived as the native protocol/control/status shell, so HTTP/control-plane connectivity and unlinked cache files survive. `Engine` is residency-dependent and exists only while its `Cache` and `model::Model` dependencies are valid; it is destroyed at suspension and recreated inside a private recovery candidate, so a dangling `model::Model` reference is structurally impossible. A thin macOS IOKit power observer supplies initial and live observations. On AC, a candidate model package/runtime/Engine is rebuilt against retained resources; compatibility and state restoration are checked before admission is reopened. Failed candidates leave immutable retained cache entries retryable and can fall back to cold initialization. Process/control readiness is a one-shot per native process generation and is a different concept from inference readiness, which is a dynamic lifecycle state that may transition `false -> true -> false -> true` inside one generation.

## Technical Context

**Language/Version**: C++20/Objective-C++ for the native engine; Python 3.12–3.14 server (Makefile validation range).

**Primary Dependencies**: Metal, Foundation, IOKit (already linked by `Makefile`); Python standard library; existing binary protocol.

**Storage**: Process-local RAM and unlinked `SlotFile` scratch files; prepared model artifacts on disk. No process-persistent cache file is established.

**Testing**: Focused native test targets in `dev/native.mk` and Python tests under `dev/tests/engine/` plus `dev/tests/test_server.py`; deterministic barriers/events, held tickets, explicit resource accounting and identity assertions.

**Target Platform**: macOS local inference; power observation is macOS-only.

**Project Type**: Python HTTP server supervising a native C++/Objective-C++ inference process.

**Performance Goals**: Reject inference promptly while suspended; do not hold lifecycle coordination locks during model load, disk IO, Metal allocation, or model teardown. No numeric latency target is defined by the specification.

**Constraints**: Do not change inference semantics; preserve the native process and process-local cache backing for warm recovery; release target/draft weights and runtime arenas before reporting suspended; unknown power/identity/recovery safety stays not-ready and uses cold recovery where needed; do not create a second Python lifecycle state machine.

**Scale/Scope**: One local native runtime and its one HTTP server process; no remote or multi-engine coordination.

## Constitution Check

| Principle | Gate and plan result |
|---|---|
| I. Inference Correctness Over Optimization | **Pass**: resume uses existing cache restore semantics; every unproven case loads cold; no serving while state is uncertain. |
| II. Explicit Ownership for Concurrent Lifecycles | **Pass with design requirement**: one native admission/revision owner must serialize close against submit and retain admitted request/ticket resources until safe completion. |
| III. One Authoritative Lifecycle Owner | **Pass with design requirement**: `RuntimeBootstrap` is the sole battery lifecycle state owner; long-lived `NativeRuntime`/`FdTransport` provide the protocol/control shell and safe-point operations and publish `Engine` only while residency is valid; Python transports status and does not decide lifecycle. |
| IV. Suspension and Destructive Teardown Are Distinct | **Pass**: native child, `FdTransport`, the long-lived `NativeRuntime` control shell, and retained cache graph stay alive while `Engine` is destroyed with residency; `close()`/EOF remains shutdown and crash restart remains recovery from process failure. |
| V. Cache Reuse Requires Proven Lifetime and Compatibility | **Pass with proof gate**: use same-process cache/backing only, materialize eligible state before model teardown, compare current identity and exact `CompositeStateLayout`; unknown means cold. |
| VI. Newer Lifecycle Intent Takes Precedence | **Pass with design requirement**: monotonic desired-intent revision gates suspend completion and candidate publication. |
| VII. Model-Less Control Plane Is Truthful | **Pass with protocol/status work**: control readiness is distinct from inference readiness; existing static frontend metadata remains detached; model-derived fields are unavailable without a resident runtime. |
| VIII. Observability Is Passive and Correctly Attributed | **Pass**: retain existing status/metrics surfaces and publish detached snapshots; do not assign runtime metrics to a request or trigger restoration during reads. |
| IX. Preserve Proven Architecture | **Pass**: extend native bootstrap/engine resource ownership and existing status/protocol; no copied EngineHolder framework or general platform abstraction. |
| X. Concurrency Claims Require Deterministic Evidence | **Pass**: deterministic event/ticket/barrier seams, not elapsed-time sleeps, prove races and drain order. |
| XI. Resource Release Must Be Real | **Pass with proof requirement**: report suspended only after package/runtime destruction and memory/resource accounting confirm release; audit callbacks and snapshots for stale strong references. |
| XII. Evidence Before Architecture | **Pass**: decisions and limitations are grounded in the live checkout in [research.md](research.md). |

No justified constitution exception is proposed. Required follow-up proof items are listed as planning uncertainties in [research.md](research.md); they do not justify claiming readiness or warm compatibility before verified.

## Current Ownership and Chosen Lifecycle Owner

The verified chain is:

```text
server/server.py
  -> server/runtime.py: MultiplexedRuntime (child process, generations, wire admission)
  -> runtime/main.mm + FdTransport (single native input/control/tick loop)
  -> RuntimeBootstrap (owns lifecycle intent/state/revision, RuntimeResources, RuntimeModel, NativeRuntime)
  -> NativeRuntime (long-lived protocol/control/status shell; publishes a live Engine only with residency)
  -> Engine [exists only while residency is valid]
       (request map, Scheduler, one pending ModelBatchTicket; borrows Cache and a non-nullable model::Model)
  -> Cache (KV graph/pool leases and StateCache)
  -> RuntimeModel / StateStorage / Metal backend and model weights
  -> CompositeState and KV pages; optional SlotFile-backed state/KV copies
```

**Authority decision**: `RuntimeBootstrap` becomes the single authoritative battery lifecycle owner. It is the narrowest existing aggregate that owns the full resource graph that must be split and can coordinate it with `NativeRuntime` safe points (and `Engine`'s, while an `Engine` exists). The native transport loop already serializes frame handling, ticking, and command-free control work. Requests must consult this authority at their final native admission boundary; Python `can_submit()` remains an early response optimization only. Engine scheduler phases remain work scheduling state, not a second power lifecycle state machine. The observer only supplies observations. `MultiplexedRuntime` continues to own process generations, crash fencing, protocol IO, and terminal shutdown.

**Engine lifetime decision**: `Engine` is not part of the long-lived control shell. Today `NativeRuntime` holds `engine::Engine core_` by value and its constructor takes `model::Model &`, so `Engine` currently lives exactly as long as `NativeRuntime` (`runtime/engine/NativeRuntime.hpp`, `NativeRuntime.cpp`). The plan keeps `NativeRuntime` long-lived and makes the `Engine` it publishes exist only while the `Cache` and `model::Model` it borrows are valid. `Engine`'s `model::Model` reference stays a non-nullable reference bound at `Engine` construction; it is never made nullable, optional, or rebindable. Suspension therefore detaches/destroys `Engine` (and `NativeRuntime` inference methods reject with explicit unavailable/not-ready behavior while no `Engine` is published) while `NativeRuntime` protocol, status, and control paths stay operational. `FdTransport` continues to run `NativeRuntime`.

`NativeRuntime` currently owns an `Engine` with references to `Cache` and `Model`; `RuntimeBootstrap` owns all three resource strata, but does not yet mediate request admission. The implementation must route the request gate through the bootstrap authority or an equivalent narrow delegation so there is one state owner. Do not put a second battery state machine in `NativeBackend` or `MultiplexedRuntime`.

**Two readiness concepts**: the native process has two independent readiness notions. **Control readiness** is a one-shot handshake per native process generation — semantically "control readiness", concretely the existing wire `ReadyEvent`, reused and redefined for that meaning (no new frame unless implementation evidence forces a protocol version change) — that means the generation is alive and protocol/control/status traffic is usable. **Inference readiness** is a dynamic lifecycle flag owned by `RuntimeBootstrap` and exposed through detached status; it toggles repeatedly within one generation and never creates a new generation. See [the readiness contract](contracts/control-readiness-and-lifecycle-status.md).

### Resource ownership strata

The plan distinguishes two semantic strata everywhere ownership is discussed:

**Retainable / base** (survives a normal ready -> suspended transition):

- backend and accounting required by retained state
- `Cache` / `StateCache`
- KV pool/backing/tier
- `StateStorage` required by retained `CompositeState`
- `SlotFile` workers/backings
- detached `ModelDescriptor`/configuration and cache identity
- detached status/resource snapshots

**Residency** (destroyed at suspension, rebuilt only inside a recovery candidate):

- `ModelPackage` target/draft/vision weights
- `model::RuntimeModel`
- execution arenas/continuations
- `Engine`
- model-derived callbacks/factories that retain residency

After a normal ready -> suspended transition only the retainable graph needed for warm reuse remains. On cold startup on battery, even that graph need not exist until the first AC load, because no reusable warm state exists yet.

## Lifecycle State and Intent Ownership

The authoritative state is stored with `RuntimeBootstrap` and exposed as detached status data:

| State | Inference admission | Meaning |
|---|---:|---|
| `ready` | open | A usable `ModelPackage`/`RuntimeModel`/`Engine` is published and current intent allows service. |
| `draining` | closed | New native requests are refused; requests admitted before closure retain resources and drain to normal completion/cancellation. |
| `suspended` | closed | Target/draft weights, `RuntimeModel`, and `Engine` are destroyed; control plane and retained base/cache resources remain, with no `Engine` published. |
| `recovering` | closed | A private candidate (`ModelPackage`, `RuntimeModel`, `Engine`) is being loaded and optionally restored; no candidate is visible to requests. |
| `recovery_failed` | closed | Latest attempt failed; retained retryable cache survives and a later AC observation may retry. |
| `shutdown` | closed | Ordinary EOF/signal shutdown supersedes automatic transitions; no readiness/suspension success is emitted for incomplete work. |

Keep a monotonic intent revision and current observed power intent (`AC`, `battery`, or `unknown`). Repeated equal observations are no-ops. Every async drain, release, load, and candidate publication captures a revision and rechecks it at each publication/destructive boundary. Newer battery intent prevents an old candidate from opening admission; newer AC intent cancels the effect of an old battery completion and triggers recovery after current safe work reaches a publication point. Unknown power fails closed to no new model publication until a definite observation; it never authorizes resume.

Transition ownership: `runtime/main.mm` samples/registers power and posts observations into the native safe-point loop; `RuntimeBootstrap` updates revision/state and performs all transitions. `NativeRuntime` consults the bootstrap gate when handling request frames. Lifecycle state/diagnostics are returned from cached bootstrap status, not inferred from process-running or Engine `ready_` alone.

### Control readiness vs inference readiness

| | Control readiness | Inference readiness |
|---|---|---|
| Owner | Native startup handshake inside the `NativeRuntime`/`RuntimeBootstrap` startup path | `RuntimeBootstrap` lifecycle state |
| Concrete seam | The existing one-shot wire `ReadyEvent`, reused for this meaning | Detached lifecycle/status field, read on demand via status request/response |
| Meaning | Generation alive; protocol/control/status usable; `MultiplexedRuntime` startup for this generation completed | A usable `Engine`/model is published and current intent authorizes serving |
| Toggles | No; once true it stays true while the child is healthy | Yes: `false -> true -> false -> true ...` inside one generation |
| On change | Starts or completes a startup attempt | Never creates, restarts, or invalidates a generation |

The existing wire `ReadyEvent` already satisfies every structural requirement of control readiness: it is the required first native event, it is one-shot per generation, it completes `MultiplexedRuntime`'s startup attempt, it is what `_ready_message`/`runtime.ready` use for generation readiness, and it can carry the static capability tuple Python needs. The minimum-change design therefore **reuses and redefines that frame** for control readiness rather than adding a new one; a new frame or protocol version bump is only justified if implementation evidence forces it. Its semantics change from "fully warmed inference is ready" to: native generation alive; protocol/control/status traffic usable; startup attempt complete; suppress ordinary startup timeout/relaunch for an intentionally model-less child; the process must not be replaced merely because inference is unavailable; and it carries the detached/static capability and configuration values needed to build the HTTP/frontend control plane without resident model weights.

The `ReadyEvent` capability payload must contain only values valid before model residency is established: the configured/descriptor context ceiling (not the later memory-plan-resolved effective context), static concurrency capability, feature bits/vision capability derivable from descriptor or configuration, and engine/generation identity as currently applicable. The memory-plan-resolved effective context is lifecycle/status data published before `inference_ready` opens.

There is exactly **one** readiness handshake per generation. There is no second model-ready/`ReadyEvent` later in the same generation, and no separate optional "model `ReadyEvent`". Dynamic inference readiness exists only as lifecycle/status `inference_ready=false` / `inference_ready=true`, which may toggle repeatedly inside the generation.

Python side of the split, planned consistently:

- `MultiplexedRuntime` generation liveness/startup uses **control readiness plus actual process health** (`process.poll()`); `wait_ready()` and `_require_generation_ready_locked()` gate on that, not on inference readiness. `runtime.ready` and `_ready_message` are therefore process/control-readiness semantics, and `runtime.readiness` remains the one-shot static capability/configuration handshake.
- `NativeBackend.can_submit()` uses **lifecycle inference readiness**; `NativeBackend.is_ready()` uses **lifecycle inference readiness** (plus its existing memory-pressure verdict); HTTP `/ready` uses **lifecycle inference readiness**. None of these may interpret `runtime.ready` as inference readiness.
- Lifecycle `inference_ready` is **not an unsolicited push**. `StatusJsonEvent` is request/response, so Python obtains it from detached native status through the existing bounded status-refresh mechanism: a cached false/stale snapshot must never leave Python permanently closed after a successful native AC recovery, and `can_submit()`/`is_ready()`/HTTP readiness must have a bounded refresh path that discovers the current lifecycle state. Refresh while model-less is passive and never starts or replaces the process or restores inference. Polling on every request is not required, and no new unsolicited lifecycle event is added unless implementation evidence shows the existing bounded refresh cannot satisfy this contract.
- A stale `true` value is never authoritative for correctness: the final native admission gate still rejects after battery closure, so no correctness claim depends on Python winning an admission race.
- Status inspection while intentionally model-less never starts or restarts the model and never replaces the native child.
- EOF/process exit/protocol failure still causes normal generation fencing and restart.
- A restarted child has lost process-local warm state and therefore recovers cold; `inference_ready=false` alone never means the generation is stale.

## Admission and Drain Boundary

The native boundary is `NativeRuntime::handleRequest()` immediately before `Engine::submit()`. Python `FrontendHandler` checks `backend.can_submit()` before request parsing/queueing (`server/server.py`), while `NativeBackend.submit()` calls `MultiplexedRuntime.submit()` and writes a request frame; these earlier checks are separated from final native admission and cannot prove close-vs-submit correctness.

Battery closure and native request admission must serialize through the single native event loop and bootstrap-owned gate. A frame handled before closure is inserted into Engine and is admitted work; its cache/lane/model resources remain owned until its ordinary terminal event and any `ModelBatchTicket` is complete. A frame handled after closure receives a prompt existing request-scoped unavailable/not-ready error. No new scheduler work can be accepted after closure. Work in `Engine`'s resource-wait/suspended states is already represented as an admitted request and is not silently discarded; it must reach its normal completion/cancellation boundary before model teardown. Existing per-request `Runtime::suspend()` is memory-pressure preemption that replays request history, not whole-machine suspension, and must not be reused as destructive battery teardown.

The drain waits for `Engine::idle()` and no command ticket/Metal command in flight; completion is driven by `FdTransport` wakeups and normal native ticks. Do not use fixed sleeps. Keep locks/coordination sections short; no model load, offload wait, Metal release, or disk operation while holding the lifecycle state lock.

T022 realizes this drain as a **pumpable RuntimeBootstrap transition** advanced at native-loop safe points rather than as a synchronous blocking loop. Before destructive release, both Engine/request drain and retained `Cache::transfersInFlight()` quiescence must hold; while either is pending, the live Engine continues to tick so queued transfer work can be submitted and retired. Revision is rechecked immediately before the first destructive step, and expensive drain/destruction work never runs while holding the lifecycle/admission mutex.

While no `Engine` is published (model-less startup or after suspension), `NativeRuntime` request handling refuses inference with an explicit request-scoped unavailable/not-ready error. It does not use warmup wording that implies a warmup is in progress or invites indefinite retry, and it does not attempt to reach a nonexistent `Engine`. Protocol, status, and control paths remain operational in that state.

### Suspend order

The ordered steps from an authorized battery intent to a published `suspended` result are:

1. close final native inference admission;
2. drain all admitted requests and command/model tickets;
3. complete/quiesce retained cache/state IO;
4. detach/destroy `Engine`;
5. destroy `RuntimeModel` and execution arenas;
6. destroy/release weight-bearing `ModelPackage` residency and model-derived factories/callbacks;
7. prove intended model/runtime residency release;
8. publish `suspended` success.

`Engine` is destroyed before `RuntimeModel` and before `ModelPackage`, and `Engine`'s `model::Model` reference is never nullable or rebindable, so a dangling `Engine` reference to released model residency is structurally impossible.

## Resource Split and Warm-State Handoff

### Retain across battery suspension

Keep the native process, `FdTransport`, long-lived `NativeRuntime` control shell, and the **retainable/base** stratum alive: cache identity, `Cache`/`StateCache`, KV page/pool and KV-tier objects, `SlotFile` workers/backings, `StateStorage` layout/pools needed to restore retained composites, the `MemoryGovernor`/backend accounting, and detached `ModelDescriptor`/status snapshots. This is required because current RAM state and Metal KV pages are device/backend-bound, and the disk tier is process-local. This deliberately bounds the battery claim to releasing the **residency** stratum — `Engine`, `model::RuntimeModel`, target/draft model weights, and the model execution runtime/arenas; retained cache memory is measured and reported rather than described as released. No readiness or status operation destroys, evicts, or unpins this retainable backing as a side effect.

When the retained/base graph survives but `RuntimeModel`/`Engine` do not, production status routes through the existing detached `ResourceSnapshot` serializer. Presence of retained `RuntimeResources` is not evidence of inference residency. The detached snapshot is composed by `RuntimeBootstrap` from current retained backend/cache/KV/state observations and must report `model_resident=false` and `inference_ready=false`; the old immutable warmup report cannot make a suspended model-less process appear inference-ready.

### Cold startup on battery

Do not create expensive inference resources merely to suspend them. When the initial power observation is battery and no reusable state exists, the process may initially contain only:

- `RuntimeBootstrap` lifecycle/config state;
- detached `ModelDescriptor`/configuration;
- long-lived `NativeRuntime` control shell;
- `FdTransport`/control/status infrastructure.

No `Cache`/`StateStorage`/backend warm graph is required before the first AC load when no reusable state exists yet; that graph is created as part of the first load/recovery rather than pre-built for a suspension that has nothing to preserve.

### Release at the suspension boundary

Refactor `RuntimeResources`/`RuntimeBootstrap` ownership so the weight-bearing `ModelPackage` is a separable residency object from detached `ModelDescriptor`, compatibility identity, cache, backend, and state backing. Destroy the `Engine` first, then the candidate/live `model::RuntimeModel` (target/draft wrappers, execution continuations, vision runtime and runtime arenas), and then destroy/move out target/draft/vision weight buffers. Release idle model state lanes and model-derived factories/callbacks that are not needed by retained `StateStorage`. Keep only immutable configuration and detached report data model-less. `RuntimeResources` presently owns `ModelPackage` and `RuntimeModel` references all of the base resources and `NativeRuntime` presently constructs `Engine` with a `model::Model&` in its constructor, so both splits are necessary; neither is an existing unload operation.

Before releasing model residency, finalize every request and preserve at least one eligible immutable composite cache state. Prefer the existing `StateCache`/`QwenCompositeState` disk offload when the file tier is enabled; await its deterministic completion. If the disk tier is disabled or refuses capacity, a bounded RAM `CompositeState` may remain only if its state-pool and Metal/backend ownership are deliberately retained and accounted as cache residency. If no safe retained representation can be proven for an attempt, invalidate unsafe entries and use cold recovery. Keep `StateStorage`, same backend and `Cache` alive to read/restore retained state. Disk copies do not survive destruction of their `SlotFile` owner or a child restart.

### Recovery candidate publication

Build the candidate privately: the required resource graph (when it does not already exist) plus `ModelPackage`, `RuntimeModel`, and `Engine`. Candidate construction is private until package identity, saved descriptor, KV layout, exact `CompositeStateLayout`, and state lengths all validate. Rebind preserved data by restoring the immutable retained `CompositeState` into newly activated target/draft lane buffers with existing `QwenStateStorage::beginRestore`/`restore`; retain the same KV cache graph/backend for matching prefix pages. Recreate model-derived factories/callbacks from the candidate package and never reuse closures that captured the old runtime. Only a successful state restore can count as warm. Existing `Cache` promotion is after successful restore; preserve that transactional order. A failure keeps source state/slots intact and retryable.

**Warm-resume latency contract**: distinguish model/runtime reconstruction from replay of the user's retained context. A compatible same-process warm recovery may reload the model residency and perform any bounded model-only/kernel preparation required for correctness, but it must not recompute the preserved matching prompt/KV/GDN/draft prefix as a cold prefill. Restore/rebind the retained prefix before publication so the first matching request after recovery resumes from the retained boundary. Cold fallback may pay the full prefill cost. Prove this with prefix-boundary/work counters rather than a wall-clock threshold alone.

Before transactional recovery relies on `StateRestore`, harden the concrete Qwen `FileRestore` so successful `finish()` commits at most once and a cancelled restore can never commit later, including the case where IO completed before cancellation. Recovery tests must additionally drive a real failed restore through Engine/candidate cleanup and prove the destination is not promoted while the immutable retained source remains retryable.


Do not publish the candidate's `Engine` or open admission until **all** of the following hold: warm compatibility/restore has succeeded or cold recovery has succeeded; the runtime is usable; the captured lifecycle revision is still current; and the latest power intent authorizes serving. Publishing means attaching the candidate `Engine` to the long-lived `NativeRuntime` and setting `inference_ready=true`. A stale candidate is destroyed without damaging retained retryable state. For missing, corrupt, mismatched, unknown, or failed warm state, construct a cold candidate; warm failure alone must not prevent usable cold recovery.

## Compatibility and Process Lifetime

Existing `RuntimeCacheIdentity` includes combined target/draft/vision loaded model manifest fingerprint, `buildId`, target artifact digest, KV storage format/page/quantization/layout geometry, and a SHA-256 namespace. `buildId` is a digest over all runtime C/C++/Objective-C++/Metal sources and build-identity tooling. `QwenCompositeState` stores `CompositeStateLayout` and `QwenStateStorage::restore` requires exact layout equality. Retained state stays in the same `Cache` instance, so it cannot accidentally attach to another cache namespace.

For each recovery, recompute identity from loaded candidate weights and compare it to the saved immutable identity; also compare retained descriptor and the exact state layout. These existing checks jointly prove target/draft/model/build/KV/state geometry for same-process recovery. Unknown equality fails to cold. Do not add a second identity tuple unless an implementation audit shows an unrepresented dimension. State payload version/corruption handling and explicit state-format identity still need the focused code audit recorded in [research.md](research.md); if current `CompositeStateLayout` validation does not cover serialized payload semantics, add only that missing version/dimension.

Choose **keep native child alive and retain the base resource/cache graph**. `SlotFile` uses `mkstemp`, immediately unlinks its path, marks the fd close-on-exec, and closes it with shared backing destruction. The state and KV cache tiers are scratch storage owned through process-local `SlotFile`/worker objects. Slot handles alone do not preserve worker/service lifetime. Restarting the native child destroys these owners and therefore discards RAM and disk-tier reuse; it cannot be treated as warm suspension.

## Python/Native Protocol and Startup

The current Python/C++ protocol has request/cancel/mask/status request frames and one-shot `ReadyEvent`; there is no lifecycle command or battery status. Because both the power observer and sole lifecycle owner are native, power intent does not cross the Python/native boundary and does not need a second command-driven state machine.

Reuse the existing model-independent one-shot **`ReadyEvent`** as the control-readiness handshake, emitted once per native process generation while model-less or model-resident. It is a handshake, not a lifecycle signal:

- it means the native process generation is alive, protocol/control/status traffic is usable, and `MultiplexedRuntime` startup for this generation has completed;
- it completes the startup attempt and suppresses ordinary startup timeout/relaunch for an intentionally model-less child;
- it carries or exposes the detached/static capability information needed to build the HTTP/frontend control plane without resident model weights (model names, configured/descriptor context ceiling, concurrency, feature bits, vision/config metadata where derivable without weights);
- it does **not** make inference ready and does **not** repeat.

Planning prose may call this semantic concept "control readiness"; the concrete minimum protocol implementation is the existing `ReadyEvent` frame, redefined in meaning rather than replaced. Do not add a new wire frame merely to rename the concept, and do not leave an open "new `ControlReadyEvent` vs old `ReadyEvent`" protocol fork — unless implementation evidence forces a version change, the existing frame is the design.

Inference readiness is **not** carried by any readiness event. There is exactly one readiness handshake per generation: no second `ReadyEvent` later in the same generation, and no separate optional "model `ReadyEvent`". It is exposed as a detached lifecycle/status field owned by `RuntimeBootstrap` and may flip `false -> true -> false -> true` within one generation without emitting any further event.

Python semantics to plan together:

- `MultiplexedRuntime` treats intentional model-less control readiness as a live generation and suppresses ordinary crash relaunch only when the native child is actually alive; real child failure retains existing generation fencing and restart policy. Control-ready/inference-unavailable never raises a new generation.
- `wait_ready()`/`_require_generation_ready_locked()` gate on control readiness plus process health; request write admission there is generation liveness, not inference permission. `runtime.ready` and `_ready_message` carry control-readiness semantics; `runtime.readiness` remains the one-shot static capability/configuration handshake.
- `NativeBackend.can_submit()` and `NativeBackend.is_ready()` gate on lifecycle inference readiness from the detached status snapshot, so a model-less-but-healthy child reports not-submittable rather than crashed. They must never interpret `runtime.ready` as inference readiness.
- Lifecycle `inference_ready` is status-based, not pushed: `StatusJsonEvent` is request/response. `can_submit()`/`is_ready()`/HTTP readiness must have a bounded status-refresh path that discovers the current lifecycle state, so a cached false or stale snapshot never leaves Python permanently closed after a successful native AC recovery. Refresh is passive while model-less: it never starts or replaces the process and never restores inference. Polling on every request is not mandated, and no unsolicited lifecycle event is added unless implementation evidence shows the existing bounded refresh cannot satisfy the contract.
- A stale `true` snapshot is never authoritative for correctness: the final native admission gate still rejects after battery closure, so no correctness claim depends on Python winning an admission race.
- Status inspection, `/status`, `/metrics`, and `/ready` reads never start a child, load a model, trigger warm restore, or replace the native child.
- EOF/`close()`/protocol failure remains shutdown or ordinary crash recovery; a restarted child has lost process-local warm state and recovers cold.
- Keep static capability metadata (from the `ReadyEvent` handshake/startup configuration) separate from current inference readiness.

`server/server.py:main()` currently binds an inactive HTTP socket, loads tokenizer/templates, launches the child lazily, blocks in `wait_ready()`, builds `Frontend`, and only then activates HTTP. With battery enabled and battery observed, launch returns control-ready without `RuntimeResources` weight loading and without a pre-built warm graph, then the server builds `Frontend` from launch/config metadata (model names, configured context ceiling, tokenizer, vision/config capability metadata) and activates HTTP. The control plane is created from the single control-readiness `ReadyEvent` plus detached configuration; no later model-readiness event exists to wait for. On AC startup normal load/recovery proceeds; the listener is available while inference status is recovering. Keep HTTP `health`, `/status`, `/metrics`, and `/ready` independent of triggering model load. A suspended inference submission is an explicit 503/unavailable response.

The observer is a thin native IOKit seam: take a synchronous initial AC/battery snapshot before model bootstrap, then watch live power-source changes and wake the existing FdTransport control handler. Repeated events merely publish observations; `RuntimeBootstrap` owns lifecycle policy. `Makefile` already links `-framework IOKit`; `runtime/metal/MetalBackend.mm` uses IOKit for GPU discovery only. Define explicit unknown/error behavior as fail-closed. The exact IOPowerSources API setup and run-loop bridging require implementation verification; do not expand into a generic power framework.

### Capabilities and context

Detached `ModelDescriptor`/configuration available before weight loading supplies static model/control-plane metadata wherever possible; keep that static capability metadata separate from current inference readiness. Automatic effective max-context is resolved only after later memory planning (today `RuntimeBootstrap::start` derives `config.nativeLoop.engine.maxContext` from `resources->memoryPlan().maximumContextTokens()`), so it is not knowable at battery startup. Plan this policy:

- while model-less, expose the configured/descriptor context ceiling as detached configuration and use it to build the control plane;
- recovery computes the actual effective serving context during its memory planning;
- publish/update that effective value in detached lifecycle/status **before** `inference_ready` becomes true;
- admission uses the currently resolved value, not the startup-time ceiling;
- later recoveries may update it again before reopening admission;
- an inconsistent or unsafe resolved value fails closed (stay not-ready), never open;
- context drift does not by itself require process restart and is never treated as a stale generation.

## Model-Less Control Plane

Existing surfaces are sufficient: `/health` is HTTP-process health; `/ready` is lifecycle inference readiness; `/status` and `/metrics` are the detailed snapshot. Preserve status schema evolution conventions and add `control_ready`, `inference_ready`, `lifecycle.state`, `lifecycle.power`, `lifecycle.revision`, `model_resident`, the effective/resolved context when known, and `last_error`, per [the readiness contract](contracts/control-readiness-and-lifecycle-status.md). Keep static served model metadata from `Frontend` detached from `ModelPackage`; dynamic native values are either detached snapshots or unavailable. Backend status currently copies a detached snapshot but can ask `runtime.status()` and its process recovery path; it must not start or restore inference when suspended. Lifecycle `inference_ready` is discovered through the existing status request/response surface with a bounded refresh: `can_submit()`, `is_ready()`, and HTTP readiness must not sit indefinitely on a stale false snapshot after a successful native AC recovery, and a stale true snapshot is never authoritative because the native gate still rejects. Do not report stale `ready=true`. No new metric family or UI is planned.

Model-less status is independent of `Engine`: it must be servable while no `Engine` exists, from bootstrap-owned detached state and the retainable graph, rather than from `Engine`'s snapshot/telemetry path. `control_ready` remains true during `draining`, `suspended`, `recovering`, and `recovery_failed` while the child itself is healthy. Model-derived runtime telemetry (batch/scheduler/model telemetry) is unavailable when residency is absent, never stale-as-live.

Do not infer battery lifecycle state from existing Scheduler/memory-pressure terminology. Existing status already carries `admission.suspended` (resource-wait) and `admission.draining` (Engine drain), and Python already reports `transport.recovering`; none of these is the battery lifecycle state and none may be reused as it. Likewise, suspended inference refusal is explicit unavailable/not-ready behavior, not warmup wording that encourages indefinite retry.

Startup/banner logs use `Starting control plane`, `Suspended · battery`, `Draining · battery`, `Recovering · AC`, `Ready`, `Recovery failed`, and `Stopping` according to owner state; never emit `Ready` for merely process-ready/control-ready. Diagnostics/status callbacks must capture values, not `RuntimeModel`, `ModelPackage`, `Engine`, or factories.

## Failure, Retry, Supersession, and Shutdown

| Race/failure | Required outcome |
|---|---|
| AC → battery idle | Close gate at owner; destroy `Engine`, then `RuntimeModel`, then weight-bearing `ModelPackage`; suspended only after release proof. |
| AC → battery with admitted work | Gate closes before any following request; admitted work/tickets finish normally; then release. |
| AC → battery → AC during drain | Latest AC revision wins; after drain retain/build candidate and return ready if valid; stale suspend cannot publish suspended. |
| Battery → AC → battery during recovery | Latest battery revision wins; candidate cannot publish/open admission; dispose candidate and finish suspended release. |
| Duplicate observation | Revision/state unchanged; no duplicate teardown/load. |
| Candidate load, warm validation, or restore fails | Keep gate closed; keep source warm data unchanged; report recovery-failed; attempt cold recovery for warm-only failure; later AC attempt can retry. |
| Cold recovery fails | Keep control plane running and gate closed; report failure and allow a later retry. |
| Battery observer uncertainty | Do not admit/recover until definite latest intent; report unavailable/recovering truthfully. |
| Startup on battery | Emit the one-shot `ReadyEvent` control-readiness handshake and publish lifecycle `control_ready=true`, `inference_ready=false`, `model_resident=false` in the existing generation; build no residency. |
| AC recovery succeeds in the same generation | Publish candidate `Engine`, set `inference_ready=true`; no new generation and no second `ReadyEvent`. |
| Battery after a successful recovery | Set `inference_ready=false` in the same generation while `control_ready` stays true and the retainable graph survives. |
| Status/`/ready`/`/status`/`/metrics` inspection while model-less or suspended | Return detached lifecycle/status only; never start a child, load a model, restore state, or replace the generation. |
| Shutdown while draining/suspended/recovering | Shutdown intent wins; stop observer, cancel unstarted candidate work, complete normal child teardown; never claim ready/suspended for incomplete transition. |
| Native process crash | Existing Python generation fencing and crash restart remain ordinary crash recovery; process-local cache is lost and new child recovers cold. |

No administrative runtime lifecycle API currently exists. Revision ownership is shaped so a future explicit action could supersede automatic intent, but this feature adds no such API.

## Resource-Release Proof

Suspended publication requires both (1) strong ownership proof that `ModelPackage`, `RuntimeModel`, `Engine`, model factories, queued closures, status providers, and warmup captures no longer retain target/draft weights or runtime arenas; and (2) before/after native memory evidence from existing `MetalBackend::memoryStats()`, `ModelMemoryActual`/`actualRuntimeMemory()`, `MemoryGovernor::snapshot()`, and state/cache snapshots. New detached resource counters or weak-lifetime test probes may be added only where existing snapshots cannot distinguish freed package/runtime allocations from retained cache/KV/backend allocations. Test actual object destruction and bytes reclaimed, not just a lifecycle enum. Status/report snapshots are value copies.

### Implementation proof gates

These are open obligations. None may be reported as already proven, and no artifact may claim readiness or warm compatibility ahead of them:

1. Destroying `Engine` -> `RuntimeModel` -> `ModelPackage` actually releases the intended target/draft/vision residency while retained state remains valid.
2. At least one eligible `CompositeState` + matching KV prefix survives suspension and later restores warm.
3. Disk state corruption/truncation is detectably invalid; add only the minimum payload version/checksum if existing protection is insufficient.
4. `Engine`/request/ticket drain plus `SlotFile`/cache IO quiescence leaves no operation touching released model/lane resources.
5. A failed recovery candidate leaves retained source state retryable and permits correct cold fallback.
6. Python control-ready/generation semantics are deterministically proven for: battery startup -> control ready, inference unavailable; AC -> recovery in the same generation; battery -> suspension in the same generation; AC -> recovery again in the same generation; suspended status inspection -> no process/model restart; actual child failure -> new generation and cold recovery. Freshness must also be proven: native AC recovery succeeds -> Python discovers `inference_ready=true` without process restart and without requiring a user to manually query `/status` first; and native battery gate closes -> a stale Python `true` can never cause actual native admission after the close boundary.


### Early vertical-slice milestones

These milestones intentionally provide something runnable before the entire feature is integrated. They are **diagnostic/validation milestones, not acceptance gates**, and they do not remove any later obligation.

- **S1 after T023 — manual suspend slice**: one live native generation can be driven manually through ready -> battery intent -> draining -> objective model residency release -> suspended, with control/status still live and exactly one process-generation `ReadyEvent`. The IOKit observer and Python automation may still be absent.
- **S2 after T026 — manual recovery slice**: the same native generation can be driven manually through ready -> suspended -> recovery -> ready, proving compatible warm restore when available and correct cold fallback otherwise. Python effective-context adoption and real power-source automation may still be absent. For the warm case, record recovery phases separately and verify the first matching request consumes the retained prefix instead of repeating the long-session prefill.
- After S1/S2, continue the normal task graph through T027–T032. Do not convert a successful manual demo into a claim that observer races, Python freshness, cold battery startup, repeated cycles, process-failure fencing, or final cross-language readiness are complete.

Known proof/hardening debt is deliberately pinned to later work rather than waived for speed: T023 isolates the dual drain/transfer barrier; T024 makes FileRestore commit-once and cancel-safe; T025 proves real failed-restore cleanup and retryability through the recovery path; T030 closes the real-stack asynchronous offload-failure proof; T032 checks that no item in this ledger was silently skipped.

## Focused Verification Strategy

Do not use the full repository suite as the normal implementation gate. Add deterministic tests at the changed boundaries:

| Boundary | Focused existing seam / test file | Proof |
|---|---|---|
| Admission, queued/active drain, ticket lifetime, stale native intent | `dev/tests/engine/native_engine_loop_test.cpp`; likely a focused lifecycle-owner native test | Barrier-controlled request close/admit and held `ModelBatchTicket`; verify all admitted work completes before `Engine` destruction and stale revisions cannot publish. |
| Protocol readiness/status and lifecycle status JSON | `dev/tests/engine/protocol_test.cpp`, `dev/tests/engine/runtime_status_test.cpp`, `dev/tests/engine/test_protocol_python.py` | Exactly one `ReadyEvent` per generation (reused for control readiness) vs repeatedly readable lifecycle `inference_ready`; semantic state round trip; model-less status without `Engine`; explicit unavailable result (no warmup wording). |
| Runtime resources split, weight/runtime destruction, warm candidate integrity | `dev/tests/engine/runtime_resources_test.mm`, `dev/tests/engine/runtime_bootstrap_test.mm`, `dev/tests/engine/slot_file_test.cpp`, `dev/tests/engine/kv_page_tier_test.mm` | Actual allocated-byte/resource release across `Engine` -> `RuntimeModel` -> `ModelPackage` while the retainable graph stays valid; retained unlinked file usability while process owner lives; candidate fail preserves source. |
| Python restart fencing, no implicit restart on intentional suspend, status/readiness | `dev/tests/engine/test_server_recovery.py`, `dev/tests/engine/test_runtime.py`, `dev/tests/engine/test_protocol_recovery.py` | Model-less control-ready is a live generation; repeated suspend/recover cycles stay in one generation with exactly one `ReadyEvent`; crash still restarts with new generation; suspended status reads do not launch model or replace the child. |
| Bounded status-refresh freshness | `dev/tests/engine/test_server_recovery.py`, `dev/tests/engine/test_runtime.py`, `dev/tests/test_server.py` | Native AC recovery makes Python discover `inference_ready=true` within the bounded refresh, with no process restart and without a user manually querying `/status` first; a closed native gate can never be bypassed by a stale Python `true`. |
| HTTP availability and explicit refusal | `dev/tests/test_server.py` | `/health`, `/status`, `/metrics` while model-less and `/ready` bound to lifecycle inference readiness; 503 inference without waiting/reload. |
| Effective context resolution | `dev/tests/engine/runtime_status_test.cpp`, `dev/tests/engine/test_server.py` | Model-less startup publishes configured/descriptor ceiling; recovery publishes effective value before `inference_ready=true`; inconsistent value fails closed; drift does not restart the child. |
| Power adapter and startup snapshot | New focused native fake-observer test (or observer test colocated with `runtime_bootstrap_test.mm`) | Initial state, duplicate notifications, unknown/error, change wake, deregistration; no real battery manipulation. |
| Warm behavior, corruption and retry | Native state/cache tests plus lifecycle-owner test | Compatible same-identity retained state is actually restored; mismatch/corruption cold-falls back; failed candidate leaves retryable source untouched. |

All race outcomes use latches, controlled tickets, fake power observations, and explicit revision/state/resource assertions. Polling or elapsed-time sleeps are not correctness evidence.

## Expected File Changes

Production files anticipated (final set depends on exact code review during implementation):

| File | Rationale |
|---|---|
| `runtime/engine/Bootstrap.hpp`, `runtime/engine/Bootstrap.mm` | Single lifecycle authority; optional model-less state; drain/release/candidate publication and intent revision. |
| `runtime/engine/RuntimeResources.hpp`, `runtime/engine/RuntimeResources.mm` | Split immutable descriptor/cache/backing from weight-bearing package residency; detached identity and actual resource reporting. |
| `runtime/engine/NativeRuntime.hpp`, `runtime/engine/NativeRuntime.cpp` | Final request admission gate; publish/destroy the `Engine` only while residency is valid (no constructor-time `model::Model&` requirement); prompt explicit unavailable response while no `Engine`; lifecycle-independent status and safe idle/drain controls. |
| `runtime/engine/Engine.hpp`, `runtime/engine/Engine.cpp` | Keep `model::Model&` non-nullable; construction-time binding only; no rebind API. |
| `runtime/engine/FdTransport.hpp`, `runtime/engine/FdTransport.cpp`, `runtime/main.mm` | Feed observer and lifecycle work through existing safe-point wakeup; initial power snapshot; retain process on battery; shutdown observer. |
| New `runtime/engine/PowerSource.hpp` and `.mm` (or narrowly scoped source under runtime) | Thin macOS IOKit current-source/notification adapter. Add only if separation improves tests; update source/build identity via normal source discovery. |
| `runtime/engine/Protocol.hpp`, `runtime/engine/Protocol.cpp`, `server/protocol.py` | Reuse the existing one-shot `ReadyEvent` as the control-readiness handshake with pre-load static capability payload (no new frame unless implementation evidence forces a version change), plus versioned detached lifecycle status contract. No power lifecycle command and no repeated readiness event when owner/observer remain native. |
| `runtime/engine/Status.hpp`, `runtime/engine/Status.cpp`, `server/backend.py`, `server/metrics.py` | Detached model-less status independent of `Engine`; encode truthful lifecycle state, `control_ready`/`inference_ready`, `model_resident`, effective context; `can_submit()`/`is_ready()` bound to lifecycle inference readiness via the bounded status-refresh path, without accidental reload; reuse existing metric surfaces. |
| `server/runtime.py`, `server/server.py`, `server/frontend.py` | Treat control readiness separately from inference readiness in generation liveness and startup (`runtime.ready`/`_ready_message`/`runtime.readiness` = control + static capabilities), activate HTTP on control-ready, keep metadata/config available model-less, consume effective context from lifecycle status, keep crash recovery distinct. |
| `Makefile` only if adding a new Objective-C++ source requires explicit source-list entry | IOKit is already linked; no new framework expected. |

Focused tests expected: `dev/tests/engine/runtime_bootstrap_test.mm`, `runtime_resources_test.mm`, `runtime_status_test.cpp`, `native_engine_loop_test.cpp`, `protocol_test.cpp`, `dev/tests/engine/test_protocol_python.py`, `test_server_recovery.py`, `test_runtime.py`, and `dev/tests/test_server.py`; add a narrow power observer test if no current injectable seam covers it. No production or test files are to be changed during this planning stage.

## Rejected Alternatives

1. **Python `MultiplexedRuntime` owns battery lifecycle**: rejected because it owns process generations and wire admission but not native scheduler safe points, weights, Metal resources, or cache state; it would require duplicating native lifecycle state and restart would discard unlinked cache backing.
2. **Restart the native child on battery and preserve the disk tier**: rejected because `SlotFile` is an unlinked fd with process-owned worker/backing lifetime; it is not process-persistent. Restart means cold recovery.
3. **Reuse per-request `Runtime::suspend()`**: rejected because it preempts one request and replays prompt history; it is not a safe system-wide close/drain/resource release and may alter normal request progress semantics.
4. **Always cold recovery**: rejected by FR-019/SC-011. It may be used only when retained state cannot be proven safe/compatible.
5. **Keep all model resources and only set a suspended flag**: rejected because it does not satisfy real release of weights/runtime residency and stale references can retain them.
6. **A generic platform power framework or copied `EngineHolder` abstraction**: rejected because native main already has an IOKit/control wake seam and `RuntimeBootstrap` owns the real resource graph; implement only the lifecycle mechanism needed by this owner.
7. **Keep `Engine` alive across suspension with a nullable or rebindable `model::Model`**: rejected because it makes dangling or half-bound model references representable and requires every inference path to handle a null model; instead `Engine` is destroyed with residency and rebound only inside a private candidate, so `model::Model&` stays a non-nullable construction-time reference.
8. **Keep the long-lived control shell as `Engine` and only release weights underneath it**: rejected because `Engine` borrows `Cache&` and `model::Model&` and holds request/scheduler/ticket state bound to model lanes; `NativeRuntime` plus `FdTransport` already provide the long-lived protocol/status/control shell without it.
9. **Reuse the one-shot `ReadyEvent` as a repeatedly emitted inference-readiness signal**: rejected because Python treats a second `ReadyEvent` in one generation as `ProtocolFatal` and gates startup on exactly one, and because readiness tied to an event cannot express `false -> true -> false -> true` without implying a new generation. Inference readiness belongs in detached lifecycle status. Note the converse is *not* rejected: the same one-shot `ReadyEvent` **is** reused as the control-readiness handshake, which is what its current wire semantics already support; only the "repeatedly emitted" reuse is rejected.
10. **Add a new `ControlReadyEvent` frame (or a separate optional model `ReadyEvent`)**: rejected as a needless protocol fork. The existing `ReadyEvent` is already the required first event, one-shot per generation, the startup-attempt completer, and the source of `runtime.ready`/`_ready_message`/`runtime.readiness` static capabilities; redefining its meaning for control readiness is the minimum change. A new frame is justified only if implementation evidence forces a protocol version change.
11. **Push unsolicited lifecycle `inference_ready` events to Python**: not planned. `StatusJsonEvent` is request/response; the bounded status-refresh path already available to `can_submit()`/`is_ready()`/HTTP readiness must first be shown inadequate before any new unsolicited event is added.
12. **Derive battery lifecycle state from existing Scheduler/resource `suspended`/`draining` or Python `transport.recovering` fields**: rejected because those are resource-wait and transport states with unrelated meaning; reusing them would conflate memory-pressure preemption and transport restart with battery suspension.

## Project Structure

### Documentation (this feature)

```text
specs/001-battery-aware-suspension/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── contracts/
    └── control-readiness-and-lifecycle-status.md
```

`tasks.md` is intentionally not created; it belongs to the later Speckit tasks stage.

### Source Code (repository root)

```text
server/                  # Python HTTP surface and child transport
runtime/main.mm          # Native process setup, power observation, control loop
runtime/engine/          # Bootstrap, resources, Engine, NativeRuntime, protocol, status
runtime/model/           # Model package/runtime, state snapshots, KV and SlotFile backing
runtime/metal/           # Metal backend/device allocation ownership
dev/tests/engine/         # Focused native and Python protocol/lifecycle tests
dev/tests/test_server.py  # HTTP behavior tests
```

**Structure Decision**: Extend the existing Python server/native engine split. The lifecycle state stays native and is owned at `RuntimeBootstrap`; Python owns neither battery state nor model reload policy.

## Post-Design Constitution Check

All twelve principles remain satisfied by the chosen design. The central risks are explicit implementation proof obligations, not accepted exceptions: (a) residency (`Engine`, `RuntimeModel`, `ModelPackage`) can be separated and destroyed without destroying cache-owned state; (b) same-process disk cache and backend graph remains valid across suspension; (c) the single one-shot `ReadyEvent` per generation (reused as control readiness) and repeatedly readable lifecycle `inference_ready` are independent, with neither implying a generation change; (d) status and memory accounting demonstrate actual release; (e) detached model-less status is served without an `Engine`; and (f) the bounded status-refresh path discovers recovery without any unsolicited lifecycle event. A failure to prove any warm-state condition takes the cold path; a failure to prove resource release prevents `suspended` success. See [Implementation proof gates](#implementation-proof-gates).
