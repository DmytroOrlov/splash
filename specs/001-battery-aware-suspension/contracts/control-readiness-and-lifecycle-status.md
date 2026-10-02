# Control Readiness and Lifecycle Status Contract

This is the planned internal contract between the native child, Python `MultiplexedRuntime`, and existing HTTP status/readiness endpoints. It extends the current binary protocol; it does not define a new user-facing lifecycle API.

It defines two independent concepts. Conflating them is a contract violation.

## Control ready

"Control readiness" is the semantic concept: a **one-shot handshake per native process generation**. Its concrete minimum implementation is the **existing wire `ReadyEvent`**, redefined in meaning rather than replaced.

The current `ReadyEvent` already is: the required first native event; one-shot per generation; what completes `MultiplexedRuntime`'s startup attempt; what `_ready_message`/`runtime.ready` use for generation readiness; and able to carry the static capability tuple Python needs. Do not add a new `ControlReadyEvent` frame merely to rename the concept, and do not leave an open "new frame vs old `ReadyEvent`" fork — unless implementation evidence forces a protocol version change, the existing frame is the design.

Its semantics change from "fully warmed inference is ready" to:

- the native process generation is alive;
- protocol/control/status traffic is usable;
- `MultiplexedRuntime` startup for this generation has completed;
- the process must not be replaced merely because inference is unavailable;
- it carries static/pre-load capability/configuration values.

Properties:

- Emitted **exactly once per generation**. It is never re-emitted for suspension or recovery, and no second readiness event of any kind exists later in the same generation — there is no second `ReadyEvent` and no separate optional "model `ReadyEvent`".
- It completes the startup attempt and suppresses ordinary startup timeout/relaunch for an intentionally model-less child; Python rejects any event that arrives before it.
- Its capability payload contains only values valid before model residency is established: served model names, the **configured/descriptor context ceiling** (not the later memory-plan-resolved effective context), static concurrency capability, feature bits/vision capability derivable from descriptor or configuration, and engine/generation identity as currently applicable.
- It does **not** make inference ready.
- It stays true while the child itself is healthy — including during `draining`, `suspended`, `recovering`, and `recovery_failed`.
- A new generation always begins with `control_ready=false` and a fresh handshake.

Frame type/version/field encoding follows `server/protocol.py` and `runtime/engine/Protocol.*`; if the payload semantics are versioned, update both encoders/decoders and protocol tests together.

## Inference ready

`inference_ready` is a **dynamic lifecycle state owned by `RuntimeBootstrap`**, exposed through detached lifecycle/status data. It is not an event: it is neither a second readiness frame nor an unsolicited lifecycle push.

It may transition repeatedly within one native process generation:

```text
false -> true -> false -> true ...
```

| Step | `control_ready` | `inference_ready` | New generation? |
|---|---:|---:|---:|
| Startup on battery | true | false | no |
| AC recovery succeeds | true | true | no |
| Battery suspension | true | false | no |
| Later AC recovery | true | true | no |
| Suspended status inspection | true | false | no (no restart, no model start) |
| Actual child failure | false, then a new handshake | false (cold recovery) | yes |

These transitions **do not** create a new native process generation, do not re-emit the readiness handshake, and do not require a second `ReadyEvent`.

`inference_ready=false` never means the generation is stale. Only EOF, process exit, or protocol failure fences a generation and forces restart; a restarted child has lost process-local warm state and therefore recovers cold.

### Bounded freshness

`StatusJsonEvent` is request/response (`StatusRequestFrame` -> `StatusJsonEvent`), not an unsolicited lifecycle push. Keep that surface unless implementation evidence proves it inadequate.

- `RuntimeBootstrap` remains the authoritative `inference_ready` owner; `NativeBackend` obtains the value from detached native status.
- `can_submit()`, `is_ready()`, and HTTP readiness have a **bounded status-refresh path** that discovers the current lifecycle state, so a cached false or stale snapshot never leaves Python permanently closed after a successful native AC recovery. The refresh trigger is the cached lifecycle value, not `runtime.ready` (which stays true while model-less).
- The trigger must not require a user to query `/status` first, and polling on every request is not mandated.
- Refresh while model-less is passive: it never starts or replaces the process and never restores inference.
- A stale `true` is never authoritative for correctness: the final native admission gate still rejects after battery closure, so no correctness claim depends on Python winning an admission race.
- No unsolicited lifecycle event is added unless later implementation evidence shows this bounded refresh cannot satisfy the contract.

## Status semantics

Existing `/status` and native status JSON gain detached fields equivalent to:

```json
{
  "control_ready": true,
  "lifecycle": {
    "state": "ready | draining | suspended | recovering | recovery_failed | shutdown",
    "power": "ac | battery | unknown",
    "revision": 1,
    "inference_ready": false,
    "model_resident": false,
    "configured_context_ceiling": 131072,
    "effective_context_tokens": null,
    "last_error": null
  }
}
```

These names illustrate semantics; final keys follow existing status schema conventions. Requirements:

- The snapshot is servable while no `Engine` exists; it comes from bootstrap-owned detached state, not from `Engine`'s snapshot/telemetry path.
- `lifecycle.state` comes from the native authoritative owner. `revision` identifies the newest accepted native power intent.
- `control_ready` is reported alongside, and independently of, `inference_ready`.
- `configured_context_ceiling` is the detached configured/descriptor value available before weight loading and is what the one-shot `ReadyEvent` carries. `effective_context_tokens` is the memory-planning-resolved serving context; it is `null`/absent until a recovery resolves it, must be published (non-null) **before** `inference_ready` becomes true, and may be updated by later recoveries before admission reopens. It travels only through lifecycle/status, never through the readiness handshake. Admission uses the current resolved value. An inconsistent or unsafe resolved value fails closed (`inference_ready=false`). Context drift alone never restarts the process.
- A model-less snapshot may include cache/backing and backend values that are still valid, but runtime-only model telemetry must be absent/unavailable, never stale-as-live.
- `control_ready` remains true during `draining`, `suspended`, `recovering`, and `recovery_failed` while the child itself is healthy.
- Status requests are passive: they cannot load or restore a model, start a process, replace the native child, or destroy/unpin warm-state backing.
- Battery lifecycle state must **not** be derived from existing Scheduler/resource terminology (`admission.suspended`, `admission.draining`, per-request suspend/replay) or from Python's `transport.recovering`. Those are unrelated states with unrelated meanings.

## Python semantics

| Python surface | Uses |
|---|---|
| `MultiplexedRuntime` generation liveness, startup attempt completion, `wait_ready()`, `_require_generation_ready_locked()` | `control_ready` **plus** actual process health (`process.poll()`); EOF/exit/protocol failure still fences the generation |
| `runtime.ready`, `_ready_message` | **Control readiness** (process/generation readiness) — never inference readiness |
| `runtime.readiness` (the one-shot `ReadyEvent`) | the static pre-residency capability/configuration tuple, including the configured/descriptor context ceiling |
| `NativeBackend.can_submit()` | lifecycle `inference_ready`, via the bounded status-refresh path |
| `NativeBackend.is_ready()` | lifecycle `inference_ready` (plus existing memory-pressure verdict), via the bounded status-refresh path |
| HTTP `/ready` | lifecycle `inference_ready`, via the bounded status-refresh path |
| HTTP `/health` | HTTP process liveness |
| HTTP `/status`, `/metrics` | detached lifecycle/control/inference status above |

Additional requirements:

- Status inspection while intentionally model-less must not start or restart the model or replace the native child.
- The bounded freshness rule in [Bounded freshness](#bounded-freshness) applies to `can_submit()`, `is_ready()`, and `/ready`: no indefinite stale-false closure after native AC recovery, and no reliance on a stale `true`.
- A suspended inference submission returns prompt explicit 503/unavailable/not-ready without waiting for AC and without triggering implicit restoration. Refusal wording is unavailable/not-ready, not warmup.
- Ordinary startup timeout/relaunch is suppressed only while the child is actually alive and control-ready; real child failure retains existing generation fencing and restart policy.

## HTTP behavior

- `/health`: HTTP/control-process liveness; remains HTTP 200 when inference is unavailable but server process is operating.
- `/ready`: HTTP 200 only when native lifecycle says `inference_ready=true`; otherwise HTTP 503.
- `/status` and `/metrics`: remain available and include truthful lifecycle/readiness information via existing schema/surfaces.
- Inference endpoints: while model-less or after lifecycle gate closure, return prompt explicit 503/unavailable/not-ready without waiting for AC or triggering implicit restoration.
- Static `/v1/models` and served-model metadata may use detached startup configuration. Do not report runtime-derived model readiness from static metadata.

## Ownership and failure distinctions

The power observer is native and reports only current power. `RuntimeBootstrap` owns intent revisions, lifecycle transitions, and `inference_ready`. The native startup handshake owns `control_ready`. `MultiplexedRuntime` owns process generation and transport fencing; it does not own battery policy.

An intentional battery suspension keeps the child process, the `NativeRuntime` control shell, `FdTransport`, and the control event stream alive while the residency stratum (`Engine`, `RuntimeModel`, `ModelPackage`) is destroyed. A child crash invalidates its generation and follows existing restart semantics; cache state is then cold because `SlotFile` backing is process-local. Shutdown terminates the child and does not emit a successful suspended/ready result for an incomplete transition.
