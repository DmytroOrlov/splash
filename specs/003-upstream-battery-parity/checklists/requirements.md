# Specification Quality Checklist: Upstream Battery Suspension Parity Migration

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-11-01
**Feature**: [spec.md](../spec.md)

**Note**: This checklist is maintained by the `$speckit-specify` / `$speckit-clarify` lifecycle.
`[x]` means the requirement-quality criterion has been reviewed and satisfied for this specification;
it does not mean migration work is complete.

## Content Quality

- [x] No implementation details (languages, frameworks, APIs) — behavior and invariants only. The
      `Compatibility and Ownership Constraints` section names upstream seams as boundary references
      (precedent: `002-pause-on-battery-flag`), and every planning-stage name (resource-domain lease/handoff
      token, admission gate, residency candidate, power observer) is explicitly flagged as a capability
      name, not an existing API.
- [x] Focused on user value and business needs — value is parity and regression avoidance; each story
      states the operator outcome at stake.
- [x] Written for non-technical stakeholders — user stories are plain-language operator journeys.
      Technical depth is confined to requirements, success criteria and boundary sections, matching
      `001`/`002` precedent for lifecycle work.
- [x] All mandatory sections completed — User Scenarios & Testing, Requirements, Success Criteria,
      Assumptions; Key Entities included (feature involves retained state).

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain — both resolved in the 2026-11-01 clarify session: `FR-004`
      (full public opt-in chain restored by this migration) and `FR-030` (archived operator-performed Apple
      Silicon live session).
- [x] Requirements are testable and unambiguous — all FRs now state a checkable outcome; the former FR-004
      and FR-030 scope ambiguities are resolved and each points to an existing `001`/`002` ID or invariant.
- [x] Success criteria are measurable — counts, zero-event assertions, token-level reuse measures, latency
      ratio, unmodified-artifact checks.
- [x] Success criteria are technology-agnostic — no frameworks, languages or libraries; terms are product
      resource concepts (residency, retained graph, persistence intent, process identity).
- [x] All acceptance scenarios are defined — 7 stories with Given/When/Then, each traced to an existing
      `001`/`002` requirement or a `REBASE_HEAD` invariant.
- [x] Edge cases are identified — mechanism-conflation, thermal/memory events during suspension, genuine
      child failure, late landing write, in-flight offload, restore failure, duplicate observations,
      untouched-rebase constraint.
- [x] Scope is clearly bounded — out-of-scope (001/002 edits, `plan.md`/`tasks.md`, patches, Git state) is
      explicit in `FR-032`/`SC-012` (step-scoped to specification authoring) and the Scope Statement; the
      former `FR-004` public-surface boundary is closed by clarification decision A.
- [x] Dependencies and assumptions identified — baseline `a8a74e6`, `REBASE_HEAD` `f9f4eb3a` as contract
      source, seams, latency-threshold basis, Apple Silicon host availability.

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria — FR-001…FR-032, each mapped in
      `Parity Traceability`.
- [x] User scenarios cover primary flows — enabled parity, disabled non-regression, async ownership,
      failure/shutdown, retained reuse, persistence intent, diagnostics.
- [x] Feature meets measurable outcomes defined in Success Criteria — SC-001…SC-012 trace to `001 SC-001…SC-012`
      and `002 SC-001…SC-008`.
- [x] No implementation details leak into specification — reviewed after the two clarifications were folded in;
      the additions name boundaries, evidence obligations and existing `001`/`002` IDs, not designs.

## Pending Clarifications

**Question 1: Public opt-in surface scope (`FR-004`)**

- **What we need to know**: Does this migration re-land the full public `serve` option chain (`002 FR-007`,
  `FR-013`, `FR-014`), or migrate only the native-side default-off gate and leave the public CLI chain to
  the reopened feature 002?
- **Implication A (migrate full chain)**: 003 owns launcher → server → native argv propagation evidence
  (`002 SC-004`) and public help; scope grows by the CLI chain and its hop-by-hop proofs.
- **Implication B (native gate only)**: 003 stays inside the native boundary; 002's reopened scope owns the
  public surface; disabled-mode parity must still be proven at the native boundary.
- **Resolved 2026-11-01 — Option A**: this migration restores the full default-off `--pause-on-battery` chain
  (launcher → shared serve options → Python server → native arguments → native Battery policy) with public help
  and exact forwarding; feature 002 stays Reopened / Not Accepted and is not modified.

**Question 2: Physical Apple Silicon evidence mode (`FR-030`)**

- **What we need to know**: Automated run on Apple Silicon hardware available to the project, or an
  operator-performed live session whose objective observations are archived as the migration's physical
  evidence?
- **Implication A (automated)**: requires an Apple Silicon runner in the project's harness; stronger
  repeatability, more harness work.
- **Implication B (archived live session)**: matches the historical live observation; requires recorded
  PID/residency/reuse observations with no CI dependency.
- **Resolved 2026-11-01 — Option B**: an operator-performed live session on Apple Silicon hardware following a
  scripted evidence-capture procedure (PID continuity, one readiness announcement, residency-release and retained
  backing evidence, restored boundary with suffix-only prefill, timestamps/logs/configuration) archived for
  independent review; an automated CI hardware runner is not a prerequisite.

## Notes

- Items marked incomplete require spec updates before `$speckit-clarify` or `$speckit-plan`.
- Validation iteration 1 recorded: 10 items pass, 3 items blocked on the two pending clarifications.
- Validation iteration 2 recorded (2026-11-01, after the clarify session): 12 items pass, 0 blocked. The two
  clarifications were folded into `spec.md`; consistency corrections were applied to `FR-010` (rollback of
  callbacks/notifiers/Cache bindings), `FR-020` (coordinated protocol extension allowed with consistent codec
  updates), `FR-025`/`SC-002` (no weakening/newly-skipped coverage; prerequisite availability respected),
  `SC-005` (restored vs executed tokens), `SC-007` (performance target vs correctness gate) and `FR-032`/`SC-012`
  (step-scoped authoring constraint).
- Git-state and untouched-artifact criteria (`FR-032`, `SC-012`) were satisfied during authoring: only
  `specs/003-upstream-battery-parity/**` and `.specify/feature.json` (untracked) were written; no rebase
  state, production code, test, `001` or `002` file was modified.
