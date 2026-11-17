#include "ProtocolPeer.hpp"
#include "TestChecks.hpp"
#include "TestImmediateTicket.hpp"
#include "TestKvPool.hpp"
#include "Supervision.hpp"
#include "engine/Bootstrap.hpp"
#include "metal/MetalBackend.hpp"
#include "model/ModelDescriptor.hpp"
#include "TestModel.hpp"

#include "TestStatus.hpp"
#include "TestCheckpoint.hpp"
#include "TestCache.hpp"
#include "TestDrafts.hpp"
#include "TestExecutor.hpp"
#include "TestEngine.hpp"
#include "TestFiles.hpp"
#include "TestStderr.hpp"
#include "engine/Cache.hpp"
#include "engine/FdTransport.hpp"
#include "engine/RecoveryCandidate.hpp"
#include "engine/RuntimeResources.hpp"
#include "model/ModelSizing.hpp"
#include "model/RuntimeArenas.hpp"
#include "model/SsdReaders.hpp"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <csignal>
#include <exception>
#include <spawn.h>
#include <sys/wait.h>
#include <condition_variable>
#include <cstdlib>
#include <cstdio>
#include <functional>
#include <future>
#include <poll.h>
#include <unistd.h>
#include <iostream>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

extern char **environ;

// [T020/T021/T022] The lifecycle-owner pump, the move-only completion envelope and
// its single serial residency worker. T015-T019 proved the primitives (the
// exclusive lease, the four witnesses, WorkerHandoff claim/park); this suite proves
// the ASYNCHRONOUS mechanism over a REAL graph: the pump drives Ready -> Draining
// -> Suspended -> Recovering -> Ready on the owner/safe-point thread, the expensive
// disposal and construction happen ONLY on the worker thread off that safe point,
// exactly one operation is ever in flight, and a stale or failed candidate is retained
// rather than published. The pump's authority is the actual RuntimeResources graph's
// own lease (start() assembled it), never a fixture lease over unrelated surfaces.

namespace splash::engine {

struct RuntimeResourcesTestAccess {
  static bool hasStartupScope(const RuntimeResources &resources) { return bool(resources.startScope_); }
  static void failBeginServing(RuntimeResources &resources, std::function<void()> hook) {
    resources.beginServingTest_ = std::move(hook);
  }
};

// The production class under test, exercised through the pump's private seams
// and fields. The lifecycle pump has no public seam to install a worker's task,
// so this is the test-only handle into RuntimeBootstrap's private lifecycle state.
class RuntimeBootstrapTestAccess final {
 public:
  static void installWorkerSeams(
      RuntimeBootstrap &bootstrap,
      std::function<DisposalReceipt(const WorkerCancellation &)> dispose,
      std::function<std::unique_ptr<RecoveryCandidate>(
          const WorkerCancellation &)> build,
      std::function<bool(const RecoveryCandidate &)> adopt) {
    bootstrap.workerSeams_.dispose = std::move(dispose);
    bootstrap.workerSeams_.build = std::move(build);
    bootstrap.workerSeams_.adopt = std::move(adopt);
  }

  static void gateProductionWarmCandidate(RuntimeBootstrap &bootstrap,
      std::function<void(const RecoveryCandidate &, const WorkerCancellation &)> gate) {
    bootstrap.workerSeams_.warmCandidateBuilt = std::move(gate);
  }
  static size_t liveCandidates(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    size_t count = 0;
    auto live = [](const CompletionEnvelope &envelope) {
      return envelope.candidate && envelope.candidate->ownsResidency();
    };
    for (const auto &envelope : bootstrap.pendingEnvelopes_) count += live(envelope);
    for (const auto &envelope : bootstrap.pendingReaps_) count += live(envelope);
    if (bootstrap.pendingReap_) count += live(*bootstrap.pendingReap_);
    return count;
  }

  // Steps the state machine one safe point (what controlPass drives).
  static void advanceLifecycle(RuntimeBootstrap &bootstrap) {
    bootstrap.advanceLifecycle();
  }

  static bool workerRunning(const RuntimeBootstrap &bootstrap) {
    return bootstrap.residencyWorker_.running();
  }
  // [T025] The mailbox's own control notifier — what a publish, and the worker
  // thread's terminal slot-clearing bookkeeping, wake. Production sets it once
  // from config.lifecycleWake; installing it here lets a test stand, with
  // deterministic condition-variable synchronization, INSIDE the worker's own
  // frame: after its completion is stored and its wake callback is running,
  // before running_ clears.
  static void setChannelWake(RuntimeBootstrap &bootstrap,
                             std::function<void()> wake) {
    bootstrap.lifecycleMailbox_.setWake(std::move(wake));
  }
  static bool channelHeld(const RuntimeBootstrap &bootstrap) {
    return bootstrap.lifecycleMailbox_.held();
  }
  static bool pumpOperationStarted(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.workerStarted_;
  }
  static uint64_t revision(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.lifecycleRevision_;
  }
  static uint64_t observationSequence(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.observationSequence_;
  }
  static LifecycleState state(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.state_;
  }
  static bool pumpModelResident(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.pumpModelResident_;
  }
  static bool shutdown(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.shutdownRequested_;
  }
  static uint64_t pendingEnvelopes(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.pendingEnvelopes_.size();
  }
  // [T032] The bounded pending-reap queue and the one envelope the reaper's
  // delegated operation currently owns.
  static uint64_t pendingReaps(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.pendingReaps_.size();
  }
  static bool reapInFlight(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.pendingReap_ != nullptr;
  }
  // [T031 prerequisite] Production construction now EXISTS, so a fixture that
  // wants the pump's EMPTY-completion branch names that completion explicitly
  // instead of relying on a missing seam.
  static void installEmptyBuildSeam(RuntimeBootstrap &bootstrap) {
    bootstrap.workerSeams_.build = [](const WorkerCancellation &) {
      return std::unique_ptr<RecoveryCandidate>();
    };
  }
  // [T033] The staging-boundary seam: a hook the pump runs AFTER real phase-1
  // staging and BEFORE the final fence, on the pump's Owner thread outside
  // lifecycleMutex_. An observation recorded here is an intent that landed
  // before publication; a throw here is a fence failure. Both roll the staged
  // transaction back with the candidate intact.
  static void installColdCancellationHooks(RuntimeBootstrap &bootstrap,
                                           std::function<void()> handoff,
                                           std::function<void()> reap) {
    bootstrap.workerSeams_.coldHandoffComplete = std::move(handoff);
    bootstrap.workerSeams_.coldReapClaimed = std::move(reap);
  }
  static void installStagingBoundary(RuntimeBootstrap &bootstrap,
                                     std::function<void()> hook) {
    bootstrap.stagingBoundaryTest_ = std::move(hook);
  }
  // [T033] The raw power-observation generation: every observePower() call
  // advances it, and the fence refuses an adoption across any move of it.
  static uint64_t powerGeneration(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.powerObservationGeneration_;
  }
  // [T031] Whether this Bootstrap's memory control has been bound: absent for
  // a model-less shell until its cold graph is adopted, live afterwards.
  static bool hasMemoryControl(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    return bootstrap.memoryControl_.has_value();
  }
  // [T031 prerequisite] What a retained completion's candidate IS, read out of
  // the payload the pump holds: its graph relationship, the parts the production
  // builder assembled, and the window its private Engine was built with. The
  // pump's state says none of that.
  static const RecoveryCandidate *lastCandidate(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    const RecoveryCandidate *found = nullptr;
    for (const CompletionEnvelope &envelope : bootstrap.pendingEnvelopes_)
      if (envelope.candidate)
        found = envelope.candidate.get();
    for (const CompletionEnvelope &envelope : bootstrap.pendingReaps_)
      if (envelope.candidate)
        found = envelope.candidate.get();
    return found;
  }
  // [T029] A fixture's controlled candidate witnesses: the four categories the
  // candidate's OWN lease consults at its handoff and at its reap. Installed
  // through the same seam struct the build/dispose/adopt callbacks use, so
  // each refusal can be exercised on its own while the lease still refuses
  // to mint anything unless all four pass.
  static void installCandidateWitnesses(
      RuntimeBootstrap &bootstrap,
      std::function<void(ResourceDomainLease &, RecoveryCandidate &)> bind) {
    bootstrap.workerSeams_.candidateWitnesses = std::move(bind);
  }
  // The most recent landed disposal receipt, read out of the retained envelope.
  static std::string lastDisposalDetail(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    std::string detail;
    for (const CompletionEnvelope &envelope : bootstrap.pendingEnvelopes_)
      if (envelope.disposal)
        detail = envelope.disposal->detail;
    return detail;
  }
  static std::optional<uint64_t> lastDisposalBytesAfter(
      const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.lifecycleMutex_);
    std::optional<uint64_t> after;
    for (const CompletionEnvelope &envelope : bootstrap.pendingEnvelopes_)
      if (envelope.disposal)
        after = envelope.disposal->backendAllocatedBytesAfter;
    return after;
  }
  // The owner's pump view of the graph's authority holder, read from the real
  // lease the graph owns.
  static ResourceDomainAuthority::Holder holder(
      const RuntimeBootstrap &bootstrap) {
    return const_cast<RuntimeResources &>(*bootstrap.resources_)
        .resourceAuthority()
        .holder();
  }
};

}  // namespace splash::engine

namespace {

using namespace splash;
using namespace splash::engine;

using splash::test::rejects;
using splash::test::require;

// ---- Upstream warmup/report characterization (HEAD side) ----

// The identity reports the loaded model's digests in lowercase hex and the
// KV layout as loaded; a malformed digest or a missing build id fails before
// anything is served.
void testRuntimeCacheIdentityReportsTheLoadedModel() {
  constexpr kv::Layout int8Layout{16, 4, 256};
  constexpr kv::Layout bf16Layout{16, 4, 256, kv::Format::BFloat16};
  const std::string combined(64, 'A');
  const std::string target(64, 'c');
  const engine::RuntimeCacheIdentity int8 =
      engine::makeRuntimeCacheIdentity(combined, target, "build", int8Layout, {});
  require(int8.modelLayoutSha256 == std::string(64, 'a') &&
              int8.targetModelSha256 == target && int8.buildId == "build" &&
              int8.kvLayout == int8Layout,
          "the cache identity did not report the loaded model");
  const engine::RuntimeCacheIdentity bf16 =
      engine::makeRuntimeCacheIdentity(combined, target, "build", bf16Layout, {});
  require(bf16.kvLayout == bf16Layout && bf16.kvLayout.format != int8.kvLayout.format,
          "the cache identity did not report the KV format");
  const auto identity = [&](std::string_view combinedDigest, std::string_view targetDigest,
                            std::string_view build) {
    static_cast<void>(
        engine::makeRuntimeCacheIdentity(combinedDigest, targetDigest, build, int8Layout, {}));
  };
  rejects([&] { identity(std::string(63, 'a'), target, "build"); },
          "manifest SHA-256 must contain exactly 64 hex characters",
          "a digest of 63 characters was accepted");
  rejects([&] { identity(combined, std::string(63, 'c') + 'g', "build"); },
          "manifest SHA-256 is not hexadecimal",
          "a digest that is not hexadecimal was accepted");
  rejects([&] { identity(combined, target, ""); }, "runtime build id is required",
          "an empty build id was accepted");
}

DeviceCapabilities device() {
  DeviceCapabilities result;
  result.deviceName = "bootstrap-test";
  result.appleGpuFamily = 9;
  result.macosMajor = 26;
  result.macosMinor = 4;
  result.physicalMemoryBytes = 32 * kGiB;
  result.recommendedMaxWorkingSetBytes = 24 * kGiB;
  result.maxBufferLengthBytes = 16 * kGiB;
  result.maxThreadgroupMemoryBytes = 32 * 1024;
  result.maxThreadgroupWidth = 1024;
  result.hasUnifiedMemory = true;
  return result;
}

EngineMemoryPlan memoryPlan() {
  return test::requireMemoryPlan(
      device(), test::modelMemoryProfile(2 * kGiB, 1 * kGiB, 1 * kGiB));
}

ActualMemoryReport validActual(const EngineMemoryPlan &plan) {
  const auto &budget = plan.breakdown();
  ActualMemoryReport actual;
  actual.targetWeightsBytes = budget.targetWeightsBytes;
  actual.draftWeightsBytes = budget.draftWeightsBytes;
  actual.visionWeightsBytes = budget.visionWeightsBytes;
  actual.stateAllocatedBytes = budget.laneStateBytes;
  actual.sharedPrefillBytes = budget.sharedPrefillBytes;
  actual.sharedDecodeBytes = budget.sharedDecodeBytes;
  actual.kvAllocatedBytes = budget.kvExtentBytes;
  actual.backendAllocatedBytes =
      actual.targetWeightsBytes + actual.draftWeightsBytes +
      actual.visionWeightsBytes +
      actual.stateAllocatedBytes + actual.sharedPrefillBytes +
      actual.sharedDecodeBytes + actual.kvAllocatedBytes;
  actual.deviceCurrentAllocatedBytes = actual.backendAllocatedBytes;
  actual.devicePeakAllocatedBytes = actual.backendAllocatedBytes;
  actual.backendPeakAllocatedBytes = actual.backendAllocatedBytes;
  return actual;
}

class Executor final : public model::RuntimeModel {
 public:
  explicit Executor(int throwingStep = -1, std::atomic<int> *destructions = nullptr)
      : destructions_(destructions), throwingStep_(throwingStep) {}
  ~Executor() override { if (destructions_) ++*destructions_; }

  StateAdmission begin(const ModelRequest &) override {
    return {0, StateFailure::None};
  }
  void suspend(uint64_t) override {}
  StateAdmission resume(const ModelRequest &) override {
    return {0, StateFailure::None};
  }
  std::unique_ptr<StateRestore> beginRestore(uint64_t, uint32_t,
                                             std::shared_ptr<const CompositeState>, bool,
                                             std::function<void()>) override {
    return {};
  }
  void setDraftContextPlan(uint64_t, DraftContextPlan) override {}
  std::vector<ModelStepResult> prefill(const BatchPlan &,
                                          std::span<const ModelBatchItem>) {
    return {};
  }
  std::vector<ModelStepResult> decode(const BatchPlan &,
                                         std::span<const ModelBatchItem>) {
    return {};
  }
  std::unique_ptr<ModelBatchTicket>
  submit(const BatchPlan &plan, std::span<const ModelBatchItem> items,
         std::function<void()> completion) override {
    return test::immediateTicket(plan.kind == WorkKind::Prefill
                                     ? prefill(plan, items)
                                     : decode(plan, items),
                                 completion);
  }
  std::shared_ptr<StateReservation> reserveState(uint64_t, uint32_t,
                                                 metal::AllocationFailure &refusal) override {
    refusal = metal::AllocationFailure::EngineBudget;
    return {};
  }
  std::shared_ptr<const CompositeState> snapshot(uint64_t) override { return {}; }
  uint64_t releaseIdleBuffer(bool) noexcept override { return 0; }
  std::optional<std::string> provideMask(uint64_t,
                                          std::span<const uint32_t>) override {
    return std::nullopt;
  }
  void end(uint64_t) override {}

  model::WarmupStepResult warmupPrefill(uint32_t rows) override {
    if (!rows || rows > model::ExecutionLimits::prefillTokenBudget)
      throw std::invalid_argument("invalid prefill warmup rows");
    prefillRows.push_back(rows);
    return warmup(0);
  }
  model::WarmupStepResult warmupDecodeBatch(uint32_t width) override {
    if (width < 1 || width > model::ExecutionLimits::maximumBatchWidth) {
      throw std::invalid_argument("invalid decode width");
    }
    return warmup(static_cast<int>(width));
  }
  model::WarmupStepResult warmupCompositeStateRestore() override {
    return warmup(5);
  }
  model::ModelMemoryActual actualRuntimeMemory() const override {
    return {1, 1};
  }
  model::ModelTelemetry telemetry() const noexcept override { return {}; }

  std::vector<int> calls;
  std::vector<uint32_t> prefillRows;
  std::function<void(int, model::WarmupStepResult &)> warmupHook;

 private:
  model::WarmupStepResult warmup(int step) {
    calls.push_back(step);
    if (step == throwingStep_)
      throw std::runtime_error("injected warmup exception");
    model::WarmupStepResult result{"measured", 0.001, {}};
    if (warmupHook)
      warmupHook(step, result);
    return result;
  }

  std::atomic<int> *destructions_;
  int throwingStep_ = -1;
};

class Harness final {
public:
  explicit Harness(int throwingStep = -1)
      : backing_(model::ExecutionLimits::warmupKvPages, 4096, 4),
        pool_(backing_, model::ExecutionLimits::warmupKvPages),
        executor_(throwingStep) {}

  Executor &executor() noexcept { return executor_; }
  KvPool &pool() noexcept { return pool_; }

  // Takes the Warming events of its warmup into `progress`, in order.
  WarmupProgress recorder() {
    return [this](const protocol::WarmingEvent &event) { progress.push_back(event); };
  }
  std::vector<protocol::WarmingEvent> progress;

private:
  test::TestKvStorage backing_;
  KvPool pool_;
  Executor executor_;
};

RuntimeBootstrapReport warmup(Harness &harness, const EngineMemoryPlan &plan,
                              std::span<const uint32_t> prefillRowClasses = {}) {
  return ServingRuntime::requireWarmup(plan, prefillRowClasses, harness.executor(), harness.pool(),
                                       harness.recorder(), [&] { return validActual(plan); });
}

// The Warming events of a warmup of `steps` that ended `done` of them: one as
// it began, and one as each step ended.
std::vector<protocol::WarmingEvent> counted(uint32_t done, uint32_t steps) {
  std::vector<protocol::WarmingEvent> events;
  for (uint32_t step = 0; step <= done; ++step)
    events.push_back({step, steps});
  return events;
}

void requireReady(const RuntimeBootstrapReport &report) {
  require(report.stage == RuntimeBootstrapStage::Ready && report.memoryAudit.valid,
          "memory-limited warmup did not become ready");
}

void testAllNativeWarmupsPrecedeReady() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness harness;
  constexpr uint32_t rowClasses[] = {1, 9, 17, 33};
  auto report = warmup(harness, plan, rowClasses);
  require(report.stage == RuntimeBootstrapStage::Ready && report.memoryAudit.valid,
          "successful native bootstrap was incomplete");
  require(harness.executor().calls == std::vector<int>({0, 0, 0, 0, 0, 1, 2, 3, 4, 5}),
          "bootstrap did not warm its prefills and B1/B2/B3/B4 in order");
  require(harness.executor().prefillRows ==
              std::vector<uint32_t>({model::ExecutionLimits::prefillTokenBudget, 1, 9, 17, 33}),
          "bootstrap did not warm a prefill of maximum rows and one of each row class");
  require(report.warmup.prefillRowClasses == WarmupStepStatus::Complete &&
              report.warmup.decodeBatches[2] == WarmupStepStatus::Complete,
          "bootstrap report omitted the row classes' prefills or the real B3 graph");
  // The prefill of the most rows, four row classes, four widths and the
  // restore.
  require(harness.progress == counted(10, 10),
          "bootstrap did not count each warmup step done as it ended");
}

// A row class's prefill is required, as the prefill of the most rows is: it
// needs no memory that one did not, so any failure of it, a refused
// allocation too, fails the start at its stage with the runway released.
void testPrefillRowClassesAreRequired() {
  const EngineMemoryPlan plan = memoryPlan();
  constexpr uint32_t rowClasses[] = {1, 9, 17};
  const std::function<void()> failures[] = {
      [] { throw metal::MetalAllocationError("injected allocation denial"); },
      [] { throw metal::MetalBackendError("injected GPU command failure"); }};
  for (const std::function<void()> &failure : failures) {
    Harness harness;
    harness.executor().warmupHook = [&harness, &failure](int step, model::WarmupStepResult &) {
      if (step == 0 && harness.executor().prefillRows.back() == 9)
        failure();
    };
    try {
      static_cast<void>(warmup(harness, plan, rowClasses));
      throw std::runtime_error("a row class's failed prefill passed");
    } catch (const RuntimeBootstrapError &error) {
      require(error.report().stage == RuntimeBootstrapStage::PrefillRowClasses &&
                  harness.executor().prefillRows ==
                      std::vector<uint32_t>({model::ExecutionLimits::prefillTokenBudget, 1, 9}) &&
                  harness.pool().snapshot().pagesActive == 0,
              "a row class's failed prefill did not fail the start at its stage, or kept the runway held");
      require(harness.progress == counted(2, 9), "a failed warmup step was counted done");
    }
  }
}


// Warmup runs on the KV runway and holds its pages as a request holds its
// own (KvPool::RunwayHold); none is held once the engine is Ready.
void testWarmupHoldsTheRunway() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness harness;
  int warmups = 0;
  harness.executor().warmupHook = [&](int, model::WarmupStepResult &) {
    ++warmups;
    for (uint32_t page = 0; page < model::ExecutionLimits::warmupKvPages; ++page)
      require(harness.pool().pageActive(page), "a warmup ran on a runway page no request held");
  };
  const auto report = warmup(harness, plan);
  require(report.stage == RuntimeBootstrapStage::Ready && warmups == 6 &&
              harness.pool().snapshot().pagesActive == 0,
          "warmup held the runway past Ready");
}

void testBudgetLimitedWarmupTriesOnlyWidthsThatFit() {
  const auto complete = memoryPlan().breakdown();
  for (uint32_t width : {1U, 2U, 3U}) {
    const uint64_t ceiling = complete.minimumRequiredBytes +
                             (width - 1) * complete.laneStateBytes +
                             complete.laneStateBytes / 2;
    const EngineMemoryPlan plan = test::requireMemoryPlan(
        device(), test::modelMemoryProfile(2 * kGiB, 1 * kGiB, 1 * kGiB), ceiling);
    Harness harness;
    const auto report = warmup(harness, plan);
    requireReady(report);
    std::vector<int> expected{0};
    for (uint32_t lane = 1; lane <= width; ++lane)
      expected.push_back(static_cast<int>(lane));
    expected.push_back(5);
    require(harness.executor().calls == expected,
            "warmup attempted a decode width that cannot fit the plan");
    for (uint32_t lane = 0; lane < report.warmup.decodeBatches.size(); ++lane) {
      require(report.warmup.decodeBatches[lane] ==
                  (lane < width ? WarmupStepStatus::Complete
                                : WarmupStepStatus::MemoryLimited),
              "budget-skipped decode was reported as measured or pending");
    }
    require(harness.progress == counted(6, 6), "a budget-skipped decode was not counted done");
  }
}

void testOptionalAllocationFailuresAreMemoryLimited() {
  const EngineMemoryPlan plan = memoryPlan();
  for (int deniedWidth : {-1, 2, 3, 4}) {
    for (bool denyRestore : {false, true}) {
      Harness harness;
      harness.executor().warmupHook = [&](int step, model::WarmupStepResult &) {
        if (step == deniedWidth || (step == 5 && denyRestore))
          throw metal::MetalAllocationError("injected allocation denial");
      };
      const auto report = warmup(harness, plan);
      requireReady(report);
      const uint32_t completedWidth = deniedWidth < 0 ? 4 : deniedWidth - 1;
      std::vector<int> expected{0};
      for (uint32_t width = 1; width <= completedWidth; ++width)
        expected.push_back(static_cast<int>(width));
      if (deniedWidth >= 0)
        expected.push_back(deniedWidth);
      expected.push_back(5);
      require(harness.executor().calls == expected,
              "bootstrap retried wider batches after allocation denial");
      for (uint32_t lane = 0; lane < report.warmup.decodeBatches.size(); ++lane) {
        require(report.warmup.decodeBatches[lane] ==
                    (lane < completedWidth ? WarmupStepStatus::Complete
                                           : WarmupStepStatus::MemoryLimited),
                "allocation-limited decode status is incorrect");
      }
      require(report.warmup.compositeStateRestore ==
                  (denyRestore ? WarmupStepStatus::MemoryLimited
                               : WarmupStepStatus::Complete),
              "restore allocation denial was reported as a measured success");
      require(harness.progress == counted(6, 6), "an allocation-limited step was not counted done");
    }
  }
}

void testResourceFailureClassificationSurvivesBootstrap() {
  for (RuntimeResourceStage stage : {RuntimeResourceStage::ModelLoading,
                                    RuntimeResourceStage::MemoryPlanning}) {
    for (RuntimeResourceFailure failure : {RuntimeResourceFailure::Other,
                                          RuntimeResourceFailure::HostCapacity,
                                          RuntimeResourceFailure::EngineCapacity,
                                          RuntimeResourceFailure::DriverAllocation}) {
      for (const char *message : {
               "currently available; close memory-heavy applications and retry",
               "different diagnostic wording"}) {
        RuntimeResourcesError resourceError(stage, message, "budget details",
                                            failure);
        RuntimeBootstrapError error(resourceError);
        const auto &report = error.report();
        require(report.stage == RuntimeBootstrapStage::ResourceAssembly &&
                    report.resourceStage == stage &&
                    report.resourceFailure == failure &&
                    report.message == message &&
                    report.budgetDescription == "budget details",
                "bootstrap lost resource failure classification or diagnostics");
        require(report.describe().starts_with(
                    "runtime bootstrap failed [resource_assembly/" +
                    std::string(runtimeResourceStageName(stage)) + "]: "),
                "the failure did not name its step of resource assembly");
      }
    }
  }
  RuntimeResourcesError unclassified(RuntimeResourceStage::BackendCreation,
                                      "currently available; close memory-heavy ");
  require(RuntimeBootstrapError(unclassified).report().resourceFailure ==
              RuntimeResourceFailure::Other,
          "resource error became retryable without explicit classification");
}

void testRequiredWarmupPreservesAllocationFailure() {
  const EngineMemoryPlan plan = memoryPlan();
  for (auto failure : {metal::AllocationFailure::HostPressure,
                       metal::AllocationFailure::EngineBudget,
                       metal::AllocationFailure::DriverRejected}) {
    Harness harness;
    harness.executor().warmupHook =
        [failure](int step, model::WarmupStepResult &) {
          if (step == 0)
            throw metal::MetalAllocationError("required allocation", failure);
        };
    try {
      static_cast<void>(warmup(harness, plan));
      throw std::runtime_error("required allocation refusal passed");
    } catch (const RuntimeBootstrapError &error) {
      require(error.report().resourceFailure == resourceAllocationFailure(failure),
              "required warmup erased allocation refusal classification");
    }
  }
}

void testFinalHostPressurePreventsReady() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness harness;
  try {
    static_cast<void>(ServingRuntime::requireWarmup(
        plan, {}, harness.executor(), harness.pool(), harness.recorder(),
        []() -> ActualMemoryReport {
          throw metal::MetalAllocationError("pressure after warmup",
                                             metal::AllocationFailure::HostPressure);
        }));
    throw std::runtime_error("final pressure check passed");
  } catch (const RuntimeBootstrapError &error) {
    require(error.report().resourceFailure == RuntimeResourceFailure::HostCapacity,
            "final host pressure lost retryability");
  }
}

void testWarmupErrorsCannotMasqueradeAsMemoryLimits() {
  enum class Failure {
    Allocation, Backend, General, ZeroTime, InfiniteTime, NanTime
  };
  constexpr RuntimeBootstrapStage stages[] = {
      RuntimeBootstrapStage::MaximumPrefill,
      RuntimeBootstrapStage::DecodeWarmup,
      RuntimeBootstrapStage::DecodeWarmup,
      RuntimeBootstrapStage::DecodeWarmup,
      RuntimeBootstrapStage::DecodeWarmup,
      RuntimeBootstrapStage::CompositeStateRestore,
  };
  const EngineMemoryPlan plan = memoryPlan();
  for (int step = 0; step < 6; ++step) {
    for (Failure failure : {Failure::Allocation, Failure::Backend,
                            Failure::General, Failure::ZeroTime,
                            Failure::InfiniteTime, Failure::NanTime}) {
      if (failure == Failure::Allocation && (step == 2 || step == 3 || step == 4 || step == 5))
        continue;
      Harness harness;
      harness.executor().warmupHook =
          [&](int current, model::WarmupStepResult &result) {
            if (current != step)
              return;
            switch (failure) {
              case Failure::Allocation:
                throw metal::MetalAllocationError("injected required allocation");
              case Failure::Backend:
                throw metal::MetalBackendError("injected GPU command failure");
              case Failure::General:
                throw std::runtime_error("injected general warmup failure");
              case Failure::ZeroTime:
                result.wallSeconds = 0.0;
                break;
              case Failure::InfiniteTime:
                result.wallSeconds = std::numeric_limits<double>::infinity();
                break;
              case Failure::NanTime:
                result.wallSeconds = std::numeric_limits<double>::quiet_NaN();
                break;
            }
          };
      try {
        static_cast<void>(warmup(harness, plan));
        throw std::runtime_error("invalid warmup passed");
      } catch (const RuntimeBootstrapError &error) {
        require(error.report().stage == stages[step] &&
                    (failure == Failure::Allocation ||
                     error.report().resourceFailure == RuntimeResourceFailure::Other) &&
                    harness.executor().calls.back() == step,
                "warmup failure was swallowed as a memory-limited success");
      }
    }
  }
}

void testExceptionsAndMemoryAreFailClosed() {
  const EngineMemoryPlan plan = memoryPlan();
  {
    Harness harness(3);
    try {
      static_cast<void>(engine::ServingRuntime::requireWarmup(
          plan, {}, harness.executor(), harness.pool(), harness.recorder(),
          [] { return ActualMemoryReport{}; }));
      throw std::runtime_error("warmup exception passed");
    } catch (const engine::RuntimeBootstrapError &error) {
      require(error.report().stage ==
                      engine::RuntimeBootstrapStage::DecodeWarmup &&
                  harness.pool().snapshot().pagesActive == 0,
              "warmup exception was not contained or kept the runway held");
    }
  }
  {
    Harness harness;
    try {
      static_cast<void>(engine::ServingRuntime::requireWarmup(
          plan, {}, harness.executor(), harness.pool(), harness.recorder(),
          [] { return ActualMemoryReport{}; }));
      throw std::runtime_error("invalid memory report passed");
    } catch (const engine::RuntimeBootstrapError &error) {
      require(error.report().stage ==
                      engine::RuntimeBootstrapStage::MemoryAudit,
              "invalid memory report escaped the audit");
    }
  }
}

void testStartupRetryWindowOpensAtFirstFailure() {
  using namespace std::chrono_literals;
  RuntimeBootstrapReport failure;
  failure.resourceStage = RuntimeResourceStage::ModelLoading;
  failure.resourceFailure = RuntimeResourceFailure::HostCapacity;
  StartupRetryWindow window(30s);
  const auto first = StartupRetryWindow::Clock::time_point{} + 5min;
  require(window.retryUntil(failure, first) == first + 30s &&
              window.retryUntil(failure, first + 29s) == first + 30s &&
              !window.retryUntil(failure, first + 30s),
          "the startup retry window did not open at the first failure");
  failure.resourceStage = RuntimeResourceStage::StorageAllocation;
  require(window.retryUntil(failure, first + 40s) == first + 70s,
          "progress through resource assembly did not open a new window");
  failure.stage = RuntimeBootstrapStage::MaximumPrefill;
  failure.resourceStage.reset();
  require(window.retryUntil(failure, first + 80s) == first + 110s,
          "progress to a later startup stage did not open a new window");
  for (const auto &[stage, resourceStage] :
       {std::pair{RuntimeBootstrapStage::MaximumPrefill,
                 std::optional<RuntimeResourceStage>()},
        std::pair{RuntimeBootstrapStage::ResourceAssembly,
                 std::optional(RuntimeResourceStage::StorageAllocation)},
        std::pair{RuntimeBootstrapStage::ResourceAssembly,
                 std::optional(RuntimeResourceStage::ModelLoading)}}) {
    failure.stage = stage;
    failure.resourceStage = resourceStage;
    require(window.retryUntil(failure, first + 90s) == first + 110s,
            "a failure without progress extended the retry window");
  }
  failure.resourceFailure = RuntimeResourceFailure::DriverAllocation;
  require(StartupRetryWindow(30s).retryUntil(failure, first) == first + 30s,
          "a driver allocation failure was not retried");
  for (auto other : {RuntimeResourceFailure::Other,
                     RuntimeResourceFailure::EngineCapacity}) {
    failure.resourceFailure = other;
    require(!StartupRetryWindow(30s).retryUntil(failure, first),
            "a failure that cannot recover was retried");
  }
}

void testProtocolLimitsFollowTheModel() {
  model::ModelCapabilities capabilities;
  capabilities.vocabularySize = 248320;
  const protocol::ProtocolLimits limits = protocolLimitsFor(capabilities, 4096);
  require(limits.maxMaskWords == 7760 * 9 && limits.maxSimulationTokens == 8 &&
              limits.maxTokenBatch == 9 && limits.maxPromptTokens == 4096 &&
              limits.maxLogicalOutputTokens == 4096,
          "the protocol limits do not follow the model and the served context");
}

// Ready says what the start serves: the engine's lanes, the context it
// resolved, vision iff it admits images, and the target's vocabulary, stop
// tokens and mask rows, which the server sizes its constraints by.
void testReadyEventForTheServedModel() {
  model::ModelDescriptor flint;
  flint.target = model::FlintLayout{};
  flint.capabilities.vocabularySize = 150144;
  EngineConfig engine;
  engine.maxContext = 73721;
  engine.maxImagePatches = 16384;
  const protocol::ReadyEvent vision =
      readyEventFor(flint, engine, protocolLimitsFor(flint.capabilities, engine.maxContext));
  require(vision == protocol::ReadyEvent{4, 73721, true, 150144, {150001, 150003, 150005, 150018}, 9},
          "Ready did not announce what a start serving Flint with images serves");
  model::ModelDescriptor dense;
  dense.target = model::Qwen3_8Layout{};
  dense.capabilities.vocabularySize = 248320;
  engine.maxContext = 262144;
  engine.maxImagePatches = 0;
  const protocol::ReadyEvent text =
      readyEventFor(dense, engine, protocolLimitsFor(dense.capabilities, engine.maxContext));
  require(text == protocol::ReadyEvent{4, 262144, false, 248320, {248044, 248046}, 9},
          "Ready did not announce what a start serving a model without images serves");
}

// The failure a start reports in place of Ready names its class, which the
// server's restart policy and the app's words read, with what a memory or
// context refusal needed against what it had.
void testStartFailuresAreClassed() {
  using Kind = protocol::StartFailureKind;
  using Bound = protocol::ShortfallBound;
  require(memoryBound(kGiB, kGiB) == Bound::MaxMemory && memoryBound(0, 24 * kGiB) == Bound::DeviceMemory &&
              memoryBound(64 * kGiB, 24 * kGiB) == Bound::DeviceMemory,
          "a budget --max-memory set was not told from this Mac's own");
  const protocol::StartShortfall memory{Bound::MaxMemory, 10'858'659'840ULL, kGiB, 0};
  const RuntimeBootstrapError refused(RuntimeResourcesError(
      RuntimeResourceStage::MemoryPlanning, "the plan's floors require more", "budget",
      RuntimeResourceFailure::EngineCapacity, memory));
  const protocol::StartFailedEvent plan = startFailedEvent(refused.report());
  require(plan.kind == Kind::MemoryBudget && plan.shortfall == memory &&
              plan.message == "the plan's floors require more",
          "a plan the budget cannot hold was not a memory budget failure with its numbers");
  RuntimeBootstrapReport context;
  context.stage = RuntimeBootstrapStage::ModelCreation;
  context.shortfall = protocol::StartShortfall{.bound = Bound::Disk, .planContextTokens = 73721};
  require(startFailedEvent(context).kind == Kind::ContextBudget &&
              startFailedEvent(context).shortfall == *context.shortfall,
          "a context the plan cannot hold was not a context budget failure");
  const auto kindOf = [](std::optional<RuntimeResourceStage> stage, RuntimeResourceFailure failure) {
    RuntimeBootstrapReport report;
    report.resourceStage = stage;
    report.resourceFailure = failure;
    const protocol::StartFailedEvent event = startFailedEvent(report);
    require(event.shortfall == protocol::StartShortfall{}, "a failure without numbers reported a shortfall");
    return event.kind;
  };
  using Stage = RuntimeResourceStage;
  using Failure = RuntimeResourceFailure;
  require(kindOf(Stage::ModelLoading, Failure::HostCapacity) == Kind::HostMemory &&
              kindOf(std::nullopt, Failure::HostCapacity) == Kind::HostMemory &&
              kindOf(Stage::StorageAllocation, Failure::DriverAllocation) == Kind::DriverAllocation &&
              kindOf(std::nullopt, Failure::EngineCapacity) == Kind::MemoryBudget &&
              kindOf(Stage::Configuration, Failure::Other) == Kind::Configuration &&
              kindOf(Stage::CapabilityValidation, Failure::Other) == Kind::Device &&
              kindOf(Stage::ModelLoading, Failure::Other) == Kind::Model &&
              kindOf(Stage::MemoryPlanning, Failure::Other) == Kind::MemoryBudget &&
              kindOf(Stage::BackendCreation, Failure::Other) == Kind::Internal &&
              kindOf(std::nullopt, Failure::Other) == Kind::Internal,
          "a start failure was not classed by its resource failure and stage");
}

// A warmup command that ran out of GPU memory fails the start as
// CommandMemory, which the start never retries: another process holds what
// the model's commands need, and a retry would take it from that process. A
// command failure of another kind is Internal.
void testAStartCommandOutOfMemoryIsCommandMemoryAndNotRetried() {
  const EngineMemoryPlan plan = memoryPlan();
  for (const bool outOfMemory : {true, false}) {
    Harness harness;
    harness.executor().warmupHook = [&](int step, model::WarmupStepResult &) {
      if (step == 0)
        throw metal::MetalBackendError("Metal command 3 failed", outOfMemory);
    };
    try {
      static_cast<void>(warmup(harness, plan));
      throw std::runtime_error("a failed warmup command passed");
    } catch (const RuntimeBootstrapError &error) {
      const RuntimeBootstrapReport &report = error.report();
      require(report.commandOutOfMemory == outOfMemory &&
                  startFailedEvent(report).kind ==
                      (outOfMemory ? protocol::StartFailureKind::CommandMemory
                                   : protocol::StartFailureKind::Internal),
              "a warmup command's want of GPU memory was not classed as CommandMemory");
      StartupRetryWindow window(supervision::kStartRetryWindow);
      require(!window.retryUntil(report, StartupRetryWindow::Clock::now()),
              "a start whose command failed was retried in-process");
    }
  }
}

// ---- [T021] The completion envelope/channel, move-only and single-publish ----
//
// The envelope's ownership and the channel's synchronized publish->claim edge
// are testable without a device: they carry no Metal work, only tokens.

void testCompletionEnvelopeIsMoveOnly() {
  static_assert(!std::is_copy_constructible_v<CompletionEnvelope>);
  static_assert(!std::is_copy_assignable_v<CompletionEnvelope>);
  static_assert(std::is_move_constructible_v<CompletionEnvelope>);
  static_assert(!std::is_copy_constructible_v<RecoveryCandidate>);
  static_assert(!std::is_copy_assignable_v<RecoveryCandidate>);
  static_assert(!std::is_copy_constructible_v<CompletionChannel>);
  static_assert(!std::is_copy_assignable_v<CompletionChannel>);
  static_assert(!std::is_move_constructible_v<CompletionChannel>);
  static_assert(!std::is_move_assignable_v<CompletionChannel>);
  std::cout << "PASS CompletionEnvelope/RecoveryCandidate are move-only\n";
}

// Exactly one envelope per operation: a publish while one already waits is
// refused, and the owner's claim takes it out once; the wake is the control
// notifier the worker calls after publishing.
void testCompletionChannelPublishOnceClaimOnce() {
  int wakes = 0;
  CompletionChannel channel;
  channel.setWake([&wakes] { ++wakes; });
  require(!channel.held(), "a fresh channel already held a completion");

  CompletionEnvelope first;
  first.lifecycleRevision = 7;
  first.disposal = std::make_unique<DisposalReceipt>();
  first.failed = false;
  require(channel.publish(std::move(first)), "the first completion was refused");
  require(channel.held() && wakes == 1, "the publish did not land or did not wake");

  CompletionEnvelope second;
  second.lifecycleRevision = 8;
  require(!channel.publish(std::move(second)),
          "a second completion landed while one waited: exactly one envelope per operation "
          "was broken");
  require(channel.held() && wakes == 1, "the refused publish woke the control loop anyway");

  auto claimed = channel.claim();
  require(claimed && claimed->lifecycleRevision == 7 && claimed->disposal,
          "the owner's claim did not take the published envelope");
  require(!channel.held() && !channel.claim().has_value(),
          "a claimed completion was still held or claimed twice");
  std::cout << "PASS CompletionChannel publishes exactly one and claims it once\n";
}

// ---- [T020/T022/T021-integration] the real-graph lifecycle pump ----

// A small Qwen3.8 model whose checkpoints load: four target and two draft
// layers, the shape the runtime plans and a start() assembles into the real
// graph the pump drives.
struct PlannedModel final {
  model::Qwen3_8Layout target;
  model::DFlashDraftLayout draft;
  ops::VisionLayout vision;
};

PlannedModel plannedModel() {
  PlannedModel result;
  model::Qwen3_8Layout &target = result.target;
  target.layers = 4;
  target.hiddenSize = 512;
  target.vocabularySize = 1024;
  target.maskToken = 1000;
  target.stopTokens = {1001, 1002};
  target.intermediateSize = 512;
  constexpr std::array<uint32_t, 2> draftReads{1, 3};
  result.draft = model::draftLayout(target.hiddenSize, target.vocabularySize, 2, 1024,
                                    10'000'000.0F, draftReads);
  ops::VisionLayout &vision = result.vision;
  vision.depth = 2;
  vision.hiddenSize = 128;
  vision.patchDimension = 1536;
  vision.intermediateSize = 200;
  vision.paddedIntermediateSize = 256;
  vision.mergedHiddenSize = 512;
  vision.outputHiddenSize = target.hiddenSize;
  vision.heads = 2;
  vision.headDimension = 64;
  vision.positionGridSide = 4;
  return result;
}

std::string gMetallib;

RuntimeBootstrapConfig lifecycleConfig(const std::filesystem::path &root) {
  const PlannedModel planned = plannedModel();
  RuntimeBootstrapConfig config;
  RuntimeResourcesConfig &resources = config.resources;
  resources.metallibPath = gMetallib;
  // Lifecycle tests exercise host Metal; ANE calibration is covered separately.
  resources.aneFfn.enabled = false;
  resources.modelRoot = root;
  resources.model = model::makeModelDescriptor("lifecycle-test", planned.target, planned.draft,
                                               planned.vision, model::TargetSource::Safetensors,
                                               model::VisionSource::Safetensors);
  resources.buildId = "lifecycle-test";
  static_cast<void>(test::writeSyntheticModel(root, planned.target, planned.draft, planned.vision));
  return config;
}


// Builds a real, started bootstrap over `root`: resources + a resident model +
// the native loop with its ReadyEvent, exactly as production start() does, so
// the pump runs on the graph's own lease. The output (ReadyEvent and later frames)
// is collected for the one-shot-ReadyEvent assertions.
struct LifecycleHarness final {
  std::vector<uint8_t> output;
  RuntimeMetrics metrics;
  std::unique_ptr<RuntimeBootstrap> bootstrap;

  explicit LifecycleHarness(const std::filesystem::path &root) {
    RuntimeBootstrapConfig config = lifecycleConfig(root);

    config.lifecycleWake = [] {};
    bootstrap = engine::RuntimeBootstrap::start(
        std::move(config),
        [this](std::span<const uint8_t> bytes) {
          output.insert(output.end(), bytes.begin(), bytes.end());
        },
        [] { return 0.0; });
    bootstrap->announceReady();
  }
};

// T053: the production transport and lifecycle pump share one bootstrap and loop.
void testFdRecoveryRevisionFence() {
  const test::TemporaryDirectory root("splash-fd-recovery");
  struct Pipes {
    int input[2]{-1, -1}, output[2]{-1, -1};
    Pipes() {
      if (pipe(input) != 0 || pipe(output) != 0) {
        for (int fd : input) if (fd >= 0) close(fd);
        throw std::runtime_error("pipe creation failed");
      }
    }
    ~Pipes() { for (int fd : input) if (fd >= 0) close(fd);
               for (int fd : output) if (fd >= 0) close(fd); }
  } pipes;
  engine::FdTransport transport(pipes.input[0], pipes.output[1]);
  auto config = lifecycleConfig(root.path());
  config.lifecycleWake = transport.controlNotifier();
  std::mutex mutex;
  std::condition_variable cv;
  bool entered = false, release = false, borrowed = true;
  std::atomic<unsigned> builds{0};
  struct View {
    LifecycleStatusSnapshot life;
    RuntimeResources *resources = nullptr;
    Cache *cache = nullptr;
    WriteBehind *writeBehind = nullptr;
    const Engine *engine = nullptr;
    ResourceDomainAuthority::Holder holder = ResourceDomainAuthority::Holder::Owner;
    bool model = false, admission = false, worker = false, operation = false;
    size_t candidates = 0, accounts = 0, poolCount = 0;
    uint64_t submitted = 0;
    bool drained = false, ioIdle = false, callbacks = false, command = false;
    Engine::CallbackRetirement retirement;
  } view;
  auto describe = [](const View &v) {
    std::ostringstream out;
    out << "state=" << lifecycleStateName(v.life.state)
        << " power=" << lifecyclePowerName(v.life.power)
        << " revision=" << v.life.revision
        << " observationSequence=" << v.life.observationSequence
        << " controlReady=" << v.life.controlReady
        << " inferenceReady=" << v.life.inferenceReady
        << " modelResident=" << v.life.modelResident
        << " configuredContextCeiling=" << v.life.configuredContextCeiling
        << " effectiveContextTokens=";
    if (v.life.effectiveContextTokens) out << *v.life.effectiveContextTokens;
    else out << "absent";
    out << " publishedEngine=" << v.engine << " admissionOpen=" << v.admission
        << " holder=" << static_cast<int>(v.holder)
        << " drained=" << v.drained << " ioIdle=" << v.ioIdle
        << " callbacksRetired=" << v.callbacks << " commandInFlight=" << v.command
        << " notifierSeats=" << v.retirement.notifierSeats
        << " notifierRuns=" << v.retirement.notifierRuns
        << " agentJobs=" << v.retirement.agentJobs << " serviceWork=" << v.retirement.serviceWork
        << " error=" << v.life.lastError;
    return out.str();
  };
  std::promise<RuntimeBootstrap *> started;
  auto ready = started.get_future();
  auto runner = std::async(std::launch::async, [&] {
    std::unique_ptr<RuntimeBootstrap> owned;
    bool announced = false;
    auto retire = [&] {
      // Even an early loop failure cannot invalidate the test thread's borrow.
      if (announced) {
        std::unique_lock lock(mutex);
        if (!cv.wait_for(lock, std::chrono::seconds(15), [&] { return !borrowed; })) {
          std::cerr << "FD recovery fixture: test borrow did not retire\n";
          std::_Exit(EXIT_FAILURE); // Last-resort deadlock containment.
        }
      }
      transport.setControlHandler({});
      owned.reset(); // Constructing/Owner thread also shuts down and destroys.
    };
    try {
      owned = RuntimeBootstrap::start(std::move(config), transport.outputSink(),
                                    [&] { return transport.maxTickMilliseconds(); });
      auto *live = owned.get();
      RuntimeBootstrapTestAccess::gateProductionWarmCandidate(*live,
          [&, live](const RecoveryCandidate &candidate, const WorkerCancellation &cancelled) {
        require(candidate.borrowedResources == &live->resources() && candidate.engine &&
                    candidate.model && candidate.residency && !candidate.ownsResources(),
                "FD gate did not receive a complete production warm candidate");
        if (++builds != 1) return;
        std::unique_lock lock(mutex);
        entered = true;
        cv.notify_all();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        while (!release && !cancelled()) {
          require(std::chrono::steady_clock::now() < deadline, "FD warm candidate gate timed out");
          cv.wait_for(lock, std::chrono::milliseconds(10));
        }
      });
      auto capture = [&, live] {
        View next;
        next.life = live->lifecycleStatus();
        next.resources = &live->resources();
        next.cache = &live->resources().cache();
        next.writeBehind = &live->resources().writeBehind();
        next.engine = live->nativeLoop().publishedEngine();
        next.model = live->hasModelRuntime();
        next.admission = live->nativeLoop().admissionOpen();
        next.holder = RuntimeBootstrapTestAccess::holder(*live);
        next.worker = RuntimeBootstrapTestAccess::workerRunning(*live);
        next.operation = RuntimeBootstrapTestAccess::pumpOperationStarted(*live);
        next.candidates = RuntimeBootstrapTestAccess::liveCandidates(*live);
        // Worker/Writer status remains passive. Only the idle Owner traverses registrations.
        if (next.holder == ResourceDomainAuthority::Holder::Owner && !next.worker && !next.operation) {
          next.accounts = live->resources().memoryGovernor().publishSnapshot().accounts.size();
          if (next.model) next.poolCount = live->modelRuntime().pools().size();
          next.drained = live->nativeLoop().requestDrain().drained();
          next.ioIdle = live->resources().cache().retainedIoIdle();
          if (next.engine) {
            next.submitted = live->nativeLoop().snapshot().submitted;
            next.command = live->nativeLoop().commandInFlight();
            next.retirement = next.engine->callbackRetirement();
            next.callbacks = next.retirement.retired();
          }
        }
        std::lock_guard lock(mutex);
        view = next;
      };
      transport.setControlHandler([live, capture] {
        const bool progressed = live->controlPass(MemoryPressure::Normal);
        capture();
        return progressed;
      });
      live->announceReady();
      capture();
      announced = true;
      started.set_value(live);
      const auto result = transport.run(live->nativeLoop());
      if (result != engine::NativeProcessExit::CleanEof) {
        std::lock_guard lock(mutex);
        std::cerr << "FD recovery loop failure: " << live->nativeLoop().engineFailure()
                  << " " << describe(view) << '\n';
      }
      retire();
      return result;
    } catch (...) {
      const auto error = std::current_exception();
      if (!announced) started.set_exception(error);
      retire();
      std::rethrow_exception(error);
    }
  });
  struct Cleanup {
    std::mutex &mutex; std::condition_variable &cv; bool &release, &borrowed;
    engine::FdTransport &transport; std::future<engine::NativeProcessExit> &runner;
    bool finished = false;
    void finish(bool checkResult = true) {
      if (finished) return;
      { std::lock_guard lock(mutex); release = true; borrowed = false; }
      cv.notify_all();
      transport.requestShutdown();
      if (runner.wait_for(std::chrono::seconds(15)) != std::future_status::ready) {
        std::cerr << "FD recovery fixture: runner did not stop after gate release and shutdown\n";
        std::_Exit(EXIT_FAILURE); // Last-resort deadlock containment.
      }
      finished = true;
      const auto result = runner.get();
      if (checkResult) require(result == engine::NativeProcessExit::CleanEof, "FD runner exited with failure");
    }
    ~Cleanup() {
      if (!finished) {
        try { finish(std::uncaught_exceptions() == 0); }
        catch (const std::exception &error) { std::cerr << "FD cleanup: " << error.what() << '\n'; }
      }
    }
  } cleanup{mutex, cv, release, borrowed, transport, runner};
  require(ready.wait_for(std::chrono::seconds(15)) == std::future_status::ready,
          "FD recovery fixture startup timed out");
  RuntimeBootstrap *bootstrap = ready.get(); // Borrow ends BEFORE cleanup.finish().
  auto snapshot = [&] { std::lock_guard lock(mutex); return view; };
  auto check = [&](bool condition, const char *message) {
    if (!condition) throw std::runtime_error(std::string(message) + ": " + describe(snapshot()));
  };
  protocol::peer::EventReader reader;
  std::vector<protocol::EngineEvent> events;
  auto send = [&](const auto &frame) {
    auto bytes = protocol::peer::serialize(frame);
    size_t offset = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (offset < bytes.size()) {
      pollfd fd{pipes.input[1], POLLOUT, 0};
      auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
      require(left.count() > 0 && poll(&fd, 1, static_cast<int>(left.count())) > 0,
              "FD request write timed out");
      const auto n = write(pipes.input[1], bytes.data() + offset, bytes.size() - offset);
      if (n < 0 && errno == EINTR) continue;
      require(n > 0, "FD request write failed");
      offset += static_cast<size_t>(n);
    }
  };
  auto status = [&](uint64_t id) -> std::string {
    send(protocol::StatusRequestFrame{id});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    std::array<uint8_t, 4096> buffer{};
    while (std::chrono::steady_clock::now() < deadline) {
      for (const auto &event : events)
        if (const auto *reply = std::get_if<protocol::StatusJsonEvent>(&event); reply && reply->correlationId == id)
          return reply->json;
      auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
      pollfd fd{pipes.output[0], POLLIN, 0};
      if (poll(&fd, 1, static_cast<int>(left.count())) <= 0) break;
      const auto count = read(pipes.output[0], buffer.data(), buffer.size());
      if (count <= 0) break;
      auto decoded = reader.feed(std::span<const uint8_t>(buffer.data(), static_cast<size_t>(count)));
      events.insert(events.end(), decoded.begin(), decoded.end());
    }
    throw std::runtime_error("FD status response timed out: " + describe(snapshot()));
  };
  uint64_t nextStatus = 5400;
  auto waitView = [&](const std::function<bool(const View &)> &done, const char *message) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    do {
      transport.controlNotifier()();
      status(nextStatus++); // FD round trip; capture runs on the Owner control pass.
      const auto current = snapshot();
      if (done(current)) return current;
    } while (std::chrono::steady_clock::now() < deadline);
    check(false, message);
    return snapshot();
  };
  const auto initial = snapshot();
  auto *resources = initial.resources;
  auto *cache = initial.cache;
  auto *writeBehind = initial.writeBehind;
  bootstrap->observePower(LifecyclePower::AC);
  waitView([](const View &v) { return v.life.inferenceReady; }, "initial AC did not authorize inference");
  bootstrap->observePower(LifecyclePower::Battery);
  const auto suspended = waitView([](const View &v) {
    return v.life.state == LifecycleState::Suspended && !v.worker && !v.operation &&
           v.holder == ResourceDomainAuthority::Holder::Owner;
  }, "physical suspension did not finish");
  check(!suspended.engine && !suspended.model && !suspended.life.modelResident &&
            !suspended.admission && suspended.resources == resources && suspended.cache == cache &&
            suspended.writeBehind == writeBehind && initial.poolCount > 0 &&
            suspended.accounts + initial.poolCount == initial.accounts,
        "physical disposal did not detach the model and retire its Ledger registrations");
  bootstrap->observePower(LifecyclePower::AC);
  { std::unique_lock lock(mutex);
    require(cv.wait_for(lock, std::chrono::seconds(15), [&] { return entered; }), "production warm build did not reach gate"); }
  const auto blocked = status(5301);
  const auto atGate = snapshot();
  check(blocked.find("\"inference_ready\":false") != std::string::npos &&
            blocked.find("\"state\":\"recovering\"") != std::string::npos &&
            !atGate.engine && !atGate.model && !atGate.admission &&
            atGate.holder == ResourceDomainAuthority::Holder::Worker,
        "blocked production candidate status was not passive and fail-closed");
  const auto blockedRevision = atGate.life.revision;
  const auto blockedSequence = atGate.life.observationSequence;
  bootstrap->observePower(LifecyclePower::AC);
  waitView([&](const View &v) { return v.life.observationSequence > blockedSequence; },
           "duplicate AC was not consumed");
  check(snapshot().life.revision == blockedRevision && builds == 1,
        "duplicate AC changed authority revision or started another build");
  bootstrap->observePower(LifecyclePower::Battery);
  status(5302);
  waitView([](const View &v) { return v.life.power == LifecyclePower::Battery; },
           "Battery did not supersede the candidate");
  protocol::RequestFrame request;
  request.requestId = 5303;
  request.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
  request.remainingDeadlineMicros = 60'000'000;
  request.logicalMaxOutputTokens = 1;
  request.promptTokens = {1, 2, 3};
  send(request);
  status(5304); // Ordered after the request; retain all decoded events.
  unsigned errors = 0, done = 0, starts = 0;
  for (const auto &event : events) {
    if (const auto *e = std::get_if<protocol::ErrorEvent>(&event); e && e->requestId == 5303) {
      ++errors;
      check(e->code == "inference_unavailable", "wrong FD refusal code");
    }
    if (const auto *e = std::get_if<protocol::DoneEvent>(&event); e && e->requestId == 5303) ++done;
    if (const auto *e = std::get_if<protocol::StartEvent>(&event); e && e->requestId == 5303) ++starts;
  }
  check(errors == 1 && done == 0 && starts == 0 && !snapshot().engine &&
            !snapshot().admission && !snapshot().life.inferenceReady && snapshot().submitted == 0,
        "FD Battery request executed or did not receive its one unavailable error");
  { std::lock_guard lock(mutex); release = true; } cv.notify_all();
  const auto retired = waitView([](const View &v) {
    return v.life.state == LifecycleState::Suspended && !v.worker && !v.operation &&
           v.candidates == 0 && v.holder == ResourceDomainAuthority::Holder::Owner;
  }, "superseded production candidate did not finish Worker retirement");
  // Exact Engine/model/residency destructor ordering is also asserted by
  // testReaperDisposesColdAndWarmCandidatesInOrder(). Here the FD boundary
  // proves no publication, no stranded ownership and no old pool registrations.
  check(!retired.engine && !retired.model && !retired.admission &&
            !retired.life.inferenceReady && retired.accounts == suspended.accounts &&
            retired.resources == resources && retired.cache == cache && retired.writeBehind == writeBehind,
        "superseded candidate leaked registrations, ownership or publication");
  status(5306);
  bootstrap->observePower(LifecyclePower::AC);
  const auto recovered = waitView([](const View &v) {
    return v.life.inferenceReady && !v.worker && !v.operation;
  }, "fresh AC did not complete production adoption");
  check(recovered.engine && recovered.model && recovered.life.modelResident && recovered.admission &&
            builds == 2 && recovered.candidates == 0 && recovered.accounts == initial.accounts &&
            recovered.resources == resources && recovered.cache == cache && recovered.writeBehind == writeBehind,
        "fresh AC did not publish a real Engine over the retained graph");
  status(5305);
  check(std::count_if(events.begin(), events.end(), [](const auto &event) {
          return std::holds_alternative<protocol::ReadyEvent>(event);
        }) == 1, "FD recovery changed the process generation's ReadyEvent count");
  cleanup.finish();
  std::cout << "PASS FD recovery revision fence\n";
}

// Counts ReadyEvent frames the loop wrote: the pump must never re-announce.
size_t readyEventCount(const std::vector<uint8_t> &bytes) {
  size_t count = 0;
  for (const auto &event : protocol::peer::decodeEvents(std::span<const uint8_t>(bytes)))
    if (std::holds_alternative<protocol::ReadyEvent>(event))
      ++count;
  return count;
}

// Advances safe points until the pump's state satisfies `done`, without sleeping:
// the pump only claims a landed completion, so re-running controlPass (or
// advanceLifecycle) consumes it deterministically once the worker's single
// operation has published. Each iteration yields the CPU, exactly as the real
// control loop does while it waits in poll(2) for the residency worker's
// wake: the delegated work (a real Engine/RuntimeModel destruction, or a
// candidate build) runs on the worker thread, and a pure spin of safe points
// can otherwise exhaust its bound before that thread gets scheduled. The
// bound counts safe points, not wall time: the loop returns as soon as the
// state is reached, and only a pump that never reaches it fails.
void pumpUntil(RuntimeBootstrap &bootstrap, const std::function<bool()> &done,
               const char *message, int limit = 100000) {
  for (int step = 0; step < limit; ++step) {
    if (done())
      return;
    static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
    std::this_thread::yield();
  }
  throw std::runtime_error(message);
}

// The same safe-point drive for waits that include REAL off-thread work: a
// candidate graph's assembly or physical disposal is a genuine GPU load, so
// the bound is generous and each iteration yields the CPU with a bounded
// wait rather than a pure spin. The predicate still decides: a pump that
// never advances fails, deterministically, at the bound.
void pumpReal(RuntimeBootstrap &bootstrap, const std::function<bool()> &done,
              const char *message, int limit = 30000) {
  for (int step = 0; step < limit; ++step) {
    if (done())
      return;
    static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  throw std::runtime_error(message);
}

// Wait for the STARTED operation's completion to land WITHOUT taking another
// safe point: only the owner thread claims a completion, so while this thread
// polls the mailbox the envelope is stored, unclaimed, and its token parked.
void waitPublished(RuntimeBootstrap &bootstrap, int limit = 3000000) {
  for (int step = 0; step < limit; ++step) {
    if (RuntimeBootstrapTestAccess::channelHeld(bootstrap))
      return;
    std::this_thread::yield();
  }
  throw std::runtime_error("the started operation never published");
}

// A worker seam that records the thread and does the ONE gated domain operation
// only a holder may perform: a zero-byte governor admission on the claimed
// authority. This proves the operation ran on the worker (which holds the
// Worker interval), never on the owner safe point, without loading a model.
struct WorkerWitness final {
  std::thread::id controlThread = std::this_thread::get_id();
  std::mutex mutex;
  std::vector<std::string> events;  // "dispose", "build", "adopt"
  std::vector<std::thread::id> disposeThreads, buildThreads, adoptThreads;
  std::atomic<int> liveOperations{0};
  int maxLiveOperations = 0;
  bool admitFailed = false;
};

// [T020] The lifecycle pump drives the whole cycle over the real graph, minting
// revisions only on a power change, publishing an observation sequence per
// meaningful change, closing native admission before draining, delegating every
// expensive step to the single residency worker, and never re-announcing the
// ReadyEvent.
void testLifecyclePumpSuspendAndRecoverOnRealGraph() {
  const test::TemporaryDirectory root("splash-native-lifecycle");
  LifecycleHarness harness(root.path());
  RuntimeBootstrap &bootstrap = *harness.bootstrap;
  WorkerWitness witness;

  // Ordinary startup already authorizes AC; no observer event has been consumed.
  // The ready graph holds its Owner interval and announced Ready once.
  require(RuntimeBootstrapTestAccess::observationSequence(bootstrap) == 0,
          "a never-observed lifecycle published an observation sequence");
  const auto initial = bootstrap.lifecycleStatus();
  require(initial.state == LifecycleState::Ready && initial.power == LifecyclePower::AC &&
              initial.inferenceReady && initial.modelResident && validLifecycleStatus(initial),
          "ordinary startup did not authorize the physically resident AC graph");
  require(bootstrap.nativeLoop().admissionOpen(),
          "start did not leave native admission open");
  require(RuntimeBootstrapTestAccess::holder(bootstrap) ==
              ResourceDomainAuthority::Holder::Owner,
          "a started bootstrap did not hold its own resource domain");
  require(readyEventCount(harness.output) == 1, "start did not announce one ReadyEvent");

  RuntimeBootstrapTestAccess::installWorkerSeams(
      bootstrap,
      [&witness, &bootstrap](const WorkerCancellation &) -> DisposalReceipt {
        const int live = ++witness.liveOperations;
        witness.maxLiveOperations = std::max(witness.maxLiveOperations, live);
        witness.disposeThreads.push_back(std::this_thread::get_id());
        // The thread identity and live-operation count prove the real
        // transferred authority reached a worker thread; a passive governor read
        // starts no Metal or model work.
        static_cast<void>(bootstrap.resources().memoryGovernor().snapshot());
        {
          std::lock_guard lock(witness.mutex);
          witness.events.push_back("dispose");
        }
        --witness.liveOperations;
        DisposalReceipt receipt;
        receipt.complete = true;
        return receipt;
      },
      [&witness, &bootstrap](const WorkerCancellation &) -> std::unique_ptr<RecoveryCandidate> {
        const int live = ++witness.liveOperations;
        witness.maxLiveOperations = std::max(witness.maxLiveOperations, live);
        witness.buildThreads.push_back(std::this_thread::get_id());
        static_cast<void>(bootstrap.resources().memoryGovernor().snapshot());
        {
          std::lock_guard lock(witness.mutex);
          witness.events.push_back("build");
        }
        --witness.liveOperations;
        auto candidate = std::make_unique<RecoveryCandidate>();
        candidate->lifecycleRevision = 0;  // the owner fences on the real revision
        return candidate;
      },
      [&witness](const RecoveryCandidate &) {
        witness.adoptThreads.push_back(std::this_thread::get_id());
        {
          std::lock_guard lock(witness.mutex);
          witness.events.push_back("adopt");
        }
        return true;
      });

  // AC authority opens the existing residency; the pump establishes it and Ready.
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap,
            [&] { return RuntimeBootstrapTestAccess::state(bootstrap) ==
                            LifecycleState::Ready &&
                            RuntimeBootstrapTestAccess::revision(bootstrap) == 0; },
            "duplicate startup AC minted a new authority revision");
  require(bootstrap.nativeLoop().admissionOpen(), "AC authority did not leave admission open");
  require(bootstrap.lifecycleStatus().inferenceReady,
          "AC authority at Ready did not mint inference readiness");
  require(bootstrap.lifecycleStatus().effectiveContextTokens.has_value() &&
              *bootstrap.lifecycleStatus().effectiveContextTokens ==
                  bootstrap.lifecycleStatus().configuredContextCeiling,
          "AC Ready did not report its effective context under the ceiling");

  // Battery: close admission BEFORE draining, and delegate the disposal.
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap,
            [&] { return RuntimeBootstrapTestAccess::state(bootstrap) ==
                            LifecycleState::Draining; },
            "Battery did not move the pump to Draining");
  require(!bootstrap.nativeLoop().admissionOpen(),
          "native admission stayed open during Draining");

  // While the worker holds the domain it must NOT be the Owner, and the pump
  // never runs the backend/governor maintenance on the safe point.
  pumpUntil(
      bootstrap,
      [&] { return RuntimeBootstrapTestAccess::state(bootstrap) ==
                     LifecycleState::Suspended; },
      "the disposal never delegated to the worker");
  require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended,
          "the pump did not publish Suspended after a current disposal envelope");
  require(!RuntimeBootstrapTestAccess::pumpModelResident(bootstrap),
          "the pump kept residency across a landed disposal");
  require(RuntimeBootstrapTestAccess::holder(bootstrap) ==
              ResourceDomainAuthority::Holder::Owner,
          "the returned authority did not rebind the Owner interval");

  // Only AC rebuilds the disposable stratum.
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap,
            [&] { return RuntimeBootstrapTestAccess::state(bootstrap) ==
                            LifecycleState::Ready; },
            "AC did not recover through Recovering to Ready");
  require(bootstrap.lifecycleStatus().inferenceReady &&
              RuntimeBootstrapTestAccess::pumpModelResident(bootstrap),
          "recovery did not restore readiness and residency");

  // Revision mints only on a power change; observationSequence advances per
  // meaningful lifecycle change and never regresses.
  require(RuntimeBootstrapTestAccess::revision(bootstrap) == 2,
          "the lifecycle revision did not advance only on power changes (Battery,AC)");
  const uint64_t sequence = RuntimeBootstrapTestAccess::observationSequence(bootstrap);
  require(sequence >= 5, "the observation sequence did not advance across the state changes");

  // The expensive disposal and construction happened ONLY on the worker thread:
  // never on the control thread, and the adoption only on the control thread.
  require(!witness.disposeThreads.empty() && !witness.buildThreads.empty(),
          "the worker seams never ran");
  bool offThreadDisposal = true, offThreadBuild = true, onThreadAdoption = true;
  for (const auto &id : witness.disposeThreads)
    offThreadDisposal = offThreadDisposal && id != witness.controlThread;
  for (const auto &id : witness.buildThreads)
    offThreadBuild = offThreadBuild && id != witness.controlThread;
  for (const auto &id : witness.adoptThreads)
    onThreadAdoption = onThreadAdoption && id == witness.controlThread;
  require(offThreadDisposal && offThreadBuild,
          "a residency disposal or construction ran on the owner safe-point thread");
  require(onThreadAdoption, "a candidate was published off the owner safe point");
  require(!witness.admitFailed, "a residency worker could not hold its transferred domain");
  require(witness.maxLiveOperations == 1, "more than one residency operation ran at once");
  {
    std::lock_guard lock(witness.mutex);
    require(witness.events == std::vector<std::string>{"dispose", "build", "adopt"},
            "the worker did not dispose, then build, then adopt in order with no overlap");
  }

  // The ReadyEvent stays one-shot across the whole suspend/recover cycle: the
  // pump never re-announces readiness.
  require(readyEventCount(harness.output) == 1,
          "the lifecycle pump re-announced the ReadyEvent");
  std::cout << "PASS lifecycle pump: Ready -> Draining -> Suspended -> Recovering -> Ready "
               "on the real graph, delegated off-thread\n";
}

// [T034] The consumed-value rule and the status ordering. A duplicate power
// observation the owner CONSUMES mints a STRICTLY newer observation sequence at
// the SAME lifecycle revision: while the mailbox holds an unconsumed sample the
// identical (revision, sequence) snapshot reads fail-closed for inference, and a
// status cache that refuses to overwrite authority it already saw at one order
// would keep serving that negative snapshot until some later power change.
// The revision still mints ONLY on a power change, the raw power-observation
// generation is a separate counter, nothing re-announces the ReadyEvent and the
// published Engine is never republished.
void testDuplicateACObservationAdvancesStatusOrder() {
  const test::TemporaryDirectory root("splash-native-duplicate-ac-order");
  LifecycleHarness harness(root.path());
  auto &bootstrap = *harness.bootstrap;
  auto &loop = bootstrap.nativeLoop();

  // The production mailbox carries every observation: the callback records,
  // the owner takes and applies it at a safe point.
  auto mailbox = std::make_shared<PendingPowerObservation>([] {});
  mailbox->recordInitial(LifecyclePower::AC);
  bootstrap.setPowerObservation(mailbox);
  if (auto observation = mailbox->take())
    bootstrap.observePower(*observation);
  pumpUntil(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
            "the initial AC sample did not establish a Ready AC lifecycle");

  const auto baseline = bootstrap.lifecycleStatus();
  const auto *engine = loop.publishedEngine();
  const uint64_t revision = RuntimeBootstrapTestAccess::revision(bootstrap);
  const uint64_t sequence = RuntimeBootstrapTestAccess::observationSequence(bootstrap);
  require(baseline.state == LifecycleState::Ready && baseline.inferenceReady &&
              baseline.effectiveContextTokens.has_value() && engine &&
              loop.admissionOpen() && readyEventCount(harness.output) == 1,
          "the AC baseline was not Ready over the published Engine with one ReadyEvent");

  // The duplicate AC sample the callback recorded and the owner has NOT reached:
  // the same (R,S) reads fail-closed, the Engine stays published, and a
  // lifecycleStatus() read versions nothing — the pump consumed nothing.
  mailbox->record(LifecyclePower::AC);
  const auto pending = bootstrap.lifecycleStatus();
  static_cast<void>(bootstrap.lifecycleStatus());
  require(!pending.inferenceReady && !pending.effectiveContextTokens &&
              RuntimeBootstrapTestAccess::revision(bootstrap) == revision &&
              RuntimeBootstrapTestAccess::observationSequence(bootstrap) == sequence &&
              loop.publishedEngine() == engine && readyEventCount(harness.output) == 1,
          "the pending duplicate failed closed at another order, or a read advanced it");

  // The owner consumes it through the production path.
  if (auto observation = mailbox->take())
    bootstrap.observePower(*observation);
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));

  const auto consumed = bootstrap.lifecycleStatus();
  require(consumed.state == LifecycleState::Ready && consumed.inferenceReady &&
              consumed.effectiveContextTokens == *baseline.effectiveContextTokens &&
              RuntimeBootstrapTestAccess::revision(bootstrap) == revision &&
              RuntimeBootstrapTestAccess::observationSequence(bootstrap) > sequence &&
              loop.publishedEngine() == engine && loop.admissionOpen() &&
              readyEventCount(harness.output) == 1,
          "the consumed duplicate AC did not mint a newer Ready order at the same revision");
  const uint64_t duplicateSequence = RuntimeBootstrapTestAccess::observationSequence(bootstrap);

  // The same rule for Battery: the drain is delegated through a seam (this
  // fixture keeps its physical Engine intact), the changed value mints one
  // revision, and the SECOND Battery observation mints no authority — only a
  // newer order.
  RuntimeBootstrapTestAccess::installWorkerSeams(
      bootstrap,
      [](const WorkerCancellation &) -> DisposalReceipt {
        DisposalReceipt receipt;
        receipt.complete = true;
        return receipt;
      },
      [](const WorkerCancellation &) { return std::unique_ptr<RecoveryCandidate>(); },
      [](const RecoveryCandidate &) { return true; });
  mailbox->record(LifecyclePower::Battery);
  if (auto observation = mailbox->take())
    bootstrap.observePower(*observation);
  pumpUntil(bootstrap,
            [&] {
              return RuntimeBootstrapTestAccess::state(bootstrap) ==
                     LifecycleState::Suspended;
            },
            "the delegated Battery drain never published Suspended");
  const uint64_t batteryRevision = RuntimeBootstrapTestAccess::revision(bootstrap);
  require(batteryRevision == revision + 1 &&
              RuntimeBootstrapTestAccess::observationSequence(bootstrap) > duplicateSequence,
          "the changed Battery did not mint exactly one new revision");
  const uint64_t batterySequence = RuntimeBootstrapTestAccess::observationSequence(bootstrap);

  mailbox->record(LifecyclePower::Battery);
  if (auto observation = mailbox->take())
    bootstrap.observePower(*observation);
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(RuntimeBootstrapTestAccess::revision(bootstrap) == batteryRevision &&
              RuntimeBootstrapTestAccess::observationSequence(bootstrap) > batterySequence &&
              RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended &&
              !bootstrap.lifecycleStatus().inferenceReady &&
              readyEventCount(harness.output) == 1,
          "the consumed duplicate Battery minted authority, reopened serving or left the order unchanged");
  std::cout << "PASS duplicate observations: at AC revision " << revision
            << " (Battery " << batteryRevision << ") the status order advanced "
            << sequence << " -> " << duplicateSequence << " -> "
            << RuntimeBootstrapTestAccess::observationSequence(bootstrap)
            << " with the Engine identity and one ReadyEvent unchanged\n";
}

// [T022] One worker, EXACTLY ONE operation in flight: a running worker is never
// joined or restarted from a safe point; shutdown invalidates the in-flight
// intent; a construction never overlaps a disposal.
void testResidencyWorkerIsSingleAndSerial() {
  const test::TemporaryDirectory root("splash-native-lifecycle-serial");
  LifecycleHarness harness(root.path());
  RuntimeBootstrap &bootstrap = *harness.bootstrap;

  std::atomic<bool> releaseDispose{false};
  std::atomic<bool> disposeEntered{false};
  std::mutex orderMutex;
  std::vector<std::string> order;
  std::atomic<int> overlap{0};
  std::atomic<bool> sawOverlap{false};
  auto note = [&](const char *name) {
    std::lock_guard lock(orderMutex);
    order.emplace_back(name);
  };

  RuntimeBootstrapTestAccess::installWorkerSeams(
      bootstrap,
      [&](const WorkerCancellation &cancelled) -> DisposalReceipt {
        ++overlap;
        if (overlap > 1)
          sawOverlap = true;
        disposeEntered = true;
        // Cooperatively block until the test releases the gate: the safe point
        // must never join this running worker.
        while (!releaseDispose.load() && !cancelled())
          std::this_thread::yield();
        note("dispose");
        --overlap;
        DisposalReceipt receipt;
        receipt.complete = true;
        return receipt;
      },
      [&](const WorkerCancellation &cancelled) -> std::unique_ptr<RecoveryCandidate> {
        static_cast<void>(cancelled);
        ++overlap;
        if (overlap > 1)
          sawOverlap = true;
        note("build");
        --overlap;
        auto candidate = std::make_unique<RecoveryCandidate>();
        candidate->lifecycleRevision = 0;
        return candidate;
      },
      [](const RecoveryCandidate &) { return true; });

  // Drive into Draining and start the disposal; it blocks on the gate.
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] { return disposeEntered.load(); },
            "the disposal operation never started");
  // The operation is running; a safe point must observe it and never join it.
  require(RuntimeBootstrapTestAccess::workerRunning(bootstrap),
          "a safe point did not see the residency worker running");
  require(RuntimeBootstrapTestAccess::holder(bootstrap) !=
              ResourceDomainAuthority::Holder::Owner,
          "the safe point held the domain the worker is operating on");
  // A few extra safe points: the pump keeps observing, still never joins.
  for (int i = 0; i < 4; ++i)
    static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
              disposeEntered.load() && !sawOverlap,
          "a safe point joined or restarted the running worker, or overlapped it");
  // An instrumented second build is impossible: while one runs the pump never
  // starts another (workerStarted_). Confirm the fence held via ordering later.
  releaseDispose = true;
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended;
  }, "the disposed operation never published after release");
  require(!sawOverlap, "a disposal overlapped another residency operation");

  // Shutdown mid-construction invalidates the in-flight intent before teardown
  // joins it: the candidate a shutdown-cancelling build might produce is dropped
  // on the worker, and Shutdown is terminal (later power never revives it).
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap, [&] { return RuntimeBootstrapTestAccess::state(bootstrap) ==
                             LifecycleState::Ready; }, "AC did not recover to Ready");
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] { return disposeEntered.load(); }, "second disposal never started");
  require(static_cast<bool>(bootstrap.shutdownLifecycle()), "shutdown was not taken");
  require(RuntimeBootstrapTestAccess::shutdown(bootstrap), "shutdown did not mark the pump");
  // Later power never revives a shutdown lifecycle.
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap, [&] { return true; }, "no-op safe point");
  require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown,
          "a power observation revived a shutdown lifecycle");
  // ~RuntimeBootstrap joins the (intent-invalid) worker; the test just checks
  // teardown does not hang or strand authority (holder ends Owner in ~ResourceDomainLease).
  harness.bootstrap.reset();
  require(true, "shutdown teardown completed");
  std::cout << "PASS residency worker: one operation, never joined from a safe point, "
               "shutdown terminal\n";
}

// [T021-integration] A candidate whose revision the pump found stale (power
// moved during the safe-point window) or whose build FAILED is never published
// into serving residency: its ownership is retained for the reaper (T032), the
// authority is returned, and the graph stays servable.
void testStaleAndFailedCandidateIsRetainedNotPublished() {
  const test::TemporaryDirectory root("splash-native-lifecycle-stale");
  LifecycleHarness harness(root.path());
  RuntimeBootstrap &bootstrap = *harness.bootstrap;

  std::atomic<bool> enterBuild{false};
  std::atomic<bool> releaseBuild{false};
  std::atomic<int> buildRuns{0};
  std::atomic<bool> throwBuild{false};

  RuntimeBootstrapTestAccess::installWorkerSeams(
      bootstrap,
      [](const WorkerCancellation &) -> DisposalReceipt {
        DisposalReceipt receipt;
        receipt.complete = true;
        return receipt;
      },
      [&](const WorkerCancellation &cancelled) -> std::unique_ptr<RecoveryCandidate> {
        ++buildRuns;
        enterBuild = true;
        while (!releaseBuild.load() && !cancelled())
          std::this_thread::yield();
        if (throwBuild.load())
          return nullptr;  // a construction that yields no candidate
        auto candidate = std::make_unique<RecoveryCandidate>();
        candidate->lifecycleRevision = 0;
        return candidate;
      },
      [](const RecoveryCandidate &) { return true; });

  // Recover to Ready first (AC), then drive a construction that is superseded
  // by a Battery intent before its completion is claimed at the safe point.
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Ready;
  }, "did not reach Ready");
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended;
  }, "did not suspend");
  // Begin a construction: it enters the seam and blocks. Then a NEW Battery
  // intent supersedes it before the pump can claim a current candidate.
  bootstrap.observePower(LifecyclePower::AC);  // Recovering, start build
  pumpUntil(bootstrap, [&] { return enterBuild.load(); }, "construction never started");
  bootstrap.observePower(LifecyclePower::AC);  // no change; keep AC but let it land
  releaseBuild = true;
  pumpUntil(bootstrap, [&] {
    return !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap);
  }, "the construction never published");
  // The candidate was built for the current revision: adopt back to Ready.
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Ready;
  }, "a current candidate was not adopted");
  require(buildRuns >= 1 && RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) >= 1,
          "the retained envelopes did not hold every completed completion");

  // A FAILED construction (no candidate): the pump records RecoveryFailed and
  // retains ownership, WITHOUT stranding the authority or releasing the retained
  // cache/KV graph, which a later AC retries.
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended;
  }, "did not suspend again");
  throwBuild = true;
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::RecoveryFailed;
  }, "a failed construction did not land RecoveryFailed");
  require(RuntimeBootstrapTestAccess::holder(bootstrap) ==
              ResourceDomainAuthority::Holder::Owner,
          "a failed construction stranded the resource-domain authority");
  require(bootstrap.lifecycleStatus().lastError.empty() == false,
          "a failed construction recorded no error for the detached snapshot");
  require(bootstrap.resources().cache().snapshot().kvTier.capacityBytes >= 0 &&
              RuntimeBootstrapTestAccess::revision(bootstrap) >= 1,
          "the retained graph was disturbed by a failed recovery");
  std::cout << "PASS stale/failed candidate retained, authority not stranded\n";
}

// ---- [T024] the physical detach over the real graph (no worker seam) ----

// The suspension safe point MOVES the published Engine (destroyEngine closes
// native admission and re-reads the drain barriers first), the Bootstrap's
// RuntimeModel and the graph's model-bound residency into the disposal payload;
// the ONE residency-worker operation destroys them on the worker thread, under
// its claimed Worker interval, in Engine -> RuntimeModel -> residency order.
// Nothing is destroyed at the safe point, and the retained graph keeps its
// identity.
void testPhysicalSuspensionDetachesStratumOnWorkerThread() {
  const test::TemporaryDirectory root("splash-native-lifecycle-detach");
  LifecycleHarness harness(root.path());
  RuntimeBootstrap &bootstrap = *harness.bootstrap;
  const std::thread::id ownerThread = std::this_thread::get_id();
  require(bootstrap.nativeLoop().hasEngine() && bootstrap.hasModelRuntime() &&
              bootstrap.resources().modelResident(),
          "a started bootstrap published no Engine/Model/residency");

  // No dispose seam is installed: this is the production physical path.
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap,
            [&] {
              return RuntimeBootstrapTestAccess::state(bootstrap) ==
                     LifecycleState::Suspended;
            },
            "the physical detach never completed");

  // The stratum left the safe point for good: Engine-absent loop, no RuntimeModel
  // retained, the residency released from RuntimeResources — while the retained
  // graph is exactly as it was: still there, backend healthy, still Owner.
  require(!bootstrap.nativeLoop().hasEngine() && !bootstrap.hasModelRuntime() &&
              bootstrap.hasResources() && !bootstrap.resources().modelResident(),
          "the physical detach did not move out exactly the Engine/Model/residency");
  require(bootstrap.resources().backend().healthy(),
          "the retained backend was disturbed by the physical detach");
  require(RuntimeBootstrapTestAccess::holder(bootstrap) ==
              ResourceDomainAuthority::Holder::Owner,
          "the detach did not return the domain to its Owner interval");

  // The receipt proves WHERE the destruction happened: named on the residency
  // worker thread, never the owner's, with the retained backend's allocation
  // after measured by the worker itself.
  const std::string detail = RuntimeBootstrapTestAccess::lastDisposalDetail(bootstrap);
  const std::string marker = "destroyed on residency-worker thread ";
  require(detail.find(marker) != std::string::npos,
          "the landed disposal receipt did not name the residency-worker disposal");
  std::ostringstream ownerName;
  ownerName << ownerThread;
  const std::string workerThreadName = detail.substr(marker.size() +
                                                     detail.find(marker));
  require(!workerThreadName.empty() && workerThreadName != ownerName.str(),
          "the stratum was destroyed on the owner safe-point thread");
  require(RuntimeBootstrapTestAccess::lastDisposalBytesAfter(bootstrap).has_value(),
          "the receipt gave no backend allocation measured after the detach");

  // The suspended loop reads Engine-absent: admission closed at the detach,
  // one ReadyEvent only for the whole life so far, and the detached status
  // emits from snapshot evidence alone — byte-stable across identical states,
  // and refusing residency claims.
  require(!bootstrap.nativeLoop().admissionOpen(),
          "the detach left native admission open");
  require(readyEventCount(harness.output) == 1,
          "the physical detach re-announced the ReadyEvent");
  const std::string first =
      bootstrap.statusJson(harness.metrics.snapshot(), NativeLoopTiming{});
  const std::string second =
      bootstrap.statusJson(harness.metrics.snapshot(), NativeLoopTiming{});
  require(first == second &&
              first.find("\"model_resident\":false") != std::string::npos &&
              first.find("\"inference_ready\":false") != std::string::npos,
          "the detached status was unstable or claimed residency/inference");

  // An explicitly empty construction must fail closed despite production
  // adoption being available; retain the failed completion and the graph.
  RuntimeBootstrapTestAccess::installEmptyBuildSeam(bootstrap);
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap,
            [&] {
              return RuntimeBootstrapTestAccess::state(bootstrap) ==
                     LifecycleState::RecoveryFailed;
            },
            "an empty construction did not land RecoveryFailed");
  require(bootstrap.lifecycleStatus().lastError.find("no recovery candidate") !=
              std::string::npos,
          "the empty construction recorded nothing for the detached snapshot");
  require(RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) == 2 &&
              RuntimeBootstrapTestAccess::holder(bootstrap) ==
                  ResourceDomainAuthority::Holder::Owner,
          "the disposal/build envelopes were not both retained beside an Owner domain");
  std::cout << "PASS physical detach: stratum destroyed on the residency worker, "
               "retained graph intact, empty construction fails closed\n";
}

// ---- [T023] the cold Battery/Unknown model-less start ----

// A model-less control shell over the same native protocol: NO RuntimeResources
// (no Metal backend, no package, no graph), no Engine, no synthetic Cache, no
// warmup, no prefix replay. Exactly one ReadyEvent (control readiness, never
// inference), native admission closed from birth, the static configured
// capability legible with nothing loaded, and the pump established from the
// battery policy's INJECTED initial observation. The first AC intent requests
// one private residency-worker construction — at most once — and with no
// adoption protocol the built candidate is retained, not published.
void testColdShellStartServesControlOnlyOnInjectedPower() {
  const test::TemporaryDirectory root("splash-native-cold-shell");
  std::vector<uint8_t> output;
  RuntimeMetrics coldMetrics;
  RuntimeBootstrapConfig liveConfig = lifecycleConfig(root.path());

  liveConfig.initialPower = LifecyclePower::Battery;
  liveConfig.lifecycleWake = [] {};
  const bool staticVision = liveConfig.resources.model.hasVision() && liveConfig.resources.maximumImagePatches != 0;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(liveConfig),
      [&output](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string("{}"); });
  RuntimeBootstrap *cold = bootstrap.get();

  // The absent objects: nothing in this start could be faked.
  require(!cold->hasResources() && !cold->hasModelRuntime() &&
              !cold->nativeLoop().hasEngine(),
          "the cold start constructed a graph, a model or an Engine anyway");
  require(readyEventCount(output) == 1,
          "the cold start did not announce exactly one control ReadyEvent");
  require(!cold->nativeLoop().admissionOpen(),
          "the cold start left native admission open");
  // The one control ReadyEvent advertises the descriptor capability.
  bool vision = false;
  for (const auto &event : protocol::peer::decodeEvents(
          std::span<const uint8_t>(output)))
    if (std::holds_alternative<protocol::ReadyEvent>(event))
      vision = std::get<protocol::ReadyEvent>(event).vision;
  require(vision == staticVision, "the cold ReadyEvent lost its static vision capability");

  // The static configured capability answers with nothing loaded.
  const auto status = cold->lifecycleStatus();
  require(status.power == LifecyclePower::Battery &&
              status.state == LifecycleState::Suspended &&
              status.modelResident == false && !status.inferenceReady &&
              !status.effectiveContextTokens.has_value() &&
              status.revision == 1 && status.configuredContextCeiling > 0,
          "the cold pump did not establish its lifecycle from the injected power");
  require(!cold->statusJson(RuntimeMetricsSnapshot{}, NativeLoopTiming{}).empty(),
          "the cold shell cannot answer /status with no graph");

  // Inference requests answer with one unavailable frame; control keeps working.
  protocol::RequestFrame coldRequest;
  coldRequest.requestId = 7;
  coldRequest.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
  coldRequest.remainingDeadlineMicros = 60'000'000;
  coldRequest.logicalMaxOutputTokens = 1;
  coldRequest.promptTokens = {1, 2, 3};
  require(cold->nativeLoop().receive(protocol::peer::serialize(coldRequest)),
          "a request over the cold shell closed the connection");
  unsigned unavailable = 0, terminal = 0;
  for (const auto &event : protocol::peer::decodeEvents(output)) {
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&event); error && error->requestId == 7) {
      ++terminal;
      unavailable += error->code == "inference_unavailable";
    }
    if (const auto *done = std::get_if<protocol::DoneEvent>(&event); done && done->requestId == 7)
      ++terminal;
  }
  require(terminal == 1 && unavailable == 1, "cold inference did not get one unavailable error");
  require(!cold->controlPass(MemoryPressure::Normal),
          "the cold control pass mutated a domain that is not there");

  // AC requests its private construction ONCE, whatever the pump does after.
  std::atomic<int> coldBuilds{0};
  RuntimeBootstrapTestAccess::installWorkerSeams(
      *cold, nullptr,
      [&coldBuilds](const WorkerCancellation &) {
        ++coldBuilds;
        return std::unique_ptr<RecoveryCandidate>(new RecoveryCandidate());
      },
      nullptr);
  cold->observePower(LifecyclePower::AC);
  pumpUntil(*cold,
            [&] {
              return RuntimeBootstrapTestAccess::state(*cold) ==
                     LifecycleState::RecoveryFailed;
            },
            "the AC intent never requested a cold construction");
  pumpUntil(*cold, [&] { return coldBuilds.load() >= 1; }, "no cold build ran");
  for (int step = 0; step < 8; ++step)
    static_cast<void>(cold->controlPass(MemoryPressure::Normal));
  require(coldBuilds.load() == 1,
          "the cold shell requested its one-shot construction more than once");
  require(RuntimeBootstrapTestAccess::pendingEnvelopes(*cold) == 1 &&
              RuntimeBootstrapTestAccess::state(*cold) ==
                  LifecycleState::RecoveryFailed,
          "the un-adoptable cold candidate was not retained with a recorded refusal");
  require(cold->lifecycleStatus().lastError.find("construction-seam candidate") != std::string::npos,
          "the cold refusal did not identify its construction seam");
  require(readyEventCount(output) == 1 && !cold->nativeLoop().admissionOpen(),
          "the cold recovery request reopened control readiness or admission");
  // The historical requireWarmupAndAnnounce failure check now belongs to the
  // production announcement boundary. A failed control Ready must return no shell.
  auto refusedConfig = lifecycleConfig(root.path());
  refusedConfig.initialPower = LifecyclePower::Battery;
  unsigned readyWrites = 0;
  std::vector<uint8_t> refusedOutput;
  try {
    auto refused = RuntimeBootstrap::startModelLess(std::move(refusedConfig),
        [&](std::span<const uint8_t> bytes) {
          for (const auto &event : protocol::peer::decodeEvents(bytes))
            readyWrites += std::holds_alternative<protocol::ReadyEvent>(event);
          if (readyWrites) throw std::runtime_error("injected Ready write failure");
          refusedOutput.insert(refusedOutput.end(), bytes.begin(), bytes.end());
        }, [] { return std::string("{}"); });
    throw std::runtime_error("failed Ready write returned a control shell");
  } catch (const RuntimeBootstrapError &error) {
    require(error.report().stage == RuntimeBootstrapStage::Ready &&
                error.report().message.find("ReadyEvent announcement failed") != std::string::npos &&
                readyWrites == 1 && refusedOutput.empty(),
            "Ready write failure escaped its announcement boundary or became visible");
  }
  std::cout << "PASS cold model-less start: one control ReadyEvent, admission closed, "
               "absent objects, one AC construction retained\n";
}

// ---- [T025] the control plane while a Worker owns the domain ----

// Control, status and power consumption stay RESPONSIVE while a residency-
// worker operation blocks: no safe point ever joins the in-flight worker; the
// detached status emits identical bytes across identical states; power
// observations are still recorded and consumed at the safe point with the
// revision fence. Shutdown while the worker is still blocked is the ONE
// explicit join: shutdownLifecycle() invalidates the intent, the cooperative
// cancel sees it, the completion lands and is claimed, and the parked token
// returns to the Owner interval before the retained backend stops.
void testControlResponsiveWhileWorkerBlocksAndShutdownJoinsIt() {
  const test::TemporaryDirectory root("splash-native-lifecycle-control");
  LifecycleHarness harness(root.path());
  RuntimeBootstrap &bootstrap = *harness.bootstrap;
  std::atomic<bool> enterDispose{false};
  std::atomic<bool> releaseDispose{false};
  std::atomic<bool> sawCancelled{false};
  std::mutex gateMutex;
  std::condition_variable gateCondition;
  struct Cleanup {
    std::atomic<bool> &release;
    std::condition_variable &condition;
    LifecycleHarness &harness;
    ~Cleanup() {
      release = true;
      condition.notify_all();
      harness.bootstrap.reset(); // Join before any gate capture dies.
    }
  } cleanup{releaseDispose, gateCondition, harness};
  bootstrap.observePower(LifecyclePower::Battery);
  pumpReal(bootstrap, [&] {
    return bootstrap.lifecycleStatus().state == LifecycleState::Suspended &&
           !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
           !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap);
  }, "physical disposal did not complete before the blocked construction");
  const auto envelopesBefore = RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap);
  RuntimeBootstrapTestAccess::gateProductionWarmCandidate(bootstrap,
      [&](const RecoveryCandidate &, const WorkerCancellation &cancelled) {
    std::unique_lock lock(gateMutex);
    enterDispose = true;
    gateCondition.notify_all();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (!releaseDispose.load() && !cancelled()) {
      require(std::chrono::steady_clock::now() < deadline, "blocked production construction timed out");
      gateCondition.wait_for(lock, std::chrono::milliseconds(10));
    }
    sawCancelled = cancelled();
  });
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] { return enterDispose.load(); },
           "the production warm candidate never reached the Worker gate");
  require(RuntimeBootstrapTestAccess::workerRunning(bootstrap),
          "the residency worker is not running while construction blocks");

  // The production disposer already ended the published stratum. A complete
  // PRIVATE warm candidate is held under Worker authority, without publication.
  // Passive status must keep its stable Owner sample and refuse inference.
  require(!bootstrap.nativeLoop().hasEngine() && !bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::holder(bootstrap) ==
                  ResourceDomainAuthority::Holder::Worker,
          "the blocked warm construction published a model or lost Worker authority");
  const std::string detachedWaits =
      "\"admission\":{\"waiting\":0,\"waiting_memory\":0,"
      "\"waiting_concurrency\":0,\"held_behind_refusal\":0,\"restoring\":0,"
      "\"suspended\":0,\"draining\":false,\"oldest_wait_ms\":0}";

  // The safe point never joins it: repeated control passes stay responsive and
  // skip all domain-bound maintenance; the detached status stays byte-identical
  // while only the worker is busy; inference stays refused and the ReadyEvent
  // one-shot.
  const std::string firstStatus =
      bootstrap.statusJson(harness.metrics.snapshot(), NativeLoopTiming{});
  for (int step = 0; step < 4; ++step)
    require(!bootstrap.controlPass(MemoryPressure::Normal),
            "control work ran over the Worker-held domain");
  require(RuntimeBootstrapTestAccess::workerRunning(bootstrap),
          "an ordinary safe point joined the in-flight worker");
  require(firstStatus == bootstrap.statusJson(harness.metrics.snapshot(),
                                              NativeLoopTiming{}),
          "the detached status changed bytes while only the worker was busy");
  require(firstStatus.find(detachedWaits) != std::string::npos &&
              firstStatus.find("\"model_resident\":false") != std::string::npos &&
              firstStatus.find("\"inference_ready\":false") != std::string::npos,
          "the detached status read the published Engine's waits, or claimed "
          "residency/inference readiness");
  require(!bootstrap.nativeLoop().admissionOpen() &&
              readyEventCount(harness.output) == 1,
          "the busy worker reopened admission or re-announced readiness");

  // Power keeps flowing to the pump while the domain is not the Owner's: the
  // observation is recorded from this thread, consumed at the safe point,
  // and the revision fence advances.
  const uint64_t revisionBefore = RuntimeBootstrapTestAccess::revision(bootstrap);
  bootstrap.observePower(LifecyclePower::Unknown);
  pumpUntil(bootstrap,
            [&] { return RuntimeBootstrapTestAccess::revision(bootstrap) != revisionBefore; },
            "a power observation was not consumed while the worker was busy");
  require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Recovering &&
              !bootstrap.nativeLoop().hasEngine() && !bootstrap.nativeLoop().admissionOpen(),
          "a mid-construction power change published a candidate or left recovery");

  // Shutdown with the worker STILL blocked (releaseDispose stays false): the
  // terminal intent cancels the operation cooperatively; the join happens ONLY
  // here; the landed envelope is claimed and its parked token returned.
  static_cast<void>(bootstrap.shutdownLifecycle());
  pumpUntil(bootstrap,
            [&] {
              return !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
                     RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) >= envelopesBefore + 1;
            },
            "shutdown did not let the blocked worker exit and its envelope land");
  require(sawCancelled.load(), "the blocked operation never saw the shutdown cancel");
  require(RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) == envelopesBefore + 1 &&
              RuntimeBootstrapTestAccess::liveCandidates(bootstrap) == 0 &&
              RuntimeBootstrapTestAccess::holder(bootstrap) ==
                  ResourceDomainAuthority::Holder::Owner,
          "the shutdown-landed envelope, candidate retirement or returned token was not accounted for");
  std::cout << "PASS control responsiveness under a blocked Worker + shutdown join\n";
}

// Selected only in exec-isolated children. These witnesses outlive the fixture
// and are examined at main's exception boundary, AFTER all its locals unwind.
constexpr const char *kGateFailureSelector = "SPLASH_BLOCKED_GATE_FAILURE";
struct BlockedGateFailure final {};
struct GateFailureWitness {
  std::string mode;
  bool injected = false;
  bool unwinding = false;
  bool released = false;
  bool callbackRetired = false;
  bool joined = false;
} gGateFailure;

void injectBlockedGateFailure(std::string_view mode, RuntimeBootstrap &bootstrap,
                              std::mutex &mutex, const std::atomic<bool> &entered,
                              const std::atomic<bool> &release) {
  if (gGateFailure.mode != mode)
    return;
  // The callback sets entered under this same mutex immediately before wait.
  // Acquiring it proves wait has released the lock; with release still false,
  // the callback cannot retire (even after a spurious wake).
  std::lock_guard lock(mutex);
  require(entered.load() && !release.load() &&
              RuntimeBootstrapTestAccess::workerRunning(bootstrap),
          "failure injection did not find a blocked publication callback");
  gGateFailure.injected = true;
  throw BlockedGateFailure{};  // Owner thread; the callback never throws.
}

// ---- [T025] completion-publication vs. the worker slot ----

// publish() stores an envelope and wakes the control loop BEFORE run() clears
// the worker's own frame, so an Owner safe point can claim the completion,
// return its parked token and reach the NEXT lifecycle operation while running_
// is still true. residencyWorker_.running() is now part of the pump's slot
// condition, checked BEFORE any quiescence proof is minted, any stratum is
// detached or any WorkerHandoff is transferred (cold construction included):
// the next operation defers instead of moving a token into a start() that
// would refuse and strand the authority. The worker's terminal bookkeeping
// then wakes this thread again (taken from the channel, invoked outside
// both mutexes, after running_ = false), so the deferral is only ever a delay,
// and one operation per slot with the lease intact still holds.
void testCompletionWakeBeforeSlotClearDefersTheNextOperation() {
  const test::TemporaryDirectory root("splash-native-lifecycle-slot-race");
  LifecycleHarness harness(root.path());
  RuntimeBootstrap &bootstrap = *harness.bootstrap;

  std::atomic<int> disposeRuns{0};
  std::atomic<int> buildRuns{0};
  std::atomic<int> liveOperations{0};
  std::atomic<int> maxLiveOperations{0};
  const auto note = [&](std::atomic<int> &runs) {
    const int live = ++liveOperations;
    maxLiveOperations = std::max(maxLiveOperations.load(), live);
    ++runs;
    --liveOperations;
  };

  // Condition-variable synchronization, no sleep, no speculative loop: the
  // worker stands inside its own wake callback until this thread releases it.
  std::mutex gateMutex;
  std::condition_variable gateCondition;
  std::atomic<bool> wakeEntered{false};
  std::atomic<bool> releaseWake{false};
  std::atomic<int> wakeCalls{0};
  std::atomic<bool> callbackRetired{false};
  struct GateCleanup {
    std::atomic<bool> &release;
    std::condition_variable &condition;
    std::mutex &mutex;
    LifecycleHarness &harness;
    std::atomic<bool> &retired;
    ~GateCleanup() {
      const bool probe = gGateFailure.mode == "slot";
      if (probe) gGateFailure.unwinding = std::uncaught_exceptions() > 0;
      { std::lock_guard lock(mutex); release = true; }
      condition.notify_all();
      harness.bootstrap.reset();  // Join BEFORE any callback captures die.
      if (probe) {
        gGateFailure.released = release.load();
        gGateFailure.callbackRetired = retired.load();
        gGateFailure.joined = !harness.bootstrap;
      }
    }
  } cleanup{releaseWake, gateCondition, gateMutex, harness, callbackRetired};

  RuntimeBootstrapTestAccess::installWorkerSeams(
      bootstrap,
      [&](const WorkerCancellation &) -> DisposalReceipt {
        note(disposeRuns);
        DisposalReceipt receipt;
        receipt.complete = true;
        return receipt;
      },
      [&](const WorkerCancellation &) -> std::unique_ptr<RecoveryCandidate> {
        note(buildRuns);
        auto candidate = std::make_unique<RecoveryCandidate>();
        candidate->lifecycleRevision = 0;
        return candidate;
      },
      [](const RecoveryCandidate &) { return true; });

  // The FIRST channel wake is a publication's: it blocks after the envelope
  // was stored, while running_ is still true. Later wakes — the worker's
  // terminal bookkeeping and any further publication — pass through.
  RuntimeBootstrapTestAccess::setChannelWake(
      bootstrap, [&] {
        if (++wakeCalls != 1)
          return;
        std::unique_lock lock(gateMutex);
        wakeEntered = true;
        gateCondition.wait(lock, [&] { return releaseWake.load(); });
        callbackRetired = true;
      });

  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Ready;
  }, "AC did not establish Ready");
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] { return wakeEntered.load(); },
            "the disposal completion never woke this thread");
  injectBlockedGateFailure("slot", bootstrap, gateMutex, wakeEntered, releaseWake);
  require(RuntimeBootstrapTestAccess::workerRunning(bootstrap),
          "the worker cleared its slot before its wake callback returned");

  // 1. The Owner claims the published envelope: its parked token comes back
  //    to this thread's Owner interval while the worker is still inside its
  //    own wake callback.
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) >= 1;
  }, "the published disposal was never claimed");
  require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended &&
              RuntimeBootstrapTestAccess::holder(bootstrap) ==
                  ResourceDomainAuthority::Holder::Owner &&
              disposeRuns.load() == 1 &&
              !RuntimeBootstrapTestAccess::channelHeld(bootstrap),
          "the claimed disposal did not return its token to this Owner interval");

  // 2-4. A newer AC intent asks for the next operation while that previous
  //      worker is still finishing: nothing is minted, transferred or started
  //      prematurely, and the original Owner lease stays valid.
  const uint64_t revisionBefore = RuntimeBootstrapTestAccess::revision(bootstrap);
  bootstrap.observePower(LifecyclePower::AC);
  for (int step = 0; step < 4; ++step)
    static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(RuntimeBootstrapTestAccess::revision(bootstrap) == revisionBefore + 1 &&
              RuntimeBootstrapTestAccess::state(bootstrap) ==
                  LifecycleState::Suspended &&
              buildRuns.load() == 0 &&
              !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap) &&
              RuntimeBootstrapTestAccess::holder(bootstrap) ==
                  ResourceDomainAuthority::Holder::Owner,
          "the deferred safe point started, refused or stranded the next operation");

  // 6. Release the blocked wake callback: the worker clears running_ outside
  //    its mutex and wakes this thread again.
  {
    std::lock_guard lock(gateMutex);
    releaseWake = true;
  }
  gateCondition.notify_all();

  // 7-8. The deferred construction then starts and completes EXACTLY ONCE:
  //      no two residency operations at any time, a wake after the slot
  //      freed, both completions retained and the domain back in this Owner
  //      interval with one ReadyEvent for the whole life.
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Ready;
  }, "the deferred recovery never started once the slot freed");
  require(buildRuns.load() == 1 && disposeRuns.load() == 1 &&
              maxLiveOperations.load() == 1 && wakeCalls.load() >= 2 &&
              RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) == 2 &&
              RuntimeBootstrapTestAccess::holder(bootstrap) ==
                  ResourceDomainAuthority::Holder::Owner &&
              readyEventCount(harness.output) == 1,
          "the deferred operation did not complete exactly once with its "
          "authority returned and no concurrent residency operation");
  std::cout << "PASS worker-slot race: deferral before any transfer, terminal "
               "wake, no stranded handoff\n";
}

// ---- [T026] terminal Shutdown over the live states + late power ----

// shutdownLifecycle() supersedes Suspended and Recovering (Draining is proven
// by testResidencyWorkerIsSingleAndSerial): it is terminal, mints its own
// revision, a running worker's cooperative cancel sees it, and its landed
// completion is claimed and retained WITHOUT becoming residency. A LATER
// power observation is never consumed after a terminal intent: no new
// recovery worker starts, no candidate is adopted, and inference readiness
// is never minted again.
void testShutdownClosesReadyAdmissionImmediately() {
  const test::TemporaryDirectory root("splash-shutdown-ready");
  LifecycleHarness harness(root.path());
  auto &bootstrap = *harness.bootstrap;
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap, [&] { return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Ready; }, "did not reach Ready");
  require(bootstrap.nativeLoop().hasEngine() && bootstrap.nativeLoop().admissionOpen(), "Ready did not have open admission");
  const auto revision = RuntimeBootstrapTestAccess::revision(bootstrap);
  require(bootstrap.shutdownLifecycle(), "Ready shutdown refused");
  require(!bootstrap.nativeLoop().admissionOpen() &&
              RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown &&
              RuntimeBootstrapTestAccess::revision(bootstrap) == revision + 1 &&
              !bootstrap.lifecycleStatus().inferenceReady,
          "shutdown did not immediately close admission");
  require(!bootstrap.shutdownLifecycle() && RuntimeBootstrapTestAccess::revision(bootstrap) == revision + 1,
          "repeated shutdown changed terminal revision");
  for (auto power : {LifecyclePower::AC, LifecyclePower::Battery, LifecyclePower::Unknown}) {
    bootstrap.observePower(power);
    static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
    require(!bootstrap.nativeLoop().admissionOpen() &&
                RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown &&
                RuntimeBootstrapTestAccess::revision(bootstrap) == revision + 1 &&
                !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap) &&
                readyEventCount(harness.output) == 1,
            "power observation revived shutdown");
  }
}

void testShutdownSupersedesSuspendedAndRecovering() {
  // (a) Suspended, then a late AC observation.
  {
    const test::TemporaryDirectory root("splash-native-lifecycle-shutdown-suspended");
    LifecycleHarness harness(root.path());
    RuntimeBootstrap &bootstrap = *harness.bootstrap;
    std::atomic<int> disposeRuns{0};
    std::atomic<int> buildRuns{0};
    RuntimeBootstrapTestAccess::installWorkerSeams(
        bootstrap,
        [&](const WorkerCancellation &) -> DisposalReceipt {
          ++disposeRuns;
          DisposalReceipt receipt;
          receipt.complete = true;
          return receipt;
        },
        [&](const WorkerCancellation &) -> std::unique_ptr<RecoveryCandidate> {
          ++buildRuns;
          auto candidate = std::make_unique<RecoveryCandidate>();
          candidate->lifecycleRevision = 0;
          return candidate;
        },
        [](const RecoveryCandidate &) { return true; });

    bootstrap.observePower(LifecyclePower::AC);
    pumpUntil(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Ready;
    }, "did not reach Ready");
    bootstrap.observePower(LifecyclePower::Battery);
    pumpUntil(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended;
    }, "did not suspend");
    require(disposeRuns.load() == 1, "the suspension disposal never ran");

    const uint64_t atShutdown = RuntimeBootstrapTestAccess::revision(bootstrap);
    require(bootstrap.shutdownLifecycle(), "shutdown from Suspended was refused");
    require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown &&
                RuntimeBootstrapTestAccess::revision(bootstrap) == atShutdown + 1 &&
                !RuntimeBootstrapTestAccess::pumpModelResident(bootstrap),
            "shutdown did not supersede Suspended with its own terminal revision");

    bootstrap.observePower(LifecyclePower::AC);
    for (int step = 0; step < 4; ++step)
      static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
    require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown &&
                buildRuns.load() == 0 &&
                !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap) &&
                RuntimeBootstrapTestAccess::revision(bootstrap) == atShutdown + 1 &&
                !bootstrap.lifecycleStatus().inferenceReady &&
                !bootstrap.nativeLoop().admissionOpen() &&
                RuntimeBootstrapTestAccess::holder(bootstrap) ==
                    ResourceDomainAuthority::Holder::Owner &&
                readyEventCount(harness.output) == 1,
            "a late AC observation revived a shutdown lifecycle, started a "
            "worker or reopened readiness");
  }

  // (b) Recovering with a construction in flight: shutdown invalidates the
  //     intent, the candidate never becomes residency and no later intent
  //     starts a second construction.
  {
    const test::TemporaryDirectory root("splash-native-lifecycle-shutdown-recovering");
    LifecycleHarness harness(root.path());
    RuntimeBootstrap &bootstrap = *harness.bootstrap;
    std::atomic<bool> enterBuild{false};
    std::atomic<bool> releaseBuild{false};
    std::atomic<bool> sawCancelled{false};
    std::atomic<int> buildRuns{0};
    std::atomic<int> adoptRuns{0};
    RuntimeBootstrapTestAccess::installWorkerSeams(
        bootstrap,
        [](const WorkerCancellation &) -> DisposalReceipt {
          DisposalReceipt receipt;
          receipt.complete = true;
          return receipt;
        },
        [&](const WorkerCancellation &cancelled) -> std::unique_ptr<RecoveryCandidate> {
          ++buildRuns;
          enterBuild = true;
          while (!releaseBuild.load() && !cancelled())
            std::this_thread::yield();
          if (cancelled())
            sawCancelled = true;
          auto candidate = std::make_unique<RecoveryCandidate>();
          candidate->lifecycleRevision = 0;
          return candidate;
        },
        [&](const RecoveryCandidate &) {
          ++adoptRuns;
          return true;
        });

    bootstrap.observePower(LifecyclePower::AC);
    pumpUntil(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Ready;
    }, "did not reach Ready");
    bootstrap.observePower(LifecyclePower::Battery);
    pumpUntil(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended;
    }, "did not suspend");
    bootstrap.observePower(LifecyclePower::AC);
    pumpUntil(bootstrap, [&] { return enterBuild.load(); },
              "the recovery construction never started");
    require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Recovering &&
                RuntimeBootstrapTestAccess::workerRunning(bootstrap),
            "the in-flight construction is not Recovering over a running worker");

    const auto revision = RuntimeBootstrapTestAccess::revision(bootstrap);
    require(bootstrap.shutdownLifecycle(), "shutdown during Recovering was refused");
    require(RuntimeBootstrapTestAccess::revision(bootstrap) == revision + 1 && !bootstrap.nativeLoop().admissionOpen(), "construction shutdown did not fence admission");
    require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown,
            "shutdown did not supersede Recovering");
    releaseBuild = true;
    pumpUntil(bootstrap, [&] {
      return !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
             RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) >= 2;
    }, "the shutdown-cancelled construction never published and landed");
    require(sawCancelled.load() && adoptRuns.load() == 0 &&
                !RuntimeBootstrapTestAccess::pumpModelResident(bootstrap) &&
                RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown &&
                ResourceDomainAuthority::Holder::Owner ==
                    RuntimeBootstrapTestAccess::holder(bootstrap),
            "a shutdown-superseded candidate was published, or the authority "
            "was stranded");

    bootstrap.observePower(LifecyclePower::AC);
    pumpUntil(bootstrap, [&] { return true; }, "no-op safe point");
    require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown &&
                buildRuns.load() == 1 && adoptRuns.load() == 0 &&
                !bootstrap.lifecycleStatus().inferenceReady && !bootstrap.nativeLoop().admissionOpen(),
            "a late power observation after shutdown resumed recovery");
  }
  std::cout << "PASS terminal shutdown: supersedes Suspended/Recovering, and late "
               "power never reopens inference\n";
}

// ---- [T029 Gate A / T032 Gates B-D] the cold candidate's OWN authority,
// the stale-candidate reaper, and shutdown around it ----

// A private candidate's Engine events go nowhere: nothing a fixture builds
// serves, and this package never publishes one into the loop.
struct CandidateSink final : engine::EngineEventSink {
  void batchCompleted(WorkKind, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                      double, double) override {}
  void started(uint64_t, uint32_t, uint32_t) override {}
  void tokens(uint64_t, std::span<const uint32_t>) override {}
  void maskRequested(uint64_t, std::span<const uint32_t>) override {}
  void completed(uint64_t, EngineFinishReason, bool, uint32_t, uint32_t, uint32_t,
                 std::span<const float>, const SpeculativeCounts &) override {}
  void failed(uint64_t, LaneOutcome, std::string, uint32_t) override {}
};

[[nodiscard]] std::string threadNameOf(std::thread::id id) {
  std::ostringstream out;
  out << id;
  return out.str();
}

// One real candidate the construction seam assembled, with the evidence about
// the thread and graph that assembled it. The zero-byte governor admission is a
// GATED operation: performing it on the seam thread is what proves that thread
// holds the fresh graph's Owner interval at assembly time; the same call from
// any other thread is expected to be refused.
EngineConfig fixtureEngineConfig(RuntimeResources &graph, EngineConfig config) {
  config = test::engineConfig(config);
  connectToGovernor(config, graph.memoryGovernor());
  return config;
}

struct ColdBuild final {
  std::filesystem::path root;
  bool withEngine = false;
  std::thread::id controlThread = std::this_thread::get_id();
  std::thread::id buildThread = std::thread::id();
  std::atomic<bool> assemblyHeldOwner{false};
  std::atomic<int> builds{0};
  std::atomic<int> liveOperations{0};
  std::atomic<int> maxLiveOperations{0};
  std::atomic<bool> enterBuild{false};
  std::atomic<bool> releaseBuild{false};
  std::atomic<bool> gatesBuild{false};
  RuntimeResources *graph = nullptr;
  engine::Engine *engine = nullptr;
  CandidateSink sink;

  explicit ColdBuild(const std::filesystem::path &rootPath, bool buildEngine)
      : root(rootPath), withEngine(buildEngine) {}

  std::unique_ptr<RecoveryCandidate> operator()(
      const WorkerCancellation &cancelled) {
    ++builds;
    const int live = ++liveOperations;
    maxLiveOperations = std::max(maxLiveOperations.load(), live);
    buildThread = std::this_thread::get_id();
    enterBuild = true;
    while (gatesBuild.load() && !releaseBuild.load() && !cancelled())
      std::this_thread::yield();
    auto resources = RuntimeResources::create(lifecycleConfig(root).resources, 0);
    graph = resources.get();
    // A gated ledger operation on the graph's own governor: the reservation is
    // admitted only while THIS thread holds the fresh lease's Owner interval.
    try {
      assemblyHeldOwner.store(static_cast<bool>(
          resources->memoryGovernor().allocationAdmission()(1, [] {})));
    } catch (const std::exception &) {
      assemblyHeldOwner.store(false);
    }
    auto candidate = std::make_unique<RecoveryCandidate>();
    candidate->resources = std::move(resources);
    if (withEngine) {
      const auto context = candidate->resources->modelContext();
      candidate->model = model::createRuntime(*context);
      candidate->engine = std::unique_ptr<engine::Engine>(
          new engine::Engine(
              fixtureEngineConfig(*candidate->resources, lifecycleConfig(root).nativeLoop.engine),
              candidate->resources->cache(), candidate->resources->writeBehind(),
              *candidate->model, sink));
      engine = candidate->engine.get();
    }
    candidate->lifecycleRevision = 0;
    --liveOperations;
    return candidate;
  }
};

// A cold control shell over the same synthetic model: started model-less with
// the battery policy's injected Battery observation, its output collected for
// the ReadyEvent count.
struct ColdShell final {
  std::vector<uint8_t> output;
  RuntimeMetrics metrics;
  std::unique_ptr<RuntimeBootstrap> bootstrap;

  explicit ColdShell(const std::filesystem::path &rootPath) {
    RuntimeBootstrapConfig config = lifecycleConfig(rootPath);

    config.initialPower = LifecyclePower::Battery;
    config.lifecycleWake = [] {};
    bootstrap = RuntimeBootstrap::startModelLess(
        std::move(config),
        [this](std::span<const uint8_t> bytes) {
          output.insert(output.end(), bytes.begin(), bytes.end());
        },
        [] { return std::string("{}"); });
  }
};

// The worker thread a reap's receipt names: after "thread ", up to the phase
// count bracket.
[[nodiscard]] std::string receiptThread(const std::string &detail) {
  const std::string marker = "destroyed on residency-worker thread ";
  const auto start = detail.find(marker);
  if (start == std::string::npos)
    return {};
  const auto end = detail.find(" [", start);
  return detail.substr(start + marker.size(),
                       end == std::string::npos
                           ? std::string::npos
                           : end - (start + marker.size()));
}

// The three allocation counts a reap's receipt reports, in order.
[[nodiscard]] std::vector<uint64_t> receiptPhases(const std::string &detail) {
  const auto open = detail.find("][");
  const auto close = detail.find(']', open == std::string::npos ? 0 : open + 2);
  if (open == std::string::npos || close == std::string::npos)
    return {};
  std::vector<uint64_t> phases;
  std::istringstream numbers(detail.substr(open + 2, close - open - 2));
  std::string phase;
  while (std::getline(numbers, phase, '>')) {
    const auto digits = phase.find_first_of("0123456789");
    if (digits == std::string::npos)
      continue;
    phases.push_back(std::stoull(phase.substr(digits)));
  }
  return phases;
}

// A warm candidate built by the construction seam: it borrows the RETAINED
// graph exactly (its Cache/KV/WriteBehind/backend stay the original objects) and
// owns only its own Engine and RuntimeModel of that graph.
struct WarmBuild final {
  RuntimeBootstrap &bootstrap;
  std::filesystem::path root;
  CandidateSink sink;
  std::atomic<int> builds{0};
  std::atomic<bool> enterBuild{false};
  std::atomic<bool> releaseBuild{false};
  std::atomic<bool> gatesBuild{false};
  RuntimeResources *borrowed = nullptr;
  engine::Cache *cache = nullptr;
  WriteBehind *writeBehind = nullptr;
  model::RuntimeModel *model = nullptr;
  engine::Engine *engine = nullptr;
  std::thread::id buildThread = std::thread::id();

  explicit WarmBuild(RuntimeBootstrap &loop,
                     const std::filesystem::path &rootPath)
      : bootstrap(loop), root(rootPath) {}

  std::unique_ptr<RecoveryCandidate> operator()(
      const WorkerCancellation &cancelled) {
    ++builds;
    buildThread = std::this_thread::get_id();
    enterBuild = true;
    while (gatesBuild.load() && !releaseBuild.load() && !cancelled())
      std::this_thread::yield();
    auto candidate = std::make_unique<RecoveryCandidate>();
    // The warm relationship: the ORIGINAL retained graph, never a replacement.
    candidate->borrowedResources = &bootstrap.resources();
    borrowed = candidate->borrowedResources;
    cache = &bootstrap.resources().cache();
    writeBehind = &bootstrap.resources().writeBehind();
    const auto context = bootstrap.resources().modelContext();
    candidate->model = model::createRuntime(*context);
    model = candidate->model.get();
    candidate->engine = std::unique_ptr<engine::Engine>(
        new engine::Engine(fixtureEngineConfig(bootstrap.resources(), lifecycleConfig(root).nativeLoop.engine),
                           bootstrap.resources().cache(),
                           bootstrap.resources().writeBehind(),
                           *candidate->model, sink));
    engine = candidate->engine.get();
    candidate->lifecycleRevision = 0;
    return candidate;
  }
};

// [T029 Gate A] A cold candidate carries its OWN authority: assembled by the
// construction thread under its own Owner interval, transferred to that worker
// under ITS OWN four witnesses, claimed and parked there, and returned by the
// native lifecycle Owner to exactly THAT candidate's lease. Each witness
// category standing alone refuses the transfer, and a refused candidate is
// disposed of under its own lawful authority: the pump publishes a failure,
// never a resource-owning candidate lacking its mandatory token.
void testColdCandidateOwnAuthorityOnItsOwnLease() {
  // 1-4. One witness category refuses at a time; nothing is handed off.
  for (int refused = 0; refused < 4; ++refused) {
    const test::TemporaryDirectory root("splash-cold-authority-refusal");
    ColdShell shell(root.path());
    ColdBuild build(root.path(), true);
    RuntimeBootstrapTestAccess::installWorkerSeams(
        *shell.bootstrap, nullptr,
        [&build](const WorkerCancellation &cancelled) {
          return build(cancelled);
        },
        nullptr);
    RuntimeBootstrapTestAccess::installCandidateWitnesses(
        *shell.bootstrap,
        [refused](ResourceDomainLease &lease, RecoveryCandidate &) {
          lease.setAdmissionWitness([refused] { return refused != 0; });
          lease.setRequestDrainWitness([refused] { return refused != 1; });
          lease.setRetainedIoWitness([refused] { return refused != 2; });
          lease.setCallbackRetirementWitness([refused] { return refused != 3; });
        });
    shell.bootstrap->observePower(LifecyclePower::AC);
    pumpReal(*shell.bootstrap,
              [&] {
                return RuntimeBootstrapTestAccess::state(*shell.bootstrap) ==
                       LifecycleState::RecoveryFailed;
              },
              "a refused cold construction never landed a failure");
    require(build.builds.load() == 1 && build.assemblyHeldOwner.load() &&
                build.buildThread != std::this_thread::get_id(),
            "the cold candidate was not assembled by the construction thread "
            "under its own Owner interval");
    require(shell.bootstrap->lifecycleStatus().lastError.find(
                "refused quiescence") != std::string::npos,
            "the refusal by candidate witness category " +
                std::to_string(refused) + " recorded no failure");
    require(RuntimeBootstrapTestAccess::pendingReaps(*shell.bootstrap) == 0 &&
                RuntimeBootstrapTestAccess::pendingEnvelopes(*shell.bootstrap) ==
                    1,
            "the refused candidate was neither disposed under its own authority "
            "nor retained as exactly one failed completion");
    require(readyEventCount(shell.output) == 1 &&
                !shell.bootstrap->nativeLoop().admissionOpen(),
            "a refused cold construction reopened inference readiness");
    // The candidate died under its own Owner interval, so its lease ended
    // lawfully: teardown of this shell asserts nothing about a stranded
    // Worker/Parked interval.
    static_cast<void>(shell.bootstrap->shutdownLifecycle());
    shell.bootstrap.reset();
  }

  // 5. All four categories retire: the production witnesses read the candidate
  //    graph's OWN Engine and Cache, the transfer happens on the construction
  //    thread, and the Owner returns exactly that token to that graph.
  const test::TemporaryDirectory root("splash-cold-authority-ready");
  ColdShell shell(root.path());
  ColdBuild build(root.path(), true);
  RuntimeBootstrapTestAccess::installWorkerSeams(
      *shell.bootstrap, nullptr,
      [&build](const WorkerCancellation &cancelled) { return build(cancelled); },
      nullptr);
  shell.bootstrap->observePower(LifecyclePower::AC);
  // Take safe points only until the construction is STARTED, then poll for its
  // publication WITHOUT another safe point: only this thread claims, so the
  // envelope below is stored, unclaimed, and its token parked.
  pumpReal(*shell.bootstrap,
           [&] {
             return RuntimeBootstrapTestAccess::pumpOperationStarted(
                 *shell.bootstrap);
           },
           "the cold construction never started");
  waitPublished(*shell.bootstrap);
  require(RuntimeBootstrapTestAccess::channelHeld(*shell.bootstrap),
          "the published cold completion was claimed before this thread fenced "
          "it");
  RuntimeResources *graph = build.graph;
  require(graph != nullptr && build.graph == graph && build.engine != nullptr &&
              build.assemblyHeldOwner.load() &&
              build.buildThread != std::this_thread::get_id(),
          "the candidate graph was not created on the construction thread");
  require(graph->resourceAuthority().holder() ==
              ResourceDomainAuthority::Holder::Parked,
          "the candidate's authority did not reach the claimed Worker's parked "
          "interval at publication");
  int refusals = 0;
  try {
    static_cast<void>(graph->memoryGovernor().allocationAdmission()(1, [] {}));
  } catch (const metal::MetalBackendError &) {
    refusals = 1;
  }
  require(refusals == 1,
          "an unauthorized thread was allowed to mutate the candidate's parked "
          "domain");
  require(readyEventCount(shell.output) == 1 &&
              !shell.bootstrap->nativeLoop().admissionOpen(),
          "the cold handoff opened native inference or re-announced readiness");
  // The Owner claims it now: its token goes back to the CANDIDATE's graph.
  pumpReal(*shell.bootstrap,
            [&] {
              return RuntimeBootstrapTestAccess::state(*shell.bootstrap) ==
                     LifecycleState::RecoveryFailed;
            },
            "the construction-seam candidate never reached the explicit refusal");
  require(graph->resourceAuthority().holder() ==
              ResourceDomainAuthority::Holder::Owner,
          "the native lifecycle Owner did not return the token to the candidate's "
          "own graph");
  require(RuntimeBootstrapTestAccess::pendingReaps(*shell.bootstrap) == 1 &&
              RuntimeBootstrapTestAccess::pendingEnvelopes(*shell.bootstrap) ==
                  0,
          "the candidate's ownership did not move to the reap queue");
  require(shell.bootstrap->lifecycleStatus().lastError.find("construction-seam candidate") !=
              std::string::npos,
          "the construction-seam candidate recorded no explicit adoption refusal");
  // The mid-lifecycle reaper (T032) resolves this candidate in the next test;
  // here teardown is the last-resort path, which must say so out loud.
  const std::string teardown = test::capturedStderr([&] {
    static_cast<void>(shell.bootstrap->shutdownLifecycle());
    shell.bootstrap.reset();
  });
  require(teardown.find("Shutdown resolves a retained recovery candidate") !=
              std::string::npos,
          "teardown did not log the lawful disposal of the retained candidate");
  std::cout << "PASS cold candidate: own graph's Owner on its construction thread, "
               "four independent refusals, own-token handoff and Owner return\n";
}

// [T032 Gate B] A candidate whose revision the pump found stale AFTER its
// construction had already published (a newer Battery observation landed in the
// same safe-point window) is never adopted: its ownership moves to the ONE
// reaper, no construction runs concurrently, nothing physical dies under
// lifecycleMutex_, and the deletion finishes under the candidate's own lawful
// graph authority — the candidate's lease Owner interval on this thread is what
// the reaper transfers, and its graph is gone before teardown is reached.
void testStaleCandidateIsReapedByTheOneReaper() {
  const test::TemporaryDirectory root("splash-cold-stale-reap");
  ColdShell shell(root.path());
  ColdBuild build(root.path(), true);
  std::atomic<int> adopts{0};
  RuntimeBootstrapTestAccess::installWorkerSeams(
      *shell.bootstrap, nullptr,
      [&build](const WorkerCancellation &cancelled) { return build(cancelled); },
      [&adopts](const RecoveryCandidate &) {
        ++adopts;
        return true;
      });
  // The candidate is allowed to PUBLISH COMPLETE — its token parked, its
  // completion unclaimed — and only THEN does the newer Battery intent arrive,
  // which is what makes it stale at the claim rather than cancelling it on the
  // worker.
  shell.bootstrap->observePower(LifecyclePower::AC);
  pumpReal(*shell.bootstrap,
           [&] {
             return RuntimeBootstrapTestAccess::pumpOperationStarted(
                 *shell.bootstrap);
           },
           "the cold construction never started");
  waitPublished(*shell.bootstrap);
  shell.bootstrap->observePower(LifecyclePower::Battery);
  pumpReal(*shell.bootstrap,
           [&] {
             return RuntimeBootstrapTestAccess::state(*shell.bootstrap) ==
                    LifecycleState::Suspended;
           },
           "the published candidate for the superseded intent did not land");
  RuntimeResources *graph = build.graph;
  require(adopts.load() == 0 && RuntimeBootstrapTestAccess::revision(*shell.bootstrap) >=
                      1,
          "a stale candidate was adopted, or its revision was never fenced");
  require(RuntimeBootstrapTestAccess::pendingReaps(*shell.bootstrap) == 1 &&
              !RuntimeBootstrapTestAccess::reapInFlight(*shell.bootstrap),
          "the stale ownership was not queued for the one reaper at that safe point");
  require(graph->resourceAuthority().holder() ==
              ResourceDomainAuthority::Holder::Owner,
          "the stale candidate's graph was not an Owner interval for the reap to "
          "transfer on this thread");
  require(build.builds.load() == 1 && build.maxLiveOperations.load() == 1,
          "another construction ran while the reap was scheduled");
  // The reap: this ONE worker, on the candidate's own transferred domain.
  pumpReal(*shell.bootstrap,
            [&] {
              return RuntimeBootstrapTestAccess::pendingEnvelopes(*shell.bootstrap) >=
                       1;
            },
            "the delegated reap never completed");
  const std::string detail = RuntimeBootstrapTestAccess::lastDisposalDetail(*shell.bootstrap);
  require(detail.find("cold candidate stratum destroyed on residency-worker thread") !=
              std::string::npos,
          "the cold reap reported no candidate destruction");
  const std::string worker = receiptThread(detail);
  require(!worker.empty() && worker == threadNameOf(build.buildThread) &&
              worker != threadNameOf(std::this_thread::get_id()),
          "the candidate was not deleted on the residency-worker thread");
  const auto phases = receiptPhases(detail);
  require(phases.size() == 3 && phases[1] <= phases[0] && phases[2] <= phases[1],
          "the reap receipt did not report the Engine-then-model allocation phases");
  require(RuntimeBootstrapTestAccess::pendingReaps(*shell.bootstrap) == 0 &&
              !RuntimeBootstrapTestAccess::reapInFlight(*shell.bootstrap) &&
              RuntimeBootstrapTestAccess::pendingEnvelopes(*shell.bootstrap) == 1,
          "the reap queue did not drain with its receipt retained");
  require(adopts.load() == 0 && readyEventCount(shell.output) == 1 &&
              !shell.bootstrap->nativeLoop().admissionOpen(),
          "reaping published, announced or reopened anything");
  // Teardown has NOTHING left to dispose: the mid-lifecycle reaper resolved it.
  const std::string teardown = test::capturedStderr([&] {
    static_cast<void>(shell.bootstrap->shutdownLifecycle());
    shell.bootstrap.reset();
  });
  require(teardown.find("Shutdown resolves a retained recovery candidate") ==
              std::string::npos,
          "the reaper left the candidate for teardown instead of reaping it "
          "mid-lifecycle");
  std::cout << "PASS stale candidate: queued for the ONE reaper, no concurrent "
               "construction, deleted under its own graph authority off the safe "
               "point\n";
}

// [T032 Gate C] Cold and warm disposal, in the mandatory order, on the worker.
// A cold candidate dies Engine -> RuntimeModel -> (private residency) -> its
// OWN RuntimeResources, with its lease ending an Owner interval on the reap
// thread before its graph goes. A warm candidate dies Engine -> RuntimeModel
// while the retained graph it borrowed keeps every address and stays servable.
void testReaperDisposesColdAndWarmCandidatesInOrder() {
  // 1. Cold, with an Engine and a RuntimeModel of its own.
  {
    const test::TemporaryDirectory root("splash-reap-cold-order");
    ColdShell shell(root.path());
    ColdBuild build(root.path(), true);
    RuntimeBootstrapTestAccess::installWorkerSeams(
        *shell.bootstrap, nullptr,
        [&build](const WorkerCancellation &cancelled) { return build(cancelled); },
        [](const RecoveryCandidate &) { return true; });
    shell.bootstrap->observePower(LifecyclePower::AC);
    pumpReal(*shell.bootstrap,
             [&] {
               return RuntimeBootstrapTestAccess::pumpOperationStarted(*shell.bootstrap);
             },
             "the cold construction never started");
    waitPublished(*shell.bootstrap);
    shell.bootstrap->observePower(LifecyclePower::Battery);
    pumpReal(*shell.bootstrap,
             [&] {
               return RuntimeBootstrapTestAccess::pendingReaps(*shell.bootstrap) >= 1;
             },
             "the cold candidate was not queued for reaping");
    auto *graph = build.graph;
    require(build.engine != nullptr && build.graph != nullptr,
            "the cold candidate carried no Engine/graph to dispose in order");
    require(graph->resourceAuthority().holder() ==
                ResourceDomainAuthority::Holder::Owner,
            "the cold reap would not transfer an Owner interval of the candidate's "
            "own graph");
    pumpReal(*shell.bootstrap,
              [&] {
                return RuntimeBootstrapTestAccess::pendingEnvelopes(*shell.bootstrap) >= 1;
              },
              "the cold reap never completed");
    const std::string detail =
        RuntimeBootstrapTestAccess::lastDisposalDetail(*shell.bootstrap);
    require(detail.find("cold candidate stratum destroyed on residency-worker thread") !=
                std::string::npos,
            "the cold receipt did not name the cold candidate disposal");
    require(detail.find("-> candidate-owned RuntimeResources]") != std::string::npos,
            "the cold receipt did not report the candidate-owned graph phase");
    const auto phases = receiptPhases(detail);
    require(phases.size() == 3 && phases[1] <= phases[0] && phases[2] <= phases[1],
            "the cold phases did not show the Engine dying before the model and "
            "the graph");
    require(receiptThread(detail) == threadNameOf(build.buildThread) &&
                !RuntimeBootstrapTestAccess::reapInFlight(*shell.bootstrap) &&
                RuntimeBootstrapTestAccess::pendingReaps(*shell.bootstrap) == 0,
            "the cold candidate was not reaped on the worker's own authority");
    const std::string teardown = test::capturedStderr([&] {
      static_cast<void>(shell.bootstrap->shutdownLifecycle());
      shell.bootstrap.reset();
    });
    require(teardown.find("Shutdown resolves a retained recovery candidate") ==
                std::string::npos,
            "the cold reaper left ownership for teardown");
  }

  // 2. Warm: the retained graph is untouched by the candidate's disposal.
  {
    const test::TemporaryDirectory root("splash-reap-warm-order");
    LifecycleHarness harness(root.path());
    RuntimeBootstrap &bootstrap = *harness.bootstrap;
    WarmBuild build(bootstrap, root.path());
    std::atomic<int> adopts{0};
    RuntimeBootstrapTestAccess::installWorkerSeams(
        bootstrap,
        [](const WorkerCancellation &) -> DisposalReceipt {
          DisposalReceipt receipt;
          receipt.complete = true;
          return receipt;
        },
        [&build](const WorkerCancellation &cancelled) { return build(cancelled); },
        [&adopts](const RecoveryCandidate &) {
          ++adopts;
          return true;
        });
    // Suspend (a seam-held drain keeps the stratum published), then let an
    // AC construction build the warm candidate and be superseded before its
    // completion is claimed.
    bootstrap.observePower(LifecyclePower::Battery);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::state(bootstrap) ==
             LifecycleState::Suspended;
    }, "the suspension never completed");
    bootstrap.observePower(LifecyclePower::AC);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap);
    }, "the warm construction never started");
    waitPublished(bootstrap);
    bootstrap.observePower(LifecyclePower::Battery);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) >= 1;
    }, "the warm candidate was not queued for reaping");
    RuntimeResources *retained = &bootstrap.resources();
    const auto *retainedCache = build.cache;
    const auto *retainedWriteBehind = build.writeBehind;
    require(build.borrowed == retained,
            "the warm candidate did not borrow this Bootstrap's retained graph");
    require(RuntimeBootstrapTestAccess::holder(bootstrap) ==
                ResourceDomainAuthority::Holder::Owner,
            "the retained graph was not an Owner interval for the warm reap");
    // The seam-held suspension receipt is already retained here: the reap's own
    // completion is the SECOND.
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) >= 2 &&
             RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 0;
    }, "the warm reap never completed");
    const std::string detail = RuntimeBootstrapTestAccess::lastDisposalDetail(bootstrap);
    require(detail.find("warm candidate stratum destroyed on residency-worker thread") !=
                std::string::npos,
            "the warm reap reported no candidate destruction");
    require(receiptThread(detail) == threadNameOf(build.buildThread) &&
                receiptThread(detail) != threadNameOf(std::this_thread::get_id()),
            "the warm candidate was not destroyed on the residency worker");
    const auto warmPhases = receiptPhases(detail);
    require(warmPhases.size() == 3 && warmPhases[1] <= warmPhases[0] &&
                warmPhases[2] <= warmPhases[1],
            "the warm receipt did not report the Engine-then-model phases");

    // The borrowed graph: every address, the residency and the published Engine
    // exactly as before, and its own lease back in this Owner interval.
    require(&bootstrap.resources() == retained &&
                &bootstrap.resources().cache() == retainedCache &&
                &bootstrap.resources().writeBehind() == retainedWriteBehind &&
                bootstrap.hasModelRuntime() && bootstrap.resources().modelResident() &&
                bootstrap.nativeLoop().hasEngine() &&
                bootstrap.resources().backend().healthy(),
            "the candidate's disposal disturbed the retained graph it borrowed");
    require(RuntimeBootstrapTestAccess::holder(bootstrap) ==
                ResourceDomainAuthority::Holder::Owner,
            "the warm reap did not return its token to the retained graph");
    require(adopts.load() == 0 && RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 0,
            "a warm candidate was adopted or left queued");
    const std::string teardown = test::capturedStderr([&] { harness.bootstrap.reset(); });
    require(teardown.find("Shutdown resolves a retained recovery candidate") ==
                std::string::npos,
            "the warm reaper left ownership for teardown");
  }
  std::cout << "PASS reaper order: cold Engine -> model -> own graph on the reap "
               "thread; warm Engine -> model while the borrowed graph survives\n";
}

// [T032 Gate D] Shutdown and reaping. A candidate queued for reaping at
// Shutdown is disposed of lawfully by teardown (never a stranded token, never
// the borrowed graph before the candidate that borrows it, never a reopened
// admission), and an ordinary safe point never joins an active reap: it defers,
// while the parked token of the domain the reap ran on comes back intact.
void testShutdownClaimsPublishedWarmCandidate() {
  const test::TemporaryDirectory root("splash-shutdown-published");
  LifecycleHarness harness(root.path());
  auto &bootstrap = *harness.bootstrap;
  auto *graph = &bootstrap.resources();
  WarmBuild build(bootstrap, root.path());
  RuntimeBootstrapTestAccess::installWorkerSeams(
      bootstrap, [](const WorkerCancellation &) { DisposalReceipt receipt; receipt.complete = true; return receipt; },
      [&build](const WorkerCancellation &cancelled) { return build(cancelled); }, nullptr);
  bootstrap.observePower(LifecyclePower::Battery);
  pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended; }, "suspension failed");
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap); }, "construction did not start");
  waitPublished(bootstrap);
  const auto revision = RuntimeBootstrapTestAccess::revision(bootstrap);
  require(bootstrap.shutdownLifecycle(), "published candidate shutdown refused");
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
  require(RuntimeBootstrapTestAccess::revision(bootstrap) == revision + 1 &&
              RuntimeBootstrapTestAccess::holder(bootstrap) == ResourceDomainAuthority::Holder::Owner &&
              &bootstrap.resources() == graph && candidate && candidate->engine && candidate->model &&
              candidate->borrowedResources == graph && !bootstrap.nativeLoop().admissionOpen() &&
              !bootstrap.lifecycleStatus().inferenceReady && readyEventCount(harness.output) == 1,
          "terminal completion did not return authority and retain candidate");
  const std::string teardown = test::capturedStderr([&] { harness.bootstrap.reset(); });
  require(teardown.find("Shutdown resolves a retained recovery candidate") != std::string::npos,
          "teardown did not dispose published candidate");
}

void testShutdownAroundTheReaper() {
  // (a) Shutdown with the reap still queued: terminal Shutdown starts no new
  //     operation, and teardown ends the candidate's ownership before the
  //     retained dependencies it borrows are stopped.
  {
    const test::TemporaryDirectory root("splash-reap-shutdown-queued");
    LifecycleHarness harness(root.path());
    RuntimeBootstrap &bootstrap = *harness.bootstrap;
    WarmBuild build(bootstrap, root.path());
    RuntimeBootstrapTestAccess::installWorkerSeams(
        bootstrap,
        [](const WorkerCancellation &) -> DisposalReceipt {
          DisposalReceipt receipt;
          receipt.complete = true;
          return receipt;
        },
        [&build](const WorkerCancellation &cancelled) { return build(cancelled); },
        nullptr);
    bootstrap.observePower(LifecyclePower::Battery);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::state(bootstrap) ==
             LifecycleState::Suspended;
    }, "the suspension never completed");
    bootstrap.observePower(LifecyclePower::AC);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap);
    }, "the warm construction never started");
    waitPublished(bootstrap);
    bootstrap.observePower(LifecyclePower::Battery);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) >= 1;
    }, "the warm candidate was not queued for reaping");
    static_cast<void>(bootstrap.shutdownLifecycle());
    for (int step = 0; step < 4; ++step)
      static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
    require(RuntimeBootstrapTestAccess::state(bootstrap) ==
                LifecycleState::Shutdown &&
                !RuntimeBootstrapTestAccess::reapInFlight(bootstrap) &&
                !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap) &&
                RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1 &&
                RuntimeBootstrapTestAccess::holder(bootstrap) ==
                    ResourceDomainAuthority::Holder::Owner &&
                !bootstrap.nativeLoop().admissionOpen() &&
                readyEventCount(harness.output) == 1,
            "Shutdown after a queued reap started an operation, stranded a token "
            "or reopened readiness");
    // Teardown disposes the queued candidate BEFORE the retained backend stops.
    const std::string teardown = test::capturedStderr([&] {
      harness.bootstrap.reset();
    });
    require(teardown.find("Shutdown resolves a retained recovery candidate") !=
                std::string::npos,
            "teardown did not report the lawful disposal of the queued candidate");
  }

  // (b) A safe point never joins a reap whose completion has published while
  //     its worker still holds the domain: the pass defers, the parked token
  //     comes back to the retained graph, and no second operation starts.
  {
    const test::TemporaryDirectory root("splash-reap-shutdown-running");
    LifecycleHarness harness(root.path());
    RuntimeBootstrap &bootstrap = *harness.bootstrap;
    WarmBuild build(bootstrap, root.path());
    RuntimeBootstrapTestAccess::installWorkerSeams(
        bootstrap,
        [](const WorkerCancellation &) -> DisposalReceipt {
          DisposalReceipt receipt;
          receipt.complete = true;
          return receipt;
        },
        [&build](const WorkerCancellation &cancelled) { return build(cancelled); },
        nullptr);
    std::mutex gateMutex;
    std::condition_variable gateCondition;
    std::atomic<bool> wakeEntered{false};
    std::atomic<bool> releaseWake{false};
    std::atomic<bool> armWakeGate{false};
    std::atomic<bool> gatedWake{false};
    std::atomic<bool> callbackRetired{false};
    struct GateCleanup {
      std::atomic<bool> &release;
      std::condition_variable &condition;
      std::mutex &mutex;
      LifecycleHarness &harness;
      std::atomic<bool> &retired;
      ~GateCleanup() {
        const bool probe = gGateFailure.mode == "reap";
        if (probe) gGateFailure.unwinding = std::uncaught_exceptions() > 0;
        { std::lock_guard lock(mutex); release = true; }
        condition.notify_all();
        harness.bootstrap.reset();  // WarmBuild and gate captures still live.
        if (probe) {
          gGateFailure.released = release.load();
          gGateFailure.callbackRetired = retired.load();
          gGateFailure.joined = !harness.bootstrap;
        }
      }
    } cleanup{releaseWake, gateCondition, gateMutex, harness, callbackRetired};
    // Armed only once the reap is queued: the first wake after arming is the
    // reap's publication, and this thread stands inside it with the envelope
    // stored, the worker's frame open, and its token parked.
    RuntimeBootstrapTestAccess::setChannelWake(
        bootstrap, [&] {
          if (!armWakeGate.load() || gatedWake.exchange(true))
            return;
          std::unique_lock lock(gateMutex);
          wakeEntered = true;
          gateCondition.wait(lock, [&] { return releaseWake.load(); });
          callbackRetired = true;
        });
    bootstrap.observePower(LifecyclePower::Battery);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::state(bootstrap) ==
             LifecycleState::Suspended;
    }, "the suspension never completed");
    bootstrap.observePower(LifecyclePower::AC);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap);
    }, "the warm construction never started");
    waitPublished(bootstrap);
    bootstrap.observePower(LifecyclePower::Battery);
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) >= 1;
    }, "the warm candidate was not queued for reaping");
    // The reap is queued and not yet started: arm the gate, and the reap's
    // publication is the first wake this thread stands inside.
    armWakeGate = true;
    pumpReal(bootstrap, [&] { return wakeEntered.load(); },
              "the reap's publication never woke the control loop");
    injectBlockedGateFailure("reap", bootstrap, gateMutex, wakeEntered, releaseWake);
    require(RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
                RuntimeBootstrapTestAccess::holder(bootstrap) !=
                    ResourceDomainAuthority::Holder::Owner,
            "the reap cleared its slot before publishing, or the safe point held "
            "the domain the reap owns");
    for (int step = 0; step < 4; ++step)
      static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
    require(RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
                build.builds.load() == 1,
            "an ordinary safe point joined or restarted the running reap");
    {
      std::lock_guard lock(gateMutex);
      releaseWake = true;
    }
    gateCondition.notify_all();
    // The parked token returns to the RETAINED graph, and Shutdown from here
    // finds a reconciled domain.
    pumpReal(bootstrap, [&] {
      return RuntimeBootstrapTestAccess::pendingEnvelopes(bootstrap) >= 2;
    }, "the reap completion was never claimed");
    require(RuntimeBootstrapTestAccess::holder(bootstrap) ==
                ResourceDomainAuthority::Holder::Owner &&
                !RuntimeBootstrapTestAccess::reapInFlight(bootstrap) &&
                RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 0 &&
                bootstrap.nativeLoop().hasEngine() &&
                bootstrap.resources().backend().healthy(),
            "the reap stranded a token or disturbed the graph it ran on");
    static_cast<void>(bootstrap.shutdownLifecycle());
    static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
    require(RuntimeBootstrapTestAccess::state(bootstrap) ==
                LifecycleState::Shutdown,
            "Shutdown after a completed reap did not stay terminal");
  }
  std::cout << "PASS shutdown around reaping: queued candidates die lawfully at "
               "teardown, safe points never join a running reap, no token stranded\n";
}

}  // namespace

// [T031 prerequisite] Gate 2: the construction a residency worker runs in
// production for a SUSPENDED graph, with NO build seam installed anywhere. The
// candidate borrows this graph by identity and owns ONLY what the builder
// assembled: the private stratum the shared model-bound phase rebuilt against
// the retained graph (retained SSD readers, the already-open tier, no second
// backend/governor/Cache), a RuntimeModel over that stratum, and the loop's own
// private Engine. Nothing is published and no admission opens, so the absent
// adoption protocol keeps the pump at Recovering with the candidate retained
// for the reaper, no ReadyEvent is re-announced, no private capacity enters
// telemetry, and this graph is exactly as it was.
void testProductionWarmCandidateIsBuiltAgainstTheRetainedGraph() {
  const test::TemporaryDirectory root("splash-native-lifecycle-build");
  LifecycleHarness harness(root.path());
  RuntimeBootstrap &bootstrap = *harness.bootstrap;
  const auto identity = bootstrap.resources().cacheIdentity();
  auto *retainedGraph = &bootstrap.resources();
  auto *retainedCache = &retainedGraph->cache();
  auto *retainedWriteBehind = &retainedGraph->writeBehind();
  const uint32_t ceiling = bootstrap.lifecycleStatus().configuredContextCeiling;
  require(ceiling > 0 && bootstrap.nativeLoop().hasEngine() && bootstrap.hasModelRuntime(),
          "a started graph published no Engine, model or ceiling");
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended &&
           !bootstrap.nativeLoop().hasEngine() && !bootstrap.hasModelRuntime();
  }, "the production physical detach never completed");
  require(!bootstrap.resources().modelResident(), "the detach left a residency in the graph");
  const size_t readyEvents = readyEventCount(harness.output);

  // The production construction: no seam installed. The staging-boundary
  // Battery observation [T033] makes the intent land while the candidate is
  // staged: the final fence refuses, the transaction rolls back with the
  // candidate INTACT, and it goes to the ONE reaper's queue — this is what
  // the T031 prerequisite's construction looks like once the adoption
  // protocol EXISTS.
  uint64_t before = 0, after = 0;
  RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, [&] {
    before = RuntimeBootstrapTestAccess::powerGeneration(bootstrap);
    bootstrap.observePower(LifecyclePower::Battery);
    bootstrap.observePower(LifecyclePower::AC);
    after = RuntimeBootstrapTestAccess::powerGeneration(bootstrap);
  });
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1;
  }, "the production recovery construction landed no refused candidate");

  const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
  require(after == before + 2 && &bootstrap.resources() == retainedGraph &&
              &retainedGraph->cache() == retainedCache &&
              &retainedGraph->writeBehind() == retainedWriteBehind,
          "warm power fence lost observations or retained identities");
  require(candidate && candidate->ownsResidency() && !candidate->ownsResources(),
          "the production candidate owned a whole graph, or nothing at all");
  require(candidate->borrowedResources == &bootstrap.resources() &&
              candidate->authorityGraph() == &bootstrap.resources() &&
              candidate->resources == nullptr,
          "the warm candidate does not borrow exactly this retained graph");
  require(candidate->engine && candidate->model && candidate->residency,
          "the builder assembled no private Engine, model or stratum");
  require(candidate->engine->maxContextTokens() == ceiling &&
              candidate->engine->maxContextTokens() > 0,
          "the candidate Engine's window is not the context this start resolved");
  require(!bootstrap.nativeLoop().hasEngine() && !bootstrap.nativeLoop().admissionOpen(),
          "the private Engine was published, or admission reopened");
  require(readyEventCount(harness.output) == readyEvents &&
              !bootstrap.lifecycleStatus().effectiveContextTokens.has_value(),
          "the recovery re-announced Ready, or a private Engine entered telemetry");
  require(RuntimeBootstrapTestAccess::holder(bootstrap) ==
              ResourceDomainAuthority::Holder::Owner,
          "the construction did not return the retained domain to its Owner");
  require(bootstrap.resources().backend().healthy() &&
              bootstrap.resources().cacheIdentity() == identity &&
              !bootstrap.resources().modelResident(),
          "the production construction disturbed the retained graph");
  RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, {});
  pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::reapInFlight(bootstrap); },
           "refused warm candidate did not start reaping");
  require(!bootstrap.lifecycleStatus().inferenceReady &&
              RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended,
          "recovery overlapped the candidate reaper");
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
           "valid AC recovery after warm fence refusal failed");
  require(RuntimeBootstrapTestAccess::holder(bootstrap) == ResourceDomainAuthority::Holder::Owner &&
              readyEventCount(harness.output) == 1,
          "warm recovery lost authority or re-announced Ready");
  protocol::RequestFrame frame;
  frame.requestId = 904;
  frame.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
  frame.remainingDeadlineMicros = 60'000'000;
  frame.logicalMaxOutputTokens = 1;
  frame.promptTokens = {1, 2, 3};
  const auto completed = bootstrap.nativeLoop().snapshot().completed;
  require(bootstrap.nativeLoop().receive(protocol::peer::serialize(frame)), "warm request refused");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (std::chrono::steady_clock::now() < deadline && bootstrap.nativeLoop().snapshot().completed == completed) {
    static_cast<void>(bootstrap.nativeLoop().tick());
    std::this_thread::yield();
  }
  require(bootstrap.nativeLoop().snapshot().completed == completed + 1,
          "warm recovery did not complete a request");
}

// [T030] What a snapshot's capacity IS: the published Engine's exact window,
// never the ceiling this start captured. The AC graph reports the Engine's own
// number while it publishes one; the same graph after the safe point moved its
// Engine out claims no effective context at all while its STATIC ceiling keeps
// being advertised; and a candidate's private Engine -- built, retained,
// published nowhere -- is legible in no request telemetry.
void testEffectiveContextIsThePublishedEngineWindow() {
  const test::TemporaryDirectory root("splash-native-capacity");
  LifecycleHarness harness(root.path());
  RuntimeBootstrap &bootstrap = *harness.bootstrap;
  bootstrap.observePower(LifecyclePower::AC);
  pumpUntil(bootstrap, [&] {
    return bootstrap.lifecycleStatus().inferenceReady;
  }, "AC over the real graph never authorized inference");
  const auto published = bootstrap.nativeLoop().publishedContextTokens();
  const auto ready = bootstrap.lifecycleStatus();
  require(published.has_value() && *published > 0 &&
              ready.effectiveContextTokens == published &&
              *ready.effectiveContextTokens <= ready.configuredContextCeiling,
          "a Ready snapshot did not report the published Engine's own window");

  // The detach: Engine absent, ceiling still advertised, effective context
  // claimed by nothing.
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended &&
           !bootstrap.nativeLoop().hasEngine();
  }, "the Engine was never detached");
  const auto detached = bootstrap.lifecycleStatus();
  require(!bootstrap.nativeLoop().publishedContextTokens().has_value() &&
              !detached.effectiveContextTokens.has_value() && !detached.inferenceReady &&
              detached.configuredContextCeiling == ready.configuredContextCeiling,
          "an Engine-absent graph claimed a capacity or lost its ceiling");

  // A private candidate Engine is built and retained, and stays invisible: the
  // ceiling it was built with is the SAME number, and the snapshot still claims
  // no effective context. The staging-boundary Battery observation refuses
  // the adoption at the final fence ([T033]) so this characterization keeps
  // proving what a RETAINED, never-published Engine means for telemetry.
  RuntimeBootstrapTestAccess::installStagingBoundary(
      bootstrap, [&bootstrap] { bootstrap.observePower(LifecyclePower::Battery); });
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1;
  }, "the production recovery construction landed no candidate");
  const auto held = bootstrap.lifecycleStatus();
  const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
  require(candidate && candidate->engine->maxContextTokens() == ready.configuredContextCeiling &&
              !held.effectiveContextTokens.has_value() && !held.inferenceReady,
          "a private Engine's window entered the request telemetry");
}

// [T031 prerequisite] The cold half of the same production builder: a model-less
// shell's first AC intent assembles a REAL graph on the residency worker's
// thread -- its own backend, streamed stores, plans, split, governor, SSD cache
// and ResourceDomainLease -- and the candidate carries that graph with its OWN
// authority parked on the construction thread. Nothing is adopted: the pump
// records why the shell stays control-only, and this shell keeps having no
// graph, no Engine and no admission of its own.
void testProductionColdCandidateAssemblesItsOwnGraph() {
  const test::TemporaryDirectory root("splash-native-cold-build");
  std::vector<uint8_t> output;
  RuntimeMetrics coldMetrics;
  RuntimeBootstrapConfig config = lifecycleConfig(root.path());

  config.initialPower = LifecyclePower::Battery;
  config.lifecycleWake = [] {};
  auto shell = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&output](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string("{}"); });
  RuntimeBootstrap &cold = *shell;
  require(!cold.hasResources() && !cold.hasModelRuntime() && !cold.nativeLoop().hasEngine(),
          "a model-less start constructed a graph anyway");
  // [T033] The staging-boundary Battery observation lands this cold candidate's
  // intent before publication: the transaction rolls back intact, the shell
  // records the refusal, and the whole candidate goes to the reaper's queue
  // for the characterization this test proves -- what the cold production
  // builder assembles, adopted nowhere.
  RuntimeBootstrapTestAccess::installStagingBoundary(
      cold, [&cold] { cold.observePower(LifecyclePower::Battery); });
  cold.observePower(LifecyclePower::AC);
  pumpReal(cold, [&] {
    return RuntimeBootstrapTestAccess::state(cold) == LifecycleState::RecoveryFailed &&
           RuntimeBootstrapTestAccess::pendingReaps(cold) == 1;
  }, "the cold production construction landed no candidate");
  const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(cold);
  require(candidate && candidate->ownsResources() && candidate->resources &&
              candidate->borrowedResources == nullptr &&
              candidate->authorityGraph() == candidate->resources.get(),
          "the cold candidate did not own and answer for its own graph");
  require(candidate->engine && candidate->model && !candidate->residency,
          "a cold candidate carries a separate stratum, or none of its own parts");
  require(candidate->engine->maxContextTokens() > 0,
          "the cold candidate's Engine enforces no context window");
  // Its OWN lease crossed the handoff on the construction thread (transfer ->
  // claim -> park), travelled out with the completion, and the pump's claim
  // returned it to that graph's OWN Owner interval -- which is exactly the state
  // the reaper requires before it can take a cold candidate's domain (T032).
  require(candidate->authorityGraph()->resourceAuthority().holder() ==
              ResourceDomainAuthority::Holder::Owner,
          "the cold candidate's own authority did not come back to its graph");
  require(!cold.hasResources() && !cold.hasModelRuntime() &&
              !cold.nativeLoop().hasEngine() && !cold.nativeLoop().admissionOpen() &&
              readyEventCount(output) == 1 && !cold.lifecycleStatus().lastError.empty() &&
              !cold.lifecycleStatus().effectiveContextTokens.has_value(),
          "the cold construction published into the shell it was built for");
}

struct ThrowingAdoptionNotifier {
  std::shared_ptr<bool> fail;
  explicit ThrowingAdoptionNotifier(std::shared_ptr<bool> flag) : fail(std::move(flag)) {}
  ThrowingAdoptionNotifier(const ThrowingAdoptionNotifier &other) : fail(other.fail) {
    if (*fail) throw std::runtime_error("injected preparation failure");
  }
  void operator()() const {}
};

void testWarmPreparationExceptionRestoresCandidate() {
  const test::TemporaryDirectory root("splash-native-warm-throw");
  LifecycleHarness harness(root.path());
  auto &bootstrap = *harness.bootstrap;
  auto *graph = &bootstrap.resources();
  auto *cache = &graph->cache();
  auto *writeBehind = &graph->writeBehind();
  bootstrap.observePower(LifecyclePower::Battery);
  pumpReal(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended &&
           !bootstrap.nativeLoop().hasEngine() && !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
           !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap) &&
           RuntimeBootstrapTestAccess::holder(bootstrap) == ResourceDomainAuthority::Holder::Owner;
  }, "warm exception setup did not suspend");
  auto fail = std::make_shared<bool>(false);
  std::function<void()> notifier = ThrowingAdoptionNotifier(fail);
  bootstrap.nativeLoop().setCompletionNotifier(std::move(notifier));
  *fail = true;
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1; },
           "throwing warm preparation did not queue candidate");
  const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
  require(candidate && candidate->engine && candidate->model && candidate->residency &&
              candidate->borrowedResources == graph && &bootstrap.resources() == graph &&
              &graph->cache() == cache && &graph->writeBehind() == writeBehind &&
              !graph->modelResident() && !bootstrap.nativeLoop().hasEngine() &&
              !bootstrap.nativeLoop().admissionOpen() && candidate->engine->callbacksRetired(),
          "throwing warm preparation did not restore candidate and retained graph");
  *fail = false;
  pumpReal(bootstrap, [&] {
    return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 0 &&
           !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
           !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap);
  }, "failed candidate was not reaped");
  for (int i = 0; i < 20; ++i)
    static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::RecoveryFailed &&
              !bootstrap.nativeLoop().admissionOpen() &&
              !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap),
          "unchanged AC retried failed preparation");
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
           "fresh AC did not retry failed preparation");
  bootstrap.observePower(LifecyclePower::Battery);
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(bootstrap.shutdownLifecycle(), "shutdown did not become terminal");
  bootstrap.observePower(LifecyclePower::AC);
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(!bootstrap.nativeLoop().admissionOpen(), "shutdown reopened admission");
}

void testNewerACAfterCommittedRelease() {
  const test::TemporaryDirectory root("splash-stale-release");
  LifecycleHarness harness(root.path());
  auto &bootstrap = *harness.bootstrap;
  auto *graph = &bootstrap.resources();
  auto *cache = &graph->cache();
  auto *writeBehind = &graph->writeBehind();
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] { return RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap); },
            "physical disposal did not start");
  waitPublished(bootstrap);
  bootstrap.observePower(LifecyclePower::AC);
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  const auto status = bootstrap.lifecycleStatus();
  require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended &&
              !status.inferenceReady && !status.modelResident &&
              !bootstrap.nativeLoop().admissionOpen() && !bootstrap.nativeLoop().hasEngine() &&
              !bootstrap.hasModelRuntime() && !graph->modelResident(),
          "stale committed release did not reconcile to closed suspension");
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
           "AC recovery after committed release failed");
  require(&bootstrap.resources() == graph && &graph->cache() == cache &&
              &graph->writeBehind() == writeBehind && readyEventCount(harness.output) == 1,
          "recovery changed retained identities or announced Ready again");
  protocol::RequestFrame frame;
  frame.requestId = 903;
  frame.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
  frame.remainingDeadlineMicros = 60'000'000;
  frame.logicalMaxOutputTokens = 1;
  frame.promptTokens = {1, 2, 3};
  const auto completed = bootstrap.nativeLoop().snapshot().completed;
  require(bootstrap.nativeLoop().receive(protocol::peer::serialize(frame)), "request refused");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (std::chrono::steady_clock::now() < deadline && bootstrap.nativeLoop().snapshot().completed == completed) {
    static_cast<void>(bootstrap.nativeLoop().tick());
    std::this_thread::yield();
  }
  require(bootstrap.nativeLoop().snapshot().completed == completed + 1,
          "request after stale release recovery did not complete");
}

void testNewerACDoesNotAcceptIncompleteRelease() {
  {
    const test::TemporaryDirectory earlyRoot("splash-superseded-before-release");
    LifecycleHarness earlyHarness(earlyRoot.path());
    auto &early = *earlyHarness.bootstrap;
    auto &loop = early.nativeLoop();
    early.observePower(LifecyclePower::AC);
    pumpReal(early, [&] { return early.lifecycleStatus().inferenceReady; }, "initial AC failed");
    auto *engine = loop.publishedEngine();
    auto *graph = &early.resources();
    auto *model = &early.modelRuntime();
    protocol::RequestFrame frame;
    frame.requestId = 914;
    frame.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
    frame.remainingDeadlineMicros = 60'000'000;
    frame.logicalMaxOutputTokens = 1;
    frame.promptTokens = {1, 2, 3};
    require(loop.receive(protocol::peer::serialize(frame)) && engine->requestDrain().queued > 0,
            "pre-release fixture did not hold an admitted request");
    early.observePower(LifecyclePower::Battery);
    static_cast<void>(early.controlPass(MemoryPressure::Normal));
    require(!loop.admissionOpen() && loop.publishedEngine() == engine,
            "Battery did not close admission before release");
    early.observePower(LifecyclePower::AC);
    static_cast<void>(early.controlPass(MemoryPressure::Normal));
    require(loop.publishedEngine() == engine && &early.resources() == graph &&
                &early.modelRuntime() == model && graph->modelResident() &&
                loop.admissionOpen() && early.lifecycleStatus().inferenceReady &&
                !RuntimeBootstrapTestAccess::pumpOperationStarted(early) &&
                readyEventCount(earlyHarness.output) == 1,
            "AC before release did not preserve and reopen the published Engine");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (loop.snapshot().completed == 0 && std::chrono::steady_clock::now() < deadline)
      static_cast<void>(loop.tick());
    require(loop.snapshot().completed == 1, "superseded drain did not complete its request");
  }
  const test::TemporaryDirectory root("splash-incomplete-release");
  LifecycleHarness harness(root.path());
  auto &bootstrap = *harness.bootstrap;
  RuntimeBootstrapTestAccess::installWorkerSeams(
      bootstrap, [](const WorkerCancellation &) { return DisposalReceipt{}; }, {}, {});
  bootstrap.observePower(LifecyclePower::Battery);
  pumpUntil(bootstrap, [&] { return RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap); },
            "incomplete disposal did not start");
  waitPublished(bootstrap);
  bootstrap.observePower(LifecyclePower::AC);
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Draining &&
              bootstrap.nativeLoop().hasEngine() && bootstrap.hasModelRuntime() &&
              bootstrap.resources().modelResident() && !bootstrap.nativeLoop().admissionOpen(),
          "incomplete disposal was treated as a committed release");
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(!bootstrap.nativeLoop().admissionOpen(),
          "incomplete disposal reopened admission on a later safe point");
}

void testColdBeginServingFailureRollsBack() {
  const test::TemporaryDirectory root("splash-cold-serving-throw");
  std::vector<uint8_t> output;
  RuntimeMetrics metrics;
  auto config = lifecycleConfig(root.path());

  config.initialPower = LifecyclePower::Battery;
  config.lifecycleWake = [] {};
  auto shell = RuntimeBootstrap::startModelLess(
      std::move(config), [&output](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      }, [] { return std::string("{}"); });
  auto &bootstrap = *shell;
  RuntimeResources *graph = nullptr;
  engine::Engine *engine = nullptr;
  model::RuntimeModel *model = nullptr;
  bool thrown = false;
  RuntimeBootstrapTestAccess::installCandidateWitnesses(bootstrap, [&](auto &lease, auto &candidate) {
    if (!graph) {
      graph = candidate.resources.get();
      engine = candidate.engine.get();
      model = candidate.model.get();
      RuntimeResourcesTestAccess::failBeginServing(*graph, [&] {
        require(!bootstrap.nativeLoop().admissionOpen() && bootstrap.nativeLoop().publishedEngine() == engine,
                "serving initialization ran without closed staged Engine");
        thrown = true;
        throw std::runtime_error("injected beginServing failure");
      });
    }
    lease.setAdmissionWitness([] { return true; });
    lease.setRequestDrainWitness([] { return true; });
    lease.setRetainedIoWitness([] { return true; });
    lease.setCallbackRetirementWitness([] { return true; });
  });
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1; },
           "beginServing failure did not queue candidate");
  const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
  require(thrown && candidate && candidate->resources.get() == graph &&
              candidate->engine.get() == engine && candidate->model.get() == model &&
              !RuntimeBootstrapTestAccess::hasMemoryControl(bootstrap) &&
              !bootstrap.hasResources() && !bootstrap.hasModelRuntime() &&
              !bootstrap.nativeLoop().hasEngine() && !bootstrap.nativeLoop().admissionOpen() &&
              !bootstrap.lifecycleStatus().inferenceReady && readyEventCount(output) == 1,
          "beginServing failure did not restore the cold candidate");
  bootstrap.observePower(LifecyclePower::Battery);
  pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 0 &&
      !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
      !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap); },
      "failed cold candidate was not safely reaped");

  // A candidate over the shell's immutable ceiling must be refused before
  // publication; a later correctly built candidate can still recover.
  const test::TemporaryDirectory invalidRoot("splash-invalid-context");
  ColdShell invalidShell(invalidRoot.path());
  CandidateSink invalidSink;
  auto &invalid = *invalidShell.bootstrap;
  const auto ceiling = invalid.lifecycleStatus().configuredContextCeiling;
  RuntimeBootstrapTestAccess::installCandidateWitnesses(
      invalid, [&](ResourceDomainLease &lease, RecoveryCandidate &candidate) {
        auto config = fixtureEngineConfig(*candidate.resources, lifecycleConfig(invalidRoot.path()).nativeLoop.engine);
        config.maxContext = ceiling + 1;
        candidate.engine = std::make_unique<engine::Engine>(
            config, candidate.resources->cache(), candidate.resources->writeBehind(),
            *candidate.model, invalidSink);
        lease.setAdmissionWitness([] { return true; });
        lease.setRequestDrainWitness([] { return true; });
        lease.setRetainedIoWitness([] { return true; });
        lease.setCallbackRetirementWitness([] { return true; });
      });
  invalid.observePower(LifecyclePower::AC);
  pumpReal(invalid, [&] { return RuntimeBootstrapTestAccess::pendingReaps(invalid) == 1; },
           "over-ceiling candidate was not refused");
  const auto *refused = RuntimeBootstrapTestAccess::lastCandidate(invalid);
  require(refused && refused->engine && refused->engine->maxContextTokens() == ceiling + 1,
          "over-ceiling candidate was not retained intact");
  require(!invalid.hasResources() && !invalid.nativeLoop().hasEngine() &&
              !invalid.nativeLoop().admissionOpen() && !invalid.lifecycleStatus().inferenceReady &&
              readyEventCount(invalidShell.output) == 1,
          "invalid context escaped the adoption fence");
  require(invalid.lifecycleStatus().lastError.find("above the configured ceiling") != std::string::npos,
          "wrong invalid context refusal: " + invalid.lifecycleStatus().lastError);
  RuntimeBootstrapTestAccess::installCandidateWitnesses(invalid, {});
  invalid.observePower(LifecyclePower::Battery);
  pumpReal(invalid, [&] { return RuntimeBootstrapTestAccess::pendingReaps(invalid) == 0 &&
      !RuntimeBootstrapTestAccess::workerRunning(invalid) &&
      !RuntimeBootstrapTestAccess::pumpOperationStarted(invalid); },
      "over-ceiling candidate was not reaped");
  invalid.observePower(LifecyclePower::AC);
  pumpReal(invalid, [&] { return invalid.lifecycleStatus().inferenceReady; },
           "valid recovery after invalid context failed");
  require(invalid.nativeLoop().admissionOpen() && invalid.nativeLoop().hasEngine() &&
              invalid.nativeLoop().publishedContextTokens().value() <= ceiling &&
              readyEventCount(invalidShell.output) == 1,
          "valid recovery after invalid context changed control generation");
}

void testColdFinalFenceInterleavings() {
  for (int scenario = 0; scenario != 3; ++scenario) {
    const test::TemporaryDirectory root("splash-native-fence");
    std::vector<uint8_t> output;
    RuntimeMetrics metrics;
    RuntimeBootstrapConfig config = lifecycleConfig(root.path());

    config.initialPower = LifecyclePower::Battery;
    config.lifecycleWake = [] {};
    auto shell = RuntimeBootstrap::startModelLess(
        std::move(config), [&output](std::span<const uint8_t> bytes) {
          output.insert(output.end(), bytes.begin(), bytes.end());
        }, [] { return std::string("{}"); });
    auto &bootstrap = *shell;
    uint64_t before = 0, after = 0;
    RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, [&] {
      before = RuntimeBootstrapTestAccess::powerGeneration(bootstrap);
      if (scenario == 0) {
        bootstrap.observePower(LifecyclePower::Battery);
        bootstrap.observePower(LifecyclePower::AC);
        after = RuntimeBootstrapTestAccess::powerGeneration(bootstrap);
      } else if (scenario == 1) {
        static_cast<void>(bootstrap.shutdownLifecycle());
      } else {
        throw std::runtime_error("staging boundary failure");
      }
    });
    bootstrap.observePower(LifecyclePower::AC);
    pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1; },
             "final fence did not queue the candidate");
    const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
    require(candidate && candidate->resources && candidate->engine && candidate->model &&
                !bootstrap.hasResources() && !bootstrap.hasModelRuntime() &&
                !bootstrap.nativeLoop().hasEngine() && !bootstrap.nativeLoop().admissionOpen() &&
                readyEventCount(output) == 1,
            "final fence did not restore the cold candidate");
    require(scenario != 0 || after == before + 2,
            "Battery to AC did not advance both observations");
    if (scenario == 1) {
      const auto revision = RuntimeBootstrapTestAccess::revision(bootstrap);
      bootstrap.observePower(LifecyclePower::AC);
      static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
      require(RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Shutdown &&
                  RuntimeBootstrapTestAccess::revision(bootstrap) == revision &&
                  !bootstrap.lifecycleStatus().inferenceReady && !bootstrap.nativeLoop().admissionOpen() &&
                  !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap) && readyEventCount(output) == 1,
              "late power revived staged shutdown");
    }
  }
}

void testCancelledColdAuthorityReturnsOnShutdown() {
  for (bool duringReap : {false, true}) {
    const test::TemporaryDirectory root("splash-cold-cancel-authority");
    ColdShell shell(root.path());
    auto &bootstrap = *shell.bootstrap;
    std::atomic<bool> invoked{false};
    auto cancel = [&] { invoked = true; static_cast<void>(bootstrap.shutdownLifecycle()); };
    RuntimeBootstrapTestAccess::installColdCancellationHooks(
        bootstrap, duringReap ? std::function<void()>{} : cancel,
        duringReap ? cancel : std::function<void()>{});
    if (duringReap)
      RuntimeBootstrapTestAccess::installStagingBoundary(
          bootstrap, [&] { bootstrap.observePower(LifecyclePower::Battery); });
    bootstrap.observePower(LifecyclePower::AC);
    if (duringReap) {
      pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1; },
               "cold candidate was not queued for cancellation test");
      RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, {});
    }
    pumpReal(bootstrap, [&] { return invoked.load(); }, "cold cancellation hook did not run");
    pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1 &&
        !RuntimeBootstrapTestAccess::workerRunning(bootstrap); },
        "shutdown did not claim the cancelled candidate");
    const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
    require(candidate && candidate->resources && candidate->engine && candidate->model &&
                candidate->resources->resourceAuthority().holder() == ResourceDomainAuthority::Holder::Owner &&
                !bootstrap.nativeLoop().hasEngine() && !bootstrap.nativeLoop().admissionOpen() &&
                readyEventCount(shell.output) == 1,
            "cancelled cold graph did not return intact to its owner");
    shell.bootstrap.reset(); // Returning here proves teardown joined and disposed the graph.
  }
}

// The OS callback writes the production mailbox, without entering the pump.
void testMailboxInvalidatesColdStaging() {
  for (bool returnToAC : {false, true}) {
    const test::TemporaryDirectory root("splash-mailbox-fence");
    ColdShell shell(root.path());
    auto &bootstrap = *shell.bootstrap;
    auto mailbox = std::make_shared<PendingPowerObservation>([] {});
    mailbox->recordInitial(LifecyclePower::AC);
    static_cast<void>(mailbox->take());
    bootstrap.setPowerObservation(mailbox);
    bool staged = false;
    RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, [&] {
      staged = true;
      mailbox->record(LifecyclePower::Battery);
      if (returnToAC) mailbox->record(LifecyclePower::AC);
    });
    bootstrap.observePower(LifecyclePower::AC);
    pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 1; },
             "mailbox observation did not refuse staged candidate");
    const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
    require(staged && candidate && candidate->resources && candidate->engine &&
                candidate->resources->resourceAuthority().holder() == ResourceDomainAuthority::Holder::Owner &&
                !bootstrap.nativeLoop().hasEngine() && !bootstrap.nativeLoop().admissionOpen() &&
                readyEventCount(shell.output) == 1,
            "mailbox fence did not roll back intact cold candidate");
    RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, {});
    if (auto observation = mailbox->take()) bootstrap.observePower(*observation);
    pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::pendingReaps(bootstrap) == 0 &&
        !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
        !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap); },
        "mailbox-refused candidate was not reaped");
    mailbox->record(LifecyclePower::AC);
    if (auto observation = mailbox->take()) bootstrap.observePower(*observation);
    pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
             "new AC intent did not recover after mailbox fence");
    require(readyEventCount(shell.output) == 1, "mailbox recovery repeated Ready");
    mailbox->record(LifecyclePower::Battery);
    const auto pending = bootstrap.lifecycleStatus();
    require(bootstrap.nativeLoop().admissionOpen() && !pending.inferenceReady &&
                !pending.effectiveContextTokens,
            "pending Battery left an authoritative inference-ready status");
    static_cast<void>(mailbox->take());
  }
}

// Disabled policy supplies no observer or pending reading; production authorizes AC.
void testDisabledPolicyRealStartup() {
  const test::TemporaryDirectory root("splash-disabled-policy");
  LifecycleHarness harness(root.path());
  auto &bootstrap = *harness.bootstrap;
  require(RuntimeBootstrapTestAccess::powerGeneration(bootstrap) == 0,
          "disabled startup received a power observation");
  auto *graph = &bootstrap.resources();
  auto *model = &bootstrap.modelRuntime();
  auto *cache = &graph->cache();
  auto *writeBehind = &graph->writeBehind();
  auto *engine = bootstrap.nativeLoop().publishedEngine();
  require(graph->modelResident() && engine && readyEventCount(harness.output) == 1,
          "disabled startup did not publish the full model");
  bootstrap.observePower(LifecyclePower::AC); // initialServingAuthorization(false, nullopt)
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  const auto status = bootstrap.lifecycleStatus();
  require(status.state == LifecycleState::Ready && status.power == LifecyclePower::AC &&
              status.modelResident && status.inferenceReady &&
              status.effectiveContextTokens == engine->maxContextTokens() &&
              bootstrap.nativeLoop().admissionOpen() &&
              !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
              !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap),
          "disabled authorization did not retain ready admission");
  protocol::RequestFrame frame;
  frame.requestId = 900;
  frame.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
  frame.remainingDeadlineMicros = 60'000'000;
  frame.logicalMaxOutputTokens = 1;
  frame.promptTokens = {1, 2, 3};
  const auto completed = bootstrap.nativeLoop().snapshot().completed;
  require(bootstrap.nativeLoop().receive(protocol::peer::serialize(frame)),
          "disabled startup rejected a real request");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (std::chrono::steady_clock::now() < deadline &&
         bootstrap.nativeLoop().snapshot().completed == completed) {
    static_cast<void>(bootstrap.nativeLoop().tick());
    std::this_thread::yield();
  }
  require(bootstrap.nativeLoop().snapshot().completed == completed + 1 &&
              &bootstrap.resources() == graph && &bootstrap.modelRuntime() == model &&
              &graph->cache() == cache && &graph->writeBehind() == writeBehind &&
              bootstrap.nativeLoop().publishedEngine() == engine && graph->modelResident() &&
              bootstrap.lifecycleStatus().state == LifecycleState::Ready &&
              bootstrap.lifecycleStatus().power == LifecyclePower::AC &&
              RuntimeBootstrapTestAccess::powerGeneration(bootstrap) == 1 &&
              !RuntimeBootstrapTestAccess::workerRunning(bootstrap) &&
              !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap) &&
              readyEventCount(harness.output) == 1,
          "disabled startup changed residency, lifecycle, or Ready count");
}

void testAdmittedRequestDrainsAcrossBattery() {
  const test::TemporaryDirectory root("splash-admitted-battery");
  LifecycleHarness harness(root.path());
  auto &bootstrap = *harness.bootstrap;
  auto &loop = bootstrap.nativeLoop();
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
           "AC did not authorize serving");
  auto *graph = &bootstrap.resources();
  auto *engine = loop.publishedEngine();
  const auto firstSequence = RuntimeBootstrapTestAccess::observationSequence(bootstrap);
  const auto firstRevision = RuntimeBootstrapTestAccess::revision(bootstrap);
  auto request = [&](uint64_t id) {
    protocol::RequestFrame frame;
    frame.requestId = id;
    frame.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
    frame.remainingDeadlineMicros = 60'000'000;
    frame.logicalMaxOutputTokens = 1;
    frame.promptTokens = {1, 2, 3};
    require(loop.receive(protocol::peer::serialize(frame)), "request connection closed");
  };
  auto terminals = [&](uint64_t id) {
    unsigned done = 0, errors = 0;
    for (const auto &event : protocol::peer::decodeEvents(harness.output)) {
      if (const auto *e = std::get_if<protocol::DoneEvent>(&event); e && e->requestId == id) ++done;
      if (const auto *e = std::get_if<protocol::ErrorEvent>(&event); e && e->requestId == id) ++errors;
    }
    return std::pair{done, errors};
  };
  require(engine && loop.admissionOpen() && readyEventCount(harness.output) == 1,
          "initial serving was not ready");
  // receive() submits to the real Engine synchronously; withholding tick is a
  // deterministic gate on its queued request, not a timing assumption.
  request(910);
  require(engine->requestDrain().queued > 0, "accepted request was not queued");
  auto mailbox = std::make_shared<PendingPowerObservation>([] {});
  mailbox->recordInitial(LifecyclePower::AC);
  static_cast<void>(mailbox->take());
  bootstrap.setPowerObservation(mailbox);
  mailbox->record(LifecyclePower::Battery);
  // Input may arrive before the control pass consumes the callback.
  request(911);
  require(terminals(911) == std::pair{0u, 1u} && engine->requestDrain().queued == 1,
          "pending mailbox Battery admitted a later request");
  for (const auto &event : protocol::peer::decodeEvents(harness.output))
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&event);
        error && error->requestId == 911)
      require(error->code == "inference_unavailable", "wrong mailbox refusal code");
  if (auto observation = mailbox->take()) bootstrap.observePower(*observation);
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  static_cast<void>(bootstrap.controlPass(MemoryPressure::Normal));
  require(!loop.admissionOpen() && loop.publishedEngine() == engine && graph->modelResident() &&
              RuntimeBootstrapTestAccess::holder(bootstrap) == ResourceDomainAuthority::Holder::Owner &&
              !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap),
          "pending request did not hold the drain barrier before disposal");
  require(terminals(911) == std::pair{0u, 1u} && terminals(910) == std::pair{0u, 0u},
          "closed admission did not distinguish the new request from queued work");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (terminals(910) == std::pair{0u, 0u} && std::chrono::steady_clock::now() < deadline) {
    static_cast<void>(loop.tick());
    std::this_thread::yield();
  }
  require(terminals(910) == std::pair{1u, 0u}, "admitted request did not finish exactly once");
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().state == LifecycleState::Suspended &&
                                !loop.hasEngine() && !graph->modelResident(); },
           "drained graph did not suspend");
  const auto suspendedSequence = RuntimeBootstrapTestAccess::observationSequence(bootstrap);
  const auto status = bootstrap.lifecycleStatus();
  require(!status.inferenceReady && !status.effectiveContextTokens &&
              loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{912})) &&
              bootstrap.statusJson(harness.metrics.snapshot(), NativeLoopTiming{}).find("\"inference_ready\":false") != std::string::npos,
          "suspended control path or status was unavailable");
  bool statusAnswered = false;
  for (const auto &event : protocol::peer::decodeEvents(harness.output))
    if (const auto *reply = std::get_if<protocol::StatusJsonEvent>(&event);
        reply && reply->correlationId == 912)
      statusAnswered = true;
  require(statusAnswered, "suspended native loop did not answer the status request");
  mailbox->record(LifecyclePower::AC);
  if (auto observation = mailbox->take()) bootstrap.observePower(*observation);
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; }, "AC recovery failed");
  require(&bootstrap.resources() == graph && graph->modelResident() && loop.hasEngine() &&
              loop.admissionOpen() && RuntimeBootstrapTestAccess::revision(bootstrap) == firstRevision + 2 &&
              firstSequence < suspendedSequence && suspendedSequence < RuntimeBootstrapTestAccess::observationSequence(bootstrap),
          "recovery did not publish truthful retained resources and lifecycle");
  request(913);
  const auto retryDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (terminals(913) == std::pair{0u, 0u} && std::chrono::steady_clock::now() < retryDeadline) {
    static_cast<void>(loop.tick());
    std::this_thread::yield();
  }
  require(terminals(913) == std::pair{1u, 0u} && terminals(910) == std::pair{1u, 0u} &&
              readyEventCount(harness.output) == 1, "recovered request or single ReadyEvent failed");
}

void testColdStaticCapabilitiesAndExplicitContext() {
  for (bool vision : {true, false}) {
    const test::TemporaryDirectory root("splash-cold-static");
    auto config = lifecycleConfig(root.path());
    RuntimeMetrics metrics;

    config.resources.model.capabilities.maximumContextTokens = 2048;
    std::get<model::Qwen3_8Layout>(config.resources.model.target).nativeContextTokens = 2048;
    config.nativeLoop.engine.maxContext = 1024;
    if (!vision) config.resources.model.visionSource = model::VisionSource::None;
    config.initialPower = LifecyclePower::Battery;
    config.lifecycleWake = [] {};
    std::vector<uint8_t> output;
    auto shell = RuntimeBootstrap::startModelLess(std::move(config),
        [&output](std::span<const uint8_t> bytes) { output.insert(output.end(), bytes.begin(), bytes.end()); },
        [] { return std::string("{}"); });
    auto events = protocol::peer::decodeEvents(output);
    require(events.size() == 1 && std::holds_alternative<protocol::ReadyEvent>(events.front()), "cold ready missing");
    const auto ready = std::get<protocol::ReadyEvent>(events.front());
    require(ready.maxContextTokens == 1024, "explicit cold Ready ceiling must be 1024");
    require(ready.vision == vision, "cold Ready vision disagrees with fixture");
    require(shell->lifecycleStatus().configuredContextCeiling == 1024 &&
            !shell->lifecycleStatus().inferenceReady && !shell->nativeLoop().admissionOpen(), "cold explicit status incorrect");
    if (vision) {
      shell->observePower(LifecyclePower::AC);
      pumpReal(*shell, [&] { return shell->lifecycleStatus().inferenceReady || shell->lifecycleStatus().state == LifecycleState::RecoveryFailed; }, "explicit recovery timed out");
      auto *engine = shell->nativeLoop().publishedEngine();
      require(engine && shell->lifecycleStatus().effectiveContextTokens == engine->maxContextTokens() && engine->maxContextTokens() <= 1024, "explicit recovery context incorrect: " + shell->lifecycleStatus().lastError);
      require(readyEventCount(output) == 1, "explicit recovery reannounced Ready");
    }
  }
  std::cout << "PASS cold static capabilities and explicit context\n";
}

void testColdConstrainedPlanAndRelaunch() {
  const test::TemporaryDirectory root("splash-cold-plan");
  auto config = lifecycleConfig(root.path());
  const uint32_t ceiling = config.resources.model.capabilities.maximumContextTokens;
  uint64_t minimum = 0;
  {
    auto resources = RuntimeResources::create(config.resources, 0);
    minimum = resources->memoryPlan().breakdown().minimumRequiredBytes;
  }
  config.resources.maximumMemoryBytes = minimum + config.resources.model.stateLayout.cachedBytes() + 64ULL * 1024 * 1024;
  uint32_t plan = 0;
  {
    auto resources = RuntimeResources::create(config.resources, 0);
    plan = resources->memoryPlan().maximumContextTokens();
  }
  require(plan > 2 && plan < ceiling, "fixture did not constrain plan context");
  for (int scenario = 0; scenario < 3; ++scenario) {
    auto candidateConfig = config;
    RuntimeMetrics metrics;

    candidateConfig.nativeLoop.engine.maxContext = scenario == 1 ? plan + 1 : 0;
    candidateConfig.resources.relaunchContext = scenario == 2 ? plan / 2 : 0;
    candidateConfig.initialPower = LifecyclePower::Battery;
    candidateConfig.lifecycleWake = [] {};
    std::vector<uint8_t> output;
    auto shell = RuntimeBootstrap::startModelLess(std::move(candidateConfig),
        [&output](std::span<const uint8_t> bytes) { output.insert(output.end(), bytes.begin(), bytes.end()); },
        [] { return std::string("{}"); });
    const auto events = protocol::peer::decodeEvents(output);
    const auto ready = std::get<protocol::ReadyEvent>(events.front());
    require(ready.maxContextTokens == (scenario == 1 ? plan + 1 : ceiling), "cold plan static ceiling incorrect");
    require(!shell->hasResources() && !shell->nativeLoop().hasEngine() && !shell->lifecycleStatus().inferenceReady, "cold plan shell loaded a model");
    shell->observePower(LifecyclePower::AC);
    pumpReal(*shell, [&] { return shell->lifecycleStatus().inferenceReady || shell->lifecycleStatus().state == LifecycleState::RecoveryFailed; }, "constrained recovery timed out");
    const auto status = shell->lifecycleStatus();
    auto *engine = shell->nativeLoop().publishedEngine();
    if (scenario == 1) {
      require(!engine && !status.inferenceReady && !status.effectiveContextTokens && !shell->nativeLoop().admissionOpen() &&
                  (status.lastError.find("context") != std::string::npos || status.lastError.find("memory") != std::string::npos), "over-budget context did not fail closed: " + status.lastError);
      std::cout << "over-budget error: " << status.lastError << "\n";
    } else {
      require(engine && status.effectiveContextTokens == engine->maxContextTokens() && engine->maxContextTokens() > 0 && engine->maxContextTokens() < ready.maxContextTokens, "constrained effective context incorrect: " + status.lastError);
      if (scenario == 2) require(engine->maxContextTokens() == plan / 2, "relaunch context was not capped to requested context");
      std::cout << "cold plan=" << plan << " static=" << ready.maxContextTokens << " effective=" << engine->maxContextTokens() << " scenario=" << scenario << "\n";
    }
    require(readyEventCount(output) == 1, "constrained recovery reannounced Ready");
  }
  std::cout << "PASS cold constrained plan, over-budget and relaunch contexts\n";
}

void exerciseRealColdAndWarmAdoption(std::optional<uint64_t> &receiptAfter) {
  const test::TemporaryDirectory root("splash-native-real-adoption");
  std::vector<uint8_t> output;
  RuntimeMetrics metrics;
  RuntimeBootstrapConfig config = lifecycleConfig(root.path());
  std::atomic<int> hostScenario{0};
  config.resources.hostMemory = [&hostScenario] {
    if (hostScenario.load() == 1)
      return std::optional<HostMemory>{};
    if (hostScenario.load() == 2)
      return std::optional<HostMemory>(HostMemory{64ULL * 1024 * 1024 * 1024, 0});
    return queryHostMemory();
  };

  config.initialPower = LifecyclePower::Battery;
  config.lifecycleWake = [] {};
  auto shell = RuntimeBootstrap::startModelLess(
      std::move(config), [&output](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      }, [] { return std::string("{}"); });
  auto &bootstrap = *shell;
  RuntimeResources *graph = nullptr;
  engine::Engine *engine = nullptr;
  model::RuntimeModel *model = nullptr;
  RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, [&] {
    const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
    require(candidate && candidate->resources, "cold staged candidate lost its graph");
    graph = candidate->resources.get();
    engine = bootstrap.nativeLoop().publishedEngine();
    model = &bootstrap.modelRuntime();
    require(!bootstrap.hasResources() && !bootstrap.nativeLoop().admissionOpen(),
            "cold staging published before the fence");
  });
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
           "cold adoption did not publish");
  require(graph && &bootstrap.resources() == graph &&
              bootstrap.nativeLoop().publishedEngine() == engine &&
              &bootstrap.modelRuntime() == model &&
              bootstrap.lifecycleStatus().effectiveContextTokens == engine->maxContextTokens() &&
              readyEventCount(output) == 1,
          "cold publication changed staged identities or Ready count");
  auto serve = [&](uint64_t id) {
    protocol::RequestFrame frame;
    frame.requestId = id;
    frame.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
    frame.remainingDeadlineMicros = 60'000'000;
    frame.logicalMaxOutputTokens = 1;
    frame.promptTokens = {1, 2, 3};
    const auto completed = bootstrap.nativeLoop().snapshot().completed;
    require(bootstrap.nativeLoop().receive(protocol::peer::serialize(frame)),
            "adopted Engine closed the request connection");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline && bootstrap.nativeLoop().snapshot().completed == completed) {
      static_cast<void>(bootstrap.nativeLoop().tick());
      std::this_thread::yield();
    }
    require(bootstrap.nativeLoop().snapshot().completed == completed + 1,
            "adopted Engine did not complete a real request");
    unsigned starts = 0;
    for (const auto &event : protocol::peer::decodeEvents(output))
      if (const auto *start = std::get_if<protocol::StartEvent>(&event); start && start->requestId == id) {
        ++starts;
        require(start->capacityTokens == bootstrap.nativeLoop().publishedEngine()->maxContextTokens(), "wrong published capacity");
      }
    require(starts == 1 && readyEventCount(output) == 1, "missing start or repeated ready");
  };
  serve(901);
  const auto modelPoolCount = bootstrap.modelRuntime().pools().size();
  const auto liveAccounts = graph->memoryGovernor().publishSnapshot().accounts.size();
  require(modelPoolCount > 0, "production model exposed no Ledger pool registrations");
  auto requireCurrentModelAccounts = [&] {
    const auto sample = graph->memoryGovernor().publishSnapshot();
    require(sample.accounts.size() == liveAccounts,
            "recovery retained registrations from an older model generation");
    for (auto *pool : bootstrap.modelRuntime().pools()) {
      const auto state = pool->state();
      require(std::count_if(sample.accounts.begin(), sample.accounts.end(), [&](const auto &account) {
        return account.name == state.name && account.currentBytes == state.currentBytes &&
               account.floorBytes == state.floorBytes && account.capBytes == state.capBytes;
      }) == 1, "Ledger account does not describe exactly the current model pool");
    }
  };
  requireCurrentModelAccounts();
  auto *cache = &graph->cache();
  auto *writeBehind = &graph->writeBehind();
  auto *backend = &graph->backend();
  auto *governor = &graph->memoryGovernor();
  auto *authority = &graph->resourceAuthority();
  const auto identity = graph->cacheIdentity();
  auto retainedState = std::make_shared<test::OffloadControl>();
  retainedState->ready = true;
  const std::vector<uint32_t> retainedPrompt(64, 42);
  cache->beginRequest(990);
  require(cache->ensureTokens(990, 64).granted(), "retained graph fixture could not allocate KV");
  cache->publishCompositeState(test::publishBlocks(*cache, 990, retainedPrompt, 64),
                               std::make_shared<test::OffloadState>(retainedState), false);
  cache->endRequest(990);
  const auto retained = cache->snapshot();
  require(retained.pool.pagesPrefix > 0 && retained.stateCache.entries == 1 &&
              retained.stateCache.bytes == 64,
          "retained graph fixture did not populate KV and composite state");
  RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, {});
  bootstrap.observePower(LifecyclePower::Battery);
  pumpReal(bootstrap, [&] { return RuntimeBootstrapTestAccess::state(bootstrap) == LifecycleState::Suspended && !bootstrap.nativeLoop().hasEngine() && !RuntimeBootstrapTestAccess::workerRunning(bootstrap) && !RuntimeBootstrapTestAccess::pumpOperationStarted(bootstrap) && RuntimeBootstrapTestAccess::holder(bootstrap) == ResourceDomainAuthority::Holder::Owner; },
           "warm adoption setup did not suspend");
  receiptAfter = RuntimeBootstrapTestAccess::lastDisposalBytesAfter(bootstrap);
  require(!bootstrap.hasModelRuntime() && !graph->modelResident() &&
              graph->memoryGovernor().publishSnapshot().accounts.size() + modelPoolCount == liveAccounts,
          "Worker disposal left old model pool registrations in the retained Ledger");
  // Traverse the retired generation's former buffer query with no model alive.
  auto &ledger = graph->memoryGovernor().ledger();
  static_cast<void>(ledger.available({.cls = ClaimClass::Start},
      {.bytes = std::numeric_limits<uint64_t>::max(), .afterStart = true},
      0, MemoryPressure::Normal));
  // Available memory clears the hard startup reserve, while spare memory is
  // below its reserve: required arenas must use initial assembly's class.
  hostScenario = 1;
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] {
    return bootstrap.lifecycleStatus().state == LifecycleState::RecoveryFailed &&
           RuntimeBootstrapTestAccess::holder(bootstrap) == ResourceDomainAuthority::Holder::Owner;
  }, "missing host measurement did not fail recovery");
  require(!RuntimeResourcesTestAccess::hasStartupScope(*graph) && !bootstrap.nativeLoop().hasEngine() &&
              !bootstrap.nativeLoop().admissionOpen() && !graph->modelResident(),
          "failed construction leaked essential mode, authority or publication");
  bootstrap.observePower(LifecyclePower::Battery);
  hostScenario = 2;
  engine = nullptr;
  RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, [&] {
    const auto *candidate = RuntimeBootstrapTestAccess::lastCandidate(bootstrap);
    require(candidate && candidate->borrowedResources == graph && !candidate->ownsResidency() && graph->modelResident() &&
                !bootstrap.nativeLoop().admissionOpen(), "warm staging lost retained graph");
    engine = bootstrap.nativeLoop().publishedEngine();
  });
  bootstrap.observePower(LifecyclePower::AC);
  try {
    pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
             "warm adoption did not publish");
  } catch (const std::exception &) {
    throw std::runtime_error("warm adoption did not publish: " + bootstrap.lifecycleStatus().lastError +
                             (engine ? " (staged)" : " (not staged)"));
  }
  const auto recovered = cache->snapshot();
  require(&graph->resourceAuthority() == authority && graph->cacheIdentity() == identity &&
              recovered.pool.pagesAllocated == retained.pool.pagesAllocated &&
              recovered.pool.pagesActive == retained.pool.pagesActive &&
              recovered.pool.pagesPrefix == retained.pool.pagesPrefix &&
              recovered.stateCache.entries == retained.stateCache.entries &&
              recovered.stateCache.bytes == retained.stateCache.bytes && graph->modelResident(),
          "warm adoption changed retained cache state");
  require(&bootstrap.resources() == graph && &graph->cache() == cache &&
              &graph->writeBehind() == writeBehind && &graph->backend() == backend &&
              &graph->memoryGovernor() == governor && engine &&
              bootstrap.nativeLoop().publishedEngine() == engine &&
              engine->borrowedCache() == cache && engine->borrowedWriteBehind() == writeBehind &&
              readyEventCount(output) == 1, "warm adoption changed retained identities");
  require(!RuntimeResourcesTestAccess::hasStartupScope(*graph),
          "warm construction left its startup Floor scope enabled");
  for (const auto cls : {ClaimClass::Optional, ClaimClass::Growth}) {
    const auto claim = ledger.open({.cls = cls});
    metal::AllocationResult admitted;
    {
      MemoryGovernor::Scope scope(*governor, claim);
      admitted = governor->allocationAdmission()(1, [] {});
    }
    ledger.close(claim);
    require(!admitted && admitted.failure == metal::AllocationFailure::HostPressure,
            "warm recovery left Optional/Growth allocations exempt from host pressure");
  }
  hostScenario = 0;
  requireCurrentModelAccounts();
  serve(902);
  const auto secondBaseline = cache->snapshot();
  RuntimeBootstrapTestAccess::installStagingBoundary(bootstrap, {});
  bootstrap.observePower(LifecyclePower::Battery);
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().state == LifecycleState::Suspended &&
                                 !bootstrap.nativeLoop().hasEngine(); },
           "second warm cycle did not suspend");
  bootstrap.observePower(LifecyclePower::AC);
  pumpReal(bootstrap, [&] { return bootstrap.lifecycleStatus().inferenceReady; },
           "second warm cycle did not recover");
  const auto secondRecovered = cache->snapshot();
  require(&bootstrap.resources() == graph && &graph->cache() == cache &&
              &graph->writeBehind() == writeBehind && &graph->backend() == backend &&
              &graph->memoryGovernor() == governor && &graph->resourceAuthority() == authority &&
              graph->cacheIdentity() == identity &&
              secondRecovered.pool.pagesAllocated == secondBaseline.pool.pagesAllocated &&
              secondRecovered.pool.pagesActive == secondBaseline.pool.pagesActive &&
              secondRecovered.pool.pagesPrefix == secondBaseline.pool.pagesPrefix &&
              secondRecovered.stateCache.entries == secondBaseline.stateCache.entries &&
              secondRecovered.stateCache.bytes == secondBaseline.stateCache.bytes &&
              readyEventCount(output) == 1,
          "second warm cycle changed retained identity or cache state");
  requireCurrentModelAccounts();
  serve(903);
}

void testRealColdAndWarmAdoption() {
  ::setenv("SPLASH_RESIDENCY_EVIDENCE", "1", 1);
  std::optional<uint64_t> receiptAfter;
  const std::string evidence = test::capturedStderr([&] { exerciseRealColdAndWarmAdoption(receiptAfter); });
  ::unsetenv("SPLASH_RESIDENCY_EVIDENCE");
  for (const auto *phase : {"phase=before_detach", "phase=worker_disposal_start",
                            "phase=worker_disposal_end", "phase=after_disposal",
                            "phase=after_recovery"})
    require(evidence.find(phase) != std::string::npos, "missing residency evidence phase");
  auto record = [&](std::string_view phase) {
    const auto at = evidence.find(phase);
    return evidence.substr(at, evidence.find('\n', at) - at);
  };
  const auto before = record("phase=before_detach");
  const auto after = record("phase=after_disposal");
  const auto recovered = record("phase=after_recovery");
  auto value = [](const std::string &line, const std::string &key) {
    const auto start = line.find(key + "=");
    require(start != std::string::npos, "missing evidence field");
    const auto first = start + key.size() + 1;
    return line.substr(first, line.find(' ', first) - first);
  };
  for (const auto *key : {"resource_graph_identity", "cache_identity", "write_behind_identity"})
    require(value(before, key) == value(after, key) && value(before, key) == value(recovered, key),
            "witness identities changed");
  require(receiptAfter && value(after, "backend_allocated_bytes_after") == std::to_string(*receiptAfter),
          "logged backend allocation differs from the disposal receipt");
  require(value(before, "holder") == "Owner" && value(before, "model_resident") == "1" &&
          value(before, "engine_published") == "1" && value(after, "holder") == "Owner" &&
          value(after, "model_resident") == "0" && value(after, "engine_published") == "0" &&
          value(after, "disposal_complete") == "1" && value(recovered, "model_resident") == "1" &&
          value(recovered, "engine_published") == "1", "invalid residency evidence");
  const std::string disabled = test::capturedStderr([&] { exerciseRealColdAndWarmAdoption(receiptAfter); });
  require(disabled.find("[SPLASH_RESIDENCY_EVIDENCE]") == std::string::npos,
          "disabled residency evidence was emitted");
}

// Opt-in host integration: installed weights, production lifecycle and inference.
void testInstalledModelRecovery(const char *root) {
  std::vector<uint8_t> output;
  RuntimeMetrics metrics;
  RuntimeBootstrapConfig config;
  config.resources.metallibPath = gMetallib;
  config.resources.modelRoot = root;
  config.resources.model = model::servedFor(model::inspectModelRoot(root), 0);
  config.resources.buildId = "installed-recovery-test";
  config.resources.maximumMemoryBytes = 37795712204ULL; // 35.2 GiB

  config.lifecycleWake = [] {};
  auto bootstrap = RuntimeBootstrap::start(std::move(config),
      [&output](std::span<const uint8_t> bytes) { output.insert(output.end(), bytes.begin(), bytes.end()); },
      [] { return 0.0; });
  bootstrap->announceReady();
  auto serve = [&](uint64_t id) {
    protocol::RequestFrame frame;
    frame.requestId = id;
    frame.absoluteDeadlineUnixMicros = std::numeric_limits<uint64_t>::max();
    frame.remainingDeadlineMicros = 300'000'000;
    frame.logicalMaxOutputTokens = 1;
    frame.promptTokens = {1, 2, 3};
    const auto completed = bootstrap->nativeLoop().snapshot().completed;
    require(bootstrap->nativeLoop().receive(protocol::peer::serialize(frame)), "request connection closed");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::minutes(5);
    while (std::chrono::steady_clock::now() < deadline && bootstrap->nativeLoop().snapshot().completed == completed) {
      static_cast<void>(bootstrap->nativeLoop().tick());
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    require(bootstrap->nativeLoop().snapshot().completed == completed + 1, "real request did not complete");
    unsigned done = 0, errors = 0, tokens = 0;
    for (const auto &event : protocol::peer::decodeEvents(output)) {
      if (const auto *e = std::get_if<protocol::DoneEvent>(&event); e && e->requestId == id) ++done;
      if (const auto *e = std::get_if<protocol::ErrorEvent>(&event); e && e->requestId == id) ++errors;
      if (const auto *e = std::get_if<protocol::TokensEvent>(&event); e && e->requestId == id) tokens += e->tokens.size();
    }
    require(done == 1 && errors == 0 && tokens > 0, "real request lacked a successful generated-token completion");
    std::cout << "completed request " << id << " with " << tokens << " generated token(s)" << std::endl;
  };
  bootstrap->observePower(LifecyclePower::AC);
  pumpReal(*bootstrap, [&] { return bootstrap->lifecycleStatus().inferenceReady; }, "initial admission failed");
  serve(1);
  bootstrap->observePower(LifecyclePower::Battery);
  pumpReal(*bootstrap, [&] { return bootstrap->lifecycleStatus().state == LifecycleState::Suspended &&
      !bootstrap->nativeLoop().hasEngine() && !bootstrap->resources().modelResident() &&
      !RuntimeBootstrapTestAccess::workerRunning(*bootstrap); }, "physical release failed", 300000);
  std::cout << "physical release completed" << std::endl;
  bootstrap->observePower(LifecyclePower::AC);
  pumpReal(*bootstrap, [&] { return bootstrap->lifecycleStatus().inferenceReady ||
      bootstrap->lifecycleStatus().state == LifecycleState::RecoveryFailed; }, "recovery timed out", 300000);
  require(bootstrap->lifecycleStatus().inferenceReady,
          "recovery failed: " + bootstrap->lifecycleStatus().lastError);
  serve(2);
  require(readyEventCount(output) == 1, "recovery emitted another ReadyEvent");
}

// Two bounded execs of this binary: a broken guard must fail this check rather
// than hang the ordinary suite. No forked Metal state and no process-group kill.
void testBlockedGateFailureCleanup(const char *executable, const char *mode) {
  std::unique_ptr<FILE, decltype(&std::fclose)> output(std::tmpfile(), &std::fclose);
  require(bool(output), "could not capture blocked-gate child output");
  const std::string selector = std::string(kGateFailureSelector) + "=";
  std::string selected = selector + mode;
  std::vector<char *> environment;
  for (char **entry = environ; *entry; ++entry) {
    if (!std::string_view(*entry).starts_with(selector))
      environment.push_back(*entry);
  }
  environment.push_back(selected.data());
  environment.push_back(nullptr);
  char *arguments[] = {const_cast<char *>(executable), gMetallib.data(), nullptr};
  posix_spawn_file_actions_t actions;
  require(posix_spawn_file_actions_init(&actions) == 0,
          "could not initialize blocked-gate spawn actions");
  int error = posix_spawn_file_actions_adddup2(&actions, fileno(output.get()),
                                             STDOUT_FILENO);
  pid_t pid = -1;
  if (!error)
    error = posix_spawnp(&pid, executable, &actions, nullptr, arguments,
                         environment.data());
  posix_spawn_file_actions_destroy(&actions);
  require(error == 0, "could not exec blocked-gate child");
  struct ChildCleanup {
    pid_t pid;
    ~ChildCleanup() {
      if (pid <= 0) return;
      kill(pid, SIGKILL);
      while (waitpid(pid, nullptr, 0) < 0 && errno == EINTR) {}
    }
  } child{pid};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
  int status = 0;
  for (;;) {
    const pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == pid) {
      child.pid = -1;  // Already reaped; never signal a recycled PID.
      break;
    }
    require(result == 0 || (result < 0 && errno == EINTR),
            "could not wait for blocked-gate child");
    require(std::chrono::steady_clock::now() < deadline,
            std::string("blocked-gate cleanup timed out: ") + mode);
    // Only parent supervision waits here; fixture interleavings use the gate.
    poll(nullptr, 0, 10);
  }
  require(std::fseek(output.get(), 0, SEEK_SET) == 0,
          "could not read blocked-gate child output");
  std::string captured;
  std::array<char, 4096> buffer;
  while (const size_t count = std::fread(buffer.data(), 1, buffer.size(), output.get()))
    captured.append(buffer.data(), count);
  const std::string expected = std::string("PASS blocked-gate failure cleanup: ") +
      mode + " blocked, owner exception, RAII release, callback retired, joined\n";
  require(WIFEXITED(status) && WEXITSTATUS(status) == EXIT_SUCCESS &&
              captured == expected,
          std::string("blocked-gate child lacked expected completion: ") + mode +
              " (status " + std::to_string(status) + ")\n" + captured);
  std::cout << captured;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    try {
      require(argc == 1 || argc == 2, "expected an optional metallib path");
      gMetallib = argc == 2 ? argv[1]
                            : (std::filesystem::path(argv[0]).parent_path().parent_path() /
                               "splash.metallib")
                                  .string();

      if (const char *mode = std::getenv(kGateFailureSelector)) {
        gGateFailure.mode = mode;
        require(gGateFailure.mode == "slot" || gGateFailure.mode == "reap",
                "unknown blocked-gate failure selector");
        if (gGateFailure.mode == "slot")
          testCompletionWakeBeforeSlotClearDefersTheNextOperation();
        else
          testShutdownAroundTheReaper();
        throw std::runtime_error("blocked-gate fixture never injected its exception");
      }

      if (const char *root = std::getenv("SPLASH_INSTALLED_RECOVERY_MODEL")) {
        testInstalledModelRecovery(root);
        return EXIT_SUCCESS;
      }

      if (std::getenv("SPLASH_COLD_CONTEXT_ONLY")) {
        testColdStaticCapabilitiesAndExplicitContext();
        testColdConstrainedPlanAndRelaunch();
        return EXIT_SUCCESS;
      }

      if (std::getenv("SPLASH_COLD_CANCEL_ONLY")) {
        testCancelledColdAuthorityReturnsOnShutdown();
        return EXIT_SUCCESS;
      }

      if (std::getenv("SPLASH_T053_ONLY")) {
        testFdRecoveryRevisionFence();
        return EXIT_SUCCESS;
      }

      testBlockedGateFailureCleanup(argv[0], "slot");
      testBlockedGateFailureCleanup(argv[0], "reap");

      // Upstream warmup/report characterization.
      testRuntimeCacheIdentityReportsTheLoadedModel();
      testAllNativeWarmupsPrecedeReady();
      testWarmupHoldsTheRunway();
      testPrefillRowClassesAreRequired();
      testBudgetLimitedWarmupTriesOnlyWidthsThatFit();
      testOptionalAllocationFailuresAreMemoryLimited();
      testResourceFailureClassificationSurvivesBootstrap();
      testRequiredWarmupPreservesAllocationFailure();
      testFinalHostPressurePreventsReady();
      testWarmupErrorsCannotMasqueradeAsMemoryLimits();
      testExceptionsAndMemoryAreFailClosed();
      testReadyEventForTheServedModel();
      testStartFailuresAreClassed();
      testAStartCommandOutOfMemoryIsCommandMemoryAndNotRetried();
      testStartupRetryWindowOpensAtFirstFailure();
      testProtocolLimitsFollowTheModel();

      // [T021] Type/channel ownership, device-free.
      testCompletionEnvelopeIsMoveOnly();
      testCompletionChannelPublishOnceClaimOnce();

      // [T020/T022/T021-integration] The asynchronous mechanism over the real
      // graph's own lease (GPU; needs the metallib beside this build).
      testFdRecoveryRevisionFence();
      testLifecyclePumpSuspendAndRecoverOnRealGraph();
      testDuplicateACObservationAdvancesStatusOrder();
      testResidencyWorkerIsSingleAndSerial();
      testStaleAndFailedCandidateIsRetainedNotPublished();

      // [T024] Production physical detach: the stratum moves at the safe point
      // and dies on the residency worker; the retained graph keeps its identity.
      // [T023] The cold model-less start. [T025] Control responsiveness under
      // a blocked Worker, and the one explicit join at shutdown.
      testPhysicalSuspensionDetachesStratumOnWorkerThread();
      testColdStaticCapabilitiesAndExplicitContext();
      testColdConstrainedPlanAndRelaunch();
      testColdShellStartServesControlOnlyOnInjectedPower();
      testControlResponsiveWhileWorkerBlocksAndShutdownJoinsIt();
      testCompletionWakeBeforeSlotClearDefersTheNextOperation();
      testShutdownClosesReadyAdmissionImmediately();
      testShutdownSupersedesSuspendedAndRecovering();

      // [T029 Gate A] The cold-first candidate's OWN graph and authority.
      testColdCandidateOwnAuthorityOnItsOwnLease();
      // [T032 Gates B, C, D] The one serial stale-candidate reaper: stale
      // after publication, cold/warm disposal order, and shutdown around it.
      testStaleCandidateIsReapedByTheOneReaper();
      testReaperDisposesColdAndWarmCandidatesInOrder();
      testShutdownClaimsPublishedWarmCandidate();
      testShutdownAroundTheReaper();

      // [T031 prerequisite] The production candidate construction (cold and warm) and
      // [T030] the exact published Engine's capacity in the request telemetry.
      testProductionWarmCandidateIsBuiltAgainstTheRetainedGraph();
      testEffectiveContextIsThePublishedEngineWindow();
      testProductionColdCandidateAssemblesItsOwnGraph();
      testWarmPreparationExceptionRestoresCandidate();
      testNewerACAfterCommittedRelease();
      testNewerACDoesNotAcceptIncompleteRelease();
      testColdBeginServingFailureRollsBack();
      testColdFinalFenceInterleavings();
      testMailboxInvalidatesColdStaging();
      testCancelledColdAuthorityReturnsOnShutdown();
      testDisabledPolicyRealStartup();
      testAdmittedRequestDrainsAcrossBattery();
      testRealColdAndWarmAdoption();

      std::cout << "native bootstrap tests passed\n";
      return EXIT_SUCCESS;
    } catch (const BlockedGateFailure &) {
      // A dedicated exception is accepted only after the fixture's guard and
      // all callback captures have unwound. Earlier assertion failures cannot
      // impersonate the intentional failure or its completed join.
      if (!gGateFailure.injected || !gGateFailure.unwinding ||
          !gGateFailure.released || !gGateFailure.callbackRetired ||
          !gGateFailure.joined) {
        std::cerr << "blocked-gate failure cleanup witnesses incomplete\n";
        return EXIT_FAILURE;
      }
      std::cout << "PASS blocked-gate failure cleanup: " << gGateFailure.mode
                << " blocked, owner exception, RAII release, callback retired, joined\n";
      return EXIT_SUCCESS;
    } catch (const std::exception &error) {
      std::cerr << "native bootstrap tests failed: " << error.what() << '\n';
      return EXIT_FAILURE;
    }
  }
}
