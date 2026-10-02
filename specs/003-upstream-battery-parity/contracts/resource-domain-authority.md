# Contract: Resource-Domain Authority and Quiescence

Covers 003 FR-005, FR-008, FR-009, FR-021; constitution II, III, X. Referenced from `plan.md` workstream C and `data-model.md` §2.

## Scope of authority

Authority covers the **disposable residency stratum** plus the retained operations that mutate shared device/host memory or destructive storage state: `metal::MetalBackend` submit/allocate/pipeline-lookup path, `MemoryGovernor`, KV-tier and StateCache destructive/allocating operations, and `Cache` disk-tier writes that draw on the write budget.

Out of scope (may proceed without the lease): `FdTransport` control traffic and frame parsing, passive status/metrics reads, thermal sampling, and the retained graph's non-mutating observation paths.

## Source facts this contract is built on (provenance-tagged: `[U]` clean HEAD `a8a74e6`, `[S3]` stage 3 only, `[D]` auto-merged draft, `[P]` proposed)

| Fact | Provenance | Source |
|---|---|---|
| One thread submits, allocates and looks up pipelines; `checkHealth()`, `healthy()`, `unhealthyReason()`, `memoryStats()`, `commandInFlight()` may be called from any thread; at most one submitted-but-not-applied command | `[U]` | `runtime/metal/MetalBackend.hpp:391-393` |
| `CommandTicket` is move-only ownership of one submitted command; destroying/replacing an unfinished ticket waits for GPU completion | `[U]` | `runtime/metal/MetalBackend.hpp:301-308` |
| Host-step `then` callbacks run on the backend's completion thread and must not throw (throwing marks the backend unhealthy) | `[U]` | `runtime/metal/MetalBackend.hpp:245-280` |
| `MemoryGovernor` is unsynchronized: it hands a caller a short-lived byte reservation | `[U]` | `runtime/engine/MemoryGovernor.hpp:184` |
| `Engine::idle()`, `Engine::inFlight(requestId)`, `Engine::setCompletionNotifier` | `[U]` | `runtime/engine/Engine.hpp:259,873,252` |
| `NativeRuntime::commandInFlight()` | `[U]` | `runtime/engine/NativeRuntime.hpp` |
| `NativeAdmissionGate { std::mutex; bool inferenceReady; }` held through Engine submission | `[D]` — **absent at HEAD** (`git grep -c NativeAdmissionGate HEAD -- runtime` is empty); a stage-3 draft that merged cleanly, to be re-derived as `[P]` with its own test | working tree `runtime/engine/NativeRuntime.hpp` |
| Retained IO observability: `StateCache::writing()`, `pollOffload()`, `Unwritten {Drop, Wait, Keep, Stay}` | `[U]` | `runtime/engine/StateCache.hpp:149,290,291` |
| KV tier transfers are currently observable only through the destructor waiting for them | `[U]` | `runtime/engine/RuntimeResources.hpp` member comment (KV disk tier before KV page storage) |

## Required interface (proposed)

```cpp
// [P] move-only execution-authority token; no copy, no default.
class ResourceDomainLease {
public:
  enum class Holder { Owner, Worker, Parked };
  // Only the lifecycle owner can create the first lease.
  static ResourceDomainLease acquireForOwner();
  // Migrating authority requires every quiescence witness below to hold.
  struct Quiescence { /* see §Quiescence proofs */ };
  [[nodiscard]] Quiescence evidence() const = delete;      // supplied by Engine/MetalBackend receipts
  [[nodiscard]] WorkerHandoff transferToWorker(Quiescence proof);
  void returnToOwner(WorkerHandoff &&handedOff);
  Holder holder() const noexcept;
  ~ResourceDomainLease();      // asserts no holder-side work is in progress
};
```

Operations take the lease as a witness parameter (no lease → the operation is not callable):
- `MetalBackend`: residency-owning submit/allocate entry points,
- `MemoryGovernor` charge/mark/reset operations,
- retained-graph destructive/allocating operations (KV tier, StateCache publication, budgeted disk writes).

## Quiescence proofs (all four required; none substitutes for another)

| # | Proof | Evidence | Legal refusal |
|---|---|---|---|
| 1 | Admission closure | `NativeAdmissionGate` closed and held through `Engine::submit`; frames arriving after closure are rejected even with a stale Python `inference_ready` | — (this is a precondition, not a refusal) |
| 2 | Request/engine drain | `Engine::idle()` **plus** live-ticket/mask/restore/telemetry counters reaching zero; `NativeRuntime::destroyEngine()` may still refuse on its own ownership evidence | refusal → keep pumping the safe point |
| 3 | Retained-state IO drain | `StateCache::writing()`/pending offload, KV-tier transfer witness, retained `WriteBehind` front-point mid-write state | refusal → keep pumping |
| 4 | Callback retirement | all Metal command tickets retired, host-step `then` closures retired, ANE service queues drained, GPU completion callbacks retired, `completionNotifier` closures detached | refusal → keep pumping |

**Happens-before requirement**: acquiring the lease for the worker must establish a happens-before edge from (a) the last admitted request's terminal event, (b) the last retained-IO completion, (c) the last retired GPU/host callback, to (d) the first worker-side residency mutation — and symmetrically back to the owner after `returnToOwner`. Mutual exclusion alone does not satisfy this; the receipts (research U-01, U-02) supply it.

## Invariants

1. Exactly one holder at any instant; `Owner` and `Worker` overlap is a defect (FR-005).
2. The lease holder is the only thread that submits/allocates on `MetalBackend` for residency work, honouring upstream's single-submitting-thread rule.
3. No expensive work (model load, arena allocation, ANE preparation, destructive destructors) runs while a lifecycle/admission mutex is held (constitution III).
4. A Battery observation never triggers, completes or substitutes idle weight release, governor growth pause, thermal response or write-through pause — and vice versa (FR-021, constitution IV).
5. Observation paths never require the lease and never mutate; while a non-owner holds authority, lifecycle reads are served from detached immutable snapshots (FR-007).
6. Shutdown supersedes everything: no observation or completed candidate may transfer authority back into a serving state (FR-013).

## Verification obligations (deterministic; no sleeps)

| Obligation | Test seam (provenance) |
|---|---|
| Handoff refuses while a ticket/`then` closure/restore/offload is outstanding, then proceeds once retired | `[U]` fixtures in `dev/tests/engine/TestExecutor.hpp` (`RestoreControl`, `OffloadControl`, `MaskOverlapTicket`) + `[P]` Metal ticket/receipt fixture |
| Lease holder is the single submitting thread during residency work | `[U]` TSan build (`make test-sanitizers`) + `[P]` submitting-thread assertion fixture |
| Admission closed at the native boundary rejects post-closure frames | `[P]` admission gate (the `[D]` `NativeAdmissionGate` draft is re-derived) + `[U]` `Engine::submit` (Gate 1) |
| Retired-callback receipt counts reach zero at the handoff point | `[P]` receipt assertions, added in `dev/tests/engine/runtime_bootstrap_test.mm` |

**Evidence is owed here, in WS C**: these narrow tests must pass at this contract's boundary before WS D or E may begin. WS G re-runs them at suite scale and never establishes them.

## Unresolved items this contract must not paper over

- **U-01** (owned by WS C): no upstream symbol exposes a retirement receipt count for GPU/host callbacks. The receipts must be implemented and tested; the gate may not be declared satisfied without them.
- **U-02** (owned by WS C): no queryable KV-tier "transfers in flight" witness at a safe point; either add the query or reuse an existing spill/KV snapshot, and prove it with a parked transfer.
