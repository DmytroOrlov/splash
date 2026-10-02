# Contract: Public CLI Opt-In Chain and Python Lifecycle Revision

Covers 003 FR-004, FR-024, FR-031, SC-008; 002 FR-002…FR-014 (gate semantics unchanged; 002 itself stays Reopened / Not Accepted); constitution IX, XII. Referenced from `plan.md` workstream F.

## Ownership of each link in the chain (current upstream, unchanged by this migration)

| Link | Owner / file | Symbol |
|---|---|---|
| Public CLI | `install/launcher.py` | `serve()` (`:228`), `parse_args()` (`:416`), option forwarding into the child argv |
| Shared serve options | `server/serve_options.py` | `parse_max_context` (`:93`), `parse_idle_release` (`:235`), defaults (`DEFAULT_PORT`, `DEFAULT_QUEUE_SIZE`, `DEFAULT_MAX_REQUEST_BYTES`) |
| Server argument parsing | `server/server.py` | `parse_args()` (`:1664`), uses `serve_options.parse_*` (`:1674`) |
| Native argument parsing | `runtime/engine/NativeArguments.{hpp,cpp}` | `NativeArguments` (`:23`), `parseNativeArguments(argc, …)` (`:88`) |
| Native policy application | `runtime/main.mm` + `engine/Bootstrap.hpp` | power observation wiring + lifecycle policy owner (Bootstrap remains the sole owner) |
| Python runtime/lifecycle observation | `server/runtime.py`, `server/backend.py` | `MultiplexedRuntime` (`:429`), `RuntimeCall.generation` (`:174`), `NativeBackend.is_ready` (`:543`) |
| Launcher tests | `dev/tests/install/test_launcher.py`, `test_launcher_local.py` | existing argv-forwarding and help assertions |

## Obligations

1. **Restore the complete opt-in chain** (FR-004): `--pause-on-battery` at the public launcher, through shared serve options, into the Python server's child argv, into native parsing, into native Battery policy — with public help text and exact forwarding. It may not be deferred to a later implementation, and may not be replaced by inference from environment, platform state, status or Python readiness.
2. **Default-off, unchanged**: with the option absent, upstream default behaviour is exactly the baseline — full startup, model residency, inference admission, ordinary memory-pressure/idle-release behaviour; **no** power observer is created or started and **no** initial power sample is taken merely to be ignored (002 FR-003…FR-005, SC-001…SC-003, FR-031, SC-008).
3. **Do not fork CLI ownership**: the historical patch parsed the flag inline in `main.mm` (`f9f4eb3a:runtime/main.mm:236`); upstream owns native CLI parsing in `NativeArguments`, so the flag migrates there with help text, and `main.mm` only wires the policy (constitution IX/XII).
4. **Disabled-mode isolation**: Battery machinery is constructed only when opted in; when disabled, zero Battery-specific lifecycle or status transitions occur in any deterministic case, under fake initial Battery and Unknown power.
5. **Python lifecycle contract** (FR-024, research D-14): status is applied only when `(processGeneration, lifecycleRevision, observationSequence)` is strictly greater than the last applied tuple. `processGeneration` `[U]` orders status across child replacement; `lifecycleRevision` `[P]` orders status across power-revised intents inside one generation; `observationSequence` `[P]` orders lifecycle phases **within one revision** (one Battery revision spans `Draining → Suspended`; the newer-AC reconciliation moves `Draining → Suspended` with no new revision), because transport/HTTP completion order is not native observation order. Bounded freshness with one passive refresh; no unsolicited push, no busy polling, no second handshake; malformed/missing/inconsistent inference-ready data fails closed.
6. **Frontend context separation** (FR-023 link): `server/frontend.py`'s single `max_context` currently serves budgeting and context-length errors at once (`:242,296,403,405,707,708,773,774,1216,1217,1218`); the migration separates static configured capability (budget ceiling, `/v1/models`, readiness) from the dynamic effective context (error thresholds and per-request telemetry follow the published Engine).

## Verification obligations

| Gate | Proof | Seam |
|---|---|---|
| 13 — disabled-mode parity | option absent + fake Battery/Unknown initial power: ordinary startup, admission unchanged, zero Battery lifecycle/status transitions, unrelated memory-pressure/reclaim/idle-release unchanged | `dev/tests/server/test_serve_options.py`, `test_native_backend.py`, `test_memory_release.py`; native disabled-path case in `native_main_test.mm` |
| Chain fidelity | exact forwarded argv and help text for the option, launcher → server → native | `dev/tests/install/test_launcher.py`, `test_launcher_local.py`, native `parseNativeArguments` case |
| 11 — Python ordering / passive status | generation-vs-revision ordering cases; old-generation completion discarded; lower revision ignored; **same generation + same revision, completions delivered in reverse observation order → the newer phase survives**; status reads cause no residency work | `dev/tests/server/test_runtime.py`, `test_protocol_python.py` + `[P]` `observationSequence` fixture |
| Context separation | Gate 12 cases from `native-control-status-and-protocol.md`, plus frontend budget/error cases | `dev/tests/server/test_chat*.py` + new static-vs-effective case |

## Prohibited implementations

| Shortcut | Why rejected |
|---|---|
| Native-only gate with no public option | FR-004 explicitly forbids deferring the public CLI |
| Keeping inline `main.mm` parsing of the flag | forks CLI ownership away from `NativeArguments` (constitution IX) |
| Enabling Battery machinery always and ignoring it at policy time | creates observers and power sampling in the default path; violates 002 FR-005/SC-003 and FR-031 |
| Python-side gating as the correctness boundary | the native gate is the boundary; Python is a prefilter (FR-024) |
| Treating child replacement as the opt-in recovery path | constitution IV; also emits a second readiness announcement (FR-022) |
