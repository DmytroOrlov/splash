# Research: Explicit Battery Suspension Opt-In

## Decision 1: Keep the configuration gate at the native startup owner

**Decision**: Carry one boolean from the public Python CLI through native argv into `NativeArguments::pauseOnBattery`; let `runNative()` decide whether battery policy is installed.

**Rationale**: `server/server.py` owns public parsing and child command construction. `runtime/main.mm` owns native parsing, power-source lifetime, startup selection, and the `FdTransport` control handler. The battery lifecycle already has one owner in the current native bootstrap. Passing the option deeper would widen the architecture without benefit.

**Alternatives considered**: Inferring the choice from status, environment, or the host's power state was rejected because the child must receive the operator's explicit startup intent. Propagating it through RuntimeBootstrap, NativeRuntime, PowerSource, or a protocol was rejected because it would duplicate policy beyond `runNative()`.

## Decision 2: Disabled means no battery-policy setup

**Decision**: With `pauseOnBattery == false`, do not create/start PowerSource, create PendingPowerObservation, register a callback, sample initial power, observe power, or run battery suspend/recovery methods. Select ordinary `RuntimeBootstrap::start()` unconditionally.

**Rationale**: Current `runNative()` installs battery handling unconditionally. A true bypass requires gating observer construction at its ownership point, before any sampling or callback registration. This preserves pre-feature serving on Battery and Unknown.

**Alternatives considered**: Starting the observer and ignoring its values was rejected because it leaves power machinery active and can accidentally invoke lifecycle transitions. A separate disabled lifecycle mode was rejected as a second implementation path.

## Decision 3: Keep the shared control handler and resource work

**Decision**: Keep one FdTransport control handler. Make its battery-specific prefix conditional on a non-null pending observer, then continue through the existing shared memory-pressure and reclaim work.

**Rationale**: The handler currently owns both battery lifecycle safe-point work and unrelated pressure/reclaim work. Removing it when disabled would regress reclaim. Its enabled lifecycle early returns remain in the enabled branch; false mode must not reach these battery-only returns.

**Alternatives considered**: Disabling the complete FdTransport handler was rejected because it also owns memory-pressure/reclaim progression. Starting a second control handler per mode was rejected because it would split unrelated responsibilities.

## Decision 4: Use true-only native argv and a false native default

**Decision**: Python appends `--pause-on-battery` only when true. Native parsing treats presence as true and omission as false. The native flag is a standalone option among the existing optional arguments.

**Rationale**: Both process boundaries are explicit, deterministic, and backward compatible. Existing native options use argv; a presence flag avoids inventing a negative form or encoding a false value.

**Alternatives considered**: A `--no-pause-on-battery` form, environment alias, config setting, and protocol field were rejected as outside the requested startup-only contract.

## Decision 5: Keep the native-main seam limited to battery-policy setup

**Decision**: Add a private battery-policy setup helper/state in `runtime/main.mm` that accepts a private PowerSource factory and returns the optional source, pending observation, and initial power only when enabled. Keep all `RuntimeBootstrap::start()` and `startModelLess()` construction directly in `runNative()` with explicit branches. If needed for deterministic selection tests, use only a pure private `shouldStartModelLess(pauseOnBattery, std::optional<LifecyclePower> initialPower)`-equivalent decision function with no startup callbacks.

**Rationale**: The existing runtime-bootstrap tests use `FakePowerSource`, but they assemble the observer and handler in their own fixture and never call `runNative()`. The production owner hard-codes `makeSystemPowerSource()`. Hardware-only observation cannot prove deterministic zero calls/samples when disabled. The setup seam isolates only the configuration-policy boundary and avoids wrapping or abstracting RuntimeBootstrap construction.

**Alternatives considered**: Relying on existing feature 001 tests alone would not prove the new configuration gate. Real hardware power transitions are nondeterministic and not appropriate for tests. A callback-driven full/model-less startup abstraction is unnecessary and rejected; the seam stays private to battery-policy setup, with startup construction remaining explicit in `runNative()`.

## Decision 6: Preserve existing native duplicate-option conventions

**Decision**: Parse `--pause-on-battery` as one standalone argv token without consuming the following option/value. Omission means false and presence means true. Preserve the parser's existing behavior for repeated options and malformed argv; `_native_command()` emits the token no more than once.

**Rationale**: The feature requires a true-only flag and safe coexistence with existing `--name value` pairs, but defines no new duplicate-option policy.

**Alternatives considered**: Adding a special duplicate rejection rule for this flag was rejected unless a general existing parser rule already requires it.

## Resolved Unknowns

- **Does a native parser test seam already exist?** No. `NativeArguments` and `parseArguments()` are private in `runtime/main.mm`, and inspected native test targets do not include that file.
- **Can current tests prove no observer starts through the owner?** No. Existing fakes are instantiated by lifecycle-level tests; `runNative()` calls `makeSystemPowerSource()` directly.
- **Must the FdTransport handler remain in disabled mode?** Yes. It also handles independent memory-pressure and reclaim work.
- **Does implementation require a lifecycle redesign?** No. The gate can be contained in `runNative()` while preserving the enabled code sequence.

No unresolved research questions remain.
