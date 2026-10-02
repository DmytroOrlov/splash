# Contract: Worker Handoff, Mailbox, Disposal and Cancellation

Covers 003 FR-006, FR-007, FR-012, FR-013; constitution III, VI, XI. Referenced from `plan.md` workstreams C/D/E and `data-model.md` §4.

## Source facts (provenance-tagged: `[U]` clean HEAD `a8a74e6`, `[S3]` stage 3 only, `[D]` auto-merged draft, `[P]` proposed)

| Fact | Provenance | Source |
|---|---|---|
| Bootstrap owns startup and the single `ReadyEvent`; `start()` returns a complete owner only after the native loop sent its event ("No partially warmed instance escapes start()") | `[U]` | `runtime/engine/Bootstrap.hpp` (`start()` at HEAD `:145`) |
| Bootstrap already has a control pass and status path usable without model work: `controlPass(MemoryPressure)`, `statusJson(...)`, `sampleThermalState()` | `[U]` | HEAD `Bootstrap.hpp:145,152,165` |
| Transport exposes a pumpable control notifier and a bounded poll: `controlNotifier()`, `run()`, and `NativeRuntime::millisecondsUntilNextWakeup()` | `[U]` | `runtime/engine/FdTransport.hpp`, `runtime/engine/NativeRuntime.hpp` |
| Model-less start and lifecycle pumps — `startModelLess()`, `beginSuspend()`, `advanceSuspend()`, `advanceRecovery()`, `publishRecoveryCandidate()`, `shutdownLifecycle()`, `observePower()`, `publishLifecycleStatus()`, `detachedResourceSnapshot()`, enums `SuspendProgress`, `RecoveryProgress` | `[D]` | present only because stage 3 auto-merged; absent at HEAD (`git grep -c advanceSuspend HEAD -- runtime` is empty) → **unverified drafts** |
| Bootstrap test seam `friend class RuntimeBootstrapTestAccess` and `recoveryBuilderForTesting_` | `[D]` | **absent at HEAD** (HEAD `Bootstrap.hpp` has no `friend class`); introducing the seam is planned work with its own narrow test |
| `NativeRuntime` publish/destroy residency surface (`publishEngine`, `tryPublishEngine`, `destroyEngine`, `hasEngine`, `idle()`) | `[D]` | working tree only; at HEAD `NativeRuntime` holds `core_` and has no such surface |
| Power observations record and wake only; `PendingPowerObservation` orders registration before the initial sample | `[S3]` | `runtime/engine/PowerSource.hpp` exists only in stage 3 (git status: added by `f9f4eb3a`) |

## Required interface (proposed)

```cpp
// [P] One synchronized completion envelope; the only channel worker → owner.
struct CompletionEnvelope {
  std::optional<RecoveryCandidate> candidate;  // private residency; empty for pure disposal
  ResourceDomainLease              lease;      // authority returns inside the envelope
  uint64_t                     revision;       // revision the work was built for
  std::optional<BuildFailure>    failure;      // detached, no residency references
  std::optional<ResourceSnapshot> snapshot;    // detached accounting for status
};

// [P] Bootstrap-owned, exactly one residency worker at a time.
class ResidencyWorker {
public:
  void start(ResourceDomainLease &&to, uint64_t capturedRevision, RecoverySpec spec);
  [[nodiscard]] CompletionEnvelope takeIfCompleted();  // non-blocking at a safe point
  [[nodiscard]] bool inFlight() const noexcept;        // never joined from a safe point
  void joinCompleted();                                   // joining a completed worker is allowed
};
```

## Protocol

1. **Handoff**: owner closes admission, satisfies all four quiescence proofs, transfers authority to one serial worker. Construction and destructive disposal happen only here.
2. **During worker ownership**: the owner keeps serving control/status traffic and honours a newer Battery/Shutdown intent immediately; an in-flight worker is **never joined** from a native safe point.
3. **Snapshot observation**: while the worker (or a parked envelope) holds authority, lifecycle state is read from immutable detached snapshots that cannot expose partially transferred residency (FR-007).
4. **Completion**: the worker places candidate + lease + revision in one envelope, wakes the transport (existing `lifecycleWake`), and afterwards **no worker-local object or destructor may touch transferred resources** — including captured callbacks.
5. **Claim**: at a safe point the owner re-inspects the current revision. Current → adopt (see adoption contract). Stale → return the candidate intact for worker-side/candidate disposal and reap it **before** eligibility reporting returns, **outside** `recoveryMutex_` (FR-012).
6. **Cancellation**: revision-fenced and cooperative. The worker's final pre-install cancellation check is required but explicitly not sufficient; revision fencing plus owner-side stale reaping is the correctness mechanism.
7. **No overlap**: no build operation and no disposal operation may be in flight simultaneously; the single worker plus the lease enforce this.
8. **Shutdown**: terminal. Bootstrap teardown first invalidates recovery intent, then waits for its **completed** worker; power-observer teardown precedes Bootstrap teardown so OS callbacks cannot outlive the lifecycle object they wake (FR-013). Completed private work must not become residency merely because it finished after shutdown won.

## Prohibited implementations

| Temptation | Why rejected |
|---|---|
| Worker publishes lifecycle truth, effective context or admission | FR-005; would create a second lifecycle owner (constitution III) |
| Owner joins an in-flight worker to "simplify" sequencing | blocks control responsiveness and violates FR-006; Battery/Shutdown could not be honoured mid-load |
| Returning `Idle` before reaping a completed stale candidate | battery-memory leak: private residency survives because the newer intent is not AC (FR-012, constitution XI) |
| Destroying the stale candidate under `recoveryMutex_` | large re-entrant lifetime boundary under a coordination lock (constitution III) |
| Worker captures `Engine`/`RuntimeModel`/package references in its wake closure | retention of exactly what must be released (constitution XI); `lifecycleWake` must be residency-free (`Bootstrap.hpp` comment on `lifecycleWake`) |

## Verification obligations (deterministic)

| Gate | Proof | Seam (provenance) |
|---|---|---|
| 4 — handoff & retirement | worker in flight; status/health/metrics/`/v1/models` + Battery + Shutdown injected mid-flight; control answers, no join, receipts reach zero | `[P]` bootstrap test seam (the `[D]` `RuntimeBootstrapTestAccess` draft must be (re-)introduced as planned work) + `[U]` `FdTransport` control notifier |
| 5 — cancellation & stale disposal | completed stale candidate with newer non-AC revision; assert reap precedes the eligibility return and no residency is retained | `[P]` test-only builder hook + residency-occupancy assertion |
| 7 — no overlap | instrumented builder that fails if a second build or a concurrent disposal starts | `[P]` test-only builder hook |
| 8 — shutdown racing recovery | shutdown during Building; assert terminal, later power ignored, candidate reaped | `[P]` shutdown pump + `[P]` test seam |

**Evidence is owed at the owning workstream**: Gate 4's handoff/responsiveness tests belong to WS D and Gate 5/7/8's candidate tests to WS E; each must pass there before dependents start (plan.md "Per-workstream evidence owed"). Gate 4 additionally depends on WS C's receipt primitives (U-01) and KV-tier witness (U-02).

Unresolved: **U-04** (owned by WS B/D) — with no `Engine`, the model-less wakeup source for a parked-but-deferred persistence deadline must still bound `FdTransport`'s poll; specify the merge rule and prove it at the transport level.
