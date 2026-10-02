# Feature Specification: Upstream Battery Suspension Parity Migration

**Feature Branch**: `003-upstream-battery-parity`

**Created**: 2026-11-01

**Status**: Draft

**Input**: User description: "Upstream migration of the existing Splash Battery suspension implementation. This is a compatibility/parity migration, NOT a new Battery suspension feature."

## Clarifications

### Session 2026-11-01

- Q: Does this migration re-land the full public opt-in CLI surface (`002 FR-007`, `FR-013`, `FR-014`), or only the native-side default-off gate? → A: A — the full public opt-in chain: launcher → shared serve options → Python server → native arguments → native Battery policy, with public help and exact forwarding restored by this migration; feature 002 stays Reopened / Not Accepted.
- Q: Is the physical Apple Silicon validation an automated hardware-CI run, or an operator-performed live session with archived objective observations? → A: B — an archived operator-performed live session per a scripted evidence-capture procedure; an automated CI hardware runner is not a prerequisite.

## Scope Statement

This specification does **not** define Battery suspension behavior. The behavioral contract is already
authoritative in `specs/001-battery-aware-suspension/spec.md` (acceptance baseline, `FR-001…FR-026`,
`SC-001…SC-012`) and its default-off opt-in gate in `specs/002-pause-on-battery-flag/spec.md`
(`FR-001…FR-015`, `SC-001…SC-008`, **Status: Reopened / Not Accepted**). Neither specification is
modified, reopened or reinterpreted here.

What this specification defines is the **migration obligation**: that the already-established Battery
suspension and recovery contract must be re-established on top of the current upstream architecture
without regressing any upstream-only capability, and the **evidence** that proves parity. Requirements
below are migration requirements; each one points back to an existing requirement or invariant instead of
restating it.

**Baseline**: the upstream tree at HEAD (`a8a74e6`), which contains no Battery power machinery, no Battery
lifecycle, and no `--pause-on-battery` option.
**Source of the migrated contract**: the interrupted-rebase `REBASE_HEAD` commit (`f9f4eb3a`), whose
commit message is the binding statement of the behavioral and concurrency invariants carried below.

**Repository state (binding, not advisory)**: the repository is in an interrupted rebase with
unresolved conflicts in production files (`runtime/engine/*`, `runtime/main.mm`, `runtime/model/QwenState.*`)
and in the Battery test files. This specification MUST be authored and validated **without** changing
Git state: no branch switch, no staging, no conflict resolution, no rebase continuation, no
production-code or test edits. If a tool step would require a branch switch, it is a blocker and stops
here.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Opted-in operator gets the same warm-suspension outcome after the move (Priority: P1)

As a Splash operator who opts into Battery suspension, after the implementation is re-established on
the current upstream architecture I want exactly the outcome feature 001 already promised: expensive
model residency is released on Battery, the long-lived server keeps serving control traffic, AC restores
inference in the same process generation, and the useful warm state survives so recovery does not replay
preserved work.

**Why this priority**: This is the entire value of the migration. If parity fails, the operator either
loses the resource-saving outcome or loses the warm-resume outcome the feature exists to provide.

**Independent Test**: Exercise the feature-001 acceptance matrix (`001` User Stories 1–6 and
`SC-001…SC-004`) against the migrated baseline through the existing deterministic power and startup seams,
with no new power vocabulary and no new lifecycle commands.

**Acceptance Scenarios**:

1. **Given** the migrated baseline serving on AC with inference ready, **When** Battery is observed,
   **Then** 001's suspension outcome is reached: admission closes at the native boundary, admitted work
   completes or cancels with its resources intact, and residency is released only after the safe boundary
   (`001 FR-001…FR-003`, `SC-001…SC-003`).
2. **Given** the migrated baseline suspended, **When** control-plane surfaces are read, **Then** they stay
   available and truthful without restoring residency (`001 FR-005…FR-008`, `SC-004`, `SC-009`).
3. **Given** the migrated baseline suspended, **When** AC is observed, **Then** recovery is automatic,
   admission reopens only on success, and normal serving resumes (`001 FR-010…FR-013`, `SC-005…SC-006`).
4. **Given** the migrated baseline started while already on Battery or with unknown power, **When** it
   starts, **Then** the model-less control shell is established without unnecessary expensive residency
   (`001 FR-014`, `SC-008`; `002 FR-009`).
5. **Given** the migrated baseline and a compatible request whose warmed prefix had to be built before
   suspension, **When** recovery has completed and the request is served again, **Then** only the uncached
   suffix is reconstructed (`001 FR-019…FR-021`, `SC-011`).

---

### User Story 2 - Operators who did not opt in see an untouched upstream product (Priority: P1)

As a Splash operator who did not enable Battery suspension, the migrated tree must behave exactly like
the upstream baseline: full startup, ordinary serving, ordinary memory-pressure handling, and no Battery
lifecycle of any kind.

**Why this priority**: A parity migration that changes default behavior is a regression, not a migration.
Feature 002's gate is explicitly **not accepted upstream**, so the default path is the primary guard.

**Independent Test**: Run the upstream-only test suites plus the disabled-mode evidence from `002`
(`FR-003…FR-006`, `SC-001…SC-003`) on the migrated tree with the option absent, under fake Battery and
Unknown initial power.

**Acceptance Scenarios**:

1. **Given** the migrated tree with the opt-in absent and a fake initial Battery or Unknown observation,
   **When** serving starts, **Then** ordinary full startup, model residency and inference admission occur
   (`002 FR-003`, `SC-001`).
2. **Given** ordinary serving is active, **When** fake Battery then AC observations arrive, **Then** zero
   admission closure, zero residency release, zero recovery and zero Battery-specific status transition occur
   (`002 FR-004`, `SC-002`).
3. **Given** ordinary serving is active, **When** the native control path handles memory pressure, reclaim,
   idle weight release, thermal state changes or write-through pause, **Then** those upstream behaviors are
   unchanged (`002 FR-006`; upstream preservation requirement below).
4. **Given** the opt-in is absent, **When** Battery machinery startup is observed, **Then** no power observer
   is created or started and no initial power sample is taken merely to ignore it (`002 FR-005`, `SC-003`).

---

### User Story 3 - Control stays responsive and ownership stays exclusive while residency work is in flight (Priority: P1)

As an operator, when residency is being released or rebuilt asynchronously, the server must keep answering
status and control requests, must honor a newer Battery or Shutdown intent immediately, and must never let
two owners act on the residency stratum at once.

**Why this priority**: The `REBASE_HEAD` invariants make exclusive handoff and asynchronous residency work
the correctness core. Overlapping ownership or a blocked control thread is how this feature historically
broke (stale-status regression, premature admission, battery memory leak).

**Independent Test**: Drive the deterministic handoff seams — worker started, control/status traffic issued,
newer Battery and Shutdown intents injected mid-flight — and observe the ownership authority and lifecycle
snapshots at each step.

**Acceptance Scenarios**:

1. **Given** the native owner holds residency-domain authority, **When** recovery work is handed to a single
   serial worker, **Then** exactly one holder owns that stratum at every instant, and the worker never
   publishes lifecycle truth, effective context or admission (`001 FR-010…FR-011`, upstream invariant
   "Recovery construction stays off the native safe-point thread").
2. **Given** residency construction or disposal is in flight, **When** status, health, metrics, model metadata
   or a newer Battery/Shutdown intent arrives, **Then** the control path answers or acts without waiting for
   the worker, and the in-flight worker is never joined from a safe point.
3. **Given** the worker is the current holder, **When** lifecycle state is read, **Then** the answer comes from
   an immutable snapshot that cannot expose partially-owned residency.
4. **Given** ownership returns to the native owner, **When** the safe point re-inspects the current revision,
   **Then** only the owner may decide currency, transfer residency, publish it, expose effective context and
   finally open admission.

---

### User Story 4 - Adoption, failure and shutdown end in a truthful state (Priority: P1)

As an operator, when recovery work is refused, fails, goes stale, or races shutdown, I want the server to
end in a state that matches physical reality — never half-published, never leaked, never claiming success.

**Why this priority**: These are the races the historical implementation had to prove; the upstream
protocol makes several of them fatal (a second readiness announcement per generation is rejected by the
server as a protocol violation), so an incorrect outcome is not merely ugly but fatal.

**Independent Test**: Force each failure seam — refused adoption, adoption failure, completed stale candidate,
Shutdown winning mid-recovery, Battery arriving after a committed release — and observe resource retention,
lifecycle state and admission at the safe point afterwards.

**Acceptance Scenarios**:

1. **Given** a rebuilt residency candidate that the long-lived owner refuses or that fails to publish,
   **When** adoption is aborted, **Then** transferred resources roll back into the private candidate before
   it is destroyed, and no live component borrows from destroyed or half-published state (`001 FR-022`).
2. **Given** a completed candidate is stale because a newer non-AC intent arrived, **When** the safe point
   runs, **Then** the completed work is reaped before eligibility reporting returns, and no private residency
   survives merely because the newer intent is not AC.
3. **Given** Shutdown is requested during draining, suspension or recovery, **When** teardown runs, **Then**
   shutdown is terminal, later power observations cannot reopen it, completed private work does not become
   residency, and observer teardown precedes startup-owner teardown (`001 FR-024`).
4. **Given** destructive release has committed and a newer AC observation arrives before the stale release
   announcement, **When** the safe point reconciles, **Then** the newer AC intent becomes a closed model-less
   suspended state and the ordinary recovery path rebuilds — admission is not reopened directly, destroyed
   objects are not resurrected synchronously, and the stale announcement is not published.

---

### User Story 5 - Retained identity is what makes recovery fast (Priority: P2)

As an operator, after recovery I want the preserved prefix to be *used*, not rebuilt: retained Cache, KV
state, composite state and slot-backed identity must be the same objects across the boundary, and a
compatible request must prefill only what was never cached.

**Why this priority**: Structurally preserving objects while replaying the expensive prefix satisfies the
label and destroys the property. It is subordinate to P1 safe suspend/recover correctness.

**Independent Test**: Deterministic suffix-only prefill proof across two serving instances sharing the
retained Cache — build a warmed prefix in the first instance, release residency, construct a second instance
around the same retained graph, issue the compatible request, and observe that only the uncached suffix is
processed.

**Acceptance Scenarios**:

1. **Given** two Engine-generation instances around one retained Cache graph, **When** a request compatible
   with the retained prefix is served after recovery, **Then** the matching retained KV prefix, its composite
   state boundary and its slot-backed identity are reused and only the uncached suffix is prefilled
   (`001 FR-019`, `SC-011`).
2. **Given** the same case, **When** recovery preparation is observed, **Then** no synthetic recovery prompt,
   no preserved-prefix replay and no full-context warmup occur.
3. **Given** retained state whose compatibility or safety cannot be proven, **When** recovery occurs, **Then**
   cold recovery is used and remains correct (`001 FR-020…FR-021`, `SC-010`).

---

### User Story 6 - Persistence intent survives the boundary (Priority: P2)

As an operator whose conversations keep their durable state, I want a Battery suspension to neither lose
pending durable-state intent nor change when, in which order, or under which disk budget that intent lands,
and I want a clean shutdown still to flush as it always did.

**Why this priority**: The upstream persistent-tier machinery is upstream-only behavior; the migrated
suspension must not silently drop or re-time it, and lost persistence is a data-quality regression even
when serving looks normal.

**Independent Test**: Suspend with due and not-yet-due durable-state points queued, observe execution during
owner authority and deferral during worker ownership, resume, then perform a clean stop and compare counters,
due times, ordering and budget behavior against the upstream baseline.

**Acceptance Scenarios**:

1. **Given** due durable-state work while the native owner holds residency-domain authority, **When** suspension
   is active, **Then** that work may still execute, keeping upstream due times, publication order, disk-write
   budget behavior and counters intact.
2. **Given** due durable-state work while the worker holds authority, **When** the safe point runs, **Then**
   the work is deferred, not dropped, not re-timed, and becomes eligible again when ownership returns.
3. **Given** suspension is active or completed, **When** the process stops cleanly, **Then** the upstream
   clean-shutdown flush semantics still drain every queued point as they do on the upstream baseline.

---

### User Story 7 - Diagnostics distinguish the right things after the move (Priority: P2)

As an operator diagnosing power behavior, I want the existing surfaces to distinguish readiness kinds: the
one-shot generation handshake, current inference readiness, the configured capability ceiling, and the
currently served context limit.

**Why this priority**: Upstream treats a second readiness announcement per generation as fatal, and mixes
"configured" and "effective" numbers in status today; collapsing them during migration breaks either the
protocol or request telemetry.

**Independent Test**: Read the existing status/readiness surfaces across ready, draining, suspended,
recovering and recovery-failed states on the migrated baseline, and compare each value's source against the
published serving instance and the configured startup ceiling.

**Acceptance Scenarios**:

1. **Given** one process generation undergoing AC → Battery → AC, **When** readiness announcements are
   counted, **Then** exactly one is emitted, the child is never replaced, and inference readiness may still
   toggle repeatedly (`001 FR-017`, `SC-009`; `002 SC-006`).
2. **Given** residency is absent, **When** model-derived surfaces are read, **Then** they report absence
   rather than reusing historical startup values (`001 FR-007`, constitution VII).
3. **Given** recovery resolved a smaller serving limit than the startup ceiling, **When** status and per-request
   telemetry are read, **Then** the ceiling and the effective limit remain distinct and telemetry follows only
   the published instance.
4. **Given** inference-ready status with inconsistent or missing effective-context data, **When** it is
   produced, **Then** it fails closed rather than substituting a plausible older value.

### Edge Cases

- Idle weight release, memory-governor growth pause, thermal-state reporting and write-through pause already
  exist upstream for unrelated reasons: a Battery observation MUST NOT be conflated with any of them, in
  either direction.
- A thermal or memory-pressure event during suspension: the Battery lifecycle is unaffected, and the
  unrelated upstream control work continues (`002 FR-006`).
- A genuine child failure during or after suspension: that legitimately creates a new process generation
  with its own single readiness announcement and a restart of lifecycle numbering; it is not a Battery
  transition and MUST NOT be used to implement one.
- Due durable-state work whose write lands after ownership has moved to the worker: the landing must not
  publish, re-open admission, or make a pending item reusable.
- Retained asynchronous offload in flight at suspension: the item stays owned for accounting and completion
  but is not obtainable as reusable state; a failed write discards the failed publication while the matching
  KV boundary survives and reports the loss truthfully.
- A restore failure into one request: that request may go cold; the immutable retained source stays available
  for a later attempt (`001 FR-022`).
- Duplicate observations of the same power state: harmless, no contradictory state (`001 FR-016`).
- Migration with an unresolved rebase: authoring, review and validation of this specification MUST complete
  without touching Git state; any step needing a branch switch is a blocker.

---

## Requirements *(mandatory)*

### Functional Requirements

**Parity obligations**

- **FR-001**: On the upstream baseline, the migrated implementation MUST satisfy the accepted behavior contract
  of `specs/001-battery-aware-suspension` `FR-001…FR-026` end to end. This specification MUST NOT restate,
  relax or extend that contract; parity is measured by 001's scenarios passing on the migrated tree.
- **FR-002**: The migration MUST reuse the single authoritative lifecycle owner and MUST NOT introduce a
  second Battery lifecycle implementation, a parallel lifecycle state machine, or a second readiness handshake
  (constitution III, IX; `002 FR-010`).
- **FR-003**: The three distinct lifetime strata — control/process generation, retained Cache/KV/composite/slot
  state graph, disposable model residency — MUST remain distinct after migration. Suspension removes only the
  last; the retained graph and the process generation survive; AC rebuilds only the disposable stratum in the
  same generation.
- **FR-004**: With the default-off gate active, the disabled path MUST preserve upstream default behavior exactly
  as `002 FR-002…FR-008` requires, and MUST NOT be satisfied by inference from status, environment, platform
  state or Python readiness. This migration MUST restore the complete default-off `--pause-on-battery` public
  opt-in chain: serving launcher → shared serve options → Python server → native arguments → native Battery
  policy, preserving public help, exact option forwarding and default-off semantics (`002 FR-007`, `FR-013`,
  `FR-014`; `002 SC-004`). Feature 002 remains `Reopened / Not Accepted` and is not re-opened or modified here;
  this migration owns restoring and validating that missing public functionality as part of the upstream
  integration. The public CLI MUST NOT be deferred to a hypothetical future implementation.

**Ownership and concurrency**

- **FR-005**: Authority over the disposable residency stratum MUST be exclusive between the long-lived native
  owner and at most one serial residency worker at any instant; overlapping authority is a defect, and the
  worker MUST NEVER publish lifecycle truth, effective context or admission.
- **FR-006**: Residency construction and disposal MUST happen off the native safe point. While it runs, the
  control path MUST keep answering status/control and MUST honor a newer Battery or Shutdown intent; an
  in-flight worker MUST NOT be joined from a safe point, and joining an already-completed worker remains
  permitted.
- **FR-007**: While the worker holds authority, lifecycle observation MUST be served from immutable snapshots
  that cannot reveal partially transferred residency, and observation MUST remain passive (`001 FR-008`).
- **FR-008**: Quiescence before destructive release MUST cover inference requests, retained-state transfers,
  host callbacks and resource-borrowing descendants, and the long-lived owner MUST still be permitted to refuse
  release when its own ownership evidence says work remains.
- **FR-009**: Suspension MUST be provable from two independent barriers — inference/request drain and
  retained-state IO drain — and MUST be accompanied by two independent proofs: that admission closes at the
  native boundary, and that each drain condition was actually reached. Neither barrier may be substituted by
  the other or by a timing delay (`001 SC-001…SC-002`; constitution X).
- **FR-010**: Candidate adoption MUST be transactional: on refusal or failure, transferred residency MUST be
  rolled back into the private candidate before that candidate is destroyed — including rollback of altered
  callbacks, notifiers and retained Cache/StateCache bindings, not merely rollback of moved object ownership —
  and no live component may borrow from destroyed or half-published state. Cold-first recovery, where the candidate
  temporarily owns the base graph, MUST destroy in dependency order.
- **FR-011**: Publication MUST remain two-phase: physical residency adoption first with admission closed, then
  a final revision/power fence before admission opens; if a Battery intent arrives between the phases, the gate
  MUST stay closed and the just-published residency MUST be releasable by ordinary subsequent suspension.
- **FR-012**: Completed stale residency work MUST be reaped before lifecycle eligibility reporting returns,
  outside the coordination lock, so that no private residency survives merely because the newer intent is not
  AC; the worker-side final cancellation check MUST NOT be treated as sufficient on its own.
- **FR-013**: Shutdown MUST be terminal over draining, suspended and recovering; power observations and
  completed candidates MUST NOT reopen it; observer teardown MUST precede startup-owner teardown (`001 FR-024`).
- **FR-014**: When a newer AC observation races an already-committed destructive release, the current AC intent
  MUST be reconciled to a closed model-less suspended state so ordinary fenced recovery rebuilds it, without
  reopening admission directly, resurrecting destroyed residency synchronously, broadening the draining state
  into a generally recoverable state, or publishing the stale release announcement.

**Retained state and persistence**

- **FR-015**: Retained Cache, KV pool/tier, composite state and slot-backed identity MUST keep their identity
  across the boundary, and prefix reuse MUST be actual suffix-only prefill using the matching retained KV
  prefix with its composite-state boundary; retained backing that is process-local MUST NOT be reconstructed by
  starting a new child.
- **FR-016**: Upstream persistence intent for durable state MUST survive the boundary: due times, publication
  order, disk-write budget behavior and counters, and clean-shutdown flush semantics MUST be preserved as they
  are on the upstream baseline.
- **FR-017**: Due durable-state work MUST be permitted to execute during Battery suspension while the native
  owner holds residency-domain authority, and MUST be deferred — not dropped, not re-timed, not re-ordered —
  while the residency worker holds authority.
- **FR-018**: Restore and persistence failures MUST remain transactional and destination-local: partial
  destination state is never published, a failed destination restore may go cold while the immutable retained
  source stays retryable, and an in-flight offload is never obtainable as reusable state
  (`001 FR-022`; commit invariant "Pending offload is not published warm state").
- **FR-019**: Status MUST describe physical ownership rather than infer it, and MUST NOT fabricate live
  model telemetry from historical startup reports while residency is absent (`001 FR-007`, `FR-023`).

**Upstream preservation**

- **FR-020**: The migration MUST leave these upstream capabilities behaviorally unchanged: loaded-model construction
  and validation, ANE execution path, streaming expert stores, SSD/spilled-KV readers, persistent cache tiers,
  releasable/idle memory release, memory control/governor growth pause and reclaim, thermal-state reporting,
  and the current native protocol and Python server behavior — meaning their upstream semantics and existing
  event functionality, including the server's rejection of more than one readiness announcement per generation
  and its child-relaunch-on-failure path. This MUST NOT be read as forbidding a coordinated protocol-version
  extension where one is necessary; any approved wire change MUST preserve those semantics and existing event
  functionality and MUST update the native and Python codecs, protocol version, schema contracts and golden
  tests consistently.
- **FR-021**: Battery release MUST remain semantically distinct from every existing upstream memory-release or
  pause mechanism, and a Battery observation MUST NOT trigger, complete or substitute idle release, growth pause,
  thermal response or write-through pause (constitution IV).
- **FR-022**: Exactly one readiness announcement per process generation MUST be preserved; Battery MUST NOT
  cause child replacement or an additional announcement, while inference readiness may toggle within the
  generation (`001 FR-017`; `002 FR-011`, `SC-006`).
- **FR-023**: The configured capability ceiling (readiness announcement and model-metadata surfaces) and the
  effective serving context (lifecycle status, per-request telemetry) MUST remain distinct, MUST be sourced only
  from the published serving instance for the effective value, and MUST fail closed when inference-ready
  context data is missing or inconsistent.
- **FR-024**: Python-side readiness remains a fail-closed prefilter over the native boundary with bounded
  freshness: no unsolicited lifecycle push, no busy polling, no second handshake, and malformed status fails
  closed (`002 FR-011`).

**Evidence obligations**

- **FR-025**: Both historical Battery regression suites carried by the migrated commit AND the upstream-only
  suites present at the baseline MUST pass on the migrated tree. The migration MUST NOT delete, weaken, mark
  expected-failure or newly skip existing regression coverage in order to reach green. Upstream tests whose
  hardware or environment prerequisites are unavailable in a given environment MUST NOT be forced to run there,
  and that allowance MUST NOT be used to drop, weaken or skip coverage whose prerequisites are present.
- **FR-026**: Deterministic race proofs MUST exist at the ownership boundary each changes for: native admission
  closure, the two independent drain barriers, worker handoff, stale-candidate disposal, Shutdown racing
  recovery, and refused/failed adoption. Timing delays MUST NOT be used as evidence (constitution X).
- **FR-027**: Transactional persistence and state-restore tests MUST cover: due-work execution under owner
  authority and deferral under worker authority, clean-stop flush parity, restore failure isolation with the
  retained source still usable, and in-flight offload never published.
- **FR-028**: A deterministic suffix-only prefill proof MUST span two serving instances sharing one retained
  Cache, and MUST assert zero preserved-prefix replay and zero full-context warmup.
- **FR-029**: After implementation, an integration test MUST cover the complete AC → Battery → AC lifecycle in
  one process generation, including admitted work during transition, control-plane reads while suspended,
  resumed serving after recovery, and truthful state at every step (`001` Stories 1–3, `SC-011`).
- **FR-030**: Physical Apple Silicon validation MUST be performed after implementation as an operator-performed
  live session on Apple Silicon hardware, following a scripted, reproducible evidence-capture procedure defined
  in the migration plan, and MUST record: real physical AC → Battery → AC transitions; unchanged native PID
  continuity with exactly one readiness announcement; objective evidence that model/ANE/weight residency was
  released; evidence that Cache/KV/state backing was retained; actual prefix reuse with a restored boundary and
  suffix-only prefill on the resumed request; captured timestamps, relevant logs, measurements and test
  configuration; and archived results sufficient for independent review. An automated CI hardware runner is
  NOT a prerequisite; the deterministic automated lifecycle and race tests (FR-025…FR-029) remain mandatory
  and separate from this physical validation.
- **FR-031**: Normal serving MUST show no regression when the feature is disabled, measured on the migrated
  tree against the upstream baseline (startup readiness, admission, ordinary memory-pressure handling,
  status surfaces) — this restates the disabled-mode outcome as a required migration criterion
  (`002 SC-001…SC-003`).
- **FR-032**: This constraint applies to the specification authoring step only: during this step the specification
  MUST NOT modify `specs/001-battery-aware-suspension/`, `specs/002-pause-on-battery-flag/`, the constitution,
  production code or tests, and MUST NOT change Git state; producing planning artifacts (`plan.md`, `tasks.md`)
  or implementation patches is out of scope for this step (constitution XII). This MUST NOT be read as forbidding
  subsequent authorized planning or implementation steps from changing production code or tests within their own
  scope; the interrupted rebase stays protected throughout the current step.

### Compatibility and Ownership Constraints

Upstream seams the migration must interoperate with (observed at the baseline, described as behavior they
provide, not as APIs to copy): the long-lived native loop and its control/status path; the startup owner and
its staged bootstrap ending in one readiness announcement; the retainable runtime-resources graph; the cache,
KV tier and persistent-cache machinery and its queued-durable-state machinery; the state cache and composite
state reuse paths; slot-backed state files and their recycler; model loading, streamed expert stores, SSD
readers and releasable/idle memory; the thermal-state and memory-control reporters; the native protocol surface
and the Python server's per-generation readiness and child-relaunch handling; and the public serving launcher
chain that feature 002 governs.

The upstream resources graph currently keeps loaded-model residency inside the retainable graph. Parity
therefore requires an explicit retained-versus-disposable ownership split at that boundary, with the
disposable stratum movable out while the retained graph keeps the existing cache/KV/slot machinery intact.
That split is a compatibility requirement of this migration, not a change to upstream serving semantics.

Names that will appear in planning — resource-domain lease/handoff token, admission gate, residency candidate,
power observer, lifecycle status fields — are **planning decisions naming capabilities**, not existing
upstream APIs. This specification requires only the capabilities those names denote (FR-005…FR-023).

### Parity Traceability

| Migration requirement | Existing source |
|---------------------|-----------------|
| FR-001…FR-003 | `001` FR-001…FR-026; `REBASE_HEAD` central stratum contract |
| FR-004 | `002` FR-002…FR-008 (gate semantics unchanged) + `002` FR-007, FR-013, FR-014, SC-004 (full public opt-in chain restored by this migration) |
| FR-005…FR-014 | `REBASE_HEAD` invariants: ownership split, drain barriers, recovery worker, two-phase publication, stale reaping, shutdown, newer-AC race |
| FR-015…FR-019 | `001` FR-019…FR-023, FR-007; `REBASE_HEAD` "Pending offload is not published warm state" |
| FR-020…FR-024 | upstream baseline behavior; `002` FR-011; constitution IV, VII |
| FR-025…FR-032 | `001` SC-001…SC-012; `002` FR-012…FR-013, SC-001…SC-008; constitution X, XI |

### Key Entities *(include if feature involves data)*

- **Parity baseline**: The upstream tree's observable serving behavior at HEAD, used as the comparison target
  for every "unchanged" claim in this specification.
- **Migrated contract instance**: The feature-001 behavior contract evaluated on the migrated tree; its
  identity is 001's requirement and scenario IDs, not a new behavior definition.
- **Retained stratum**: The cache, KV, composite-state and slot-backed graph plus its queued persistence intent,
  with identity that must survive the boundary.
- **Disposable stratum**: Model residency together with the components that borrow from the retained stratum;
  the only stratum suspension releases and recovery rebuilds.
- **Residency authority**: The exclusive right to act on the disposable stratum, held by the long-lived owner
  or by one serial residency worker, never both (planning-stage name for a capability, per the constraints
  section).
- **Persistence intent**: A queued intention to make durable state durable, with a due time, an order, a
  disk-budget relation and a clean-stop obligation that must survive deferral.
- **Parity evidence bundle**: The set of deterministic proofs, integration results and physical validation that
  establishes migration success; each item is traceable to an existing requirement ID.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of feature-001 acceptance scenarios re-run on the migrated tree, the outcome matches
  001's expectations with no weakened assertion; parity is 001 `SC-001…SC-006` satisfied unchanged.
- **SC-002**: The historical Battery regression set and the upstream-only set both pass at 100% on the
  migrated tree, with zero dropped, deleted, weakened, downgraded or newly skipped cases in either set; upstream
  cases whose hardware or environment prerequisites are absent in a given environment are not required to run
  there, and that allowance never counts as coverage of cases whose prerequisites are present.
- **SC-003**: Zero additional readiness announcements occur across any AC → Battery → AC sequence within one
  process generation, and zero child replacements are attributable to a power observation.
- **SC-004**: Each of the six named races (admission closure, request drain, retained-IO drain, worker handoff,
  stale disposal, shutdown/failed adoption) has at least one deterministic proof at its ownership boundary, and
  the count of timing-delay-based proofs in the new evidence is zero.
- **SC-005**: In the two-instance shared-retained-Cache proof, preserved-prefix replay is zero, the restored
  cached-prefix boundary is greater than zero (cached-prefix tokens are restored, not executed), and the tokens
  actually executed as prefill equal only the uncached suffix — restored tokens and executed tokens are counted
  separately — reproducibly across repeated runs.
- **SC-006**: Across the validated AC → Battery → AC lifecycle, native process identity is unchanged,
  model-sized residency is objectively observed absent while the retained graph is observed present, and the
  resumed compatible request reuses the retained prefix (001 `SC-003`, `SC-011`).
- **SC-007**: Post-recovery resumed serving of a previously warmed long prefix completing in no more than half the
  time that prefix originally took to build is a measured performance target — supporting evidence alongside zero
  preserved-prefix replay — not a mandatory correctness gate; it MUST NOT substitute for the token-level prefix-reuse
  proof in SC-005, because recovery latency also includes model loading, ANE preparation and storage variance
  (see Assumptions for the threshold's basis).
- **SC-008**: With the feature disabled, zero Battery-specific lifecycle or status transitions occur in any
  deterministic case, ordinary startup and admission are unchanged from the baseline, and unrelated
  memory-pressure/reclaim/idle-release behavior is unchanged (002 `SC-001…SC-003`).
- **SC-009**: Across suspension, queued persistence intent is neither lost nor re-timed: due counts,
  publication order, budget-held-back behavior and clean-stop flush results match the upstream baseline, and
  due work runs under owner authority and is deferred under worker authority.
- **SC-010**: After a stale-completion, shutdown or failed-adoption case, observed retained residency from the
  abandoned work is zero, and no live component references destroyed or half-published residency.
- **SC-011**: All five semantic lifecycle conditions from 001 (`SC-009`) remain distinguishable on the migrated
  tree through existing surfaces, and no read of those surfaces changes lifecycle state or restores residency.
- **SC-012**: The specification authoring step leaves `specs/001`, `specs/002`, the constitution and all production/test
  files unmodified and Git state exactly as found; subsequent authorized planning and implementation steps MAY
  change production code and tests within their own scope, and the interrupted rebase remains protected throughout
  the current step.

## Assumptions

- The upstream tree at HEAD (`a8a74e6`) is the compatibility baseline; the interrupted rebase's `REBASE_HEAD`
  commit (`f9f4eb3a`) and its commit message are the authoritative statement of the migrated contract's
  behavioral and concurrency invariants.
- The repository stays in its interrupted rebase state throughout this step; the unresolved conflicts are
  expected and are not to be touched. Any step that would require a branch switch is treated as a blocker.
- Feature 001's contract and feature 002's gate semantics are accepted inputs; 002's own acceptance decision
  is not this feature's to revisit.
- "Objective observation" for residency means an existing or planning-stage deterministic seam or OS-level
  resource read, not a state label; this specification requires the observation, not the mechanism.
- The 50% resumed-latency threshold in SC-007 is derived from the historical live observation (a prefix that
  took over a minute to build resumed in about six seconds); it is preserved as supporting performance evidence
  and a documented performance target, not a mandatory correctness gate, and never substitutes for SC-005's
  token-level prefix-reuse proof; any tighter or looser threshold is a documented decision for planning, not a
  change in intent.
- Physical validation is an operator-performed live session on an Apple Silicon macOS host available to the
  project after implementation, with its objective observations recorded and archived as the migration's
  physical evidence per FR-030; an automated CI hardware runner is not required.
- Test evidence for the deterministic criteria may use existing power-source, startup and status seams;
  deterministic isolation MUST NOT weaken the proof obligations in FR-025…FR-031.
- Migration is a compatibility change: any place where upstream's current ownership shape and 001's required
  strata conflict is resolved in favor of 001's strata, while keeping upstream serving behavior unchanged
  for users who did not opt in.
