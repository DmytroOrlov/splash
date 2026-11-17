# Disabled-mode upstream baseline — clean `a8a74e6`

## Scope

Clean upstream has no Battery opt-in feature, no Battery lifecycle state, and no Battery lifecycle tests. Therefore no baseline Battery lifecycle tests were invented. This document records upstream behavior for ordinary startup, admission, memory pressure, idle weight release, status, and control paths that the later migration must not regress.

All commands below ran in the external clean baseline:

```text
/tmp/splash-baseline-a8a74e6-complete.vc83v0
```

The interrupted repository tree was not used.

## Relevant existing upstream tests

### Native CPU focused tests

Commands:

```sh
cd "$BASELINE_DIR"
build/engine-tests/runtime-bootstrap
build/engine-tests/runtime-status dev/tests/engine/status_golden.json
build/engine-tests/native-engine-loop
build/engine-tests/native-fd-transport
build/engine-tests/engine
build/engine-tests/memory-governor
build/engine-tests/runtime-metrics
```

Results:

| Binary | Category | Result |
|---|---|---|
| `runtime-bootstrap` | startup/warmup/Ready announcement | PASS |
| `runtime-status` | status contract | PASS |
| `native-engine-loop` | admission, memory pressure, idle-weight release, request loop | PASS |
| `native-fd-transport` | control transport and status/control behavior | PASS |
| `engine` | admission/request engine behavior | PASS |
| `memory-governor` | memory pressure/reservation behavior | PASS |
| `runtime-metrics` | control-plane metric behavior | PASS |

Counts: 7 native focused binaries executed; 7 PASS; 0 failures; skipped counts are not reported by the harness.

### Python focused tests

Commands:

```sh
cd "$BASELINE_DIR"
.venv/bin/python -m unittest dev.tests.server.test_native_backend
.venv/bin/python -m unittest dev.tests.server.test_runtime
.venv/bin/python -m unittest dev.tests.server.test_request_contract
.venv/bin/python -m unittest dev.tests.server.test_memory_release
.venv/bin/python -m unittest dev.tests.server.test_status_contract
.venv/bin/python -m unittest dev.tests.server.test_server_recovery
.venv/bin/python -m unittest dev.tests.server.test_serve_options
.venv/bin/python -m unittest dev.tests.server.test_server_main
.venv/bin/python -m unittest dev.tests.server.test_crash_trace
.venv/bin/python -m unittest dev.tests.install.test_launcher
```

Results:

| Suite | Category | Tests | Result |
|---|---|---:|---|
| `test_native_backend` | admission/status backend behavior | 47 | PASS |
| `test_runtime` | native event/runtime generation, Ready handling | 65 | PASS |
| `test_request_contract` | request admission/request API contract | 26 | PASS |
| `test_memory_release` | idle memory/weight release behavior | 6 | PASS |
| `test_status_contract` | status/control schema behavior | 8 | PASS |
| `test_server_recovery` | ordinary engine relaunch/replacement recovery | 24 | PASS |
| `test_serve_options` | startup option parsing/control options | 8 | PASS |
| `test_server_main` | server startup paths | 10 | PASS |
| `test_crash_trace` | startup failure diagnostics/crash trace | 18 | PASS |
| `test_launcher` | launcher startup forwarding | 37 | PASS |

Counts: 249 Python focused tests executed; 249 PASS; 0 failures/errors; 0 skipped.

## Full upstream target comparison

The full baseline target `make -j4 -k test-python` had already run in T001:

- First attempt: 1468 Python tests, 1 environmental Node-harness timeout, 8 skipped.
- Rerun: 1468 Python tests, 0 failures/errors, 8 skipped.

The focused disabled-mode suites above all passed independently.

## What this baseline proves

Clean upstream proves:

1. Ordinary startup can warm, audit, and announce exactly one ReadyEvent.
2. The Python control plane enforces one ReadyEvent per process/control generation.
3. The announced startup context is directly consumed as the frontend serving limit and catalog context.
4. Ordinary request admission, engine request handling, memory pressure, idle-weight release, status, control transport, crash startup diagnostics, relaunch/replacement, option parsing, and launcher forwarding have existing regression coverage.
5. Upstream has no opt-in Battery lifecycle behavior, so it cannot itself prove the later disabled-mode non-regression contract against a Battery feature.

## What requires post-migration comparison

The following can only be established after the 003 migration because the Battery opt-in and lifecycle state do not exist at `a8a74e6`:

1. A disabled default option creates no power observer, no initial power sample, and no Battery lifecycle transitions.
2. Battery lifecycle transitions, when enabled, do not alter ordinary startup/admission behavior for non-Battery paths.
3. Static ceiling/effective-context split preserves `/v1/models`, context-length errors, and output budgeting as intended.
4. Idle-weight release and memory-pressure behavior remains unchanged when Battery features are disabled.
5. Historical Battery lifecycle tests, when reintroduced, coexist with these upstream ordinary-mode tests without deleting or weakening any case.
