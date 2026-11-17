# Clean upstream baseline evidence — `a8a74e6`

## T001 — Baseline extraction and supported target results

### Extraction

Full commit: `a8a74e6b1aeafb318257a40359cdc95724eae02f`.

The repository remained in its interrupted rebase. No checkout, worktree, stash, reset, staging, branch switch, or rebase continuation was performed. The working tree was read as a source for the clean commit only.

Initial extraction:

```sh
BASELINE_DIR=$(mktemp -d /tmp/splash-baseline-a8a74e6-complete.XXXXXX)
git archive a8a74e6 | tar -x -C "$BASELINE_DIR"
```

Resolved location:

```text
/tmp/splash-baseline-a8a74e6-complete.vc83v0
```

Plain `git archive` exported 467 files because `a8a74e6:.gitattributes` declares `dev/tests`, `dev/benchmarks`, selected dev files, `.github`, `.gitignore`, and `.gitattributes` `export-ignore`. The tests required by the requested targets were therefore restored into the same external baseline from commit blobs using `git cat-file` into paths under `$BASELINE_DIR`; this was read-only relative to the repository.

Extraction result:

```text
tracked commit files: 762
baseline files after archive + export-ignored blob overlay: 762
blob mismatches: 0
mode mismatches: 0
```

The clean baseline is outside `/Users/do/git/splash`; the conflicted repository's build outputs were not used.

### Build environment

```text
OS/kernel: Darwin 25.6.0, arm64
macOS: 26.7
GNU Make: 3.81
C++ compiler: Apple clang 21.0.0 (arm64-apple-darwin25.6.0)
Metal compiler: Apple metal 32023.921 (metalfe-32023.921.6)
Python: 3.13.16
Python executable: /private/tmp/splash-baseline-a8a74e6-complete.vc83v0/.venv/bin/python
Python prefix: /private/tmp/splash-baseline-a8a74e6-complete.vc83v0/.venv
Node (used by frontend Python harnesses): v26.12.0
```

The baseline's Makefile created a fresh `.venv` inside the external baseline. No model weights were downloaded and no real-model inference target was run.

### Executed targets

All four commands were run in the extracted baseline:

```sh
cd "$BASELINE_DIR"
make -j4 -k check-native-cpu
make -j4 -k test-engine-cpu
make -j4 -k test-sanitizers
make -j4 -k test-python
```

#### Results

| Target | Result | Test count available |
|---|---:|---|
| `check-native-cpu` | PASS | 43 native CPU test binaries executed, 43 binary-level PASS; per-assertion counts are not reported by the harness |
| `test-engine-cpu` | PASS | 43 native CPU test binaries re-executed, 43 binary-level PASS |
| `test-sanitizers` | PASS | 36 sanitizer test binaries executed, 36 binary-level PASS |
| `test-python` first attempt | FAIL | 1468 Python tests discovered, 1 error, 8 skipped |
| `test-python` rerun | PASS | 1468 Python tests discovered, 0 failures/errors, 8 skipped |

`check-native-cpu` also built the production `build/splash` target and passed its platform check before CPU tests.

#### Failure diagnostic and classification

The first `make -j4 -k test-python` attempt ended:

```text
Ran 1468 tests in 591.310s
FAILED (errors=1, skipped=8)
```

Failing test:

```text
dev.tests.server.test_chat.ChatTest.test_api_key_field_shows_only_once_the_server_answers_401
```

Failure kind: environmental timeout in the Node subprocess frontend harness. The Python test timed out after 5 seconds waiting for:

```text
/opt/homebrew/bin/node -e <frontend harness> .../server/chat.html
```

It was not a native engine failure, Python assertion failure, missing prerequisite, or real-model inference failure.

Immediately after the environment and build outputs were already present, the same target was rerun:

```text
Ran 1468 tests in 577.118s
OK (skipped=8)
```

Conclusion: `test-python` is flaky on this machine under the 5-second Node harness limit; the baseline evidence records both the observed failure and the observed rerun PASS. It is not reported as an unconditional stable PASS.

---

## T002 — Wire, status, ReadyEvent, and StartEvent baseline

All facts below were read from clean `a8a74e6` blobs, not the conflicted working tree.

### Native protocol constants

`a8a74e6:runtime/engine/Protocol.hpp`

| Constant | Value | Line |
|---|---:|---:|
| `kProtocolVersion` | `11` | 21 |
| `kFrameHeaderBytes` | `16` | 24 |
| `kStatusSchemaVersion` | `6` | 25 |

Header layout comment: magic `"SPLH"`, protocol version `u16`, frame type `u16`, payload length `u64`.

### Python protocol constants

`a8a74e6:server/protocol.py`

| Constant | Value | Line |
|---|---:|---:|
| `PROTOCOL_VERSION` | `11` | 18 |
| `FRAME_HEADER_BYTES` | `16` | 21 |
| `STATUS_SCHEMA_VERSION` | `6` | 22 |

The Python header struct is `_HEADER = struct.Struct("<4sHHQ")`, matching magic, protocol version, frame type, and payload length.

### Status schema version

- Native status JSON emits `"schema_version": kStatusSchemaVersion` in `a8a74e6:runtime/engine/Status.cpp:321`.
- Python status ingestion requires `snapshot.get("schema_version") == wire.STATUS_SCHEMA_VERSION` in `a8a74e6:server/backend.py:552`.
- Python fallback/empty status documents use `wire.STATUS_SCHEMA_VERSION` in `a8a74e6:server/backend.py:617`.

### `ReadyEvent` upstream semantics

Native event fields, `a8a74e6:runtime/engine/Protocol.hpp:239`:

```cpp
struct ReadyEvent {
  uint32_t maxConcurrentRequests = 0;
  uint32_t maxContextTokens = 0;
  bool vision = false;
};
```

Encoding, `a8a74e6:runtime/engine/Protocol.cpp:576-583`, writes `maxConcurrentRequests`, `maxContextTokens`, then boolean `vision`.

Native startup behavior:

- `RuntimeBootstrap::requireWarmupAndAnnounce` performs required warmup and memory audit, then calls `nativeLoop.announceReady()` once at `a8a74e6:runtime/engine/Bootstrap.mm:250`.
- `NativeRuntime::announceReady()` refuses an unhealthy engine, refuses a second ready announcement, sends exactly one `ReadyEvent`, and sets `ready_ = true` at `a8a74e6:runtime/engine/NativeRuntime.cpp:220-231`.
- The emitted context is the startup configuration/native plan context selected during `RuntimeBootstrap::start()` and sent through the native loop.

Python handling:

- `MultiplexedRuntime` stores the live generation's ready message in `_ready_message` and the first readiness for relaunch compatibility in `_first_ready`, `a8a74e6:server/runtime.py:483` and `:486`.
- On `ReadyEvent`, `a8a74e6:server/runtime.py:1163` checks generation and terminal state.
- A second ReadyEvent for the current generation raises `ProtocolFatal("native sent more than one ReadyEvent")` at `:1168`.
- It verifies that the ReadyEvent matches the startup attempt and has not timed out at `:1170-1178`.
- It compares `max_context_tokens`, `max_concurrent_requests`, and `vision` against `_first_ready` at `:1182-1189`; a mismatch is `EngineUnhealthy` at `:1196-1199`.
- Non-error native events before ReadyEvent raise `ProtocolFatal("native event arrived before ReadyEvent")` at `:1215`.

### Existing upstream `StartEvent` fields

Native `StartEvent`, `a8a74e6:runtime/engine/Protocol.hpp:249`:

```cpp
struct StartEvent {
  uint64_t requestId = 0;
  uint32_t lane = 0;
  uint32_t matchedPromptTokens = 0;
};
```

There is no `capacityTokens` field in clean upstream.

Python `StartEvent`, `a8a74e6:server/protocol.py:327`, has:

```python
request_id: int
lane: int
matched_prompt_tokens: int
```

Native start emission, `a8a74e6:runtime/engine/NativeRuntime.cpp:481-485`, sends `protocol::StartEvent{requestId, lane, matchedTokens}`. Native validation, `Protocol.cpp:428`, requires nonzero request id and a lane below `ExecutionLimits::maximumBatchWidth`. Python validation/unpack, `server/protocol.py:1024-1030`, requires nonzero request id and stores the three fields. Python per-request start recording is at `server/runtime.py:258`, and dispatch rejects duplicate or late `StartEvent` at `:1223-1226`.

### Exactly-one-ReadyEvent-per-generation handling

Clean upstream enforces exactly one ReadyEvent on two axes:

1. Native: `ready_` prevents a second announcement from the same native runtime.
2. Python: `_ready_message is not None` raises `ProtocolFatal` for a second ReadyEvent in the current process/control generation.

Python also compares the first ReadyEvent's `max_context_tokens`, `max_concurrent_requests`, and `vision` for relaunch compatibility, preventing a relaunched engine from silently changing those static capability domains.
