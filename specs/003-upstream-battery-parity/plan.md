# Implementation Plan: Upstream Battery Suspension Parity Migration

**Branch**: `003-upstream-battery-parity` | **Date**: 2026-11-01 | **Spec**: [spec.md](./spec.md)

**Input**: `specs/003-upstream-battery-parity/spec.md` (32 functional requirements, 12 success criteria, no open clarifications)

**Nature of this plan**: an UPSTREAM MIGRATION PLAN. The behavioural contract is fixed by `specs/001-battery-aware-suspension` (FR-001…FR-026, SC-001…SC-012) and the default-off gate by `specs/002-pause-on-battery-flag` (Reopened / Not Accepted). This plan re-establishes that contract on the upstream tree at `a8a74e6` and supplies the evidence that proves parity. It does not design new Battery behaviour.

**Git posture (binding for this step)**: the repository is in an interrupted rebase (`REBASE_HEAD` = `f9f4eb3a` replaying onto `a8a74e6`). This plan is authored **without** touching Git state: no branch switch, staging, conflict resolution, rebase continuation, production-code or test edits. Stage 2 of every conflicted path is the current upstream API surface; stage 3 is the historical Battery behaviour. Implementation of this plan happens in a later, separately authorized step that owns resolving the rebase; nothing here presumes the conflicts are already resolved.

---

## Summary

Battery parity on the current upstream architecture requires three coordinated changes, none of which is a behavioural change to 001's contract:

1. **Ownership split (strata).** Upstream `RuntimeResources` owns every process-wide native resource exactly once, *including* the loaded model, its SSD readers, its `ReleasableMemory` parts and the ANE program (`runtime/engine/RuntimeResources.hpp`, private member block: `model_`, `readers_`, `operators_`, `aneFfn_`, `releasableMemory_`). Parity requires a **retained** stratum (backend, governor, Cache, KV pool/tier/pages, state storage, SlotFiles, persistent-cache directory, disk space, and — moved out of `Engine` — the queued persistence intent) and a **disposable** stratum (model package/weights, streamed stores, ANE residency, `RuntimeModel`, `Engine`, and every model-dependent binding and borrowed address). Suspension releases only the disposable stratum; AC rebuilds only that stratum in the same process generation.
2. **Exclusive execution-authority handoff.** One move-only resource-domain authority token (`ResourceDomainLease`) passes from the native owner to one serial residency worker and back, with asynchronous disposal and construction, immutable snapshots for observation, revision fencing, stale-candidate reaping, two-phase publication and terminal shutdown. MetalBackend permits exactly one submitting/allocating thread (`runtime/metal/MetalBackend.hpp:391-393`) and `MemoryGovernor` is unsynchronized, so mutual exclusion alone is not enough: the plan defines the happens-before edge and the quiescence proof for the migration of authority.
3. **Compatibility restoration, on two independent axes.** Wire framing and status schema versioning are separate decisions; neither implies the other. Current-upstream wire facts to integrate with: `kProtocolVersion = 11`, `kFrameHeaderBytes = 16` (`runtime/engine/Protocol.hpp:21,24`; `server/protocol.py:18,21`) and upstream `StartEvent { requestId, lane, matchedPromptTokens }` (`Protocol.hpp:253-259`, packed/unpacked by `server/protocol.py`). Current-upstream status fact: `kStatusSchemaVersion = 6` (`Protocol.hpp:25`, `server/protocol.py:22`). Consumer expectations of `ReadyEvent.maxContextTokens` are enumerated in research.md D-10 (`server/server.py:1817,1834-1841`, `server/runtime.py:1183-1187`, `server/frontend.py`'s single `max_context`) — upstream today treats that value as the *served* context, so changing its meaning is a compatibility question, not a free rename. The historical patch's 24-byte header, schema-5 status, inline `main.mm` CLI parsing and its different `StartEvent` layout (`f9f4eb3a:runtime/engine/Protocol.hpp:265-273`: `{requestId, cacheDisposition, slotIndex, matchedPromptTokens, capacityTokens}`) must not be transplanted wholesale; a coordinated protocol-version extension is permitted where evidence requires it (FR-020), and the per-request capacity telemetry question is **resolved as an approved decision** (U-05): restore an in-band `StartEvent.capacityTokens` field via a coordinated binary event extension that preserves the 16-byte header and every existing event field, with the corresponding `PROTOCOL_VERSION` bump — not the historical 24-byte header / v7 framing. Gate 12 remains unpassed until that extension and its deterministic test land.

Deliverable evidence: 39 historical Battery C++ tests preserved/adapted, ~90 upstream-only C++ tests not lost by whole-file conflict resolution, deleted Python Battery suites relocated into `dev/tests/server/`, plus deterministic race proofs, a two-Engine-over-one-retained-Cache suffix-only prefill proof, and an operator-performed physical Apple Silicon session.

---

## Technical Context

**Language/Version**: C++20 (`ENGINE_TEST_CXXFLAGS := -std=c++20 -O2 -Wall -Wextra -Werror`, `dev/native.mk:2`), Objective-C++/`.mm` for Metal and macOS adapters; Python 3.12–3.14 (`PYTHON_CANDIDATES ?= python3.13 python3 python3.12 python3.14`, `Makefile:18`).

**Primary dependencies**: Metal / MPS compute (`runtime/metal/MetalBackend.*`, generated `splash.metallib`), Neural Engine ANE service (`ops::AneFfn`, `engine/AneFfnStartup.hpp`), macOS `IOPowerSources` via the historical `engine/PowerSource.hpp` adapter, POSIX pipes (`engine/FdTransport.*`), Python stdlib `http.server`/`argparse`/`unittest` frontend+control plane.

**Storage**: file-backed KV page extents and `model::SlotFile` state files, persistent cache tiers under `RuntimeResourcesConfig::cacheRoot` namespaced by `persistentCacheNamespace()`, disk quota/write budget (`model::DiskBudget`, `--max-cache-disk[-writes]`).

**Testing**: native test binaries built and run by `dev/native.mk` (`make test-engine-cpu`, `test-engine-metal`, `test-sanitizers`, `test-sanitizers-metal`, `test-real`); Python suites discovered from the checkout root — `make test-python` → `python -m unittest discover -s dev/tests -t . -p '<pattern>'` (`dev/Makefile:138-142`); `make check` = `check-source check-native-engine check-python check-app`; CI runs `make check-native-cpu`, `make test-sanitizers`, `make check-python` (`.github/workflows/ci.yml:45-70`). Native assertions use `splash::test::require/check/rejects` from `dev/tests/engine/TestChecks.hpp`; golden fixtures `dev/tests/engine/status_golden.json` and `dev/tests/engine/protocol_golden.txt`.

**Target platform**: Apple Silicon macOS hosts (validation is operator-performed there); hosted CI has no GPU, so Metal-only tests are built, not run, in CI.

**Project Type**: single application: native inference runtime (child process, `build/splash`) + Python HTTP control plane (`server/`) + launcher (`install/launcher.py`).

**Performance Goals**: not a throughput plan. Parity performance claims are bounded to SC-007 (resumed long-prefix latency ≤ 50% of original build time) as *supporting* evidence, never a substitute for SC-005's token-level prefix-reuse proof.

**Constraints**:
- Wire/compat: `kProtocolVersion = 11`, `kFrameHeaderBytes = 16`, `kStatusSchemaVersion = 6`; exactly one `ReadyEvent` per process generation; the server rejects a second per-generation readiness announcement. A protocol-version increment is allowed only as a coordinated change (both codecs, goldens, validators, `native_peer.py`) and is never adopted or rejected on the bare grounds of "keep 11" — see research.md D-12/D-10 and the approved U-05 decision (in-band `StartEvent.capacityTokens`, which forces that bump).
- Concurrency: `MetalBackend` — one thread submits/allocates/looks up pipelines; `checkHealth()/healthy()/unhealthyReason()/memoryStats()/commandInFlight()` may be called from any thread (`runtime/metal/MetalBackend.hpp:391-393`); at most one submitted-but-not-applied command; `CommandTicket` destruction waits for GPU completion (`:301-308`). `MemoryGovernor` is unsynchronized and only hands out short-lived byte reservations (`runtime/engine/MemoryGovernor.hpp:184`).
- Cost: recovery construction (model load, ANE preparation, memory arenas) must stay off the native safe point; no join of an in-flight worker from a safe point.
- Compatibility: additive JSON fields must not bump `kStatusSchemaVersion` without a stated rule (see research.md D-12).

**Scale/Scope**: ~14 conflicted production paths, ~10 conflicted/new test paths, 7 workstreams (A–G), 13 validation gates; no new subsystem beyond the ownership/authority primitives.

---

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design (results in Complexity Tracking note below).*

| Principle | Verdict | How this plan satisfies it |
|---|---|---|
| I. Inference correctness over optimization | PASS | Suffix-only reuse is proven by token accounting (SC-005) and falls back to cold recovery when compatibility is unproven (FR-015/018; 001 FR-020…FR-021). No sampling/batching/cancellation semantics change (FR-020). |
| II. Explicit ownership for concurrent lifecycles | PASS | Strata become explicit types; authority is a move-only token rather than a check-then-act flag; admitted work retains its resources through the drain barriers (FR-005…FR-009). |
| III. One authoritative lifecycle owner | PASS | `RuntimeBootstrap` remains the sole lifecycle owner; `PowerSource` observations only record and wake (contracts/native-control-status-and-protocol.md). No second lifecycle machine or handshake (FR-002, FR-022). |
| IV. Suspension ≠ destructive teardown | PASS | Shutdown is a distinct terminal state; suspension keeps retained identity; crash recovery/child replacement is explicitly *not* a Battery mechanism (FR-013, FR-022). |
| V. Cache reuse requires proven lifetime and compatibility | PASS | Retained Cache/KV/CompositeState/SlotFile identity survives by construction; unknown compatibility fails closed to cold recovery; restore failure stays destination-local and the source stays retryable (FR-015, FR-018). |
| VI. Newer lifecycle intent wins | PASS | Lifecycle revision fencing plus process-generation ordering; stale candidates reaped; stale announcements not published (FR-012, FR-014, FR-024). |
| VII. Model-less control plane is truthful | PASS | Detached snapshots report physical absence of ModelPackage/RuntimeModel/model telemetry; no fabricated live values from the startup report; reads stay passive (FR-007, FR-019, SC-011). |
| VIII. Observability is passive and correctly attributed | PASS | `StartEvent` telemetry follows only the published Engine; static ceiling and effective context remain separate sources (FR-023). |
| IX. Preserve proven architecture | PASS | The split keeps upstream class names/seams where semantics match (`RuntimeResources`, `Engine`, `NativeRuntime`, `WriteBehind` moves owner not implementation; no parallel state machine). `NativeAdmissionGate` and the `RuntimeBootstrapTestAccess` seam are **not** upstream — they are proposed additions (provenance `[P]`/`[D]`, see the key in Source Integration Points) and must not be cited as existing upstream guarantees. |
| X. Concurrency claims need deterministic evidence | PASS | Every gate in the table below is a deterministic seam/ownership observation; zero sleeps as proof; the historical patch's timing-free seams are reused (FR-026, SC-004). |
| XI. Resource release must be real | PASS | FR-025…FR-031 require objective residency absence (OS-level resource read and deterministic seams) with diagnostics/callbacks/`ReleasableMemory`/`SsdReaders`/`then` closures audited for retention. |
| XII. Evidence before architecture | PASS | Class placement, protocol framing and lease mechanics are derived from the checked-out upstream symbols cited below, not from 001's prose or the old class shape. |

No gate violations, so **Complexity Tracking** has no entries. Two items that could look like exceptions are explicitly governed instead of exempted and are recorded as decisions in research.md: D-12 (schema/version compatibility rule, under FR-020) and D-07 (SC-007 latency threshold, already declared non-gating by 003 SC-007).

---

## Technical Approach

### A. The ownership split and where the seams are

The strata and their current upstream owners (verified at `a8a74e6`, and re-checked against the conflicted working tree rather than trusting auto-merge):

| Stratum | Current upstream owner / symbol | Required change |
|---|---|---|
| Control / process generation | `runtime/main.mm` (native loop, `IdleSleepAssertion` at `main.mm:107-111`), `engine/FdTransport.hpp` (`controlNotifier()`, `LoopWake`, `run()`), `engine/Bootstrap.hpp::RuntimeBootstrap::start` (one `ReadyEvent`) | Keep as-is; add a model-less start path. No child replacement. |
| Retained graph | `engine/RuntimeResources.hpp::RuntimeResources` — `backend_`, `memoryGovernor_`, `cache_`, `kvPool_`, `kvTier_`, `kvPages_`, `stateStorage_`, `diskSpace_`, `persistentCache_` (`CacheDirectory` + `model::SlotFile` kv/states), `readers_` (`model::SsdReaders`), probation thread | Remove model residency and model-dependent bindings from it; retain everything else with existing identity. Add the delayed persistence-intent owner (WriteBehind) here (FR-016/017). |
| Disposable residency | currently inside `RuntimeResources` (`model_`, `readers_` model streams, `operators_` model bindings, `aneFfn_`, `releasableMemory_`) plus `Bootstrap::modelResidency_/model_` and `NativeRuntime::core_` | New move-only disposable type owning the model package/weights, streamed expert/PLE stores, ANE program residency, `model::RuntimeModel`, `Engine` and every model-dependent binding; constructed and destroyed only under worker authority. |
| Engine borrow surface | `engine/Engine.hpp` (`submit`, `idle()`, `flushRestorePoints()`, `reclaimMemory`, `growExperts`, `inFlight(requestId)` at `:873`, `WriteBehind writeBehind_` at `:903`, `EngineSnapshot::writeBehind` at `:220`) | `Engine` **borrows** the retained persistence-intent owner instead of owning it; `Engine::flushRestorePoints()` keeps delegating to the retained owner's `flush()` only at clean stop. |
| Idle-weight machinery | `engine/ReleasableMemory.hpp` (parts = weight images, `model::ExpertStore`, ANE program), `NativeRuntime::releaseIdleWeights/releaseWeights/restoreWeights`, `NativeLoopConfig::weights` | Must move with the disposable stratum and be inert (never dereferenced) when residency is absent. Upstream `NativeRuntime::weightsSnapshot()` reads `config_.weights` unconditionally — needs residency-conditional handling. |

**Not-to-do list carried into the plan**: do not transplant the historical `ModelPackageResidency` / `takeModelPackageResidency()` shape (present in the working tree only because stage 3 auto-merged) as the answer: it keeps `ReleasableMemory`, `readers_`, `aneFfn_` and the model's streamed stores in the retained graph, which retains exactly what Battery must release. The historical `ModelPackageResidency` wrapper is a naming artifact, not the ownership design.

**Stable-address requirement**: `Engine` and `model::RuntimeModel` hold references/pointers into retained objects (`Cache`, KV pages, state storage) and model-side objects. Any adopted candidate must bind to the *same* retained addresses; adoption therefore transfers pointers that were captured after the retained graph was created, and rollback must restore the pre-adoption bindings (callbacks, notifiers, Cache/StateCache hooks) — not just re-move pointers (FR-010).

### B. Exclusive resource-domain authority (the concurrency core)

Proposed primitive (contracts/resource-domain-authority.md): a move-only `ResourceDomainLease` held by exactly one of {native owner, one serial residency worker, parked completion envelope}, state machine `Owner → Worker → Parked → Owner`. The lease is the *witness* parameter accepted by the operations that mutate the disposable stratum and the affected retained storage (MetalBackend submit/allocate path, `MemoryGovernor`, KV/StateCache destructive or allocating operations). Because `MemoryGovernor` is unsynchronized and `MetalBackend` allows a single submitting thread, the lease plus explicit quiescence evidence — not a mutex — is the mechanism.

Quiescence before handoff, proven by four independent witnesses (FR-008/FR-009): (1) native admission closed at `NativeAdmissionGate` held through `Engine` submission; (2) request/engine drain, evidenced through existing `Engine::idle()`/`inFlight()`/`commandInFlight()` plus new per-category retirement counters; (3) retained-state IO drain, evidenced by `StateCache::writing()`/`pollOffload()`, KV-tier transfer state and the retained WriteBehind front-point state; (4) callback retirement: Metal command tickets (`MetalBackend` completion callbacks and host-step `then`), ANE service queue drain, GPU completion callbacks, and `Engine::setCompletionNotifier` closures. Upstream does **not** expose the receipts needed for (2)–(4) in the form the proof requires; the plan therefore specifies the receipts to implement and their deterministic tests (research.md U-01, U-02, owned by workstream C).

### C. Model-less control shell, native admission, asynchronous release

`RuntimeBootstrap` grows a model-less start (stage 3 already sketched `startModelLess()`; must be re-derived against the upstream `start()` and `requireWarmupAndAnnounce()`). Cold Battery/Unknown startup builds no `RuntimeResources` graph at all (no synthetic retained cache). Warm suspension preserves the retained graph. `NativeRuntime` remains the protocol/control shell with `publishEngine` / `tryPublishEngine` / `destroyEngine` semantics and `hasEngine()`; while a worker owns the lease, lifecycle reads come from detached immutable snapshots (`engine/Status.hpp::LifecycleStatusSnapshot`, `detachedResourceSnapshot()`).

### D. Private recovery, transactional adoption, stale reaping, two-phase publication

Candidate envelope holds the disposable stratum + (cold-first only) a privately created retained graph, with destruction ordered `Engine → RuntimeModel → ModelPackage → candidate-owned RuntimeResources`. The worker publishes nothing; it hands one synchronized completion envelope (candidate + lease + revision) to the owner. The owner alone: re-checks revision, adopts (physical residency, admission still closed), fences a final time on revision/power, then opens inference admission. Stale completed candidates are reaped *before* eligibility reporting returns, and outside the coordination lock. Newer-AC-after-committed-release is reconciled to a closed model-less `Suspended` state (FR-014). Shutdown is terminal, observer teardown precedes bootstrap teardown (FR-013).

### E. WriteBehind retained policy

`WriteBehind` (upstream: `runtime/engine/WriteBehind.hpp`, owned by `Engine` at `:903`) moves to the retained graph; `Engine` borrows it. Due-work execution continues during suspension whenever the owner holds the lease; work is deferred — not dropped, re-timed or reordered — while the worker or parked envelope holds it. `flush()` stays a clean-shutdown-only operation and must never be used as Battery due-work (it lifts the write budget and iterates newest-first). Wakeup scheduling becomes model-less: `nextWakeup()` must reach the transport even with `Engine` absent (research.md D-05).

### F. Protocol, status, CLI and Python lifecycle

Additive lifecycle fields inside status schema 6 (`control_ready`, `inference_ready`, `configured_context_ceiling`, `effective_context_tokens`, `lifecycle{power,state,...}` — the merged `runtime/engine/Status.cpp:285-360` already emits these; they are an **auto-merged draft** (`[D]`) that must be re-verified against schema 6 and the fail-closed rules, not assumed correct). Status schema versioning is its own axis: additive optional fields neither automatically require nor forbid a schema bump (research D-12).

Wire framing (`kProtocolVersion = 11`, 16-byte header) is preserved as the **default outcome, not as a prohibition**: a coordinated protocol-version increment is permitted where evidence forces it (FR-020), and it is never adopted or rejected on the bare grounds of "keep 11". `ReadyEvent.maxContextTokens` keeps carrying one context value on the wire, but its meaning shifts from upstream's "the served context" (today startup context == served context) to "the configured pre-residency ceiling"; the consumers of that value are enumerated and reconciled in research D-10 (`server/server.py:1817,1834-1841`, `server/runtime.py:1183-1187`, `server/frontend.py`, `RuntimeResourcesConfig::relaunchContext`). 003's per-request capacity telemetry **is decided** (U-05): it is carried in-band as a restored `StartEvent.capacityTokens` field (a coordinated wire-layout change in both codecs with a `PROTOCOL_VERSION` bump, per D-12 rule 3), sourced only from the exact published `Engine`; deriving it from a status lookup at request-issue time is rejected. The status-schema axis stays independent — optional lifecycle fields do not by themselves bump `kStatusSchemaVersion`.

The `--pause-on-battery` chain is restored across `install/launcher.py` → `server/serve_options.py` → `server/server.py` → `runtime/engine/NativeArguments` → native policy, with public help and exact forwarding (FR-004; 002 FR-007/FR-013/FR-014). Python keeps a bounded-freshness, fail-closed prefilter over the native gate, ordered by three domains: process generation, lifecycle revision, and an intra-revision observation sequence (FR-024, research D-14).

### G. Test migration, deterministic race validation, full regression, physical evidence

Both suites are preserved: the 39 historical Battery C++ cases (concentrated in `dev/tests/engine/runtime_bootstrap_test.mm` and `runtime_status_test.cpp`, with smaller additions in `runtime_resources_test.mm`, `native_engine_loop_test.cpp`, `protocol_test.cpp`, `qwen_state_storage_test.mm`, and new `native_main_test.mm`) are re-homed against the new interfaces; the ~90 upstream-only C++ cases in the same files (`runtime_bootstrap_test.mm` 30, `runtime_resources_test.mm` 55, `native_engine_loop_test.cpp` 119, `runtime_status_test.cpp` 30 registrations at HEAD) must survive; the deleted historical Python suites (`dev/tests/test_server.py`, `dev/tests/engine/test_server_recovery.py`, `test_protocol_recovery.py`, `test_response_lifecycle.py`) are relocated into `dev/tests/server/` (adjacent to `test_runtime.py`, `test_status_contract.py`, `test_serve_options.py`) and `dev/tests/install/test_launcher.py`.

---

## Source Integration Points

For each planned interface: source symbol (provenance-tagged) → required change → invariant → verification → dependencies. (Full detail lives in the contracts; this table is the review index.)

**Provenance key (used in this table, `data-model.md` and every contract):**

| Tag | Meaning | How verified |
|---|---|---|
| `[U]` | **Current upstream** — present at clean HEAD `a8a74e6` | `git grep`/`git show HEAD:<path>` |
| `[S3]` | **Historical stage 3 only** — present at `f9f4eb3a`, absent at HEAD | `git show f9f4eb3a:<path>` |
| `[D]` | **Auto-merged working-tree draft** — appears in the conflicted tree because a file merged cleanly; **not** an upstream guarantee and not assumed correct | absent from `HEAD`, present in the working tree |
| `[P]` | **Proposed** for this migration — no source exists yet | n/a |

Verified absences at HEAD that the earlier draft of this plan had implied were upstream (confirmed by `git grep -c <symbol> HEAD -- runtime`): `NativeAdmissionGate`, `publishEngine`, `tryPublishEngine`, `startModelLess`, `advanceSuspend`, `advanceRecovery`, `RecoveryCandidate`, `LifecycleStatusSnapshot`, `LifecyclePower`, `RuntimeBootstrapTestAccess`. All are `[D]` or `[P]`.

| # | Source symbol (provenance-tagged) | Required change or new interface | Ownership / concurrency invariant | Verification | Depends on |
|---|---|---|---|---|---|
| 1 | `engine/RuntimeResources.hpp`: `RuntimeResources::create`, `~RuntimeResources`, members `model_`, `readers_`, `operators_`, `aneFfn_`, `releasableMemory_`, `adoptPersistentCache`, probation thread | Split: retained graph keeps backend/governor/Cache/KV/state/SlotFile/disk/probation; model residency + model-dependent bindings move to a new disposable owner. `modelContext()`/`actualMemoryReport()`/`streamedExpertStats()`/`aneFfnSnapshot()`/`kvSpillStatus()` become residency-optional | Retained graph survives suspension with identity; disposable stratum never referenced without the lease | `dev/tests/engine/runtime_resources_test.mm` (upstream cases kept) + new residency-absent case; ASan/TSan variants in `dev/native.mk` | none (first workstream) |
| 2 | `engine/WriteBehind.hpp`: `published/run/flush/nextWakeup/snapshot`, `stalled_`, `queued_`; owned at `engine/Engine.hpp:903` | Owner moves to retained graph; `Engine` borrows it; due-work gated on lease state | Exactly one executor of due work at a time; due times/order/budget preserved | `dev/tests/engine/persistent_cache_test.cpp` (existing budget/order cases) + new owner/worker deferral cases | 1 |
| 3 | `engine/MetalBackend.hpp:391-393` (one submitting thread, `commandInFlight()` any-thread), `CommandTicket` (`:301-308`), `submitCommandAsync` `then` | Add lease-gated submit path + callback-retirement receipt (count of tickets/`then` closures not yet retired) | Lease holder is the single submitting thread during residency work; retirement counted before handoff | New deterministic test with a controllable ticket fixture; existing `metal_backend_test`/`handoff_test` must pass | 1 |
| 4 | `engine/MemoryGovernor.hpp` (unsynchronized, short-lived reservations) | Governor access restricted to the lease holder; snapshot for status | Single-writer by lease, not by mutex | TSan build (`make test-sanitizers`) + governor-focused case | 1, 3 |
| 5 | `[U]` `engine/NativeRuntime.hpp`: `core_`, `idle()`-equivalent call sites, `millisecondsUntilNextWakeup()`, `setCompletionNotifier`, `weights`, `releaseIdleWeights`, `weightsSnapshot` · `[D]` `publishEngine`, `tryPublishEngine`, `destroyEngine`, `hasEngine`, `NativeAdmissionGate`, `NativeLoopConfig::configuredContextCeiling` (none of these exist at HEAD) | Shell owns only a published `Engine`; `[P]` gate + publish/destroy surface to be re-derived; `weights`/`releaseIdleWeights`/`weightsSnapshot` become residency-conditional | Admission closed at the native gate through submission; shell never touches leased resources | `dev/tests/engine/native_engine_loop_test.cpp` (upstream cases kept) + new residency-absent case | 1 |
| 6 | `engine/FdTransport.hpp`: `controlNotifier()`, `LoopWake`, `run()`, `InputReader` | Control traffic continues while worker holds lease; model-less wakeup source for WriteBehind | Transport never joins an in-flight worker; processes control frames only | `dev/tests/engine/fd_transport` tests + new handoff-responsiveness test | 1, 2, 5 |
| 7 | `[D]` `engine/Status.hpp`/`Status.cpp`: `LifecyclePower`, `LifecycleState`, `LifecycleStatusSnapshot`, `validLifecycleStatus`, fail-closed status emission (absent at HEAD; merged in cleanly) · `[U]` `kStatusSchemaVersion = 6`, `maximumContextTokens` in the live status document (`Status.cpp:351`) | Complete and re-verify the lifecycle status surface against schema 6 under rule D-12; detached snapshots while the worker holds lease; add the intra-revision observation sequence (`[P]`) | Reads passive; inference-ready requires live Engine agreement | `dev/tests/engine/runtime_status_test.cpp` + `dev/tests/engine/status_golden.json` + `dev/tests/server/test_status_contract.py` | 1, 5 |
| 8 | `[U]` `engine/Bootstrap.hpp`: `start()`, `requireWarmupAndAnnounce()`, `controlPass()`, `statusJson()`, `RuntimeBootstrapConfig`, `StartupRetryWindow`, `protocolLimitsFor()` · `[D]` `startModelLess`, `beginSuspend`, `advanceSuspend`, `advanceRecovery`, `publishRecoveryCandidate`, `shutdownLifecycle`, `observePower`, `SuspendProgress`, `RecoveryProgress`, `RecoveryCandidate`, `RecoveryPublication` | Add model-less start, lifecycle revision state, suspend/recovery pumps, candidate envelope, authority handoff; keep `start()`'s one-`ReadyEvent` contract | Sole lifecycle owner; no expensive work under `lifecycleMutex_`/`recoveryMutex_` | `dev/tests/engine/runtime_bootstrap_test.mm` — **the `RuntimeBootstrapTestAccess` seam is `[D]`, not upstream: adding it is itself planned work with its own test** | 1-7 |
| 9 | `[S3]` `engine/PowerSource.hpp`/`.mm` (historical stage-3-only files: `PowerSource`, `makeSystemPowerSource`, `PendingPowerObservation`, `PowerObservationTeardown`; absent at HEAD) | Re-anchor onto the `[D]` lifecycle enums and `main.mm` teardown order (observer teardown before bootstrap teardown) | Callbacks record + wake only; registration precedes the initial sample | native wiring test (see Gate 8; the `native-main` test target is `[P]`, see quickstart §2) | 7, 8 |
| 10 | `runtime/engine/NativeArguments.hpp/.cpp`: `NativeArguments`, `parseNativeArguments` | Add `--pause-on-battery` parsing + help (not inline in `main.mm`) | CLI parsing owned by `NativeArguments` | `dev/tests/engine` native-args cases + `dev/tests/install/test_launcher.py` | 8 |
| 11 | `server/serve_options.py` (shared parse helpers), `server/server.py::parse_args`, `install/launcher.py::serve/parse_args` | Restore the `--pause-on-battery` chain and help; forward exactly to the native argv | Default-off; opt-in only | `dev/tests/server/test_serve_options.py`, `dev/tests/install/test_launcher.py`, `test_launcher_local.py` | 10 |
| 12 | `[U]` `server/runtime.py`: `MultiplexedRuntime`, `GenerationRequest`, `RuntimeCall.generation`, `_ready_message`, `relaunch_command(ReadyEvent)`, `_StatusWaiter`, the cross-relaunch context-equality check at `:1183-1187` | Add the within-generation lifecycle revision contract **plus an intra-revision observation sequence** (`[P]`, research D-14) and bounded-freshness status refresh; keep one `ReadyEvent` per generation | Generation orders across children; revision orders across revisions; observation sequence orders phases *inside* one revision — completion arrival order is not observation order | `dev/tests/server/test_runtime.py`, `test_protocol_python.py` + new same-revision out-of-order completion case | 11 |
| 13 | `server/backend.py`: `NativeBackend.is_ready/refusal/_recover/_relaunch/_ensure_recovery_locked/status_snapshot` | Python admission = fail-closed prefilter over the native gate; no second handshake; no `wait_ready()` on inference_ready false | Stale Python `true` is tolerable only because the native gate is authoritative | `dev/tests/server/test_native_backend.py`, `test_memory_release.py` | 12 |
| 14 | `server/frontend.py`: `self.max_context` (budgeting + context-length checks at `:242,296,403,405,707,708,773,774,1216,1217,1218`) | Separate static capability from dynamic effective context for budgeting vs. error reporting | Effective value only from the published Engine | `dev/tests/server/test_chat*.py` context cases + new static-vs-effective case | 7, 12, 13 |
| 15 | `dev/tests/engine/TestExecutor.hpp`: `prefillRows` (`:358`), `prefillChunks` (`:359`), `lastRestoredTokens` (`:244,292`), restore/offload ticket fixtures | Drive two `Engine`s over one retained `Cache` and assert suffix-only prefill with restored vs executed tokens counted separately | Retained identity reused, no synthetic prompt, no full warmup | The dedicated SC-005 proof test | 1, 2, 5, 8 |
| 16 | `[U]` goldens/fixtures: `dev/tests/engine/status_golden.json`, `protocol_golden.txt`, `native_command_golden.txt`, `dev/tests/native_peer.py`, `dev/tests/server_fixtures` (`FakeRuntime`, `HarnessTestCase`) | Update goldens for additive lifecycle fields only under the D-12 rule; replace historical fixture infra with upstream fixtures | Schema/codec consistency across native+Python; schema version axis separate from wire version axis | `test_status_contract.py`, `protocol_test.cpp` golden vectors | 7, 14 |
| 17 | `[U]` `server/protocol.py` `_START` pack/unpack + `runtime/engine/Protocol.cpp::encodeStart` · `[S3]` `StartEvent.capacityTokens` (`f9f4eb3a:runtime/engine/Protocol.hpp:270`, `f9f4eb3a:server/protocol.py:289,940,1594`) · `[D]` `Status.cpp` `effective_context_tokens` | **Per-request capacity telemetry contract — approved decision (U-05)**: carry capacity **in-band** as a restored `StartEvent.capacityTokens` field sourced only from the exact published `Engine`, added via a coordinated binary event extension (both codecs + `PROTOCOL_VERSION` bump per D-12 rule 3) that preserves the 16-byte header and every existing event field; the status-lookup-at-request-issue-time alternative is rejected. | The value attributed to a request must be provably the one for the Engine that served it (constitution VIII); adoption updates the shell's request-telemetry context only after that Engine is published. | Gate 12 deterministic test: a recovery that resolves a smaller context, asserting the attributed capacity follows the published Engine and never the ceiling. U-05 is approved; Gate 12 stays unpassed until this test lands. | 7, 12, 14, 16 |

---

## Implementation Workstreams (dependency-ordered, no numbered tasks yet)

| WS | Name | Depends on | Core work | Gate(s) proven at this WS |
|---|---|---|---|---|
| **A** | Baseline and compatibility gates | — | **Baseline evidence must come from the clean upstream commit, never from the conflicted working tree** (which is not buildable). Extract `a8a74e6` read-only into a directory **outside** the repository with `git archive a8a74e6` piped into `tar -x -C "$BASELINE_DIR"` (`git archive` writes only to stdout; no `checkout`/`worktree`/`reset`/`stash`), then build and run the upstream suites **there**; or reuse verified CI evidence for that commit. Capture the wire/status facts (v11, 16-byte header, schema 6, one `ReadyEvent`, upstream `StartEvent` layout) and the `ReadyEvent.maxContextTokens` consumer set (research D-10); establish the two-axis compatibility rule (D-12) before any wire change; capture the disabled-mode parity baseline (002 SC-001…SC-003 seams). **No baseline run happens in this planning step.** | Gate 13 (disabled-mode parity) baseline; establishes the comparison target for FR-020/FR-031/SC-008 |
| **B** | Retained/disposable ownership split + persistence-intent retention | A | Split `RuntimeResources`; move `WriteBehind` owner; relocate `ReleasableMemory`/streamed stores/ANE program into the disposable owner; audit borrowed addresses | Gate 1 (native admission closure *structure*: the `[P]` admission gate held through `Engine` submission), Gate 9 part 1 (WriteBehind ordering/budgets preserved under new owner), Gate 10 part 1 (restore integrity untouched) |
| **C** | Exclusive resource-domain authority + provable quiescence | B | Implement `ResourceDomainLease` + happens-before/retirement receipts; lease-gate MetalBackend/MemoryGovernor/retained-storage ops | Gate 1 (admission closure, proven), Gate 2 (request drain), Gate 3 (retained-IO drain), Gate 4 (handoff + callback retirement) |
| **D** | Model-less control shell, native admission, asynchronous release | C | `[P]` model-less start, cold vs warm states, publish/destroy residency surface (the `[D]` drafts `startModelLess`/`publishEngine`/`tryPublishEngine`/`destroyEngine`/`beginSuspend`/`advanceSuspend` are re-derived and re-tested), pumpable safe points, control responsiveness during release | Gate 4 part 2 (control stays responsive; never join in-flight worker), Gate 8 (terminal shutdown wiring: observer teardown before bootstrap teardown) |
| **E** | Private recovery, transactional adoption, stale disposal, two-phase publication | D | Worker construction, completion envelope, rollback incl. callbacks/bindings, stale reaping outside the lock, revision/power fence, newer-AC-after-release reconciliation | Gate 5 (asynchronous cancellation + stale disposal), Gate 6 (transactional adoption failure), Gate 7 (two-phase publication + superseding power intents), Gate 8 (shutdown racing recovery) |
| **F** | Protocol, Python lifecycle, public CLI, frontend context | A, C, E | Status additive fields on the schema axis; static ceiling vs effective context; the approved in-band `StartEvent.capacityTokens` extension (U-05) with its coordinated `PROTOCOL_VERSION` bump; `--pause-on-battery` chain; Python three-domain ordering (generation, revision, observation sequence) with bounded freshness and passive status | Gate 11 (Python ordering incl. same-revision completions, and passive status), Gate 12 (static capability vs effective context — **unpassed until the U-05 capacity extension and its deterministic test land**), Gate 13 (disabled-mode parity, final) |
| **G** | Final integration, full regression and physical evidence | B…F | Re-home the remaining historical Battery C++ cases and any still-unrelocated upstream C++ cases; relocate the deleted historical Python suites into `dev/tests/server/` and `dev/tests/install/`; run the FR-029 full AC → Battery → AC integration test; run the complete regression sweep; perform the operator physical session. **Not** where foundational guarantees get their first test: gates 1-4 need passing narrow tests from WS B/C/D and gates 5-8 from WS C/E before this stage begins (see the evidence table below). | Gates 1-13 final confirmation; FR-025…FR-031 evidence bundle |

### Per-workstream evidence owed before dependent work starts

No workstream may hand off to its dependents without the narrow deterministic tests below passing. WS G re-runs them at full-suite scale; it does not supply them.

| WS | Narrow evidence that must pass before dependents start | Prerequisite primitives |
|---|---|---|
| B | Retained/disposable split with identity-preservation assertions; the existing `WriteBehind` due/order/budget cases stay green after the owner move (`persistent-cache` suite); one residency-absent status case | none |
| C | **Retirement-receipt tests**: a parked command ticket, a pending host-step `then`, and a pending engine callback each refuse handoff, then retire and permit. **KV-tier transfer witness test**: a parked transfer refuses, completes, permits. Lease handoff/return round-trip; governor single-writer under TSan | **U-01** (receipts) and **U-02** (KV witness) are implemented *here* — they are prerequisites, not WS-G work |
| D | Model-less start creates no `RuntimeResources`; cold-vs-warm distinction asserted; `destroyEngine` refuses while either barrier is unmet; control traffic answered while the worker holds the lease; observer-before-bootstrap teardown order test | B, C |
| E | Rollback test (refused adoption restores callbacks/notifiers and Cache/StateCache bindings; candidate destroyed in dependency order); stale-reap-before-eligibility test; two-phase fence test (Battery between phases keeps admission closed); shutdown-racing-recovery test | C, D |
| F | Status golden + contract tests for the new fields under the D-12 rule; static-vs-effective context cases; **same-revision out-of-order completion test**; CLI chain forwarding tests; disabled-mode parity cases | A, C, E |
| G | Full sweeps (`make check`, `make test`), FR-029 integration test, physical evidence bundle | B…F |

Rule enforced: a gate is credited to the workstream that owns the ownership boundary it protects, and that workstream's narrow test must be green there. Gates 1-4 belong to B/C/D, gates 5-8 to C/E, gates 9-10 to B/E, gates 11-13 to A/F. A later, higher-level lifecycle test may **re-confirm** a gate but never establishes it, and a workstream whose prerequisite primitive (U-01…U-05) is unimplemented must report its gate BLOCKED.

---

## Validation Gates and Their Proofs

| # | Gate | Deterministic proof planned | Seam |
|---|---|---|---|
| 1 | Native admission closure | Inject admission-closed frames after closure; assert rejection despite stale Python `inference_ready` | `[P]` admission gate (re-derived from the `[D]` draft) + `[U]` `Engine::submit` |
| 2 | Request drain | Drive `Engine` to `idle()` with live ticket/mask/restore fixtures; assert destructive release refuses until each category retires | `Engine::idle/inFlight/commandInFlight` + new retirement counters |
| 3 | Retained-state IO drain | Park a StateCache offload and a KV-tier transfer; assert refusal, then completion → progress | `StateCache::writing()/pollOffload()` |
| 4 | Handoff + callback retirement | Worker in flight; issue status/health/metrics/models + Battery + Shutdown; assert control answers, worker not joined, tickets/`then` receipts reach zero | `FdTransport::controlNotifier`, `MetalBackend::commandInFlight` |
| 5 | Asynchronous cancellation + stale disposal | Completed stale candidate with newer non-AC revision; assert reap before eligibility return, no retained residency | `[D]` recovery pump + `[P]` test seam for candidate inspection (the `[D]` `RuntimeBootstrapTestAccess` friend is itself planned work) |
| 6 | Transactional adoption failure | Refused adoption; assert rollback of callbacks/bindings, candidate destroyed in dependency order | `[D]` adoption surface (`tryPublishEngine`) + `[P]` binding-witness fixture |
| 7 | Two-phase publication + superseding intents | Battery between adoption and fence; assert gate stays closed and residency releasable by ordinary suspension | `publishRecoveryCandidate` fence |
| 8 | Terminal shutdown | Shutdown during draining/suspended/recovering; later power ignored; completed candidate never becomes residency | `shutdownLifecycle` |
| 9 | WriteBehind ordering/budgets/deferral | Due and not-yet-due points across owner/worker authority; compare counters, due times, order, budget-held points; clean-stop flush parity vs baseline | `WriteBehind::run/flush/nextWakeup` |
| 10 | Restore integrity, destination-local failure, retryable source | Corrupt/truncated/cancelled restore into one request; source remains usable; in-flight offload not obtainable | `StateCache` fixtures, `TestExecutor::RestoreControl` |
| 11 | Python generation/revision ordering, **including same-revision ordering**, passive status | Old-generation completion discarded; lower revision ignored; **two completions with the same generation *and* same revision, arriving in reverse observation order → the older must not overwrite the newer**; status reads never load residency | `[U]` `MultiplexedRuntime` generation handling + `[P]` observation-sequence field / request-issue sequence rule (research D-14) — see `dev/tests/server/test_runtime.py` |
| 12 | Static capability vs dynamic effective context | Recovery resolving a smaller context: ceiling unchanged on readiness and `/v1/models`; per-request capacity telemetry follows the published Engine only via the approved in-band `StartEvent.capacityTokens` field; inconsistent inference-ready data fails closed | `[D]` status validation + the **approved** U-05 in-band `StartEvent` capacity extension (coordinated `PROTOCOL_VERSION` bump) — Gate 12 stays unpassed until it and its test land |
| 13 | Disabled-mode upstream parity | Option absent + fake Battery/Unknown; zero Battery lifecycle/status transitions; ordinary memory-pressure/idle release unchanged | `002` disabled-mode seams in `test_serve_options.py`/`test_native_backend.py` |

`TestExecutor` already exposes `prefillRows`, `prefillChunks`, restored boundaries and KV-content checks; the SC-005 proof uses them (two `Engine` instances over one retained `Cache`), and is kept separate from the FR-029 Battery→AC integration test.

---

## Rebase-Aware Migration Sequence

1. Read stage 2 (`HEAD` side) of each conflicted path for the current API; read stage 3 (`f9f4eb3a` side) only for historical behaviour and test intent.
2. Treat cleanly auto-merged content as **unverified drafts (`[D]`), never as upstream guarantees**: `runtime/engine/Status.hpp` and `Status.cpp`'s lifecycle enums/validation, `runtime/engine/Bootstrap.hpp`'s `startModelLess`/`beginSuspend`/`advanceSuspend`/`advanceRecovery`/`publishRecoveryCandidate`/`shutdownLifecycle`/`RecoveryCandidate`/`RecoveryPublication`/`SuspendProgress`/`RecoveryProgress`/`RuntimeBootstrapTestAccess` friend seam, `RuntimeResources.hpp`'s `ModelPackageResidency`/`takeModelPackageResidency`, and `NativeRuntime.hpp`'s `NativeAdmissionGate`/`publishEngine`/`tryPublishEngine`/`destroyEngine`/`configuredContextCeiling`. Every one of these is absent from `HEAD` and must be re-derived against the ownership/authority design, then re-tested. `dev/tests/engine/native_main_test.mm` and its `native-main` test target are likewise stage-3 additions (absent from HEAD's `dev/native.mk`) and are **planned** targets.
3. Never resolve a conflicted test file by taking one whole side: both the upstream registrations and the Battery registrations must survive (FR-025/SC-002).
0. **Four trees, and what "integration" means.** Clean HEAD `a8a74e6` (baseline) · unresolved rebase tree (conflict markers; NOT buildable; never a test subject) · partially integrated tree (implementation tasks resolve conflict markers IN the files they own, defaulting to the upstream stage-2 side where new machinery is not yet implemented, so a chosen test target compiles and runs narrow gate tests) · fully resolved tree (full regression + integration). Resolving file CONTENT is authorized to the implementing task; git-index/rebase operations (`add`/`commit`/`reset`/`checkout`/`stash`/`rebase --continue`) are NOT — the operator alone stages and continues. A gate is PASS only when its target actually compiled and exercised the code; otherwise NOT RUN.
4. Files where upstream replaced historical fixture infrastructure (`dev/tests/engine/Test*` headers, `status_golden.json`, `protocol_golden.txt`, `dev/tests/server_fixtures`): migrate assertions onto the upstream fixtures rather than restoring the REBASE_HEAD-only historical harnesses (`dev/tests/test_server.py`, engine-path `dev/tests/engine/{test_server_recovery,test_runtime,test_launcher}.py`). Note upstream ALREADY has `dev/tests/server/{test_server_recovery,test_protocol_recovery,test_response_lifecycle}.py` at HEAD — migrate only Battery-specific assertions there, do not treat these as deleted files.
5. Wire/CLI changes land in WS F only, after WS B–E have the ownership guarantees, so a protocol extension can never mask a missing lower-level guarantee.

---

## Documentation Artifacts (this step)

```text
specs/003-upstream-battery-parity/
├── spec.md            (approved input; unchanged)
├── plan.md            (this file)
├── research.md        (established decisions D-01…D-15 + open items U-01…U-04 and the approved U-05 decision)
├── data-model.md      (ownership, authority states, identities, envelopes, revisions, invariants)
├── quickstart.md      (validation sequence + physical evidence procedure)
├── contracts/
│   ├── resource-domain-authority.md
│   ├── worker-handoff-and-disposal.md
│   ├── engine-detach-and-transactional-adoption.md
│   ├── writebehind-retained-scheduling.md
│   ├── native-control-status-and-protocol.md
│   ├── retained-state-reuse-and-restore-integrity.md
│   └── public-cli-opt-in-and-python-lifecycle.md
├── checklists/        (existing from the specify step)
└── tasks.md           (NOT created here: belongs to $speckit-tasks)
```

## Source Code Layout (repository, real paths)

```text
runtime/engine/            # C++/Obj-C++ runtime: Engine, Bootstrap, NativeRuntime, RuntimeResources,
                         # StateCache, WriteBehind, Status, Protocol, FdTransport, NativeArguments,
                         # MemoryGovernor, MemoryControl, ReleasableMemory, PowerSource
runtime/model/             # LoadedModel/RuntimeModel, QwenState(+Storage), SlotFile, SparseRowStore,
                         # SsdReaders, KvBlockCache/KvHistoryStream, ModelFactory
runtime/metal/             # MetalBackend (one submitting thread), kernels
runtime/ops/               # ExecutionPlans, AneFfn, PageStorage, Vision
runtime/main.mm            # native process entry, power wiring, IdleSleepAssertion
server/                    # Python control plane: server.py, runtime.py, backend.py, frontend.py,
                         # protocol.py, serve_options.py, metrics.py, crash_trace.py
install/launcher.py        # public CLI: splash serve → serve options → child argv
dev/tests/engine/          # native suites + Test* fixtures + goldens (status_golden.json,
                         # protocol_golden.txt) + *.py protocol/lifecycle suites
dev/tests/server/          # Python server suites (test_runtime.py, test_status_contract.py,
                         # test_serve_options.py, test_native_backend.py, test_memory_release.py, ...)
dev/tests/install/         # test_launcher.py, test_launcher_local.py, test_clients.py
dev/native.mk, dev/Makefile, Makefile   # build + test orchestration (test-engine-cpu/metal,
                                         # test-sanitizers, test-python, check-*)
```

**Structure decision**: no new top-level component. All migration work lands inside the existing native runtime + Python server layout, reusing existing build targets and test directories; the only new files are planning artifacts here and (in implementation) the authority/candidate primitives under `runtime/engine/`.

---

## Dependencies

- **Internal**: the WS graph above (A→B→C→D→E→F→G). No gate may be closed by a dependency's test alone.
- **Spec/decision inputs**: 001's accepted behaviour contract and 002's gate semantics (not reopened); `REBASE_HEAD` commit message invariants; constitution I–XII.
- **Hardware**: physical validation (FR-030) needs one Apple Silicon macOS host after implementation; deterministic proofs (FR-025…FR-029) need none beyond CI-equivalent toolchain, and Metal-only tests remain built-not-run on GPU-less CI (FR-025's prerequisite allowance).
- **Toolchain**: `make` (Makefile + dev/Makefile + dev/native.mk), Python 3.12–3.14 venv (`$(VENV)/bin/python`), `ruff` (config `dev/ruff.toml`) for Python formatting gates.

## Post-Design Re-check

Constitution re-checked after Phase 1 design: PASS for all twelve principles (see Constitution Check table). Three recurring risks were converted into explicit plan constraints instead of exceptions: (a) auto-merged stage-3 content is treated as unverified `[D]` input with a provenance key, (b) protocol/schema evolution is governed by the two independent axes of D-12 rather than a blanket version decision, and (c) baseline comparison always comes from the clean commit extracted read-only (D-15), never from the conflicted tree. Genuine unresolved implementation details are recorded in research.md §U (U-01…U-04) with the workstream that owns each one, while U-05 is an approved decision awaiting implementation; **Gate 12 remains unpassed until U-05's approved in-band `StartEvent` capacity extension and its deterministic test land**, and Gates 2/3/4 are BLOCKED until U-01/U-02 land in WS C.
