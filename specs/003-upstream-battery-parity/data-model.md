# Data Model: Runtime Ownership and Lifecycle State (003)

Runtime state and ownership model, not database entities. Provenance tags (identical to `plan.md`'s key) appear on every name:

| Tag | Meaning |
|---|---|
| `[U]` | present at clean upstream HEAD `a8a74e6` (verified with `git grep`/`git show HEAD:<path>`) |
| `[S3]` | historical stage 3 only (`f9f4eb3a`), absent at HEAD |
| `[D]` | auto-merged working-tree draft: present in the conflicted tree because a file merged cleanly — **not** an upstream guarantee |
| `[P]` | proposed for this migration; no source exists yet |

Presence in the conflicted working tree is **never** evidence of being upstream. Per 003's constraints section, `[P]` names denote required capabilities rather than upstream APIs.

---

## 1. Lifetime strata

```text
[U] process generation (native PID + FdTransport)      ─ outlives ─▶
[U] retained resource graph (RuntimeResources minus residency)  ─ outlives ─▶
[P] disposable inference residency (ModelResidency + RuntimeModel + Engine)
```

| Identity | Owner | Survives suspension? | Key symbol (provenance) |
|---|---|---|---|
| Process generation | `runtime/main.mm` + `FdTransport` | yes | `[U]` one `ReadyEvent` per generation |
| Retained graph | `[U]` `engine/RuntimeResources.hpp::RuntimeResources` | yes | `[U]` `cache()`, `backend()`, `memoryGovernor()`, `cacheIdentity()` |
| Cache / KV pool+tier+pages | retained graph | yes, same addresses | `[U]` `engine::Cache`, `KvPool`, `KvPageTier`, `kv::PageStorage` |
| CompositeState / StateCache | retained graph | yes | `[U]` `engine/StateCache.hpp` |
| SlotFiles + persistent tier | retained graph | yes (process-local backing) | `[U]` `PersistentCacheFiles`, `model::SlotFile`, `CacheDirectory` |
| Persistence intent (delayed durable state) | **moved to** retained graph | yes | `[U]` `engine/WriteBehind.hpp` (currently owned at `[U]` `Engine.hpp:903`) |
| Model package / weight images | disposable stratum | **no** | `[U]` `model_` inside `RuntimeResources` (the split is `[P]`) |
| Streamed stores (PLE table, routed experts) | disposable stratum | no | `[U]` `SparseRowStore`, expert store stats |
| ANE residency (program, arenas) | disposable stratum | no | `[U]` `ops::AneFfn`, `AneFfnModel` |
| `ReleasableMemory` parts | disposable stratum | no | `[U]` `engine/ReleasableMemory.hpp` |
| `model::RuntimeModel` | `[U]` `Bootstrap::model_` today; `[P]` disposable owner after the split | no | `[U]` `modelRuntime()` |
| `engine::Engine` | `[U]` `NativeRuntime::core_` while published; `[P]` candidate while private | no | `[U]` `core_` |
| Model-dependent bindings (callbacks, notifiers, Cache/StateCache hooks) | disposable stratum | no | `[U]` `setCompletionNotifier`, `Cache::persist`, `WriteBehind::published` wiring |

Detachable-residency APIs (`publishEngine`, `tryPublishEngine`, `destroyEngine`, `hasEngine`, the admission gate, the candidate envelope, `startModelLess`, the suspend/recovery pumps) are `[D]` drafts from stage 3, **not** `[U]` upstream APIs, and are re-derived as `[P]` in this plan.

**Destruction order while suspended** (warm): `Engine → RuntimeModel → residency`; retained graph and generation stay alive.
**Cold-first recovery candidate** (candidate owns the base graph): `Engine → RuntimeModel → ModelPackage → candidate-owned RuntimeResources`.

---

## 2. Resource-domain authority

### State machine

```text
Owner ──(admission closed + drains proven + callbacks retired)──▶ Worker
Worker ──(work completed; envelope parked)──▶ Parked
Parked ──(owner claims envelope at a safe point)──▶ Owner
```

| State | Holder | May act | May publish |
|---|---|---|---|
| `Owner` | long-lived native owner (Bootstrap/`NativeRuntime` thread) | serving, draining, retained due-work, adoption, admission publication | yes (only here) |
| `Worker` | one serial Bootstrap-owned residency worker | private candidate construction, destructive disposal | **never** (no lifecycle truth, no effective context, no admission) |
| `Parked` | the synchronized completion envelope between worker completion and owner claim | nothing (inert holder) | no |

### Rules (invariants, enforceable at the interfaces)

1. Exactly one holder at any instant; `Owner+Worker` overlap is a defect (FR-005).
2. The lease is a **move-only witness** accepted by: MetalBackend submit/allocate/pipeline-lookup path, `MemoryGovernor`, and destructive/allocating retained-storage operations (KV tier, StateCache publication, Cache disk-tier writes under budget).
3. Handoff preconditions (all four witnesses, no substitutes, no sleeps — FR-008/FR-009):
   - admission closed at the admission gate (`[D]` `NativeAdmissionGate` draft; `[P]` in this plan) held through `Engine` submission;
   - request/engine drain (`[U]` `Engine::idle()`, `Engine::inFlight()`, `commandInFlight()`, plus retirement receipts **`[P]`**, prerequisite U-01);
   - retained-state IO drain (`[U]` `StateCache::writing()`/`pollOffload()`, plus the KV-tier transfer witness **`[P]`**, prerequisite U-02);
   - callback retirement (Metal command tickets + host-step `then` + ANE service queues + GPU completion callbacks + `completionNotifier` closures; receipts **`[P]`**, prerequisite U-01).
4. The owner alone performs: revision re-inspection, physical adoption, effective-context publication, final fence, admission opening, and rollback on refused adoption.
5. Observation while `Worker`/`Parked` is authoritative → immutable detached snapshots only (FR-007).
6. Never join an in-flight worker from a native safe point; joining an already-completed worker is permitted (FR-006).
7. Shutdown is terminal over `Draining`/`Suspended`/`Recovering` and cannot be reopened by power observations or completed candidates (FR-013).

### Why not a mutex

A mutex serializes calls but does not (a) prove quiescence before authority migrates, (b) express the "defer due persistence work while the worker holds authority" rule, or (c) keep expensive residency work out of coordination locks (constitution III). The lease is the explicit-lifetime mechanism; receipts supply the happens-before edge.

---

## 3. Lifecycle state and revisions

```text
[D] LifecyclePower { Unknown, AC, Battery }                    // engine/Status.hpp: auto-merged draft, absent at HEAD
[D] LifecycleState { Ready, Draining, Suspended, Recovering, RecoveryFailed, Shutdown }
[D] LifecycleStatusSnapshot { power, state, controlReady, inferenceReady,
                              modelResident, configuredContextCeiling,
                              effectiveContextTokens, ... }    // re-derived, not assumed
```

| Field | Source of truth | Rule |
|---|---|---|
| `power` | `[S3]` `PowerSource` observation via `PendingPowerObservation` (record + wake only) | duplicate observations harmless; Unknown is not AC and fails closed |
| `observationSequence` | `[P]` monotonic per-generation counter published by the native lifecycle owner at every lifecycle publication | applied strictly-greater with generation and revision; orders phases **inside one revision** (D-14) |
| `controlReady` | shell existence (transport + protocol frame handling) | true in every non-Shutdown state of a live generation |
| `inferenceReady` | published `Engine` + `[P]` admission gate | may toggle true→false→true many times per generation; never triggers a new `ReadyEvent` |
| `configuredContextCeiling` | static pre-residency configuration | the value carried by `ReadyEvent.maxContextTokens` and `/v1/models`; **its meaning shifts from upstream's served context to the ceiling** (research D-10 consumer table) |
| `effectiveContextTokens` | the **published** `Engine` only | required present, positive, ≤ ceiling, equal to live Engine when `inferenceReady`; else fail closed |
| `modelResident` | physical residency presence (not a lifecycle string) | drives truthful absence reporting |
| request capacity telemetry | **approved in-band field (U-05)**: an explicit `StartEvent.capacityTokens` added by a coordinated binary event extension (`PROTOCOL_VERSION` bump, D-12 rule 3) preserving the 16-byte header; adoption updates the shell's request-telemetry context only after the exact `Engine` is published | must be provably the capacity of the `Engine` that served the request (constitution VIII); the status-lookup-at-issue-time alternative is rejected |

**Ordering domains (three, FR-024 / constitution VI / research D-14)**
- `[P]` `lifecycleRevision`: monotonic within one native process generation; power changes create revised intent only when the value changes; publication must match the current revision; cancellation is revision-fenced. (The `observePower`/revision pump visible in the tree is `[D]`, absent at HEAD.)
- `[U]` `processGeneration`: `server/runtime.py` `RuntimeCall.generation`; orders status across child replacement. A replacement child may legitimately restart numbering at a lower revision, so revision alone must never order across generations.
- `[P]` `observationSequence`: orders lifecycle phases **within one revision** (one Battery revision spans `Draining → Suspended`; one AC revision spans `Recovering → Ready`; the newer-AC reconciliation moves `Draining → Suspended` with no new revision). HTTP completion order is transport order and is never treated as observation order.
- Python applies a completion only when `(processGeneration, lifecycleRevision, observationSequence)` is strictly greater than the last applied tuple.

**State transitions the model must permit**
```text
Ready ─Battery▶ Draining ─(both drains)▶ Suspended
Suspended ─AC▶ Recovering ─(adoption+fence)▶ Ready
Recovering ─(stale/refused/failed)▶ RecoveryFailed | Suspended
newer AC racing a committed release▶ Suspended(model-less, admission closed) ▶ normal recovery
any ─Shutdown▶ Shutdown (terminal)
```

---

## 4. Candidate envelope and completion mailbox

```text
[P] RecoveryCandidate {           // private Bootstrap state, never published by the worker
    resources      // present only for cold-first recovery; outlives every borrower
    residency      // disposable stratum
    model          // model::RuntimeModel
    engine         // engine::Engine
    lifecycleRevision
}
[P] CompletionEnvelope { candidate?, lease, revision, buildError?, resourceSnapshot? }
```

Rules: one synchronized completion envelope carries candidate + authority + revision together; after publishing it, no worker-local object or destructor may touch transferred resources; the owner claims current results and returns stale results intact for worker-side disposal; no build and disposal operation overlaps; the candidate is destroyed outside the coordination lock (FR-012).

`[D]` `RecoverySpec` (value-owned reload inputs: `RuntimeResourcesConfig`, model descriptor, engine config, `memoryPressure`, `cancelled`, host-memory provider, `lifecycleWake`) supplies the model-less rebuild inputs and must not capture residency — a stage-3 draft, absent at HEAD, re-derived as `[P]`.

---

## 5. Persistence intent (retained, deferred under worker authority)

```text
[U] WriteBehind { waiting_: deque<Point{block, due}>, queued_: set, stalled_,
                  counters_: {waiting, durable, unneeded, refused},
                  kDelayMilliseconds = 10'000, kMinimumTokens = 2048 }
```

| Property | Must survive | Behaviour during suspension |
|---|---|---|
| pending points + dedup (`queued_`) | yes | untouched |
| absolute due times | yes | not re-timed |
| publication order (one at a time, publish order) | yes | preserved |
| disk-write budget interaction (`stalled_`) | yes | budget-held points stay held |
| counters (`WriteBehindSnapshot`) | yes | comparable to the upstream baseline (SC-009) |
| clean-stop flush (`flush()`: newest-first, due-or-not, budget lifted) | yes | used **only** at clean shutdown; never as Battery due-work |

Execution policy under authority: `Owner` → due work may run (`run(now)`); `Worker`/`Parked` → deferred, not dropped, not re-timed, not re-ordered, eligible again when authority returns (FR-017).

---

## 6. Retained-state reuse and restore integrity

| Item | Identity rule | Failure rule |
|---|---|---|
| KV prefix + composite-state boundary + slot-backed identity | identical objects across the boundary; process-local backing not reconstructible by a new child (FR-015) | unknown compatibility → cold recovery (constitution V) |
| First compatible request after recovery | restore boundary > 0, executed prefill == uncached suffix only, tokens counted separately (SC-005) | no synthetic prompt, no preserved-prefix replay, no full-context warmup |
| Restore into one destination | transactional, destination-local; verify before commit; finish/cancel linearizable | failed destination may go cold; immutable source stays retryable (FR-018) |
| In-flight offload | owned for accounting/completion, **never obtainable** as reusable `CompositeStateLease` while writing | failed write discards the failed publication; KV boundary survives, `lostState` reported truthfully |

---

## 7. Readiness and context invariants

- Exactly one `ReadyEvent` per process generation; its `maxContextTokens` carries the **configured ceiling** under this contract — a meaning shift from upstream, whose consumers currently treat the same value as the served context (`server/server.py:1841`); the consumer reconciliation is research D-10.
- `inference_ready` toggles within a generation with no additional handshake.
- `/v1/models` = static ceiling; lifecycle `effective_context_tokens` = published-Engine value; request capacity telemetry is attributed only to the `Engine` that served the request, by the approved in-band `StartEvent.capacityTokens` field fixed in U-05 (added with a coordinated `PROTOCOL_VERSION` bump; the status-read-at-issue-time alternative is rejected).
- Two independent versioning axes: **status schema** (`kStatusSchemaVersion`, JSON document — additive fields do not by themselves require or forbid a bump) and **wire protocol** (`kProtocolVersion`, binary frame layout — any change to a packed frame such as `StartEvent` forces a coordinated bump across both codecs, goldens and validators). Neither axis implies the other. The 16-byte frame header and existing event functionality are preserved; keeping the numeral 11 is not itself a requirement.
- Passive reads: `/ready`, `/status`, `/health`, `/metrics`, `/v1/models` must not load weights, rebuild `RuntimeResources`, publish an `Engine`, call `wait_ready()`, replace the child or open admission.
- Lifecycle observation order is the strictly-greater tuple `(processGeneration, lifecycleRevision, observationSequence)`; transport/HTTP completion order is never observation order (D-14).

---

## 8. Authority × lifecycle compatibility matrix

| Lifecycle state | Legal authority holder | Admission | Due persistence work |
|---|---|---|---|
| `Ready` (serving) | `Owner` | open | runs |
| `Draining` | `Owner` | closed | runs |
| `Suspended` (model-less, warm) | `Owner` | closed | runs (model-less wakeup source required, U-04) |
| `Recovering` (construction) | `Worker` or `Parked` | closed | deferred |
| `Recovering` (adoption phase) | `Owner`, admission still closed | closed | runs |
| `RecoveryFailed` | `Owner` | closed | runs |
| `Shutdown` | `Owner` (terminal) | closed | clean-stop flush only |

Any cell where two holders are legal, or where admission is open outside `Ready` with a published Engine, is a defect.
