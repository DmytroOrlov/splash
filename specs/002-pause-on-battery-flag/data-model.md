# Data Model: Explicit Battery Suspension Opt-In

This feature adds no persisted data, protocol fields, status values, or lifecycle entities. It adds one process-start configuration value across the CLI/native process boundary.

## Process-Start Option

| Field | Type / representation | Default | Validation and behavior |
|---|---|---|---|
| Public `pause_on_battery` | Boolean parsed from `--pause-on-battery` | `false` | Presence sets true; absence leaves false. It cannot change after startup. |
| Native `pauseOnBattery` | Boolean in native startup arguments | `false` | Presence of native `--pause-on-battery` sets true; omission leaves false. |

## Relationship

The public boolean is propagated as a true-only argv token to the native boolean. The native startup owner uses that value to either install the existing battery policy or bypass it. The option does not become part of RuntimeBootstrap, NativeRuntime, PowerSource, status, readiness, or inference protocol state.
