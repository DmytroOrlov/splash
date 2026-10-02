# Research: Upstream Battery Parity Migration (003)

Scope discipline: everything below is a **decision already taken** (with its rationale and the alternatives that were rejected), or a **genuinely unresolved implementation detail**. No re-run of the architecture investigation; no restatement of 001/002 behaviour; no open design questions are left implicit.

Decision ids are referenced from `plan.md`, `data-model.md` and the contracts.

---

## D-01 — Migration, not redesign, of the three strata

**Decision**: Keep the stratum contract exactly as `REBASE_HEAD` states it (control generation ⊃ retained graph ⊃ disposable residency) and re-express it on upstream ownership. The retained stratum keeps the existing class `RuntimeResources`; the disposable stratum becomes a new move-only owner type; `Engine`/`RuntimeModel` borrow the retained stratum.

**Rationale**: constitution IX (reuse existing abstractions whose semantics match) plus 003 FR-003. Upstream `RuntimeResources` already owns the whole graph exactly once with a documented reverse-destruction order; renaming or duplicating it would create a parallel abstraction (constitution IX violation) and would silently break `adoptPersistentCache()`/`beginServing()`/`closePersistentCache()` probation semantics that belong to the retained stratum.

**Alternatives rejected**: (a) Reverting to the historical shape where `ModelPackage` lives inside the base graph — retains the weight residency Battery exists to release (001 invariant, constitution XI). (b) Keeping `Engine` permanently embedded in `NativeRuntime` with nullable/rebindable `Cache&`/`Model&` — weakens a useful upstream invariant and would hide the residency boundary. (c) Making "suspension" a child restart — destroys process-local `SlotFile` backing and produces a second `ReadyEvent` (003 FR-022; the server treats a second per-generation announcement as fatal).

---

## D-02 — The stage-3 `ModelPackageResidency` wrapper is not the ownership answer

**Decision**: Do not transplant `ModelPackageResidency`/`takeModelPackageResidency()` (which the working tree shows only because stage 3 auto-merged into `runtime/engine/RuntimeResources.hpp`). Re-derive the disposable owner from what upstream actually keeps in the graph: `model_` (`model::LoadedModel`), `readers_` model streams, `operators_` model bindings, `aneFfn_` program residency, `releasableMemory_`.

**Rationale**: upstream `ReleasableMemory` is constructed *over* the weight images, the streamed expert store and the ANE program (`runtime/engine/ReleasableMemory.hpp` class comment; its `parts_` are `model::WeightMemory *` plus a `Split`). Any split that leaves `releasableMemory_`, `readers_` or `aneFfn_` in the retained graph keeps exactly the resources Battery must release — a constitution XI failure that a wrapper class name would disguise.

**Alternatives rejected**: (a) Accepting the auto-merged wrapper as sufficient (it moves only the package object). (b) Making every model-dependent member `std::optional` in place of a distinct owner type (constitution II: check-then-act ownership rather than explicit lifetime).

---

## D-03 — Stable addresses for objects borrowed by `Engine` and `RuntimeModel`

**Decision**: A recovery candidate binds to the *existing retained objects at their existing addresses*. Adoption transfers pointers that were captured against the retained graph; it never re-creates retained objects. Rollback restores the pre-adoption bindings — callbacks, completion notifiers, `Cache`/`StateCache` hooks — not only moved pointers.

**Rationale**: 003 FR-010 requires rollback of modified callbacks, notifiers and Cache/StateCache bindings. Upstream `Engine::setCompletionNotifier`, `NativeRuntime::setCompletionNotifier`, `StateCache` (`acquireDeepest`, `pollOffload`, `writing()`) and `Cache::persist`/`WriteBehind::published` wiring are the concrete binding sites that a candidate install mutates.

**Alternatives rejected**: re-installing retained objects into a candidate (`RuntimeResources` rebuild on recovery) — destroys retained identity (FR-015) and re-does prefix work (001 FR-019/SC-011).

---

## D-04 — Exclusive execution-authority handoff (lease), not a mutex

**Decision**: A move-only `ResourceDomainLease` with states `Owner → Worker → Parked → Owner`, accepted as a witness parameter by operations that mutate the disposable stratum and the affected retained storage (MetalBackend submit/allocate, `MemoryGovernor`, destructive/allocating KV/StateCache ops). The native owner holds authority during serving and draining; exactly one serial residency worker takes it for construction and destructive disposal; a parked completion envelope can hold it between worker completion and owner claim.

**Rationale**: `MetalBackend` permits exactly one submitting/allocating thread and allows only one submitted-but-not-applied command (`runtime/metal/MetalBackend.hpp:391-393`); `MemoryGovernor` is explicitly unsynchronized (`runtime/engine/MemoryGovernor.hpp:184`: it hands a caller a short-lived byte reservation). A mutex serializes calls but cannot prove the *quiescence* precondition, cannot prevent a second caller from acting on a half-drained stratum, and would put expensive work under a coordination lock (constitution III). The lease makes single-ownership a compile-time-shaped constraint and makes "who may act now" observable in status.

**Alternatives rejected (materially)**:
- **Ordinary mutex / atomic flag**: mutual exclusion ≠ happens-before + retirement; it cannot express "worker holds authority, therefore retained due-work is deferred", and it invites check-then-act (constitution II).
- **Synchronous owner-thread recovery**: model load + ANE preparation block the transport; Battery/Shutdown intent could not be honoured mid-flight and status would stall (003 US-3, FR-006, 001 invariant "recovery construction stays off the native safe-point thread").
- **Child replacement**: new generation, new `ReadyEvent`, lost process-local backing; forbidden by FR-022/001.
- **Idle weight release as the Battery mechanism**: `ReleasableMemory` releases weight *parts* while the engine stays alive and re-takes them on demand; it does not destroy `Engine`/`RuntimeModel`/package, is driven by idle timing (not power), and is upstream-only behaviour that must stay unchanged (FR-021, constitution IV).
- **Battery-time `WriteBehind::flush()`**: `flush()` steps every waiting point *newest-first, due or not, whatever the write budget* (`runtime/engine/WriteBehind.hpp` comment + `Cache::liftDiskWriteBudget`). Using it at Battery would reorder publication and bypass the budget — precisely what FR-016/017 and SC-009 forbid.

---

## D-05 — Persistence intent belongs to the retained graph

**Decision**: `WriteBehind` (upstream `runtime/engine/WriteBehind.hpp`, currently a member at `runtime/engine/Engine.hpp:903`, reported through `EngineSnapshot::writeBehind` at `:220`, driven by `Engine::flushRestorePoints()` at `:332`) moves to the retained graph, borrowed by `Engine`. During Battery suspension, due work executes whenever the native owner holds the lease and the operation is safe; it is deferred while the worker or parked envelope holds authority. Wakeup scheduling becomes model-less so `WriteBehind::nextWakeup()` still reaches `FdTransport` with no `Engine` present.

**Rationale**: FR-016/017 and SC-009: pending points and dedup state (`waiting_`, `queued_`), absolute due times, publication order, disk budgets (`stalled_` + budget), stalled accounting and clean-shutdown flush semantics must survive the boundary. Those fields are per-graph, not per-Engine; keeping them in `Engine` would drop queued intent when residency is destroyed.

**Alternatives rejected**: (a) Flushing at suspension (D-04's rejection). (b) Dropping queued points and re-discovering them after recovery (loses ordering and counters). (c) Keeping `WriteBehind` in `Engine` and re-adopting points post-recovery (changes due times; cannot prove counters match the baseline).

---

## D-06 — Two independent drain barriers, each with its own proof

**Decision**: Destructive release requires (1) inference/request quiescence — evidenced by `Engine::idle()`, `Engine::inFlight(requestId)` (`Engine.hpp:873`), `NativeRuntime::commandInFlight()` plus the new per-category retirement receipts — AND (2) retained-state IO quiescence — evidenced by `StateCache::writing()`/`pollOffload()` and KV-tier transfer state. `NativeRuntime::destroyEngine()` may still refuse when its own ownership evidence says work remains. No sleeps, no substitution of one barrier for the other.

**Rationale**: FR-008/FR-009, 001 SC-001…SC-002, constitution X. `Engine::idle()` alone does not prove Cache/StateCache preservation work finished; drained high-level state does not override lower-level live tickets, masks, telemetry or restore ownership.

**Alternatives rejected**: a single "quiescent" boolean (masks the two independent proofs); a bounded wait/sleep (forbidden as evidence).

---

## D-07 — Two-phase publication with a final revision/power fence

**Decision**: physical adoption (transfer disposable residency, adopt the exact `Engine`, publish effective context) happens with admission **closed**; only a final fence on the same AC revision may then set `inference_ready` and open the gate. If Battery lands between the phases the gate stays closed and the just-published residency is released by ordinary subsequent suspension.

**Rationale**: FR-011; 003 US-4 scenario 4 (newer AC racing an already-committed release) and 001's publication invariants. Upstream's server rejects a second readiness announcement, so an optimistic "publish and mark ready" would be unrecoverable.

**Alternatives rejected**: single-step publish-and-ready; reopening admission directly during the newer-AC reconciliation (forbidden by FR-014); broadening `Draining` into a recoverable state.

---

## D-08 — Stale candidate reaping before eligibility, outside the coordination lock

**Decision**: `advanceRecovery` consumes/reaps a completed candidate *before* returning merely because the current lifecycle is Battery/Unknown/Shutdown. Destruction happens outside `recoveryMutex_`. The worker's final cancellation check is required but never treated as sufficient.

**Rationale**: FR-012 and the `REBASE_HEAD` battery-memory-leak note: on cold-first recovery a stale candidate can own an entire private `RuntimeResources` graph. Destroying that under the lifecycle mutex hides a large, re-entrant lifetime boundary under a short coordination lock (constitution III).

**Alternatives rejected**: returning "not eligible → Idle" first (reintroduces the leak); destroying under `recoveryMutex_`.

---

## D-09 — Shutdown is terminal; teardown order is fixed

**Decision**: Shutdown supersedes Draining/Suspended/Recovering; power observations and completed candidates cannot reopen it; Bootstrap teardown first invalidates recovery intent, then waits for its already-completed worker; power-observer teardown precedes Bootstrap teardown.

**Rationale**: FR-013, constitution IV, 001 FR-024. An OS power callback must not outlive the lifecycle object it wakes.

**Alternatives rejected**: reversing teardown order; treating shutdown as another suspend phase.

---

## D-10 — Three distinct context values, with the `ReadyEvent` meaning shift evaluated rather than asserted

**Decision**: keep exactly three context notions and their sources:

| Value | Meaning | Where it is read |
|---|---|---|
| configured ceiling | static pre-residency capability | `ReadyEvent.maxContextTokens` (`runtime/engine/Protocol.hpp:239-246`), `/v1/models` (`server/server.py:594-595`) |
| effective serving context | the published `Engine`'s resolved context | lifecycle status `effective_context_tokens` (schema document only) |
| per-request capacity | the capacity of the exact `Engine` that served that request | **approved: explicit in-band `StartEvent.capacityTokens` field, carried with a coordinated `PROTOCOL_VERSION` bump (U-05)** |

The decision covers the *semantics* (which value is which, and the fail-closed rules) and, per the authoritative `REBASE_HEAD` commit message ("`StartEvent capacityTokens` is per-request telemetry and must follow the currently published Engine, not the historical `ReadyEvent` ceiling. Engine adoption therefore updates NativeRuntime's request-telemetry context only after that exact Engine is successfully published"), the wire mechanism for the third row is now **approved**: an explicit in-band `StartEvent.capacityTokens` field added by a coordinated binary event extension (U-05). The earlier status-lookup-at-request-issue-time alternative is rejected — it does not establish the original `StartEvent` contract and risks attributing the wrong capacity to a request across recovery transitions. The coordinated change preserves the upstream 16-byte frame header and every existing event field and behaviour; the historical 24-byte header and v7 framing are NOT restored. The JSON status-schema decision stays independent (no schema bump for optional fields).

**Consumer evidence for `ReadyEvent.maxContextTokens` at clean HEAD** (the meaning shift is a compatibility question because upstream uses this one value for everything):

| Consumer | Upstream use | Effect of the meaning shift |
|---|---|---|
| `server/server.py:1834-1836` | validates the announced value against `--max-context`, else `1 <= value <= MAX_CONTEXT_TOKENS`, and calls the engine "invalid context window" on mismatch | Under 001's contract the value is the *configured* ceiling, so this check stays valid (it compares against configuration) — but it must stop being used as the serving limit |
| `server/server.py:1841` | `effective_context = readiness.max_context_tokens` → passed to `Frontend` as its budget and context-error limit | **This is the real change**: upstream conflates ceiling with effective context. Budgeting must stay ceiling-based; request-limit decisions must move to the status-borne effective value |
| `server/runtime.py:1183-1187` | cross-relaunch equality check on `(max_context_tokens, max_concurrent_requests, vision)` | Stays valid (the static tuple is static by definition) |
| `server/server.py:1817` | `relaunch_command=lambda first: _native_command(args, model_root, first.max_context_tokens)` → the relaunch context upstream feeds `RuntimeResourcesConfig::relaunchContext` | Must keep feeding the value appropriate for a *child relaunch*; note Battery recovery is not a relaunch, so this path is untouched by suspension |
| `server/frontend.py:242/296/403-405/707-708/773-774/1216-1218` | one `max_context` used for both budgeting and `ContextLengthError` thresholds | Splits into static ceiling vs effective context (003 FR-023) |

**Rationale**: 001's own contract states that the effective value "travels only through lifecycle/status, never through the readiness handshake" (`specs/001-battery-aware-suspension/contracts/control-readiness-and-lifecycle-status.md:91`) while also warning "unless implementation evidence forces a protocol version change, the existing frame is the design" (`:11`) — so the frame choice is evidence-gated, not decreed. Constitution VIII requires request-local attribution only when provable.

**Alternatives rejected**: making `ReadyEvent` dynamic; emitting another `ReadyEvent` after recovery; deriving effective context from the startup/warmup report; collapsing frontend budgeting and context-error thresholds onto one value; and deriving per-request capacity from a status lookup at request-issue time (does not carry the exact serving Engine and can misattribute capacity across recovery transitions).

## D-11 — Model-less cold start vs warm suspension remain distinct states

**Decision**: Cold Battery/Unknown startup builds only the control shell: no `RuntimeResources`, no package, no `RuntimeModel`, no `Engine`, no synthetic retained cache, no recovery warmup or prefix replay. The first valid AC transition constructs the retained graph privately inside the candidate, which then owns it (destruction order `Engine → RuntimeModel → ModelPackage → candidate-owned RuntimeResources`) and whose graph is transferred on successful publication, not rebuilt.

**Rationale**: 001 FR-014, 003 FR-003/FR-010 and the `REBASE_HEAD` cold-vs-warm note. Borrowers (`Engine`, `RuntimeModel`) must never point at destroyed or half-published resources.

**Alternatives rejected**: prebuilding the graph on Battery to make code paths symmetric (defeats the memory-release goal); letting Bootstrap own the cold graph while the candidate borrows it (adoption cannot then be transactional).

## D-12 — Compatibility axes: status schema and wire protocol are separate

**Decision**:

1. **Framing**: the 16-byte header (`kFrameHeaderBytes = 16`) and existing event functionality are preserved; the historical patch's 24-byte header and v7 framing are not migrated. Nothing here depends on the numeral `11`.
2. **Status schema axis**: `kStatusSchemaVersion` (`Protocol.hpp:25`, `server/protocol.py:22`) is bumped only when an existing JSON field's name, type, unit or semantics changes. Purely additive optional fields neither require nor forbid a bump, provided no existing field changes, both native and Python readers tolerate absence and ignore unknowns, and `dev/tests/engine/status_golden.json`, `dev/tests/server/test_status_contract.py`, `server/metrics.py`'s `PROMETHEUS_SERIES` and `dev/tests/native_peer.py` move in the same change. This rule is about JSON document compatibility; it says nothing about `PROTOCOL_VERSION`.
3. **Wire protocol axis**: `PROTOCOL_VERSION` (`Protocol.hpp:21`, `server/protocol.py:18`) is bumped whenever a message's *binary layout* changes — including any new or removed field inside a fixed packed frame such as `StartEvent` (`server/protocol.py` `_START.pack/unpack`) — and the bump must land simultaneously in the native codec, the Python codec, validators, `dev/tests/engine/protocol_golden.txt`, `status_golden.json` and `native_peer.py`. A bump is **permitted by FR-020** ("a coordinated protocol-version extension where one is necessary") and is chosen or refused only on evidence about consumers, never on the bare preference for keeping 11.
4. The two axes are independent: an additive status field set can leave both at 6 and 11; a `StartEvent` field addition forces a protocol bump with no schema bump.

**Rationale**: FR-020 permits a coordinated extension while forbidding behaviour change; the repository pins schema 6 in three independent places and pins the wire layout in two codecs plus goldens, so conflating the axes either breaks consumers or hides a real incompatibility.

**Alternatives rejected**: bumping the schema merely because optional JSON fields appear; shipping new fields without a rule; forbidding a protocol bump in advance (would silently force a *same-version* layout change, the worst outcome); assuming a protocol bump is free (both codecs and both golden sets must move together).

## D-13 — Public CLI chain is restored in-tree, not deferred

**Decision**: `--pause-on-battery` is restored end-to-end: `install/launcher.py` (public option + help + exact forwarding) → `server/serve_options.py` (shared serve option) → `server/server.py` (`parse_args`, child argv assembly) → `runtime/engine/NativeArguments.{hpp,cpp}` (`parseNativeArguments`) → native Battery policy in `runtime/main.mm`. Default-off; opt-in only; 002 stays Reopened / Not Accepted.

**Rationale**: 003 FR-004 forbids deferring the public CLI. Historical stage 3 parsed the flag inline in `main.mm` (`f9f4eb3a:runtime/main.mm:236`); upstream owns native CLI parsing in `NativeArguments`, so inline parsing must be migrated, not duplicated.

**Alternatives rejected**: native-side-only gate (FR-004 violation); keeping parsing in `main.mm` (forks upstream CLI ownership; two parsers).

## D-14 — Same-revision lifecycle ordering needs an explicit observation sequence

**Decision**: Python lifecycle state is ordered by a three-part tuple, applied strictly-greater: `(processGeneration, lifecycleRevision, observationSequence)`. `observationSequence` is a monotonic per-generation counter published by the native lifecycle owner on every lifecycle publication (admission closure, drain progress, suspension, recovery phases, reconciliation) and carried in the status document as an additive field under the D-12 status-schema rule. Python ignores a completion whose tuple is not strictly greater than the last applied one, and never infers order from HTTP arrival order.

**Why the two-domain rule is insufficient**: a single revision spans several phases — one Battery revision covers `Draining → Suspended`, one AC revision covers `Recovering → Ready`, and the newer-AC reconciliation moves `Draining → Suspended` without a new revision. Within one revision, two status completions can therefore be out of order, and the revision rule treats them as equal.

**Fallback rule (compatibility allowance, not a substitute)**: when the producer does not publish `observationSequence` (older native build), Python may fall back to the strict order of *its own status-request issue sequence*, provided the native side never publishes an older snapshot for a later-issued request. That precondition is asserted by a native-side test rather than trusted.

**Rationale**: constitution VI (stale automatic work must not overwrite newer authoritative intent; revisions, generations, ownership tokens "or an equivalent explicit mechanism"). `server/runtime.py` already keys completions by generation (`RuntimeCall.generation`), and `server/backend.py:501` caches decoded status events, so ordering must be decided where the snapshot is applied.

**Deterministic coverage required**: same generation, same revision, two completions delivered in reverse issue order → the newer phase survives; and the reverse-order case across a revision boundary → revision rule dominates; and an old-generation completion arriving after a replacement child is live → discarded.

**Alternatives rejected**: relying on HTTP completion order (it is transport order, not native observation order); a monotonic phase *ordinal* per state name (phases are not globally monotonic — `Recovering → RecoveryFailed → Recovering` spans revisions); client-side wall-clock comparison (constitution X forbids timing as evidence).

## D-15 — Baseline evidence must come from the clean commit, not the conflicted tree

**Decision**: upstream baseline evidence is produced from clean HEAD `a8a74e6` only, via a **read-only extraction outside the repository**: `git archive a8a74e6 | tar -x -C "$BASELINE_DIR"` (`git archive` writes solely to stdout; nothing in the working tree, index or rebase state changes), or by reusing verified CI evidence for that commit. Three distinct trees are named consistently across the plan: **clean upstream HEAD** (baseline comparison), **the current conflicted working tree** (migration workspace, not buildable, never a test subject), and **the eventually resolved tree** (implementation and regression evidence).

**Rationale**: the working tree contains unresolved conflict markers in production and test files, so any "baseline" measured on it is meaningless and would poison every "unchanged" claim in FR-020/FR-031/SC-008. Constitution XII requires claims to be derived from a real checkout.

**Constraints honoured**: no `git checkout`, `git worktree add`, `git reset`, `git stash`, branch switching or rebase continuation; the extraction never runs during this planning step.

**Alternatives rejected**: running baseline suites in the conflicted tree (invalid); `git worktree add`/`git checkout` (mutates repository state, forbidden by the rebase-protection rule); inferring the baseline from the CI log without recording which commit it came from.

## Test-migration decisions

**Decision (T-1)**: For every conflicted test file, migrate by union: keep upstream registrations and re-home Battery cases onto current fixtures (`TestChecks.hpp`, `TestExecutor.hpp`, `TestStatus.hpp`, `TestCache.hpp`, `TestAdmission.hpp`, `ProtocolPeer.*`, goldens). Concretely: `runtime_bootstrap_test.mm` (upstream ~30 registrations, historical ~79), `runtime_resources_test.mm` (upstream 55), `native_engine_loop_test.cpp` (upstream 119), `runtime_status_test.cpp` (upstream 30), plus the smaller historical additions in `protocol_test.cpp`, `qwen_state_storage_test.mm`, `slot_file_test.cpp`, and the new `native_main_test.mm`. Roughly 39 historical Battery-specific cases must survive; roughly 90 upstream-only cases must not be lost.

**Decision (T-2)**: Deleted historical Python suites (`dev/tests/test_server.py`, `dev/tests/engine/test_server_recovery.py`, `test_protocol_recovery.py`, `test_response_lifecycle.py`) are relocated into their current homes: `dev/tests/server/` (next to `test_runtime.py`, `test_status_contract.py`, `test_native_backend.py`, `test_serve_options.py`, `test_protocol_python.py`, `test_memory_release.py`) and `dev/tests/install/test_launcher.py`. They use `dev/tests/server_fixtures` (`FakeRuntime`, `HarnessTestCase`) and `dev/tests/native_peer.py` instead of the deleted harnesses.

**Decision (T-3)**: The SC-005 proof uses `TestExecutor`'s existing seams — `prefillRows` (`dev/tests/engine/TestExecutor.hpp:358`), `prefillChunks` (`:359`), `lastRestoredTokens` (`:244,292`), plus `RestoreControl`/`OffloadControl` fixtures — with **two `Engine` instances over one retained `Cache`**, counting restored tokens and executed prefill tokens separately. It stays separate from the FR-029 full-lifecycle integration test.

**Decision (T-4)**: Physical Apple Silicon validation is an operator-performed scripted session with archived objective evidence (`quickstart.md`), not a CI hardware runner; deterministic suites remain mandatory and independent (FR-030, SC-003…SC-006).

---

## Genuinely unresolved implementation details

U-01 through U-04 are the remaining genuinely open items; each is scoped to an implementation choice with a required test, and none changes the architecture. Each is a **prerequisite** owned by the workstream named in the last column (plan.md "Per-workstream evidence owed"): it must be resolved there, not deferred to WS G. **U-05 is no longer an open architectural choice**: its mechanism is an **approved design decision** (restore in-band `StartEvent.capacityTokens` with a coordinated protocol bump) that now awaits implementation and verification; **Gate 12 remains unpassed until that implementation and its deterministic test succeed.**

| id | Unresolved detail | What must be decided in implementation (with its test) | Owned by |
|---|---|---|---|
| U-01 | **Retirement receipts do not exist upstream.** No current symbol reports "GPU completion callbacks / host-step `then` closures / engine callbacks not yet retired" as a count at a safe point (`MetalBackend` exposes `commandInFlight()` and ticket destruction waiting; `Engine` exposes `idle()`, `inFlight(requestId)`, `commandInFlight()`). | Define the minimal receipt set (per-category counters + a monotonic retirement witness) on `MetalBackend`/`Engine`, plus the happens-before edge to the lease acquisition. Deterministic test: parked ticket + pending `then` fixture must make handoff refuse, then retire and permit. | WS C |
| U-02 | **Exact retained-IO drain witness for the KV tier.** `KvPageTier`'s transfers are currently only observable through its destructor waiting for transfers (`RuntimeResources.hpp` member comment), not through a queryable "transfers in flight" at a safe point. | Choose between adding a tier transfer-count query or reusing an existing spill/KV-status snapshot (`kvSpillStatus()` is engine-thread-scoped). Must not be substituted by `Engine::idle()`. Test: parked tier transfer → refusal. | WS C |
| U-03 | **Whether an additive status field set can stay at schema 6 for the *physical-absence* representation.** `Status.cpp`'s inference-ready validation exists in the merged tree, but the detached "model absent" representation (absence of ModelPackage/RuntimeModel/model telemetry reported separately from retained Cache/KV accounting) has no confirmed upstream field shape. | Decide the field shape for model-less status (distinct null/absent markers vs. omitted keys) under D-12 rule 2, and pin it in `status_golden.json`, `test_status_contract.py` and `metrics.py` in one change. | WS F |
| U-04 | **Model-less wakeup arithmetic.** With no `Engine`, `millisecondsUntilNextWakeup()` must fold `WriteBehind::nextWakeup()` (plus any deferred-work deadline) into the transport's poll bound; upstream only asks the engine. | Decide the merge rule (min of present sources; unbounded when none) and prove it with a transport-level test that a Battery-parked graph still wakes for due persistence work and for a completion landing. | WS B/D |
| U-05 | **APPROVED design decision — awaiting implementation and verification (not an open architectural choice).** Per-request capacity telemetry is decided: restore an explicit **in-band** `StartEvent.capacityTokens` field carrying the capacity of the exact `Engine` that served that request. The authoritative `REBASE_HEAD` commit message states it directly: "`StartEvent capacityTokens` is per-request telemetry and must follow the currently published Engine, not the historical `ReadyEvent` ceiling. Engine adoption therefore updates NativeRuntime's request-telemetry context only after that exact Engine is successfully published." The earlier status-lookup-at-request-issue-time alternative is rejected because it does not establish the original `StartEvent` contract and risks misattributing capacity across recovery transitions. Implementation is a coordinated binary event extension landing together: native codec (`runtime/engine/Protocol.{hpp,cpp}::encodeStart`), Python codec (`server/protocol.py` `_START`), validators, the `PROTOCOL_VERSION` bump (D-12 rule 3), `dev/tests/engine/protocol_golden.txt`, `dev/tests/engine/status_golden.json`, `dev/tests/native_peer.py` and test fixtures — preserving the upstream 16-byte frame header and every existing event field/behaviour. The historical v7 framing / 24-byte header / `cacheDisposition`+`slotIndex` are NOT restored. The JSON status-schema decision stays independent (no schema bump for optional fields). | Deterministic test (Gate 12): recovery resolves a smaller context and the attributed request capacity follows the published Engine, never the ceiling. | WS E/F |

If U-01, U-02 or U-04 cannot be justified from the checked-out source during implementation, the affected gate must be recorded as BLOCKED rather than satisfied by a higher-level lifecycle test or by an undocumented substitute (plan.md workstream rule + constitution X). U-05's mechanism is already fixed by the `REBASE_HEAD` evidence above; its Gate 12 remains unpassed until the in-band `StartEvent` capacity extension and its deterministic test land.
