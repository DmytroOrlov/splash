# Contract: Retained State and Prefix Reuse, Restore Integrity

Covers 003 FR-015, FR-018, SC-005, SC-010; constitution V, XI. Referenced from `plan.md` workstreams B/E/G and `data-model.md` §6.

## Current upstream machinery (reused, not re-invented — constitution IX)

Every symbol in this table is `[U]`: verified at clean HEAD `a8a74e6`.

| Machinery | Source | Role across the boundary |
|---|---|---|
| `engine::Cache` (probe/hit/dedup/reuse counters, `adopt`, `keepDiskLimit`, `persist`) | `runtime/engine/Cache.hpp`; counters visible in `status_golden.json`'s `cache` section | KV prefix matching and reuse must be the same object |
| `engine::StateCache`, `CompositeStateLease` (move-only), `acquireDeepest(kvChain)`, `writing()`, `pollOffload()`, `Unwritten {Drop, Wait, Keep, Stay}`, `StateUse {offloads, offloadFailures, pending}` | `runtime/engine/StateCache.hpp:19-291` | CompositeState/GDN/draft boundary reuse; pending-write restriction |
| KV tiers and page storage: `KvPool`, `KvPageTier`, `kv::PageStorage`, `KvBlockCache`, `KvHistoryStream` | `runtime/engine/RuntimeResources.hpp` members + member-order comment | Retained KV pool/tier/backing, spilled-KV readers |
| `model::SlotFile` + `PersistentCacheFiles` + `CacheDirectory` + `persistentCacheNamespace(RuntimeCacheIdentity, CompositeStateLayout)` | `runtime/engine/RuntimeResources.hpp:57-91,392` | Slot-backed state identity; persistent tier takes back what the last process left |
| `RuntimeCacheIdentity { modelLayoutSha256, buildId, kvLayout, ropeScaling, targetModelSha256 }` | `runtime/engine/RuntimeResources.hpp:57-67` | Compatibility proof for retained state against the recovered runtime |
| `model::QwenStateStorage` / `model::QwenState` | `runtime/model/QwenState.hpp` | State storage backing that must survive |
| Test fixtures: `TestExecutor.hpp` — `RestoreControl` (`:142`), `RestoreTicket` (`:151`), `OffloadControl` (`:81`), `OffloadTicket` (`:87`), `OffloadState`, `DiskState`, `KeptState`, `prefillRows` (`:358`), `prefillChunks` (`:359`), `lastRestoredTokens` (`:244,292`), `TestCache.hpp`, `TestKvPool.hpp`, `TestKvTier.hpp` | `dev/tests/engine/` | Deterministic seams for the proofs below |

## Obligations

### Retained identity and actual reuse (FR-015, SC-005)
1. Across suspension the retained `Cache`, KV pool/tier/backing, `StateCache`/CompositeState and `SlotFile` graph keep their **object identity**; the first compatible request after recovery reuses the matching retained KV prefix **with** its composite-state boundary and slot-backed identity, and prefills **only** the uncached suffix.
2. Restored tokens and executed prefill tokens are counted **separately**: `restoredTokens > 0`, executed prefill == uncached suffix tokens only, reproducible across runs (SC-005).
3. Recovery preparation may reload residency and do bounded model-only preparation. It must not issue a synthetic recovery prompt, replay the preserved prefix, or run a full-context warmup.
4. Process-local retained backing (slot-owned scratch/workers) must not be reconstructed by starting a new child: the same process generation must supply it (001 invariant; constitution V's "disk backing alone does not prove survival").

### Compatibility must be proven, else fail closed (constitution V)
5. Retained state carries enough identity (`RuntimeCacheIdentity`, KV layout, RoPE scaling, state layout) to prove compatibility with the recovered runtime; unknown compatibility → cold recovery, still correct (FR-015, SC-010, 001 FR-020/FR-021).
6. Retained state must hold no dangling model/runtime/factory/device ownership after residency is released. Existing cache identity mechanisms are reused; new identity only for an unproven compatibility dimension.

### Restore integrity: transactional and destination-local (FR-018)
7. A retained disk state is an immutable source. Corrupt/truncated payload, cancellation, failed IO or verification failure must never publish partially restored destination state; `FileRestore` verifies before commit and makes finish/cancel ordering linearizable.
8. A failed destination restore may take that request cold while the immutable source stays available for a later attempt; the source is not discarded merely to simplify cold fallback.
9. Do not weaken the payload integrity check or treat "read completed" as "publishable".

### Pending offload is not published warm state (FR-018, 001 invariant)
10. An in-flight asynchronous StateCache offload stays owned for transfer ownership, quota/accounting and completion processing, but must not be obtainable as a reusable `CompositeStateLease` while writing. The restriction belongs at acquisition/publication semantics, not at internal ownership.
11. If the asynchronous write fails, discard the failed disk publication while the matching KV boundary survives, so a later lookup truthfully reports retained KV boundary + no CompositeState + lost state, and cold-falls back without corrupting the source or the retry path.

## Verification obligations

| Gate | Proof | Seam |
|---|---|---|
| SC-005 / Gate "suffix-only prefill" | two `Engine` instances over **one** retained `Cache`: warm prefix in instance 1, release residency, instance 2 around the same graph, serve the compatible request; assert restored > 0, executed == suffix, zero replay/warmup | `TestExecutor::prefillRows/prefillChunks/lastRestoredTokens` + `TestCache`/`TestKvPool` fixtures |
| FR-029 integration | full AC→Battery→AC in one generation: admitted work during transition, control reads while suspended, resumed serving, truthful state at each step | new native integration test in `runtime_bootstrap_test.mm` and a Python lifecycle suite in `dev/tests/server/` |
| Gate 10 | destination restore failure isolation, source still retryable, in-flight offload not obtainable | `TestExecutor::RestoreControl/OffloadControl`, `StateCache::writing()` |
| Identity preservation | object-address identity assertions across the boundary (deterministic, not name/value equality) | `[P]` bootstrap test seam (the `[D]` `RuntimeBootstrapTestAccess` draft must be introduced as planned work) + retained-graph pointer witnesses |

## Prohibited shortcuts

| Shortcut | Why rejected |
|---|---|
| Structurally preserving Cache objects while replaying the prefix | satisfies the label, destroys the property (SC-005, 001 SC-011) |
| Discarding the retained source after one failed restore | breaks retryability (FR-018, constitution V) |
| Hiding a pending offload entry to "prevent" reuse | breaks transfer ownership, quota/accounting and completion processing; restriction belongs at acquisition semantics |
| Reconstructing process-local backing in a replacement child | loses process-local identity; also emits a second `ReadyEvent` (FR-022) |
| Judging compatibility by disk file presence alone | constitution V: disk backing alone does not prove survival across a lifetime boundary |
