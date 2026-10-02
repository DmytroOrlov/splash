# Quickstart acceptance audit — 2026-11-08

The migration HEAD is `34f17bcb378dca0c43c80d14de3493e93efc798b`. Earlier task-specific results are not represented as runs on the corrected resolved tree. Both sequential full gates passed on the stable source manifest.

| Quickstart gate | Status | Supporting evidence and limitation |
|---|---|---|
| Clean baseline | PASS | `dev/tests/evidence/baseline-a8a74e6.md`: isolated clean commit; 43 CPU binaries, 36 sanitizer binaries, Python 1468 tests and 8 skips on rerun. First Python attempt had a Node harness timeout. |
| Ownership / retained graph | PASS, prior focused evidence | `tasks.md` T007–T009, T015; task records are evidence where no separate transcript is archived. |
| Persistence and retained reuse | PASS, prior focused evidence | `tasks.md` T012–T013, T035, T046; tests assert token and write/restore properties. |
| Admission / drain / handoff | PASS, prior focused evidence | `tasks.md` T010, T016–T019, T024–T025; archived `runtime-bootstrap-host.log` and sanitizer logs in this directory are pre-rebase. |
| Native main / power | PASS, prior focused evidence | `tasks.md` T020, T023, T045. |
| Status and protocol | PASS, prior focused evidence | `tasks.md` T037, T040, T042 and named golden fixtures; physical recovered StartEvent in `../session-20261107-t048-host/start-events.jsonl`. |
| Native CLI and disabled parity | PASS, prior focused evidence | `tasks.md` T039, T041; resolved-tree comparison in `baseline-comparison-20261108.md`. |
| Python lifecycle | PASS, prior focused evidence | `tasks.md` T038 and referenced focused results; resolved-tree comparison in `baseline-comparison-20261108.md`. |
| Source architecture | PASS | `architecture-20261108.log`, exit 0 on current source. |
| Ruff check / format | PASS | `ruff-check-20261108.log` and `ruff-format-20261108.log`, both exit 0, 153 files checked by formatter. Prior errors retained in `ruff-check-prior.log` and `ruff-format-prior.log`. |
| CPU sanitizers / Metal TSan | PASS, prior focused evidence | `sanitizers.log`, `sanitizers-metal-host.log`, `results.txt`; pre-rebase, not proof of current full gate. |
| Full resolved-tree check | PASS | `check-stable-20261108.log` and `.result`: exit 0, Python 1489 tests / 8 skips, Swift 61 tests / 0 failures. |
| Full resolved-tree test | PASS | `test-stable-20261108.log` and `.result`: exit 0, Python 1489 tests / 8 skips. |
| Integration sequence | PASS, prior focused evidence | `tasks.md` T045 and archived bootstrap evidence; physical observations recorded separately below. |
| Physical AC → Battery → AC | PASS, accepted core with limitations | `../session-20261107-t048-host/session.md` and raw artifacts. Privileged powermetrics unavailable; no HTTP timing independently captured within the 52.348 ms disposal interval; no raw binary ReadyEvent count independently archived; some intermediate endpoint responses were not archived. Deterministic blocked-worker and ReadyEvent regressions establish their own contracts, not physical measurements. |
| Baseline comparison / 36 flags | BLOCKED for complete assertion-level proof | `baseline-comparison-20261108.md`, `registrations-20261108.txt`, `upstream-registration-comparison.txt`, and `coverage-audit-20261108.md`; the 36 historical assertion-level gaps remain unverified. |
