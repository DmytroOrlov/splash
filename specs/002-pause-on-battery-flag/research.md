# Research: Public Battery Opt-In Propagation

## Decision 1: Make the outer launcher the public option owner

**Decision**: Declare the flag on `install/launcher.py::parse_args()`'s `serve` subparser, because `./splash` dispatches directly to this module and this parser owns `./splash serve --help`.

**Evidence**: The top-level `splash` shell script resolves its symlink and execs Python with `install/launcher.py`. The launcher parser currently lacks the flag. The observed argparse rejection therefore happens before `server/server.py` is entered.

**Alternatives considered**: Adding the option only to the server parser is insufficient and is already implemented. Moving public parsing to another module would redesign ownership to deduplicate one option and is unnecessary.

## Decision 2: Forward through the existing launcher-to-server argv

**Decision**: Add the true-only `--pause-on-battery` token to the argv built in `install/launcher.py::serve()` only when the parsed launcher value is true.

**Evidence**: The launcher constructs the `server/server.py` exec argv in one list in `serve()`. This is the missing hop. No shared option abstraction exists or is needed.

**Alternatives considered**: Environment/config forwarding violates the startup argv contract. Always passing a false-valued token would add an unsupported negative/config representation and is unnecessary because both downstream parsers default false.

## Decision 3: Keep disabled mode power-free and authorize serving at the owner

**Decision**: Keep server parsing/forwarding and native argument parsing unchanged. At `runtime/main.mm::runNative()`, preserve enabled mode's real initial power observation. When disabled, start the ordinary full bootstrap without constructing, starting, or sampling a `PowerSource`; after successful bootstrap, apply one synthetic AC-equivalent serving authorization through the existing Bootstrap lifecycle API.

**Evidence**: The coordinator source audit found that disabled mode creates/publishes full residency through `RuntimeBootstrap::start(...)`, but its initial snapshot remains `power=Unknown`, `state=RecoveryFailed`, `modelResident=true`, `inferenceReady=false`, and NativeAdmissionGate remains closed. `validLifecycleStatus()` permits inference readiness only for Ready + AC + resident model. Enabled mode reaches readiness by applying its sampled initial power to published residency; disabled mode has no sample and currently skips this transition entirely. Thus the defect is closed inference admission, not merely incomplete evidence.

**Owner rule**: Disabled option means policy intent to serve independent of power. Once ordinary full bootstrap succeeds, select the existing API's AC-equivalent initial lifecycle authorization at the owner boundary. This is synthetic configuration intent, not a physical sample. Create no observer, keep no pending observation, and process no later physical Battery/AC changes. Do not propagate the boolean into lifecycle classes, power interfaces, protocol, status, readiness, backend, or frontend; do not weaken Unknown fail-closed behavior for enabled mode.

**Alternatives considered**: Sampling power while disabled would violate the explicit opt-out. Relaxing `validLifecycleStatus()` or adding a lifecycle enum/field would weaken or duplicate feature 001 lifecycle semantics. Propagating the option deeper or creating a second lifecycle implementation exceeds the owner boundary. The existing Bootstrap lifecycle API already supports the required AC-on-published-residency transition.

## Decision 4: Separate public declaration from exact-token recognition

**Decision**: Use two real `./splash` checks. For public help/declaration, run `./splash serve --help` and assert exit 0 plus the flag and required help wording. For exact flag recognition, run `./splash serve --model incoai/Qwen3.8-27B-Splash --pause-on-battery --__splash_cli_acceptance_probe__` and inspect the final `error: unrecognized arguments:` diagnostic: after the fix it must contain the unique probe and not the feature flag. Separately use existing launcher, server, native-main, and lifecycle/recovery tests for downstream propagation and semantics.

**Evidence**: The shell script forwards original arguments to `install/launcher.py` after symlink resolution and Python-version selection. A real invocation of the probe command in the current repository exits 2 with both `--pause-on-battery` and `--__splash_cli_acceptance_probe__` in the final diagnostic, confirming the failure is safely at argparse today. Once fixed, argparse must list only the deliberately unknown probe. It fails before `main()` enters `serve()`, so there is no install, model download/build, server, or native startup. Help is a separate declaration check: argparse can exit successfully on help despite an earlier unknown token, so neither help exit nor help text alone proves that the exact supplied token was recognized.

**Alternatives considered**: Testing only `server.server.parse_args()` bypasses the public boundary. A monolithic test or new production seam is unnecessary; compositional existing test seams keep each downstream hop observable. Starting models, building native runtime, or invoking native serving is unnecessary.

## Resolved Questions

- **Which component owns public help and option acceptance?** `install/launcher.py`, dispatched by the repository's `splash` shell entry point.
- **Where does the launcher forward server options?** `install/launcher.py::serve()`'s command list before `os.execve()` of `server/server.py`.
- **Which downstream option hops already work?** Server parse and `_native_command()`; native `parseNativeOptions()`/`NativeArguments`; startup gate in `runNative()`.
- **Which tests have useful seams?** `dev/tests/install/test_launcher.py` for outer parser plus server argv; `dev/tests/test_server.py` for server parse/native argv; extend existing `dev/tests/engine/native_main_test.mm` for disabled owner/fake-source evidence; reuse `runtime_bootstrap_test.mm::testInitialAcObservationOpensExistingBootstrapResidency` for admission semantics. Add no monolithic process test or duplicate lifecycle matrix.
- **Can the defect be fixed without deeper lifecycle changes?** Yes. Make the startup choice at `runNative()` using the existing Bootstrap API. No production change is expected in RuntimeBootstrap, NativeRuntime, PowerSource, server, protocol/status/readiness, or frontend/backend.
