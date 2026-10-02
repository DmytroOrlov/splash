# Implementation Plan: Explicit Battery Suspension Opt-In

**Branch**: `002-pause-on-battery-flag` | **Date**: 2026-10-06 | **Spec**: [spec.md](spec.md)

## Summary

Complete the public `./splash serve` option path and correct the disabled-mode startup admission defect found by the C1 source audit. The expected production changes are the missing public option/forwarding in `install/launcher.py` and an owner-local startup authorization in `runtime/main.mm::runNative()`. Disabled mode must retain ordinary full bootstrap while authorizing its published residency to serve through the existing Bootstrap lifecycle API, without observing physical power. Enabled mode continues using the real initial power observation exactly as today. The option still terminates at `runNative()`; no deeper lifecycle or interface changes are planned.

## Technical Context

**Language/Version**: Python 3.12–3.14 launcher/server; C++20 / Objective-C++ native runtime (existing implementation)

**Primary Dependencies**: Existing `argparse`, `os.execve`, server argv construction, native `serve-native` parser; no new dependency or shared option abstraction

**Storage**: N/A; process-start option only

**Testing**: Real `./splash serve` help/probe checks for public parsing; `dev/tests/engine/test_launcher.py` exec seam for launcher→server argv; extended `dev/tests/engine/native_main_test.mm` fake-power owner evidence; existing `runtime_bootstrap_test.mm::testInitialAcObservationOpensExistingBootstrapResidency` for AC-on-residency admission; focused `runNative()` source audit; server and feature 001 lifecycle/recovery regressions.

**Target Platform**: Public macOS serving command, with launcher argument parsing runnable independently of native execution

**Project Type**: Shell public executable → Python launcher → Python server → native serving process

**Performance Goals**: No material startup work beyond parse and conditional argv construction

**Constraints**: Opt-in, default false; preserve enabled feature 001 behavior; disabled mode bypasses all physical power observation and uses a synthetic AC-equivalent serving authorization selected solely by the false option. Configuration terminates at `runNative()`. No negative flag, env/config/protocol/runtime toggle. Do not redesign parser ownership or lifecycle architecture.

## Constitution Check

- **Inference correctness and lifecycle ownership**: Pass. `runNative()` remains the native policy owner; no lifecycle classes receive the option.
- **Proven architecture**: Pass. Keep the option at the public launcher and `runNative()` owner; use the existing Bootstrap lifecycle API and admission gate.
- **Deterministic evidence**: Pass with real public help/probes, fake-power native-owner checks, existing Bootstrap admission proof, and actual-owner wiring audit. These compose at each real transformation edge without a monolithic process test.
- **Scope and compatibility**: Pass. Disabled mode remains independent of physical power and gains serving authorization after successful full bootstrap. Enabled option semantics remain unchanged; no changes below `runNative()`.
- **Memory claims**: Pass. Public help will explain model residency release and AC recovery without promising all memory is freed.

No constitution exception is required.

## Repository Findings

### Public and internal argv ownership

1. `./splash` resolves its own symlink to the repository, selects Python 3.12–3.14, then `exec`s `install/launcher.py` with the original arguments.
2. `install/launcher.py::parse_args()` owns the public `serve` parser and `./splash serve --help`. Its current `serve` parser has no `--pause-on-battery`, causing the reported rejection before the server starts. `install/launcher.py::serve()` builds argv for `server/server.py` and then `os.execve`s it; it currently has no conditional battery flag forwarding.
3. `server/server.py::parse_args()` already accepts `--pause-on-battery`, defaults it to false, and owns internal server help. `_native_command(args)` already appends the true-only token exactly once when enabled.
4. `runtime/main.mm::parseNativeOptions()` already parses the standalone token; `NativeArguments::pauseOnBattery` defaults false; `printUsage()` lists it. `runNative()` currently constructs/publishes full residency in disabled mode but skips the initial `observePower()` lifecycle transition, leaving `power=Unknown`, `state=RecoveryFailed`, `modelResident=true`, `inferenceReady=false`, and NativeAdmissionGate closed. Enabled mode resolves admission with its real initial observation.
5. Disabled startup has no `PowerSource`, pending observation, or initial sample. After ordinary full bootstrap succeeds, `runNative()` must apply one synthetic AC-equivalent serving authorization through the existing Bootstrap lifecycle API. This value expresses option policy, not physical power; no observer is created and no later Battery/AC changes are processed.

### Existing test seams

- `dev/tests/engine/test_launcher.py` directly calls `launcher.main()` and stubs `os.execve` in `test_foreground_exec_preserves_terminal_and_holds_lock`; its setup also stubs model installation and the port socket. Extend this seam to assert flag absence/presence at the launcher→server argv boundary without model downloads or native execution. This is lower-hop propagation evidence; a direct `launcher.main()` call is not the outer executable boundary.
- Use two safe real-executable checks. **Help/declaration:** `./splash serve --help` (or the flag-present help form) must exit 0 and show the option plus its required semantics; this proves shell dispatch and public help/declaration only. **Exact-token recognition:** run `./splash serve --model incoai/Qwen3.8-27B-Splash --pause-on-battery --__splash_cli_acceptance_probe__` and inspect the final `error: unrecognized arguments:` diagnostic. After the flag is implemented, the unique probe must be listed and `--pause-on-battery` must not be listed there. Before the fix, both are listed. This deliberately fails in argparse before `main()` can call `serve()`, so it causes no install, download, build, server, or native startup. Do not infer token recognition from help exit or from the flag appearing elsewhere in help/usage output.
- Existing `dev/tests/test_server.py` covers the server default, server help, and `_native_command()` propagation; retain these as lower-hop regression evidence.
- Extend existing `dev/tests/engine/native_main_test.mm` to deterministically prove disabled fake Battery and Unknown sources are never constructed/started/sampled, ordinary full bootstrap is selected, the owner selects AC-equivalent authorization after successful bootstrap, and no pending observer remains. Keep enabled callback-before-sample, Battery/Unknown model-less, and AC full-start checks.
- Reuse `runtime_bootstrap_test.mm::testInitialAcObservationOpensExistingBootstrapResidency` for the lifecycle-side proof: AC applied to already-published residency reaches Ready, enables inference, opens NativeAdmissionGate, retains Engine and installed RuntimeModel/ModelPackage, and creates no new generation or extra ReadyEvent. Strengthen only the smallest assertion missing from this seam.
- Audit actual `runNative()` wiring to prove full start, post-success disabled authorization, no observer/pendingPower and no later physical power reactions, with the shared non-battery control/reclaim path intact. Retain enabled feature 001 recovery tests unchanged.

## Corrected Propagation Graph

```text
./splash [symlink resolution + Python selection]
  → install/launcher.py::parse_args() [public serve option + public help]
  → install/launcher.py::serve() [server argv forwarding]
  → server/server.py::parse_args() [internal option]
  → server/server.py::_native_command() [native argv forwarding]
  → runtime/main.mm::parseArguments()/parseNativeOptions()
  → NativeArguments::pauseOnBattery
  → runNative() [startup-policy gate; endpoint of configuration]
```

The user-facing help owner is `install/launcher.py`; the required help surface is exercised by `./splash serve --help`. Exact token recognition is separately exercised with the deliberate unknown-probe invocation above. Internal server/native help remains separate lower-level evidence and cannot replace public help or recognition evidence.

## Design Decisions

- Add `--pause-on-battery` to the outer `serve` parser as `store_true`, default false, with help equivalent to “Release model residency while on battery and recover on AC power.”
- Forward the token from launcher to server only when true. Do not add a common option abstraction for this single startup flag.
- Reuse existing server parse→native argv implementation. In `runNative()`, enabled mode continues to apply its real initial Battery/Unknown/AC observation. Disabled mode makes no power source, observer, pending observation, or sample; after successful ordinary `RuntimeBootstrap::start(...)`, it applies a single synthetic AC-equivalent lifecycle authorization through the existing Bootstrap API so published residency becomes inference-ready.
- The synthetic AC-equivalent value is configuration-policy intent selected solely because `pauseOnBattery == false`; it is not a physical sample. No subsequent physical Battery/AC observation is processed in disabled mode.
- Keep the option out of Bootstrap/NativeRuntime/PowerSource, protocol, status/readiness, environment, config, and runtime mutation.

## Expected Patch

**Production**: `install/launcher.py` for outer option declaration/help and conditional forwarding; `runtime/main.mm` for owner-local disabled startup authorization after successful ordinary full bootstrap.

**Tests**: `dev/tests/engine/test_launcher.py` retains public help/probe and launcher/server argv evidence. Extend existing `dev/tests/engine/native_main_test.mm` for disabled fake Battery/Unknown bypass, full-start selection, owner authorization choice, and absent pending observer. Reuse and minimally strengthen `runtime_bootstrap_test.mm::testInitialAcObservationOpensExistingBootstrapResidency` for admission on existing residency. Add no monolithic process test or duplicate lifecycle matrix. Audit actual `runNative()` wiring and retain existing server and enabled lifecycle/recovery regressions.

No production changes are planned in `runtime/engine/*`, RuntimeBootstrap lifecycle, NativeRuntime lifecycle, PowerSource interfaces, server, protocol/status/readiness, or backend/frontend. The fix is owner-local in `runNative()` and reuses existing lifecycle API. The existing native-main and Bootstrap seams provide compositional evidence.

## Acceptance Evidence Strategy

Use this compositional boundary→evidence chain; each check proves only its named hop:

The boundary→evidence matrix separates declaration from recognition and propagation:

1. **Public help/option declaration**: real `./splash serve --help`; assert exit 0 and flag plus required model-residency/AC-recovery wording. This proves shell dispatch and the public help surface, not recognition of a token supplied to this invocation.
2. **Default-mode outer public probe**: real `./splash serve --model incoai/Qwen3.8-27B-Splash --__splash_cli_acceptance_probe__`; inspect the final `error: unrecognized arguments:` diagnostic and require the unique probe to appear. It deliberately stops in public argparse before serving. This proves the real public executable/serve command shape without the battery flag is accepted up to the deliberate probe; it does not inspect the parsed boolean value.
3. **Enabled outer public probe**: real `./splash serve --model incoai/Qwen3.8-27B-Splash --pause-on-battery --__splash_cli_acceptance_probe__`; inspect the final diagnostic and require the unique probe to appear and `--pause-on-battery` to be absent. It proves exact public token recognition and safely stops before serving.
4. **Launcher→server propagation**: existing `test_launcher.py` `launcher.main()` + mocked `os.execve` seam; true produces exactly one token, omission none. The omitted case is the direct default-false evidence paired with the default-mode public probe. This direct call is propagation evidence, not outer executable evidence.
5. **Server parse and server→native propagation**: existing `test_server.py` checks false default, true acceptance, omission, and exactly-one token from `_native_command()`.
6. **Native owner / disabled fake-power evidence**: extend the existing `native_main_test.mm` seam. For configured fake Battery and Unknown in disabled mode, prove no source construction/start/sample, ordinary full bootstrap selection, AC-equivalent authorization selection after successful full bootstrap, and no pending observer afterward. Preserve enabled registration-before-sample and Battery/Unknown model-less, AC full-start evidence.
7. **Existing Bootstrap admission evidence**: reuse `runtime_bootstrap_test.mm::testInitialAcObservationOpensExistingBootstrapResidency`. Prove applying AC to already-published model residency reaches Ready, sets inferenceReady, opens NativeAdmissionGate, retains Engine and installed RuntimeModel/ModelPackage, and does not create another process generation or ReadyEvent. Strengthen only missing assertions in this test.
8. **Actual-owner wiring audit**: inspect `runtime/main.mm::runNative()` and confirm disabled mode selects ordinary `RuntimeBootstrap::start(...)`, then applies AC-equivalent authorization only after successful bootstrap; creates no observer, retains no `pendingPower`, and therefore cannot react to later physical Battery/AC changes. Confirm the shared non-battery control/reclaim path remains reachable. This is a source audit, not a monolithic test.
9. **Shared control/reclaim component regressions**: existing `native_fd_transport_test.cpp::testShutdownRequestAndControlContinuation` and `memory_governor_test.cpp` reclaim-policy tests cover their respective shared components; they do not by themselves prove `runNative()` wiring.
10. **Focused feature 001 startup/recovery subset**: `runtime_bootstrap_test.mm::testBatteryColdStartCreatesOnlyTheControlShellBeforeAc` and `test_server_recovery.py::test_battery_control_ready_http_recovers_on_ac_without_new_generation` cover enabled Battery startup and same-generation AC recovery. `test_server_recovery.py::test_same_generation_recovery_updates_context_without_new_handshake` covers the narrower context/recovery claim. These cases do not stand in for the full inherited Gate-F set.
11. **Inherited accepted feature 001 Gate-F regression**: the full Gate-F T032 command set is documented under Validation Plan and Quickstart; it is the inherited evidence for FR-010, FR-011, and SC-008.
12. **Final source/diff scope audit**: read-only inspection of the final implementation diff and source for FR-015 exclusions; see the explicit scope audit under Validation Plan.

Do not call an internal server parser test or direct `launcher.main()` invocation the outer executable boundary. Do not treat help output or exit status as proof that a supplied flag token was recognized. Do not add a production seam to combine these existing boundaries into one test.

### Requirement Traceability

The evidence names below refer to the deterministic checks and regression suites above; entries identify the evidence that directly covers each requirement. Composed evidence follows the clarified spec's boundary rule and does not infer propagation between tests.

| Requirement | Named evidence |
|---|---|
| FR-001 | Public help/option declaration; enabled outer public probe; launcher→server propagation; server parse/server→native propagation |
| FR-002 | Default-mode outer public probe; launcher→server propagation (omission/default false); server parse/server→native propagation (false default and omission); native parse/startup semantics (omitted default) |
| FR-003 | Disabled native-owner fake Battery/Unknown bypass → ordinary full-start selection → AC-equivalent authorization → existing Bootstrap AC-on-residency admission proof → actual `runNative()` wiring audit; inherited Gate-F regression |
| FR-004 | Disabled-mode native-owner evidence plus disabled `runNative()` source audit (no observer and battery-specific prefix unreachable) |
| FR-005 | Disabled-mode native-owner evidence in `native_main_test.mm::testBatteryPolicySetupGateAndStartupDecision` |
| FR-006 | Disabled-mode native-owner evidence plus disabled `runNative()` source audit; shared component regression evidence from `native_fd_transport_test.cpp::testShutdownRequestAndControlContinuation` and `memory_governor_test.cpp` |
| FR-007 | Launcher→server propagation; server parse/server→native propagation; native parse/startup semantics |
| FR-008 | Native parse/startup semantics and disabled-mode native-owner evidence in `native_main_test.mm` |
| FR-009 | Native parse/startup semantics (Battery/Unknown model-less selection; AC full-startup selection); focused feature 001 startup/recovery subset |
| FR-010 | Inherited accepted feature 001 Gate-F T032 regression command set |
| FR-011 | Inherited accepted feature 001 Gate-F T032 regression command set |
| FR-012 | Public help/option declaration and probes; launcher→server; server→native; disabled fake Battery/Unknown bypass → ordinary full-start selection → AC-equivalent authorization → Bootstrap AC-on-residency admission proof → actual `runNative()` wiring audit; inherited Gate-F regressions |
| FR-013 | Public help/option declaration; enabled outer public probe; launcher→server; server parse/server→native; native parse/startup; focused feature 001 startup/recovery subset |
| FR-014 | Public help/option declaration (`./splash serve --help`) |
| FR-015 | Final source/diff scope audit (no negative flag, false-valued argv, environment alias, config setting, protocol/status command, or runtime mutation); parser tests cover the positive true-only representation |

### Success-Criterion Traceability

| Success criterion | Named evidence |
|---|---|
| SC-001 | Disabled fake Battery/Unknown bypass → ordinary full-start selection → AC-equivalent authorization → existing Bootstrap AC-on-residency admission proof → actual `runNative()` wiring audit; inherited Gate-F regression |
| SC-002 | Disabled-mode native-owner evidence plus disabled `runNative()` source audit (no observer or battery-specific control prefix) |
| SC-003 | Disabled-mode native-owner evidence plus disabled `runNative()` source audit for shared path reachability; `native_fd_transport_test.cpp::testShutdownRequestAndControlContinuation` and `memory_governor_test.cpp` prove their respective shared components |
| SC-004 | Public help/option declaration; default-mode and enabled outer public probes; launcher→server; server parse/server→native; native parse/startup semantics |
| SC-005 | Native parse/startup semantics; focused feature 001 startup/recovery subset |
| SC-006 | `test_server_recovery.py::test_same_generation_recovery_updates_context_without_new_handshake` and inherited Gate-F regression |
| SC-007 | Public help/option declaration (`./splash serve --help`) |
| SC-008 | Inherited accepted feature 001 Gate-F T032 regression command set |

## Final Manual User-Command Smoke

After deterministic automated validation passes, perform this separate manual acceptance smoke on the intended macOS host:

```sh
./splash serve \
  --model incoai/Qwen3.8-27B-Splash \
  --max-context 256K \
  --pause-on-battery
```

Observe that the public CLI accepts `--pause-on-battery`. On AC, enabled policy must retain normal full startup. On Battery or Unknown, it must retain feature 001's fail-closed, model-less behavior. If a Battery/Unknown-to-AC transition is exercised, verify established same-process-generation recovery. This manual command may proceed into real model preparation and native serving; it supplements, and does not replace, the deterministic automated evidence above.

## Validation Plan (after implementation)

1. Flag-present public help invocation through `./splash`, then focused launcher argv propagation tests.
2. Existing focused server option/help tests.
3. Existing native-main argument/setup target.
4. Existing feature 001 runtime-bootstrap and Python recovery tests as regression evidence.
5. Run the inherited accepted feature 001 Gate-F T032 commands below for SC-008 and the full preserved lifecycle invariant set:

   ```sh
   .venv/bin/python -m unittest \
     dev.tests.engine.test_runtime \
     dev.tests.engine.test_protocol_python \
     dev.tests.engine.test_server_recovery \
     dev.tests.test_server

   make build/engine-tests/protocol \
     build/engine-tests/runtime-status \
     build/engine-tests/runtime-bootstrap \
     build/engine-tests/native-engine-loop
   build/engine-tests/protocol
   build/engine-tests/runtime-status
   build/engine-tests/runtime-bootstrap
   build/engine-tests/native-engine-loop
   ```

6. Perform the final source/diff scope audit for FR-015 using read-only inspection of the implementation diff and source. Confirm there is no negative flag, false-valued argv representation, environment alias, config-file setting, protocol/status command, or runtime mutation/toggle. The true-only parser behavior is covered by the named launcher/server/native parser evidence above.
7. After the deterministic automated checks and scope audit pass, perform the separate manual real-command smoke in **Final Manual User-Command Smoke** as the final acceptance layer.

This planning task does not run tests. No lifecycle implementation work is expected.

## Checklist Status

`checklists/requirements.md` exists. Its assertions are generic spec-quality checks and are not obviously false, but the checklist was checked before the material 2026-10-06 public-boundary clarification. Revalidate the “testable and unambiguous requirements,” “acceptance criteria,” and “feature readiness” assertions against the clarified outer CLI/help requirements before task generation. In particular, do not treat the internal server parser/help coverage as satisfying public acceptance/help.

Tasks remain unchanged and are not generated or regenerated in this planning pass.
