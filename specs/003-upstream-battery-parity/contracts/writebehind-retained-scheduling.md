# Contract: WriteBehind Retained Scheduling

Covers 003 FR-016, FR-017, FR-018, FR-021; constitution IX, XI, XII. Referenced from `plan.md` workstream B/E and `data-model.md` §5.

## Current upstream interface (unchanged implementation, changed owner)

`runtime/engine/WriteBehind.hpp` — `[U]` at clean HEAD `a8a74e6`:

| Member | Current semantics (upstream) |
|---|---|
| `published(uint64_t block, uint32_t tokens, double now)` | records a restore point published/reused at that block; nothing in a temporary tier |
| `run(double now)` | steps points that are due, one at a time, in publication order; true when one became durable or was given up; a write it starts wakes the engine when it lands |
| `flush()` | clean stop: steps **every** waiting point, **newest first, due or not, whatever the write budget** (`Cache::liftDiskWriteBudget`); true once none is left |
| `nextWakeup()` | when `run()` next has something to do that no landing write would wake it for (next due point, or when a budget-held step is admitted again) |
| `snapshot()` | `WriteBehindSnapshot { waiting, durable, unneeded, refused }` |
| constants | `kDelayMilliseconds = 10'000`, `kMinimumTokens = 2048` |
| state | `waiting_` deque of `Point{block, due}`, `queued_` dedup set, `stalled_`, `counters_` |

Current ownership: `WriteBehind writeBehind_` is an `Engine` member (`runtime/engine/Engine.hpp:903`), surfaced through `EngineSnapshot::writeBehind` (`Engine.hpp:220-221`) and driven at clean stop by `Engine::flushRestorePoints()` (`Engine.hpp:334`). Existing tests: `dev/tests/engine/persistent_cache_test.cpp` (due/order/budget cases), `engine_test.cpp:10356` (due-time bound).

## Required change (proposed)

1. **Owner moves to the retained graph.** `RuntimeResources` (retained stratum) owns the `WriteBehind` instance; `Engine` holds a borrow (`engine::WriteBehind &`) and keeps its existing status reporting path pointing at the retained counters (FR-019: retained accounting is reported even while residency is absent).
2. **Due-work policy under authority** (FR-017):
   - `Owner` holds the lease and the operation is safe → `run(now)` may execute due work.
   - `Worker` or a parked envelope holds the lease → work is **deferred**: not dropped, not re-timed, not re-ordered; eligible again when authority returns.
   - Deferral must not touch `waiting_` due values, `queued_`, ordering or counters.
3. **`flush()` stays clean-shutdown-only.** It must never be used to advance Battery due-work: it reverses order (newest-first), ignores due times, and lifts the disk-write budget — contradicting FR-016/017 and SC-009.
4. **Model-less wakeup source** (unresolved detail U-04): with no `Engine`, the transport's poll bound must still account for `nextWakeup()` and any deferred-work deadline so that due persistence work executes during a suspended state; the merge rule (minimum over present sources; unbounded when none) must be defined and tested.
5. **Interaction with ownership transfer and shutdown**: a persistence completion that lands while authority has moved must not publish, re-open admission, or make a pending item reusable (003 edge case); shutdown keeps the existing clean-stop sequence — `Engine::flushRestorePoints()` (when residency exists) then retained flush, then `RuntimeResources::closePersistentCache()` (which seals the persistent tier).

## Invariants

| Invariant | Basis |
|---|---|
| Pending points and dedup state survive the boundary | constitution IX (same abstraction, new owner), FR-016 |
| Absolute due times and publication order preserved under deferral | FR-017 |
| Disk-write budget behaviour and counters comparable to baseline | FR-016, SC-009 |
| Stalled state (`stalled_`) accounting unchanged | FR-016 |
| Clean-shutdown flush semantics identical to upstream baseline | FR-016, SC-009 |
| A Battery observation never triggers or substitutes write-through pause (or vice versa) | FR-021, constitution IV |
| No retention of model residency inside the persistence owner | constitution XI |

## Verification obligations

| Gate | Proof | Seam |
|---|---|---|
| 9 — ordering, budgets, deferral | queue due and not-yet-due points; run with `Owner` authority (work executes) and with `Worker` authority (deferred); compare `waiting/durable/unneeded/refused` counters, due values, order and budget-held points against the baseline | existing `persistent_cache_test.cpp` structure + new authority-parameterized cases |
| 3 — retained-IO drain interaction | a point mid-write makes the drain barrier refuse until the write retires | `run()`/settlement witness |
| 8 — clean-stop flush parity | suspend then clean stop; every queued point drains as on the upstream baseline | `Engine::flushRestorePoints` + retained flush |
| 10 — pending offload not published | an in-flight offload is owned for accounting/completion but not obtainable as a reusable lease; a failed write discards the failed publication and the KV boundary survives with truthful loss | `StateCache::writing()`, `Unwritten`, `TestExecutor::OffloadControl` |

## Prohibited shortcuts

| Shortcut | Why rejected |
|---|---|
| Calling `WriteBehind::flush()` at Battery | order and budget semantics change (SC-009 fails) |
| Re-deriving queued points after recovery from cache state | due times and counters cannot match the baseline |
| Keeping `WriteBehind` inside `Engine` and re-seeding on recovery | loses pending intent across the boundary (FR-016) |
| Letting a completion that lands during worker ownership publish state or open admission | violates the observation/publication boundary (FR-005/FR-007) |
