# Data Model: Explicit Battery Suspension Opt-In

This feature adds no persisted data, protocol fields, status values, or lifecycle entities. It adds one process-start boolean whose public representation and propagation hops are:

| Hop | Owner and representation | Default / behavior |
|---|---|---|
| Public input | `./splash` dispatches to `install/launcher.py::parse_args()`; `args.pause_on_battery` is set by `--pause-on-battery` | False when absent |
| Launcher child argv | `install/launcher.py::serve()` forwards the standalone token to `server/server.py` | Token present exactly once when true; omitted when false |
| Server parse | `server/server.py::parse_args()` boolean `pause_on_battery` | False when absent |
| Native child argv | `server/server.py::_native_command(args)` | Token present exactly once when true; omitted when false |
| Native parse | `runtime/main.mm::NativeArguments::pauseOnBattery` | False when absent |
| Policy owner | `runtime/main.mm::runNative()` | Enabled installs existing battery policy and applies its real initial observation; disabled creates/samples no power source and, after successful ordinary full bootstrap, applies one synthetic AC-equivalent serving authorization through the existing Bootstrap lifecycle API |

The option is process-start configuration. Its boolean terminates at `runNative()` and is not propagated into RuntimeBootstrap, NativeRuntime, PowerSource, status, readiness, or inference protocol state. In disabled mode, the AC-equivalent value represents configuration-policy intent selected solely by the false option; it is not a physical power sample and no later physical power changes are observed. No false-valued argv token is required because each downstream representation defaults false.
