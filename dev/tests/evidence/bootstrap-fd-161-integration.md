# Bootstrap / FD 1.6.1 integration evidence

Production Bootstrap executes successfully against the merged NativeRuntime/Engine/Writer lifecycle and host Metal. No Git index, history or rebase operations were performed.

## Final verification

| Command | Exit | Result |
| --- | --- | --- |
| `make BUILD=build/t015-corrected build/t015-corrected/engine-tests/runtime-bootstrap build/t015-corrected/engine-tests/native-fd-transport` | 0 | Both owning targets compiled in the preceding part of this session. Production Bootstrap and RuntimeResources are linked into Bootstrap's executable. |
| `make BUILD=build/t015-corrected build/t015-corrected/engine-tests/runtime-bootstrap` | 0 | Final rebuild; `/private/tmp/bootstrap-final-build.log`. |
| `SPLASH_T053_ONLY=1 build/t015-corrected/engine-tests/runtime-bootstrap build/t015-corrected/splash.metallib` | 0 | Host Metal, bounded to 60 seconds; 0.76 seconds. `/private/tmp/bootstrap-fd-focused.log`. T053 also executed successfully in the final full run. |
| `build/t015-corrected/engine-tests/runtime-bootstrap build/t015-corrected/splash.metallib` | 0 | Host Metal, bounded to 240 seconds; final run 7.52 seconds. `/private/tmp/bootstrap-run-2.log`. |
| `build/t015-corrected/engine-tests/native-fd-transport` | 0 | Previously executed successfully in 1.21 seconds. Not rerun during the continuation, as requested. |
| `git diff --check -- <eight touched source/build files>` | 0 | Clean. |
| `git diff --check` | 2 | 129 diagnostic lines across 20 other files; unresolved source conflicts remain. `/private/tmp/bootstrap-global-diff-check.log`. |

The first owning build stopped on NativeArguments.hpp's conflict; the next stopped on Runtime.hpp's conflict. Both were resolved at their actual compile boundaries, preserving upstream declarations and the Battery additions. Subsequent owning builds passed. No full make check/test, Governor, Ledger, W1 or sanitizer suite was run in this package.

## T053 ownership and physical evidence

Bootstrap is constructed in the async FD runner's local `owned`. The test thread receives only a borrowed pointer through `promise<RuntimeBootstrap *>`. On normal completion or exception, the runner waits for the test borrow to end, clears the transport callback and resets `owned` on that same constructing/Owner thread. Cleanup releases the gate, retires the borrow, requests shutdown and retrieves the bounded runner result; it never destroys Bootstrap. All borrowed-pointer uses precede cleanup.finish().

T053 installs no synthetic dispose, build or adopt callback. Its only hook is WorkerSeams::warmCandidateBuilt, called after production buildCandidateOnWorker() returns a complete warm candidate and before publication. It blocks only the first attempt, observes cooperative cancellation, and leaves the later AC attempt to construct and adopt normally. The existing serial ResidencyWorker and domain lease retain all ownership.

| Former FD assertion | Executed current predicate |
| --- | --- |
| Fake disposal completed | No published Engine, no RuntimeModel, modelResident false, admission closed; idle Owner returned. Graph/Cache/WriteBehind pointers unchanged. Ledger account count drops by exactly the disposed model's pool count. |
| staleDestructions == 1 | Superseded candidate leaves zero live candidate ownership, no Engine/model/publication and the same account count as physical suspension. No older pool registration remains. Warm cancellation physically destroys the candidate under Worker authority in ResidencyWorker::run; exact reaper destructor ordering is independently preserved in testReaperDisposesColdAndWarmCandidatesInOrder. |
| adoptions == 0 on Battery | No published Engine, model or open admission; inferenceReady false. |
| adoptions == 1 after fresh AC | Real Engine and RuntimeModel published, modelResident/inferenceReady/admission true, exactly two completed production warm builds, zero stranded candidate ownership, restored account count. |
| Retained identities | Exact RuntimeResources, Cache and WriteBehind pointers match startup after disposal, cancellation and recovery. |
| One ReadyEvent | Exactly one decoded ReadyEvent over the whole FD process generation. |
| Unavailable request | Exactly one inference_unavailable, zero Start, zero Done, zero Engine submissions and no published Engine at the Battery request boundary. |
| Duplicate AC | Consumed observationSequence advances, revision remains equal to the blocked revision, and production build count stays one. |
| Status during blocked work | FD status responds while holder is Worker; recovering, inference false, Engine/model absent and admission closed. No live Ledger traversal outside idle Owner capture. |

Failure diagnostics include state, power, revision, observationSequence, controlReady, inferenceReady, modelResident, configuredContextCeiling, effectiveContextTokens, publishedEngine, admissionOpen and holder, plus drain/IO/callback witnesses. The JSON schema and validator are unchanged.

## Assertion preservation and current-contract replacements

All sixteen upstream Bootstrap test bodies and their registrations remain. Battery completion-channel, lifecycle, physical disposal, worker slot, reaper, cold/warm construction, cancellation, context, rollback, mailbox and request-drain tests remain registered. The historical forwarding warmup harness was adapted to the current pure requireWarmup API; executable production fixtures own Ready announcements.

| Historical predicate/API | Current replacement |
| --- | --- |
| Fixed prefill plus B1/B2/B3/B4/restore warmup order | testAllNativeWarmupsPrecedeReady checks the maximum prefill, every supplied row class, all decode widths and restore in order. testPrefillRowClassesAreRequired and testWarmupHoldsTheRunway preserve required-row/runway assertions. |
| Budget-limited warmup retains runtime concurrency | testBudgetLimitedWarmupTriesOnlyWidthsThatFit asserts exact attempted widths, every Complete/MemoryLimited report entry and completed progress. testReadyEventForTheServedModel preserves the four-lane Ready contract. The pure warmup no longer mutates an Engine. |
| Exceptions and invalid audits expose no Ready | Existing upstream stage/pool/error checks remain; actual Ready counts and pre-final-fence admission checks are exercised by cold/warm Bootstrap fixtures. |
| Failed Ready write: AnnounceReady error and empty output | testColdShellStartServesControlOnlyOnInjectedPower now also injects failure at the production model-less Ready sink: exactly one attempted Ready write, empty visible output, RuntimeBootstrapError at current Ready stage with the announcement failure message, and no shell returned. |
| No observer yet means RecoveryFailed | Ordinary start now authorizes AC: require Ready, AC, resident model, inferenceReady and validLifecycleStatus; observationSequence remains zero until an observation is consumed. |
| Initial AC/Battery/AC revision == 3 | Startup AC is already authorized. Pump test requires duplicate initial AC to leave revision zero, then Battery/AC to reach two. Request-drain test requires its captured baseline plus exactly two power changes, retaining all identity/readiness/order assertions. |
| Production recovery fails because T029-T033 is unbuilt | Production warm/private-candidate tests deliberately inject staging-window power changes and assert intact rollback, queued candidate, authority Owner, no publication/effective context/extra Ready; later valid AC physically adopts and completes a request. Production cold candidate test uses the real final-fence Battery refusal. testRealColdAndWarmAdoption executes successful cold and repeated warm adoption. |
| Construction-seam candidate fails adoption | Retained as an explicit current construction-seam refusal, not evidence that production adoption is absent. Checks name construction-seam candidate, bounded ownership/reap queues, returned authority and closed admission. Empty-build regression explicitly returns no candidate and checks that refusal. |
| Blocked fake disposal implies absent model in status | testControlResponsiveWhileWorkerBlocksAndShutdownJoinsIt first physically disposes, then blocks a real private warm candidate using the same narrow gate. Absent Engine/model, stable passive status, cancellation, shutdown receipt accounting and returned Owner authority are all asserted. |
| governor.setServing(false) witnesses essential-mode retirement | RuntimeResourcesTestAccess verifies startup Floor scope absent after failed construction and after adoption; no Engine/admission/residency after refusal. |
| allocationAdmission/growthAdmission without claim scopes | Each of Optional and Growth opens its own Ledger claim and Scope, invokes the unified allocationAdmission, and must be refused specifically with HostPressure. |
| Retired-model callback probe | Read-only Ledger::available traverses after model destruction, preserving retained cache contents. The earlier newly-added free() probe reclaimed cache and caused the retained-state assertion to fail; it was corrected without relaxing that assertion. |

Native FD fixtures use the unified constructor with retained WriteBehind and Model, serving weights under config.engine.weights, current Ready argument and status callback. All upstream transport/status/shutdown assertions and both Battery additions are retained. The queued-input pending-power regression still checks one unavailable, zero Start/Done and zero submissions before the control pass consumes the observation.

## Source proof and executed lifecycle coverage

- Bootstrap::detachDisposalAtSafePoint moves Engine, RuntimeModel and residency into the production worker payload. physicalDisposal destroys Engine, then RuntimeModel, then residency on the worker, and returns measured backend allocation evidence.
- Engine registers model pools/buffer callback through generation-owned MemoryLedger::ModelRegistration. Engine's destructor retires that registration before the model can die. The real cold/warm test checks disposed account removal, read-only traversal with no model alive, exactly one account matching each recovered model pool's name/current/floor/cap, and no account accumulation across generations.
- testRealColdAndWarmAdoption completes requests before suspension and after both warm recoveries. It preserves retained graph/backend/governor/authority/Cache/WriteBehind and cached KV/composite-state measurements. It verifies staging identities, final-fence admission, one ReadyEvent, physical-disposal receipts and the evidence phases before_detach, worker_disposal_start/end, after_disposal and after_recovery.
- Bootstrap teardown retires the NativeRuntime Writer before resource shutdown; Engine's Writer retirement waits for completion/reaper work and polls the authenticated receipt; Engine destruction rejects outstanding Writer/callback obligations. These existing production mechanisms were not redesigned or rerun in isolation.
- Negative paths executed in the full runner include completion before slot clearance; Battery during construction/staging; stale-candidate reaping; shutdown around blocked worker/reaper work; independent retained-IO witness refusal; cold cancelled-candidate authority return; duplicate AC ordering; exact effective context and configured ceiling; failed beginServing rollback; over-ceiling refusal; mailbox invalidation; admitted-request drainage.

No product lifecycle defect remained after physically consistent fixture corrections. The only new production code is the inactive-by-default warm-candidate test gate. Status, ResourceDomainLease, MemoryLedger, Engine/Writer, NativeRuntime and protocol were not changed during the continuation.

## Exact normal registrations

Bootstrap executes 49 named tests once, plus the two distinct slot/reap exec-isolated cleanup probes. The focused and opt-in selector branches return before the normal runner. One main and one shared exception boundary remain.

```text
testBlockedGateFailureCleanup(argv[0], "slot")
testBlockedGateFailureCleanup(argv[0], "reap")
testRuntimeCacheIdentityReportsTheLoadedModel()
testAllNativeWarmupsPrecedeReady()
testWarmupHoldsTheRunway()
testPrefillRowClassesAreRequired()
testBudgetLimitedWarmupTriesOnlyWidthsThatFit()
testOptionalAllocationFailuresAreMemoryLimited()
testResourceFailureClassificationSurvivesBootstrap()
testRequiredWarmupPreservesAllocationFailure()
testFinalHostPressurePreventsReady()
testWarmupErrorsCannotMasqueradeAsMemoryLimits()
testExceptionsAndMemoryAreFailClosed()
testReadyEventForTheServedModel()
testStartFailuresAreClassed()
testAStartCommandOutOfMemoryIsCommandMemoryAndNotRetried()
testStartupRetryWindowOpensAtFirstFailure()
testProtocolLimitsFollowTheModel()
testCompletionEnvelopeIsMoveOnly()
testCompletionChannelPublishOnceClaimOnce()
testFdRecoveryRevisionFence()
testLifecyclePumpSuspendAndRecoverOnRealGraph()
testDuplicateACObservationAdvancesStatusOrder()
testResidencyWorkerIsSingleAndSerial()
testStaleAndFailedCandidateIsRetainedNotPublished()
testPhysicalSuspensionDetachesStratumOnWorkerThread()
testColdStaticCapabilitiesAndExplicitContext()
testColdConstrainedPlanAndRelaunch()
testColdShellStartServesControlOnlyOnInjectedPower()
testControlResponsiveWhileWorkerBlocksAndShutdownJoinsIt()
testCompletionWakeBeforeSlotClearDefersTheNextOperation()
testShutdownClosesReadyAdmissionImmediately()
testShutdownSupersedesSuspendedAndRecovering()
testColdCandidateOwnAuthorityOnItsOwnLease()
testStaleCandidateIsReapedByTheOneReaper()
testReaperDisposesColdAndWarmCandidatesInOrder()
testShutdownClaimsPublishedWarmCandidate()
testShutdownAroundTheReaper()
testProductionWarmCandidateIsBuiltAgainstTheRetainedGraph()
testEffectiveContextIsThePublishedEngineWindow()
testProductionColdCandidateAssemblesItsOwnGraph()
testWarmPreparationExceptionRestoresCandidate()
testNewerACAfterCommittedRelease()
testNewerACDoesNotAcceptIncompleteRelease()
testColdBeginServingFailureRollsBack()
testColdFinalFenceInterleavings()
testMailboxInvalidatesColdStaging()
testCancelledColdAuthorityReturnsOnShutdown()
testDisabledPolicyRealStartup()
testAdmittedRequestDrainsAcrossBattery()
testRealColdAndWarmAdoption()
```

Native FD executes these 18 tests exactly once:

```text
testTransportNeedsRoomForInput()
testCleanEofAndProtocolFailure()
testShutdownRequestAndControlContinuation()
testPendingBatteryRefusesInputBeforeControl()
testControlWaitsForTheCommandInFlight()
testLoopRecordsItsLongestTick()
testLoopWakesForAnEngineDeadline()
testTheLoopAnswersWhileTheWeightsAreWritten()
testReaderReadsWhileTheLoopIsBusy()
testQueueBoundStopsTheWriter()
testShutdownAndTheTransportsEndStopTheReader()
testTheInputsEndBeforeRunIsAShutdown()
testInputEndsAfterItsBytes()
testShutdownInterruptsABlockedOutputWrite()
testNoOutputWriteStartsAfterAShutdown()
testFailedOutputEndsTheLoop()
testDetachedStratumWakesForADueRestorePoint()
testFlushEndsOrStopsAtItsDeadline()
```

The T053, cold-context, cold-cancellation, installed-model and blocked-gate opt-in selectors remain. Ordinary CI uses the existing synthetic checkpoint fixture with real production Metal; ANE calibration is disabled, the vocabulary/mask/stop tokens are coherent, and the production metallib is a build prerequisite.

## Remaining whole-rebase blockers

The index deliberately remains unmerged, including source-resolved entries. This package does not stage or continue it. The global diff check still reports untouched conflicts in app Server/ServerView/Transcript and tests; engine_cache/native_arguments/persistent_cache/qwen_state_storage/runtime_resources/runtime_status/slot_file tests; runtime/main.mm; server backend/frontend/metrics/runtime/server and associated server tests/fixtures. Other owning targets must be resolved and verified separately. No whole-rebase completion claim is made.
