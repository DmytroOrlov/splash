# Splash 1.6.1 — integration preflight & rebase-readiness evidence

Scope: bounded mechanical preflight of the integrated working tree on branch
`integration/battery-161`, rebase paused applying Battery commit `05448b0f`
onto `d8af1054` (HEAD `ca2e0289`, msgnum=2/end=2). No Git index resolution, no
staging, no commits. Full logs under `/private/tmp/splash-161-integration-preflight/logs/`.

Accepted upstream evidence is carried forward, not re-audited. Historical parity matrix
lives in `dev/tests/evidence/battery-161-native-parity-closeout.md` (44/44 mapped, 0 PENDING).

---

## A. Git conflict inventory (54 paths)

Git state captured before/after work (unchanged):

```
HEAD      = ca2e02891ad6f4696fcb074d9676b15781fbcabb
onto      = d8af1054aab0f97de21d043e01aa98af3754f10e   (upstream 1.6.1)
stopped-sha = 05448b0f998c29728e7a57f8f1ac2fdac202a06f   (Battery commit, msgnum 2/2)
orig-head = 05448b0f998c29728e7a57f8f1ac2fdac202a06f
```

Baseline counts confirmed: **52 `UU` (stages 1/2/3) + 2 `DU` (stages 1/3) = 54 unmerged.**
Working-tree conflict markers across all repository files (excluding `.git`, `build`,
`target`, `.venv`): **0** (`rg '^(<{7}|={7}|>{7})'` and `'<{7} |>{7} '` → none). The two
`={7}`/`={5}` hits from the broad scan are a `specs/**` log separator and `THIRD_PARTY_NOTICES`
ASCII art — no 3-part conflict triple exists. `git diff --check` (both work↔index and
empty-tree↔HEAD) returned rc=0 with no output: unmerged index stages do NOT produce whitespace/marker
errors. All 54 have resolved working-tree content; the unmerged state is index stages only.

Legend for "Remaining concern": `—` = index-stage bookkeeping only, no mechanical blocker;
text otherwise = a real blocker.

### Build system (2)

| Path | Git conflict type | Working-tree markers | Accepted owning package | Remaining concern |
|---|---|---|---|---|
| `Makefile` | UU | none | A + native CPU wiring | — (working tree resolves; digest rebuilds OK) |
| `dev/native.mk` | UU | none | Engine/NativeRuntime/Cache test wiring | — (splits `engine`,`native-engine-loop` and wires `native-lifecycle-focused`) |

### Swift / UI (5) — carry-forward Package C (`swift test --build-system native`, 218 passed)

| Path | Git conflict type | Working-tree markers | Accepted owning package | Remaining concern |
|---|---|---|---|---|
| `app/Sources/Splash/Server.swift` | UU | none | C (Swift) | — (source manifest unchanged after Package C run; 218 carried) |
| `app/Sources/Splash/ServerView.swift` | UU | none | C (Swift) | — |
| `app/Sources/Splash/Transcript.swift` | UU | none | C (Swift) | — |
| `app/Tests/SplashTests/SplashTests.swift` | UU | none | C (Swift) | — |
| `app/Tests/SplashTests/TranscriptTests.swift` | UU | none | C (Swift) | — |

Note: `MainView.swift`, `Preferences.swift`, `Menus.swift`, `DrawerTests.swift` are `M`/`MM`
(merge-dirty) but **not** unmerged — no action. Swift default SwiftPM `make check-app` was
not re-run: Metal Toolchain missing (see D). Source-identity manifest (section E) shows these
Swift files byte-identical to the accepted state, so the 218-test result is valid to carry.

### Native production (22)

| Path | Git conflict type | Working-tree markers | Accepted owning package | Remaining concern |
|---|---|---|---|---|
| `runtime/main.mm` | UU | none | A (native entrypoint) | — (production `splash` builds & links, exit 0) |
| `runtime/engine/Bootstrap.hpp` | UU | none | NativeRuntime/Bootstrap | — |
| `runtime/engine/Bootstrap.mm` | UU | none | NativeRuntime/Bootstrap | — |
| `runtime/engine/Cache.cpp` | UU | none | Cache | — (2 Cache regressions already reconciled vs snapshot) |
| `runtime/engine/Cache.hpp` | UU | none | Cache | — |
| `runtime/engine/Engine.cpp` | UU | none | Engine | — |
| `runtime/engine/Engine.hpp` | UU | none | Engine | ⚠ Engine ctor now takes 5 args incl. `WriteBehind` (line 255); `runtime_metrics_test.cpp` not migrated (see B/C) |
| `runtime/engine/MemoryGovernor.cpp` | UU | none | MemoryGovernor | — |
| `runtime/engine/MemoryGovernor.hpp` | UU | none | MemoryGovernor | — |
| `runtime/engine/NativeArguments.hpp` | UU | none | A/native-arguments | — |
| `runtime/engine/NativeRuntime.cpp` | UU | none | NativeRuntime | — |
| `runtime/engine/NativeRuntime.hpp` | UU | none | NativeRuntime | — |
| `runtime/engine/Protocol.cpp` | UU | none | Protocol | — (kProtocolVersion=14, kStatusSchemaVersion=8 → match) |
| `runtime/engine/Protocol.hpp` | UU | none | Protocol | — |
| `runtime/engine/RuntimeResources.hpp` | UU | none | RuntimeResources | ⚠ architecture-check: new engine→assembly cross-ref (see B) |
| `runtime/engine/RuntimeResources.mm` | UU | none | RuntimeResources | — |
| `runtime/engine/StateCache.hpp` | UU | none | Cache | — |
| `runtime/engine/Status.cpp` | UU | none | RuntimeStatus | — |
| `runtime/engine/Status.hpp` | UU | none | RuntimeStatus | — |
| `runtime/metal/MetalBackend.hpp` | UU | none | Metal backend | ⚠ Metal compile blocked by missing Metal Toolchain (env, not source) |
| `runtime/metal/MetalBackend.mm` | UU | none | Metal backend | ⚠ (same Metal-toolchain blocker for `.air`/host-step; `.mm`/ObjC++ itself compiles via clang++) |
| `runtime/model/Runtime.hpp` | UU | none | Engine/Runtime | — |

### Native tests (13)

| Path | Git conflict type | Working-tree markers | Accepted owning package | Remaining concern |
|---|---|---|---|---|
| `dev/tests/engine/engine_cache_test.cpp` | UU | none | EngineCache | — (run green this preflight: 199 tests) |
| `dev/tests/engine/memory_governor_test.cpp` | UU | none | MemoryGovernor | — (13, host telemetry) |
| `dev/tests/engine/metal_backend_test.mm` | UU | none | Metal backend | ⚠ `metal_backend_test.metal`→`metal-backend.air` blocked by Metal Toolchain |
| `dev/tests/engine/native_arguments_test.cpp` | UU | none | A/native-arguments | — (run green with golden+configs) |
| `dev/tests/engine/native_fd_transport_test.cpp` | UU | none | NativeRuntime/FD | — |
| `dev/tests/engine/persistent_cache_test.cpp` | UU | none | PersistentCache | — (run green) |
| `dev/tests/engine/protocol_golden.txt` | UU | none | Protocol | — (native↔python agree at v14) |
| `dev/tests/engine/protocol_test.cpp` | UU | none | Protocol | — (run green) |
| `dev/tests/engine/qwen_state_storage_test.mm` | UU | none | Qwen | — (Metal-gated executable) |
| `dev/tests/engine/runtime_bootstrap_test.mm` | UU | none | NativeRuntime/Bootstrap | — |
| `dev/tests/engine/runtime_resources_test.mm` | UU | none | RuntimeResources | — |
| `dev/tests/engine/runtime_status_test.cpp` | UU | none | RuntimeStatus | — (run green w/ goldens) |
| `dev/tests/engine/slot_file_test.cpp` | UU | none | SlotFile | — (run green) |

### Python / HTTP (10) — carry-forward Package B (230 focused + 97 related)

| Path | Git conflict type | Working-tree markers | Accepted owning package | Remaining concern |
|---|---|---|---|---|
| `dev/tests/server/test_native_backend.py` | UU | none | B | — (mocks engine; no real binary spawn) |
| `dev/tests/server/test_protocol_python.py` | UU | none | B | — (compares protocol.py to protocol_golden.txt) |
| `dev/tests/server/test_protocol_recovery.py` | UU | none | B | — |
| `dev/tests/server_fixtures.py` | UU | none | B | — |
| `server/backend.py` | UU | none | B | — |
| `server/frontend.py` | UU | none | B | ⚠ context-plumbing defect: `_serving_context`/`max_context` reference `_context_generation`; `_output_budget`/`_check_image_request_size` → see D (real assertion failures) |
| `server/metrics.py` | UU | none | B | — |
| `server/protocol.py` | UU | none | B | — (PROTOCOL_VERSION=14, STATUS_SCHEMA_VERSION=8 → match) |
| `server/runtime.py` | UU | none | B | — |
| `server/server.py` | UU | none | B | ⚠ `--pause-on-battery` serve option not mirrored in app launch options (test_launcher) |

### Legacy deleted tests (2 — `DU`, do NOT resurrect)

| Path | Git conflict type | Working-tree markers | Accepted owning package | Remaining concern |
|---|---|---|---|---|
| `dev/tests/engine/engine_test.cpp` | DU (stages 1,3) | none | Engine (migrated to split `engine` suite) | Split registration present: `TEST_ENGINE_TEST = engine` built from `engine_requests/checkpoints/commands/memory/spill/disk/memory_rules/release_property` + `engine_test_main.cpp`. File left in tree, correctly unreferenced by build. Its internal ref to `specs/003-upstream-battery-parity/contracts/engine-detach-and-transactional-adoption.md` tripped architecture-check (see B). |
| `dev/tests/engine/native_engine_loop_test.cpp` | DU (stages 1,3) | none | NativeRuntime loop (migrated) | Split registration present: `TEST_NATIVE_LOOP_TEST = native-engine-loop` built from `native_loop_wire/weights/memory` + `native_loop_test_main.cpp`. File left in tree, correctly unreferenced. |

Split executable registrations for both legacy targets **exist and are current**; monoliths
not restored and not deleted.

---

## B. Build & test results (exact outcomes)

| Command | Exit | Duration | Tests | Evidence log |
|---|---|---|---|---|
| `make BUILD=build/t015-corrected -j4 build/t015-corrected/splash` | **0** | 4s | n/a (compile/link) | `logs/A-production-build.log` |
| `make BUILD=build/t015-corrected check-source` | **2** | 6s | architecture-check (fails before `git diff --check`) | `logs/B-check-source.log` |
| `git diff --check` + `git diff --check <empty> HEAD` (run manually) | 0 / 0 | — | no whitespace/marker errors | `logs/B-git-diff-check*.log` |
| `make BUILD=build/t015-corrected -j4 check-native-cpu` | **2** | 77s | build phase aborted (compile error) | `logs/C-check-native-cpu.log` |
| `make BUILD=build/t015-corrected -k -j4 check-native-cpu` (enumerate) | **2** | 18s | **1** compile error | `logs/C-check-native-cpu-k.log` |
| Representative CPU binaries run directly (engine, native-engine-loop, engine-cache, persistent-cache, memory-governor, memory-ledger, native-lifecycle-focused, json-writer, slot-file, cache-directory, disk-space, verify-budget) | **0** | 0–2s each | engine **469 passed,0 failed**; others pass | `logs/C-run-*.log` |
| Same with required args: protocol, runtime-status, native-arguments | **0** | 0–1s | "protocol/status/arguments tests passed" | `logs/C-run-*-args.log` |
| `make BUILD=build/t015-corrected -j4 check-python` (as prescribed) | **2** | 621s | Ran 1669; **failures=20, errors=25, skipped=8** (wrong binary — see D2) | `logs/D-check-python.log` |
| `make -j4 check-python` (BUILD=build default) | **2** | 26s | production `.air` recompile blocked (Metal Toolchain) | `logs/D2-check-python-default-build.log` |
| test-python against CURRENT binary via `build/splash`→t015 symlink | **2** | 625s | Ran 1669; **failures=5, errors=4, skipped=8** | `logs/D3-test-python-current.log` |
| `compileall` / `ruff check` / `ruff format --check` | 0 / 0 / 0 | — | "All checks passed", 194 files formatted | `logs/D4-*.log` |
| `make BUILD=build/t015-corrected -j4 check-native-metal` | **2** | 4s | blocked at `metal-backend.air` | `logs/E-check-native-metal.log` |
| `check-native-build` | **not run** | — | blocked by identical Metal Toolchain failure (`metal-backend.air`/kernels) — recorded once, not retried | see D |

### B.1 check-source failure analysis (real predicate, NOT git-index/marker)

`architecture-check` failed at `Error 1`; `git diff --check` steps never executed. Failures split:

Real production architecture predicates (merge-introduced — new engine headers added by
Battery `A`/`AM` files):
```
runtime/engine/ModelResidency.hpp: engine depends on ops (ops/ExecutionPlans.hpp)
runtime/engine/RecoveryCandidate.hpp: engine depends on engine assembly (engine/RuntimeResources.hpp)
runtime/engine/ResourceDomainLease.hpp: engine depends on metal (metal/MetalBackend.hpp)
runtime/model/WeightImages.cpp: model depends on engine (engine/ResourceDomainLease.hpp)
runtime/engine holds 36591 production lines, over its budget 30105   (engine +6486 over cap)
```
Secondary documentation/contract cross-reference errors (52 total) resolve relative to
`specs/**` scaffolding and the retained legacy `engine_test.cpp`; 30 belong to `.agents/skills/speckit-*`
and `specs/**` (present at HEAD `ca2e0289` "spec kit"), and 2 are `engine_test.cpp`'s ref to a
`contracts/…md` that exists only under `specs/003-…/contracts/`. These are NOT the CPU/Python gate
predicates and do not reflect unresolved index stages.

---

## C. Test wiring (focused Battery tests)

Confirmed via `dev/native.mk`:

- Wired into the **ordinary CPU gate** (`TEST_CPU_TARGETS`, run by `test-engine-cpu`): `engine`
  (split), `native-engine-loop` (split), `engine-cache`, `persistent-cache`, `memory-governor`,
  `memory-ledger`, `native-lifecycle-focused`, `native-main`, `native-arguments`, `runtime-status`,
  `runtime-resources` (Metal), `slot-file`, `protocol`, etc. `TEST_NATIVE_LIFECYCLE :=
  $(ENGINE_TEST_BUILD)/native-lifecycle-focused` (line 144) is in `TEST_CPU_TARGETS` (257), the
  CPU compile group (390) and the run sequence (675).
- `native-lifecycle-focused` compiles and links the focused fixtures `engine_writer_test.cpp`
  (added explicitly at 896, filtered from `TEST_INPUTS` at 891) and `native_lifecycle_ledger_test.cpp`
  (897). Both fixtures are **present** and part of that target → integrated.

Focused/untracked test sources **NOT referenced by any build rule** (genuine wiring gaps;
not blindly added):

| File | Status in build graph |
|---|---|
| `dev/tests/engine/memory_snapshot_publication_test.cpp` | untracked; referenced by no target |
| `dev/tests/engine/resource_domain_governor_scope_test.cpp` | untracked; no target |
| `dev/tests/engine/weight_images_writer_test.cpp` | untracked; no target |
| `dev/tests/engine/writer_authority_test.cpp` | untracked; no target |
| `dev/tests/engine/native_lifecycle_focused.mk` | untracked; included by no Makefile (standalone "-tsan" entry point from the conflicted build; superseded by the wired `native-lifecycle-focused` target) |

Writer/authority/memory-snapshot/residency scope coverage currently rides only on
`native-lifecycle-focused` (writer+ledger fixtures). The four `*_test.cpp` above are unwired
standalone files — decision for the stronger model, not an automatic `+=`.

Legacy monolith `engine_test.cpp` / `native_engine_loop_test.cpp`: correctly **unreferenced**
by `Makefile`/`native.mk`; not restored.

---

## D. Environment blockers, separated

### D.1 Real source / test compilation failure (blocking check-native-cpu as a whole)
Exactly one, reproduced under `-k`:
```
dev/tests/engine/runtime_metrics_test.cpp:99:10: error: no matching constructor for
    initialization of 'Engine'
  Engine engine(test::engineConfig(), cache, model, events);   // 4 args
runtime/engine/Engine.hpp:255:3: note: candidate requires 5 arguments
  Engine(EngineConfig, Cache&, WriteBehind&, model::Model&, EngineEventSink&)
```
Failing predicate: `TEST_METRICS_TEST` (`engine-tests/runtime-metrics`). Owning source:
`dev/tests/engine/runtime_metrics_test.cpp:99` must pass a `WriteBehind` after `cache`. Every other
CPU test target compiled; the aggregate `test-engine-cpu` recipe never ran because this prerequisite
failed to build. Not a production bug — an un-migrated test call site.

### D.2 Real Python assertion failures (against the CURRENT binary, 4 ERROR + 5 FAIL of 1669)
Root cause cluster in `server/frontend.py` context plumbing:
```
AttributeError: 'Frontend' object has no attribute '_context_generation'  (frontend.py:340 max_context)
ContextLengthError: prompt exceeds the context window  (frontend.py:435 _check_image_request_size; :1093 _output_budget)
AssertionError: 8 != 262142   /  8 != 131072   (_output_budget returns 8)
```
Affected tests: `test_anthropic_contract`, `test_chat_count_tokens`, `test_images`
(test_image_positions_ignore_quoted_vision_tokens), `test_output_budget`.
Owning source: `server/frontend.py` `_serving_context`/`max_context`/`_output_budget`/`_check_image_request_size`
and the `_context_generation` init path (frontend.py:245/313/340/1093). Hand to stronger model.
Plus one packaging/option drift:
```
test_launcher test_the_apps_launch_options_are_the_serve_options:
  AssertionError: '--pause-on-battery' present in serve options, missing in app launch options
```
Owning source: app launcher/launch-options list vs `serve_options`.

### D.3 Toolchain / SDK limitation (environmental — NOT a source defect)
`error: error: cannot execute tool 'metal' due to missing Metal Toolchain; use:
xcrun -downloadComponent MetalToolchain` — `xcrun -f metal` resolves, but the Metal **compiler
component** is absent. Consequences observed (recorded once, not retried):
- `host-step.metallib` compile: tolerated (warns; awake host steps run as plain ones) — production
  `splash` still links (exit 0) using the pre-existing `build/t015-corrected/splash.metallib`.
- `check-native-metal`: hard fail at `build/t015-corrected/engine-tests/metal-backend.air`.
- `check-native-build`: would hit the same `.air`/kernel compilations → not separately run.
- Python `test_build_identity test_actual_flag_changes_and_reversions` shells `make` in a temp
  tree compiling `metal-backend.air` → counts as 1 of the 5 python FAILs (environmental, not python).
Package C's SwiftPM `metal` shader failure is the same root cause; Swift 218 not re-run.

### D.4 Rebase-index / source-marker issues
None mechanical: 0 conflict markers; `git diff --check` clean; 54 unmerged index stages intact.
architecture-check failure is a source predicate (D of B), not an index artifact.

---

## E. Source identity & Git-state preservation

Source manifest (all git-tracked + untracked source/test files, excluding `build/`, `target/`,
`.venv/`; 1028 files) SHA-256, sorted:

```
pre  combined = 2702c3bf691f11ef2324fa32434b34803d6ce87542690b2826ed0b426066be08
post combined = 2702c3bf691f11ef2324fa32434b34803d6ce87542690b2826ed0b426066be08
FILESET identical; MANIFEST diff → empty
```
No gate rewrote repository source. Swift sources in the unmerged index are byte-identical to the
accepted Package C state → 218-test evidence validly carried forward.

Git-state preservation (identical pre vs post):
```
.git/index sha256 = 99849deb6f541221a5cbcac9b512f2f4a90259f4a1bcac0c211047a083ec2d23  (unchanged; no staging)
.git/rebase-merge/*  diff → empty (head-name/onto/orig-head/msgnum/end/stopped-sha intact)
unmerged paths before/after = 54;  working-tree conflict markers = 0
```
No `git add/rm/reset/restore/checkout/stash`, no commit/amend, no rebase continue/skip/abort.
Build output `build/splash` was temporarily symlinked to `build/t015-corrected/splash` to run the
Python gate against the current engine (canonical() then loads the current
`splash.metallib`), then **restored** to its original (13 Nov) bytes. No source or git mutation.

---

## F. Handoff — prioritized actionable problems for the stronger model

1. **[Critical, build-blocking]** Migrate `dev/tests/engine/runtime_metrics_test.cpp:99` to pass
   a `WriteBehind` to the 5-arg `Engine` ctor (`runtime/engine/Engine.hpp:255`). This is the sole
   blocker for `check-native-cpu` (all other CPU binaries compile & pass: engine 469, engine-cache
   199, etc.).
2. **[Critical, architecture]** Resolve `check-source` architecture predicate: engine line budget
   **36591 > 30105** and the new engine→ops / engine→assembly / engine→metal / model→engine
   crossings from `ModelResidency.hpp`, `RecoveryCandidate.hpp`, `ResourceDomainLease.hpp`,
   `WeightImages.cpp` (decide layer exceptions vs. re-homing these new headers, or split engine).
3. **[Behavior, Python]** Fix `server/frontend.py` context plumbing: `_context_generation`
   AttributeError + `_output_budget` returning `8` + premature `ContextLengthError` (test_output_budget
   `8 != 262142/131072`, test_images, test_anthropic_contract, test_chat_count_tokens).
4. **[Option drift, Python]** Mirror `--pause-on-battery` in the app launch options so it matches
   `serve_options` (test_launcher test_the_apps_launch_options_are_the_serve_options).
5. **[Wiring decision]** Decide fate of unwired focused tests
   (`memory_snapshot_publication_test.cpp`, `resource_domain_governor_scope_test.cpp`,
   `weight_images_writer_test.cpp`, `writer_authority_test.cpp`) and the orphan
   `native_lifecycle_focused.mk` — add to a target, retire, or exclude; do not blanket-add.
6. **[Index resolution, operator]** 54 paths await operator decision (52 `UU`, 2 `DU`). Working
   trees are marker-free; the 2 `DU` legacy monoliths must stay deleted/resolved-toward-split
   (`engine`, `native-engine-loop` registrations already exist). architecture-check's 2
   `engine_test.cpp` doc-ref errors clear once that file is resolved away.

### Evidence sufficient to avoid unnecessary reruns (do NOT re-execute)
- Package A production entrypoint + native-main + native-arguments: re-confirmed green here (build exit 0; `native-arguments` passes with golden+configs). No rerun needed.
- Package C Swift 218: sources unchanged → carried; skip `make check`/SwiftPM (Metal Toolchain env failure is known).
- Historical parity 44/44: see `dev/tests/evidence/battery-161-native-parity-closeout.md`; not duplicated here.
- Metal gates (`check-native-metal`, `check-native-build`, host-step `.air`): blocked by missing Metal
  Toolchain — recorded once; do not retry on this machine.
- `check-native-cpu`: the aggregate never ran (D.1 compile error); the individual registered CPU
  binaries were executed and are green (engine 469 / engine-cache 199 / persistent-cache / memory-* /
  native-lifecycle-focused / status / protocol / arguments pass) — this is the CPU evidence; do not rerun the
  full aggregate until fix #1 lands.
