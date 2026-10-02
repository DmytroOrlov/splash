# Quickstart: Validate Explicit Battery Suspension Opt-In

## Prerequisites

- macOS development toolchain and the repository's configured Python/native build environment.
- No real battery-state change is needed. The native owner test uses a fake source.

## Focused validation order

1. Run the focused public parser/argv and help tests after implementation:

   ```sh
   python3 -m unittest dev.tests.test_server.ServerTest.test_server_requires_explicit_model_and_paths
   python3 -m unittest dev.tests.test_server.ServerTest.test_pause_on_battery_help
   ```

   Expected: omitted flag parses false and emits no child token; present flag parses true and emits one token; help contains the option and accurate semantics.

2. Build and run the focused native-main argument/owner test target added for this feature:

   ```sh
   make build/engine-tests/native-main
   build/engine-tests/native-main
   ```

   Expected: omitted native option is false; present option is true without shifting adjacent existing `--name value` pairs; disabled setup makes no power factory/sample/observer-registration calls; enabled setup registers before sampling. The pure startup decision is full when disabled with no initial power, model-less for enabled Battery/Unknown, and full for enabled AC. A no-observer control tick reaches the shared common-control sentinel. RuntimeBootstrap construction remains directly in `runNative()` and its existing lifecycle behavior is covered by the regression target below.

3. Run the existing feature 001 native lifecycle regression:

   ```sh
   build/engine-tests/runtime-bootstrap
   ```

   Expected: cold Battery start, revision-fenced same-generation recovery, and the single ReadyEvent behavior remain valid.

4. Run the existing Python recovery regression:

   ```sh
   python3 -m unittest dev.tests.engine.test_server_recovery.ServerRecoveryTest.test_battery_control_ready_http_recovers_on_ac_without_new_generation
   ```

   Expected: the existing public recovery behavior remains unchanged.

5. Review the implementation diff for whitespace with `git diff --check` and `git diff --cached --check`.

## Scope of this gate

Do not run real battery manipulation or the heavy Qwen Metal suite for this configuration-only change. Run the broader feature 001 regression suite only if implementation edits lifecycle code, which this plan does not expect.
