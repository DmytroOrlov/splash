#include "Q8PageFormatReference.hpp"
#include "TestImmediateTicket.hpp"
#include "engine/Cache.hpp"
#include "engine/Bootstrap.hpp"
#include "engine/FdTransport.hpp"
#include "engine/PowerSource.hpp"
#include "TestModel.hpp"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <barrier>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <latch>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <span>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>
#include <unistd.h>

namespace splash::engine {

class RuntimeBootstrapTestAccess final {
public:
  static SuspendProgress advanceSuspendObserved(RuntimeBootstrap &bootstrap,
                                                bool engineDrained,
                                                bool transfersInFlight) {
    return bootstrap.advanceSuspendObserved(engineDrained, transfersInFlight);
  }

  static void installModelResidency(
      RuntimeBootstrap &bootstrap,
      std::unique_ptr<model::RuntimeModel> runtime,
      std::unique_ptr<ModelPackageResidency> package) {
    bootstrap.model_ = std::move(runtime);
    bootstrap.modelResidency_ = std::move(package);
  }

  static bool hasModelPackage(const RuntimeBootstrap &bootstrap) noexcept {
    return bootstrap.modelResidency_ != nullptr;
  }

  static bool inferenceAdmissionOpen(const RuntimeBootstrap &bootstrap) {
    if (!bootstrap.admissionGate_)
      return false;
    std::lock_guard lock(bootstrap.admissionGate_->mutex);
    return bootstrap.admissionGate_->inferenceReady;
  }

  static void installTestRecoverySpec(RuntimeBootstrap &bootstrap,
                                      EngineConfig engine,
                                      std::function<void()> lifecycleWake = {}) {
    RuntimeBootstrap::RecoverySpec spec;
    spec.modelRoot = "/detached/model/root";
    spec.model = model::ModelDescriptor{};
    spec.kvFormat = kv::Format::Int8;
    spec.buildId = "test-build";
    spec.memoryPressure = [] { return MemoryPressure::Normal; };
    spec.cancelled = [] { return false; };
    spec.hostAvailableMemory = [] {
      return std::optional<uint64_t>(8ULL << 30);
    };
    spec.lifecycleWake = std::move(lifecycleWake);
    spec.engine = std::move(engine);
    bootstrap.recoverySpec_ = std::move(spec);
  }

  static void createPrivateCandidate(
      RuntimeBootstrap &bootstrap,
      std::unique_ptr<ModelPackageResidency> package,
      std::unique_ptr<model::RuntimeModel> model, Cache &cache,
      uint64_t revision) {
    auto candidate = bootstrap.makeRecoveryCandidate(
        std::move(package), std::move(model), cache,
        bootstrap.recoverySpec_->engine, revision);
    std::lock_guard lock(bootstrap.recoveryMutex_);
    bootstrap.recoveryCandidate_ = std::move(candidate);
  }

  static bool hasRecoveryCandidate(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.recoveryMutex_);
    return bootstrap.recoveryCandidate_ != nullptr;
  }

  static Engine *recoveryCandidateEngine(RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.recoveryMutex_);
    return bootstrap.recoveryCandidate_
               ? bootstrap.recoveryCandidate_->engine.get()
               : nullptr;
  }

  static Engine *publishedEngine(RuntimeBootstrap &bootstrap) {
    return bootstrap.nativeLoop_->core_.get();
  }

  static std::optional<RuntimeBootstrap::RecoveryPublication>
  publishRecoveryResidency(RuntimeBootstrap &bootstrap) {
    return bootstrap.publishRecoveryResidency();
  }

  static bool finalizeRecoveryPublication(
      RuntimeBootstrap &bootstrap,
      const RuntimeBootstrap::RecoveryPublication &publication) {
    return bootstrap.finalizeRecoveryPublication(publication);
  }

  static bool tryPublishPrivateEngine(RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.recoveryMutex_);
    if (!bootstrap.recoveryCandidate_)
      return false;
    return bootstrap.nativeLoop_->tryPublishEngine(
        bootstrap.recoveryCandidate_->engine);
  }

  static void injectNativePublicationBlockers(RuntimeBootstrap &bootstrap) {
    bootstrap.nativeLoop_->telemetry_.emplace(
        9001, NativeRuntime::RequestTelemetry{});
    bootstrap.nativeLoop_->pendingMasks_.emplace(
        9002, NativeRuntime::PendingMask{9001, 1});
  }

  static void clearNativePublicationBlockers(RuntimeBootstrap &bootstrap) {
    bootstrap.nativeLoop_->telemetry_.clear();
    bootstrap.nativeLoop_->pendingMasks_.clear();
  }

  static bool recoveryCandidateComplete(const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.recoveryMutex_);
    return bootstrap.recoveryCandidate_ &&
           bootstrap.recoveryCandidate_->modelResidency &&
           bootstrap.recoveryCandidate_->model &&
           bootstrap.recoveryCandidate_->engine;
  }

  static uint64_t recoveryCandidateRevision(
      const RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.recoveryMutex_);
    return bootstrap.recoveryCandidate_->lifecycleRevision;
  }

  static model::RuntimeModel *recoveryCandidateModel(
      RuntimeBootstrap &bootstrap) {
    return bootstrap.recoveryCandidate_->model.get();
  }

  static const void *recoveryCandidateAddress(
      RuntimeBootstrap &bootstrap) {
    return bootstrap.recoveryCandidate_.get();
  }

  static bool candidateEngineGonePackageRetained(const void *address) {
    const auto *candidate =
        static_cast<const RuntimeBootstrap::RecoveryCandidate *>(address);
    return candidate && !candidate->engine && candidate->modelResidency;
  }

  static CacheSnapshot recoveryCandidateCacheSnapshot(
      RuntimeBootstrap &bootstrap) {
    return bootstrap.recoveryCandidate_->engine->snapshot().resources;
  }

  static void destroyRecoveryCandidate(RuntimeBootstrap &bootstrap) {
    std::lock_guard lock(bootstrap.recoveryMutex_);
    bootstrap.recoveryCandidate_.reset();
  }

  static RecoveryProgress advanceRecovery(RuntimeBootstrap &bootstrap) {
    return bootstrap.advanceRecovery();
  }

  static void installRecoveryBuilder(
      RuntimeBootstrap &bootstrap,
      std::function<void(uint64_t)> builder) {
    std::lock_guard lock(bootstrap.recoveryMutex_);
    bootstrap.recoveryBuilderForTesting_ = std::move(builder);
  }

  static void buildRecoveryCandidate(RuntimeBootstrap &bootstrap) {
    RuntimeBootstrap::RecoverySpec spec;
    uint64_t revision = 0;
    {
      std::lock_guard lock(bootstrap.lifecycleMutex_);
      revision = bootstrap.lifecycle_.revision;
      spec = *bootstrap.recoverySpec_;
    }
    bootstrap.buildRecoveryCandidate(revision, std::move(spec));
  }
};

} // namespace splash::engine

namespace {

using namespace splash;
using namespace splash::engine;
namespace runtime = splash::engine;

class FakePowerSource final : public PowerSource {
public:
  explicit FakePowerSource(LifecyclePower initial) : current_(initial) {}
  ~FakePowerSource() override { stop(); }

  LifecyclePower current() const noexcept override {
    std::lock_guard lock(mutex_);
    return current_;
  }

  void start(Callback callback) override {
    if (!callback)
      throw std::invalid_argument("fake power observer requires a callback");
    std::lock_guard lock(mutex_);
    callback_ = std::move(callback);
    stopped_ = false;
  }

  void stop() noexcept override {
    try {
      std::unique_lock lock(mutex_);
      stopped_ = true;
      callback_ = {};
      condition_.notify_all();
      condition_.wait(lock, [this] { return activeCallbacks_ == 0; });
    } catch (...) {
    }
  }

  void emit(LifecyclePower power) {
    Callback callback;
    {
      std::lock_guard lock(mutex_);
      current_ = power;
      if (stopped_ || !callback_)
        return;
      callback = callback_;
      ++activeCallbacks_;
    }
    try {
      callback(power);
    } catch (...) {
    }
    {
      std::lock_guard lock(mutex_);
      --activeCallbacks_;
      condition_.notify_all();
    }
  }

  void waitUntilStopped() {
    std::unique_lock lock(mutex_);
    condition_.wait(lock, [this] { return stopped_; });
  }

private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  Callback callback_;
  LifecyclePower current_;
  size_t activeCallbacks_ = 0;
  bool stopped_ = true;
};

void waitFor(std::condition_variable &condition, std::unique_lock<std::mutex> &lock,
             const std::function<bool()> &predicate,
             std::string_view failureMessage) {
  if (!condition.wait_for(lock, std::chrono::seconds(5), predicate))
    throw std::runtime_error(std::string(failureMessage));
}

struct ReleaseLatchesOnExit final {
  std::vector<std::latch *> latches;
  ~ReleaseLatchesOnExit() {
    for (std::latch *latch : latches) {
      if (latch && !latch->try_wait())
        latch->count_down();
    }
  }
};

struct JoinThreadsOnExit final {
  std::vector<std::thread *> threads;
  ~JoinThreadsOnExit() {
    for (std::thread *thread : threads) {
      if (thread && thread->joinable())
        thread->join();
    }
  }
};

struct StopTransportThreadOnExit final {
  FdTransport &transport;
  std::thread &thread;
  ~StopTransportThreadOnExit() {
    transport.requestShutdown();
    if (thread.joinable())
      thread.join();
  }
};

struct PipePair final {
  int readFd = -1;
  int writeFd = -1;
  PipePair() {
    int descriptors[2];
    if (pipe(descriptors) < 0)
      throw std::runtime_error("unable to create test pipe");
    readFd = descriptors[0];
    writeFd = descriptors[1];
  }
  ~PipePair() {
    if (readFd >= 0)
      close(readFd);
    if (writeFd >= 0)
      close(writeFd);
  }
};

// Pre-split API characterization: start publishes a single aggregate owner;
// its accessors expose the aggregate resources, Bootstrap-owned model runtime,
// and native loop by reference. These assertions intentionally do not claim
// independent destruction or release of any residency stratum.
static_assert(std::is_same_v<
              decltype(RuntimeBootstrap::start(
                  std::declval<RuntimeBootstrapConfig>(),
                  std::declval<NativeRuntime::ByteSink>(),
                  std::declval<NativeRuntime::StatusProvider>())),
              std::unique_ptr<RuntimeBootstrap>>);
static_assert(std::is_same_v<
              decltype(RuntimeBootstrap::startModelLess(
                  std::declval<RuntimeBootstrapConfig>(),
                  std::declval<NativeRuntime::ByteSink>(),
                  std::declval<NativeRuntime::StatusProvider>())),
              std::unique_ptr<RuntimeBootstrap>>);
static_assert(std::is_same_v<
              decltype(std::declval<RuntimeBootstrap &>().resources()),
              RuntimeResources &>);
static_assert(std::is_same_v<
              decltype(std::declval<RuntimeBootstrap &>()
                           .modelPackageResidency()),
              ModelPackageResidency &>);
static_assert(std::is_same_v<
              decltype(std::declval<RuntimeBootstrap &>().modelRuntime()),
              model::RuntimeModel &>);
static_assert(std::is_same_v<
              decltype(std::declval<RuntimeBootstrap &>().nativeLoop()),
              NativeRuntime &>);

void require(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}

void testWarmupLaneComparisons() {
  const model::WarmupLaneResult baseline{
      {17, 32, {101, 102}, false, DecodeStage::Regular, 7, 2, 0}, 103, 34};
  require(baseline == baseline, "warmup result equality is not reflexive");
  require(baseline.sameWorkAs(baseline), "warmup work equality is not reflexive");
  auto requireDifferent = [&](auto change, bool changesWork = true) {
    auto candidate = baseline;
    change(candidate);
    require(candidate != baseline, "warmup comparison ignored an observable result");
    require(candidate.sameWorkAs(baseline) != changesWork,
            "warmup work comparison confused token identity and work counts");
  };
  requireDifferent([](auto &value) { ++value.step.requestId; });
  requireDifferent([](auto &value) { ++value.step.consumedPromptTokens; });
  requireDifferent([](auto &value) { ++value.step.outputTokens[0]; }, false);
  requireDifferent([](auto &value) { value.step.outputTokens.pop_back(); });
  requireDifferent([](auto &value) { value.step.finished = true; });
  requireDifferent([](auto &value) {
    value.step.nextDecodeStage = DecodeStage::RequestInitialMask;
  });
  requireDifferent([](auto &value) { ++value.step.draftedTokens; });
  requireDifferent([](auto &value) { ++value.step.acceptedDraftTokens; });
  requireDifferent([](auto &value) { ++value.step.outputTokensWithoutKv; });
  requireDifferent([](auto &value) { ++*value.pendingToken; }, false);
  requireDifferent([](auto &value) { value.pendingToken.reset(); });
  requireDifferent([](auto &value) { ++value.committedTokens; });
  std::vector lanes{baseline, baseline};
  ++lanes[1].step.requestId;
  auto reordered = lanes;
  std::swap(reordered[0], reordered[1]);
  require(lanes != reordered, "warmup comparison ignored batch-plan lane order");
  require(lanes != std::vector{baseline}, "warmup comparison ignored missing lanes");
}

class TemporaryModelRoot final {
public:
  TemporaryModelRoot() {
    path_ = std::filesystem::temp_directory_path() /
            ("splash-geometry-" +
             std::string([NSUUID UUID].UUIDString.UTF8String));
    if (!std::filesystem::create_directory(path_))
      throw std::runtime_error("unable to create temporary model root");
    std::filesystem::create_directories(path_ / "tokenizer");
    std::ofstream config(path_ / "tokenizer" / "config.json");
    config << R"({"text_config":{"model_type":"qwen3_5_text","max_position_embeddings":262144,"hidden_size":5120,"vocab_size":248320}})";
    if (!config)
      throw std::runtime_error("unable to write tokenizer config");
  }
  ~TemporaryModelRoot() { std::filesystem::remove_all(path_); }

  const std::filesystem::path &path() const noexcept { return path_; }
  void write(std::string_view document) const {
    std::ofstream output(path_ / "manifest.json");
    output << document;
    if (!output)
      throw std::runtime_error("unable to write temporary model manifest");
  }

private:
  std::filesystem::path path_;
};

std::string executionManifest(uint32_t draftRows = 8,
                              std::string_view extraGeometry = {}) {
  std::ostringstream out;
  out << R"({"schema_version":3,"model":"Qwen3.8-27B-DFlash2","format":{"name":"splash-packed-q4","q4_bits":4,"q4_group_size":64,"q4_storage_n":256,"section_alignment_bytes":16384,"target_layer_magic":"MDFL0006","draft_layer_magic":"MDFD0004","vision_magic":"MDFV0001"},"execution_geometry":{)"
      << R"("allocation_extent_target_bytes":134217728,)"
      << R"("draft_proposal_tokens":7,)"
      << "\"draft_query_rows\":" << draftRows << ','
      << R"("draft_sliding_window":2048,)"
      << R"("maximum_batch_width":4,)"
      << R"("prefill_token_budget":2048,)"
      << R"("target_kv_block_tokens":32,)"
      << R"("target_verify_rows":8)" << extraGeometry << "}}";
  return out.str();
}

void testInstalledManifestBindsExecutionGeometry() {
  TemporaryModelRoot root;
  root.write(executionManifest());
  static_cast<void>(model::inspectModelPackage(root.path()));

  root.write(executionManifest(7));
  try {
    static_cast<void>(model::inspectModelPackage(root.path()));
    throw std::runtime_error("geometry mismatch was accepted");
  } catch (const std::invalid_argument &error) {
    require(std::string_view(error.what()).find("draft_query_rows") !=
                std::string_view::npos,
            "geometry mismatch did not identify its field");
  }

  root.write(executionManifest(8, R"(,"description":"package metadata")"));
  static_cast<void>(model::inspectModelPackage(root.path()));

  std::string missingGeometry = executionManifest();
  const std::string requiredField = "\"draft_sliding_window\":2048,";
  const size_t field = missingGeometry.find(requiredField);
  require(field != std::string::npos, "test manifest lost required geometry");
  missingGeometry.erase(field, requiredField.size());
  root.write(missingGeometry);
  try {
    static_cast<void>(model::inspectModelPackage(root.path()));
    throw std::runtime_error("missing geometry field was accepted");
  } catch (const std::invalid_argument &error) {
    require(std::string_view(error.what()).find("draft_sliding_window") !=
                std::string_view::npos,
            "missing geometry field did not identify its name");
  }

  std::string wrongStorage = executionManifest();
  const size_t storage = wrongStorage.find("\"q4_storage_n\":256");
  require(storage != std::string::npos, "test manifest lost Q4 storage");
  wrongStorage.replace(storage, std::string("\"q4_storage_n\":256").size(),
                       "\"q4_storage_n\":128");
  root.write(wrongStorage);
  try {
    static_cast<void>(model::inspectModelPackage(root.path()));
    throw std::runtime_error("wrong Q4 storage was accepted");
  } catch (const std::invalid_argument &error) {
    require(std::string_view(error.what()).find("q4_storage_n") !=
                std::string_view::npos,
            "Q4 storage mismatch did not identify the weight format");
  }
}

void testRuntimeCacheNamespaceBindsIdentityOnce() {
  constexpr kv::Layout kvLayout{16, 4, 256};
  const std::string combinedA(64, 'a');
  const std::string combinedB(64, 'b');
  const std::string targetA(64, 'c');
  const std::string targetB(64, 'd');
  const engine::RuntimeCacheIdentity first =
      engine::makeRuntimeCacheIdentity(combinedA, targetA, "build-a",
                                       kvLayout);
  const engine::RuntimeCacheIdentity same =
      engine::makeRuntimeCacheIdentity(combinedA, targetA, "build-a",
                                       kvLayout);
  const engine::RuntimeCacheIdentity modelChanged =
      engine::makeRuntimeCacheIdentity(combinedB, targetA, "build-a",
                                       kvLayout);
  const engine::RuntimeCacheIdentity targetChanged =
      engine::makeRuntimeCacheIdentity(combinedA, targetB, "build-a",
                                       kvLayout);
  const engine::RuntimeCacheIdentity buildChanged =
      engine::makeRuntimeCacheIdentity(combinedA, targetA, "build-b",
                                       kvLayout);
  auto bf16Layout = kvLayout;
  bf16Layout.format = kv::Format::BFloat16;
  const auto formatChanged = engine::makeRuntimeCacheIdentity(
      combinedA, targetA, "build-a", bf16Layout);
  require(first.cacheNamespace != formatChanged.cacheNamespace &&
              first.namespaceSha256 != formatChanged.namespaceSha256,
          "INT8 and BF16 aliased the same prefix-cache namespace");
  require(first.cacheNamespace == same.cacheNamespace &&
              first.namespaceSha256 == same.namespaceSha256,
          "runtime cache namespace is not deterministic");
  require(first.cacheNamespace != modelChanged.cacheNamespace &&
              first.cacheNamespace != targetChanged.cacheNamespace &&
              first.cacheNamespace != buildChanged.cacheNamespace,
          "runtime cache namespace omitted model, layout, or build identity");
  require(kv::matchesLayout(first.kvLayout, kvLayout) &&
              first.kvLayout.modelArtifactSha256 !=
                  targetChanged.kvLayout.modelArtifactSha256,
          "runtime Q8 layout guard omitted the target artifact");
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
  result.supportsPlacementSparse = true;
  return result;
}

EngineMemoryPlan memoryPlan() {
  return requireEngineMemoryPlan(
      device(), test::modelMemoryProfile(2 * kGiB, 1 * kGiB, 1 * kGiB));
}

ActualMemoryReport validActual(const EngineMemoryPlan &plan) {
  const auto &budget = plan.breakdown();
  ActualMemoryReport actual;
  actual.targetWeightsBytes = budget.targetWeightsBytes;
  actual.draftWeightsBytes = budget.draftWeightsBytes;
  actual.visionWeightsBytes = budget.visionWeightsBytes;
  actual.stateResidentBytes = budget.activeStateCellBytes;
  actual.sharedPrefillBytes = budget.sharedPrefillBytes;
  actual.sharedDecodeBytes = budget.sharedDecodeBytes;
  actual.kvResidentBytes = budget.kvExtentBytes;
  actual.backendAllocatedBytes =
      actual.targetWeightsBytes + actual.draftWeightsBytes +
      actual.visionWeightsBytes +
      actual.stateResidentBytes + actual.sharedPrefillBytes +
      actual.sharedDecodeBytes + actual.kvResidentBytes;
  actual.deviceCurrentAllocatedBytes = actual.backendAllocatedBytes;
  actual.devicePeakAllocatedBytes = actual.backendAllocatedBytes;
  // Model warmup estimates add the pipeline and runtime reserves.
  actual.estimatedWarmupPeakBytes = actual.backendAllocatedBytes +
                                    budget.pipelineReserveBytes +
                                    budget.runtimeOverheadReserveBytes;
  return actual;
}

class Backing final : public KvBacking {
public:
  explicit Backing(uint32_t pages) : resident_(pages, true) {}
  uint32_t pageCount() const noexcept override { return resident_.size(); }
  uint64_t bytesPerPage() const noexcept override { return 4096; }
  bool isResident(uint32_t page) const override { return resident_.at(page); }
  splash::metal::AllocationResult ensureResident(uint32_t page) override {
    resident_.at(page) = true;
    return true;
  }
  bool releaseBackingForPage(uint32_t page) override {
    const bool resident = resident_.at(page);
    resident_.at(page) = false;
    return resident;
  }
  uint32_t extentFirstPage(uint32_t page) const override {
    return page - page % 4;
  }
  uint32_t extentPageCount(uint32_t page) const override {
    return std::min<uint32_t>(4, resident_.size() - extentFirstPage(page));
  }
private:
  std::vector<bool> resident_;
};

class State final : public CompositeState {
public:
  uint64_t bytes() const noexcept override { return 64; }
};

class HeldRequestTicket final : public ModelBatchTicket {
public:
  HeldRequestTicket(std::vector<ModelStepResult> results,
                    std::shared_ptr<bool> ready)
      : results_(std::move(results)), ready_(std::move(ready)) {}
  bool ready() const noexcept override { return *ready_; }
  std::vector<ModelStepResult> wait() override { return std::move(results_); }
  double wallMilliseconds() const noexcept override { return 0.0; }

private:
  std::vector<ModelStepResult> results_;
  std::shared_ptr<bool> ready_;
};

class Executor final : public model::RuntimeModel {
public:
  explicit Executor(uint64_t estimatedPeak, int failingStep = -1,
                    int throwingStep = -1)
      : estimatedPeak_(estimatedPeak), failingStep_(failingStep),
        throwingStep_(throwingStep) {}
  ~Executor() override {
    if (destructionHook)
      destructionHook();
  }

  StateAdmission begin(const ModelRequest &) override {
    return {0, StateFailure::None};
  }
  void suspend(uint64_t) override {}
  StateAdmission resume(const ModelRequest &) override {
    return {0, StateFailure::None};
  }
  void restore(uint64_t, uint32_t, std::shared_ptr<const CompositeState>,
                     bool) override {}
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
    std::vector<ModelStepResult> results =
        plan.kind == WorkKind::Prefill ? prefill(plan, items)
                                       : decode(plan, items);
    if (heldRequestTicketReady) {
      if (results.empty()) {
        for (const ModelBatchItem &item : items) {
          ModelStepResult result;
          result.requestId = item.requestId;
          result.consumedPromptTokens =
              plan.kind == WorkKind::Prefill ? item.tokenCount : 0;
          results.push_back(std::move(result));
        }
      }
      return std::make_unique<HeldRequestTicket>(
          std::move(results), heldRequestTicketReady);
    }
    return test::immediateTicket(std::move(results), completion);
  }
  std::unique_ptr<ModelBatchTicket>
  submitTransfers(std::function<void()>) override {
    ++transferSubmissions;
    return nullptr;
  }
  std::shared_ptr<const CompositeState> snapshot(uint64_t) override {
    return std::make_shared<State>();
  }
  uint64_t reclaimIdleState(bool) noexcept override { return 0; }
  void provideMask(uint64_t, std::span<const uint32_t>) override {}
  void end(uint64_t) override {}

  model::WarmupStepResult warmupPrefill(uint32_t rows) override {
    if (!rows || rows > model::ExecutionLimits::prefillTokenBudget)
      throw std::invalid_argument("invalid prefill warmup rows");
    lastPrefillRows = rows;
    return warmup(0);
  }
  model::WarmupStepResult warmupDecodeBatch(uint32_t width) override {
    if (width < 1 || width > model::ExecutionLimits::maximumBatchWidth) {
      throw std::invalid_argument("invalid decode width");
    }
    return warmup(static_cast<int>(width));
  }
  model::WarmupStepResult warmupDraftVerifyCommit() override {
    return warmup(5);
  }
  model::WarmupStepResult warmupCompositeStateRestore() override {
    return warmup(6);
  }
  model::ModelMemoryActual actualRuntimeMemory() const override {
    return {1, 1};
  }
  model::ModelTelemetry telemetry() const noexcept override {
    return {};
  }

  std::vector<int> calls;
  uint32_t lastPrefillRows = 0;
  std::function<void(int, model::WarmupStepResult &)> warmupHook;
  std::shared_ptr<bool> heldRequestTicketReady;
  std::function<void()> destructionHook;
  uint32_t transferSubmissions = 0;

private:
  model::WarmupStepResult warmup(int step) {
    calls.push_back(step);
    if (step == throwingStep_) {
      throw std::runtime_error("injected warmup exception");
    }
    model::WarmupStepResult result{
        step != failingStep_, estimatedPeak_, "measured", 0.001, {}};
    if (warmupHook)
      warmupHook(step, result);
    return result;
  }

  uint64_t estimatedPeak_ = 0;
  int failingStep_ = -1;
  int throwingStep_ = -1;
};

class Harness final {
public:
  Harness(const EngineMemoryPlan &plan, int failingStep = -1,
          int throwingStep = -1, bool failReadyWrite = false)
      : backing_(16), pool_(backing_),
        resources_(pool_, CacheNamespace{}),
        executor_(validActual(plan).estimatedWarmupPeakBytes, failingStep,
                  throwingStep),
        loop_(
            loopConfig(), resources_, executor_,
            [this, failReadyWrite](std::span<const uint8_t> bytes) {
              if (failReadyWrite) {
                throw std::runtime_error("injected output failure");
              }
              output_.insert(output_.end(), bytes.begin(), bytes.end());
            },
            [] { return std::string("{\"schema_version\":5}"); }) {}

  Executor &executor() noexcept { return executor_; }
  engine::NativeRuntime &loop() noexcept { return loop_; }
  Cache &cache() noexcept { return resources_; }
  uint32_t residentBackingPages() const {
    uint32_t count = 0;
    for (uint32_t page = 0; page < backing_.pageCount(); ++page)
      count += backing_.isResident(page);
    return count;
  }
  const std::vector<uint8_t> &output() const noexcept { return output_; }
  void retainPrefixState() {
    std::vector<uint32_t> prompt(65);
    for (uint32_t i = 0; i < prompt.size(); ++i)
      prompt[i] = 1000 + i;
    resources_.beginRequest(901);
    require(resources_.ensureTokens(901, prompt.size()).granted(),
            "retained-prefix fixture could not acquire KV pages");
    const uint64_t block =
        resources_.publishCommittedBlocks(901, prompt, 64);
    require(block != 0, "retained-prefix fixture did not publish a KV block");
    resources_.publishCompositeState(block, std::make_shared<State>());
    resources_.endRequest(901);
  }

private:
  static engine::NativeLoopConfig loopConfig() {
    engine::NativeLoopConfig config;
    config.engine.maxContext = 1024;
    return config;
  }

  Backing backing_;
  KvPool pool_;
  engine::Cache resources_;
  Executor executor_;
  std::vector<uint8_t> output_;
  engine::NativeRuntime loop_;
};

RuntimeBootstrapReport warmup(Harness &harness, const EngineMemoryPlan &plan);
size_t readyEventCount(const std::vector<uint8_t> &output);

void testPreSplitBootstrapHarnessObservesCoupledGraph() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness harness(plan);
  const CacheSnapshot before = harness.cache().snapshot();
  require(harness.residentBackingPages() == 16 &&
              before.pool.pagesResident == 16 &&
              before.activeRequests == 0 && !harness.loop().ready(),
          "pre-split harness did not expose retained cache/backing and native loop");

  const RuntimeBootstrapReport report = warmup(harness, plan);
  const CacheSnapshot after = harness.cache().snapshot();
  require(report.ready && harness.loop().ready() &&
              harness.executor().calls.size() == 7 &&
              harness.residentBackingPages() == 16 &&
              after.pool.pagesResident == before.pool.pagesResident &&
              after.activeRequests == 0,
          "pre-split bootstrap changed retained resources during warmup");
}

void testModelLessControlShellAndEnginePublication() {
  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 1024;
  std::vector<uint8_t> output;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });

  NativeRuntime &loop = bootstrap->nativeLoop();
  require(!bootstrap->hasResources() && !bootstrap->hasModelRuntime() &&
              !loop.hasEngine() && loop.idle() && !loop.commandInFlight() &&
              !loop.tick() && loop.runControl([] { return true; }) &&
              loop.ready(),
          "model-less bootstrap did not expose a usable control shell");

  auto request = protocol::serializeMessage(
      protocol::Message{protocol::StatusRequestFrame{41}});
  require(request && loop.receive(*request.value),
          "model-less NativeRuntime rejected a passive status request");
  protocol::FrameParser parser;
  auto parsed = parser.consume(output);
  auto decoded = parsed.frame ? protocol::decodeFrame(*parsed.frame)
                              : protocol::ProtocolResult<protocol::Message>{};
  const auto *ready = decoded
                          ? std::get_if<protocol::ReadyEvent>(&*decoded.value)
                          : nullptr;
  require(ready && ready->engineInstanceId == 1 &&
              ready->maxContextTokens == 1024,
          "model-less bootstrap did not emit its static control ReadyEvent");
  parsed = parser.consume(std::span<const uint8_t>(output).subspan(
      parsed.consumedBytes));
  decoded = parsed.frame ? protocol::decodeFrame(*parsed.frame)
                         : protocol::ProtocolResult<protocol::Message>{};
  const auto *status = decoded
                           ? std::get_if<protocol::StatusJsonEvent>(
                                 &*decoded.value)
                           : nullptr;
  require(status && status->correlationId == 41 &&
              status->json == R"({"schema_version":5})",
          "model-less NativeRuntime did not keep status service available");

  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  loop.publishEngine(dependencies.cache(), dependencies.executor());
  require(loop.hasEngine() && loop.snapshot().maximumContextTokens == 1024,
          "NativeRuntime failed to publish an Engine over valid dependencies");
  loop.destroyEngine();
  require(!loop.hasEngine() && loop.idle() && !loop.tick() &&
              loop.runControl([] { return true; }),
          "NativeRuntime control shell failed after Engine destruction");

  output.clear();
  request = protocol::serializeMessage(
      protocol::Message{protocol::StatusRequestFrame{42}});
  require(request && loop.receive(*request.value),
          "NativeRuntime status/control stopped after Engine destruction");
  parser = protocol::FrameParser{};
  parsed = parser.consume(output);
  decoded = parsed.frame ? protocol::decodeFrame(*parsed.frame)
                         : protocol::ProtocolResult<protocol::Message>{};
  status = decoded ? std::get_if<protocol::StatusJsonEvent>(&*decoded.value)
                   : nullptr;
  require(status && status->correlationId == 42 && !loop.hasEngine(),
          "status service required a live Engine after detachment");
}

void testBatteryColdStartCreatesOnlyTheControlShellBeforeAc() {
  std::vector<uint8_t> output;
  FakePowerSource source(LifecyclePower::Battery);
  auto pending = std::make_shared<PendingPowerObservation>([] {});
  source.start([pending](LifecyclePower value) { pending->record(value); });
  pending->recordInitial(source.current());
  const auto initial = pending->take();
  require(initial == LifecyclePower::Battery,
          "cold-start fixture did not sample Battery before bootstrap");

  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 0;
  config.nativeLoop.configuredContextCeiling = 1024;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });
  require(bootstrap->observePower(*initial),
          "initial Battery was not consumed by the Bootstrap owner");
  const LifecycleStatusSnapshot lifecycle = bootstrap->lifecycleStatus();
  const ResourceSnapshot resources = bootstrap->detachedResourceSnapshot();
  require(lifecycle.power == LifecyclePower::Battery &&
              lifecycle.state == LifecycleState::Suspended &&
              lifecycle.controlReady && !lifecycle.inferenceReady &&
              !lifecycle.modelResident &&
              lifecycle.configuredContextCeiling == 1024 &&
              !lifecycle.effectiveContextTokens &&
              !bootstrap->hasResources() && !bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap) &&
              !bootstrap->nativeLoop().hasEngine() &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              validResourceSnapshot(resources) &&
              resources.backendAllocatedBytes == 0 &&
              !resources.modelPackageResident && !resources.runtimeResident &&
              !resources.retainedCacheBytes && !resources.retainedKvBytes &&
              !resources.retainedStateBytes &&
              !resources.modelTelemetryAvailable &&
              bootstrap->advanceRecovery() == RecoveryProgress::Idle &&
              !bootstrap->hasResources() &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap) &&
              readyEventCount(output) == 1,
          "Battery cold start created model residency or a synthetic warm graph");

  auto request = protocol::serializeMessage(
      protocol::Message{protocol::StatusRequestFrame{43}});
  require(request && bootstrap->nativeLoop().receive(*request.value) &&
              bootstrap->nativeLoop().ready() && readyEventCount(output) == 1,
          "Battery cold start did not keep one control-ready generation live");
  source.stop();
}

void testPrivateRecoveryCandidateOwnershipAndRollback() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness retained(plan);
  retained.retainPrefixState();
  const CacheSnapshot before = retained.cache().snapshot();
  require(before.stateCache.entries == 1 && before.activeRequests == 0 &&
              retained.residentBackingPages() == 16,
          "candidate fixture did not begin with retained cache/KV state");

  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 1024;
  std::vector<uint8_t> output;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });

  require(bootstrap->observePower(LifecyclePower::Battery),
          "candidate fixture did not create battery intent");
  LifecycleStatusSnapshot suspended = bootstrap->lifecycleStatus();
  suspended.state = LifecycleState::Suspended;
  suspended.controlReady = true;
  suspended.inferenceReady = false;
  suspended.modelResident = false;
  require(bootstrap->publishLifecycleStatus(suspended) &&
              bootstrap->observePower(LifecyclePower::AC),
          "candidate fixture did not reach same-generation AC recovery");
  const LifecycleStatusSnapshot recoveryStatus = bootstrap->lifecycleStatus();
  EngineConfig candidateConfig;
  candidateConfig.maxContext = 1024;
  RuntimeBootstrapTestAccess::installTestRecoverySpec(*bootstrap,
                                                       candidateConfig);

  bool missingGraphRejected = false;
  try {
    RuntimeBootstrapTestAccess::buildRecoveryCandidate(*bootstrap);
  } catch (const std::logic_error &) {
    missingGraphRejected = true;
  }
  require(missingGraphRejected &&
              bootstrap->lifecycleStatus().revision == recoveryStatus.revision &&
              !bootstrap->nativeLoop().hasEngine() &&
              !bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap),
          "failed candidate precondition changed live model-less publication");
  const CacheSnapshot afterMissingGraph = retained.cache().snapshot();
  require(afterMissingGraph.stateCache.entries == before.stateCache.entries &&
              afterMissingGraph.stateCache.bytes == before.stateCache.bytes &&
              afterMissingGraph.pool.pagesResident == before.pool.pagesResident &&
              retained.residentBackingPages() == 16,
          "failed candidate precondition consumed retained cache/KV state");

  // Engine construction failure destroys the local package/runtime candidate
  // and leaves the retained source graph untouched.
  EngineConfig invalidConfig = candidateConfig;
  invalidConfig.maxContext = 0;
  RuntimeBootstrapTestAccess::installTestRecoverySpec(*bootstrap,
                                                       invalidConfig);
  bool failedRuntimeDestroyed = false;
  auto failedRuntime = std::make_unique<Executor>(0);
  failedRuntime->destructionHook = [&] { failedRuntimeDestroyed = true; };
  bool engineConstructionRejected = false;
  try {
    RuntimeBootstrapTestAccess::createPrivateCandidate(
        *bootstrap, std::make_unique<ModelPackageResidency>(model::ModelPackage{}),
        std::move(failedRuntime), retained.cache(), recoveryStatus.revision);
  } catch (const std::invalid_argument &) {
    engineConstructionRejected = true;
  }
  require(engineConstructionRejected && failedRuntimeDestroyed &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap) &&
              !bootstrap->nativeLoop().hasEngine() &&
              bootstrap->lifecycleStatus().revision == recoveryStatus.revision,
          "candidate Engine failure leaked into live Bootstrap publication");
  const CacheSnapshot afterEngineFailure = retained.cache().snapshot();
  require(afterEngineFailure.stateCache.entries == before.stateCache.entries &&
              afterEngineFailure.stateCache.bytes == before.stateCache.bytes &&
              afterEngineFailure.pool.pagesResident == before.pool.pagesResident &&
              retained.residentBackingPages() == 16,
          "failed candidate destruction consumed retained source state");

  RuntimeBootstrapTestAccess::installTestRecoverySpec(*bootstrap,
                                                       candidateConfig);
  RuntimeBootstrapTestAccess::createPrivateCandidate(
      *bootstrap, std::make_unique<ModelPackageResidency>(model::ModelPackage{}),
      std::make_unique<Executor>(0), retained.cache(),
      recoveryStatus.revision);
  require(RuntimeBootstrapTestAccess::recoveryCandidateComplete(*bootstrap) &&
              RuntimeBootstrapTestAccess::recoveryCandidateRevision(*bootstrap) ==
                  recoveryStatus.revision,
          "private candidate did not own package/runtime/Engine at its revision");
  const CacheSnapshot throughCandidate =
      RuntimeBootstrapTestAccess::recoveryCandidateCacheSnapshot(*bootstrap);
  require(throughCandidate.stateCache.entries == before.stateCache.entries &&
              throughCandidate.stateCache.bytes == before.stateCache.bytes &&
              throughCandidate.pool.pagesResident == before.pool.pagesResident,
          "candidate Engine was not bound to the retained Cache/KV graph");

  const LifecycleStatusSnapshot whilePrivate = bootstrap->lifecycleStatus();
  const ResourceSnapshot detached = bootstrap->detachedResourceSnapshot();
  require(!bootstrap->nativeLoop().hasEngine() &&
              !bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              !whilePrivate.inferenceReady && !whilePrivate.modelResident &&
              !detached.lifecycle.inferenceReady &&
              !detached.lifecycle.modelResident &&
              !detached.modelPackageResident && !detached.runtimeResident &&
              readyEventCount(output) == 1,
          "private candidate changed readiness, publication, or ReadyEvent count");

  require(bootstrap->observePower(LifecyclePower::Battery) &&
              RuntimeBootstrapTestAccess::recoveryCandidateRevision(*bootstrap) <
                  bootstrap->lifecycleStatus().revision &&
              RuntimeBootstrapTestAccess::recoveryCandidateComplete(*bootstrap) &&
              !bootstrap->nativeLoop().hasEngine() &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap),
          "stale recovery candidate escaped its private revision fence");

  const void *candidateAddress =
      RuntimeBootstrapTestAccess::recoveryCandidateAddress(*bootstrap);
  auto *candidateRuntime = dynamic_cast<Executor *>(
      RuntimeBootstrapTestAccess::recoveryCandidateModel(*bootstrap));
  require(candidateRuntime != nullptr,
          "private candidate did not retain the test RuntimeModel");
  bool destroyedInEngineRuntimePackageOrder = false;
  candidateRuntime->destructionHook = [&] {
    destroyedInEngineRuntimePackageOrder =
        RuntimeBootstrapTestAccess::candidateEngineGonePackageRetained(
            candidateAddress);
  };
  RuntimeBootstrapTestAccess::destroyRecoveryCandidate(*bootstrap);
  require(destroyedInEngineRuntimePackageOrder &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap),
          "candidate did not destroy Engine before RuntimeModel before package");
  const CacheSnapshot afterDestroy = retained.cache().snapshot();
  require(afterDestroy.stateCache.entries == before.stateCache.entries &&
              afterDestroy.stateCache.bytes == before.stateCache.bytes &&
              afterDestroy.pool.pagesResident == before.pool.pagesResident &&
              retained.residentBackingPages() == 16 &&
              !bootstrap->nativeLoop().hasEngine() &&
              !bootstrap->hasModelRuntime(),
          "candidate rollback damaged the retained base graph");

  // A newer AC revision can assemble a fresh private candidate after the
  // stale candidate has been destroyed. It remains unpublished until T026.
  require(bootstrap->observePower(LifecyclePower::AC),
          "candidate rollback did not accept a newer AC revision");
  const LifecycleStatusSnapshot currentRecovery = bootstrap->lifecycleStatus();
  RuntimeBootstrapTestAccess::installTestRecoverySpec(*bootstrap,
                                                       candidateConfig);
  RuntimeBootstrapTestAccess::createPrivateCandidate(
      *bootstrap, std::make_unique<ModelPackageResidency>(model::ModelPackage{}),
      std::make_unique<Executor>(0), retained.cache(),
      currentRecovery.revision);
  const CacheSnapshot throughFreshCandidate =
      RuntimeBootstrapTestAccess::recoveryCandidateCacheSnapshot(*bootstrap);
  require(RuntimeBootstrapTestAccess::recoveryCandidateComplete(*bootstrap) &&
              RuntimeBootstrapTestAccess::recoveryCandidateRevision(*bootstrap) ==
                  currentRecovery.revision &&
              throughFreshCandidate.stateCache.entries ==
                  before.stateCache.entries &&
              throughFreshCandidate.stateCache.bytes == before.stateCache.bytes &&
              throughFreshCandidate.pool.pagesResident ==
                  before.pool.pagesResident &&
              !bootstrap->nativeLoop().hasEngine() &&
              !bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              readyEventCount(output) == 1,
          "new current-revision candidate was not private over the retained cache");
  RuntimeBootstrapTestAccess::destroyRecoveryCandidate(*bootstrap);
  const CacheSnapshot afterFreshCandidate = retained.cache().snapshot();
  require(afterFreshCandidate.stateCache.entries == before.stateCache.entries &&
              afterFreshCandidate.stateCache.bytes == before.stateCache.bytes &&
              afterFreshCandidate.pool.pagesResident == before.pool.pagesResident &&
              retained.residentBackingPages() == 16 &&
              !bootstrap->nativeLoop().hasEngine() &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              readyEventCount(output) == 1,
          "fresh private candidate destruction changed publication or retained cache");
}

std::unique_ptr<RuntimeBootstrap> makeRecoveryPublicationFixture(
    Cache &cache, std::vector<uint8_t> &output, uint32_t candidateContext,
    std::optional<uint32_t> priorEffectiveContext = std::nullopt) {
  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 1024;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });
  require(bootstrap->observePower(LifecyclePower::Battery),
          "publication fixture did not establish initial battery revision");
  LifecycleStatusSnapshot suspended = bootstrap->lifecycleStatus();
  suspended.state = LifecycleState::Suspended;
  suspended.controlReady = true;
  suspended.inferenceReady = false;
  suspended.modelResident = false;
  suspended.effectiveContextTokens = priorEffectiveContext;
  require(bootstrap->publishLifecycleStatus(suspended) &&
              bootstrap->observePower(LifecyclePower::AC),
          "publication fixture did not reach suspended AC recovery");

  EngineConfig candidateConfig;
  candidateConfig.maxContext = candidateContext;
  RuntimeBootstrapTestAccess::installTestRecoverySpec(*bootstrap,
                                                       candidateConfig);
  RuntimeBootstrapTestAccess::createPrivateCandidate(
      *bootstrap, std::make_unique<ModelPackageResidency>(model::ModelPackage{}),
      std::make_unique<Executor>(0), cache,
      bootstrap->lifecycleStatus().revision);
  return bootstrap;
}

void testRecoveryCandidatePublicationIsTransactionalAndExact() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness retained(plan);
  retained.retainPrefixState();
  std::vector<uint8_t> output;
  auto bootstrap = makeRecoveryPublicationFixture(retained.cache(), output, 768);
  const auto nativeGeneration = &bootstrap->nativeLoop();
  Engine *candidateEngine =
      RuntimeBootstrapTestAccess::recoveryCandidateEngine(*bootstrap);
  require(candidateEngine && readyEventCount(output) == 1,
          "publication fixture did not have one complete candidate generation");

  auto emptyEngine = std::unique_ptr<Engine>{};
  require(!bootstrap->nativeLoop().tryPublishEngine(emptyEngine) &&
              !emptyEngine && !bootstrap->nativeLoop().hasEngine(),
          "NativeRuntime accepted a null candidate Engine");

  RuntimeBootstrapTestAccess::injectNativePublicationBlockers(*bootstrap);
  require(!RuntimeBootstrapTestAccess::tryPublishPrivateEngine(*bootstrap) &&
              RuntimeBootstrapTestAccess::recoveryCandidateEngine(*bootstrap) ==
                  candidateEngine &&
              !bootstrap->nativeLoop().hasEngine(),
          "NativeRuntime consumed a candidate with retained request/mask state");
  RuntimeBootstrapTestAccess::clearNativePublicationBlockers(*bootstrap);

  const auto publication =
      RuntimeBootstrapTestAccess::publishRecoveryResidency(*bootstrap);
  require(publication && publication->engine == candidateEngine &&
              RuntimeBootstrapTestAccess::publishedEngine(*bootstrap) ==
                  candidateEngine &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap) &&
              bootstrap->nativeLoop().hasEngine() &&
              bootstrap->hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap),
          "private candidate Engine was replaced or ownership transfer was incomplete");

  const LifecycleStatusSnapshot published = bootstrap->lifecycleStatus();
  require(published.state == LifecycleState::Recovering &&
              published.power == LifecyclePower::AC &&
              published.modelResident && !published.inferenceReady &&
              published.effectiveContextTokens == 768 &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap),
          "effective context was not published before final admission");
  require(RuntimeBootstrapTestAccess::finalizeRecoveryPublication(
              *bootstrap, *publication),
          "current AC candidate failed its final publication fence");
  const LifecycleStatusSnapshot ready = bootstrap->lifecycleStatus();
  require(ready.state == LifecycleState::Ready &&
              ready.power == LifecyclePower::AC && ready.controlReady &&
              ready.modelResident && ready.effectiveContextTokens == 768 &&
              ready.inferenceReady &&
              RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              &bootstrap->nativeLoop() == nativeGeneration &&
              readyEventCount(output) == 1,
          "candidate publication changed the control generation or readiness contract");
}

void testInvalidRecoveryContextFailsClosedAndCanRetry() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness retained(plan);
  retained.retainPrefixState();
  std::vector<uint8_t> output;
  auto bootstrap = makeRecoveryPublicationFixture(retained.cache(), output, 1025);
  const CacheSnapshot retainedBefore = retained.cache().snapshot();
  Engine *candidateEngine =
      RuntimeBootstrapTestAccess::recoveryCandidateEngine(*bootstrap);
  const void *candidateAddress =
      RuntimeBootstrapTestAccess::recoveryCandidateAddress(*bootstrap);
  auto *candidateRuntime = dynamic_cast<Executor *>(
      RuntimeBootstrapTestAccess::recoveryCandidateModel(*bootstrap));
  require(candidateEngine && candidateRuntime,
          "invalid-context candidate fixture is incomplete");
  bool candidateDestroyedInOrder = false;
  candidateRuntime->destructionHook = [&] {
    candidateDestroyedInOrder =
        RuntimeBootstrapTestAccess::candidateEngineGonePackageRetained(
            candidateAddress);
  };

  require(!bootstrap->publishRecoveryCandidate() &&
              !bootstrap->nativeLoop().hasEngine() &&
              !bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap),
          "unsafe effective context escaped into live serving state");
  const LifecycleStatusSnapshot failed = bootstrap->lifecycleStatus();
  const CacheSnapshot retainedAfter = retained.cache().snapshot();
  require(failed.state == LifecycleState::RecoveryFailed &&
              failed.power == LifecyclePower::AC && !failed.modelResident &&
              !failed.inferenceReady && !failed.effectiveContextTokens &&
              !failed.lastError.empty() && candidateDestroyedInOrder &&
              retainedAfter.stateCache.entries == retainedBefore.stateCache.entries &&
              retainedAfter.stateCache.bytes == retainedBefore.stateCache.bytes &&
              retainedAfter.pool.pagesResident == retainedBefore.pool.pagesResident &&
              readyEventCount(output) == 1,
          "invalid candidate rollback changed retained state or lifecycle truth");

  EngineConfig validConfig;
  validConfig.maxContext = 768;
  RuntimeBootstrapTestAccess::installTestRecoverySpec(*bootstrap, validConfig);
  RuntimeBootstrapTestAccess::createPrivateCandidate(
      *bootstrap, std::make_unique<ModelPackageResidency>(model::ModelPackage{}),
      std::make_unique<Executor>(0), retained.cache(), failed.revision);
  require(bootstrap->publishRecoveryCandidate() &&
              bootstrap->lifecycleStatus().inferenceReady &&
              bootstrap->lifecycleStatus().effectiveContextTokens == 768 &&
              RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              readyEventCount(output) == 1,
          "a later valid AC candidate could not recover in the same generation");
}

void testFinalRecoveryFenceKeepsNewBatteryIntentClosed() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness retained(plan);
  retained.retainPrefixState();
  std::vector<uint8_t> output;
  auto bootstrap = makeRecoveryPublicationFixture(retained.cache(), output, 768);
  const CacheSnapshot retainedBefore = retained.cache().snapshot();
  const auto publication =
      RuntimeBootstrapTestAccess::publishRecoveryResidency(*bootstrap);
  require(publication && bootstrap->lifecycleStatus().effectiveContextTokens == 768 &&
              !bootstrap->lifecycleStatus().inferenceReady &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap),
          "publication phase did not leave resolved context behind a closed gate");

  require(bootstrap->observePower(LifecyclePower::Battery) &&
              !RuntimeBootstrapTestAccess::finalizeRecoveryPublication(
                  *bootstrap, *publication),
          "new battery revision failed to fence final admission opening");
  const LifecycleStatusSnapshot battery = bootstrap->lifecycleStatus();
  require(battery.power == LifecyclePower::Battery &&
              battery.revision == publication->lifecycleRevision + 1 &&
              battery.modelResident && !battery.inferenceReady &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              bootstrap->nativeLoop().hasEngine() && bootstrap->hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
              readyEventCount(output) == 1,
          "stale AC completion opened admission or lost published residency");

  require(bootstrap->beginSuspend() &&
              bootstrap->advanceSuspend() == SuspendProgress::Suspended &&
              !bootstrap->nativeLoop().hasEngine() &&
              !bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              readyEventCount(output) == 1,
          "battery drain could not release residency after a stale AC completion");
  const CacheSnapshot retainedAfter = retained.cache().snapshot();
  require(retainedAfter.stateCache.entries == retainedBefore.stateCache.entries &&
              retainedAfter.stateCache.bytes == retainedBefore.stateCache.bytes &&
              retainedAfter.pool.pagesResident == retainedBefore.pool.pagesResident,
          "stale final fence damaged the retained cache/KV graph");
}

void testRecoveryContextDriftKeepsControlGeneration() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness retained(plan);
  std::vector<uint8_t> output;
  auto bootstrap =
      makeRecoveryPublicationFixture(retained.cache(), output, 768, 1024);
  RuntimeBootstrap *const bootstrapIdentity = bootstrap.get();
  NativeRuntime *nativeGeneration = &bootstrap->nativeLoop();
  require(bootstrap->lifecycleStatus().effectiveContextTokens == 1024 &&
              bootstrap->publishRecoveryCandidate() &&
              bootstrap->lifecycleStatus().effectiveContextTokens == 768 &&
              bootstrap->lifecycleStatus().inferenceReady &&
              bootstrap.get() == bootstrapIdentity &&
              &bootstrap->nativeLoop() == nativeGeneration &&
              readyEventCount(output) == 1,
          "effective-context drift restarted control or retained the old serving limit");

  protocol::RequestFrame frame;
  frame.requestId = 3132;
  frame.priority = protocol::RequestPriority::Foreground;
  frame.cohort = protocol::Cohort::Greedy;
  frame.constraint = protocol::ConstraintMode::None;
  frame.absoluteDeadlineUnixMicros = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::system_clock::now().time_since_epoch())
          .count()) + 10'000'000;
  frame.remainingDeadlineMicros = 5'000'000;
  frame.logicalMaxOutputTokens = 1;
  frame.promptTokens = {1, 2};
  auto request = protocol::serializeMessage(protocol::Message{std::move(frame)});
  require(request && bootstrap->nativeLoop().receive(*request.value),
          "recovered NativeRuntime rejected the context-drift request");
  require(bootstrap->nativeLoop().tick(),
          "recovered Engine did not advance the context-drift request");

  protocol::FrameParser parser;
  size_t offset = 0;
  size_t readyCount = 0;
  size_t startCount = 0;
  bool readyCeilingIsConfigured = false;
  bool requestCapacityIsEffective = false;
  uint32_t observedRequestCapacity = 0;
  while (offset < output.size()) {
    const auto step = parser.consume(
        std::span<const uint8_t>(output).subspan(offset));
    require(!step.issue && step.consumedBytes,
            "context-drift output contained an invalid protocol frame");
    offset += step.consumedBytes;
    if (!step.frame)
      continue;
    const auto decoded = protocol::decodeFrame(*step.frame);
    require(static_cast<bool>(decoded),
            "context-drift output frame did not decode");
    if (const auto *ready =
            std::get_if<protocol::ReadyEvent>(&*decoded.value)) {
      ++readyCount;
      readyCeilingIsConfigured = ready->maxContextTokens == 1024;
    }
    if (const auto *started =
            std::get_if<protocol::StartEvent>(&*decoded.value);
        started && started->requestId == 3132) {
      ++startCount;
      observedRequestCapacity = started->capacityTokens;
      requestCapacityIsEffective = started->capacityTokens == 768;
    }
  }
  require(readyCount == 1 && readyCeilingIsConfigured,
          "context-drift ReadyEvent did not retain its configured ceiling of 1024");
  require(bootstrap->lifecycleStatus().effectiveContextTokens == 768 &&
              bootstrap.get() == bootstrapIdentity &&
              &bootstrap->nativeLoop() == nativeGeneration,
          "context-drift lifecycle or control generation changed during request");
  require(startCount == 1,
          "context-drift request did not emit exactly one StartEvent");
  const std::string capacityFailure =
      "context-drift StartEvent capacity was " +
      std::to_string(observedRequestCapacity) +
      " instead of the Engine's 768-token context";
  require(requestCapacityIsEffective, capacityFailure.c_str());
}

void testNativeRuntimeAdoptionRefusalPreservesCandidate() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness retained(plan);
  std::vector<uint8_t> output;
  auto bootstrap = makeRecoveryPublicationFixture(retained.cache(), output, 768);
  Engine *candidateEngine =
      RuntimeBootstrapTestAccess::recoveryCandidateEngine(*bootstrap);
  RuntimeBootstrapTestAccess::injectNativePublicationBlockers(*bootstrap);
  require(!RuntimeBootstrapTestAccess::tryPublishPrivateEngine(*bootstrap) &&
              RuntimeBootstrapTestAccess::recoveryCandidateEngine(*bootstrap) ==
                  candidateEngine &&
              !bootstrap->nativeLoop().hasEngine() &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap),
          "NativeRuntime refusal consumed or exposed the candidate Engine");
  RuntimeBootstrapTestAccess::clearNativePublicationBlockers(*bootstrap);

  bootstrap->nativeLoop().publishEngine(retained.cache(), retained.executor());
  require(!RuntimeBootstrapTestAccess::tryPublishPrivateEngine(*bootstrap) &&
              RuntimeBootstrapTestAccess::recoveryCandidateEngine(*bootstrap) ==
                  candidateEngine &&
              bootstrap->nativeLoop().hasEngine(),
          "NativeRuntime consumed a candidate while another Engine was published");
  bootstrap->nativeLoop().destroyEngine();
  require(bootstrap->publishRecoveryCandidate() &&
              RuntimeBootstrapTestAccess::publishedEngine(*bootstrap) ==
                  candidateEngine &&
              readyEventCount(output) == 1,
          "exact candidate Engine could not publish after refusal preconditions cleared");
}

void testBootstrapPowerIntentRevisionAndShutdownAuthority() {
  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 1024;
  std::vector<uint8_t> output;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });

  LifecycleStatusSnapshot status = bootstrap->lifecycleStatus();
  require(status.power == LifecyclePower::Unknown &&
              status.state == LifecycleState::RecoveryFailed &&
              status.controlReady && !status.inferenceReady &&
              status.configuredContextCeiling == 1024 &&
              !bootstrap->observePower(LifecyclePower::Unknown),
          "initial unknown power was not represented fail-closed");
  require(bootstrap->observePower(LifecyclePower::Battery),
          "first battery observation did not create an intent revision");
  status = bootstrap->lifecycleStatus();
  require(status.revision == 1 && status.power == LifecyclePower::Battery &&
              !bootstrap->observePower(LifecyclePower::Battery) &&
              bootstrap->lifecycleStatus().revision == 1,
          "duplicate power observation changed intent revision");

  LifecycleStatusSnapshot suspended;
  suspended.power = LifecyclePower::Battery;
  suspended.state = LifecycleState::Suspended;
  suspended.revision = 1;
  suspended.controlReady = true;
  suspended.configuredContextCeiling = 1024;
  require(bootstrap->publishLifecycleStatus(suspended),
          "current revision lifecycle status was rejected");
  require(bootstrap->observePower(LifecyclePower::AC),
          "AC transition did not supersede battery intent");
  auto stale = suspended;
  stale.state = LifecycleState::Ready;
  stale.power = LifecyclePower::Battery;
  require(!bootstrap->publishLifecycleStatus(stale) &&
              bootstrap->lifecycleStatus().revision == 2 &&
              bootstrap->lifecycleStatus().state == LifecycleState::Suspended,
          "stale lifecycle completion overwrote newer power intent");
  require(!bootstrap->observePower(LifecyclePower::AC),
          "duplicate AC observation created a revision");

  require(bootstrap->observePower(LifecyclePower::Unknown),
          "unknown observation did not create a fail-closed revision");
  status = bootstrap->lifecycleStatus();
  require(status.revision == 3 && status.power == LifecyclePower::Unknown &&
              status.state == LifecycleState::RecoveryFailed &&
              !status.inferenceReady &&
              status.lastError == "power source is unknown",
          "unknown power did not close inference readiness");
  auto unsafe = status;
  unsafe.power = LifecyclePower::AC;
  unsafe.state = LifecycleState::Ready;
  unsafe.inferenceReady = true;
  unsafe.modelResident = true;
  unsafe.effectiveContextTokens = 512;
  require(!bootstrap->publishLifecycleStatus(unsafe),
          "unknown-power lifecycle accepted inference-ready publication");

  require(bootstrap->shutdownLifecycle(),
          "shutdown did not become authoritative lifecycle intent");
  status = bootstrap->lifecycleStatus();
  const uint64_t shutdownRevision = status.revision;
  require(status.state == LifecycleState::Shutdown && !status.controlReady &&
              !status.inferenceReady && !bootstrap->shutdownLifecycle() &&
              !bootstrap->observePower(LifecyclePower::AC) &&
              bootstrap->lifecycleStatus().revision == shutdownRevision &&
              !bootstrap->publishLifecycleStatus(suspended),
          "automatic intent superseded shutdown lifecycle state");
}

struct SuspendBootstrapFixture {
  std::unique_ptr<RuntimeBootstrap> bootstrap;
  Executor *runtime = nullptr;
};

SuspendBootstrapFixture makeSuspendBootstrapFixture(
    std::vector<uint8_t> &output, Harness &dependencies) {
  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 1024;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });

  auto runtime = std::make_unique<Executor>(0);
  Executor *runtimePointer = runtime.get();
  auto package = std::make_unique<ModelPackageResidency>(model::ModelPackage{});
  RuntimeBootstrapTestAccess::installModelResidency(
      *bootstrap, std::move(runtime), std::move(package));
  bootstrap->nativeLoop().publishEngine(dependencies.cache(),
                                        bootstrap->modelRuntime());

  require(bootstrap->observePower(LifecyclePower::AC),
          "suspend fixture did not establish AC intent");
  LifecycleStatusSnapshot ready = bootstrap->lifecycleStatus();
  ready.state = LifecycleState::Ready;
  ready.controlReady = true;
  ready.inferenceReady = true;
  ready.modelResident = true;
  ready.effectiveContextTokens = 512;
  require(bootstrap->publishLifecycleStatus(ready),
          "suspend fixture did not publish ready model residency");
  return {std::move(bootstrap), runtimePointer};
}

void testFakePowerSourceQueuesAtSafePointAndStopsDelivery() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  std::vector<uint8_t> output;
  SuspendBootstrapFixture fixture =
      makeSuspendBootstrapFixture(output, dependencies);
  RuntimeBootstrap &bootstrap = *fixture.bootstrap;
  size_t runtimeDestructions = 0;
  fixture.runtime->destructionHook = [&] { ++runtimeDestructions; };

  FakePowerSource acSource(LifecyclePower::AC);
  FakePowerSource batteryInitial(LifecyclePower::Battery);
  FakePowerSource unknownSource(LifecyclePower::Unknown);
  require(acSource.current() == LifecyclePower::AC &&
              batteryInitial.current() == LifecyclePower::Battery &&
              unknownSource.current() == LifecyclePower::Unknown,
          "fake power source did not expose synchronous AC/Battery/Unknown samples");

  std::atomic<size_t> wakes{0};
  auto pending = std::make_shared<PendingPowerObservation>([&] { ++wakes; });
  acSource.start([pending](LifecyclePower value) { pending->record(value); });
  pending->recordInitial(acSource.current());
  const uint64_t initialRevision = bootstrap.lifecycleStatus().revision;
  const auto initial = pending->take();
  require(initial == LifecyclePower::AC &&
              !bootstrap.observePower(*initial) &&
              bootstrap.lifecycleStatus().revision == initialRevision,
          "synchronous initial AC was not represented as a duplicate safe-point observation");
  PendingPowerObservation ordering([] {});
  ordering.record(LifecyclePower::Battery);
  ordering.recordInitial(LifecyclePower::AC);
  require(ordering.take() == LifecyclePower::Battery,
          "late initial sample overwrote a newer observer callback");

  acSource.emit(LifecyclePower::Battery);
  require(bootstrap.lifecycleStatus().revision == initialRevision,
          "observer callback revised Bootstrap before the native safe point");
  const auto battery = pending->take();
  require(battery == LifecyclePower::Battery &&
              bootstrap.observePower(*battery) &&
              bootstrap.lifecycleStatus().revision == initialRevision + 1 &&
              !bootstrap.lifecycleStatus().inferenceReady &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              bootstrap.beginSuspend() &&
              bootstrap.advanceSuspend() == SuspendProgress::Suspended &&
              runtimeDestructions == 1,
          "AC-to-Battery handoff did not close admission and finish suspension at a safe point");

  acSource.emit(LifecyclePower::Battery);
  const uint64_t batteryRevision = bootstrap.lifecycleStatus().revision;
  const auto duplicate = pending->take();
  require(duplicate == LifecyclePower::Battery &&
              !bootstrap.observePower(*duplicate) &&
              !bootstrap.beginSuspend() &&
              bootstrap.advanceSuspend() == SuspendProgress::Idle &&
              bootstrap.lifecycleStatus().revision == batteryRevision &&
              runtimeDestructions == 1,
          "duplicate Battery observation created a revision or repeated teardown");

  acSource.emit(LifecyclePower::Unknown);
  const auto unknown = pending->take();
  require(unknown == LifecyclePower::Unknown &&
              bootstrap.observePower(*unknown) &&
              bootstrap.lifecycleStatus().state == LifecycleState::RecoveryFailed &&
              !bootstrap.lifecycleStatus().inferenceReady &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              RuntimeBootstrapTestAccess::advanceRecovery(bootstrap) ==
                  RecoveryProgress::Idle,
          "Unknown power failed to close admission or incorrectly started recovery");

  acSource.stop();
  const uint64_t stoppedRevision = bootstrap.lifecycleStatus().revision;
  const size_t stoppedWakeCount = wakes.load();
  acSource.emit(LifecyclePower::AC);
  require(!pending->take() &&
              bootstrap.lifecycleStatus().revision == stoppedRevision &&
              wakes.load() == stoppedWakeCount,
          "stopped observer delivered into the pending native handoff");
}

void testInitialAcObservationOpensExistingBootstrapResidency() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  std::vector<uint8_t> output;
  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 512;
  config.nativeLoop.configuredContextCeiling = 512;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });
  auto runtime = std::make_unique<Executor>(0);
  auto package = std::make_unique<ModelPackageResidency>(model::ModelPackage{});
  RuntimeBootstrapTestAccess::installModelResidency(
      *bootstrap, std::move(runtime), std::move(package));
  bootstrap->nativeLoop().publishEngine(dependencies.cache(),
                                        bootstrap->modelRuntime());
  LifecycleStatusSnapshot startup = bootstrap->lifecycleStatus();
  startup.state = LifecycleState::RecoveryFailed;
  startup.power = LifecyclePower::Unknown;
  startup.controlReady = true;
  startup.modelResident = true;
  startup.inferenceReady = false;
  startup.effectiveContextTokens = 512;
  startup.lastError = "power source is unknown";
  require(bootstrap->publishLifecycleStatus(startup),
          "startup fixture could not represent pre-observation residency");

  auto pending = std::make_shared<PendingPowerObservation>([] {});
  FakePowerSource source(LifecyclePower::AC);
  source.start([pending](LifecyclePower value) { pending->record(value); });
  pending->recordInitial(source.current());
  const auto initial = pending->take();
  require(initial == LifecyclePower::AC &&
              bootstrap->observePower(*initial) &&
              bootstrap->lifecycleStatus().state == LifecycleState::Ready &&
              bootstrap->lifecycleStatus().inferenceReady &&
              RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              bootstrap->nativeLoop().hasEngine() &&
              readyEventCount(output) == 1,
          "synchronous initial AC did not ready existing residency in the same generation");
  source.stop();
}

void testPowerObserverStopWaitsForInflightCallback() {
  FakePowerSource source(LifecyclePower::AC);
  std::atomic<size_t> wakes{0};
  auto pending = std::make_shared<PendingPowerObservation>([&] { ++wakes; });
  std::latch callbackEntered(1);
  std::latch releaseCallback(1);
  std::latch stopReturned(1);
  source.start([pending, &callbackEntered, &releaseCallback](LifecyclePower value) {
    callbackEntered.count_down();
    releaseCallback.wait();
    pending->record(value);
  });

  std::thread emitter([&] { source.emit(LifecyclePower::Battery); });
  std::thread stopper;
  JoinThreadsOnExit join{std::vector<std::thread *>{&emitter, &stopper}};
  ReleaseLatchesOnExit release{{&releaseCallback}};
  callbackEntered.wait();
  stopper = std::thread([&] {
    source.stop();
    stopReturned.count_down();
  });
  source.waitUntilStopped();
  require(!stopReturned.try_wait(),
          "observer stop returned while a callback still held its context");
  releaseCallback.count_down();
  emitter.join();
  stopper.join();
  require(stopReturned.try_wait() &&
              pending->take() == LifecyclePower::Battery && wakes.load() == 1,
          "observer teardown did not join its final callback before returning");
  source.emit(LifecyclePower::AC);
  require(!pending->take() && wakes.load() == 1,
          "observer delivered a callback after stop completed");
}

void testAsyncRecoveryKeepsFdTransportResponsiveAndRevisionFenced() {
  PipePair input;
  PipePair outputPipe;
  FdTransport transport(input.readFd, outputPipe.writeFd);
  auto pipeSink = transport.outputSink();
  std::mutex outputMutex;
  std::vector<uint8_t> output;
  auto sink = [&](std::span<const uint8_t> bytes) {
    {
      std::lock_guard lock(outputMutex);
      output.insert(output.end(), bytes.begin(), bytes.end());
    }
    pipeSink(bytes);
  };
  std::mutex statusMutex;
  std::condition_variable statusCondition;
  size_t statusCalls = 0;
  Harness retained(memoryPlan());
  retained.retainPrefixState();
  const CacheSnapshot retainedBefore = retained.cache().snapshot();
  require(retainedBefore.stateCache.entries == 1 &&
              retainedBefore.activeRequests == 0 &&
              retained.residentBackingPages() == 16,
          "async recovery fixture did not retain its Cache/KV graph");
  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 512;
  config.nativeLoop.configuredContextCeiling = 512;
  config.lifecycleWake = transport.controlNotifier();
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config), sink, [&] {
        {
          std::lock_guard lock(statusMutex);
          ++statusCalls;
        }
        statusCondition.notify_all();
        return std::string(R"({"schema_version":5})");
      });
  RuntimeBootstrap *bootstrapPointer = bootstrap.get();
  require(bootstrap->observePower(LifecyclePower::Battery),
          "async recovery fixture did not create an initial Battery revision");
  LifecycleStatusSnapshot suspended = bootstrap->lifecycleStatus();
  suspended.state = LifecycleState::Suspended;
  suspended.controlReady = true;
  suspended.inferenceReady = false;
  suspended.modelResident = false;
  require(bootstrap->publishLifecycleStatus(suspended),
          "async recovery fixture could not enter Suspended");

  EngineConfig recoveryEngine;
  recoveryEngine.maxContext = 512;
  RuntimeBootstrapTestAccess::installTestRecoverySpec(
      *bootstrap, recoveryEngine, transport.controlNotifier());
  std::latch firstBuildStarted(1);
  std::latch releaseFirstBuild(1);
  std::latch firstCandidateBuilt(1);
  std::latch secondBuildStarted(1);
  std::latch releaseSecondBuild(1);
  std::latch secondCandidateBuilt(1);
  std::atomic<size_t> staleRuntimeDestructions{0};
  ReleaseLatchesOnExit release{{&releaseFirstBuild, &releaseSecondBuild}};
  std::atomic<size_t> buildCount{0};
  RuntimeBootstrapTestAccess::installRecoveryBuilder(
      *bootstrap, [&, bootstrapPointer, cache = &retained.cache()](uint64_t rev) {
        const size_t build = buildCount.fetch_add(1);
        if (build == 0) {
          firstBuildStarted.count_down();
          releaseFirstBuild.wait();
        } else if (build == 1) {
          if (RuntimeBootstrapTestAccess::hasRecoveryCandidate(
                  *bootstrapPointer))
            throw std::runtime_error("stale candidate survived into fresh AC build");
          secondBuildStarted.count_down();
          releaseSecondBuild.wait();
        } else {
          throw std::runtime_error("more than one recovery retry was started");
        }
        auto runtime = std::make_unique<Executor>(0);
        if (build == 0) {
          runtime->destructionHook = [&] { ++staleRuntimeDestructions; };
        }
        RuntimeBootstrapTestAccess::createPrivateCandidate(
            *bootstrapPointer,
            std::make_unique<ModelPackageResidency>(model::ModelPackage{}),
            std::move(runtime), *cache, rev);
        if (build == 0)
          firstCandidateBuilt.count_down();
        else
          secondCandidateBuilt.count_down();
      });

  std::mutex controlMutex;
  std::condition_variable controlCondition;
  size_t controlCalls = 0;
  RecoveryProgress lastRecoveryProgress = RecoveryProgress::Idle;
  SuspendProgress lastSuspendProgress = SuspendProgress::Idle;
  auto pending = std::make_shared<PendingPowerObservation>(
      transport.controlNotifier());
  FakePowerSource source(LifecyclePower::Battery);
  source.start([pending](LifecyclePower value) { pending->record(value); });
  pending->recordInitial(source.current());
  transport.setControlHandler([&] {
    if (const auto value = pending->take())
      static_cast<void>(bootstrap->observePower(*value));
    static_cast<void>(bootstrap->beginSuspend());
    lastSuspendProgress = bootstrap->advanceSuspend();
    lastRecoveryProgress =
        lastSuspendProgress == SuspendProgress::WaitingForDrain
            ? RecoveryProgress::Idle
            : RuntimeBootstrapTestAccess::advanceRecovery(*bootstrap);
    {
      std::lock_guard lock(controlMutex);
      ++controlCalls;
    }
    controlCondition.notify_all();
    return lastSuspendProgress == SuspendProgress::WaitingForDrain;
  });

  std::atomic<NativeProcessExit> exit{NativeProcessExit::IoFailure};
  std::thread transportThread([&] {
    exit.store(transport.run(bootstrap->nativeLoop()),
               std::memory_order_release);
  });
  StopTransportThreadOnExit transportCleanup{transport, transportThread};
  {
    std::unique_lock lock(controlMutex);
    waitFor(controlCondition, lock, [&] { return controlCalls >= 1; },
            "transport did not consume its synchronous initial Battery sample");
  }
  const LifecycleStatusSnapshot initialBattery = bootstrap->lifecycleStatus();
  require(initialBattery.power == LifecyclePower::Battery &&
              initialBattery.state == LifecycleState::Suspended &&
              initialBattery.controlReady && !initialBattery.inferenceReady &&
              !initialBattery.modelResident && !bootstrap->hasResources() &&
              !bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap) &&
              !bootstrap->nativeLoop().hasEngine() &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              readyEventCount(output) == 1,
          "Battery control-ready generation created residency before AC");

  source.emit(LifecyclePower::AC);
  firstBuildStarted.wait();
  {
    std::unique_lock lock(controlMutex);
    waitFor(controlCondition, lock, [&] {
      return lastRecoveryProgress == RecoveryProgress::Building;
    }, "AC safe point did not start asynchronous recovery");
  }
  const uint64_t firstAcRevision = bootstrap->lifecycleStatus().revision;
  size_t callsBeforeDuplicateAc = 0;
  {
    std::lock_guard lock(controlMutex);
    callsBeforeDuplicateAc = controlCalls;
  }
  source.emit(LifecyclePower::AC);
  {
    std::unique_lock lock(controlMutex);
    waitFor(controlCondition, lock, [&] {
      return controlCalls > callsBeforeDuplicateAc;
    }, "duplicate AC callback did not wake FdTransport");
  }
  require(bootstrap->lifecycleStatus().revision == firstAcRevision &&
              buildCount.load() == 1,
          "duplicate AC observation started another lifecycle revision or recovery build");
  auto statusRequest = protocol::serializeMessage(
      protocol::Message{protocol::StatusRequestFrame{901}});
  require(static_cast<bool>(statusRequest),
          "status frame could not be serialized during recovery");
  size_t written = 0;
  while (written < statusRequest.value->size()) {
    const ssize_t count = write(
        input.writeFd, statusRequest.value->data() + written,
        statusRequest.value->size() - written);
    require(count > 0, "status request could not be written to FdTransport");
    written += static_cast<size_t>(count);
  }
  {
    std::unique_lock lock(statusMutex);
    waitFor(statusCondition, lock, [&] { return statusCalls == 1; },
            "FdTransport status handling blocked behind private recovery build");
  }

  source.emit(LifecyclePower::Battery);
  {
    std::unique_lock lock(controlMutex);
    waitFor(controlCondition, lock, [&] {
      return bootstrap->lifecycleStatus().power == LifecyclePower::Battery &&
             controlCalls >= 3;
    }, "Battery observation was not applied at the next transport safe point");
  }
  const uint64_t batteryRevision = bootstrap->lifecycleStatus().revision;
  size_t callsBeforeWorkerCompletion = 0;
  {
    std::lock_guard lock(controlMutex);
    callsBeforeWorkerCompletion = controlCalls;
  }
  releaseFirstBuild.count_down();
  firstCandidateBuilt.wait();
  {
    std::unique_lock lock(controlMutex);
    waitFor(controlCondition, lock, [&] {
      const LifecycleStatusSnapshot lifecycle = bootstrap->lifecycleStatus();
      const CacheSnapshot retainedAfter = retained.cache().snapshot();
      std::vector<uint8_t> emitted;
      {
        std::lock_guard outputLock(outputMutex);
        emitted = output;
      }
      return controlCalls > callsBeforeWorkerCompletion &&
             lifecycle.state == LifecycleState::Suspended &&
             lifecycle.power == LifecyclePower::Battery &&
             lifecycle.revision == batteryRevision &&
             !bootstrap->nativeLoop().hasEngine() &&
             !bootstrap->hasModelRuntime() &&
             !RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
             !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap) &&
             staleRuntimeDestructions.load() == 1 &&
             !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
             retainedAfter.stateCache.entries ==
                 retainedBefore.stateCache.entries &&
             retainedAfter.stateCache.bytes == retainedBefore.stateCache.bytes &&
             retainedAfter.kvCache.blocks == retainedBefore.kvCache.blocks &&
             retainedAfter.kvCache.bytes == retainedBefore.kvCache.bytes &&
             retainedAfter.pool.pagesActive == retainedBefore.pool.pagesActive &&
             retainedAfter.pool.pagesPrefix == retainedBefore.pool.pagesPrefix &&
             retainedAfter.pool.pagesResident ==
                 retainedBefore.pool.pagesResident &&
             retainedAfter.pool.residentBackingBytes ==
                 retainedBefore.pool.residentBackingBytes &&
             retained.residentBackingPages() == 16 &&
             readyEventCount(emitted) == 1;
    }, "completed stale recovery was not reaped at a Battery safe point");
  }
  require(bootstrap->lifecycleStatus().revision == batteryRevision &&
              staleRuntimeDestructions.load() == 1 &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap),
          "stale candidate residency survived while Battery remained current");

  source.emit(LifecyclePower::AC);
  secondBuildStarted.wait();
  statusRequest = protocol::serializeMessage(
      protocol::Message{protocol::StatusRequestFrame{902}});
  require(static_cast<bool>(statusRequest),
          "second status frame could not be serialized");
  written = 0;
  while (written < statusRequest.value->size()) {
    const ssize_t count = write(input.writeFd,
                                statusRequest.value->data() + written,
                                statusRequest.value->size() - written);
    require(count > 0, "second status request could not be written");
    written += static_cast<size_t>(count);
  }
  {
    std::unique_lock lock(statusMutex);
    waitFor(statusCondition, lock, [&] { return statusCalls == 2; },
            "FdTransport stopped serving status during fresh recovery build");
  }
  releaseSecondBuild.count_down();
  secondCandidateBuilt.wait();
  {
    std::unique_lock lock(controlMutex);
    waitFor(controlCondition, lock, [&] {
      const LifecycleStatusSnapshot status = bootstrap->lifecycleStatus();
      return status.state == LifecycleState::Ready && status.inferenceReady &&
             RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap);
    }, "current AC recovery result did not publish on a native safe point");
  }
  require(buildCount.load() == 2 &&
              bootstrap->lifecycleStatus().power == LifecyclePower::AC &&
              bootstrap->nativeLoop().hasEngine() &&
              bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap),
          "fresh recovery did not publish exactly the current candidate");

  source.stop();
  const uint64_t readyRevision = bootstrap->lifecycleStatus().revision;
  source.emit(LifecyclePower::Battery);
  require(bootstrap->lifecycleStatus().revision == readyRevision &&
              !pending->take(),
          "stopped power observer changed Bootstrap after callback teardown");
  transport.requestShutdown();
  if (transportThread.joinable())
    transportThread.join();
  require(exit.load(std::memory_order_acquire) == NativeProcessExit::CleanEof,
          "FdTransport did not shut down cleanly after asynchronous recovery");
  std::vector<uint8_t> emitted;
  {
    std::lock_guard lock(outputMutex);
    emitted = output;
  }
  require(readyEventCount(emitted) == 1,
          "same-process suspend/recovery emitted a second ReadyEvent");
}

void testShutdownWinsBlockedRecoveryCompletion() {
  Harness retained(memoryPlan());
  std::vector<uint8_t> output;
  std::latch completionWake(1);
  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 512;
  config.nativeLoop.configuredContextCeiling = 512;
  config.lifecycleWake = [&] { completionWake.count_down(); };
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });
  require(bootstrap->observePower(LifecyclePower::Battery),
          "shutdown race fixture did not establish Battery intent");
  LifecycleStatusSnapshot suspended = bootstrap->lifecycleStatus();
  suspended.state = LifecycleState::Suspended;
  suspended.controlReady = true;
  suspended.inferenceReady = false;
  suspended.modelResident = false;
  require(bootstrap->publishLifecycleStatus(suspended) &&
              bootstrap->observePower(LifecyclePower::AC),
          "shutdown race fixture did not enter AC recovery intent");
  EngineConfig candidateConfig;
  candidateConfig.maxContext = 512;
  RuntimeBootstrapTestAccess::installTestRecoverySpec(
      *bootstrap, candidateConfig, [&] { completionWake.count_down(); });

  std::latch buildStarted(1);
  std::latch releaseBuild(1);
  ReleaseLatchesOnExit release{{&releaseBuild}};
  RuntimeBootstrap *bootstrapPointer = bootstrap.get();
  RuntimeBootstrapTestAccess::installRecoveryBuilder(
      *bootstrap, [&, bootstrapPointer, cache = &retained.cache()](uint64_t rev) {
        buildStarted.count_down();
        releaseBuild.wait();
        RuntimeBootstrapTestAccess::createPrivateCandidate(
            *bootstrapPointer,
            std::make_unique<ModelPackageResidency>(model::ModelPackage{}),
            std::make_unique<Executor>(0), *cache, rev);
      });
  require(RuntimeBootstrapTestAccess::advanceRecovery(*bootstrap) ==
              RecoveryProgress::Building,
          "AC recovery did not move construction to its worker");
  buildStarted.wait();
  require(bootstrap->shutdownLifecycle(),
          "shutdown did not supersede in-flight recovery revision");
  const uint64_t shutdownRevision = bootstrap->lifecycleStatus().revision;
  releaseBuild.count_down();
  completionWake.wait();
  require(RuntimeBootstrapTestAccess::advanceRecovery(*bootstrap) ==
                  RecoveryProgress::Idle &&
              bootstrap->lifecycleStatus().state == LifecycleState::Shutdown &&
              bootstrap->lifecycleStatus().revision == shutdownRevision &&
              !bootstrap->nativeLoop().hasEngine() &&
              !bootstrap->hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(*bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(*bootstrap) &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(*bootstrap) &&
              readyEventCount(output) == 1,
          "completed stale recovery retained residency or overrode shutdown");
}

std::vector<protocol::Message>
decodedMessages(const std::vector<uint8_t> &output) {
  protocol::FrameParser parser;
  size_t offset = 0;
  std::vector<protocol::Message> messages;
  while (offset < output.size()) {
    const auto step = parser.consume(
        std::span<const uint8_t>(output).subspan(offset));
    require(!step.issue && step.consumedBytes,
            "suspend output contained an invalid protocol frame");
    offset += step.consumedBytes;
    if (!step.frame)
      continue;
    const auto decoded = protocol::decodeFrame(*step.frame);
    require(static_cast<bool>(decoded),
            "suspend output frame did not decode");
    messages.push_back(*decoded.value);
  }
  return messages;
}

size_t readyEventCount(const std::vector<uint8_t> &output) {
  const auto messages = decodedMessages(output);
  size_t readyEvents = 0;
  for (const auto &message : messages)
    readyEvents += std::holds_alternative<protocol::ReadyEvent>(message);
  return readyEvents;
}

void testRepeatedSameGenerationSuspendRecoveryPreservesRetainedGraph() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness retained(plan);
  retained.retainPrefixState();
  const CacheSnapshot baseline = retained.cache().snapshot();
  require(baseline.stateCache.entries == 1 && baseline.activeRequests == 0 &&
              retained.residentBackingPages() == 16,
          "repeated-cycle fixture did not contain the retained cache graph");

  std::vector<uint8_t> output;
  SuspendBootstrapFixture fixture =
      makeSuspendBootstrapFixture(output, retained);
  RuntimeBootstrap &bootstrap = *fixture.bootstrap;
  RuntimeBootstrap *const bootstrapIdentity = &bootstrap;
  NativeRuntime *const nativeIdentity = &bootstrap.nativeLoop();

  std::mutex wakeMutex;
  std::condition_variable wakeCondition;
  size_t completionWakes = 0;
  EngineConfig recoveryConfig;
  recoveryConfig.maxContext = 512;
  RuntimeBootstrapTestAccess::installTestRecoverySpec(
      bootstrap, recoveryConfig, [&] {
        {
          std::lock_guard lock(wakeMutex);
          ++completionWakes;
        }
        wakeCondition.notify_all();
      });

  std::atomic<size_t> buildCount{0};
  RuntimeBootstrapTestAccess::installRecoveryBuilder(
      bootstrap, [&, bootstrapIdentity, cache = &retained.cache()](uint64_t revision) {
        ++buildCount;
        auto package =
            std::make_unique<ModelPackageResidency>(model::ModelPackage{});
        auto runtime = std::make_unique<Executor>(0);
        RuntimeBootstrapTestAccess::createPrivateCandidate(
            *bootstrapIdentity, std::move(package), std::move(runtime), *cache,
            revision);
      });

  const auto retainedGraphMatchesBaseline = [&] {
    const CacheSnapshot current = retained.cache().snapshot();
    return current.stateCache.entries == baseline.stateCache.entries &&
           current.stateCache.bytes == baseline.stateCache.bytes &&
           current.kvCache.blocks == baseline.kvCache.blocks &&
           current.kvCache.bytes == baseline.kvCache.bytes &&
           current.pool.pagesActive == baseline.pool.pagesActive &&
           current.pool.pagesPrefix == baseline.pool.pagesPrefix &&
           current.pool.pagesResident == baseline.pool.pagesResident &&
           current.pool.residentBackingBytes ==
               baseline.pool.residentBackingBytes &&
           retained.residentBackingPages() == 16;
  };

  const auto runBatteryAcCycle = [&](size_t cycle) {
    require(bootstrap.observePower(LifecyclePower::Battery) &&
                bootstrap.beginSuspend(),
            "Battery intent did not start the repeated suspend cycle");
    SuspendProgress suspendProgress = bootstrap.advanceSuspend();
    while (suspendProgress == SuspendProgress::WaitingForDrain)
      suspendProgress = bootstrap.advanceSuspend();

    const LifecycleStatusSnapshot suspended = bootstrap.lifecycleStatus();
    require(suspendProgress == SuspendProgress::Suspended &&
                suspended.power == LifecyclePower::Battery &&
                suspended.state == LifecycleState::Suspended &&
                suspended.controlReady && !suspended.inferenceReady &&
                !suspended.modelResident && !bootstrap.nativeLoop().hasEngine() &&
                !bootstrap.hasModelRuntime() &&
                !RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
                !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
                readyEventCount(output) == 1 && retainedGraphMatchesBaseline(),
            "Battery suspend did not preserve the graph in the same control generation");

    size_t wakeBeforeRecovery = 0;
    {
      std::lock_guard lock(wakeMutex);
      wakeBeforeRecovery = completionWakes;
    }
    require(bootstrap.observePower(LifecyclePower::AC) &&
                RuntimeBootstrapTestAccess::advanceRecovery(bootstrap) ==
                    RecoveryProgress::Building,
            "AC intent did not start asynchronous recovery");
    {
      std::unique_lock lock(wakeMutex);
      waitFor(wakeCondition, lock,
              [&] { return completionWakes > wakeBeforeRecovery; },
              "recovery builder did not signal its lifecycle completion");
    }

    require(RuntimeBootstrapTestAccess::advanceRecovery(bootstrap) ==
                RecoveryProgress::Ready,
            "safe-point recovery did not publish its completed candidate");
    const LifecycleStatusSnapshot ready = bootstrap.lifecycleStatus();
    require(ready.power == LifecyclePower::AC &&
                ready.state == LifecycleState::Ready && ready.controlReady &&
                ready.inferenceReady && ready.modelResident &&
                ready.effectiveContextTokens == 512 &&
                bootstrap.nativeLoop().hasEngine() &&
                bootstrap.hasModelRuntime() &&
                RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
                RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
                !RuntimeBootstrapTestAccess::hasRecoveryCandidate(bootstrap) &&
                &bootstrap == bootstrapIdentity &&
                &bootstrap.nativeLoop() == nativeIdentity &&
                buildCount.load() == cycle && readyEventCount(output) == 1 &&
                retainedGraphMatchesBaseline(),
            "AC recovery changed generation identity or the retained cache graph");
  };

  runBatteryAcCycle(1);
  runBatteryAcCycle(2);

  const LifecycleStatusSnapshot final = bootstrap.lifecycleStatus();
  require(buildCount.load() == 2 && &bootstrap == bootstrapIdentity &&
              &bootstrap.nativeLoop() == nativeIdentity &&
              readyEventCount(output) == 1 && retainedGraphMatchesBaseline() &&
              final.state == LifecycleState::Ready &&
              final.power == LifecyclePower::AC && final.inferenceReady &&
              final.effectiveContextTokens == 512 &&
              RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap),
          "two successful power cycles did not remain in one ready generation");
}

void testPumpableSuspendReleaseAndDetachedPublication() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  std::vector<uint8_t> output;
  SuspendBootstrapFixture fixture =
      makeSuspendBootstrapFixture(output, dependencies);
  RuntimeBootstrap &bootstrap = *fixture.bootstrap;
  NativeRuntime &loop = bootstrap.nativeLoop();
  require(loop.idle() && !loop.commandInFlight() &&
              fixture.runtime->transferSubmissions == 0,
          "dual-barrier fixture began with Engine work in flight");

  bool engineGoneAtRuntimeDestruction = false;
  bool packageAliveAtRuntimeDestruction = false;
  fixture.runtime->destructionHook = [&] {
    engineGoneAtRuntimeDestruction = !loop.hasEngine();
    packageAliveAtRuntimeDestruction =
        RuntimeBootstrapTestAccess::hasModelPackage(bootstrap);
  };

  require(bootstrap.observePower(LifecyclePower::Battery) &&
              bootstrap.beginSuspend(),
          "current battery intent did not begin suspension");
  const LifecycleStatusSnapshot draining = bootstrap.lifecycleStatus();
  require(draining.state == LifecycleState::Draining &&
              draining.controlReady && !draining.inferenceReady &&
              draining.modelResident && loop.hasEngine() &&
              bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap),
          "beginSuspend did not close admission while preserving residency");
  require(bootstrap.beginSuspend(),
          "equivalent in-progress battery suspend was not idempotent");

  const uint64_t drainingRevision = bootstrap.lifecycleStatus().revision;
  require(RuntimeBootstrapTestAccess::advanceSuspendObserved(
              bootstrap, true, true) == SuspendProgress::WaitingForDrain &&
              loop.idle() && !loop.commandInFlight() &&
              fixture.runtime->transferSubmissions == 1 &&
              bootstrap.lifecycleStatus().revision == drainingRevision &&
              bootstrap.lifecycleStatus().state == LifecycleState::Draining &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              loop.hasEngine() && bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              readyEventCount(output) == 1,
          "A=true/B=true did not wait with one bounded tick and intact residency");

  require(RuntimeBootstrapTestAccess::advanceSuspendObserved(
              bootstrap, true, false) == SuspendProgress::Suspended &&
              engineGoneAtRuntimeDestruction &&
              packageAliveAtRuntimeDestruction && !loop.hasEngine() &&
              !bootstrap.hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              bootstrap.lifecycleStatus().state == LifecycleState::Suspended &&
              readyEventCount(output) == 1,
          "A=true/B=false did not release in order without another tick");

  const ResourceSnapshot released = bootstrap.detachedResourceSnapshot();
  require(validResourceSnapshot(released) &&
              released.lifecycle.state == LifecycleState::Suspended &&
              released.lifecycle.controlReady &&
              !released.lifecycle.inferenceReady &&
              !released.lifecycle.modelResident &&
              !released.modelPackageResident &&
              !released.modelPackageResidentBytes &&
              !released.runtimeResident && !released.runtimeResidentBytes &&
              !released.modelTelemetryAvailable,
          "successful suspend did not expose objective model-less residency");
  const std::string status = runtimeStatusJson(
      released, RuntimeMetricsSnapshot{}, MemoryPressure::Normal, {},
      ResourceWaitSnapshot{});
  require(status.find("\"state\":\"suspended\"") != std::string::npos &&
              status.find("\"model_resident\":false") !=
                  std::string::npos &&
              status.find("\"inference_ready\":false") !=
                  std::string::npos &&
              status.find("\"inference_ready\":true") ==
                  std::string::npos,
          "detached suspended status exposed stale warmup readiness");

  const CacheSnapshot retained = dependencies.cache().snapshot();
  require(retained.pool.pagesResident == 16 && retained.activeRequests == 0 &&
              dependencies.residentBackingPages() == 16 &&
              loop.ready() && loop.runControl([] { return true; }) &&
              readyEventCount(output) == 1,
          "suspend did not preserve retained test backing and control shell");
  auto statusRequest = protocol::serializeMessage(
      protocol::Message{protocol::StatusRequestFrame{88}});
  require(statusRequest && loop.receive(*statusRequest.value) &&
              readyEventCount(output) == 1,
          "model-less control shell failed or emitted a second ReadyEvent");
}

void testSuspendDrainsPreCloseRequestAndRejectsPostCloseRequest() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  std::vector<uint8_t> output;
  SuspendBootstrapFixture fixture =
      makeSuspendBootstrapFixture(output, dependencies);
  RuntimeBootstrap &bootstrap = *fixture.bootstrap;
  NativeRuntime &loop = bootstrap.nativeLoop();
  fixture.runtime->heldRequestTicketReady = std::make_shared<bool>(false);

  auto makeRequest = [](uint64_t id) {
    protocol::RequestFrame frame;
    frame.requestId = id;
    frame.priority = protocol::RequestPriority::Foreground;
    frame.cohort = protocol::Cohort::Greedy;
    frame.constraint = protocol::ConstraintMode::None;
    frame.absoluteDeadlineUnixMicros = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count()) + 10'000'000;
    frame.remainingDeadlineMicros = 5'000'000;
    frame.logicalMaxOutputTokens = 1;
    frame.promptTokens = {1, 2};
    return protocol::serializeMessage(protocol::Message{std::move(frame)});
  };

  auto admitted = makeRequest(801);
  require(admitted && loop.receive(*admitted.value) && loop.tick() &&
              loop.snapshot().submitted == 1 && !loop.idle() &&
              loop.commandInFlight(),
          "pre-close request did not reach a held Engine ticket");
  bool engineGoneAtRuntimeDestruction = false;
  bool packageAliveAtRuntimeDestruction = false;
  fixture.runtime->destructionHook = [&] {
    engineGoneAtRuntimeDestruction = !loop.hasEngine();
    packageAliveAtRuntimeDestruction =
        RuntimeBootstrapTestAccess::hasModelPackage(bootstrap);
  };

  require(bootstrap.observePower(LifecyclePower::Battery) &&
              bootstrap.beginSuspend(),
          "held pre-close request prevented suspend from entering Draining");
  const uint64_t drainingRevision = bootstrap.lifecycleStatus().revision;
  require(bootstrap.lifecycleStatus().state == LifecycleState::Draining &&
              !bootstrap.lifecycleStatus().inferenceReady &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              loop.hasEngine() && bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap),
          "beginSuspend did not close admission while preserving active residency");

  auto postClose = makeRequest(802);
  require(postClose && loop.receive(*postClose.value) &&
              loop.snapshot().submitted == 1 &&
              bootstrap.lifecycleStatus().revision == drainingRevision &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              loop.hasEngine() && readyEventCount(output) == 1,
          "post-close request reached Engine or changed suspend state");
  const auto postCloseMessages = decodedMessages(output);
  require(std::any_of(postCloseMessages.begin(), postCloseMessages.end(),
                      [](const protocol::Message &message) {
                        const auto *error =
                            std::get_if<protocol::ErrorEvent>(&message);
                        return error && error->requestId == 802 &&
                               error->failureClass ==
                                   protocol::FailureClass::RequestError &&
                               error->code == "inference_unavailable";
                      }),
          "post-close request did not receive request-scoped unavailable");

  auto cancel = protocol::serializeMessage(
      protocol::Message{protocol::CancelFrame{801}});
  require(cancel && loop.receive(*cancel.value) &&
              bootstrap.advanceSuspend() == SuspendProgress::WaitingForDrain &&
              !loop.idle() && loop.commandInFlight() && loop.hasEngine() &&
              bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap),
          "suspend released residency before the admitted ticket drained");

  *fixture.runtime->heldRequestTicketReady = true;
  require(bootstrap.advanceSuspend() == SuspendProgress::WaitingForDrain &&
              loop.idle() && !loop.commandInFlight() && loop.hasEngine() &&
              bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap),
          "held request did not reach its cancellation boundary before release");
  const auto drainedMessages = decodedMessages(output);
  require(std::any_of(drainedMessages.begin(), drainedMessages.end(),
                      [](const protocol::Message &message) {
                        const auto *done =
                            std::get_if<protocol::DoneEvent>(&message);
                        return done && done->requestId == 801 &&
                               done->reason == protocol::FinishReason::Cancelled;
                      }),
          "admitted request did not complete through normal cancellation output");

  require(bootstrap.advanceSuspend() == SuspendProgress::Suspended &&
              engineGoneAtRuntimeDestruction &&
              packageAliveAtRuntimeDestruction && !loop.hasEngine() &&
              !bootstrap.hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              bootstrap.lifecycleStatus().state == LifecycleState::Suspended &&
              readyEventCount(output) == 1,
          "suspend did not release only after the admitted request drained");
}

void testShutdownSupersedesSuspendDuringDrain() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  std::vector<uint8_t> output;
  SuspendBootstrapFixture fixture =
      makeSuspendBootstrapFixture(output, dependencies);
  RuntimeBootstrap &bootstrap = *fixture.bootstrap;
  NativeRuntime &loop = bootstrap.nativeLoop();
  bool runtimeDestroyed = false;
  fixture.runtime->destructionHook = [&] { runtimeDestroyed = true; };

  require(bootstrap.observePower(LifecyclePower::Battery) &&
              bootstrap.beginSuspend() &&
              RuntimeBootstrapTestAccess::advanceSuspendObserved(
                  bootstrap, true, true) == SuspendProgress::WaitingForDrain &&
              loop.hasEngine() && bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              bootstrap.lifecycleStatus().state == LifecycleState::Draining,
          "shutdown fixture did not hold suspension before destructive release");
  require(bootstrap.shutdownLifecycle(),
          "ordinary shutdown did not supersede the active suspend intent");
  const uint64_t shutdownRevision = bootstrap.lifecycleStatus().revision;
  require(bootstrap.advanceSuspend() == SuspendProgress::Superseded &&
              bootstrap.lifecycleStatus().state == LifecycleState::Shutdown &&
              bootstrap.lifecycleStatus().revision == shutdownRevision &&
              loop.hasEngine() && bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              !runtimeDestroyed &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              readyEventCount(output) == 1,
          "stale suspend released residency or overrode shutdown");
}

void testShutdownWinsAlreadySuspendedLifecycle() {
  Harness dependencies(memoryPlan());
  std::vector<uint8_t> output;
  SuspendBootstrapFixture fixture =
      makeSuspendBootstrapFixture(output, dependencies);
  RuntimeBootstrap &bootstrap = *fixture.bootstrap;
  NativeRuntime &loop = bootstrap.nativeLoop();

  require(bootstrap.observePower(LifecyclePower::Battery) &&
              bootstrap.beginSuspend(),
          "already-suspended fixture could not begin battery suspension");
  SuspendProgress progress = bootstrap.advanceSuspend();
  while (progress == SuspendProgress::WaitingForDrain)
    progress = bootstrap.advanceSuspend();
  const LifecycleStatusSnapshot suspended = bootstrap.lifecycleStatus();
  require(progress == SuspendProgress::Suspended &&
              suspended.power == LifecyclePower::Battery &&
              suspended.state == LifecycleState::Suspended &&
              suspended.controlReady && !suspended.inferenceReady &&
              !suspended.modelResident && !loop.hasEngine() &&
              !bootstrap.hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              readyEventCount(output) == 1,
          "fixture did not reach a fully released suspended lifecycle");

  const uint64_t suspendedRevision = suspended.revision;
  require(bootstrap.shutdownLifecycle(),
          "shutdown did not supersede the already-suspended lifecycle");
  const LifecycleStatusSnapshot shutdown = bootstrap.lifecycleStatus();
  require(shutdown.state == LifecycleState::Shutdown &&
              shutdown.revision == suspendedRevision + 1 &&
              !shutdown.controlReady && !shutdown.inferenceReady &&
              !shutdown.modelResident &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              !loop.hasEngine() && !bootstrap.hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              readyEventCount(output) == 1,
          "shutdown did not close the already-suspended lifecycle cleanly");

  require(!bootstrap.observePower(LifecyclePower::AC) &&
              !bootstrap.beginSuspend() &&
              bootstrap.advanceSuspend() == SuspendProgress::Idle &&
              RuntimeBootstrapTestAccess::advanceRecovery(bootstrap) ==
                  RecoveryProgress::Idle,
          "stale automatic lifecycle work ran after suspended shutdown");
  const LifecycleStatusSnapshot final = bootstrap.lifecycleStatus();
  require(final.revision == shutdown.revision &&
              final.state == LifecycleState::Shutdown &&
              !final.controlReady && !final.inferenceReady &&
              !final.modelResident && !loop.hasEngine() &&
              !bootstrap.hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              readyEventCount(output) == 1,
          "stale automatic work changed or reconstructed suspended shutdown");
}

void testSuspendRevisionSupersededBeforeDestructiveRelease() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  std::vector<uint8_t> output;
  SuspendBootstrapFixture fixture =
      makeSuspendBootstrapFixture(output, dependencies);
  RuntimeBootstrap &bootstrap = *fixture.bootstrap;
  NativeRuntime &loop = bootstrap.nativeLoop();
  bool runtimeDestroyed = false;
  fixture.runtime->destructionHook = [&] { runtimeDestroyed = true; };

  require(bootstrap.observePower(LifecyclePower::Battery) &&
              bootstrap.beginSuspend() &&
              bootstrap.observePower(LifecyclePower::AC),
          "could not supersede battery suspend before release");
  require(bootstrap.advanceSuspend() == SuspendProgress::Superseded &&
              loop.hasEngine() && bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              !runtimeDestroyed &&
              RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              bootstrap.lifecycleStatus().power == LifecyclePower::AC &&
              bootstrap.lifecycleStatus().state == LifecycleState::Ready &&
              bootstrap.lifecycleStatus().inferenceReady,
          "AC intent failed to resume published residency after superseding drain");
}

void testSuspendRevisionSupersededAfterDestructiveRelease() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  std::vector<uint8_t> output;
  SuspendBootstrapFixture fixture =
      makeSuspendBootstrapFixture(output, dependencies);
  RuntimeBootstrap &bootstrap = *fixture.bootstrap;
  NativeRuntime &loop = bootstrap.nativeLoop();
  RuntimeBootstrap *const bootstrapIdentity = &bootstrap;
  NativeRuntime *const nativeIdentity = &loop;
  std::mutex completionMutex;
  std::condition_variable completionWake;
  uint32_t completionCount = 0;
  EngineConfig recoveryConfig;
  recoveryConfig.maxContext = 512;
  RuntimeBootstrapTestAccess::installTestRecoverySpec(
      bootstrap, recoveryConfig, [&] {
        {
          std::lock_guard lock(completionMutex);
          ++completionCount;
        }
        completionWake.notify_one();
      });
  RuntimeBootstrapTestAccess::installRecoveryBuilder(
      bootstrap, [&](uint64_t revision) {
        auto package =
            std::make_unique<ModelPackageResidency>(model::ModelPackage{});
        auto runtime = std::make_unique<Executor>(0);
        RuntimeBootstrapTestAccess::createPrivateCandidate(
            bootstrap, std::move(package), std::move(runtime),
            dependencies.cache(), revision);
      });
  bool newerIntentArrived = false;
  fixture.runtime->destructionHook = [&] {
    newerIntentArrived = !loop.hasEngine() &&
                         bootstrap.observePower(LifecyclePower::AC);
  };

  require(bootstrap.observePower(LifecyclePower::Battery) &&
              bootstrap.beginSuspend(),
          "could not begin late-supersession suspend");
  const uint64_t suspendRevision = bootstrap.lifecycleStatus().revision;
  require(bootstrap.advanceSuspend() == SuspendProgress::Superseded &&
              newerIntentArrived && !loop.hasEngine() &&
              !bootstrap.hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(bootstrap),
          "newer power intent interrupted committed destructive release");
  const LifecycleStatusSnapshot released = bootstrap.lifecycleStatus();
  require(released.power == LifecyclePower::AC &&
              released.revision == suspendRevision + 1 &&
              released.state == LifecycleState::Suspended &&
              !released.inferenceReady && !released.modelResident &&
              released.controlReady && !loop.hasEngine() &&
              released.effectiveContextTokens == 512 &&
              !bootstrap.hasModelRuntime() &&
              !RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              !RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              readyEventCount(output) == 1,
          "stale suspend did not leave a recoverable model-less AC lifecycle");

  require(RuntimeBootstrapTestAccess::advanceRecovery(bootstrap) ==
              RecoveryProgress::Building,
          "current AC revision did not start recovery after stale suspend");
  uint32_t observedCompletionCount = 0;
  {
    std::unique_lock lock(completionMutex);
    completionWake.wait(lock, [&] { return completionCount > 0; });
    observedCompletionCount = completionCount;
  }
  require(observedCompletionCount == 1,
          "recovery builder emitted more than one completion wake");
  require(RuntimeBootstrapTestAccess::advanceRecovery(bootstrap) ==
              RecoveryProgress::Ready,
          "current AC recovery did not publish at the next safe point");

  const LifecycleStatusSnapshot recovered = bootstrap.lifecycleStatus();
  require(&bootstrap == bootstrapIdentity &&
              &bootstrap.nativeLoop() == nativeIdentity &&
              recovered.power == LifecyclePower::AC &&
              recovered.state == LifecycleState::Ready &&
              recovered.inferenceReady && recovered.modelResident &&
              recovered.effectiveContextTokens == 512 && loop.hasEngine() &&
              bootstrap.hasModelRuntime() &&
              RuntimeBootstrapTestAccess::hasModelPackage(bootstrap) &&
              RuntimeBootstrapTestAccess::inferenceAdmissionOpen(bootstrap) &&
              !RuntimeBootstrapTestAccess::hasRecoveryCandidate(bootstrap) &&
              readyEventCount(output) == 1,
          "late AC intent did not recover in the same control generation");
}

void testBootstrapSerializesLifecycleIntentWithRequestAdmission() {
  RuntimeBootstrapConfig config;
  config.nativeLoop.engine.maxContext = 1024;
  std::vector<uint8_t> output;
  auto bootstrap = RuntimeBootstrap::startModelLess(
      std::move(config),
      [&](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string(R"({"schema_version":5})"); });
  RuntimeBootstrap &authority = *bootstrap;
  NativeRuntime &loop = authority.nativeLoop();
  const EngineMemoryPlan plan = memoryPlan();
  Harness dependencies(plan);
  loop.publishEngine(dependencies.cache(), dependencies.executor());

  require(authority.observePower(LifecyclePower::AC),
          "AC intent did not advance admission revision");
  auto ready = authority.lifecycleStatus();
  ready.state = LifecycleState::Ready;
  ready.controlReady = true;
  ready.modelResident = true;
  ready.inferenceReady = true;
  ready.effectiveContextTokens = 1024;
  require(authority.publishLifecycleStatus(ready),
          "current AC lifecycle status did not open native admission");

  auto makeRequest = [](uint64_t id) {
    protocol::RequestFrame frame;
    frame.requestId = id;
    frame.priority = protocol::RequestPriority::Foreground;
    frame.cohort = protocol::Cohort::Greedy;
    frame.constraint = protocol::ConstraintMode::None;
    frame.absoluteDeadlineUnixMicros = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count()) + 10'000'000;
    frame.remainingDeadlineMicros = 5'000'000;
    frame.logicalMaxOutputTokens = 1;
    frame.promptTokens = {1, 2};
    return protocol::serializeMessage(protocol::Message{std::move(frame)});
  };
  auto admitted = makeRequest(71);
  require(admitted && loop.receive(*admitted.value) &&
              loop.snapshot().submitted == 1,
          "current AC intent did not admit the request");

  require(authority.observePower(LifecyclePower::Battery),
          "battery intent did not close native admission");
  auto rejected = makeRequest(72);
  require(rejected && loop.receive(*rejected.value) &&
              loop.snapshot().submitted == 1,
          "request after gate closure reached Engine submission");
  const auto messages = [&] {
    protocol::FrameParser parser;
    std::vector<protocol::Message> result;
    size_t offset = 0;
    while (offset < output.size()) {
      auto step = parser.consume(std::span<const uint8_t>(output).subspan(offset));
      require(!step.issue && step.consumedBytes,
              "admission output contained an invalid frame");
      offset += step.consumedBytes;
      if (step.frame) {
        auto decoded = protocol::decodeFrame(*step.frame);
        require(static_cast<bool>(decoded), "admission frame did not decode");
        result.push_back(std::move(*decoded.value));
      }
    }
    return result;
  }();
  require(std::any_of(messages.begin(), messages.end(), [](const auto &message) {
            const auto *error = std::get_if<protocol::ErrorEvent>(&message);
            return error && error->requestId == 72 &&
                   error->code == "inference_unavailable";
          }),
          "closed admission did not return a prompt unavailable response");

  require(authority.observePower(LifecyclePower::AC),
          "AC intent did not reopen the next admission revision");
  ready = authority.lifecycleStatus();
  ready.state = LifecycleState::Ready;
  ready.controlReady = true;
  ready.modelResident = true;
  ready.inferenceReady = true;
  ready.effectiveContextTokens = 1024;
  require(authority.publishLifecycleStatus(ready),
          "current AC status did not reopen request admission");

  auto racingRequest = makeRequest(73);
  require(static_cast<bool>(racingRequest),
          "racing request could not be encoded");
  std::barrier raceStart(3);
  bool raceReceiveSucceeded = false;
  bool racePowerObserved = false;
  std::thread requestThread([&] {
    raceStart.arrive_and_wait();
    raceReceiveSucceeded = loop.receive(*racingRequest.value);
  });
  std::thread closeThread([&] {
    raceStart.arrive_and_wait();
    racePowerObserved = authority.observePower(LifecyclePower::Battery);
  });
  raceStart.arrive_and_wait();
  requestThread.join();
  closeThread.join();
  require(raceReceiveSucceeded,
          "racing request closed the protocol connection");
  require(racePowerObserved,
          "racing battery intent did not close admission");
  const uint64_t submittedAfterRace = loop.snapshot().submitted;
  require(submittedAfterRace == 1 || submittedAfterRace == 2,
          "racing request had an ambiguous admission result");
  if (submittedAfterRace == 2) {
    bool prematureRaceDestroyRejected = false;
    try {
      loop.destroyEngine();
    } catch (const std::logic_error &) {
      prematureRaceDestroyRejected = true;
    }
    require(prematureRaceDestroyRejected,
            "racing admitted request did not retain Engine residency");
  } else {
    protocol::FrameParser parser;
    size_t offset = 0;
    bool unavailable = false;
    while (offset < output.size()) {
      auto step = parser.consume(std::span<const uint8_t>(output).subspan(offset));
      require(!step.issue && step.consumedBytes,
              "racing admission output contained an invalid frame");
      offset += step.consumedBytes;
      if (!step.frame)
        continue;
      auto decoded = protocol::decodeFrame(*step.frame);
      require(static_cast<bool>(decoded),
              "racing admission response did not decode");
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&*decoded.value))
        unavailable |= error->requestId == 73 &&
                       error->code == "inference_unavailable";
    }
    require(unavailable,
            "racing request rejected after closure lacked prompt unavailable response");
  }

  bool prematureDestroyRejected = false;
  try {
    loop.destroyEngine();
  } catch (const std::logic_error &) {
    prematureDestroyRejected = true;
  }
  require(prematureDestroyRejected,
          "admitted request did not retain Engine residency across closure");
  for (uint64_t id : {71, 73}) {
    auto cancel = protocol::serializeMessage(
        protocol::Message{protocol::CancelFrame{id}});
    require(cancel && loop.receive(*cancel.value),
            "admitted request could not be cancelled after admission closed");
  }
  for (uint32_t step = 0; step < 32 && !loop.idle(); ++step)
    static_cast<void>(loop.tick());
  require(loop.idle(), "admitted request failed to reach a drain boundary");
  loop.destroyEngine();
  require(!loop.hasEngine() && loop.ready(),
          "closing inference admission destroyed control readiness");
}

void testAllNativeWarmupsPrecedeReady() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness harness(plan);
  require(!harness.loop().ready() && harness.output().empty(),
          "runtime became visible before warmup");
  ActualMemoryReport actual = validActual(plan);
  auto report = engine::RuntimeBootstrap::requireWarmupAndAnnounce(
      plan, harness.executor(),
      [&](uint64_t estimate) {
        require(estimate == actual.estimatedWarmupPeakBytes,
                "bootstrap lost the maximum measured peak");
        actual.estimatedWarmupPeakBytes = estimate;
        return actual;
      },
      harness.loop());
  require(report.ready && report.warmup.ready() && report.memoryAudit.valid &&
              harness.loop().ready() && !harness.output().empty(),
          "successful native bootstrap was incomplete");
  require(harness.executor().calls == std::vector<int>({0, 1, 2, 3, 4, 5, 6}),
          "bootstrap did not warm fixed prefill and B1/B2/B3/B4 in order");
  require(harness.executor().lastPrefillRows == model::ExecutionLimits::prefillTokenBudget,
          "bootstrap memory warmup did not explicitly use maximum prefill rows");
  require(report.warmup.decodeBatches[2] == WarmupStepStatus::Complete,
          "bootstrap report omitted the real B3 graph");
}

RuntimeBootstrapReport warmup(Harness &harness, const EngineMemoryPlan &plan) {
  return RuntimeBootstrap::requireWarmupAndAnnounce(
      plan, harness.executor(),
      [&](uint64_t estimate) {
        auto actual = validActual(plan);
        actual.estimatedWarmupPeakBytes = estimate;
        return actual;
      },
      harness.loop());
}

void requireReadyWithoutReducingConcurrency(
    Harness &harness, const RuntimeBootstrapReport &report) {
  require(report.ready && report.warmup.ready() && report.memoryAudit.valid &&
              harness.loop().ready(),
          "memory-limited warmup did not become ready");
  protocol::FrameParser parser;
  const auto parsed = parser.consume(harness.output());
  require(!parsed.issue && parsed.frame &&
              parsed.consumedBytes == harness.output().size() && !parser.finish(),
          "bootstrap did not emit one complete Ready frame");
  const auto message = protocol::decodeFrame(*parsed.frame);
  const auto *ready = message ? std::get_if<protocol::ReadyEvent>(&*message.value)
                              : nullptr;
  require(ready && ready->maxConcurrentRequests == 4,
          "startup budget permanently reduced the advertised concurrency");
}

void testBudgetLimitedWarmupKeepsRuntimeConcurrency() {
  const auto complete = memoryPlan().breakdown();
  for (uint32_t width : {1U, 2U, 3U}) {
    // Enough for the requested resident cells and one KV extent, with less
    // than one extra cell of headroom. This is a valid single-lane plan.
    const uint64_t ceiling = complete.minimumRequiredBytes +
                            (width - 1) * complete.activeStateCellBytes +
                            complete.activeStateCellBytes / 2;
    const EngineMemoryPlan plan = requireEngineMemoryPlan(
        device(), test::modelMemoryProfile(2 * kGiB, 1 * kGiB, 1 * kGiB),
        ceiling);
    Harness harness(plan);
    const auto report = warmup(harness, plan);
    requireReadyWithoutReducingConcurrency(harness, report);
    std::vector<int> expected{0};
    for (uint32_t lane = 1; lane <= width; ++lane)
      expected.push_back(static_cast<int>(lane));
    expected.insert(expected.end(), {5, 6});
    require(harness.executor().calls == expected,
            "warmup attempted a decode width that cannot fit the plan");
    for (uint32_t lane = 0; lane < report.warmup.decodeBatches.size(); ++lane) {
      require(report.warmup.decodeBatches[lane] ==
                  (lane < width ? WarmupStepStatus::Complete
                                : WarmupStepStatus::MemoryLimited),
              "budget-skipped decode was reported as measured or pending");
    }
  }
}

void testOptionalAllocationFailuresAreMemoryLimited() {
  const EngineMemoryPlan plan = memoryPlan();
  for (int deniedWidth : {-1, 2, 3, 4}) {
    for (bool denyRestore : {false, true}) {
      Harness harness(plan);
      harness.executor().warmupHook = [&](int step, model::WarmupStepResult &) {
        if (step == deniedWidth || (step == 6 && denyRestore))
          throw metal::MetalAllocationError("injected allocation denial");
      };
      const auto report = warmup(harness, plan);
      requireReadyWithoutReducingConcurrency(harness, report);
      const uint32_t completedWidth = deniedWidth < 0 ? 4 : deniedWidth - 1;
      std::vector<int> expected{0};
      for (uint32_t width = 1; width <= completedWidth; ++width)
        expected.push_back(static_cast<int>(width));
      if (deniedWidth >= 0)
        expected.push_back(deniedWidth);
      expected.insert(expected.end(), {5, 6});
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
      // Text must neither opt a generic error into retries nor opt a real
      // capacity shortage out. Preserve the diagnostics through wrapping.
      for (const char *message : {
               "currently available; close memory-heavy applications and retry",
               "different diagnostic wording"}) {
        RuntimeResourcesError resourceError(stage, message, "{\"budget\":1}",
                                             "budget details", failure);
        RuntimeBootstrapError error(resourceError);
        const auto &report = error.report();
        require(!report.ready &&
                    report.stage == RuntimeBootstrapStage::ResourceAssembly &&
                    report.resourceFailure == failure &&
                    report.message == message && report.warmup.error == message &&
                    report.memoryPlanJson == "{\"budget\":1}" &&
                    report.budgetDescription == "budget details",
                "bootstrap lost resource failure classification or diagnostics");
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
    Harness harness(plan);
    harness.executor().warmupHook =
        [failure](int step, model::WarmupStepResult &) {
          if (step == 0)
            throw metal::MetalAllocationError("required allocation", failure);
        };
    try {
      static_cast<void>(warmup(harness, plan));
      throw std::runtime_error("required allocation refusal announced ready");
    } catch (const RuntimeBootstrapError &error) {
      require(error.report().resourceFailure == resourceAllocationFailure(failure) &&
                  !harness.loop().ready() && harness.output().empty(),
              "required warmup erased allocation refusal classification");
    }
  }
}

void testFinalHostPressurePreventsReady() {
  const EngineMemoryPlan plan = memoryPlan();
  Harness harness(plan);
  try {
    static_cast<void>(RuntimeBootstrap::requireWarmupAndAnnounce(
        plan, harness.executor(),
        [](uint64_t) -> ActualMemoryReport {
          throw metal::MetalAllocationError("pressure after warmup",
                                             metal::AllocationFailure::HostPressure);
        }, harness.loop()));
    throw std::runtime_error("final pressure check announced ready");
  } catch (const RuntimeBootstrapError &error) {
    require(error.report().resourceFailure == RuntimeResourceFailure::HostCapacity &&
                !harness.loop().ready() && harness.output().empty(),
            "final host pressure lost retryability or announced ready");
  }
}

void testEveryWarmupFailureIsFailClosed() {
  const EngineMemoryPlan plan = memoryPlan();
  constexpr engine::RuntimeBootstrapStage expected[] = {
      engine::RuntimeBootstrapStage::MaximumPrefill,
      engine::RuntimeBootstrapStage::DecodeWarmup,
      engine::RuntimeBootstrapStage::DecodeWarmup,
      engine::RuntimeBootstrapStage::DecodeWarmup,
      engine::RuntimeBootstrapStage::DecodeWarmup,
      engine::RuntimeBootstrapStage::DraftVerifyCommit,
      engine::RuntimeBootstrapStage::CompositeStateRestore,
  };
  for (int step = 0; step < 7; ++step) {
    Harness harness(plan, step);
    try {
      static_cast<void>(engine::RuntimeBootstrap::requireWarmupAndAnnounce(
          plan, harness.executor(),
          [&](uint64_t estimate) {
            auto actual = validActual(plan);
            actual.estimatedWarmupPeakBytes = estimate;
            return actual;
          },
          harness.loop()));
      throw std::runtime_error("failed warmup announced ready");
    } catch (const engine::RuntimeBootstrapError &error) {
      require(error.report().stage == expected[step] &&
                  error.report().resourceFailure == RuntimeResourceFailure::Other &&
                  !harness.loop().ready() && harness.output().empty(),
              "failed warmup escaped the native bootstrap gate");
    }
  }
}

void testWarmupErrorsCannotMasqueradeAsMemoryLimits() {
  enum class Failure {
    Allocation, Backend, General, MissingPeak, ZeroTime, InfiniteTime, NanTime
  };
  constexpr RuntimeBootstrapStage stages[] = {
      RuntimeBootstrapStage::MaximumPrefill,
      RuntimeBootstrapStage::DecodeWarmup,
      RuntimeBootstrapStage::DecodeWarmup,
      RuntimeBootstrapStage::DecodeWarmup,
      RuntimeBootstrapStage::DecodeWarmup,
      RuntimeBootstrapStage::DraftVerifyCommit,
      RuntimeBootstrapStage::CompositeStateRestore,
  };
  const EngineMemoryPlan plan = memoryPlan();
  for (int step = 0; step < 7; ++step) {
    for (Failure failure : {Failure::Allocation, Failure::Backend,
                            Failure::General, Failure::MissingPeak,
                            Failure::ZeroTime, Failure::InfiniteTime,
                            Failure::NanTime}) {
      if (failure == Failure::Allocation &&
          (step == 2 || step == 3 || step == 4 || step == 6))
        continue; // Only these paths may skip a real allocation refusal.
      Harness harness(plan);
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
            case Failure::MissingPeak:
              result.estimatedPeakBytes = 0;
              break;
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
        throw std::runtime_error("invalid warmup announced ready");
      } catch (const RuntimeBootstrapError &error) {
        require(error.report().stage == stages[step] &&
                    !error.report().warmup.ready() && !harness.loop().ready() &&
                    harness.output().empty() &&
                    harness.executor().calls.back() == step,
                "warmup failure was swallowed as a memory-limited success");
      }
    }
  }
}

void testExceptionsMemoryAndReadyWriteAreFailClosed() {
  const EngineMemoryPlan plan = memoryPlan();
  {
    Harness harness(plan, -1, 3);
    try {
      static_cast<void>(engine::RuntimeBootstrap::requireWarmupAndAnnounce(
          plan, harness.executor(),
          [](uint64_t) { return ActualMemoryReport{}; }, harness.loop()));
      throw std::runtime_error("warmup exception announced ready");
    } catch (const engine::RuntimeBootstrapError &error) {
      require(error.report().stage ==
                      engine::RuntimeBootstrapStage::DecodeWarmup &&
                  !harness.loop().ready(),
              "warmup exception was not contained");
    }
  }
  {
    Harness harness(plan);
    try {
      static_cast<void>(engine::RuntimeBootstrap::requireWarmupAndAnnounce(
          plan, harness.executor(),
          [](uint64_t) { return ActualMemoryReport{}; }, harness.loop()));
      throw std::runtime_error("invalid memory report announced ready");
    } catch (const engine::RuntimeBootstrapError &error) {
      require(error.report().stage ==
                      engine::RuntimeBootstrapStage::MemoryAudit &&
                  !harness.loop().ready(),
              "invalid memory report escaped the audit");
    }
  }
  {
    Harness harness(plan, -1, -1, true);
    try {
      static_cast<void>(engine::RuntimeBootstrap::requireWarmupAndAnnounce(
          plan, harness.executor(),
          [&](uint64_t estimate) {
            auto actual = validActual(plan);
            actual.estimatedWarmupPeakBytes = estimate;
            return actual;
          },
          harness.loop()));
      throw std::runtime_error("failed Ready write left runtime ready");
    } catch (const engine::RuntimeBootstrapError &error) {
      require(error.report().stage ==
                      engine::RuntimeBootstrapStage::AnnounceReady &&
                  !harness.loop().ready() && harness.output().empty(),
              "Ready write failure left a visible runtime");
    }
  }
}

void testStartupRetryWindowOpensAtFirstFailure() {
  using namespace std::chrono_literals;
  RuntimeBootstrapReport failure;
  failure.resourceFailure = RuntimeResourceFailure::HostCapacity;
  StartupRetryWindow window(30s);
  // A cold start fails for the first time after minutes of preparation.
  const auto first = StartupRetryWindow::Clock::time_point{} + 5min;
  require(window.retryUntil(failure, first) == first + 30s &&
              window.retryUntil(failure, first + 29s) == first + 30s &&
              !window.retryUntil(failure, first + 30s),
          "the startup retry window did not open at the first failure");
  // A retry that fails later in startup made progress: a new window opens.
  // Failing again at that stage or before does not extend it.
  failure.stage = RuntimeBootstrapStage::MaximumPrefill;
  require(window.retryUntil(failure, first + 40s) == first + 70s,
          "progress to a later startup stage did not open a new window");
  for (auto stage : {RuntimeBootstrapStage::MaximumPrefill,
                     RuntimeBootstrapStage::ResourceAssembly}) {
    failure.stage = stage;
    require(window.retryUntil(failure, first + 50s) == first + 70s,
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

// The disk tier suggestion follows the plan within the host's headroom
// beyond its reserve and the warning margin; a host with no more than those
// holds nothing.
void testMemoryMayNotHoldBeyondHostHeadroom() {
  const EngineMemoryPlan plan = memoryPlan();
  const auto &budget = plan.breakdown();
  const uint64_t held = EngineMemoryPolicy::hostAvailableReserveBytes(
                            budget.physicalMemoryBytes) +
                        kHostWarningMarginBytes;
  const uint64_t available = held + budget.minimumRequiredBytes + 64 * kMiB;
  const uint32_t fits = plan.contextTokensWithin(available - held);
  require(fits && fits < plan.maximumContextTokens() &&
              !memoryMayNotHold(plan, available, fits) &&
              memoryMayNotHold(plan, available, fits + 1) &&
              !memoryMayNotHold(plan, 64 * kGiB, plan.maximumContextTokens()) &&
              memoryMayNotHold(plan, held, 1),
          "the disk tier suggestion does not follow the host's headroom");
}

} // namespace

int main() {
  try {
    testWarmupLaneComparisons();
    testInstalledManifestBindsExecutionGeometry();
    testRuntimeCacheNamespaceBindsIdentityOnce();
    testPreSplitBootstrapHarnessObservesCoupledGraph();
    testModelLessControlShellAndEnginePublication();
    testBatteryColdStartCreatesOnlyTheControlShellBeforeAc();
    testPrivateRecoveryCandidateOwnershipAndRollback();
    testRecoveryCandidatePublicationIsTransactionalAndExact();
    testInvalidRecoveryContextFailsClosedAndCanRetry();
    testFinalRecoveryFenceKeepsNewBatteryIntentClosed();
    testRecoveryContextDriftKeepsControlGeneration();
    testNativeRuntimeAdoptionRefusalPreservesCandidate();
    testBootstrapPowerIntentRevisionAndShutdownAuthority();
    testFakePowerSourceQueuesAtSafePointAndStopsDelivery();
    testInitialAcObservationOpensExistingBootstrapResidency();
    testPowerObserverStopWaitsForInflightCallback();
    testAsyncRecoveryKeepsFdTransportResponsiveAndRevisionFenced();
    testRepeatedSameGenerationSuspendRecoveryPreservesRetainedGraph();
    testShutdownWinsBlockedRecoveryCompletion();
    testPumpableSuspendReleaseAndDetachedPublication();
    testSuspendDrainsPreCloseRequestAndRejectsPostCloseRequest();
    testShutdownSupersedesSuspendDuringDrain();
    testShutdownWinsAlreadySuspendedLifecycle();
    testSuspendRevisionSupersededBeforeDestructiveRelease();
    testSuspendRevisionSupersededAfterDestructiveRelease();
    testBootstrapSerializesLifecycleIntentWithRequestAdmission();
    testAllNativeWarmupsPrecedeReady();
    testBudgetLimitedWarmupKeepsRuntimeConcurrency();
    testOptionalAllocationFailuresAreMemoryLimited();
    testResourceFailureClassificationSurvivesBootstrap();
    testRequiredWarmupPreservesAllocationFailure();
    testFinalHostPressurePreventsReady();
    testEveryWarmupFailureIsFailClosed();
    testWarmupErrorsCannotMasqueradeAsMemoryLimits();
    testExceptionsMemoryAndReadyWriteAreFailClosed();
    testStartupRetryWindowOpensAtFirstFailure();
    testMemoryMayNotHoldBeyondHostHeadroom();
    std::cout << "native bootstrap tests passed\n";
    return EXIT_SUCCESS;
  } catch (const std::exception &error) {
    std::cerr << "native bootstrap tests failed: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
