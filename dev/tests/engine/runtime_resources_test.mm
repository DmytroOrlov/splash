#include "engine/RuntimeResources.hpp"
#include "engine/Status.hpp"
#include "engine/MemoryPlan.hpp"

#import <Foundation/Foundation.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace {

using namespace splash;
using namespace splash::engine;

static_assert(std::is_same_v<decltype(RuntimeResources::create(
                                 std::declval<const RuntimeResourcesConfig &>())),
                             std::unique_ptr<RuntimeResources>>);
static_assert(std::is_same_v<decltype(std::declval<RuntimeResources &>().backend()),
                             metal::MetalBackend &>);
static_assert(std::is_same_v<decltype(std::declval<RuntimeResources &>().cache()),
                             Cache &>);
static_assert(std::is_same_v<decltype(std::declval<RuntimeResources &>().stateStorage()),
                             model::StateStorage &>);
static_assert(std::is_same_v<
              decltype(std::declval<RuntimeResources &>()
                           .takeModelPackageResidency()),
              std::unique_ptr<ModelPackageResidency>>);

void require(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}

std::string describe(const RuntimeResourcesError &error) {
  std::ostringstream out;
  out << "failure=" << static_cast<int>(error.failure())
      << " what()=" << error.what() << " message()=" << error.message()
      << " statusJson()=" << error.statusJson()
      << " budgetDescription()=" << error.budgetDescription();
  return out.str();
}

template <typename Predicate>
void requireResourceError(const RuntimeResourcesError &error,
                          Predicate predicate, const char *message) {
  if (!predicate(error))
    throw std::runtime_error(std::string(message) + ": " + describe(error));
}

class TemporaryModelRoot final {
public:
  // Placeholders are sparse: a package larger than the machine's memory
  // costs three extents on disk.
  explicit TemporaryModelRoot(uint64_t bytesPerComponent = 16 * 1024)
      : fileBytes(bytesPerComponent), packageBytes(3 * bytesPerComponent) {
    path = std::filesystem::temp_directory_path() /
           ("splash-budget-" +
            std::string([NSUUID UUID].UUIDString.UTF8String));
    for (const char *component : {"target", "draft", "vision"}) {
      std::filesystem::create_directories(path / component);
      const auto file = path / component / "placeholder.bin";
      std::ofstream(file).put('\0');
      std::filesystem::resize_file(file, fileBytes);
    }
  }

  ~TemporaryModelRoot() {
    std::error_code ignored;
    std::filesystem::remove_all(path, ignored);
  }

  uint64_t fileBytes;
  uint64_t packageBytes;
  std::filesystem::path path;
};

class RuntimeResidencyProbe final : public model::RuntimeModel {
public:
  explicit RuntimeResidencyProbe(metal::MetalBackend &backend,
                                 uint64_t bytes)
      : arena_(backend.allocateBuffer(bytes)) {}

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
  std::unique_ptr<ModelBatchTicket>
  submit(const BatchPlan &, std::span<const ModelBatchItem>,
         std::function<void()>) override {
    return {};
  }
  std::shared_ptr<const CompositeState> snapshot(uint64_t) override {
    return {};
  }
  uint64_t reclaimIdleState(bool) noexcept override { return 0; }
  void provideMask(uint64_t, std::span<const uint32_t>) override {}
  void end(uint64_t) override {}
  model::WarmupStepResult warmupPrefill(uint32_t) override { return {}; }
  model::WarmupStepResult warmupDecodeBatch(uint32_t) override { return {}; }
  model::WarmupStepResult warmupDraftVerifyCommit() override { return {}; }
  model::WarmupStepResult warmupCompositeStateRestore() override { return {}; }
  model::ModelMemoryActual actualRuntimeMemory() const override { return {}; }
  model::ModelTelemetry telemetry() const noexcept override { return {}; }

private:
  metal::MetalBuffer arena_;
};

class RetainedCompositeState final : public CompositeState {
public:
  uint64_t bytes() const noexcept override { return 128; }
};

class RetainedStateStorage final : public model::StateStorage {
public:
  uint64_t actualAllocatedBytes() const noexcept override { return bytes; }
  uint64_t releaseIdle(uint32_t, uint32_t) noexcept override { return 0; }
  uint64_t bytes = 128;
};

class RetainedBacking final : public kv::Backing {
public:
  explicit RetainedBacking(uint32_t pages) : resident_(pages, true) {}
  uint32_t pageCount() const noexcept override {
    return static_cast<uint32_t>(resident_.size());
  }
  uint64_t bytesPerPage() const noexcept override { return 4096; }
  bool isResident(uint32_t page) const override { return resident_.at(page); }
  metal::AllocationResult ensureResident(uint32_t page) override {
    resident_.at(page) = true;
    return true;
  }
  bool releaseBackingForPage(uint32_t page) override {
    const bool wasResident = resident_.at(page);
    resident_.at(page) = false;
    return wasResident;
  }
  uint32_t extentFirstPage(uint32_t page) const override { return page - page % 4; }
  uint32_t extentPageCount(uint32_t page) const override {
    return std::min<uint32_t>(4, pageCount() - extentFirstPage(page));
  }

private:
  std::vector<bool> resident_;
};

RuntimeResourcesConfig budgetConfig(const char *metallibPath,
                                    const TemporaryModelRoot &root) {
  RuntimeResourcesConfig config;
  config.metallibPath = metallibPath;
  config.modelRoot = root.path;
  config.model = model::makeModelDescriptor(
      "budget-test", model::Qwen3_8Layout{}, model::DFlashDraftLayout{},
      ops::VisionLayout{});
  config.buildId = "budget-test";
  return config;
}

// Startup fails at the loader, whose weight files are deliberately absent.
// Reaching it is the assertion: everything the engine checks before opening
// the package let this configuration through.
void requireReachesModelLoader(RuntimeResourcesConfig config,
                               const std::filesystem::path &root,
                               const char *message) {
  try {
    auto resources = RuntimeResources::create(config);
    throw std::runtime_error("placeholder model unexpectedly loaded");
  } catch (const RuntimeResourcesError &error) {
    requireResourceError(
        error,
        [&](const RuntimeResourcesError &actual) {
          return actual.failure() == RuntimeResourceFailure::Other &&
                 std::string(actual.what()).find("[model_loading]") !=
                     std::string::npos &&
                 actual.message().find("unable to open") != std::string::npos &&
                 actual.message().find((root / "target").string()) !=
                     std::string::npos;
        },
        message);
  }
}

void testWeightBudgetBeforeLoading(const char *metallibPath) {
  TemporaryModelRoot root;
  RuntimeResourcesConfig config = budgetConfig(metallibPath, root);

  {
    config.memoryPressure = [] { return MemoryPressure::Critical; };
    try {
      auto resources = RuntimeResources::create(config);
      throw std::runtime_error("model load ignored system pressure");
    } catch (const RuntimeResourcesError &error) {
      requireResourceError(
          error,
          [](const RuntimeResourcesError &actual) {
            return actual.failure() == RuntimeResourceFailure::HostCapacity;
          },
          "startup pressure did not remain retryable");
      requireResourceError(
          error,
          [](const RuntimeResourcesError &actual) {
            return actual.message().find("not enough free memory") !=
                   std::string::npos;
          },
          "startup pressure reached the weight loader");
    }
  }
  config.memoryPressure = [] { return MemoryPressure::Warning; };

  // Beside its weights a model needs at least the runtime reserves, one state
  // cell and one KV extent. The low ceiling is one byte short of all that, so
  // every directory must be counted. The other ceilings must reach the real
  // loader, whose expected weight files are deliberately absent. No actual
  // model package is needed for this test.
  const kv::Layout kvLayout = config.model.targetKvLayout;
  const uint64_t minimumBytes =
      root.packageBytes + model::kPipelineReserveBytes +
      model::kRuntimeOverheadReserveBytes +
      config.model.stateLayout.activeCellBytes() +
      uint64_t{kvLayout.backingExtentPages()} * kvLayout.bytesPerModelPage();
  for (uint64_t ceiling : {minimumBytes - 1, minimumBytes, uint64_t{0}}) {
    config.maximumMemoryBytes = ceiling;
    try {
      auto resources = RuntimeResources::create(config);
      throw std::runtime_error("placeholder model unexpectedly loaded");
    } catch (const RuntimeResourcesError &error) {
      if (ceiling == minimumBytes - 1) {
        requireResourceError(
            error,
            [&](const RuntimeResourcesError &actual) {
              return actual.failure() == RuntimeResourceFailure::EngineCapacity;
            },
            "hard weight budget lost its engine-capacity classification");
        requireResourceError(
            error,
            [&](const RuntimeResourcesError &actual) {
              return std::string(actual.what()).find("[memory_planning]") !=
                         std::string::npos &&
                     actual.message().find("require " +
                                           std::to_string(minimumBytes) +
                                           " bytes") != std::string::npos &&
                     actual.message().find("budget is " +
                                           std::to_string(minimumBytes - 1) +
                                           " bytes") != std::string::npos;
            },
            "weight loading began before checking the memory ceiling");
      } else {
        requireResourceError(
            error,
            [](const RuntimeResourcesError &actual) {
              return actual.failure() == RuntimeResourceFailure::Other;
            },
            "missing model file was misclassified as allocation pressure");
      }
    }
  }
  config.maximumMemoryBytes = 0;
  requireReachesModelLoader(config, root.path,
                            "a sufficient weight budget did not reach the "
                            "model loader");
}

// A 34.5 GiB model under a 35 GiB budget: the weights alone fit, but not
// with what the runtime needs beside them. Startup refuses it before any
// weight is prepared or registered.
void testModelBeyondBudgetIsRefusedBeforeLoading(const char *metallibPath) {
  TemporaryModelRoot root(23 * kGiB / 2);
  RuntimeResourcesConfig config = budgetConfig(metallibPath, root);
  config.maximumMemoryBytes = 35 * kGiB;
  try {
    auto resources = RuntimeResources::create(config);
    throw std::runtime_error("placeholder model unexpectedly loaded");
  } catch (const RuntimeResourcesError &error) {
    requireResourceError(
        error,
        [](const RuntimeResourcesError &actual) {
          return actual.failure() == RuntimeResourceFailure::EngineCapacity &&
                 std::string(actual.what()).find("[memory_planning]") !=
                     std::string::npos;
        },
        "a model that cannot fit reached the weight loader");
  }
}

// The rule that keeps users off the startup floor: admission weighs
// reclaimable memory against the macOS reserve, never against the model.
// A package far larger than everything reclaimable still starts, because
// mapped weights become resident page by page under the operation guard.
void testStartupAdmissionIgnoresPackageSize(const char *metallibPath) {
  TemporaryModelRoot root(2 * kGiB);
  RuntimeResourcesConfig config = budgetConfig(metallibPath, root);
  require(root.packageBytes > 3 * kGiB, "the package must exceed the sample");
  config.hostAvailableMemory = [] {
    return std::optional<uint64_t>(3 * kGiB);
  };
  requireReachesModelLoader(config, root.path,
                            "a package larger than reclaimable host memory "
                            "refused to start");

  // Below the reserve macOS is the one at risk, so startup waits instead.
  // Unmeasurable telemetry waits the same way.
  for (std::optional<uint64_t> available :
       {std::optional<uint64_t>(64 * kMiB), std::optional<uint64_t>()}) {
    config.hostAvailableMemory = [available] { return available; };
    try {
      auto resources = RuntimeResources::create(config);
      throw std::runtime_error("model load ignored the macOS reserve");
    } catch (const RuntimeResourcesError &error) {
      requireResourceError(
          error,
          [](const RuntimeResourcesError &actual) {
            return actual.failure() == RuntimeResourceFailure::HostCapacity;
          },
          "exhausted host memory did not remain retryable");
      requireResourceError(
          error,
          [](const RuntimeResourcesError &actual) {
            return actual.message().find("not enough free memory") !=
                   std::string::npos;
          },
          "exhausted host memory reached the weight loader");
    }
  }
}

// The memory plan takes the vision category from what loaded, so a model
// with vision whose loader produced no vision bytes must stop here.
void testLoadedVisionIsRequiredOnlyWithVision() {
  model::ModelPackage package;
  package.descriptor = model::makeModelDescriptor(
      "loaded-test", model::Qwen3_8Layout{}, model::DFlashDraftLayout{},
      ops::VisionLayout{});
  model::Qwen3_8Weights target;
  target.actualAllocatedBytes = 1;
  target.manifestFingerprintSha256 = "target";
  package.target = std::move(target);
  package.draft.actualAllocatedBytes = 1;
  package.manifestFingerprintSha256 = "package";
  bool rejected = false;
  try {
    requireLoadedModel(package);
  } catch (const std::invalid_argument &) {
    rejected = true;
  }
  require(rejected && package.descriptor.hasVision(),
          "a multimodal model without loaded vision weights was accepted");
  package.vision.actualAllocatedBytes = 1;
  requireLoadedModel(package);
  package.vision.actualAllocatedBytes = 0;
  package.descriptor.visionSource = model::VisionSource::None;
  requireLoadedModel(package);
}

void testPackageResidencyReleasesAllWeightCategories(const char *metallibPath) {
  constexpr uint64_t probeBytes = 2 * kMiB;
  metal::MetalBackend backend(metallibPath);
  metal::MetalBuffer retainedBackendAllocation =
      backend.allocateBuffer(probeBytes);
  RetainedBacking backing(16);
  KvPool pool(backing);
  Cache cache(pool, CacheNamespace{});
  std::vector<uint32_t> retainedPrompt(65);
  for (uint32_t index = 0; index < retainedPrompt.size(); ++index)
    retainedPrompt[index] = 1000 + index;
  cache.beginRequest(73);
  require(cache.ensureTokens(73, retainedPrompt.size()).granted(),
          "retained resource fixture could not acquire cache KV");
  const uint64_t retainedBlock =
      cache.publishCommittedBlocks(73, retainedPrompt, 64);
  require(retainedBlock != 0,
          "retained resource fixture did not publish its KV boundary");
  cache.publishCompositeState(retainedBlock,
                              std::make_shared<RetainedCompositeState>());
  cache.endRequest(73);
  RetainedStateStorage stateStorage;
  auto slotFile = std::make_shared<model::SlotFile>(
      model::SlotFile::kAlignmentBytes, 4 * model::SlotFile::kAlignmentBytes);
  auto slot = slotFile->acquire();
  require(slot && slotFile->usedBytes() == model::SlotFile::kAlignmentBytes,
          "retained SlotFile did not acquire its backing slot");
  const uint64_t retainedBytes = backend.refreshMemoryStats().allocatedBytes;

  model::Qwen3_8Weights target;
  target.actualAllocatedBytes = probeBytes;
  ops::AffineWeights targetPlanes;
  targetPlanes.weights = backend.allocateBuffer(probeBytes);
  target.tokenEmbedding =
      ops::EmbeddingWeights(1, 1, std::move(targetPlanes));

  model::ModelPackage package;
  package.target = std::move(target);
  package.draft.actualAllocatedBytes = probeBytes;
  package.draft.predecessorCodebook = backend.allocateBuffer(probeBytes);
  package.vision.actualAllocatedBytes = probeBytes;
  package.vision.tensors.positionTable = backend.allocateBuffer(probeBytes);

  auto residency = std::make_unique<ModelPackageResidency>(std::move(package));
  auto bootstrapModel =
      std::make_unique<RuntimeResidencyProbe>(backend, probeBytes);
  const uint64_t resident = backend.refreshMemoryStats().allocatedBytes;
  require(resident >= retainedBytes + 4 * probeBytes &&
              residency->package().targetActualAllocatedBytes() == probeBytes &&
              residency->package().draft.actualAllocatedBytes == probeBytes &&
              residency->package().vision.actualAllocatedBytes == probeBytes,
          "package/runtime residency did not own their allocations");

  residency.reset();
  const uint64_t afterPackage = backend.refreshMemoryStats().allocatedBytes;
  require(resident - afterPackage >= 3 * probeBytes &&
              bootstrapModel != nullptr && backend.healthy(),
          "destroying package residency did not release its weight allocations");

  bootstrapModel.reset();
  const uint64_t afterRuntime = backend.refreshMemoryStats().allocatedBytes;
  require(afterPackage - afterRuntime >= probeBytes &&
              afterRuntime >= retainedBytes && backend.healthy(),
          "destroying Bootstrap-owned RuntimeModel did not release runtime residency");

  auto retainedLookup = cache.lookup(retainedPrompt);
  require(retainedLookup.kvBoundary == 64 &&
              retainedLookup.resumeBoundary() == 64 &&
              retainedLookup.state.has_value(),
          "retained matching KV/composite state did not survive residency release");
  retainedLookup.state.reset();
  const CacheSnapshot retainedCache = cache.snapshot();
  const metal::MetalMemoryStats memory = backend.refreshMemoryStats();
  ResourceSnapshot released;
  released.lifecycle = LifecycleStatusSnapshot{
      .power = LifecyclePower::Battery,
      .state = LifecycleState::Suspended,
      .revision = 22,
      .controlReady = true,
      .inferenceReady = false,
      .modelResident = false,
      .configuredContextCeiling = 1024,
  };
  released.backendAllocatedBytes =
      memory.allocatedBytes + memory.sparseResidentBytes;
  released.retainedCacheBytes = retainedCache.stateCache.bytes;
  released.retainedKvBytes = retainedCache.pool.residentBackingBytes;
  released.retainedStateBytes = stateStorage.actualAllocatedBytes();
  require(retainedCache.stateCache.entries == 1 &&
              retainedCache.pool.pagesResident == 16 &&
              retainedCache.pool.residentBackingBytes == pool.residentBackingBytes() &&
              stateStorage.actualAllocatedBytes() == 128 &&
              slotFile->usedBytes() == model::SlotFile::kAlignmentBytes &&
              slot != nullptr && retainedBackendAllocation &&
              retainedBackendAllocation.sizeBytes() == probeBytes &&
              released.backendAllocatedBytes >= retainedBytes &&
              released.backendAllocatedBytes > 0 &&
              !released.modelPackageResident &&
              !released.modelPackageResidentBytes &&
              !released.runtimeResident && !released.runtimeResidentBytes &&
              !released.modelTelemetryAvailable &&
              validResourceSnapshot(released) && backend.healthy(),
          "retained cache/state/slot/backend resources failed after residency destruction");
}

} // namespace

int main(int argc, char **argv) {
  @autoreleasepool {
    try {
      require(argc == 2, "expected metallib path");
      testLoadedVisionIsRequiredOnlyWithVision();
      testWeightBudgetBeforeLoading(argv[1]);
      testModelBeyondBudgetIsRefusedBeforeLoading(argv[1]);
      testStartupAdmissionIgnoresPackageSize(argv[1]);
      testPackageResidencyReleasesAllWeightCategories(argv[1]);
      std::cout << "runtime resources tests passed\n";
      return EXIT_SUCCESS;
    } catch (const std::exception &error) {
      std::cerr << "runtime resources tests failed: " << error.what() << '\n';
      return EXIT_FAILURE;
    }
  }
}
