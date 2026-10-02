# Validation status — 2026-11-08

**Final acceptance, 2026-11-13:** T056, T049, T051 and T052 complete. Both sequential full gates and both Ruff gates passed on the matching before/after 704-file manifest SHA-256 `a9fdbde0ef0540b77802e27282d447c854a74c4cfe6d8806ce31288dc4ea4d99`. See `final-20261113/acceptance-summary.md`, `quickstart-audit.md` and `baseline-comparison.md`. T048 physical limitations remain explicit; earlier entries below are historical.

**Historical pre-T056 T055 status, 2026-11-13:** complete: 36 historical rows reconciled (19 VERIFIED, 10 CHANGED CONTRACT VERIFIED, 7 REPAIRED AND VERIFIED, none unresolved) in `post-rebase-20261107/coverage-audit-20261108.md`. Focused final-source native-engine-loop, host-Metal runtime-bootstrap and Python runtime tests exited 0. The pre-release AC supersession production fix and its incomplete-disposal boundary are covered by the bootstrap binary. T056 has not run; the older check/test results below are historical and do not validate the present source. T049, T051 and T052 remain open.

## Resolved-tree validation, 2026-11-08

HEAD `34f17bcb378dca0c43c80d14de3493e93efc798b`; the rebase is complete. Stable source manifest `post-rebase-20261107/source-manifest-20261108.sha256` has SHA-256 `7a474f678013f25b7fe8abd3c9a9b645800f12592a87eb1ff7d061734cd82112`; it includes tracked and unignored untracked source and excludes acceptance evidence and `tasks.md` so records can be updated without changing the fingerprint. The complete stable-tree `make BUILD=build/t015-corrected check` passed exit 0 (1489 Python tests, eight skips; 61 Swift tests, no failures), with `check-stable-20261108.log` and `.result` archived. The sequential `make BUILD=build/t015-corrected test` also passed exit 0 (1489 Python tests, eight skips); `test-stable-20261108.log` and `.result` are archived. The source manifest was recomputed after both gates and matched byte for byte. T049 remains open: SC-002 requires proof of zero weakened historical Battery assertions, while some of the 36 historical flags concern Battery lifecycle observables whose exact assertion preservation remains unverified. T051 and T052 depend on T049 and remain open. No production regression is inferred from these gaps.

The recovered earlier check failed in Swift (61 tests, 8 locale-dependent issues; no reliable shell exit code archived). A subsequent diagnostic check changed Swift tests while running and ended exit 2: 1489 Python tests, 1 error and 8 skips, before the app phase. Its `test_usage_counts_only_tokens_before_the_thinking_delimiter` encountered a fail-closed 503; the test seeds a status that may expire during HTTP client construction. The test now refreshes the fake runtime status immediately before that usage request, and the focused test passed. The Swift tests now assert the same values and message structure with Foundation localized punctuation; all 61 passed focused. Both exact Ruff commands pass, 153 files already formatted. Full diagnostic logs and focused results are in `post-rebase-20261107/`.

`post-rebase-20261107/quickstart-audit-20261108.md` records provenance and the physical limitations. `post-rebase-20261107/coverage-audit-20261108.md` lists the 36 historical verification flags; no claim of assertion-level preservation is made from names alone. Current registrations are in `post-rebase-20261107/registrations-20261108.txt`.

## Accepted T048 physical core, 2026-11-07

PASS under quickstart §6's physical pass criteria: the operator's [host session](session-20261107-t048-host/session.md) records native PID 962 with no restarts, one server Ready announcement, Battery → AC → Battery → AC (revisions 1–4), a 22,355,618,584-byte worker disposal receipt, stable retained Resources/Cache/WriteBehind identities, and recovered reuse of 27,840 cached plus 25 uncached tokens. The 27,865-token warm request took 66.703512 seconds and the recovered request 3.027476 seconds; both returned HTTP 200. The decoded recovered in-band StartEvent reports capacity 32768.

Observational limitations remain: privileged powermetrics was declined; no HTTP response was independently timestamped inside the 52.348 ms worker interval (the deterministic blocked-worker test covers that property separately); no independent raw binary ReadyEvent count was archived (the native Bootstrap regression covers it separately); and `/v1/models`, `/health`, and `/metrics` responses were not independently archived per phase. The session also records the monitor PID-filter and RSS limitations. These are not physical observations inferred from the deterministic tests.

Prior partially integrated runs, including the earlier incomplete T048 session, retain their original records in `session-20261107-t048/session.md` and task-specific evidence. They are not the resolved-tree gates above.

## Focused deterministic gate provenance

These are prior focused passes on the partially integrated tree, recorded in the named task evidence, not full resolved-tree results.

| Gate | Status | Provenance in tasks.md |
|---|---|---|
| 1 | PASS | T010, T019 |
| 2 | PASS | T016 |
| 3 | PASS | T018 |
| 4 | PASS | T017, T022, T025 |
| 5 | PASS | T032 |
| 6 | PASS | T031 |
| 7 | PASS | T033, T034 |
| 8 | PASS | T026, T036 |
| 9 | PASS | T008, T028 |
| 10 | PASS | T012, T035, T046 |
| 11 | PASS | T038; post-fix focused log `/private/tmp/splash-t050-lifecycle-final.log` |
| 12 | PASS | T037, T040, T042; recovered physical in-band event captured in `session-20261107-t048-host/start-events.jsonl` |
| 13 | PASS | T039, T041; resolved-tree comparison in `post-rebase-20261107/baseline-comparison-20261108.md` |

Task entries identify the seams and commands; where they lack a retained standalone log, provenance is the task record itself, not an independently archived run transcript.

Latest focused fixture/protocol tests: 94 tests, exit 0 (`/private/tmp/splash-t050-focused-final.log`). Both prescribed Ruff commands exit 0.

## 2026-11-12 focused PowerSource evidence

The production observer callback interleaving is now covered by `testSystemPowerStopWaitsForInflightCallback` in `dev/tests/engine/native_main_test.mm:31`. The focused native-main build and outside-sandbox execution exited 0. The native-engine-loop binary exited 0, and `python -m unittest dev.tests.server.test_runtime dev.tests.server.test_chat_completions` ran 74 tests successfully. The existing locale-dependent Swift tests passed 61 tests, but independent controlled-locale expectations remain unproved. No new full gates were run; the prior manifest and gate results do not certify this changed source. SC-002 and T049/T051/T052 remain open.
