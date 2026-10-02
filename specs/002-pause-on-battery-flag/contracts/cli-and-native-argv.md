# Public CLI and Native Argument Contract

## Public command and help

The public executable is `./splash`. It resolves its launcher path and execs `install/launcher.py`, whose `serve` subparser owns public option acceptance and user-facing help.

```text
./splash serve --model <owner/repo> --pause-on-battery
./splash serve --help
./splash serve --model <owner/repo> --pause-on-battery --__splash_cli_acceptance_probe__
```

The `serve` parser accepts `--pause-on-battery` as a true-only option, default false. The first command proves the public help surface and option declaration: assert exit 0 and that help displays the flag with concise semantics equivalent to releasing model residency on battery and recovering on AC power, without claiming all memory is freed. It does not prove exact-token recognition.

The second command proves exact outer-token recognition. Inspect the final `error: unrecognized arguments:` diagnostic: after implementation it must list `--__splash_cli_acceptance_probe__` and must not list `--pause-on-battery`; before implementation both are expected. This uses the real shell dispatch/Python selection and public parser, and fails before serving setup. Do not use global stderr absence because usage text may legitimately contain the registered flag. Neither help exit status nor help text alone proves that an exact supplied token was recognized. No install, download, build, server, or native process starts in either check. Internal server/native usage are separate surfaces.

## Launcher to server

`install/launcher.py::serve()` includes `--pause-on-battery` in its `server/server.py` exec argv exactly once when true and omits it when false. It must not use an environment/config alias.

## Server to native

`server/server.py::parse_args()` accepts the flag and defaults false. `_native_command(args)` emits the standalone native token exactly once when true and omits it when false.

## Native parse and startup

`serve-native` accepts the standalone token among its existing optional arguments. Presence sets `NativeArguments::pauseOnBattery = true`; omission leaves its default false. `runNative()` is the terminal owner of this startup configuration.

When enabled, `runNative()` uses the real initial Battery, Unknown, or AC observation exactly as today. When disabled, it creates, starts, and samples no `PowerSource`, selects ordinary `RuntimeBootstrap::start(...)`, and after successful full bootstrap applies one synthetic AC-equivalent serving authorization through the existing Bootstrap lifecycle API. That value is configuration-policy intent selected solely because the option is false, not a physical power sample. Disabled mode retains no pending observation and processes no later physical Battery/AC changes. The boolean is not propagated into lifecycle classes, status/readiness, or protocol, and is not inferred from environment or power state. Enabled Unknown remains fail-closed.

## Evidence boundary

Keep evidence compositional and name the boundary each test proves:

1. **Public help/option declaration**: real `./splash serve --help`; assert successful exit and required flag/help wording.
2. **Exact outer executable recognition**: real flag-plus-unique-probe command above; inspect the unrecognized-arguments diagnostic for probe present and feature flag absent.
3. **Launcher→server propagation**: existing `launcher.main()` plus mocked `os.execve` proves exactly one token for true and none for omission. This direct call is not outer executable evidence.
4. **Server parse→native argv**: existing server tests prove server acceptance/default and exactly-one native token.
5. **Native parse/owner choice**: native-main tests prove native default/presence parsing, enabled startup selection, and disabled fake-source bypass/full-start/AC-equivalent authorization choice.
6. **Bootstrap admission**: `runtime_bootstrap_test.mm::testInitialAcObservationOpensExistingBootstrapResidency` proves AC authorization applied to existing residency opens Ready/inference admission while retaining model/runtime resources and avoiding a new generation or ReadyEvent.
7. **Actual `runNative()` wiring**: a focused source audit proves successful ordinary full bootstrap precedes disabled authorization, no observer or pending observation exists, later physical changes cannot be processed, and shared non-battery control/reclaim remains reachable.
8. **Lifecycle semantics**: existing lifecycle/recovery tests remain regression evidence for unchanged enabled behavior.

A server parser-only test cannot prove public CLI acceptance. Do not add a production seam to make one monolithic test; isolate model downloads/builds and native execution at the existing test boundaries.
