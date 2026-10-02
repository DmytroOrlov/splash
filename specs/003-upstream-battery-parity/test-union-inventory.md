# Test union inventory (T044, complete)

T044 test-name inventory reconciliation completed. The exact upstream, historical and current definition counts and current registration counts are recorded for every listed conflicted suite. All upstream C++ test definitions remain registered; the Python launcher union is complete. T043's accepted tests (211 Python tests, exit 0) establish the assertions they exercise, but do not establish preservation of every historical Battery assertion.

**Current T055 disposition (2026-11-13):** the authoritative assertion-level reconciliation is the final 36-row table in `evidence/post-rebase-20261107/coverage-audit-20261108.md`: 19 VERIFIED, 10 CHANGED CONTRACT VERIFIED, 7 REPAIRED AND VERIFIED, 0 unresolved. T055 is complete; final-source full gates remain T056. The inventory and flags below are the original T044 snapshot, retained for provenance and superseded where they describe those 36 rows as unverified.

| Flagged gaps | Owner | Evidence needed |
|---|---|---|
| `testAdmissionCloseRejectsLaterRequestWhileAdmittedRestoreDrains`, `testCancelledRestoreRetainsEngineUntilTicketDrains` | native engine loop | Admission during a draining restore; cancelled asynchronous StateRestore retains its request lane until ready. |
| Bootstrap historical names flagged individually below | runtime bootstrap / lifecycle tests | An assertion for each named observable property. |
| `testInstalledManifestBindsExecutionGeometry` | model loading / geometry | Rejection of the three historical installed-manifest corruptions. |
| `testPowerObserverStopWaitsForInflightCallback` | native-main / PowerSource tests | Resolved by `testSystemPowerStopWaitsForInflightCallback` (production observer run loop and handler). |
| `testRuntimeCacheNamespaceBindsIdentityOnce` | runtime resources / cache | Any exact historical namespace-string cases not covered by current partition tests. |
| `testWarmupLaneComparisons` | model warmup tests | Changed contract verified: the work-comparison API and its sole confirmation consumer were removed together; see Phase A audit. |
| Python runtime names flagged individually below | server runtime | Evidence for each historical request-specific or other distinction. |

The historical counts compare index stages 2 (upstream) and 3 (historical) with the files at the T044 inventory. Registered calls were read from the then-current entry point (or `run` for Qwen); they were not a new execution. Absent names are not automatically missing behavior. The extra native-engine-loop call is `testIdleWeightsAreReleasedAndRestored` with `false` and `true`, not an accidental duplicate.

### `dev/tests/engine/native_engine_loop_test.cpp`

Upstream definitions: 48; historical definitions: 22; distinct historical additions: 5; current definitions: 73; registered calls: 74 (73 distinct). Historical names preserved: 17. Upstream names absent: none.

Historical names absent (dispositions follow): testAdmissionCloseRejectsLaterRequestWhileAdmittedRestoreDrains, testCancelledRestoreRetainsEngineUntilTicketDrains, testImageRequestWithoutVisionStaysRequestScoped, testInvalidPromptTokensStayRequestScoped, testLifecycleAdmissionGateIsFinalNativeBoundary.

Dispositions are recorded below; registration alone does not prove assertions.

### `dev/tests/engine/protocol_test.cpp`

Upstream definitions: 19; historical definitions: 16; distinct historical additions: 7; current definitions: 21; registered calls: 21 (21 distinct). Historical names preserved: 11. Upstream names absent: none.

Historical names absent (dispositions follow): testBoundedArbitraryStatusJson, testEveryMessageAndMultiplexedStream, testFailureTaxonomyAndCapacityEvent, testOverflowLimitsAndOuterTruncation, testRequestWireAndRoundTrip.

Preserved by specific modern tests: `testBoundedArbitraryStatusJson` → `testBoundedArbitraryStatusJsonAndFrames`; `testEveryMessageAndMultiplexedStream` → `testGoldenVectors`, `testClientAndEventStreams`, `testTruncationAtEveryBoundary`; `testFailureTaxonomyAndCapacityEvent` → `testFailureTaxonomy`, `testClientAndEventStreams`; `testOverflowLimitsAndOuterTruncation` → `testInvalidLimitsAndOuterTruncation`; `testRequestWireAndRoundTrip` → `testRequestRoundTrip`. Also registered: `testMalformedPayloadClassification`, `testDetachedLifecycleStatusRoundTrip`, `testReadyIsOneStaticGenerationHandshake`. These follow wire version 12 and its 20-byte Start payload.

### `dev/tests/engine/qwen_state_storage_test.mm`

Upstream definitions: 10; historical definitions: 10; distinct historical additions: 6; current definitions: 16; registered calls: 16 (16 distinct). Historical names preserved: 10. Upstream names absent: none.

Historical names absent (dispositions follow): none.

Disposition: all historical names preserved by exact name.

### `dev/tests/engine/runtime_bootstrap_test.mm`

Upstream definitions: 11; historical definitions: 37; distinct historical additions: 28; current definitions: 37; registered calls: 37 (37 distinct). Historical names preserved: 9. Upstream names absent: none.

Historical names absent (dispositions follow): testAsyncRecoveryKeepsFdTransportResponsiveAndRevisionFenced, testBatteryColdStartCreatesOnlyTheControlShellBeforeAc, testBootstrapPowerIntentRevisionAndShutdownAuthority, testBootstrapSerializesLifecycleIntentWithRequestAdmission, testEveryWarmupFailureIsFailClosed, testFakePowerSourceQueuesAtSafePointAndStopsDelivery, testFinalRecoveryFenceKeepsNewBatteryIntentClosed, testInitialAcObservationOpensExistingBootstrapResidency, testInstalledManifestBindsExecutionGeometry, testInvalidRecoveryContextFailsClosedAndCanRetry, testMemoryMayNotHoldBeyondHostHeadroom, testModelLessControlShellAndEnginePublication, testNativeRuntimeAdoptionRefusalPreservesCandidate, testPowerObserverStopWaitsForInflightCallback, testPreSplitBootstrapHarnessObservesCoupledGraph, testPrivateRecoveryCandidateOwnershipAndRollback, testPumpableSuspendReleaseAndDetachedPublication, testRecoveryCandidatePublicationIsTransactionalAndExact, testRecoveryContextDriftKeepsControlGeneration, testRepeatedSameGenerationSuspendRecoveryPreservesRetainedGraph, testRuntimeCacheNamespaceBindsIdentityOnce, testShutdownSupersedesSuspendDuringDrain, testShutdownWinsAlreadySuspendedLifecycle, testShutdownWinsBlockedRecoveryCompletion, testSuspendDrainsPreCloseRequestAndRejectsPostCloseRequest, testSuspendRevisionSupersededAfterDestructiveRelease, testSuspendRevisionSupersededBeforeDestructiveRelease, testWarmupLaneComparisons.

Dispositions are recorded below; registration alone does not prove assertions.

### `dev/tests/engine/runtime_resources_test.mm`

Upstream definitions: 22; historical definitions: 5; distinct historical additions: 2; current definitions: 26; registered calls: 26 (26 distinct). Historical names preserved: 3. Upstream names absent: none.

Historical names absent (dispositions follow): testPackageResidencyReleasesAllWeightCategories, testStartupAdmissionIgnoresPackageSize.

Preserved by specific modern tests: `testPackageResidencyReleasesAllWeightCategories` → `testResidencyReleasesAllWeightCategories`; `testStartupAdmissionIgnoresPackageSize` → `testStartupAdmissionIgnoresModelSize` and `testStartChecksTheReserveWithWhatItServes`.

### `dev/tests/engine/runtime_status_test.cpp`

Upstream definitions: 15; historical definitions: 10; distinct historical additions: 5; current definitions: 23; registered calls: 23 (23 distinct). Historical names preserved: 7. Upstream names absent: none.

Historical names absent (dispositions follow): testDetachedStatusKeepsControlDiagnosticsAndMetrics, testFullStatusLifecycleAuthorityAndContextValidation, testWarmupStatesPreserveReadinessAndMeasurementTruth.

Preserved by specific modern tests: `testDetachedStatusKeepsControlDiagnosticsAndMetrics` → `testControlReadyStatusCanBeModelLess`, `testDetachedStatusKeepsRetainedMeasurements`, `testDetachedLifecycleValues`; `testFullStatusLifecycleAuthorityAndContextValidation` → `testDetachedLifecycleValues`, `testResidentLifecycleStatus`; `testWarmupStatesPreserveReadinessAndMeasurementTruth` → `testWarmupStepsReportMeasurementTruth`, `testResidentZerosAndAbsentResidencyReadApart`. Schema 6 retains the distinction between null and zero.

### `dev/tests/engine/slot_file_test.cpp`

Upstream definitions: 22; historical definitions: 2; distinct historical additions: 1; current definitions: 23; registered calls: 23 (23 distinct). Historical names preserved: 2. Upstream names absent: none.

Historical names absent (dispositions follow): none.

Disposition: all historical names preserved by exact name.

### `dev/tests/install/test_launcher.py`

Upstream 37; historical 37; distinct historical additions 9; current definitions 46; unittest-discovered definitions 46. All historical names preserved by name. Semantic replacement: none needed. Unresolved: none identified.

### `dev/tests/server/test_runtime.py`

Upstream 65; historical 45; distinct historical additions 10; current definitions 66; unittest-discovered definitions 66. Historical names preserved by name: 36. The following historical names are absent:

- `test_concurrent_submitters_share_one_failed_startup` → `test_concurrent_waiters_share_one_failed_startup` (shared failed startup; submitter-specific semantics unverified).
- `test_deadline_helper_serializes_absolute_and_remaining_clocks` → `test_wire_deadline_is_stamped_once_at_submission` (deadline stamping; exact remaining-clock assertion unverified).
- `test_expired_request_does_not_launch_or_write` → **Preserved semantically:** `test_submit_on_a_not_ready_runtime_fails_fast_and_launches_nothing` asserts an expired submission raises `TimeoutError` and the factory has no processes, hence no process wire to write.
- `test_request_and_capacity_failures_are_scoped` → `test_request_failures_are_scoped` (request failures; capacity assertion unverified).
- `test_short_request_leaves_shared_startup_running` → `test_short_wait_leaves_shared_startup_running` (short waiter leaves shared startup running; request-specific equivalence unverified).
- `test_slow_process_factory_does_not_hold_request_deadline` → `test_slow_process_factory_does_not_hold_a_waiter` (waiter deadline; request-specific equivalence unverified).
- `test_startup_expires_even_after_every_caller_has_left` → `test_startup_expires_even_after_every_waiter_has_left`.
- `test_startup_rejects_ready_missing_required_features` → **Superseded safely:** protocol v12 ReadyEvent contains concurrency, context and vision, not the obsolete feature-bits field; rejecting a valid v12 Ready for absent feature bits would reject the current contract. Required wire fields and frame validation are covered by current protocol tests.
- `test_unhealthy_fatal_and_eof_fail_all_then_restart_lazily` → `test_unhealthy_fatal_and_eof_fail_all_then_restart_on_wait_ready` (failure and restart on wait_ready).

Disposition: the seven qualified replacements above are flagged earlier-gate coverage gaps where the historical request-specific or other distinction is not proven. In particular, the last two entries do not establish that startup expiry and restart preserve every historical caller/request distinction.

## Historical Battery assertion mapping (T043 audit)

- `test_inference_readiness_controls_admission_independent_of_process_ready` → `test_battery_control_ready_http_recovers_on_ac_without_new_generation` checks live transport with admission closed; `test_native_ready_is_authoritative_and_malformed_status_fails_closed` checks critical memory pressure.
- `test_suspended_status_is_passively_refreshed_to_ac_without_status_polling` → new HTTP test queues the existing recovery worker and waits without polling `/status`; `test_timed_out_status_keeps_one_background_refresh_alive` covers worker ownership.
- `test_first_effective_context_is_adopted_by_bounded_passive_refresh` → new HTTP test checks initial refusal and later effective 72 on the same frontend.
- `test_battery_control_ready_http_recovers_on_ac_without_new_generation` → same-named new HTTP test.
- `test_same_generation_recovery_updates_context_without_new_handshake` → new HTTP test checks 72 → suspended → 64, same frontend, readiness witness and no wait-ready calls.
- `test_invalid_resolved_context_fails_closed_without_fencing_generation` → `test_effective_context_limits_and_static_metadata` checks null, zero, negative, boolean and over-ceiling frontend limits; `test_contradictory_context_status_fails_closed` checks ceiling, maximum and readiness mismatch. `test_invalid_resolved_context_fails_closed_without_fencing_generation` now covers all thirteen missing, malformed and inconsistent native observations, then accepts a newer valid status and serves in the same generation.
- `test_out_of_order_lifecycle_snapshots_follow_highest_revision` → `test_lifecycle_order_rejects_reverse_sequence_and_old_generation` checks older revision and lower sequence rejection.
- `test_child_restart_resets_revision_ordering_for_new_generation` → same ordering test accepts revision 1 after generation change and rejects a late prior-generation observation.
- `test_stale_true_is_only_a_prefilter_before_native_admission` → **Superseded safely:** `test_stale_positive_refuses_before_native_submit_and_refreshes` checks stale positive status refuses before native submission, schedules refresh, and recovers in the same generation. `test_pre_admission_native_failure_is_refused_once_without_retry` separately verifies a native refusal after the frontend admission decision is surfaced once without retry. The historical assumption that stale positive status may reach native admission is obsolete under the stronger fail-closed freshness policy.
- `test_model_less_control_ready_frontend_uses_ready_event_ceiling` → new HTTP test checks model-less control endpoints and static model ceiling; `test_model_less_status_is_ready_without_relaunch_or_second_handshake` checks process handshake behavior.
- `test_pause_on_battery_help` → `test_pause_on_battery_public_option_and_safe_probes` checks launcher option/help.

## Native dispositions and earlier-gate coverage gaps

- Preserved by specific modern tests: `testLifecycleAdmissionGateIsFinalNativeBoundary` → `testAdmissionGateIsFinalNativeBoundary` and `testStaleReadyObservationCannotBypassTheGate`; `testImageRequestWithoutVisionStaysRequestScoped` → `testImageRequestBeyondVisionStaysRequestScoped` (missing vision and exceeded patch cap); `testInvalidPromptTokensStayRequestScoped` → `testOutOfVocabularyTokensStayRequestScoped` (including invalid score tokens).
- Flagged earlier-gate coverage gap, native engine loop: `testAdmissionCloseRejectsLaterRequestWhileAdmittedRestoreDrains` — the historical admission and draining restore interaction is not established by the supplied evidence. `testCancelledRestoreRetainsEngineUntilTicketDrains` — `testHandoffRefusesIOTheRetainedGraphStillRuns` and `testDestroyEngineRefusesRetainedGraphIO` cover running writes and unsafe handoff, not cancelled asynchronous StateRestore lane ownership until `ready()`.
- Preserved by specific modern tests: `testMemoryMayNotHoldBeyondHostHeadroom` → `testStartupAdmissionIgnoresModelSize` and `testStartChecksTheReserveWithWhatItServes`.
- Flagged earlier-gate coverage gap, model loading / geometry: `testInstalledManifestBindsExecutionGeometry` — `testPrivateRecoveryResidencyAgainstRetainedGraph` and `testYarnRuntime` do not establish rejection of mismatched `draft_query_rows`, missing `draft_sliding_window`, and incorrect `q4_storage_n` in an installed manifest. Current geometry comes from the loaded model and adoption checks retained identity and KV/state geometry.
- Preserved: `testPowerObserverStopWaitsForInflightCallback` → `testSystemPowerStopWaitsForInflightCallback` (`dev/tests/engine/native_main_test.mm:31`): the production observer run loop invokes the real notification handler, the callback blocks, and `stop()` cannot return after it marks the observer stopped until the callback is released; a subsequent handler invocation cannot reach the client. Focused native-main passed outside the sandbox on 2026-11-12.
- Flagged earlier-gate coverage gap, runtime resources / cache: `testRuntimeCacheNamespaceBindsIdentityOnce` — `testRuntimeCacheIdentityReportsTheLoadedModel`, `testPersistentCacheNamespace`, and `testRetainedIdentityAcrossResidencyMove` support asserted identity, partition and retention properties. Exact old namespace-string cases remain unverified. The old test compared determinism and separation by model digest, target digest, build and KV format; it did not count setter calls. Stored `cacheIdentity_` and its retention witness support retained identity.
- Changed contract verified, model warmup tests: `testWarmupLaneComparisons` — the separate `sameWorkAs()` relation and its sole confirmation consumer were deliberately removed together; current `WarmupLaneResult` retains defaulted full equality and lane observations for the runtime oracle. The detailed historical predicates and source provenance are in the Phase A audit.

The following historical bootstrap names are flagged earlier-gate coverage gaps in `runtime_bootstrap_test.mm`: their exact historical observable properties have not been established by the evidence recorded here. These flags do not assert that production behavior is broken.

| Historical name | Observable property needing evidence |
|---|---|
| `testAsyncRecoveryKeepsFdTransportResponsiveAndRevisionFenced` | FD responsiveness during async recovery and revision fence |
| `testBatteryColdStartCreatesOnlyTheControlShellBeforeAc` | Native cold-start control shell before AC |
| `testBootstrapPowerIntentRevisionAndShutdownAuthority` | Power intent revision and shutdown authority |
| `testBootstrapSerializesLifecycleIntentWithRequestAdmission` | Lifecycle intent serialization with admission |
| `testEveryWarmupFailureIsFailClosed` | Fail-closed behavior for each warmup failure |
| `testFakePowerSourceQueuesAtSafePointAndStopsDelivery` | Safe-point queueing and stopped delivery |
| `testFinalRecoveryFenceKeepsNewBatteryIntentClosed` | Final recovery fence against newer Battery intent |
| `testInitialAcObservationOpensExistingBootstrapResidency` | Initial AC opens existing bootstrap residency |
| `testInvalidRecoveryContextFailsClosedAndCanRetry` | Native invalid recovery context and retry |
| `testModelLessControlShellAndEnginePublication` | Native model-less shell and engine publication |
| `testNativeRuntimeAdoptionRefusalPreservesCandidate` | Candidate preservation after adoption refusal |
| `testPreSplitBootstrapHarnessObservesCoupledGraph` | Historical coupled-graph observation |
| `testPrivateRecoveryCandidateOwnershipAndRollback` | Candidate ownership and rollback |
| `testPumpableSuspendReleaseAndDetachedPublication` | Pumpable release and detached publication |
| `testRecoveryCandidatePublicationIsTransactionalAndExact` | Transactional exact candidate publication |
| `testRecoveryContextDriftKeepsControlGeneration` | Context drift preserves control generation |
| `testRepeatedSameGenerationSuspendRecoveryPreservesRetainedGraph` | Repeated native recovery retains graph in one generation |
| `testShutdownSupersedesSuspendDuringDrain` | Shutdown supersedes suspend during drain |
| `testShutdownWinsAlreadySuspendedLifecycle` | Shutdown wins while already suspended |
| `testShutdownWinsBlockedRecoveryCompletion` | Shutdown wins blocked recovery completion |
| `testSuspendDrainsPreCloseRequestAndRejectsPostCloseRequest` | Pre-close drain and post-close refusal |
| `testSuspendRevisionSupersededAfterDestructiveRelease` | Revision supersession after release |
| `testSuspendRevisionSupersededBeforeDestructiveRelease` | Revision supersession before release |
