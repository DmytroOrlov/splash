# Feature Specification: Battery-Aware Suspension and Recovery

**Feature Branch**: `001-battery-aware-suspension`

**Created**: 2026-10-01

**Status**: Draft

**Input**: User description: Battery-aware suspension and recovery of local Splash inference on macOS

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Safely suspend inference on battery (Priority: P1)

As a user running Splash on a MacBook, when the machine switches from AC power to battery, I want inference to stop using the expensive model/runtime residency as soon as this can happen safely, while the server remains available.

**Why this priority**: This is the primary battery-saving outcome, and its safety boundary protects in-flight inference correctness.

**Independent Test**: Observe a powered, ready server transition to battery under idle and active request load; verify admission closes, admitted work completes according to normal semantics, expensive inference residency is released only after the safe drain boundary, and the control plane remains available.

**Acceptance Scenarios**:

1. **Given** Splash is ready on AC with no active inference, **When** battery power is observed, **Then** new inference is no longer admitted, the server remains available, and Splash reaches a truthful suspended/model-less state after the safe boundary and release outcome are established.
2. **Given** one inference request was admitted before the battery transition, **When** battery is observed, **Then** that request retains required resources and reaches its normal completion or cancellation boundary before expensive residency is released.
3. **Given** multiple inference requests were admitted before the battery transition, **When** battery is observed, **Then** each admitted request retains its required resources through its normal completion or cancellation boundary and release waits until all required work is safe.
4. **Given** a new inference request races the moment admission closes, **When** the transition is processed, **Then** the request is either legitimately admitted with its required resources protected through its safe boundary or promptly rejected as unavailable; it is never admitted based on a stale open decision.
5. **Given** the server has already observed battery power, **When** it observes the same power state again, **Then** the duplicate observation does not disrupt work, repeat a harmful lifecycle transition, or produce a false state.
6. **Given** suspension is draining or releasing residency, **When** server shutdown begins, **Then** shutdown follows its normal shutdown outcome, no new work is admitted, and suspension does not report a completed suspended state unless its success conditions were actually reached.
7. **Given** suspension fails while entering the suspended state or releasing residency, **When** the failure becomes known, **Then** the control plane stays available where the server itself remains operational, state reports the failure/not-ready condition truthfully, and inference is not exposed as ready if safety or release is unproven.
8. **Given** recovery has already begun on AC, **When** the same AC state is observed repeatedly, **Then** duplicate observations do not disrupt recovery or produce false readiness.

### User Story 2 - Keep the model-less server useful and truthful (Priority: P1)

As a user while Splash is suspended on battery, I want the server and diagnostics to remain available and accurately describe what is unavailable.

**Why this priority**: The server must remain useful without suggesting that inference is ready or requiring a process restart to learn its state.

**Independent Test**: While suspended, inspect health, status, diagnostics, and relevant existing metrics; submit an inference request; verify inspection does not restore model residency and the request promptly receives an explicit unavailable/not-ready result.

**Acceptance Scenarios**:

1. **Given** Splash is suspended/model-less, **When** a user reads health, status, diagnostics, or relevant existing metrics, **Then** the long-lived server responds and reports meaningful current lifecycle information.
2. **Given** Splash is suspended/model-less, **When** a user submits an inference request, **Then** it receives a prompt explicit unavailable/not-ready outcome, does not wait indefinitely for AC, and does not trigger implicit model restoration.
3. **Given** model-derived information cannot safely be read in the model-less state, **When** diagnostics or status are requested, **Then** that information is reported as unavailable rather than fabricated or represented as stale live state.
4. **Given** Splash is suspended/model-less, **When** control-plane inspection occurs, **Then** inspection alone does not restore expensive inference residency.
5. **Given** shutdown begins while Splash is suspended, **When** shutdown completes, **Then** the server stops according to its normal shutdown behavior without claiming inference readiness or recovery.

### User Story 3 - Automatically recover on AC power (Priority: P1)

As a user, when AC power returns, I want Splash to restore inference automatically and serve normally once recovery is actually successful.

**Why this priority**: Automatic recovery completes the power transition without requiring users to manually restart the server.

**Independent Test**: Transition a suspended server to AC and observe that it remains unavailable until usable inference is ready, then resumes normal serving; induce one recovery failure and verify a later valid attempt can succeed.

**Acceptance Scenarios**:

1. **Given** Splash is suspended on battery, **When** AC power is validly observed, **Then** recovery begins automatically and inference remains unavailable until a usable runtime is ready.
2. **Given** recovery has made inference usable, **When** recovery succeeds, **Then** admission reopens and normal serving behavior resumes without silently changing ordinary inference behavior.
3. **Given** recovery fails, **When** the failure is known, **Then** the control plane remains available, state is truthfully not-ready/recovery-failed, and inference admission remains closed.
4. **Given** one recovery attempt failed, **When** a later valid recovery attempt occurs, **Then** Splash can recover to a usable inference state; the earlier failure does not permanently prevent recovery.
5. **Given** recovery is in progress, **When** the server is shut down, **Then** shutdown follows its normal outcome and incomplete recovery is not reported as ready.
6. **Given** recovery is in progress, **When** battery power returns, **Then** stale recovery completion cannot reopen inference against the newer battery intent; Splash converges to the current safe suspended outcome.
7. **Given** recovery fails while reusable state is unavailable, invalid, incompatible, or unverifiable, **When** a later valid recovery is attempted, **Then** Splash recovers cold and failure to reuse warm state does not prevent recovery of a usable model.

### User Story 4 - Start safely when already on battery (Priority: P1)

As a user starting Splash while the Mac is already on battery, I want the server to become available in the appropriate model-less state without first establishing unnecessary expensive inference residency.

**Why this priority**: Starting in the correct state avoids immediately taking on the workload the feature is intended to suspend.

**Independent Test**: Start Splash with battery-aware suspension enabled while the Mac is on battery; verify control-plane availability and truthful suspended diagnostics without a transient ready inference service or unnecessary expensive residency, then return to AC and verify automatic recovery.

**Acceptance Scenarios**:

1. **Given** battery-aware suspension is enabled and the Mac is on battery, **When** Splash starts, **Then** the server becomes available in a user-visible state equivalent to suspended/model-less without first establishing unnecessary expensive inference residency.
2. **Given** Splash started model-less on battery, **When** AC power returns, **Then** normal automatic recovery occurs and inference is admitted only after recovery succeeds.

### User Story 5 - Resolve racing lifecycle intent correctly (Priority: P1)

As a user, I want rapid power changes and overlapping lifecycle work to resolve to the latest valid state, so older asynchronous work cannot leave Splash in the wrong serving mode.

**Why this priority**: Incorrect outcomes under rapid changes can either resume expensive inference on battery or leave service unavailable after AC recovery.

**Independent Test**: Exercise rapid AC/battery sequences while draining and while recovering, and verify final admission and state match the newest authoritative power intent.

**Acceptance Scenarios**:

1. **Given** Splash is ready on AC, **When** power changes AC → battery → AC while suspension work is still draining, **Then** Splash converges to the latest valid AC intent and does not let stale suspension work leave it incorrectly suspended once safe recovery succeeds.
2. **Given** Splash is recovering on AC, **When** power changes battery → AC → battery before recovery finishes, **Then** Splash converges to the latest battery intent and stale recovery cannot reopen admission.
3. **Given** repeated observations report the same power state, **When** those observations are processed, **Then** they are harmless and do not produce contradictory state or unnecessary repeated transitions.
4. **Given** the effective current state requires suspension, **When** asynchronous work completes out of order, **Then** inference admission is not left open.
5. **Given** the effective current state requires ready service and recovery succeeds, **When** older lifecycle work completes later, **Then** inference admission is not left permanently closed.
6. **Given** Splash provides an explicit administrative lifecycle action that conflicts with automatic power behavior, **When** newer explicit authoritative intent is issued, **Then** stale automatic work does not undo that intent. If no such action exists, this feature does not add a new public lifecycle API.

### User Story 6 - Actually release the intended expensive residency (Priority: P1)

As a user enabling battery suspension, I expect a successful suspended state to correspond to a real reduction in expensive inference residency.

**Why this priority**: A state label alone does not achieve the battery/resource outcome.

**Independent Test**: After suspension reaches its terminal success state, verify through an objective resource/lifecycle observation that the expensive inference residency targeted by the feature is no longer retained merely by long-lived server state.

**Acceptance Scenarios**:

1. **Given** all admitted work has reached the safe drain boundary, **When** suspension reports success, **Then** expensive inference residency targeted for release is no longer retained merely by stale long-lived references.
2. **Given** the control plane remains available while model-less, **When** suspension completes, **Then** only resources needed for safe model-less operation and independently safe reusable state may remain.
3. **Given** release of targeted residency fails or cannot be established, **When** the transition settles, **Then** Splash does not claim successful suspension while that expensive residency remains effectively retained.

### User Story 7 - Preserve reusable warm state and resume from it when safe (Priority: P2)

As a user, I want Splash to preserve reusable inference state across suspension and to resume from that state when it can be proven safe, while retaining correct cold recovery as the reliable fallback.

**Why this priority**: Warm-resume capability is required for completion of the full feature, but it remains subordinate to P1 basic safe suspend/resume and to inference correctness; reuse for any particular recovery attempt stays conditional on proven safety and compatibility.

**Independent Test**: Recover once in a controlled proven-compatible case where compatible reusable state survived suspension, and once with missing, invalid, incompatible, or unverifiable state; verify warm resume occurs in the proven-compatible case, warm reuse never occurs for unsafe or unproven state, and successful cold recovery remains possible in both.

**Acceptance Scenarios**:

1. **Given** a controlled suspension in which compatible reusable state survived the suspension boundary and its compatibility with the recovered runtime is proven, **When** recovery occurs, **Then** Splash resumes from that preserved state without changing inference correctness.
2. **Given** reusable state is missing, invalid, incompatible, unverifiable, or unsafe across the suspension boundary, **When** recovery occurs, **Then** Splash recovers cold rather than reusing it; this correct cold recovery satisfies that individual recovery attempt.
3. **Given** warm state cannot be preserved or reused for any reason, **When** recovery is attempted, **Then** a usable model can still be restored through cold recovery; preservation or reuse failure never makes recovery of a usable model impossible.
4. **Given** a recovery attempt fails, **When** reusable state remains intended to be retryable, **Then** that failed attempt does not silently corrupt it.
5. **Given** an explicit destructive lifecycle operation already exists, **When** it is performed, **Then** it may intentionally discard resumable state.
6. **Given** Splash suspends while reusable inference state exists that can safely survive the suspension boundary, **When** suspension completes, **Then** that state is preserved rather than unconditionally discarded, so a later proven-compatible recovery can resume from it; an implementation that always discards reusable state and always recovers cold does not satisfy this feature.

### User Story 8 - Make lifecycle state observable (Priority: P2)

As a user or developer operating Splash, I want existing observability surfaces to distinguish meaningful lifecycle states so power-related behavior can be diagnosed.

**Why this priority**: Accurate state reporting is necessary to diagnose automatic transitions and distinguish unavailable inference from a ready server.

**Independent Test**: Observe existing relevant status and diagnostic surfaces across ready, draining, suspended, recovering, and failed recovery conditions; verify each state is distinguishable without triggering recovery.

**Acceptance Scenarios**:

1. **Given** Splash is in any lifecycle state required by this feature, **When** a user inspects relevant existing observability, **Then** normal/ready, draining for suspension, suspended/model-less, recovering/resuming, and recovery-failed/not-ready states are distinguishable by semantic meaning.
2. **Given** observability is queried in any state, **When** the query completes, **Then** it does not change inference behavior or restore expensive residency.

### Edge Cases

- Power changes while admitted work has not reached its safe drain boundary: admitted work keeps required resources through its normal completion or cancellation boundary, and the newest valid power intent determines what follows.
- Power changes while recovery is incomplete: admission remains closed until the newest current intent has successfully reached a usable state.
- Duplicate observations of either power state: no false transitions or harmful duplicate lifecycle effects.
- Shutdown while draining, suspended, or recovering: normal shutdown takes precedence; incomplete transitions are not represented as successful ready or suspended states.
- Inference arriving after suspension: prompt explicit unavailable/not-ready outcome; no indefinite wait and no implicit reload.
- Inference racing admission closure: either safely admitted before closure or rejected after closure, with no stale-decision admission.
- Failure entering suspension or releasing residency: state remains truthful and cannot claim successful resource reduction when that outcome was not achieved.
- Failed restoration: server/control plane stays alive where operational, inference remains unavailable, and later valid recovery remains possible.
- Warm reusable state missing or not verifiably compatible: cold recovery is used; correctness does not depend on warm state.
- Reusable state cannot be safely preserved across a particular suspension, or preservation fails: that recovery proceeds cold, the failure does not prevent recovery of a usable model, and state still intended to be retryable is not silently corrupted.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: When battery-aware suspension is enabled and AC-to-battery power change is observed, Splash MUST automatically stop admitting new inference for the suspension transition.
- **FR-002**: Inference legitimately admitted before admission closes MUST retain all resources required to complete or cancel according to normal request semantics.
- **FR-003**: Splash MUST reach the required safe drain boundary for admitted work before releasing the expensive inference residency targeted by this feature.
- **FR-004**: Suspension MUST NOT silently alter ordinary model output semantics, sampling, batching, cancellation, retry behavior, or request attribution.
- **FR-005**: The long-lived server and control plane MUST remain available while inference is suspended, subject to ordinary server shutdown or failure.
- **FR-006**: While suspended, inference requests MUST receive a prompt explicit unavailable/not-ready outcome, MUST NOT wait indefinitely for AC power, and MUST NOT implicitly restore model residency.
- **FR-007**: Health, status, diagnostics, and relevant existing metrics MUST remain meaningful in the model-less state; unsafe or unavailable model-derived information MUST be reported as unavailable rather than fabricated or presented as stale live state.
- **FR-008**: Control-plane inspection MUST NOT itself restore expensive inference residency.
- **FR-009**: Splash MUST report successful suspension only after the targeted expensive inference residency is no longer effectively retained merely by stale long-lived references; if release fails or cannot be established, state MUST NOT claim success.
- **FR-010**: On a valid AC-power observation while suspended, recovery MUST begin automatically; inference admission MUST remain closed until a usable inference runtime is ready.
- **FR-011**: Successful recovery MUST reopen inference admission and restore normal serving behavior without silently changing ordinary inference behavior.
- **FR-012**: Failed recovery MUST leave the server/control plane available where operational, report a truthful not-ready/recovery-failed state, and keep inference unavailable.
- **FR-013**: Failure of one recovery attempt MUST NOT permanently prevent a later valid recovery attempt.
- **FR-014**: When battery-aware suspension is enabled and Splash starts while already on battery, the server MUST become available in a user-visible model-less state without first establishing unnecessary expensive inference residency.
- **FR-015**: Lifecycle outcomes MUST converge to the newest valid authoritative power intent when power changes during drain or recovery; older asynchronous work MUST NOT override newer intent by completing later.
- **FR-016**: Duplicate observations of the same power state MUST be harmless and MUST NOT create contradictory lifecycle state.
- **FR-017**: Inference MUST NOT remain admitted while the effective current state requires suspension, and MUST NOT remain permanently unavailable after successful recovery to the effective current state.
- **FR-018**: Where an existing explicit administrative lifecycle action can conflict with automatic power behavior, newer explicit authoritative intent MUST NOT be undone by stale automatic work. This feature MUST NOT introduce such an API when none currently exists.
- **FR-019**: Splash MUST support warm resume: it MUST be capable of preserving reusable inference state across the suspension boundary and of resuming recovery from that state when safety and compatibility are proven, and it MUST exercise that capability in such proven-compatible cases. An implementation that always discards reusable state and always recovers cold MUST NOT satisfy this feature.
- **FR-020**: Warm reuse for any particular suspension/recovery attempt is conditional: Splash MUST reuse retained state only when its safety and compatibility with the recovered runtime are proven. When retained state is missing, invalid, incompatible, unverifiable, corrupted, or cannot safely survive the suspension boundary, Splash MUST recover cold, and that correct cold recovery satisfies the individual attempt; warm reuse is never required in such cases.
- **FR-021**: Missing, invalid, incompatible, unverifiable, or unsafe reusable state MUST NOT prevent cold recovery of a usable model, and failure of warm-state preservation or reuse MUST NOT make recovery of a usable model impossible.
- **FR-022**: A failed recovery attempt MUST NOT silently corrupt reusable state that remains intended to be retryable.
- **FR-023**: Existing relevant observability MUST make semantic equivalents of normal/ready, draining, suspended/model-less, recovering/resuming, and recovery-failed/not-ready distinguishable without requiring a new dashboard, provider-specific UI, or metric family.
- **FR-024**: Shutdown while draining, suspended, or recovering MUST follow ordinary shutdown semantics and MUST NOT report an incomplete lifecycle transition as successfully ready or suspended.
- **FR-025**: If entering suspension or releasing targeted residency fails, Splash MUST keep state truthful, MUST NOT claim suspension success, and MUST NOT admit inference while its safety or readiness is unproven; a later valid power intent MUST remain able to resolve the lifecycle state.
- **FR-026**: An existing explicit destructive lifecycle operation, if Splash has one, MAY intentionally discard resumable state; this feature MUST NOT require introducing a new such operation.

### Key Entities *(include if feature involves data)*

- **Power observation**: The observed current power source relevant to whether inference should be suspended or restored.
- **Lifecycle state**: The user-visible serving condition, including readiness, suspension progress, suspended/model-less operation, recovery progress, and recovery failure.
- **Inference request**: A unit of work with an admission outcome and normal completion or cancellation semantics.
- **Reusable inference state**: State that can be preserved across suspension to enable warm resume; it may be reused only for an individual recovery attempt whose safety and compatibility are established, and its preservation capability is required while its reuse remains conditional.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of controlled AC-to-battery scenarios, no request is newly admitted based on a stale open-admission decision after suspension admission closure takes effect.
- **SC-002**: In 100% of controlled scenarios with admitted active requests, each request reaches its normal completion or cancellation boundary with required resources intact before targeted expensive residency is released.
- **SC-003**: In 100% of successful terminal suspended outcomes, objective resource/lifecycle observation confirms the targeted expensive inference residency is no longer retained merely by long-lived stale references.
- **SC-004**: In 100% of suspended-state inference attempts, the outcome is an explicit unavailable/not-ready response without indefinite waiting or implicit restoration of expensive residency.
- **SC-005**: In 100% of successful recovery scenarios, inference remains unavailable until a usable runtime is ready, then returns to normal serving behavior.
- **SC-006**: In 100% of failed recovery scenarios, status is not-ready/recovery-failed and a later valid recovery attempt can reach ready state when restoration succeeds.
- **SC-007**: In 100% of controlled rapid power-change sequences, the final lifecycle/admission outcome matches the newest valid authoritative intent, regardless of the completion order of older asynchronous work.
- **SC-008**: In 100% of startups performed with the feature enabled while already on battery, the control plane becomes available without first establishing unnecessary expensive inference residency.
- **SC-009**: Users can distinguish all five required semantic lifecycle states through existing relevant observability, and inspection does not change lifecycle state or restore inference residency.
- **SC-010**: In 100% of recovery cases with unusable or unproven reusable state, cold recovery remains available and warm reuse does not occur.
- **SC-011**: In 100% of controlled recovery scenarios in which compatible reusable state survived the suspension boundary and its compatibility with the recovered runtime is proven, objective lifecycle/diagnostic observation shows recovery resumed from that preserved state rather than re-establishing it cold; an implementation that never provides warm resume and always recovers cold fails this criterion.
- **SC-012**: In 100% of recovery attempts where warm-state preservation or reuse fails, recovery of a usable model remains possible through cold recovery, and reusable state still intended to be retryable is not silently corrupted.

## Assumptions

- The feature applies to local inference on macOS and is active when battery-aware suspension is enabled.
- “Prompt” unavailable response means the request resolves as unavailable without waiting for a future power change; this specification sets no numeric latency threshold.
- Existing relevant health, status, diagnostics, and metrics are the observability surfaces in scope; the feature does not require a new UI or metric family.
- Normal request completion, cancellation, shutdown, and inference semantics remain the product contract during power transitions.
- AC/battery observations represent the current authoritative power intent for automatic lifecycle behavior.
- “Proven” compatibility and safety for warm reuse means objectively established for the recovery at hand; this specification does not dictate how that proof is obtained, only that reuse is forbidden without it.
- Warm-resume capability and proven-case warm reuse are required for completion of this feature, while correctness and cold recovery always take precedence for any individual recovery attempt.
