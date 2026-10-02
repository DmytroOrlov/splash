# Tasks: Explicit Battery Suspension Opt-In

**Input**: Design documents from `specs/002-pause-on-battery-flag/`

**Prerequisites**: `spec.md`, `plan.md`, `research.md`, `data-model.md`, `contracts/cli-and-native-argv.md`, `quickstart.md`

**Organization**: Seven narrow tasks follow the public contract, native argument seam, owner gate, shared control path, regression checkpoint, and final feature gate. Feature 001 is used as a regression dependency only.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel because it touches different files and has no dependency on unfinished tasks.
- **[Story]**: Maps to a user story in `spec.md`.
- Every task names its exact file paths, dependencies, evidence, validation commands, and any architectural STOP condition.

## Phase 1: User Story 2 - Explicitly enable battery suspension (Priority: P1)

**Goal**: Operators can opt in through the public CLI and the explicit choice reaches native argv.

**Independent Test**: Verify absent/present parsing, false/true child argv behavior, and unchanged existing optional argument ordering.

- [X] T001 [P] [US2] In `server/server.py`, add exactly `--pause-on-battery` as a `store_true` option defaulting false and propagate it from `_native_command(args)` as one standalone token only when true; extend `dev/tests/test_server.py::ServerTest.test_server_requires_explicit_model_and_paths` to prove false default, true value, zero/one child tokens, exactly-once emission, and preserved argv ordering. Run `python3 -m unittest dev.tests.test_server.ServerTest.test_server_requires_explicit_model_and_paths`. STOP if propagation requires backend, frontend, protocol, or readiness changes.
- [X] T002 [P] [US2] In `runtime/main.mm`, add `NativeArguments::pauseOnBattery = false`, parse standalone `--pause-on-battery` without consuming or shifting an adjacent existing `--name value` pair, and include it in `printUsage()` when accepted options are listed; add `dev/tests/engine/native_main_test.mm` and register `build/engine-tests/native-main` in `dev/native.mk` using only a narrowly named test-only guard that suppresses the executable entry point. Prove omission=false, presence=true, and existing pairs still parse in `--pause-on-battery`-adjacent argv. Preserve current repeated-option and malformed-argv conventions; do not create special duplicate rejection. Run `make build/engine-tests/native-main && build/engine-tests/native-main`. STOP before adding a production header/API, changing PowerSource, or broadening parser ownership.

## Phase 2: User Story 3 - Understand the opt-in from CLI help (Priority: P2)

**Goal**: Public help describes the flag accurately and does not promise that all memory is freed.

**Independent Test**: Captured public help contains the flag and concise semantics equivalent to “Release model residency while on battery and recover on AC power,” without claiming all cache/state is released.

- [X] T003 [US3] In `server/server.py` and `dev/tests/test_server.py`, add the concise help text and a focused `ServerTest.test_pause_on_battery_help` assertion for the option and accurate wording; run `python3 -m unittest dev.tests.test_server.ServerTest.test_pause_on_battery_help`. Depends on T001 because the help entry is part of the new public option. Do not add a negative flag or imply complete memory/cache/state release.

## Phase 3: User Story 1 - Keep ordinary serving independent of power (Priority: P1)

**Goal**: With the option absent, serving takes the normal full startup path and never installs battery policy, while shared native control work remains available.

**Independent Test**: Native owner tests prove disabled setup makes no power-source factory, start, sample, callback registration, or initial-power calls and disabled startup selection is full with no initial power. A focused source audit verifies the actual `runNative()` control-handler shape: battery-only early returns are scoped inside `if (pendingPower)`, and shared resource/reclaim work follows outside it.

- [X] T004 [US1] In `runtime/main.mm`, add only the private battery-policy setup state/helper described in `plan.md`: disabled returns no PowerSource, PendingPowerObservation, or initial power; enabled uses a private injected source factory, registers its callback before sampling, records and consumes the authoritative initial observation, then returns the optional policy state. Keep RuntimeBootstrap construction directly in `runNative()`: disabled/no initial power and enabled AC call `RuntimeBootstrap::start()`; enabled Battery/Unknown call `RuntimeBootstrap::startModelLess()`. If needed, use only a pure private `shouldStartModelLess(bool, std::optional<LifecyclePower>)` decision function with no startup callbacks. Extend `dev/tests/engine/native_main_test.mm` with deterministic factory, source-start, sample, and callback-registration counts, no-initial-power assertion when disabled, and the startup-selection decision cases. Run `make build/engine-tests/native-main && build/engine-tests/native-main`. Depends on T002. STOP if the option must cross the `runNative()` boundary or if RuntimeBootstrap/NativeRuntime/lifecycle classes need production changes.
- [X] T005 [US1] In `runtime/main.mm`, keep one FdTransport control handler installed in both modes; put only observation consumption and existing observe/suspend/recovery work, including its current lifecycle-specific early returns, inside `if (pendingPower)`. Keep `hasResources()`, memory-pressure/governor work, reclaim, and deferred reclaim after that branch in the shared path. Keep post-handler initial observation consumption and initial suspend progression enabled-only. Verify with the real `setupBatteryPolicy` test proving `pendingPower` is absent when disabled, plus a focused source audit of the actual `runNative()` control-handler shape showing battery-only early returns scoped inside `if (pendingPower)` and shared resource/reclaim work outside it. Run `make build/engine-tests/native-main && build/engine-tests/native-main`. Depends on T004. STOP if satisfying this requires changes to `runtime/engine/Bootstrap.*` or `runtime/engine/NativeRuntime.*`.

## Phase 4: User Story 2 - Preserve the accepted enabled behavior (Priority: P1)

**Goal**: Confirm the option gate reuses feature 001 and has not changed its enabled-mode behavior.

**Independent Test**: Existing Battery cold-start and same-generation recovery regressions pass, including the single ReadyEvent behavior and Python-visible recovery.

- [X] T006 [US2] Verification only: run `make build/engine-tests/runtime-bootstrap && build/engine-tests/runtime-bootstrap` and confirm `testBatteryColdStartCreatesOnlyTheControlShellBeforeAc()` plus `testAsyncRecoveryKeepsFdTransportResponsiveAndRevisionFenced()` pass in `dev/tests/engine/runtime_bootstrap_test.mm`; run `.venv/bin/python -m unittest dev.tests.engine.test_server_recovery.ServerRecoveryTests.test_battery_control_ready_http_recovers_on_ac_without_new_generation` for `dev/tests/engine/test_server_recovery.py`. Do not add duplicate feature 001 lifecycle tests or change its spec, plan, tasks, Bootstrap, recovery, or status protocol. Depends on T004 and T005. STOP and report the exact failure if any regression appears.

## Phase 5: Final Feature Gate

**Purpose**: Verify the complete configuration flow and review the final scope.

- [X] T007 Run the ordered feature gate: `.venv/bin/python -m unittest dev.tests.test_server.ServerTest.test_server_requires_explicit_model_and_paths`, then `.venv/bin/python -m unittest dev.tests.test_server.ServerTest.test_pause_on_battery_help`, then `make build/engine-tests/native-main` and `build/engine-tests/native-main`, then `make build/engine-tests/runtime-bootstrap` and `build/engine-tests/runtime-bootstrap`, then `.venv/bin/python -m unittest dev.tests.engine.test_server_recovery.ServerRecoveryTests.test_battery_control_ready_http_recovers_on_ac_without_new_generation`; finally run read-only `git diff --check` and `git diff --cached --check`. T005 evidence is the real `setupBatteryPolicy` test proving `pendingPower` is absent when disabled, plus a focused source audit of the actual `runNative()` control-handler shape showing battery-only early returns scoped inside `if (pendingPower)` and shared resource/reclaim work outside it. Confirm the production path set is exactly `server/server.py` and `runtime/main.mm`, and the only planned test/build paths are `dev/tests/test_server.py`, `dev/tests/engine/native_main_test.mm`, and `dev/native.mk`. Do not manipulate real battery state or run the heavy Qwen Metal suite. Depends on T001–T006; STOP and report unexpected lifecycle failures rather than broadening scope.

## Dependencies & Execution Order

```text
T001 ──> T003 ───────────────┐
                             ├──> T007
T002 ──> T004 ──> T005 ──> T006 ──┘
          └────────────────> T006
```

- T001 and T002 are independent and may run in parallel because they touch separate public Python and native argument/test-target surfaces.
- T003 depends on T001 and is the help-specific acceptance check for the public option.
- T004 depends on T002 because the native option and native-main fixture must exist before testing the owner gate.
- T005 depends on T004 because the common handler-path proof exercises the completed owner setup gate.
- T006 depends on T004 and T005 and is regression-only for the immutable feature 001 baseline.
- T007 depends on all preceding tasks.

## Parallel Execution Example

```text
Task T001: public Python flag and propagation in server/server.py + dev/tests/test_server.py
Task T002: native flag and native-main parser target in runtime/main.mm + dev/tests/engine/native_main_test.mm + dev/native.mk
```

Do not parallelize T003 with T001, or T004/T005 with each other; those tasks share files and ordered seams.

## Implementation Strategy

1. Deliver the public option and native argument contract first (T001–T003).
2. Implement the smallest owner-level policy gate and shared control path (T004–T005); the flag ends in `runNative()`.
3. Use existing feature 001 tests as the enabled-mode regression gate (T006), without duplicating its lifecycle matrix.
4. Complete the ordered final gate (T007). No feature 001 task is reopened.

## Scope Guard

Expected production files are exactly `server/server.py` and `runtime/main.mm`. Expected test/build files are exactly `dev/tests/test_server.py`, `dev/tests/engine/native_main_test.mm`, and `dev/native.mk`. Do not create implementation tasks for RuntimeBootstrap, NativeRuntime, PowerSource interfaces, StateCache, QwenState, protocol/status, backend, or frontend. If an implementation blocker makes any additional production file necessary, STOP and return to planning/review before broadening scope.
