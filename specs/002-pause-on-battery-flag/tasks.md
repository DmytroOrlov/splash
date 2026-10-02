# Tasks: Explicit Battery Suspension Opt-In

**Input**: Current design documents in `specs/002-pause-on-battery-flag/`.

**Scope**: Reconcile this task graph to the C1-corrected plan. Production edits are limited to `install/launcher.py` and the owner-local startup choice in `runtime/main.mm`. Focused test edits are limited to the existing launcher, native-main, and Bootstrap test seams. Server and inherited feature-001 evidence are verification-only. All tasks remain open.

## Phase 1: Public launcher option (Priority: P1)

**Goal**: Accept the opt-in at the public `serve` parser and forward its true-only value to the server.

**Independent Test**: T002 directly checks launcher parsing/argv and the real public `./splash` help and safe probes.

- [X] T001 [US2] In `install/launcher.py`, add `--pause-on-battery` to the public `serve` parser as `store_true`, default false, with help explaining model residency release on battery and recovery on AC without claiming all memory is freed. In `serve(args)`, forward exactly one standalone token to `server/server.py` iff true, preserving existing option order. Add no negative flag, false-valued token, environment alias, or config setting. (FR-001, FR-002, FR-007, FR-014, FR-015; SC-004, SC-007)
- [X] T002 [US2] In `dev/tests/engine/test_launcher.py`, use the existing launcher seam to prove omission=false and presence=true; with mocked `os.execve`, prove omission forwards zero and presence exactly one `--pause-on-battery` token. Add real safe subprocess evidence through `./splash serve --help` and both probes: default `./splash serve --model incoai/Qwen3.8-27B-Splash --__splash_cli_acceptance_probe__`; enabled `./splash serve --model incoai/Qwen3.8-27B-Splash --pause-on-battery --__splash_cli_acceptance_probe__`. Check each exact final argparse `unrecognized arguments:` diagnostic: it contains the deliberate probe; the enabled diagnostic does not contain `--pause-on-battery`. Each probe stops before install, download, build, server, or native startup. This is the only dedicated public-help evidence task. (FR-001, FR-002, FR-007, FR-012–FR-014; SC-004, SC-007)

## Phase 2: Disabled startup serving authorization (Priority: P1)

**Goal**: Correct C1 at the `runNative()` owner while keeping disabled mode independent of physical power and preserving enabled behavior.

**Independent Test**: T004 proves owner decisions at the native-main seam; T005 proves AC admission on existing Bootstrap residency; T007 audits actual owner wiring.

- [X] T003 [US1] In `runtime/main.mm`, implement the disabled-mode owner rule. Construct, start, and sample no `PowerSource`; select ordinary `RuntimeBootstrap::start(...)`; only after successful full bootstrap apply one synthetic AC-equivalent serving authorization through the existing Bootstrap lifecycle API. Retain no pending observer and process no later physical Battery/AC observations. Keep shared non-battery control/reclaim reachable. Enabled mode must continue using the real initial Battery/Unknown/AC observation unchanged. Do not change lifecycle APIs or propagate `pauseOnBattery` deeper. Stop if implementation appears to require production changes in `runtime/engine/*`, RuntimeBootstrap lifecycle/API, NativeRuntime lifecycle, PowerSource interfaces, `server/server.py`, backend/frontend, protocol/status/readiness. (FR-003–FR-006, FR-008, FR-012; SC-001–SC-003)

## Phase 3: Focused owner and admission evidence (Priority: P1)

**Goal**: Directly prove disabled startup authorization and reuse existing lifecycle-side admission evidence without creating another lifecycle matrix.

- [X] T004 [US1] Extend `dev/tests/engine/native_main_test.mm` using its existing seam; add no parser or production seam. Build/run `make build/engine-tests/native-main && build/engine-tests/native-main`. Prove disabled fake Battery and fake Unknown sources are never constructed, started, or sampled; disabled selects ordinary full bootstrap, selects AC-equivalent serving authorization only after successful bootstrap, and leaves no pending observer. Preserve enabled callback-registration-before-sample ordering, Battery/Unknown model-less startup, AC full startup, native flag omission/presence, and neighboring argv semantics. (FR-003–FR-005, FR-008, FR-012–FR-013; SC-001–SC-005)
- [X] T005 [US1] In `dev/tests/engine/runtime_bootstrap_test.mm::testInitialAcObservationOpensExistingBootstrapResidency`, add only missing assertions to prove AC authorization applied to already-published residency reaches `LifecycleState::Ready`, sets `inferenceReady`, opens `NativeAdmissionGate`, retains Engine, RuntimeModel, and ModelPackage, and creates no new process generation or extra ReadyEvent. Build/run the existing `build/engine-tests/runtime-bootstrap` target to verify this test. Reuse this test; do not add a lifecycle matrix. (FR-003, FR-009, FR-012–FR-013; SC-001, SC-005–SC-006)

## Phase 4: Existing lower-hop and inherited regression evidence (Priority: P1)

**Goal**: Verify existing server propagation and preserve accepted feature-001 enabled semantics.

- [X] T006 [US1] Verification only in `dev/tests/test_server.py`: check false default, true parsing, true-only exactly-once `_native_command()` forwarding and omission when false, neighboring native argv ordering, and existing internal help. Do not authorize production edits to `server/server.py`. (FR-002, FR-007, FR-012–FR-013; SC-004)
- [X] T007 [US1] After T003, perform an actual source audit of `runtime/main.mm::runNative()`: ordinary full bootstrap precedes disabled AC-equivalent authorization; authorization occurs only after successful bootstrap; disabled mode creates no observer and retains no `pendingPower`; later physical power cannot reach battery handling; battery lifecycle work and its early returns remain under `if (pendingPower)`; shared `hasResources`, memory-pressure, governor, and reclaim work remains outside that branch and reachable. This source audit proves the disabled owner reaches the shared non-battery control/reclaim path and battery-only early returns cannot intercept it. Then build/run the existing component regressions with `make build/engine-tests/native-fd-transport build/engine-tests/memory-governor`, `build/engine-tests/native-fd-transport`, and `build/engine-tests/memory-governor`: `testShutdownRequestAndControlContinuation` covers shared control/continuation behavior, and `memory-governor` covers reclaim-policy component behavior. These component tests do not prove `runNative()` wiring. Do not substitute a synthetic local-lambda test. (FR-004–FR-006, FR-012; SC-002–SC-003)
- [X] T008 [US2] After T003 and T005, verification only: run the exact inherited feature-001 Gate-F T032 regression commands: `.venv/bin/python -m unittest dev.tests.engine.test_runtime dev.tests.engine.test_protocol_python dev.tests.engine.test_server_recovery dev.tests.test_server`; then `make build/engine-tests/protocol build/engine-tests/runtime-status build/engine-tests/runtime-bootstrap build/engine-tests/native-engine-loop`; then run `build/engine-tests/protocol`, `build/engine-tests/runtime-status`, `build/engine-tests/runtime-bootstrap`, and `build/engine-tests/native-engine-loop`. Retain this as regression evidence for enabled same-generation recovery, one ReadyEvent, revision fencing, and all other accepted feature-001 invariants; do not add a lifecycle matrix. (FR-009–FR-013; SC-005–SC-006, SC-008)

## Phase 5: Final deterministic and source gate

**Purpose**: Keep acceptance open until all implementation and evidence tasks pass.

- [X] T009 Run the final deterministic/source gate after T001–T008. Include T002 launcher tests, public help and both safe probes; build/run `build/engine-tests/native-main` for T004's C1 evidence; build/run `build/engine-tests/runtime-bootstrap` for T005's strengthened Bootstrap admission test; T006 server lower-hop verification; T007's actual `runNative()` source audit plus the `native-fd-transport` and `memory-governor` component regressions; and the exact inherited Gate-F commands in T008. The source audit proves `runNative()` wiring and path reachability; the component targets prove their own existing behavior only. Perform a read-only FR-015 source/diff audit for absence of a negative flag, false-valued argv representation, environment alias, config setting, protocol/status command, or runtime mutation/toggle. Finish with `git diff --check` and `git diff --cached --check`. Do not run the manual serving command as part of this gate. (FR-001–FR-015; SC-001–SC-008)

## Phase 6: Final USER MANUAL gate

**Purpose**: User-performed real serving acceptance after the deterministic gate passes.

- [ ] T010 USER MANUAL: after T009 passes, the user runs the following on the intended macOS host and observes public option acceptance; AC full startup; enabled Battery/Unknown model-less behavior; and, if exercised, same-process-generation recovery on Battery/Unknown→AC. This may prepare/download a model and start serving, so it is performed manually by the user, not automatically by the implementation agent. Direct traceability is limited to FR-001, FR-009, SC-005, and SC-006.

  ```sh
  ./splash serve \
    --model incoai/Qwen3.8-27B-Splash \
    --max-context 256K \
    --pause-on-battery
  ```

## Dependencies & Execution Order

```text
T001 → T002 ───────────────────────────┐
T003 → T004 ───────────────────────────┤
     ├→ T005 ──────────────────────────┤
     └→ T007 ──────────────────────────┤
T006 ──────────────────────────────────┤→ T009 → T010 (USER MANUAL)
T005 → T008 ───────────────────────────┘
```

- T002 depends on the launcher parser/forwarding in T001.
- T004, T005, and T007 depend on the owner implementation in T003. T005 reuses the existing lifecycle test and adds only missing assertions.
- T006 is verification-only and independent of the focused edits. T008 depends on T003 and T005 because its inherited regression run includes the affected native/bootstrap behavior.
- T009 depends on every implementation/evidence task T001–T008; T010 follows only after T009.

## Traceability

- **FR-001**: T001–T002, T009; T010 directly observes FR-001.
- **FR-002**: T001–T002, T006, T009.
- **FR-003**: T004 disabled fake Battery/Unknown bypass → ordinary full-start selection → AC-equivalent authorization → T005 Bootstrap AC-on-existing-residency admission proof → T007 actual `runNative()` wiring audit; T009 checks the complete chain.
- **FR-004**: T004 disabled no-observation evidence; T007 no later battery handling and owner wiring; T009.
- **FR-005**: T004 disabled bypass and enabled callback/sample ordering plus Battery/Unknown/AC startup decisions; T009.
- **FR-006**: T003 preserves shared path; T007 `runNative()` source audit proves reachability and that battery-only early returns cannot intercept the path; T007 `native-fd-transport` proves existing shared control/continuation behavior and `memory-governor` proves existing reclaim-policy component behavior. Neither component test proves `runNative()` wiring; T009 aggregates all three evidence items.
- **FR-007**: T001–T002 launcher propagation; T006 server-to-native propagation; T009.
- **FR-008**: T004 native omission/presence and startup selection; T009.
- **FR-009**: T004–T005, T008, T009; T010 directly observes FR-009.
- **FR-010–FR-011**: T008 inherited Gate-F regression; T009.
- **FR-012**: T002 public acceptance, T004 owner evidence, T005 admission proof, T006 server hop, T007 actual wiring audit, T008 inherited regression; composed C1 chain: disabled fake Battery/Unknown bypass → ordinary full-start selection → AC-equivalent authorization → Bootstrap AC-on-existing-residency admission proof → actual `runNative()` wiring audit; T009 checks the full set.
- **FR-013**: T002 public boundary, T006 server hop, T004 native parse/startup choice, T005 lifecycle admission, T008 enabled recovery/ReadyEvent regression; T009.
- **FR-014**: T001 help text and T002 (the sole dedicated public-help evidence task); T009 reruns T002's help check.
- **FR-015**: T001–T002 true-only representation; T009 final read-only source/diff audit.
- **SC-001**: T004 disabled fake Battery/Unknown bypass → ordinary full-start selection → AC-equivalent authorization → T005 Bootstrap AC-on-existing-residency admission proof → T007 actual `runNative()` wiring audit; T009 checks the composed chain.
- **SC-002–SC-003**: T004 no observer/sample evidence; T007 source audit proves no later battery handling and `runNative()` shared-path reachability; T007 `native-fd-transport` and `memory-governor` prove their respective component regressions, not owner wiring; T009.
- **SC-004**: T002 public help/probes, T001–T002 launcher propagation, T006 server propagation, T004 native parse/startup; T009.
- **SC-005**: T004 enabled Battery/Unknown/AC selection, T008 inherited regression, T009; T010 directly observes SC-005.
- **SC-006**: T005 no new generation/ReadyEvent, T008 inherited recovery regression, T009; T010 directly observes SC-006 when transition is exercised.
- **SC-007**: T002 sole dedicated public-help evidence task; T009 reruns that assertion.
- **SC-008**: T008 inherited Gate-F regression; T009.

## Scope Guard

Do not schedule production changes outside `install/launcher.py` and the owner-local `runtime/main.mm` change in T003. If satisfying C1 appears to require production changes in `runtime/engine/*`, RuntimeBootstrap lifecycle/API, NativeRuntime lifecycle, PowerSource interfaces, `server/server.py`, backend/frontend, or protocol/status/readiness, stop and report the contradiction. Do not create another native parser seam or lifecycle matrix.
