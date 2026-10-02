# Contract: Engine Detach / Adoption and Transactional Rollback

Covers 003 FR-003, FR-010, FR-011, FR-014, FR-015, FR-019; constitution II, IV, V, VII. Referenced from `plan.md` workstreams B/D/E and `data-model.md` §1, §3.

## Source facts (provenance-tagged: `[U]` clean HEAD `a8a74e6`, `[S3]` stage 3 only, `[D]` auto-merged draft, `[P]` proposed)

| Fact | Provenance | Source |
|---|---|---|
| `NativeRuntime` is the long-lived protocol/control shell owning only the currently published `Engine`; `Engine` construction binds valid non-null `Cache&`/`Model&` | `[D]` wording and surface; the underlying `core_` ownership is `[U]` | working tree `runtime/engine/NativeRuntime.hpp` |
| Adoption without consuming on rejection: `tryPublishEngine(std::unique_ptr<engine::Engine>&)`; also `publishEngine`, `destroyEngine`, `hasEngine` | `[D]` — absent at HEAD; re-derived as `[P]` | working tree `runtime/engine/NativeRuntime.hpp` |
| Upstream `NativeRuntime` holds `std::unique_ptr<engine::Engine> core_` and calls through it unconditionally (`observePrefill`, `statusSnapshot`, `weightsSnapshot`, `reclaimMemory`, `expertGrowthBytes`, `growExperts`, `releaseIdleWeights`) | `[U]` | `runtime/engine/NativeRuntime.hpp` |
| Residency-adjacent surface that must become residency-conditional: `NativeLoopConfig::weights`, `weightAdmission`, `growthAdmission`, `WeightsSnapshot`, `idleSinceMilliseconds_`, `restoreStarted_` | `[U]` | `runtime/engine/NativeRuntime.hpp` |
| Bootstrap reverse-destruction residency ordering `Engine → RuntimeModel → ModelPackage → base`, `RecoveryCandidate` destructor | `[D]` | stage-3 draft merged into the working tree |
| Retained machinery the borrower reaches: `engine::Cache`, `StateCache::acquireDeepest`, `Cache::adopt`, `adoptPersistentCache()`, `beginServing()`, `closePersistentCache()` | `[U]` | `runtime/engine/StateCache.hpp`, `runtime/engine/RuntimeResources.hpp` |
| `Engine::flushRestorePoints()` is the clean-stop flush entry | `[U]` | `runtime/engine/Engine.hpp:334` |
| Bootstrap friend test seam `RuntimeBootstrapTestAccess` | `[D]` — **absent at HEAD** (HEAD `Bootstrap.hpp` declares no `friend class`); introducing it is planned work with its own test | working tree `runtime/engine/Bootstrap.hpp` |

## Required interface (proposed)

```cpp
// [P] the disposable stratum: move-only, never default-constructible-empty.
class ModelResidency {
public:
  model::ModelPackage       package;     // weight images, mapped regions
  model::ExpertStoreHandle  experts;     // streamed routed experts (if any)
  model::SparseRowStoreHandle ple;       // streamed PLE table (if any)
  engine::ReleasableMemoryHandle releasable; // parts over images/experts/ANE program
  ops::AneFfnResidencyHandle  ane;       // program + prefill arena residency
  std::unique_ptr<model::RuntimeModel> model;
  std::unique_ptr<engine::Engine> engine;
  // ordered teardown, asserted by the type:
  // engine → model → ane → releasable → experts/ple → package
};

// [U→P] shell surface, residency-conditional:
void publishEngine(engine::Cache &cache, model::Model &model);
[[nodiscard]] bool tryPublishEngine(std::unique_ptr<engine::Engine> &candidate);
void destroyEngine();
[[nodiscard]] bool hasEngine() const noexcept;
```

## Obligations

### Detach (suspension)
1. Two independent drain barriers hold first (see the authority contract); then destruction order is `Engine → RuntimeModel → residency`, with the retained graph and generation alive.
2. Model-dependent bindings are **undone** before residency is destroyed: `Engine::setCompletionNotifier`/`NativeRuntime::setCompletionNotifier` closures, Cache/StateCache hooks that reach the Engine, `ReleasableMemory` part pointers, ANE bindings, `ReleasableMemory`-driven `releaseIdleWeights`/`growExperts`/`reclaimForExperts` paths, streamed-store readers and execution-plan bindings, shared readers.
3. Status after detach reports physical absence of ModelPackage/RuntimeModel/model telemetry, separately from retained Cache/KV/state accounting (FR-019, constitution VII). Historical startup/warmup values must not be reused as live values.

### Adoption (recovery)
4. Candidate construction is private and off the safe point; adoption happens only on the owner thread with the lease returned.
5. **Cold-first** candidate temporarily owns `RuntimeResources`; teardown order `Engine → RuntimeModel → ModelPackage → candidate-owned RuntimeResources`; on success the same graph is **transferred** into Bootstrap, never rebuilt.
6. Rollback on refusal or failure restores, in the pre-adoption configuration: pointers **and** altered callbacks, notifiers, Cache/StateCache bindings, and the shell's residency-conditional state (FR-010). Afterwards no live component borrows from destroyed or half-published state, and the candidate is destroyed in order.
7. Stable addresses: adopted bindings point at the same retained objects that existed before suspension (FR-015); no retained object is re-created to make adoption convenient.

### Two-phase publication
8. Phase 1 (physical): transfer residency, adopt the exact Engine, publish the resolved effective context — admission **closed**, lifecycle `Recovering`.
9. Phase 2 (fence): re-check revision/power; only a still-current AC revision may set `inferenceReady` and open the gate. A Battery landing between phases leaves the gate closed and the just-published residency releasable by ordinary subsequent suspension (FR-011).
10. Effective context is taken from the adopted Engine itself, never from startup/warmup reports (FR-023).

### Newer-AC-after-committed-release reconciliation
11. When a Battery revision has passed the last pre-release fence, residency is destroyed, and a newer AC observation arrives before the stale release announcement: reconcile the current AC revision to a **closed, model-less `Suspended`** state and let the ordinary fenced recovery path rebuild. Do not reopen admission directly, do not resurrect destroyed objects synchronously, do not broaden `Draining` into a generally recoverable state, do not publish the stale announcement (FR-014).

## Prohibited implementations

| Temptation | Why rejected |
|---|---|
| Making `Cache&`/`Model&` nullable/rebindable to keep `Engine` embedded in the shell | weakens an existing invariant and hides the residency boundary |
| Rolling back only moved pointers | FR-010 explicitly requires callback/binding rollback; half-published bindings are the historical failure mode |
| Adopting then marking ready in one step | race with Battery in the gap (FR-011) |
| Rebuilding `RuntimeResources` during recovery | destroys retained identity and replays prefix work (FR-015, 001 FR-019) |
| Reusing crash/child-replacement teardown as the suspension path | constitution IV: resumable vs destructive paths differ; retained backing is process-local |

## Verification obligations

| Gate | Proof | Seam (provenance) | Status |
|---|---|---|---|
| 6 — refused/failed adoption | adoption refuses; assert callbacks/notifiers/bindings restored, candidate destroyed in dependency order, no live borrower | `[P]` adoption surface + `[P]` bootstrap test seam + binding-witness fixtures | owed in **WS E**, before WS F/G rely on adoption |
| 7 — two-phase publication | Battery injected between adoption and fence; gate closed, later suspension releases residency | `[P]` fence seam | owed in **WS E** |
| 12 — static vs effective context | smaller recovered context; ceiling vs effective values; inconsistent inference-ready data fails closed | `[D→P]` status validation + `runtime_status_test.cpp` + `test_status_contract.py` | U-05 approved (in-band `StartEvent.capacityTokens`); gate unpassed until that extension + its test land |
| SC-005 — retained identity actually used | two `Engine` instances over one retained `Cache`; `restoredTokens > 0`, executed prefill == uncached suffix, counted separately | `[U]` `dev/tests/engine/TestExecutor.hpp` `prefillRows` (`:358`), `prefillChunks` (`:359`), `lastRestoredTokens` (`:244,292`) | owed in **WS B/E**; WS G only re-runs it |

No gate above may be credited to WS G's integration suite; the owning workstream's narrow test is the evidence.
