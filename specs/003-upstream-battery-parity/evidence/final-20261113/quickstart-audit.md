# Final quickstart audit — 2026-11-13

Final source: `source-before.sha256` equals `source-after.sha256`, manifest digest `a9fdbde0ef0540b77802e27282d447c854a74c4cfe6d8806ce31288dc4ea4d99`. Historical focused evidence retains its original source provenance; the current full gates independently exercise registered cases. See the earlier [audit](../post-rebase-20261107/quickstart-audit-20261108.md) and [assertion reconciliation](../post-rebase-20261107/coverage-audit-20261108.md) for commands, individual assertions and historical run identities.

| Quickstart gate | Status | Evidence |
|---|---|---|
| Clean baseline | PASS | `dev/tests/evidence/baseline-a8a74e6.md`: clean a8a74e6 extraction; CPU and sanitizer targets, Python rerun. Initial Node timeout recorded there. |
| Ownership / retained graph | PASS | T007–T009/T015 focused task evidence; final `make ... check` and `make ... test`, `runtime-resources`, logs here. |
| Persistence / retained reuse | PASS | T012–T013/T035/T046 focused `persistent-cache`/`engine` evidence; final full logs. |
| Admission / drain / handoff | PASS | T053/T055 focused `runtime-bootstrap` and `native-engine-loop` evidence in coverage audit; final full logs. |
| Native main / power | PASS | T053 bounded observer test and `native-main` focused evidence in coverage audit; final full logs. |
| Status / protocol | PASS | T037/T040/T042 focused `runtime-status`/`protocol` and golden fixtures; final full logs. |
| CLI / disabled parity | PASS | T039/T041 focused `native-arguments` and Python disabled-mode tests; final full logs. |
| Python lifecycle | PASS | T038 and T054/T055 focused `dev.tests.server.test_runtime` evidence in coverage audit; final full logs. |
| Source architecture | PASS | `make BUILD=build/t015-corrected check`, `check-host.log`: `dev/tools/check_architecture.py`, PASS. |
| Ruff check / format | PASS | Exact prescribed commands, `ruff-check.log`, `ruff-format.log`; both exit 0. |
| CPU sanitizers / Metal TSan | PASS | Historical focused `make test-sanitizers` and `make test-sanitizers-metal`, `../post-rebase-20261107/sanitizers.log`, `sanitizers-metal-host.log`, `results.txt`. These runs are not represented as final-fingerprint sanitizer runs. |
| Full check | PASS | `make BUILD=build/t015-corrected check`, `check-host.log` and `.exit`; Python 1489/8 skips, Swift 61/0 failures. |
| Full test | PASS | `make BUILD=build/t015-corrected test`, `test.log` and `.exit`; Python 1489/8 skips. |
| Integration sequence | PASS | T045 focused bootstrap/Python evidence and final full logs; one-generation deterministic sequence. |
| Physical AC → Battery → AC | PASS (accepted core, limited observations) | Operator session `../session-20261107-t048-host/session.md`. Privileged powermetrics unavailable; no HTTP timing independently captured inside the 52.348 ms disposal interval; raw binary ReadyEvent count and some intermediate endpoint responses not archived. Deterministic witnesses establish their own contracts, not these missing physical measurements. Session was not repeated. |
| Assertion reconciliation | PASS | T055 coverage audit: 19 verified, 10 changed-contract verified, 7 repaired and verified, zero unresolved. |

The missing physical measurements above are NOT RUN as independent observations; acceptance of T048's core does not upgrade them to measured PASS. No final-source sanitizer rerun is claimed.
