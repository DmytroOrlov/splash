# Quickstart: Validate Public Battery Suspension Opt-In

## Prerequisites

- Run on a development checkout with the repository's supported Python installed.
- No model download, native build, or real battery-state change is needed for the public parser/argv checks.

## Focused validation order

1. **Public help surface and declaration** — run from the repository root:

   ```sh
   ./splash serve --help
   ```

   Expected: exit 0; help includes `--pause-on-battery` and describes model residency release on battery and recovery on AC without claiming all memory is freed. This proves shell dispatch and public help/declaration only; it does not prove recognition of an exact supplied flag token.

2. **Default-mode outer public probe** — invoke:

   ```sh
   ./splash serve \
     --model incoai/Qwen3.8-27B-Splash \
     --__splash_cli_acceptance_probe__
   ```

   Expected: the final `error: unrecognized arguments:` diagnostic contains `--__splash_cli_acceptance_probe__`. The deliberate unknown token stops in public argparse before serving. This proves the real public executable/serve command shape without `--pause-on-battery` is accepted up to the probe; it does not introspect the parsed boolean value. Combine it with the launcher omission/default-false evidence below to establish the public/default-false chain.

3. **Enabled outer public probe** — invoke:

   ```sh
   ./splash serve \
     --model incoai/Qwen3.8-27B-Splash \
     --pause-on-battery \
     --__splash_cli_acceptance_probe__
   ```

   Expected after the fix: argparse fails before serving; the final `error: unrecognized arguments:` diagnostic contains the deliberate probe and does not contain `--pause-on-battery`. Before the fix, both are listed. Inspect that diagnostic specifically; the usage line may legitimately contain the registered flag. This executes real shell/Python dispatch and public parsing, but the deliberate unknown token stops the command before install, download/build, server, or native startup.

4. **Launcher→server argv** — extend/run the existing launcher tests in `dev/tests/engine/test_launcher.py`. Exercise `launcher.main()` with its real parser while stubbing installation, port probing, and `os.execve`. This is the launcher propagation hop, not the shell executable boundary.

   Expected: the opted-in invocation reaches the intercepted server exec with exactly one `--pause-on-battery`; the default invocation reaches it without the token and has `pause_on_battery == false`. Pair the default case with the default-mode outer public probe; the outer probe alone does not reveal the boolean value. No model/native process starts.

5. **Server parse and server→native argv** — run the focused assertions in `dev/tests/test_server.py`.

   Expected: default false, opt-in accepted, internal help wording correct, and `_native_command()` forwards exactly one true-only native token.

6. **Native argument and owner gate evidence** — extend/run the existing `native_main_test.mm` target.

   Expected: omitted native option remains false; presence is parsed without shifting neighboring option/value pairs. With disabled mode and fake sources configured as Battery and Unknown, prove no source is constructed, started, or sampled; ordinary full bootstrap is selected; the owner selects AC-equivalent serving authorization after successful bootstrap; and no pending observer remains. Enabled callback registration still precedes the real initial sample; Battery/Unknown selects model-less startup and AC selects full startup.

7. **Existing Bootstrap admission evidence** — reuse `runtime_bootstrap_test.mm::testInitialAcObservationOpensExistingBootstrapResidency` as the lifecycle-side proof. Applying AC to already-published model residency must reach `LifecycleState::Ready`, set `inferenceReady`, open `NativeAdmissionGate`, retain Engine and an installed RuntimeModel/ModelPackage, and create no process generation or extra ReadyEvent. Strengthen only the smallest missing assertion in this existing test; do not add a duplicate lifecycle matrix.

8. **Actual `runNative()` wiring audit** — inspect `runtime/main.mm::runNative()`. Prove the disabled owner calls ordinary `RuntimeBootstrap::start(...)`, applies AC-equivalent authorization only after successful full bootstrap, creates no power observer, retains no `pendingPower`, and therefore cannot react to later physical Battery/AC changes. Confirm the shared non-battery control/reclaim path remains reachable. This source audit connects the native-owner choice to the existing Bootstrap admission proof; it is not a monolithic process test. The existing `native_fd_transport_test.cpp::testShutdownRequestAndControlContinuation` and `memory_governor_test.cpp` reclaim-policy tests prove their components only.

8. **Inherited accepted feature 001 Gate-F regression** — run the exact T032 command set from `specs/001-battery-aware-suspension/tasks.md`:

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

   This accepted Gate-F set is inherited regression evidence for the cross-language readiness/freshness and process-failure paths, effective context, passive status, recovery races, same-generation lifecycle behavior, and exactly one ReadyEvent. It adds no new lifecycle matrix.

9. **Final FR-015 source/diff scope audit** — after implementation, read-only inspect the final source and complete working-tree diff. Confirm it adds no negative flag, false-valued argv representation, environment alias, config-file setting, protocol/status command, or runtime mutation/toggle. Parser tests above establish the positive true-only token; the final scope audit establishes these exclusions.

## Final Manual User-Command Smoke

Run this separate manual acceptance smoke after the deterministic automated validation above passes, from the repository root on the intended macOS host:

```sh
./splash serve \
  --model incoai/Qwen3.8-27B-Splash \
  --max-context 256K \
  --pause-on-battery
```

Expected observations:

- The public CLI accepts `--pause-on-battery` and does not reject the option.
- On AC, enabled policy retains normal full startup.
- On Battery or Unknown, feature 001's established fail-closed, model-less behavior remains in force.
- If a Battery/Unknown-to-AC transition is exercised, recovery follows the established same-process-generation behavior.

This command may proceed into real model preparation and native serving. This manual smoke is the final real-command acceptance layer; it supplements and does not replace the deterministic automated evidence.

The ownership and argv details are in [the CLI/native contract](contracts/cli-and-native-argv.md); this sequence documents validation and expected observations, not implementation code.
