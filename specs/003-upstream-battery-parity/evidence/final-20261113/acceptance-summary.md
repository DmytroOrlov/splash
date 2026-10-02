# Final acceptance — 2026-11-13

HEAD `34f17bcb378dca0c43c80d14de3493e93efc798b`; 704 filesystem source files, before/after manifests byte-identical, manifest SHA-256 `a9fdbde0ef0540b77802e27282d447c854a74c4cfe6d8806ce31288dc4ea4d99`. Method and exclusions: `manifest-method.md` and `manifest-method.py`. This includes staged and unstaged working-tree source; evidence-only edits do not change it.

| Command | Result | UTC start → end | Evidence |
|---|---|---|---|
| `make BUILD=build/t015-corrected check` | 0; Python 1489, 0 failures/errors, 8 skips; Swift 61, 0 failures | 16:24:28 → 17:20:32 | `check-host.log`, `check-host.exit` |
| `make BUILD=build/t015-corrected test` | 0; Python 1489, 0 failures/errors, 8 skips | 17:21:15 → 18:12:13 | `test.log`, `test.exit` |
| `.venv/bin/python -m ruff check --config dev/ruff.toml server install/*.py dev/tests` | 0 | during test gate | `ruff-check.log`, `ruff-check.exit` |
| `.venv/bin/python -m ruff format --check --config dev/ruff.toml server install/*.py dev/tests` | 0; 153 files | during test gate | `ruff-format.log`, `ruff-format.exit` |

The gates ran sequentially; the source architecture check passed within `check`. Full native suites completed in both gates; 82 printed native command lines each are not a count of distinct binaries or assertions. Initial sandbox check failed exit 2 before native tests because `metallib` was inaccessible (`check.log`, `check.exit`); host retry above passed. The passing native runs include ANE fallback timeout warnings and Python fixture ResourceWarnings; see full logs. Eight skips are documented in prior `python-static-skips-20261108.txt`. No source was repaired during these gates.

T056 and T049 are accepted on the matching final source and T055's assertion-level evidence. T051 and T052 are accepted as documented in `quickstart-audit.md` and `baseline-comparison.md`. Historical focused results retain their own source provenance. Accepted physical T048 retains documented missing observations; no physical cycle was repeated. No acceptance blocker remains within those documented limitations. Ready for operator-owned final Git review.

## Recovery follow-up

The results above are historical passes on the earlier fingerprint, before the subsequent physical recovery failure; they do not validate the recovery fixes or the cleaned source. In that later physical attempt, Battery release was independently established but recovery/inference failed. The actual fixes were exception-safe essential-allocation mode during warm construction, acceptance of newer changing health and Metal telemetry at the same lifecycle order, and bounded synchronous status refresh before rejecting a stale readiness snapshot. Admission, reserves and revision fencing remain in place.

The operator subsequently performed a successful physical AC → Battery → AC recovery on the installed model: HTTP inference completed with 8,443 input tokens and 8,352 cached, TTFT 0.5 s versus 19.1 s before Battery, one running server generation and no reported restart. Battery memory release was established by previous physical diagnostics, not newly measured in that final session. No additional physical telemetry is claimed here.

On the cleaned harness, the full-server synthetic cycle passed with native PID 34340 and the same retained graph across detach and recovery. Both HTTP generations returned 200; the second had 9,552 input tokens, 9,536 cached and one completion token. The test observed one readiness announcement and the protocol rejects duplicate ReadyEvents. The dedicated integration build and configuration are documented in `dev/tests/integration/README.md`. An initial sandbox run failed because Metal was unavailable; the host run passed.

The first cleaned-source full `check` exited 2: the old `test_stale_positive_refuses_before_native_submit_and_refreshes` expected HTTP 503 even when synchronous refresh returned a fresh healthy snapshot, and observed 200. The test now forces the refresh to time out for its stale-refusal assertion; it still verifies no native submit, a queued refresh, and eventual successful recovery. The focused server suites passed 81 tests after that correction. This changes the test, not the recovery algorithm. A new source fingerprint is used for the final gates.

Final cleaned-source validation: `make BUILD=build/t015-corrected check` exit 0, followed sequentially by `make BUILD=build/t015-corrected test` exit 0. The latter ran 1,492 Python tests with eight skips; check also passed 61 Swift tests. Logs: `recovery-clean-check.log`, `recovery-clean-test.log`. Both gates used the same 707-file working-tree source manifest `recovery-clean-source.sha256`, SHA-256 `d7f97f0f66dc7ebe983560d778543a96f056bd801848a03feab21e1ca16d3326`; the before and after manifests matched byte for byte using the documented method. Final prescribed Ruff check and format and both `git diff --check` and `git diff HEAD --check` exited 0. Focused memory-governor and native-bootstrap tests exited 0; focused Python backend/server recovery suites exited 0 (81 tests). The real-model synthetic HTTP cycle exited 0. No additional physical power cycle was performed for cleanup.
