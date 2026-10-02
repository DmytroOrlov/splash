# Focused Validation Guide

This guide defines implementation validation scenarios, not implementation steps or a repository-wide test gate. Run focused targets on macOS because the native runtime uses Metal and IOKit. See [data-model.md](data-model.md) for state ownership and [the protocol contract](contracts/control-readiness-and-lifecycle-status.md) for readiness semantics.

## Prerequisites

- macOS host with supported Metal device and Xcode command line tools.
- Existing Splash development environment and dependencies installed as described in `DEVELOPMENT.md`.
- Build the native runtime and native tests using the repository's existing Makefile targets; do not use live machine power toggles as deterministic test input.

## Focused native checks

Build and run the focused native binaries from the repository root (the build recipes live in `dev/native.mk`):

```sh
make \
  build/engine-tests/native-engine-loop \
  build/engine-tests/runtime-bootstrap \
  build/engine-tests/runtime-resources \
  build/engine-tests/runtime-status \
  build/engine-tests/protocol \
  build/engine-tests/slot-file
build/engine-tests/native-engine-loop
build/engine-tests/runtime-bootstrap
MTL_SHADER_VALIDATION=1 \
  build/engine-tests/runtime-resources \
  build/splash.metallib
build/engine-tests/runtime-status
build/engine-tests/protocol
build/engine-tests/slot-file
```

These existing targets cover:

- `native_engine_loop_test.cpp`: held command ticket; prove admission closure and request drain before `Engine`/model teardown.
- `runtime_bootstrap_test.mm` and `runtime_resources_test.mm`: model-less battery startup (control-ready, no residency, no pre-built warm graph), residency release across `Engine` -> `RuntimeModel` -> `ModelPackage`, candidate retry, and retained base graph.
- `runtime_status_test.cpp` and `protocol_test.cpp`: exactly one `ReadyEvent` per generation (reused as control readiness) vs repeatedly readable lifecycle `inference_ready`, model-less status served without an `Engine`, and truthful lifecycle status.
- `slot_file_test.cpp` plus cache/KV tier tests: selected state offload completion and same-process backing lifetime.

The implementation tests must use explicit latches/tickets and fake power input. For active work, hold completion, deliver a battery observation, assert new native admission is closed, then release the held ticket and assert teardown starts only afterward. Do not use sleeps to assert ordering. Assert that no readiness event is re-emitted across suspend/recover cycles and that inference refusal while model-less uses unavailable/not-ready wording rather than warmup wording.

## Focused Python and HTTP checks

Run focused pytest files under the repository's configured Python environment:

```sh
.venv/bin/python -m pytest -q \
  dev/tests/engine/test_server_recovery.py \
  dev/tests/engine/test_runtime.py \
  dev/tests/engine/test_protocol_recovery.py \
  dev/tests/test_server.py
```

- `dev/tests/engine/test_server_recovery.py`
- `dev/tests/engine/test_runtime.py`
- `dev/tests/engine/test_protocol_recovery.py`
- `dev/tests/test_server.py`

Gate startup/recovery with `threading.Event` or barriers. For battery startup, assert that the model loader is not invoked before control readiness and that HTTP activates. While suspended, assert `/health` is 200, `/ready` is 503, `/status`/`/metrics` return lifecycle state with `control_ready=true` and `inference_ready=false`, and inference responds promptly with 503 without starting a process or loading a model. Across every suspend/recover cycle, assert the `MultiplexedRuntime` generation counter is unchanged, exactly one `ReadyEvent` was received for that generation, and no second readiness event arrived. Assert `backend.can_submit()`, `backend.is_ready()`, and HTTP `/ready` follow lifecycle `inference_ready` (never `runtime.ready`), while generation liveness/`wait_ready()` follows control readiness plus process health. Assert `runtime.readiness` returns the static pre-residency capability tuple (configured/descriptor context ceiling), not a memory-plan-resolved effective context.

## Required scenario outcomes

1. **Already on battery**: only control-ready state becomes available initially; no target/draft package, model runtime, `Engine`, or pre-built warm graph is constructed. `inference_ready` is false. AC observation allows model load and `inference_ready` only after success.
2. **Admission race and drain**: race request-frame processing against battery closure through a deterministic barrier. Each request is either accepted before close and retained through terminal completion, or rejected after close. Drain, cache/state IO quiescence, `Engine` destruction, then `RuntimeModel` and `ModelPackage` destruction, in that order.
3. **Intent ordering**: gate suspend and recovery completions, apply newer opposite power observations, then release gates. Final state/admission follows the highest revision, regardless of completion order. A stale candidate is destroyed without damaging retained retryable state.
4. **Warm success**: materialize a compatible composite cache state, suspend, recover under the same identity **in the same generation**, issue a matching-prefix request, and prove a cache/state restore occurred. `inference_ready` goes true without any new readiness event.
5. **Warm failure/cold fallback**: alter or invalidate identity/state layout, inject offload/restore failure, and assert cold recovery succeeds while the retained source remains usable for a later retry.
6. **Real release**: assert destruction/lifetime probes for `Engine`, package/runtime/arenas and compare existing Metal/resource counters. Assert retained KV/cache/backend totals separately. A lifecycle state string alone is not proof.
7. **Repeated toggling in one generation**: battery startup -> control ready/inference unavailable; AC -> recovery in the same generation; battery -> suspension in the same generation; AC -> recovery again in the same generation. `control_ready` stays true throughout; the generation never changes.
8. **Status inspection is passive**: while model-less or suspended, query `/status`, `/metrics`, and `/ready` repeatedly and assert no process start, no model load, no warm restore, no child replacement, and no destruction/unpinning of warm-state backing.
9. **Actual child failure**: kill/fail the child and assert generation fencing produces a new generation, a fresh one-shot `ReadyEvent` control-readiness handshake, and cold recovery.
10. **Bounded status-refresh freshness**: after native AC recovery succeeds, assert `backend.can_submit()`, `backend.is_ready()`, and HTTP `/ready` discover `inference_ready=true` within the bounded refresh — with no process restart and without requiring a user to manually query `/status` first. Then close the native battery gate and assert a deliberately stale Python `true` can never produce actual native admission after the close boundary.
11. **Effective context**: model-less startup publishes the configured/descriptor ceiling; recovery publishes the resolved effective value before `inference_ready` becomes true; an injected inconsistent/unsafe value fails closed; context drift alone does not restart the child.
12. **Shutdown**: request shutdown while draining, suspended, and candidate recovery is held. Assert ordinary shutdown wins and no incomplete transition reports success.

## Gate scope

Use only affected C++/Objective-C++ targets and focused Python files during normal development. The entire repository suite is not a routine gate for this feature; broader CI remains the final integration check after focused ownership-boundary evidence passes.
