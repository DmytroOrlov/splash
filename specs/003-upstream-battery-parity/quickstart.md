# Quickstart: Validation Sequence for the 003 Migration

This is a **planned validation guide**. Nothing in it has been executed as part of this planning step, and no claim below reports a passing run. The migration's implementation step (later, authorized) is what runs these; the interrupted rebase is not touched by this step.

Conventions: `make` targets come from `Makefile`, `dev/Makefile` and `dev/native.mk`; native test binaries land in `build/engine-tests/` (`BUILD := build`, `ENGINE_TEST_BUILD := $(BUILD)/engine-tests`); Python suites are discovered from the checkout root (`dev/Makefile:138-142`). Use the project venv's Python (`$(VENV)/bin/python`, `Makefile:9`).

## 0. Prerequisites

```shell
python3 -V                                   # 3.12–3.14 (Makefile:18 PYTHON_CANDIDATES)
make install-environment                    # creates $(VENV); no model download needed
git status --short                          # expect the interrupted rebase: keep it untouched
```
Deterministic native/Python suites need no installed model. `test-real`/`test-http-real`/`test-agent-real` do, and are out of scope for the parity gates except where a gate is explicitly physical (FR-030).

## 1. Baseline evidence before migration (workstream A)

**The current working tree is not a valid baseline**: it holds unresolved rebase conflict markers in production and test files and is not buildable. Four trees are named separately throughout: **clean HEAD** `a8a74e6` (baseline only), **unresolved rebase tree** (current; has conflict markers, NOT buildable, never a test subject — a PASS against it is invalid), **partially integrated tree** (conflict markers removed file-by-file by implementation tasks; a chosen test target compiles and runs once the sources it links are integrated — this is where narrow gate tests execute), and **fully resolved tree** (full regression + integration evidence). Content-level conflict resolution in the files an implementation task owns is permitted; git-index/rebase operations (`add`/`commit`/`reset`/`checkout`/`stash`/`rebase --continue`) are not — the operator alone stages and continues. Never report PASS for a target that did not compile and exercise the code: do the smallest necessary integration first, else report NOT RUN.

```shell
BASELINE_DIR=$(mktemp -d /tmp/splash-baseline-a8a74e6.XXXXXX)   # outside the repository
git archive a8a74e6 | tar -x -C "$BASELINE_DIR"     # stdout-only; no checkout/worktree/reset/stash
# then, inside "$BASELINE_DIR" and with its own venv:
#   make check-native-cpu  && make test-engine-cpu && make test-sanitizers && make test-python
```

`git archive` writes only to stdout, so the repository's index, working tree and rebase state are untouched. No `git checkout`, `git worktree add`, `git reset` or `git stash` is used anywhere in this plan. **No baseline run is performed in this planning step**; the commands above are recorded for the implementation step.

Archive from the baseline tree: pass counts per suite, and the pinned compatibility facts that feed research D-12/D-10 — `kProtocolVersion = 11`, `kFrameHeaderBytes = 16`, `kStatusSchemaVersion = 6`, one `ReadyEvent` per generation, upstream `StartEvent { requestId, lane, matchedPromptTokens }` with no capacity field, and the `ReadyEvent.maxContextTokens` consumer set (`server/server.py:1817,1834-1841`, `server/runtime.py:1183-1187`, `server/frontend.py`).

## 2. Focused suites per gate

Run the narrowest target that proves the gate, then the full sweep. **Provenance of the target matters**: `existing` means the target is registered at HEAD; `planned` means the target depends on test files or a test-registration line that stage 3 added and that this migration must (re-)introduce, so it does not exist until implementation lands.

| Gate | Focused command | Target status | Notes |
|---|---|---|---|
| Ownership split / retained graph | `make build/engine-tests/runtime-resources && build/engine-tests/runtime-resources` | existing | retained cases + new residency-absent case |
| Persistence scheduling | `make build/engine-tests/persistent-cache && build/engine-tests/persistent-cache` ; then `build/engine-tests/engine` | existing | existing due/order/budget cases, then the owner/worker deferral cases |
| Admission, drain, handoff | `build/engine-tests/runtime-bootstrap` ; `build/engine-tests/native-engine-loop` ; `build/engine-tests/native-fd-transport` | existing targets, **planned cases** | Gates 1-4; the receipt/witness fixtures and the bootstrap test seam are new work in WS C/D; also run under TSan (§3) |
| Native main / power wiring | `make build/engine-tests/native-main && build/engine-tests/native-main` | **planned** | `dev/tests/engine/native_main_test.mm` and its registration are absent at HEAD; cold Battery/Unknown start and teardown order |
| Status truthfulness | `build/engine-tests/runtime-status dev/tests/engine/status_golden.json` | existing target, planned cases | Gate 12 — U-05 is an approved decision (in-band `StartEvent.capacityTokens`); this gate stays unpassed until that extension and its deterministic test land; any additive field moves the golden in the same change |
| Protocol compatibility | `build/engine-tests/protocol dev/tests/engine/protocol_golden.txt` | existing | the 16-byte header and existing event functionality are preserved; the approved U-05 decision forces a coordinated `PROTOCOL_VERSION` bump (D-12 rule 3) adding `StartEvent.capacityTokens` — both codecs, validators, `protocol_golden.txt`, `status_golden.json` and `native_peer.py` move in the same change |
| Native CLI chain | `make build/engine-tests/native-arguments && build/engine-tests/native-arguments dev/tests/engine/native_command_golden.txt dev/tests/fixtures/model-configs` | existing target, planned cases | `--pause-on-battery` parsing + help |
| Retained reuse / suffix-only prefill (SC-005) | `build/engine-tests/engine` (the two-Engine/one-Cache case) | existing target, planned case | asserts `restoredTokens > 0`, executed prefill == uncached suffix, counted separately |
| Python lifecycle (Gates 11) | `$(VENV)/bin/python -m unittest dev.tests.server.test_runtime dev.tests.server.test_status_contract dev.tests.server.test_native_backend -v` | existing targets, planned cases | bounded freshness; generation/revision ordering; **same-generation, same-revision out-of-order completions must not regress older state**; status reads stay passive |
| Disabled-mode parity (Gate 13) | `$(VENV)/bin/python -m unittest dev.tests.server.test_serve_options dev.tests.server.test_memory_release dev.tests.install.test_launcher dev.tests.install.test_launcher_local -v` | existing | option absent → zero Battery lifecycle/status transitions; ordinary memory-pressure/idle release unchanged |
| Source/lint gates | `make check-source` ; `$(VENV)/bin/python -m ruff check --config dev/ruff.toml server install/*.py dev/tests` ; `... ruff format --check ...` | existing | part of `make check-python` |

## 3. Concurrency and memory proofs (Gates 1-8, in workstream order)

```shell
make test-sanitizers                 # ASan/UBSan + TSan engine/control suites
make test-sanitizers-metal           # Metal TSan suites (Apple Silicon host only)
```
Requirements for these gates: every refusal/progress assertion must come from an ownership or receipt observation at the boundary (no `sleep`-based evidence, constitution X). Where research.md records an unresolved primitive (U-01 receipts, U-02 KV-tier witness), the affected gate is reported **BLOCKED** with that primitive named rather than closed by a higher-level lifecycle test; U-05 is already an approved decision, so Gate 12 is reported **NOT RUN** until its in-band `StartEvent.capacityTokens` extension and deterministic test land.

Evidence ordering: the narrow tests for Gates 1-4 belong to workstreams B/C/D and must pass there before WS E starts; Gates 5-8 belong to C/E; Gates 9-10 to B/E; Gates 11-13 to A/F. §4 below re-runs everything at suite scale; it is not where a foundational guarantee is first tested. A workstream whose prerequisite primitive is unimplemented reports BLOCKED and does not hand off.

## 4. Full regression after implementation (FR-025, SC-002)

```shell
make check            # check-source check-native-engine check-python check-app
make test             # test-engine (cpu+metal) + test-python
```
Acceptance rule: zero deleted, weakened, expected-failure or newly-skipped cases in **either** the migrated historical Battery set (≈39 cases, concentrated in `runtime_bootstrap_test.mm` / `runtime_status_test.cpp`) or the upstream-only set (≈90 registrations across `runtime_bootstrap_test.mm`, `runtime_resources_test.mm`, `native_engine_loop_test.cpp`, `runtime_status_test.cpp`). Metal-only suites are **built** on GPU-less CI and run on an Apple Silicon host — that environment allowance never counts as coverage of suites whose prerequisites are present.

## 5. Integration proof (FR-029)

One deterministic AC → Battery → AC sequence inside a single process generation: admitted work during the transition, control-plane reads while suspended, resumed serving after recovery, truthful state at each step, exactly one readiness announcement. Native side in `runtime_bootstrap_test.mm`; Python side in `dev/tests/server/` (adjacent to `test_runtime.py`). Reported separately from the SC-005 two-Engine proof.

## 6. Physical Apple Silicon evidence session (FR-030)

Operator-performed, scripted, archived. Not a CI job. Run on a battery-powered Apple Silicon macOS host after implementation.

1. **Prepare.** Note host, macOS build, model selection and the exact serve options used (with `--pause-on-battery` explicitly set). Record the command line verbatim.
2. **Start on AC.** Capture: native child PID (`ps -o pid=,ppid=,command=` for the runtime child), `/status` document, `/v1/models` ceiling, and the process's model-residency indicators.
3. **Warm a long prefix.** Issue a request whose warmed prefix is large enough to build in well over a minute; record its wall time and the `/status` cache counters (`kv_hit_tokens`, `reused_tokens`, `disk`) — this is the state whose reuse must be proven.
4. **Observe the physical power transition.** Unplug the AC adapter. Record the OS power observation with the tool used (on this project's hosts, `/usr/bin/powermetrics` — e.g. its consumer-power/battery sampler — since `pmstatus`/`smap` are not available; record the exact invocation and version). Capture timestamps before/after.
5. **Capture released-residency evidence.** Immediately after suspension completes, capture: process RSS/VSZ deltas (`ps -o pid=,rss=,vsz=,etime=`), the native `/status` sections that must report absence (`weights`, `memory_actual`, streamed stores, ANE) versus retained sections that must remain present (`kv`, `state`, `disk.write_behind`), and the deterministic residency-occupancy seam from the instrumented build. If the host provides a mapped-file report (`smap`/`pmap` from dev tools), capture the model file's mapped region too; otherwise state that the mapped-region view was unavailable and rely on the RSS delta + residency seam.
6. **Capture control responsiveness while suspended.** Read `/ready`, `/health`, `/status`, `/metrics`, `/v1/models` and confirm they answered without restoring residency (`inference_ready` false, model telemetry reporting absence). Capture a newer-intent check: while residency work is in flight, confirm status/control still answer.
7. **Re-plug to AC.** Record the power observation again; wait for recovery; then re-issue the same compatible request. Capture: unchanged native PID (`ps` again), exactly one readiness announcement observed for the generation (server logs), restored prefix tokens > 0 and executed prefill equal to the uncached suffix from the resumed request's telemetry, the per-request capacity value attributed to that request together with **the mechanism that supplied it — the approved in-band `StartEvent.capacityTokens` field — and confirmation that it follows the published Engine, never the ceiling**, and the resumed request's wall time versus step 3's build time (SC-007 supporting number; SC-005 token proof is primary).
8. **Archive.** A single evidence bundle: `evidence/` directory with `session.md` (transcript of the commands run, host/version record), `powermetrics.log`, `status.<phase>.json` for each phase, `ps.log`, `server.log`, `measurements.tsv` (timestamps, RSS, token counts, latencies), and the exact build identity (`build-id`) plus the test configuration used. Every observation in the bundle must be traceable to FR-030's required items and to SC-003/SC-006.

Pass criteria for the physical session: PID unchanged across AC → Battery → AC, one readiness announcement, objective residency-release evidence, retained-graph evidence present, restored-boundary + suffix-only reuse on the resumed request. If any item cannot be observed on the host, record it as a gap in the bundle rather than inferring it from a state label.

## 7. Reporting

Report per gate: `PASS` (with the deterministic seam and archived artifact), `BLOCKED` (with the missing primitive named — research.md U-01…U-05), or `NOT RUN`. Environment-allowance skips (Metal-only suites on GPU-less hosts) are reported separately and never folded into a PASS, and a `PASS` recorded against the conflicted working tree is invalid by definition: baseline `PASS` claims come only from the clean-commit extraction of §1.
