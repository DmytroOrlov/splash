# Implementation Plan: Explicit Battery Suspension Opt-In

**Branch**: `002-pause-on-battery-flag` | **Date**: 2026-10-03 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-pause-on-battery-flag/spec.md`

## Summary

Add one default-false startup option, `--pause-on-battery`, to the public `serve` CLI and propagate it as a true-only native child argv option. `runNative()` owns the gate: when false it performs normal full startup without creating, starting, or sampling a power source, and skips only battery-specific control work; when true it runs the existing feature 001 observer, startup, lifecycle, and teardown path unchanged. Keep the native FdTransport control handler installed in both modes so memory-pressure and reclaim work continue.

## Technical Context

**Language/Version**: Python 3 (server CLI); C++20 / Objective-C++ (native owner and tests)

**Primary Dependencies**: Existing `argparse`, native `serve-native` argv parser, `PowerSource`, `PendingPowerObservation`, `FdTransport`, `RuntimeBootstrap`; no new dependency

**Storage**: N/A; process-start configuration only

**Testing**: `unittest` for `dev/tests/test_server.py` and `dev/tests/engine/test_server_recovery.py`; native runtime-bootstrap executable in `dev/tests/engine/runtime_bootstrap_test.mm`; focused owner/argument coverage in `dev/tests/engine/native_main_test.mm`

**Target Platform**: Existing macOS native serving path

**Project Type**: Python server CLI launching a native macOS process

**Performance Goals**: No additional power-observer setup or initial power sample when disabled; no material startup-path work beyond parsing and conditional argv construction

**Constraints**: One boolean flow only: Python option → child argv → `NativeArguments::pauseOnBattery` → `runNative()` gate. Default false. No lifecycle redesign, protocol/status change, env/config alias, negative flag, or runtime toggle. Enabled semantics must remain feature 001 behavior.

**Scale/Scope**: Two expected production files (`server/server.py`, `runtime/main.mm`), focused tests, and feature 002 design artifacts. No production semantic changes are expected in Bootstrap, NativeRuntime, PowerSource, StateCache, QwenState, backend, or frontend.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Inference correctness / explicit lifecycle ownership**: Pass. The new boolean stops at the native startup owner. Existing feature 001 lifecycle authority and native admission boundary remain untouched.
- **Preserve proven architecture**: Pass. The enabled path reuses the existing PowerSource → RuntimeBootstrap lifecycle. The disabled path uses normal full startup and has no parallel state machine.
- **Safe suspension and retained state**: Pass. No changes are planned to suspension, teardown internals, cache lifetime, restore, or recovery behavior.
- **Model-less control plane and passive readiness**: Pass. Enabled behavior remains as accepted in feature 001; disabled mode never enters battery model-less startup.
- **Deterministic evidence**: Pass with a narrow native-main ownership test seam (detailed below) to verify bypass and startup selection; existing lifecycle tests remain regression evidence.
- **Resource release claims**: Pass. Help will say “Release model residency while on battery and recover on AC power” and will not claim that all memory is freed.
- **Scope and compatibility**: Pass. The default remains historical normal serving; the user explicitly opts in to battery behavior.

No constitution exception is required.

## Repository Findings and Fixed Design

### Current seams inspected

- `server/server.py::parse_args()` owns public serving argument parsing and help. `_native_command(args)` constructs the native child argv. `main()` starts the serving path using that command.
- `dev/tests/test_server.py::ServerTest.test_server_requires_explicit_model_and_paths` already covers parser defaults and the child command's optional-argument ordering; extend it for the false/true flag. Add a focused `ServerTest` help assertion using `parse_args(["--help"])` and captured stderr/stdout as appropriate for `argparse`.
- `runtime/main.mm::NativeArguments`, `parseArguments()`, `printUsage()`, and `runNative()` own native option parsing and startup. `parseArguments()` currently accepts an optional positional cache quota followed by `--name value` option pairs. The new presence flag must be recognized as a standalone option without consuming the following option or changing existing pair parsing.
- `runNative()` unconditionally creates `PowerSource` and `PendingPowerObservation`, starts the callback, samples initial power, selects full vs model-less bootstrap, applies the initial observation, and captures pending power in the control handler.
- `PowerObservationTeardown` already checks for a null `powerSource` and shuts down `RuntimeBootstrap` afterward. Keep one teardown owner and instantiate it with a nullable source in either mode.
- The current control callback first consumes battery observations, advances suspension/recovery, and can return early while waiting for drain, while recovery is building, or when `hasResources()` is false. Memory-pressure and deferred-reclaim logic follows those branches. The disabled path must bypass the battery prefix and its lifecycle-specific early returns entirely, then run the existing shared resource/control work. Keep the handler installed in both modes.
- `dev/tests/engine/runtime_bootstrap_test.mm` contains `testBatteryColdStartCreatesOnlyTheControlShellBeforeAc()` and `testAsyncRecoveryKeepsFdTransportResponsiveAndRevisionFenced()` (the latter verifies one ReadyEvent after same-generation recovery). These prove feature 001 behavior at its current boundary; they do not invoke `runNative()`.
- No native argument or `runtime/main.mm` test target currently exposes the anonymous-namespace `parseArguments()` or injects `makeSystemPowerSource()` into `runNative()`. `dev/tests/engine/test_server_recovery.py::ServerRecoveryTest.test_battery_control_ready_http_recovers_on_ac_without_new_generation` covers the Python-visible recovery contract.

### Configuration flow

`server/server.py::parse_args()` (`args.pause_on_battery`, default false) → `_native_command(args)` (append `--pause-on-battery` exactly once only when true) → `runtime/main.mm::parseArguments()` (`NativeArguments::pauseOnBattery`, default false) → `runNative()`.

No option is added below `runNative()`. Do not add configuration to RuntimeBootstrap, NativeRuntime, StateCache, QwenState, PowerSource, protocol/status messages, Python readiness, or server request handling.

### Native argument parsing

- Add exactly `bool pauseOnBattery = false` to `NativeArguments`.
- Recognize standalone `--pause-on-battery` by consuming one argv element and setting the field true, without consuming or shifting the following option/value. Omission is false and presence is true. Preserve existing parser behavior for repeated options and malformed argv; do not introduce a new duplicate-option policy for this flag. `_native_command()` emits the token at most once.
- Add the flag to `printUsage()`'s optional arguments because native usage lists accepted options.
- Do not serialize false to argv; omission is the false default.

### runNative() and control-handler ownership

- Keep `MemoryPressureMonitor`, `FdTransport`, `RuntimeMetrics`, and the control handler alive in both modes.
- Declare `std::unique_ptr<engine::PowerSource> powerSource;` and `std::shared_ptr<engine::PendingPowerObservation> pendingPower;` as empty by default.
- Only inside `if (arguments.pauseOnBattery)`: create both objects, start the observer callback, record the synchronous initial sample after callback registration, and consume the latest authoritative initial observation. Preserve that ordering exactly.
- Construct the existing `PowerObservationTeardown(powerSource, bootstrap)` once after the optional observer setup, so enabled teardown still stops the observer before bootstrap lifecycle shutdown and disabled null-source teardown remains valid.
- During bootstrap selection, use `RuntimeBootstrap::startModelLess()` for enabled Battery/Unknown; use `RuntimeBootstrap::start()` for enabled AC; when disabled, unconditionally use `RuntimeBootstrap::start()` without any power sample or observation-derived branch.
- After bootstrap publication, call `observePower(initialPower)` only in enabled mode.
- Install one `FdTransport` control handler in both modes. Capture nullable `pendingPower` and branch on its presence for the battery-specific prefix only. With a pending observer, preserve the existing sequence: take latest observation → `observePower()` → `beginSuspend()` → `advanceSuspend()` → `advanceRecovery()` and preserve its current enabled-mode lifecycle retry/early-return semantics. With no observer, execute none of these battery operations.
- Keep the control flow in this order, with the lifecycle early returns scoped inside the `if (pendingPower)` branch:

  ```text
  controlHandler() {
    if (pendingPower) {
      consume observation
      observePower
      begin/advance suspend
      advance recovery
      // existing enabled-mode lifecycle-specific early returns stay here
    }

    // common path in both modes
    if (!published->hasResources())
      return false
    memory pressure / governor / reclaim / deferred reclaim
  }
  ```

  Do not move `hasResources()`, memory-pressure handling, or reclaim inside the battery branch. Disabled mode must reach the common path and cannot hit the battery-only `WaitingForDrain` or `Building` returns. In enabled model-less state, the common `hasResources()` guard still avoids model-bound reclaim work.
- After registering the handler, consume a pending initial power observation and invoke initial suspend progression only in enabled mode. Then run `FdTransport` normally in either mode.

### Test seam decision

A seam is required at the `runtime/main.mm` startup-owner boundary: the production owner hard-codes `makeSystemPowerSource()`, while direct parser access is private to `main.mm`, and existing fake-source tests exercise `RuntimeBootstrap`/`FdTransport` below the owner. Add `dev/tests/engine/native_main_test.mm` and register `build/engine-tests/native-main` in `dev/native.mk`. Compile the private native-main code into that test translation unit with a narrowly named test-only guard that suppresses only the production `main()` entry point; do not extract the option parser into a new production module. Add a private battery-policy setup helper/state used by `runNative()` whose only responsibility is to return no source, pending observation, or initial power when disabled, and when enabled to create the source through a private injected factory, register the callback before sampling, and return the pending observation plus consumed authoritative initial power. Production supplies `makeSystemPowerSource()`; the test supplies a counting fake factory. Keep all `RuntimeBootstrap` construction directly in `runNative()` with explicit branches: disabled policy or enabled AC calls `RuntimeBootstrap::start()`; enabled Battery/Unknown calls `RuntimeBootstrap::startModelLess()`. If deterministic unit coverage needs it, add only a tiny pure private decision function equivalent to `shouldStartModelLess(pauseOnBattery, std::optional<LifecyclePower> initialPower)`; it accepts and invokes no startup callbacks. The fixture proves zero factory/sample/callback setup when disabled, observer-before-sample when enabled, and the pure startup decision for disabled with no initial power, enabled Battery/Unknown, and enabled AC. Keep the real lifecycle behavior in the existing Bootstrap tests; the setup helper must not replace or wrap the lifecycle owner. Exercise a control tick with no pending observer and a sentinel at the shared common-control section to prove disabled policy reaches it rather than a battery-only early return; do not reproduce the memory governor. The seam must not add a public test API, alter PowerSource interfaces, or propagate the option into lifecycle classes.

This seam is solely for testing the new owner gate, not a redesign of the completed lifecycle.

## Project Structure

### Documentation (this feature)

```text
specs/002-pause-on-battery-flag/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── contracts/
    └── cli-and-native-argv.md
```

### Source Code (repository root)

```text
server/server.py
runtime/main.mm
dev/tests/test_server.py
dev/tests/engine/runtime_bootstrap_test.mm
dev/tests/engine/test_server_recovery.py     # regression only unless a public behavior gap is exposed
dev/tests/engine/native_main_test.mm          # focused owner/parser test seam
dev/native.mk                                 # register build/engine-tests/native-main
```

**Structure Decision**: Preserve the existing single Python CLI + native runtime layout. Expected production edits are limited to `server/server.py` and `runtime/main.mm`. Add the named native-main fixture and target because current tests do not reach the owner-level gate or native parser.

## Implementation and Validation Plan

1. **Python option and help**: Add `--pause-on-battery` as `store_true` with default false and concise help text. Extend `ServerTest.test_server_requires_explicit_model_and_paths` for false default, true parsing, false argv omission, true exactly-once propagation; add help wording assertion.
2. **Native argv and owner gate**: Add the default-false `NativeArguments` field and standalone parser option. Make native usage list it. Gate power source creation, callback registration, initial sample, initial observe/suspend/recovery, and power-dependent startup selection inside `runNative()`.
3. **Preserve shared control work**: Leave the FdTransport handler installed. Put only the existing power-observation and lifecycle prefix behind observer presence; keep shared memory-pressure/reclaim logic after the conditional prefix. Ensure no battery-prefix early return is reachable in false mode.
4. **Focused native-owner evidence**: Add `dev/tests/engine/native_main_test.mm` and `build/engine-tests/native-main` as described above. Prove omitted/present native arg, unrelated args unchanged when the standalone flag is inserted beside existing `--name value` pairs, observer factory/sample/registration counts, and the pure startup decision for disabled with no initial power, enabled Battery/Unknown, and enabled AC. Exercise a control tick with no pending observer and verify it reaches the shared common path; do not duplicate the memory governor or lifecycle matrix. Use deterministic counters/barriers, not sleeps.
5. **Enabled regression evidence**: Keep `testBatteryColdStartCreatesOnlyTheControlShellBeforeAc()` and `testAsyncRecoveryKeepsFdTransportResponsiveAndRevisionFenced()` unchanged as feature 001 regression gates; add no duplicate lifecycle matrix. Keep `ServerRecoveryTest.test_battery_control_ready_http_recovers_on_ac_without_new_generation` as the Python-observed same-generation/one-ready regression.
6. **Ordered validation**:
   1. Focused Python CLI/server tests: `python3 -m unittest dev.tests.test_server.ServerTest.test_server_requires_explicit_model_and_paths` plus the new help test.
   2. Focused native-main argument/owner target (new native test target registered in `dev/native.mk`).
   3. Existing native lifecycle regression: `build/engine-tests/runtime-bootstrap` (covers model-less Battery startup and revision-fenced same-generation recovery).
   4. Python recovery regression: `python3 -m unittest dev.tests.engine.test_server_recovery.ServerRecoveryTest.test_battery_control_ready_http_recovers_on_ac_without_new_generation`.
   5. Review whitespace with `git diff --check` and `git diff --cached --check` after implementation. These are read-only checks; no battery manipulation or heavy Qwen Metal suite is required for this gate.

## Complexity Tracking

No constitution violations. The one narrow native-main test seam is justified because the current `runNative()` directly constructs the system power observer and the existing fake power tests start below that ownership boundary; deterministic proof of “no observer/sample when disabled” is otherwise unavailable without hardware-dependent testing.
