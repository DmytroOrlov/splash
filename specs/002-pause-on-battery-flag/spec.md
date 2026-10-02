# Feature Specification: Explicit Battery Suspension Opt-In

**Feature Branch**: `002-pause-on-battery-flag`

**Created**: 2026-10-03

**Status**: Draft

**Input**: User description: Add `--pause-on-battery` as an explicit opt-in gate for the already completed battery-aware suspension behavior.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Keep ordinary serving independent of power (Priority: P1)

As a Splash operator who does not request battery suspension, I want Splash to start and serve normally regardless of whether the Mac is on AC, battery, or has an unknown power state.

**Why this priority**: This preserves historical behavior on upgrade. Battery suspension must not unexpectedly remove model residency or make inference unavailable for users who did not opt in.

**Independent Test**: Start the public serving command with no battery flag under a deterministic fake initial Battery observation, verify ordinary full startup and admitted inference, then change the fake observation through Battery and AC and verify no battery lifecycle transition occurs.

**Acceptance Scenarios**:

1. **Given** the public `serve` command is invoked without `--pause-on-battery`, **When** arguments are parsed, **Then** `pause_on_battery` is false.
2. **Given** battery suspension is disabled and the initial power source would report Battery or Unknown, **When** native serving starts, **Then** it performs normal full startup and makes inference available with ordinary model and Engine residency.
3. **Given** battery suspension is disabled and serving is active, **When** later observations would report Battery and AC, **Then** they do not close inference admission, suspend or recover model/runtime resources, or produce a battery-specific status transition.
4. **Given** battery suspension is disabled, **When** native control handles unrelated memory pressure or reclaim work, **Then** that work continues normally.

### User Story 2 - Explicitly enable battery suspension (Priority: P1)

As a Splash operator who wants to reduce model residency on battery, I want to enable the existing battery-aware behavior with `splash serve --model <model> --pause-on-battery` and have the choice reach the native serving process.

**Why this priority**: The opt-in must be usable through the public command and must control the native process that owns power observation and lifecycle decisions.

**Independent Test**: Verify the public CLI accepts the flag, the native child receives an explicit enabled value, and a direct `serve-native` invocation can explicitly select both default-disabled and enabled modes.

**Acceptance Scenarios**:

1. **Given** the public `serve` command includes `--pause-on-battery`, **When** it launches native serving, **Then** the native child receives the enabled option explicitly.
2. **Given** native serving receives the enabled option and initial power is Battery or Unknown, **When** it starts, **Then** it follows the existing model-less cold-start behavior from feature 001.
3. **Given** native serving receives the enabled option and initial power is AC, **When** it starts, **Then** it performs ordinary full startup.
4. **Given** enabled serving transitions from Battery to AC, **When** recovery completes, **Then** it follows feature 001's same-process-generation suspension and recovery behavior and emits no additional ReadyEvent for that generation.

### User Story 3 - Understand the opt-in from CLI help (Priority: P2)

As an operator choosing whether to enable battery suspension, I want the serving help text to describe the flag clearly without overstating memory release.

**Why this priority**: Clear help prevents accidental assumptions that the flag is on by default or that suspension frees every cache and state resource.

**Independent Test**: Inspect public serving help and verify it includes the flag and concise semantics explaining model residency release on battery and recovery on AC, without promising that all memory is freed.

**Acceptance Scenarios**:

1. **Given** an operator requests public serving help, **When** the options are displayed, **Then** `--pause-on-battery` is shown with semantics equivalent to “Release model residency while on battery and recover on AC power.”
2. **Given** the help describes the suspension behavior, **When** the wording is read, **Then** it does not imply that retained warm Cache/KV/state is necessarily freed.

### Edge Cases

- Power is Battery or Unknown when the flag is absent: power is irrelevant to the battery policy; ordinary full startup and serving proceed.
- Power observation is unavailable or cannot be determined when the flag is absent: startup and serving do not fail closed for battery reasons.
- The flag is absent while a later Battery event occurs: the observer and battery lifecycle machinery are not started merely to ignore the event.
- The native control handler owns both battery lifecycle handling and unrelated memory-pressure/reclaim work: disabling battery policy leaves the unrelated control work operational.
- The public CLI has enabled the option but the child argument is missing or malformed: argument handling fails deterministically instead of guessing from status, environment, platform power, or Python readiness.
- Enabled behavior races, failures, or shutdown occur: all accepted feature 001 guarantees remain in force without being weakened by the configuration gate.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Battery-aware suspension MUST be opt-in through the public `serve` flag `--pause-on-battery`.
- **FR-002**: When the flag is absent, the effective `pause_on_battery` value MUST be false.
- **FR-003**: When the flag is absent, startup MUST preserve the historical normal serving path, including full native runtime startup, regardless of an initial Battery or Unknown power condition.
- **FR-004**: When the flag is absent, later Battery observations MUST NOT close inference admission, suspend Engine/RuntimeModel/ModelPackage residency, initiate battery recovery behavior on AC, or create a battery-specific status transition.
- **FR-005**: When the flag is absent, power observation and battery lifecycle policy setup MUST be bypassed at the highest practical ownership boundary; disabled mode MUST NOT start an observer or sample initial power merely to ignore it.
- **FR-006**: Disabling battery policy MUST NOT disable the native control handler or its independent memory-pressure and reclaim responsibilities.
- **FR-007**: When the flag is present, the public CLI MUST pass the enabled choice explicitly to the native child process. The native `serve-native` command MUST have an explicit boolean representation of the same choice, defaulting to false when omitted.
- **FR-008**: Native behavior MUST be selected from the explicit option value. It MUST NOT be inferred from status, environment variables, platform state when disabled, or Python readiness.
- **FR-009**: With the flag enabled, initial Battery or Unknown MUST retain feature 001's fail-closed model-less startup; initial AC MUST retain feature 001's normal full startup.
- **FR-010**: With the flag enabled, all accepted behavior and invariants of `specs/001-battery-aware-suspension` MUST remain unchanged. This feature MUST add only a configuration gate and MUST NOT introduce a second battery lifecycle implementation.
- **FR-011**: With the flag enabled, observer registration before the initial synchronous sample, same-generation recovery, exactly one ReadyEvent per process generation, revision-fenced asynchronous recovery, passive status/readiness, effective-context publication before admission, warm matching-prefix suffix-only restore, and the accepted race, shutdown, and transactional guarantees MUST remain intact.
- **FR-012**: CLI and startup evidence MUST deterministically cover both modes. Default-mode evidence MUST cover parsing/default value, normal full startup under fake Battery, model and Engine residency, inference admission, absence of battery suspend/recovery on later fake power changes, and continued non-battery control/reclaim operation. It SHOULD prove no observer is created or started when the available seam permits.
- **FR-013**: Enabled-mode evidence MUST cover public CLI acceptance, explicit child propagation, native argument representation, Battery and AC startup selection, Battery-to-AC same-generation recovery, and one ReadyEvent per generation. Existing feature 001 tests MUST serve as regression evidence; this feature MUST add only focused tests for the gate and propagation rather than duplicate the full lifecycle matrix.
- **FR-014**: Public serving help MUST display `--pause-on-battery` with concise semantics that explain model residency release on battery and recovery on AC without promising that all memory is freed.
- **FR-015**: The feature MUST NOT add a negative flag, environment-variable alias, config-file setting, protocol message, lifecycle status command, or runtime mutation of the option.

### Compatibility and Ownership Constraints

- The public CLI and native child argument construction are owned by `server/server.py`; the current child command is built by `_native_command(args)`.
- The native argument representation and parser are in `runtime/main.mm` (`NativeArguments` and `parseArguments()`); native startup selection is in `runNative()`.
- The configuration gate belongs at the native startup owner that chooses whether battery observation and policy are installed. Battery lifecycle internals in RuntimeBootstrap, NativeRuntime, StateCache, QwenState, and PowerSource retain their feature 001 semantics; changes there are limited to test seams if unavoidable.
- Battery policy disabled is distinct from native control handling disabled. The native transport/control path must remain available for unrelated memory-pressure and reclaim work.
- Existing retained RuntimeResources/Cache/KV/StateStorage/SlotFile state across normal enabled suspension is governed by feature 001 and must not be described as all memory being freed.

### Key Entities *(include if feature involves data)*

- **Battery suspension option**: A process-start choice with a default of disabled that determines whether the existing battery lifecycle policy participates in native serving.
- **Native serving process**: The child process that owns power observation and battery lifecycle policy when the option is enabled.
- **Power observation**: The current power source input used only by enabled battery policy; it is irrelevant to serving policy when disabled.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In all deterministic default-mode startup cases, including fake initial Battery and Unknown, Splash reaches ordinary full model serving readiness and admits inference without a battery-specific unavailable state.
- **SC-002**: In all deterministic default-mode power-change cases, fake Battery and AC changes cause zero battery suspension, recovery, admission-closure, or battery-specific status transitions.
- **SC-003**: In default mode, battery observer startup and initial power sampling occur zero times where the deterministic observer seam is available, while non-battery memory-pressure/reclaim control remains functional.
- **SC-004**: In all CLI propagation cases, the public flag's enabled value is represented explicitly in the native child invocation, and native parsing distinguishes enabled from the false default.
- **SC-005**: In all enabled startup cases, Battery/Unknown selects the established model-less path and AC selects the established full startup path.
- **SC-006**: In enabled Battery-to-AC regression cases, process identity and generation are preserved, exactly one ReadyEvent is emitted for the process generation, and recovery follows the feature 001 accepted behavior.
- **SC-007**: Public serving help displays the opt-in flag and accurate concise semantics without claiming that all memory is released.
- **SC-008**: The existing feature 001 acceptance invariants remain passing as regression evidence, with no second battery lifecycle behavior introduced by this feature.

## Assumptions

- Feature 001, `specs/001-battery-aware-suspension`, is complete and is the authoritative behavior baseline; this specification does not reopen or revise it.
- A flag absent from the public command means false for the native child as well as the Python CLI; the native parser's omitted-option default is false.
- The native child argument convention may encode the true-only boolean as a presence flag; no false argument is needed because false is the default.
- “Normal full startup” means the pre-feature serving behavior, including ordinary model and Engine residency and no policy-driven admission closure based on power state.
- Existing deterministic power-source and startup seams should be reused for the focused gate tests; any unavoidable seam work must not change production lifecycle semantics.
- The feature applies to the existing macOS battery policy. It does not broaden supported platforms or power conditions.
