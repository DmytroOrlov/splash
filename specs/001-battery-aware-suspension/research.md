# Battery-Aware Suspension Research

This document records architecture decisions from the live Splash checkout on 2026-10-01. The feature spec/checklist and project constitution are inputs, not substitutes for current code evidence.

## 1. Lifecycle ownership

**Decision**: `RuntimeBootstrap` is the one native battery lifecycle authority, extended to own desired power intent/revision, serving state, resource transitions, and inference admission gate. `NativeRuntime`/`FdTransport` remain the long-lived protocol/control/status shell and consult that gate; `Engine` is residency-dependent and exists only while its `Cache` and `model::Model` dependencies are valid; `MultiplexedRuntime` remains a process supervisor.

**Verified current behavior**:

- `server/runtime.py::MultiplexedRuntime` owns the child process, startup attempts, process generation, `_pending`, and status waiters (`server/runtime.py`, `MultiplexedRuntime.__init__`, `submit`, `_launch_startup_attempt`, `_require_generation_ready_locked`). Its `close()` is terminal and tears down the process; `_ensure_process()` relaunches on failure.
- Native process main constructs `RuntimeBootstrap`, then gives its `NativeRuntime` to `FdTransport::run` (`runtime/main.mm::runNative`; `runtime/engine/FdTransport.cpp::run`). The native loop serializes complete input frames, control callbacks, `tick()`, and poll wakeups.
- `NativeRuntime` holds `engine::Engine core_` **by value** and is constructed with `engine::Cache &` and `model::Model &`, passing both into `Engine`'s constructor in its member-init list (`runtime/engine/NativeRuntime.hpp`; `NativeRuntime.cpp::NativeRuntime`). Today `Engine`'s lifetime is therefore identical to `NativeRuntime`'s.
- `Engine` owns the request map, `Scheduler`, pending `ModelBatchTicket`, and `idle()` view, but borrows `Cache &cache` and `model::Model &model`, stored as `model::Model &model_` (`runtime/engine/Engine.hpp:80`, `:289`). The model reference is a non-nullable reference, not a pointer or optional.
- `RuntimeBootstrap` owns `RuntimeResources`, `RuntimeModel`, and `NativeRuntime` as three `unique_ptr` members; its documented reverse destruction order is loop → model → resources (`runtime/engine/Bootstrap.hpp`). Startup creates resources, runtime and loop before real warmup/Ready (`runtime/engine/Bootstrap.mm::start`).

**Rationale**: `Engine` is narrower for scheduling but cannot replace/destroy the resources it borrows. Python's supervisor is outside the safe point and cannot own the cache/model resources. `RuntimeBootstrap` is the smallest existing aggregate that spans the whole ownership chain. Request gate checks must delegate to this one owner; scheduler phases are not another battery state machine.

**Required change**: Native request handling must ask the bootstrap-owned gate immediately before `Engine::submit()`. The current `NativeRuntime` has no back-reference to bootstrap, so route admission through a narrow callback/delegation owned by bootstrap. Do not store independent lifecycle truth in Python or `NativeRuntime`.

**Required change (Engine residency)**: because `core_` is a value member and `NativeRuntime`'s constructor demands a `model::Model &`, the existing shape cannot express a model-less child. `NativeRuntime` must stay constructible and long-lived without a model, and must publish/attach an `Engine` only while residency is valid, destroying it at suspension and attaching a freshly built candidate `Engine` on recovery. Do **not** satisfy this by making `Engine::model_` nullable or rebindable — that would make dangling or half-bound model references representable. `FdTransport` keeps running `NativeRuntime` across every transition.

**Required change (two readiness concepts)**: process/control readiness and inference readiness are distinct and must not share one signal.

- **Control readiness**: a one-shot handshake per native process generation, concretely the **existing wire `ReadyEvent` redefined for this meaning** (no new frame unless implementation evidence forces a protocol version change). It means the generation is alive, protocol/control/status traffic is usable, and `MultiplexedRuntime` startup for this generation completed; it suppresses ordinary startup timeout/relaunch for an intentionally model-less child and carries detached/static capability information for the HTTP/frontend control plane. Once emitted, it stays true while the child is healthy — including during `draining`, `suspended`, `recovering`, and `recovery_failed`.
- **Inference readiness**: a dynamic lifecycle flag owned by `RuntimeBootstrap`, exposed through detached lifecycle status and read on demand through the existing status request/response surface (not an unsolicited push). It may transition `false -> true -> false -> true` within one generation (battery startup, AC recovery, battery suspension, later AC recovery) and never creates, restarts, or invalidates a generation. `NativeBackend` discovers it through a bounded status-refresh path, so a cached false/stale snapshot cannot leave Python permanently closed after native AC recovery; a stale true is never authoritative because the native admission gate still rejects.

There is exactly one readiness handshake per generation: no second `ReadyEvent` later in the same generation and no separate optional "model `ReadyEvent`". `runtime.ready`/`_ready_message` therefore carry control-readiness semantics and `runtime.readiness` remains the one-shot static capability/configuration handshake; `can_submit()`/`is_ready()`/HTTP `/ready` must not interpret `runtime.ready` as inference readiness.

`inference_ready=false` never means the generation is stale. Only EOF, process exit, or protocol failure fences a generation.

## 2. Admission and drain

**Decision**: Correctness boundary is native `NativeRuntime::handleRequest()` immediately before `Engine::submit()`. Power changes and frame handling are serialized by the native transport loop. `RuntimeBootstrap` closes admission at that boundary, then drains all previously submitted Engine work and command tickets.

**Verified current behavior**:

- `server/server.py` checks `backend.can_submit()` before request parsing/HTTP queue admission, while `server/backend.py::NativeBackend.submit()` registers `_active` and invokes `runtime.submit()` later. These are separate check/act operations.
- `MultiplexedRuntime.submit()` acquires `_admission_slots`, serializes, ensures a process generation, stores `RuntimeCall` in `_pending` under `_state_lock`, then writes under a separate `_write_lock` (`server/runtime.py::submit`, `_write_bytes`). The written byte order is authoritative wire order, but there is no lifecycle close gate.
- Native `handleRequest()` validates and directly calls `core_.submit()` (`runtime/engine/NativeRuntime.cpp::handleRequest`). `Engine::submit()` inserts the request and scheduler entry. A later tick admits queued work to model resources (`Engine.cpp::admitQueued`/`admit`).
- `Engine::idle()` is false while requests or a command ticket remain (`Engine.cpp`); `Engine::Pending` owns a `ModelBatchTicket`. Engine reclaim comments state work happens at command-completion safe points (`Engine.hpp`).
- `Scheduler::suspendForResources` / `resumeFromResources` and `Runtime::suspend(requestId)` represent per-request memory-pressure preemption/replay, not feature-level suspension.

**Required behavior**: A request frame handled before the owner closes is admitted work, including queued/waiting-resource work; it keeps required resources until normal terminal completion/cancellation. Frames handled after closure receive prompt explicit unavailable error. Drain waits for `Engine::idle()` and no command in flight, without elapsed-time sleeps or request-semantic changes. When no `Engine` is published at all (model-less startup or after suspension), `NativeRuntime` refuses with explicit unavailable/not-ready wording — not "warmup has not completed", which implies an in-progress warmup and invites indefinite retry. Suspend order is fixed: close admission → drain requests and command/model tickets → quiesce retained cache/state IO → detach/destroy `Engine` → destroy `RuntimeModel`/arenas → destroy weight-bearing `ModelPackage` residency and model-derived factories → prove residency release → publish `suspended`.

## 3. Native process and reusable storage lifetime

**Decision**: Keep native child and its base resource/cache graph alive. Do not restart the child for suspension.

**Verified current behavior**:

- `SlotFile::Backing` owns an fd, shared disk budget and file metadata; `SlotFile` owns the IO worker. `SlotFile` creates `mkstemp`, immediately `unlink`s the path, sets `FD_CLOEXEC` and `F_NOCACHE`, and closes fd on backing destruction (`runtime/model/SlotFile.cpp::Backing`, `SlotFile` constructor/destructor).
- `SlotFile::Slot` shared-owns backing, but asynchronous reads/writes use the `SlotFile` worker. A slot handle does not create a process-persistent pathname or worker lifetime.
- `RuntimeResources::create()` constructs state `SlotFile`, `QwenStateStorage`, optional KV `KvPageTier` plus its own `SlotFile`, `KvPool`, and `Cache` (`runtime/engine/RuntimeResources.mm`). `Cache` stores KV graph and `StateCache` alongside them (`runtime/engine/Cache.hpp`).
- RAM KV and Qwen state allocations are Metal/backend-bound. The optional disk tier holds recoverable copies in file/fd state, but still uses in-process `SlotFile` objects/workers and backend/runtime owners.

**Rationale**: The scratch tier cannot survive a native process restart; a rebooted child necessarily recovers cold. Same-process retention is required for both file-backed slots and cache metadata.

## 4. Model-resource split

**Decision**: Preserve the backend and cache graph; release the **residency** stratum — weight-bearing `ModelPackage`, `model::RuntimeModel` (target/draft/vision wrappers, runtime arenas, runtime continuations), `Engine`, and model-derived factories/callbacks that retain residency — after drain. Keep the **retainable/base** stratum independently owned: backend/accounting, `Cache`/`StateCache`, KV pool/backing/tier, `StateStorage` required by retained `CompositeState`, `SlotFile` workers/backings, detached `ModelDescriptor`/configuration, cache identity, and detached status/resource snapshots.

**Ownership split is two-sided**: `RuntimeResources` currently bundles the weight-bearing `ModelPackage` with the base graph, and `NativeRuntime` currently bundles `Engine` with its process-lifetime shell. Both bundles must be split; neither is an existing unload operation.

**Verified current behavior**:

- `RuntimeResources` currently owns `model::ModelPackage`, `ops::ExecutionPlans`, backend, `MemoryGovernor`, KV page storage, `StateStorage`, KV tier/pool, and `engine::Cache` (`runtime/engine/RuntimeResources.hpp`). Its destructor order is documented in that header.
- `ModelPackage` owns target, DFlash draft, and vision weight objects; `loadModelPackage` loads all their prepared/packed weights (`runtime/model/ModelFactory.hpp`, `ModelFactory.cpp::loadPackage`).
- `Runtime::Impl` owns target/draft/vision execution objects and prefill/decode arenas while borrowing the package, backend, pages, state storage, and operators (`runtime/model/Runtime.mm`). `RuntimeModel` is separately owned by `RuntimeBootstrap`.
- `QwenStateStorage` owns GDN cells and draft rings; `releaseIdle` only reclaims idle pool buffers. `QwenCompositeState` RAM snapshots contain private state buffers and a shared pool; disk-only snapshots have no pool/slot-buffer reference and retain `SlotFile`/disk-slot handles (`runtime/model/QwenState.hpp`, `QwenState.cpp`).
- `RuntimeResources::memoryGovernor()` and `MetalBackend::memoryStats()` are existing accounting seams.

**Rationale**: Keeping `RuntimeResources` as-is also keeps its `ModelPackage` weights, so merely destroying `RuntimeModel` is not enough. Destroying all `RuntimeResources`, however, destroys cache identity, KV cache and unlinked SlotFile owners. A resource ownership split is required.

**Cold startup on battery**: do not create expensive inference resources merely to suspend them. When the first power observation is battery and no reusable state exists, the process need hold only `RuntimeBootstrap` lifecycle/config state, a detached `ModelDescriptor`/configuration, the long-lived `NativeRuntime` control shell, and `FdTransport`/control/status infrastructure. No `Cache`/`StateStorage`/backend warm graph is required before the first AC load when there is no warm state to preserve; it is built with the first load/recovery.

**Preservation constraint**: Prefer completed offload to avoid retained cache entries keeping state-pool allocations in RAM. If the disk tier is unavailable, preserving a bounded RAM candidate requires retaining `StateStorage`, its buffer-pool ownership, and the same backend, with those bytes counted as retained cache residency. If that ownership cannot be kept safely, cold fallback applies for that attempt. Retain only the resources that warm KV/recurrent-state reuse demonstrably needs; quantify that footprint separately from released model residency.

## 5. Warm-state reuse and transactional recovery

**Decision**: Warm resume comes from the existing `Cache`/`StateCache` reusable prefix and immutable `CompositeState`, retained in the same process. Prefer a disk-backed candidate, then load candidate package/runtime and restore through existing cache-aware admission. If disk backing is disabled, bounded RAM state may be retained only when its pool/backend ownership is kept and accounted. Do not destructively consume source state before restore commits.

**Verified current behavior**:

- `Engine::Cache` maintains KV blocks and state lookup; `StateCache::acquireDeepest` returns a pin-owning `CompositeStateLease` (`runtime/engine/Cache.hpp`, `StateCache.hpp`).
- Qwen composite state holds target recurrent (GDN) plus draft-context state. `Runtime::snapshot()` copies committed state into a cache slot; `snapshotToDisk()`/`QwenCompositeState::offload()` materialize a host staging copy and write via `SlotFile` (`runtime/model/Runtime.mm`, `QwenState.cpp`).
- Qwen snapshot boundary requires page alignment and a complete draft window (`Runtime::committedStateSlot`). Qwen restore checks concrete composite type and exact `CompositeStateLayout`, and copies from immutable cached state into a new lane (`QwenStateStorage::restore` / `beginRestore`).
- Existing Engine cache promotion occurs only after successful restore (`runtime/engine/Engine.cpp` restore completion; `runtime/engine/Cache.cpp` promote paths). State leases pin entries during restore.

**Required behavior**: Complete any pending state offload before suspension success. Retain immutable disk state source across failed candidate restore, and only publish/promote candidate state/runtime after validated restore and current intent revision. If no complete state, safe state cannot be materialized, layout check fails, IO fails, or recovery attempt cannot prove reuse, evict/drop unsafe candidates and recover cold. Warm-completed scenario must be observed to hit restored cache/state, not merely retain metadata.

## 6. Compatibility identity

**Decision**: Reuse `RuntimeCacheIdentity`, saved `ModelDescriptor`, and exact state-layout check; compare them on every candidate recovery. Unknown means cold.

**Verified current behavior**:

- `makeRuntimeCacheIdentity()` hashes combined loaded model manifest, target manifest, `buildId`, and a target KV layout guard. The canonical namespace includes build ID, target digest, format, page tokens, quantization/scale and target KV geometry (`runtime/engine/RuntimeResources.mm::canonicalRuntimeCacheNamespace`, `makeRuntimeCacheIdentity`).
- Combined package manifest includes target, draft and vision file records (`runtime/model/ModelFactory.cpp::loadPackage`, `WeightStore.cpp::weightManifestFingerprint`). Record identity includes path, declared bytes, magic/layer/type and non-empty content identity.
- `dev/tools/build_identity.py::production_input_paths` hashes all runtime C/C++/Objective-C++/Metal source plus build identity tools, so it covers runtime state layout and interpretation code.
- `QwenCompositeState` embeds `CompositeStateLayout` and `QwenStateStorage::restore` validates exact layout equality.

**Rationale**: The current namespace is strong for model files/build/KV, and state restoration independently checks exact state geometry. Recovery is same-process and compares a saved descriptor, so reusing the cache namespace avoids redundant identity. State payload-format/corruption validation still needs implementation review; add a format identity only if it is not already proven by build identity and existing state checks.

## 7. Python/native protocol and crash distinction

**Decision**: Reuse the existing one-shot `ReadyEvent` as the control-readiness handshake and add detached lifecycle status for inference readiness; do not send power intent across the boundary while both observer and owner are native. The existing `ReadyEvent` is already the required first event, one-shot per generation, the startup-attempt completer, the source of `_ready_message`/`runtime.ready`/`runtime.readiness`, and able to carry the static capability tuple — so its meaning is redefined rather than replaced by a new frame (a new frame or version bump only if implementation evidence forces it). Inference readiness is a dynamic status field, not a repeated event.

**Verified current behavior**:

- Protocol supports request/cancel/mask/status request and server events including `ReadyEvent`, status JSON, request errors and completion; no power, lifecycle, or control-ready message (`server/protocol.py`, `runtime/engine/Protocol.hpp/.cpp`).
- `StatusJsonEvent` is request/response: native `NativeRuntime::handleStatus()` answers a `StatusRequestFrame` with `StatusJsonEvent` and emits nothing unsolicited (`runtime/engine/NativeRuntime.cpp::handleStatus`). Python already has a bounded refresh mechanism: `NativeBackend._ensure_background_status_refresh()` is invoked from `can_submit()` and from status-error paths (`server/backend.py`).
- Native `NativeRuntime::announceReady()` throws `"ready was already announced"` when `ready_` is already set, and sets `ready_ = true` after sending `ReadyEvent{instanceId, maxConcurrent, maxContext, features}` (`runtime/engine/NativeRuntime.cpp`). It is structurally one-shot per child process. On battery startup no memory plan exists yet, so `config_.engine.maxContext` at that point is the configured/descriptor ceiling rather than a memory-plan-resolved effective context.
- `NativeRuntime::handleRequest()` gates on `ready_` and, when false, answers `"engine_not_ready"` / `"engine warmup has not completed"` (`NativeRuntime.cpp`) — wording that assumes a warmup is in progress and must not be reused for battery suspension.
- Python `_dispatch_message` raises `ProtocolFatal("native sent more than one ReadyEvent")` on a second `ReadyEvent`, `ProtocolFatal("native event arrived before ReadyEvent")` for any event that arrives first, and sets the startup attempt's `event` only on `ReadyEvent` (`server/runtime.py::MultiplexedRuntime._dispatch_message`). `wait_ready()` is `_ensure_process()` plus `self.ready`.
- `MultiplexedRuntime.ready` is `not closed and process is not None and process.poll() is None and _ready_message is not None and terminal_error is None` (`server/runtime.py::ready`) — it currently conflates process liveness with inference readiness.
- `_first_ready` is recorded once and never reset; every later `ReadyEvent` must repeat identical `max_context_tokens`, `max_concurrent_requests`, and `feature_bits` or Python raises `"native context window, concurrency or features changed; restart the Splash server"` (`server/runtime.py`).
- `NativeBackend.can_submit()` uses `self.runtime.ready`; `is_ready()` layers the status `ready` flag and `memory_pressure` on top; HTTP `/ready` calls `is_ready()` (`server/backend.py`, `server/server.py::do_GET`).
- `NativeBackend.status()` reports `transport.recovering = not transport_ready` — an existing, unrelated use of the word "recovering" (`server/backend.py`).
- Python process generation, startup attempts and failed child fencing are already explicit in `MultiplexedRuntime`; `NativeBackend._engine_failed` starts ordinary backed-off relaunch/status refresh (`server/backend.py`).
- Python `close()` means shutdown and cancels active calls; it cannot mean temporary suspension.

**Required behavior**: A model-less child is still control-ready and alive, not crashed/restarting.

- The existing `ReadyEvent` completes the startup attempt in its control-readiness role, suppresses ordinary startup timeout/relaunch for an intentionally model-less child, and carries only pre-residency capability values (configured/descriptor context ceiling, static concurrency capability, feature bits/vision capability derivable from descriptor or configuration, and engine/generation identity as currently applicable) needed to build the HTTP/frontend control plane. Do not add a new `ControlReadyEvent` frame or a separate optional "model `ReadyEvent`" for this.
- Inference readiness is exposed as a detached lifecycle field and may flip `false -> true -> false -> true` inside one generation with no additional readiness event. There is exactly one readiness handshake per generation; do not require a second `ReadyEvent` after recovery, and do not treat `inference_ready=false` as a stale generation.
- `MultiplexedRuntime` generation liveness/startup uses control readiness plus actual process health; `runtime.ready` and `_ready_message` become control-readiness semantics and `runtime.readiness` remains the one-shot static capability/configuration handshake. `backend.can_submit()`, `backend.is_ready()`, and HTTP `/ready` use lifecycle inference readiness and must not interpret `runtime.ready` as inference readiness. Static capability metadata stays separate from inference readiness.
- Lifecycle `inference_ready` is obtained from the existing status request/response surface, not from an unsolicited push. The bounded refresh trigger must move off `runtime.ready` (which becomes true while model-less) and onto the cached lifecycle status: `can_submit()`/`is_ready()`/HTTP readiness schedule a bounded status refresh when the cached lifecycle value is false or stale, so Python discovers native AC recovery without a process restart and without a user manually querying `/status` first. Refresh is passive while model-less: never start or replace the process, never restore inference. Do not poll on every request, and add no unsolicited lifecycle event unless implementation evidence shows this bounded refresh cannot satisfy the contract. A stale `true` is never authoritative — the native gate still rejects after battery closure, so no correctness claim depends on Python winning an admission race.
- Effective max-context is resolved only after memory planning, so it cannot ride the startup-time handshake: expose the configured/descriptor ceiling while model-less, publish the resolved effective value in status before `inference_ready` becomes true, let admission use the current resolved value, fail closed on an inconsistent/unsafe value, and never restart the child for context drift.
- Add lifecycle state/power/revision/`model_resident`/`last_error` to existing native status. Existing generation fencing handles child crashes. Shutdown remains EOF/signal/`close()`. Status reads while suspended must not call a process-start/recovery path and must not restore inference.

## 8. Power observation and startup

**Decision**: Add a small IOKit observer under `runtime/main.mm`/native runtime; synchronous initial snapshot, then live notifications posted to the existing control wake loop. Observer provides AC/battery/unknown only.

**Verified current behavior**:

- `Makefile:196` already links `-framework IOKit`; existing IOKit use in `runtime/metal/MetalBackend.mm` queries GPU registry only. Repository search found no power-source adapter.
- `FdTransport` already has a control notifier/handler and poll-based wake seam (`runtime/engine/FdTransport.hpp/.cpp`). Memory-pressure observations are recorded asynchronously; resource changes run at safe points (`runtime/main.mm::MemoryPressureMonitor`, control handler).
- `runtime/main.mm::parseArguments()` calls `inspectModelPackage()` to obtain `ModelDescriptor` and then `bootstrapConfig()` records model root, format, context, and disk budget. `RuntimeResources::create()` performs the expensive package/resource assembly later through `RuntimeBootstrap::start()`. Thus detached descriptor/configuration is available before weight-bearing bootstrap.
- Python `server/server.py::main()` binds the socket but keeps it inactive, then loads tokenizer/templates, starts a lazy native runtime, blocks on `wait_ready()`, reads `runtime.readiness` to derive `effective_context`, concurrency, and vision flags, constructs `Frontend`, and activates HTTP only after the readiness event.

**Required behavior**: Initial power must be known before expensive package/runtime loading. On battery+feature enabled, the child emits the one-shot control-readiness `ReadyEvent` without `RuntimeResources` model weights and without pre-building the retainable warm graph when no reusable state exists, while launch arguments/descriptors preserve intended model config; its capability payload is the configured/descriptor ceiling, not a memory-plan-resolved value. Python can then build frontend and activate HTTP from detached config, using that configured/descriptor ceiling as a placeholder that later lifecycle status may refine. On AC it loads/recovers normally, publishing the resolved effective context before `inference_ready` becomes true. IOPowerSources API/run-loop bridging and unknown/error semantics need implementation verification; the observer never makes resource decisions.

## 9. Model-less status and observability

**Decision**: Keep existing HTTP surfaces and provide semantic readiness with detached data that is independent of `Engine`.

**Verified current behavior**:

- `/health` is constant HTTP liveness, `/ready` calls `backend.is_ready()`, `/status` and `/metrics` obtain server/frontend/backend status (`server/server.py::do_GET`, `FrontendServer.status`).
- `NativeBackend` deep-copies native status snapshots; timeout fallback marks readiness false and reports stale age (`server/backend.py::_cache_status`, `status`). Some readiness/status paths can schedule background status refresh, which invokes `runtime.wait_ready()` if transport is down.
- `Frontend.status()` contains static model names and configuration plus frontend caches/metrics; `FrontendServer.status()` includes HTTP instance details.
- Native `runtimeStatusJson(...)` takes `EngineMemoryPlan`, `engine::EngineSnapshot`, `model::ModelTelemetry`, cache identity, and memory snapshots, and is invoked from `runtime/main.mm` (`runtime/engine/Status.cpp::runtimeStatusJson`, `Status.hpp`). Its top-level `ready` is computed from `warmup.ready() && memoryAudit.valid && metalHealthy && hostSafe && currentBytes <= hardBudgetBytes`, and it embeds `admission.suspended` (resource wait) and `admission.draining` (Engine drain). None of these is the battery lifecycle state, and the function as written cannot produce a model-less snapshot because it requires an `Engine` snapshot.
- Python separately reports `transport.recovering` for "transport not ready", again unrelated to battery lifecycle recovery (`server/backend.py`).

**Required behavior**: A model-less snapshot must be servable from bootstrap-owned detached state while no `Engine` exists — add a detached status path rather than faking an `Engine` snapshot. Keep `/health` true while HTTP runs; `/ready` 503 until lifecycle `inference_ready`; `/status` and `/metrics` return `control_ready`, `inference_ready`, `lifecycle.state`, `lifecycle.power`, `lifecycle.revision`, `model_resident`, effective context when known, and `last_error`, and mark model-derived values unavailable in model-less state. `control_ready` stays true while the child is healthy across `draining`, `suspended`, `recovering`, and `recovery_failed`. Do not derive battery lifecycle state from `admission.suspended`, `admission.draining`, `transport.recovering`, Scheduler phases, or memory-pressure verdicts. Reads must not start child, load weights, trigger warm restore, replace the generation, or hold runtime references, and must not destroy or unpin warm-state backing. Static model metadata/config remains available, model-specific live telemetry is detached/unavailable. Suspended refusal is explicit unavailable/not-ready behavior, not warmup wording.

**Freshness**: `StatusJsonEvent` remains request/response. `NativeBackend` must keep a bounded status-refresh path for `inference_ready` (existing `_ensure_background_status_refresh()`), triggered from the cached lifecycle value rather than from `runtime.ready`, so a cached false or stale snapshot cannot leave `can_submit()`/`is_ready()`/HTTP readiness permanently closed after native AC recovery. That refresh is passive and never starts/replaces the process or restores inference, and no correctness claim depends on it: a stale `true` still loses to the native admission gate after battery closure. No unsolicited lifecycle event is added unless implementation evidence shows this bounded refresh is inadequate.

## 10. Test seams and implementation uncertainties

**Verified focused seams**:

- `dev/tests/engine/native_engine_loop_test.cpp` has held-ticket/native-loop seams for controlled command completion.
- `runtime_bootstrap_test.mm`, `runtime_resources_test.mm`, `runtime_status_test.cpp`, `protocol_test.cpp`, and `slot_file_test.cpp` exercise bootstrap/resources/status/protocol/file tiers; focused build recipes are in `dev/native.mk`.
- `dev/tests/engine/test_server_recovery.py` has event-gated startup/recovery doubles; `dev/tests/test_server.py` has HTTP harnesses. Do not rely on its polling helper for race correctness; use event gates.

**Unproven from current checkout; retain as planning risks, not assumptions**:

Implementation proof gates (none may be reported as already proven):

1. Destroying `Engine` -> `RuntimeModel` -> `ModelPackage` actually releases the intended target/draft/vision residency while retained state remains valid, and every such Metal allocation is visible in `MetalBackend::memoryStats()` while `Cache`, KV tier, and `StateStorage` remain valid.
2. At least one eligible `CompositeState` + matching KV prefix survives suspension and later restores warm — under all disk-quota, pin and in-flight IO conditions. Offload can refuse/fail; correctness then requires cold fallback and no false suspended-success claim.
3. Disk state corruption/truncation is detectably invalid; add only the minimum payload version/checksum if existing protection is insufficient. Whether current `CompositeStateLayout` and build ID fully cover payload semantics, especially within one same-process instance, still needs a concrete state-format audit; unknown remains cold.
4. `Engine`/request/ticket drain plus `SlotFile`/cache IO quiescence leaves no operation touching released model/lane resources.
5. A failed recovery candidate leaves retained source state retryable and permits correct cold fallback.
6. Python control-ready/generation semantics are deterministically proven for: battery startup -> control ready, inference unavailable; AC -> recovery in the same generation; battery -> suspension in the same generation; AC -> recovery again in the same generation; suspended status inspection -> no process/model restart; actual child failure -> new generation and cold recovery. Freshness must also be proven: native AC recovery succeeds -> Python discovers `inference_ready=true` without process restart and without requiring a user to manually query `/status` first; and native battery gate closes -> a stale Python `true` can never cause actual native admission after the close boundary.

Additional implementation uncertainties:

7. The exact IOKit power-source notification API, callback/run-loop teardown, and error behavior are not already established in this checkout. Implement behind an injectable source and validate on macOS.
8. How to satisfy normal request cancellation semantics if server shutdown arrives during native drain while a request is already admitted. Preserve the current terminal shutdown policy and test before destroying model resources.
9. How Python's `_first_ready` constant-capability check and `Frontend` construction-time `effective_context` are reconciled with a recovered engine that resolves a different effective max-context without a restart; the effective value must travel through detached lifecycle status rather than a repeated readiness event.

These items are proof obligations. They do not permit an always-cold implementation to satisfy the warm-resume specification, nor a lifecycle enum alone to satisfy release proof.
