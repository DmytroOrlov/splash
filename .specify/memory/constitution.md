<!--
Sync Impact Report
- Version change: scaffold → 1.0.0 (initial project constitution)
- Modified principles: none; all twelve principles are newly established
- Added sections: Splash Core Principles; Architecture and Resource Constraints;
  Specification and Verification; Governance
- Removed sections: unresolved scaffold placeholders and examples
- Follow-up TODO: confirm the original ratification date
-->

# Splash Constitution

## Core Principles

### I. Inference Correctness Over Optimization
Power saving, telemetry, cache reuse, warm recovery, and observability MUST remain
auxiliary to inference correctness. They MUST NOT silently change model output
semantics, sampling, batching, request attribution, cancellation, retry behavior,
or scheduler correctness. If an optimization cannot be proven safe, the system
MUST use a correct colder or slower path.

### II. Explicit Ownership for Concurrent Lifecycles
Resources that can be replaced, suspended, unloaded, or destroyed during
concurrent work MUST have explicit lifetime ownership. Lifecycle decisions MUST
not rely on check-then-act sequences. Admitted inference MUST retain its required
model, runtime, and cache resources through completion or cancellation. Work MUST
NOT be admitted based on a stale decision after admission closes. Cleanup MUST
support duplicate finalization safely; idempotence does not replace clear
ownership.

### III. One Authoritative Lifecycle Owner
Coordinated lifecycle state MUST have one authoritative owner, including
admission, draining, suspension and recovery, runtime replacement, automatic
power reactions, and conflicting administrative intent where such operations
exist. Power and battery observers provide inputs; transports carry intent; neither
becomes a competing owner of lifecycle truth. Expensive model, cache, or device
work MUST NOT run while short coordination-state locks are held.

### IV. Suspension and Destructive Teardown Are Distinct
Temporary suspension for later recovery MUST remain semantically distinct from
destructive shutdown, unload, or replacement. A resumable operation MUST NOT
reuse a destructive path unless every promised surviving state is independently
proven durable and compatible. Crash recovery and power suspension MUST NOT be
treated as equivalent without evidence.

### V. Cache Reuse Requires Proven Lifetime and Compatibility
Warm cache or prefix reuse is optional; correct cold recovery is mandatory.
Retained state MUST remain valid throughout suspension, have no dangling model,
runtime, factory, or device ownership, and carry enough identity to prove
compatibility with the recovered runtime. Unknown compatibility MUST fail closed
to cold recovery. Failed candidate or recovery attempts MUST NOT corrupt state
whose retryability is promised. Disk backing alone does not prove survival across
a process or resource lifetime boundary. Existing cache identity mechanisms
SHOULD be reused when they prove the required property; new identity is warranted
only for an unproven compatibility dimension.

### VI. Newer Lifecycle Intent Takes Precedence
Where asynchronous lifecycle actions can supersede one another, stale automatic
work MUST NOT overwrite newer authoritative intent merely because it completes
later. Revisions, generations, ownership tokens, or an equivalent explicit
mechanism MUST resolve that race. This principle does not require inventing
administrative APIs that Splash does not have; lifecycle ownership MUST allow
future explicit intent to be represented safely.

### VII. Model-Less Control Plane Is Truthful
Health, status, metrics, startup reporting, and diagnostics MUST define behavior
when no model is resident. Control-plane reads MUST NOT dereference destroyed
runtime state, retain inference resources indefinitely, implicitly reload them,
or present stale model state as live. Unsafe or unavailable model-derived
information MUST be reported as unavailable, not fabricated or retained through
unsafe ownership.

### VIII. Observability Is Passive and Correctly Attributed
Telemetry MUST NOT change inference behavior to obtain measurements. A value
MUST be presented as request-local only when its ownership is provable;
process-, batch-, scheduler-, and engine-wide measurements MUST NOT be silently
attributed to an individual request. Valid authoritative provider or runtime
measurements MUST take precedence over estimates for the same semantic quantity.
Missing measurements mean absence, not zero.

### IX. Preserve Proven Architecture
Lifecycle, telemetry, and cache features MUST reuse existing Splash ownership
and scheduling abstractions when their semantics match. Features MUST NOT create
parallel provider-specific or feature-specific state machines when an existing
owner can correctly own the behavior. Superficially similar mechanisms MUST NOT
be merged when their ownership or lifetime semantics differ. Shared abstractions
MUST follow demonstrated common semantics, not speculative reuse.

### X. Concurrency Claims Require Deterministic Evidence
Race-sensitive behavior MUST be verified with deterministic synchronization,
explicit state or ownership observations, or controlled seams wherever
practical. Arbitrary sleeps MUST NOT serve as proof of drain ordering, stale
action invalidation, admission closure, teardown safety, retry ownership, cache
handoff, or concurrent request attribution. High-risk lifecycle changes MUST
include focused regression coverage at the ownership boundary they change.

### XI. Resource Release Must Be Real
Features intended to reduce memory or device pressure MUST establish that
long-lived server objects, diagnostics, callbacks, caches, factories, and startup
state do not retain the expensive model or runtime resources intended for
release. Detached display and diagnostic data SHOULD be used when reporting does
not require a live object reference.

### XII. Evidence Before Architecture
Specifications MUST describe user-visible behavior and invariants. Process
boundaries, controller placement, cache-detachment mechanics, protocol messages,
and class ownership belong in planning and MUST be derived from the current
Splash checkout. Borrowed designs MUST preserve the required invariant rather
than incidental class structure.

## Architecture and Resource Constraints

Architecture choices MUST follow evidence from the current Splash checkout.
Provider and runtime integrations MUST preserve the common inference contract
while keeping genuinely different ownership and lifetime semantics explicit.
Resource and cache claims MUST identify what remains live, what is released, and
what evidence demonstrates the stated behavior.

## Specification and Verification

Specifications and reviews MUST trace behavior to observable outcomes and
invariants. Plans for lifecycle-sensitive or telemetry changes MUST explicitly
review concurrent ownership, lifecycle authority, safe suspension and teardown,
cache lifetime and compatibility, model-less control-plane truthfulness, and
inference independence from telemetry and power policy. Regression evidence
SHOULD target the concrete ownership boundary changed.

## Governance

This constitution governs project specifications, plans, implementation, and
review. Amendments MUST update this document and its Sync Impact Report; reviews
MUST check proposed work against applicable principles and record justified
exceptions. Principles are versioned semantically: MAJOR for incompatible
removals or redefinitions, MINOR for added principles or materially expanded
guidance, and PATCH for non-semantic clarification. Every amendment MUST update
the last-amended date. Constitution compliance is reviewed during specification
and plan review and again when implementation evidence is evaluated. Any
exception MUST state the conflicting principle, the evidence and rationale, and
the scope of the exception.

**Version**: 1.0.0 | **Ratified**: TODO(RATIFICATION_DATE): original adoption date unknown | **Last Amended**: 2026-10-01
