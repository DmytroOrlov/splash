# Public CLI Boundary and Acceptance Evidence Checklist: Explicit Battery Suspension Opt-In

**Purpose**: Independently assess the completeness, clarity, consistency, and testability of the public CLI, argument propagation, and acceptance evidence requirements.
**Created**: 2026-10-06
**Feature**: [spec.md](../spec.md)

**Note**: This custom checklist is a reviewer-owned requirements-quality review artifact.
**Review Ownership**: Mark an item `[x]` only when the reviewer determines its requirements-quality criterion is satisfied.
**Marker Semantics**: `[x]` means the criterion has been reviewed and satisfied for requirements quality. It does not mean implementation work is complete.

## Requirement Completeness

- [ ] CHK001 Are the public command boundary and the shell symlink/launcher dispatch explicitly part of the acceptance scope, with `./splash serve` distinguished from direct Python module invocation? [Completeness, Spec §Clarifications; Contract §Public command and help]
- [ ] CHK002 Are public help/option declaration and recognition of an exact supplied `--pause-on-battery` token defined as separate acceptance claims? [Clarity, Spec §Clarifications; Contract §Public command and help]
- [ ] CHK003 Does the exact-token recognition criterion require inspecting the final unknown-arguments diagnostic for the unique probe present and the feature token absent, rather than relying on help output or exit status? [Acceptance Criteria, Contract §Public command and help]
- [ ] CHK004 Does the evidence requirement define a safe real-executable recognition invocation that stops before installation, download, build, server, or native work? [Completeness, Contract §Public command and help; Quickstart §Focused validation order]
- [ ] CHK005 Are both launcher→server and server→native argv hops explicitly covered, including exactly one standalone token when true and omission when false? [Completeness, Spec §FR-007; Data Model]
- [ ] CHK006 Does evidence separately cover native argv parsing into `NativeArguments::pauseOnBattery` and the `runNative()` policy decision endpoint? [Completeness, Spec §FR-007–FR-009; Contract §Native parse and startup]
- [ ] CHK007 Are absent/default-false semantics specified at the public parser, server parser, and native argument representation, including false propagation without an invented false token? [Completeness, Spec §FR-002, FR-007; Data Model]
- [ ] CHK008 Are true-only propagation and exactly-once token requirements stated at both argv hops, with ordering relative to neighboring native options sufficiently defined? [Clarity, Data Model; Contract §Launcher to server and §Server to native]
- [ ] CHK009 Do the requirements explicitly exclude a negative flag, false-valued token, environment/config alias, protocol field, status command, and runtime mutation? [Completeness, Spec §FR-015; Contract §Native parse and startup]
- [ ] CHK010 Is the help wording requirement explicit about model residency release on Battery and recovery on AC while avoiding a claim that all retained memory, cache, or state is freed? [Clarity, Spec §User Story 3 and FR-014; Contract §Public command and help]
- [ ] CHK011 Are enabled startup semantics separately defined for initial Battery, Unknown, and AC, and is disabled mode defined to bypass power policy while retaining unrelated native control/reclaim behavior? [Scenario Coverage, Spec §User Stories 1–2; FR-006, FR-009]
- [ ] CHK012 Is reuse of feature-001 lifecycle/recovery acceptance evidence required without duplicating that lifecycle matrix, while still identifying the invariants this feature must preserve? [Consistency, Spec §FR-010–FR-013; Plan §Acceptance Evidence Strategy]

## Requirement Clarity and Consistency

- [ ] CHK013 Is there a complete boundary→evidence chain from the real outer executable through launcher parsing/argv, server parsing/argv, native parsing, and `runNative()`, with every hop directly observed or an explicit justified composition? [Ambiguity, Spec §Clarifications and FR-012–FR-013; Plan §Acceptance Evidence Strategy]
- [ ] CHK014 Are the requirements consistent about whether enabled/default propagation evidence must begin at the real outer executable and reach native argv in one composed invocation, or may be assembled from separately invoked boundary tests? [Conflict, Spec §Clarifications and FR-012–FR-013; Plan §Acceptance Evidence Strategy; Contract §Evidence boundary]
- [ ] CHK015 Does the acceptance language distinguish evidence that proves public CLI acceptance from internal launcher parser tests, server parser tests, and native parser tests? [Clarity, Spec §Clarifications; Contract §Evidence boundary]
- [ ] CHK016 Are deterministic test-double limits clear about which boundary may be intercepted and what must already have been observed before model preparation/native execution is isolated? [Clarity, Spec §FR-013 and SC-004; Plan §Acceptance Evidence Strategy]
- [ ] CHK017 Are default-mode evidence requirements complete for full startup under Battery/Unknown, model and Engine residency, inference admission, later Battery/AC observations, absence of battery transitions, and continued non-battery reclaim? [Completeness, Spec §FR-003–FR-006 and FR-012; SC-001–SC-003]
- [ ] CHK018 Are enabled-mode startup, same-generation recovery, and one-ReadyEvent acceptance criteria traceable to explicit evidence without implying that a public parser probe itself demonstrates lifecycle behavior? [Consistency, Spec §FR-009–FR-013; SC-005–SC-008]
- [ ] CHK019 Is each success criterion SC-001 through SC-008 mapped to named acceptance evidence, with no success criterion left to inference from an adjacent or differently scoped test? [Traceability, Spec §SC-001–SC-008; Plan §Acceptance Evidence Strategy]
- [ ] CHK020 Is each functional requirement FR-001 through FR-015 mapped to explicit acceptance evidence or a clearly identified inherited feature-001 regression source? [Traceability, Spec §FR-001–FR-015; Contract §Evidence boundary]
- [ ] CHK021 Is the required final real user-command smoke after implementation distinguished from deterministic automated acceptance, and are its command, expected observation, and safety boundary specified? [Gap, Spec §FR-012–FR-014; Plan §Validation Plan; Quickstart]

## Repository Boundary and Scope Evidence

- [ ] CHK022 Are the named production and test seams validated against current repository ownership, including whether the launcher parser and forwarding path actually own the missing public hop? [Dependency, Plan §Repository Evidence]
- [ ] CHK023 Is expected production/test scope justified by the current launcher, server, native, and test ownership boundaries rather than inherited solely from prior conclusions? [Assumption, Plan §Expected Patch; Research §Resolved Questions]
- [ ] CHK024 Are lifecycle/recovery tests identified as regression evidence only, with the configuration-gate evidence kept at the launcher/server/native argument and owner seams? [Consistency, Plan §Acceptance Evidence Strategy; Quickstart §Focused validation order]

## Existing Requirements Checklist Revalidation

- [ ] CHK025 Are the checked “testable and unambiguous requirements,” “clear acceptance criteria,” and “feature readiness” assertions in `checklists/requirements.md` still supportable after the reopened public-boundary clarification and exact-token evidence requirement? [Ambiguity, requirements.md §Requirement Completeness and §Feature Readiness; Plan §Checklist Status]

## Notes

- Mark items `[x]` only after review confirms the requirement-quality criterion is satisfied; this generated checklist intentionally leaves every item unchecked.
- `$speckit-implement` reads checklist checkbox state as a gate and must not modify markers.
- `checklists/requirements.md` is a separate built-in spec-quality checklist maintained by `$speckit-specify` and `$speckit-clarify`; this checklist does not replace it.
- Items assess written requirements and evidence design, not implementation correctness.
