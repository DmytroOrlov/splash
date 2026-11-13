#include "GgufFixtures.hpp"
#include "TestChecks.hpp"
#include "AllocationFailure.hpp"
#include "TestFiles.hpp"
#include "TestCheckpoint.hpp"
#include "TestDrafts.hpp"
#include "TestStderr.hpp"
#include "engine/Bootstrap.hpp"
#include "engine/RuntimeResources.hpp"
#include "engine/Engine.hpp"
#include "engine/MemoryPlan.hpp"
#include "model/ModelSizing.hpp"
#include "model/RuntimeArenas.hpp"
#include "model/SsdReaders.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <sys/time.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <type_traits>
#include <atomic>

// T007 proved the ownership move; T009 proved the residency owns ANE,
// ReleasableMemory and the streamed model stores, and that retained APIs and
// model-dependent reads stay absence-safe. The test-only peer never exports a
// residency beyond its retained owner's scope, and proves no physical
// suspension (T015-T025).
namespace splash::engine {
struct RuntimeResourcesTestAccess final {
  static auto retained(const RuntimeResources &r) {
    return std::array<const void *, 15>{
        r.backend_.get(), r.readers_.get(), r.memoryGovernor_.get(),
        r.kvPages_.get(), r.stateStorage_.get(), r.kvTier_.get(),
        r.diskSpace_.get(), r.kvPool_.get(), r.cache_.get(),
        r.persistentCache_.directory.get(), r.persistentCache_.kv.get(),
        r.persistentCache_.states.get(), &r.cacheIdentity_,
        r.blockCache_.get(), r.historyStream_.get()};
  }
  static model::SsdReaders &readers(RuntimeResources &r) { return *r.readers_; }
  // [T031 prerequisite] What a residency holds is read ONLY through its owner's
  // friends: the stratum's presence (its idle-weight memory) and its loaded
  // model's address, for the private-residency and adoption-gate proofs.
  static const ReleasableMemory *held(const ModelResidency &r) { return r.releasableMemory(); }
  static const model::LoadedModel &model(const ModelResidency &r) { return r.model(); }
  static auto slot(RuntimeResources &r) { return r.persistentCache_.kv->acquire(); }
  static bool onProbation(const RuntimeResources &r) { return r.probation_.joinable(); }
  template <class Inspect> static void moved(RuntimeResources &r, Inspect inspect) {
    const auto before = *r.modelContext();
    auto *beforeReleasable = r.releasableMemory();
    ModelResidency parked(std::move(r.residency_));
    try {
      test::require(!r.residency_.storage_, "the moved-from fixture still has model data");
      // Absence safety: retained APIs stay valid, model-dependent reads report
      // absence (null/Off) instead of dereferencing or faking live values.
      test::require(!r.modelResident() && !r.modelContext() &&
                        r.releasableMemory() == nullptr,
                    "the moved-from residency still exposed model or idle-weight access");
      test::require(!r.streamedExpertStats() && !r.streamedTableStats() &&
                        r.aneFfnShare() == 0.0 && r.aneFfnMinimumRows() == 0 &&
                        !r.actualMemoryReport(model::ModelMemoryActual{}),
                    "an absent residency reported live model telemetry");
      test::require(r.aneFfnSnapshot().state == AneFfnSnapshot::State::Off &&
                        r.aneFfnSnapshot().reason == r.aneFfnOutcome().reason,
                    "an absent residency fabricated an ANE snapshot");
      test::require(&parked.model() == &before.model &&
                        &parked.operators() == &before.operators &&
                        parked.aneFfn() == before.aneFfn &&
                        parked.releasableMemory() == beforeReleasable,
                    "moving residency changed a model-dependent address");
      // Only retained APIs are valid here. No absent model/idle/ANE access.
      inspect();
    } catch (...) {
      r.residency_ = std::move(parked);
      throw;
    }
    r.residency_ = std::move(parked);
  }
  static ModelResidency make(model::LoadedModel &&loaded, ops::ExecutionPlans &&plans,
                             std::unique_ptr<ops::AneFfn> &&aneFfn) {
    return ModelResidency(std::move(loaded), std::move(plans), std::move(aneFfn));
  }
};
} // namespace splash::engine

namespace {

using namespace splash;
using namespace splash::engine;

using splash::test::rejects;
using splash::test::require;

// Historical ownership/interface assertions, adapted to upstream signatures.
static_assert(std::is_same_v<decltype(RuntimeResources::create(
    std::declval<const RuntimeResourcesConfig &>(), uint32_t{})),
    std::unique_ptr<RuntimeResources>>);
static_assert(std::is_same_v<decltype(std::declval<RuntimeResources &>().backend()),
                             metal::MetalBackend &>);
static_assert(std::is_same_v<decltype(std::declval<RuntimeResources &>().cache()), Cache &>);
static_assert(!std::is_copy_constructible_v<ModelResidency>);
static_assert(!std::is_copy_assignable_v<ModelResidency>);
static_assert(std::is_nothrow_move_constructible_v<ModelResidency>);
static_assert(std::is_nothrow_move_assignable_v<ModelResidency>);

class RetainedCompositeState final : public CompositeState {
public:
  uint64_t bytes() const noexcept override { return 128; }
};

// A small model whose weights load and whose geometry the runtime plans:
// four target and two draft layers of the 2048-wide hidden state a compiled
// draft attention takes, the draft reading a GDN layer and the attention
// layer, with Qwen3.8-27B's attention and GDN heads and a two-block vision
// tower.
struct PlannedModel final {
  model::Qwen3_8Layout target;
  model::DFlashDraftLayout draft;
  ops::VisionLayout vision;
};

PlannedModel plannedModel() {
  PlannedModel result;
  model::Qwen3_8Layout &target = result.target;
  target.layers = 4;
  target.hiddenSize = 2048;
  target.vocabularySize = 1024;
  target.intermediateSize = 1024;
  constexpr std::array<uint32_t, 2> draftReads{1, 3};
  result.draft = model::draftLayout(target.hiddenSize, target.vocabularySize, 2, 1024, 10'000'000.0F, draftReads);
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

// The target and draft checkpoints of `model` under root, which weight
// planning reads; its vision tower stays absent, so loading stops there.
void writeCheckpoints(const std::filesystem::path &root, const model::ModelDescriptor &model) {
  std::visit([&](const auto &target) { test::writeSyntheticCheckpoints(root, target, model.draft); },
             model.target);
}

RuntimeResourcesConfig budgetConfig(const char *metallibPath, const std::filesystem::path &root) {
  const PlannedModel planned = plannedModel();
  RuntimeResourcesConfig config;
  config.metallibPath = metallibPath;
  config.modelRoot = root;
  config.model = model::makeModelDescriptor("budget-test", planned.target, planned.draft, planned.vision,
                                            model::TargetSource::Safetensors, model::VisionSource::Safetensors);
  config.buildId = "budget-test";
  writeCheckpoints(root, config.model);
  return config;
}

// A model under root whose weights load, which nothing but the host
// refuses: `name` names its descriptor and build.
RuntimeResourcesConfig loadableConfig(const char *metallibPath, const std::filesystem::path &root,
                                      const std::string &name) {
  const PlannedModel planned = plannedModel();
  static_cast<void>(test::writeSyntheticModel(root, planned.target, planned.draft, planned.vision));
  RuntimeResourcesConfig config;
  config.metallibPath = metallibPath;
  config.modelRoot = root;
  config.model = model::makeModelDescriptor(name, planned.target, planned.draft, planned.vision,
                                            model::TargetSource::Safetensors,
                                            model::VisionSource::Safetensors);
  config.model.sourceIdentity = "synthetic";
  config.buildId = name;
  config.hostMemory = [] { return std::optional<HostMemory>(HostMemory{64 * kGiB, 64 * kGiB}); };
  return config;
}

// A local volume of 1000 GiB with `availableBytes` free, which leaves the
// automatic SSD cache room from 12 GiB on.
DiskVolume localVolume(uint64_t availableBytes) {
  return {"/Volumes/Test", availableBytes, 1000 * kGiB, true};
}

// A volume probe that reads `volume` for every directory.
std::function<std::optional<DiskVolume>(const std::filesystem::path &)>
reading(std::optional<DiskVolume> volume) {
  return [volume](const std::filesystem::path &) { return volume; };
}

// The routed experts of each layer of the MoE model below.
constexpr uint32_t kMoeExperts = 128;
constexpr uint32_t kMoeLayers = 8;

// A MoE model under root whose weights load: the planned model's draft and
// vision tower beside kMoeLayers layers of Qwen3.6-35B-A3B's geometry, each
// with kMoeExperts routed experts, eight a token. Its experts above their
// smallest store, a layer's, take more than the arenas of its prefill groups
// and the first 64K tokens of its KV.
RuntimeResourcesConfig moeConfig(const char *metallibPath, const std::filesystem::path &root) {
  const PlannedModel planned = plannedModel();
  model::Qwen3_6MoeLayout target;
  target.layers = kMoeLayers;
  target.vocabularySize = planned.target.vocabularySize;
  target.experts = kMoeExperts;
  static_cast<void>(test::writeSyntheticModel(root, target, planned.draft, planned.vision));
  RuntimeResourcesConfig config;
  config.metallibPath = metallibPath;
  config.modelRoot = root;
  config.model = model::makeModelDescriptor("moe-test", target, planned.draft, planned.vision,
                                            model::TargetSource::Safetensors, model::VisionSource::Safetensors);
  config.model.sourceIdentity = "synthetic";
  config.buildId = "moe-test";
  config.hostMemory = [] { return std::optional<HostMemory>(HostMemory{64 * kGiB, 64 * kGiB}); };
  return config;
}

// A Qwen3.8-Flash-Next model under root whose weights load, a block-sparse
// target whose KV spills: a GGUF of its family's tensors
// (gguf_fixtures::targetTensors) with its attention, GDN, indexer and PLE
// heads but a hidden state of 256 values, a vocabulary of 256 tokens, eight
// layers, every second one full attention, and four routed experts a layer,
// and a draft of one layer that reads four of them; no vision tower.
RuntimeResourcesConfig flashNextConfig(const char *metallibPath, const std::filesystem::path &root) {
  model::Qwen4ExpLayout target;
  target.layers = 8;
  target.hiddenSize = 256;
  target.vocabularySize = 256;
  target.fullAttentionPeriod = 2;
  target.maskToken = 252;
  target.stopTokens = {250, 251};
  target.pleEosToken = 250;
  target.pleImageToken = 253;
  target.experts = 4;
  target.expertsPerToken = 2;
  target.expertIntermediateSize = 256;
  target.pleLayer = 0;
  gguf_fixtures::TensorTypes types = gguf_fixtures::qwen4ExpTypes();
  for (const char *name : {"hc_attn_down.weight", "hc_attn_up.weight", "hc_ffn_down.weight", "hc_ffn_up.weight",
                           "output_hc_down.weight", "output_hc_up.weight", "ffn_gate_exps.weight",
                           "ffn_up_exps.weight", "ffn_down_exps.weight", "ffn_gate_shexp.weight",
                           "ffn_up_shexp.weight", "ffn_down_shexp.weight"})
    types[name] = gguf_fixtures::kQ8_0;
  // The PLE hash, its heads an equal share of the table's rows each.
  std::vector<test::gguf::Key> keys = gguf_fixtures::metadata(target);
  const std::string ple = std::string(model::Qwen4ExpLayout::ggufArchitecture) + ".ple.";
  const uint32_t heads = target.pleHeads(), headRows = gguf_fixtures::kPleTableRows / heads;
  std::vector<int32_t> offsets, rows(heads, int32_t(headRows));
  for (uint32_t head = 0; head < heads; ++head)
    offsets.push_back(int32_t(head * headRows));
  keys.push_back(test::gguf::int32ArrayKey(ple + "layer_multipliers", {1, 31, 961}));
  keys.push_back(test::gguf::int32ArrayKey(ple + "head_offsets", offsets));
  keys.push_back(test::gguf::int32ArrayKey(ple + "head_vocab_sizes", rows));
  keys.push_back(test::gguf::uint32Key(ple + "eos_token_id", target.pleEosToken));
  std::filesystem::create_directories(root / "target");
  test::writeFile(root / "target" / "model.gguf",
                  test::gguf::file(keys, gguf_fixtures::targetTensors(target, types)));
  constexpr std::array<uint32_t, 4> draftReads{1, 3, 5, 7};
  const model::DFlashDraftLayout draft =
      model::draftLayout(target.hiddenSize, target.vocabularySize, 1, 512, 1'000'000.0F, draftReads);
  test::writeSyntheticShard(root / "draft" / "model.safetensors", test::draftTensors(draft));
  RuntimeResourcesConfig config;
  config.metallibPath = metallibPath;
  config.modelRoot = root;
  config.model = model::makeModelDescriptor("flash-next-test", target, draft,
                                            {.outputHiddenSize = target.hiddenSize}, model::TargetSource::Gguf,
                                            model::VisionSource::None);
  config.model.sourceIdentity = "synthetic";
  config.buildId = "flash-next-test";
  config.hostMemory = [] { return std::optional<HostMemory>(HostMemory{64 * kGiB, 64 * kGiB}); };
  return config;
}

// What a start sized: its context, the least memory its plan needs and its
// arenas, its routed experts' store, whether its SSD cache started, its
// backend's memory, its log and how many times it loaded the weights.
struct StreamedStart final {
  uint32_t context = 0;
  uint64_t minimumRequired = 0, arenaBytes = 0;
  std::optional<model::ExpertStoreStats> experts;
  bool tier = false;
  metal::MetalMemoryStats memory;
  std::string log;
  size_t loads = 0;
};

StreamedStart startStreamed(const RuntimeResourcesConfig &config) {
  StreamedStart started;
  started.log = test::capturedStderr([&] {
    auto resources = RuntimeResources::create(config, 0);
    const EngineMemoryBreakdown &budget = resources->memoryPlan().breakdown();
    started.context = resources->memoryPlan().maximumContextTokens();
    started.minimumRequired = budget.minimumRequiredBytes;
    started.arenaBytes = budget.sharedPrefillBytes + budget.sharedDecodeBytes;
    started.experts = resources->streamedExpertStats();
    started.tier = resources->cache().snapshot().kvTier.capacityBytes != 0;
    started.memory = resources->backend().refreshMemoryStats();
  });
  for (size_t at = started.log.find("Weights loaded"); at != std::string::npos;
       at = started.log.find("Weights loaded", at + 1))
    ++started.loads;
  return started;
}

// The sizes a model's weights take, planned from its files before it loads,
// are what it loads: the images without its routed experts and those with
// all of them, and the smallest store, which holds a layer's experts and
// refuses a byte less. One load plans the arenas of either: those of streamed
// experts planned from a model that loads them whole are a streaming model's,
// and the reverse.
void testStreamableWeightsAreWhatLoads(const RuntimeResourcesConfig &config) {
  const std::filesystem::path &root = config.modelRoot;
  const model::StreamableWeights weights =
      model::streamableWeights(root, config.model, {.streamExperts = true, .streamTable = true});
  require(weights.expertBytes > weights.expertMinimumBytes && weights.expertMinimumBytes && !weights.tableBytes &&
              !weights.tableMinimumBytes && !weights.tableRowBytes && weights.tableRefusal.empty(),
          "the streamable weights of a MoE without a table are not its experts'");
  const auto allocated = [](const model::LoadedModel &loaded) {
    return loaded.targetActualAllocatedBytes() + loaded.draft.actualAllocatedBytes +
           loaded.vision.actualAllocatedBytes;
  };
  metal::MetalBackend backend(config.metallibPath.string());
  const ops::ExecutionPlans operators(backend.capabilities());
  const auto arenas = [&](const model::LoadedModel &loaded, model::StreamedParts parts) {
    const model::ModelMemoryPlan plan =
        model::plannedRuntimeMemory(loaded, operators, kv::Format::Int8, ops::GdnStateFormat::Float32, parts);
    return plan.sharedPrefillPlannedAllocatedBytes + plan.sharedDecodePlannedAllocatedBytes;
  };
  const model::LoadedModel whole = model::loadModel(backend, root, config.model);
  require(allocated(whole) == weights.loadedBytes + weights.expertBytes,
          "the experts loaded with their layers did not take what was planned");
  // Streamed experts read on a pool of SSD readers, as the engine's do.
  const auto readers = std::make_shared<model::SsdReaders>(model::kSsdReaders);
  const model::LoadedModel streamed = model::loadModel(
      backend, root, config.model, {.expertMemoryBytes = weights.expertMinimumBytes, .readers = readers});
  require(streamed.expertStore() && streamed.expertStore()->stats().slots == kMoeExperts &&
              allocated(streamed) <= weights.loadedBytes + weights.expertMinimumBytes,
          "the smallest store did not hold a layer's experts within its bytes");
  require(arenas(whole, {.experts = true}) == arenas(streamed, model::StreamedParts::loaded(streamed)) &&
              arenas(streamed, {}) == arenas(whole, model::StreamedParts::loaded(whole)) &&
              arenas(whole, {.experts = true}) > arenas(whole, {}),
          "the arenas of what streams are not those of a model loaded so, or prefill groups took no more");
  const auto sharedBefore = readers.use_count();
  {
    auto residency = RuntimeResourcesTestAccess::make(
        model::loadModel(backend, root, config.model,
                         {.expertMemoryBytes = weights.expertMinimumBytes, .readers = readers}),
        ops::ExecutionPlans(backend.capabilities()), std::unique_ptr<ops::AneFfn>{});
    require(readers.use_count() > sharedBefore,
            "the streamed residency did not borrow the shared reader pool");
    auto moved = std::move(residency);
  }
  require(readers.use_count() == sharedBefore,
          "destroying streamed residency kept an unexpected reader-pool share");
  std::atomic<size_t> reads{0};
  readers->run(8, [&](size_t) { ++reads; });
  require(reads == 8, "shared KV/spill readers stopped with the model streams");
  rejects([&] {
    static_cast<void>(
        model::loadModel(backend, root, config.model,
                         {.expertMemoryBytes = weights.expertMinimumBytes - 1, .readers = readers}));
  }, "holds fewer slots", "a store a byte below the smallest loaded");
}

// --expert-memory auto loads a MoE target's routed experts where the plan
// holds them, in one load as main does. Where it does not, they stream
// through a store of all that the first 64K tokens of KV leave, in two
// loads: the first plans the arenas of either, and the second loads that
// store; the backend's peaks, which the memory audit holds to the plan,
// count only the second. The automatic SSD cache gives its state staging up
// where it alone would stream them. Off loads them whatever the budget, a
// budget without room for their arenas stops the start with its breakdown,
// a size loads them whole where the plan holds them, as auto does, and
// otherwise streams them through the store auto would, whose floor is that
// size, in two loads, and a size below the smallest store is refused by name
// before anything loads.
void testAutomaticExpertMemory(RuntimeResourcesConfig config) {
  const model::StreamableWeights weights =
      model::streamableWeights(config.modelRoot, config.model, {.streamExperts = true});
  const StreamedStart whole = startStreamed(config);
  require(!whole.experts && whole.loads == 1 &&
              whole.log.find("Routed experts load with their layers") != std::string::npos,
          "routed experts memory holds did not load with their layers in one load");
  const auto streams = [&](const StreamedStart &start, const char *message) {
    require(start.experts && start.experts->slots > kMoeExperts &&
                start.experts->slots < kMoeLayers * kMoeExperts && start.loads == 2 &&
                start.log.find("--expert-memory auto leaves it beside the floors") != std::string::npos &&
                start.context >= 65'536,
            message);
  };
  // A byte short of the budget that holds every expert, which the plan
  // without the arenas holds: whole, then through the store. The first
  // load's experts do not count toward the peaks.
  config.maximumMemoryBytes = whole.minimumRequired - 1;
  const StreamedStart reloaded = startStreamed(config);
  streams(reloaded,
          "experts that fit beside everything but the arenas did not stream through the store the plan sizes");
  const uint64_t firstLoad = weights.loadedBytes + weights.expertBytes;
  require(reloaded.memory.peakAllocatedBytes < firstLoad && reloaded.memory.devicePeakAllocatedBytes < firstLoad,
          "the backend's peaks counted the load the start discarded");
  // Short of that too: at the floor, then through the store.
  config.maximumMemoryBytes = whole.minimumRequired - whole.arenaBytes - 1;
  streams(startStreamed(config),
          "routed experts memory cannot hold did not stream through the store the plan sizes");

  // A byte short of every expert beside the automatic SSD cache's staging:
  // the cache gives it up, and they load whole in one load.
  config.cacheDisk = {.automatic = true};
  config.diskVolume = reading(localVolume(500 * kGiB));
  config.maximumMemoryBytes = whole.minimumRequired + config.model.stateLayout.cachedBytes() - 1;
  const StreamedStart yielded = startStreamed(config);
  require(!yielded.experts && !yielded.tier && yielded.loads == 1 &&
              yielded.log.find("SSD cache off: its " + std::to_string(config.model.stateLayout.cachedBytes() >> 20) +
                               " MiB of state staging would stream the routed experts") != std::string::npos,
          "the automatic SSD cache's staging streamed experts that load whole without it");
  config.maximumMemoryBytes += 1;
  const StreamedStart kept = startStreamed(config);
  require(!kept.experts && kept.tier && kept.loads == 1, "the automatic SSD cache yielded room it had");
  config.cacheDisk = {};
  config.diskVolume = RuntimeResourcesConfig{}.diskVolume;

  config.expertMemory = {StreamedSetting::Mode::Off, 0};
  config.maximumMemoryBytes = 0;
  require(!startStreamed(config).experts, "--expert-memory off streamed the experts");
  // A budget that holds the weights but not their arenas: the start loads
  // them, and stops with the engine plan's breakdown.
  config.maximumMemoryBytes = whole.minimumRequired - whole.arenaBytes / 2;
  try {
    static_cast<void>(RuntimeResources::create(config, 0));
    throw std::runtime_error("a plan without room for its arenas started");
  } catch (const RuntimeResourcesError &error) {
    require(error.stage() == RuntimeResourceStage::MemoryPlanning &&
                error.budgetDescription().find("deficit: " + std::to_string(whole.arenaBytes / 2) + " bytes") !=
                    std::string::npos,
            "a start without room for its arenas was refused without its breakdown");
  }
  config.maximumMemoryBytes = 0;
  config.expertMemory = {StreamedSetting::Mode::Size, weights.expertMinimumBytes};
  const StreamedStart sizedWhole = startStreamed(config);
  require(!sizedWhole.experts && sizedWhole.loads == 1 &&
              sizedWhole.log.find("--expert-memory ignored: memory holds every routed expert") != std::string::npos,
          "an explicit size streamed the experts memory holds whole");
  config.maximumMemoryBytes = whole.minimumRequired - 1;
  const StreamedStart floor = startStreamed(config);
  require(floor.experts && floor.experts->slots > kMoeExperts && floor.loads == 2 &&
              floor.experts->floorBytes < floor.experts->capBytes && floor.experts->chunks > 1 &&
              floor.log.find("gives chunks back down to its floor, the " +
                             std::to_string(weights.expertMinimumBytes >> 20) + " MiB --expert-memory sets") !=
                  std::string::npos,
          "an explicit size did not stream the experts memory cannot hold through the store auto would above "
          "that floor, loaded at the floor first");
  config.maximumMemoryBytes = 0;
  config.expertMemory = {StreamedSetting::Mode::Size, weights.expertMinimumBytes - 1};
  try {
    static_cast<void>(RuntimeResources::create(config, 0));
    throw std::runtime_error("a size below the smallest store was accepted");
  } catch (const RuntimeResourcesError &error) {
    require(error.stage() == RuntimeResourceStage::Configuration &&
                std::string_view(error.what()).find("is less than its smallest store") != std::string_view::npos,
            "a size below the smallest store was not refused by name before loading");
  }
}

// --verify-rows: by default a MoE target's decode cycles verify the rows the
// verify budget chooses, whether its routed experts load with their layers or
// stream from the SSD, and a dense target's every row; `all` verifies every
// row. The start says which, and the runtime built on what it assembled runs
// it.
void testVerifyRows(const char *metallibPath, RuntimeResourcesConfig moe) {
  struct Started final {
    std::string log;
    bool budget = false;
  };
  const auto start = [](const RuntimeResourcesConfig &config) {
    Started started;
    started.log = test::capturedStderr([&] {
      const auto resources = RuntimeResources::create(config, 0);
      const EngineMemoryBreakdown &budget = resources->memoryPlan().breakdown();
      std::unique_ptr<model::RuntimeModel> runtime;
      require(static_cast<bool>(resources->memoryGovernor().allocationAdmission()(
                  budget.sharedPrefillBytes + budget.sharedDecodeBytes,
                  [&] { runtime = model::createRuntime(*resources->modelContext()); })),
              "a runtime's arenas were refused");
      started.budget = runtime->telemetry().verifyBudget;
    });
    return started;
  };
  const auto requireStart = [&](const RuntimeResourcesConfig &config, std::string_view line, bool budget,
                                const char *message) {
    const Started started = start(config);
    require(started.log.find(line) != std::string::npos && started.budget == budget, message);
  };
  const std::string_view budgeted = "Decode cycles verify the rows the verify budget chooses (--verify-rows auto, as "
                                    "moe-test is a MoE target): greedy and seeded outputs can differ from run to run.";
  requireStart(moe, budgeted, true, "a MoE target with resident experts did not budget its rows");
  // A budget a byte short of the one that holds every expert streams them.
  moe.maximumMemoryBytes = startStreamed(moe).minimumRequired - 1;
  moe.expertMemory = {StreamedSetting::Mode::Size,
                      model::streamableWeights(moe.modelRoot, moe.model, {.streamExperts = true}).expertMinimumBytes};
  requireStart(moe, budgeted, true, "a MoE target whose experts stream did not budget its rows");
  moe.verifyRows = model::VerifyRows::All;
  requireStart(moe, "Decode cycles verify every row of the draft's block (--verify-rows all).", false,
               "--verify-rows all did not verify every row of a MoE target");
  const test::TemporaryDirectory root("splash-verify-rows");
  requireStart(loadableConfig(metallibPath, root.path(), "verify-rows-test"),
               "Decode cycles verify every row of the draft's block (--verify-rows auto, as verify-rows-test is "
               "dense).",
               false, "a dense target did not verify every row");
}

// Startup fails at the loader, whose vision weight files are deliberately
// absent. Reaching it is the assertion: everything the engine checks before
// loading the weights let this configuration through.
void requireReachesModelLoader(RuntimeResourcesConfig config,
                               const std::filesystem::path &root,
                               const char *message) {
  try {
    auto resources = RuntimeResources::create(config, 0);
    throw std::runtime_error("a model without weights unexpectedly loaded");
  } catch (const RuntimeResourcesError &error) {
    const std::string_view text = error.what();
    require(error.failure() == RuntimeResourceFailure::Other &&
                error.stage() == RuntimeResourceStage::ModelLoading &&
                text.find(root.string()) != std::string_view::npos,
            message);
  }
}

// Beside its weights a model needs at least the runtime reserves, one lane's
// state and the KV runway.
uint64_t minimumBytes(const RuntimeResourcesConfig &config) {
  return minimumRequiredBytes(model::streamableWeights(config.modelRoot, config.model, {}).loadedBytes +
                                  model::kPipelineReserveBytes + model::kRuntimeOverheadReserveBytes,
                              config.model.stateLayout.laneBytes(),
                              config.model.targetKvLayout)
      .value();
}

// A persistent cache's directory is named for what its copies hold: the same
// models and layouts name the same one under any build, and a change to any
// of them, or to the RoPE scaling its keys went through, names another.
void testPersistentCacheNamespace() {
  const model::ModelDescriptor model = model::makeModelDescriptor(
      "namespace-test", model::Qwen3_8Layout{}, test::qwen3_8Draft(),
      test::qwen3_8Vision(), model::TargetSource::Safetensors,
      model::VisionSource::Safetensors);
  const auto identity = [&](char models, std::string_view build, kv::Format format) {
    kv::Layout layout = model.targetKvLayout;
    layout.format = format;
    return makeRuntimeCacheIdentity(std::string(64, models), std::string(64, 'b'), build,
                                    layout, {});
  };
  const std::string name =
      persistentCacheNamespace(identity('a', "build", kv::Format::Int8), model.stateLayout);
  require(name.size() == 32 && name.find_first_not_of("0123456789abcdef") == std::string::npos,
          "a cache namespace is not 32 lowercase hex digits");
  require(persistentCacheNamespace(identity('a', "another build", kv::Format::Int8),
                                   model.stateLayout) == name,
          "the build changed the cache namespace");
  model::CompositeStateLayout states = model.stateLayout, bfloatStates = model.stateLayout;
  ++states.draft.layers;
  bfloatStates.target.format = ops::GdnStateFormat::BFloat16;
  require(persistentCacheNamespace(identity('c', "build", kv::Format::Int8), model.stateLayout) !=
                  name &&
              persistentCacheNamespace(identity('a', "build", kv::Format::BFloat16),
                                       model.stateLayout) != name &&
              persistentCacheNamespace(identity('a', "build", kv::Format::Int8), states) != name &&
              persistentCacheNamespace(identity('a', "build", kv::Format::Int8), bfloatStates) != name,
          "other models, layouts or state formats shared a cache namespace");
  // A dense layout's namespace is the one main (be3b083c) names, with FP32
  // and BF16 states: a change of its lines would leave every 27B's and 35B's
  // persistent cache cold.
  require(name == "6365d687c8be103a3bbcc6d2a83b1543" &&
              persistentCacheNamespace(identity('a', "build", kv::Format::Int8), bfloatStates) ==
                  "172879058b5e2bcc713e129a2b62393a",
          "a dense layout's cache namespace is not the one main names");
  // A QSA layout's pages hold token-major values and the index's pooled
  // keys, and its states the PLE history and the index's pending keys.
  RuntimeCacheIdentity tokenMajor = identity('a', "build", kv::Format::Int8), indexed = tokenMajor;
  tokenMajor.kvLayout.valuesTokenMajor = true;
  indexed.kvLayout.indexDimension = 128;
  model::CompositeStateLayout auxiliary = model.stateLayout;
  auxiliary.target.auxiliaryBytes = 9216;
  require(persistentCacheNamespace(tokenMajor, model.stateLayout) != name &&
              persistentCacheNamespace(indexed, model.stateLayout) != name &&
              persistentCacheNamespace(identity('a', "build", kv::Format::Int8), auxiliary) != name,
          "token-major values, an index or auxiliary state shared a dense layout's cache namespace");
  const auto scaled = [&](double factor) {
    kv::Layout layout = model.targetKvLayout;
    layout.format = kv::Format::Int8;
    return persistentCacheNamespace(makeRuntimeCacheIdentity(std::string(64, 'a'), std::string(64, 'b'), "build",
                                                             layout, {factor, 262144}),
                                    model.stateLayout);
  };
  require(scaled(1.0) == name && scaled(4.0) != name && scaled(2.0) != name && scaled(2.0) != scaled(4.0),
          "YaRN's keys shared a cache namespace with another scaling's");
  // Factors that print alike to six digits still rotate keys differently.
  require(scaled(3.9999999) != scaled(4.0) && scaled(1.0000001) != scaled(1.0000004),
          "factors alike to six digits shared a cache namespace");
  // A target without GDN layers stores nothing in the state format.
  const RuntimeCacheIdentity dense = identity('a', "build", kv::Format::Int8);
  model::CompositeStateLayout attentionOnly{{}, model.stateLayout.draft}, bfloatAttentionOnly = attentionOnly;
  bfloatAttentionOnly.target.format = ops::GdnStateFormat::BFloat16;
  require(persistentCacheNamespace(dense, attentionOnly) != name &&
              persistentCacheNamespace(dense, attentionOnly) == persistentCacheNamespace(dense, bfloatAttentionOnly),
          "a target without GDN layers shared a hybrid's namespace, or took another for its state format");
  // A sliding window orders a page's regions and labels its slots with their
  // page's form: each window and each set of windowed layers names a cache of
  // its own.
  RuntimeCacheIdentity windowed = dense, otherWindow = dense, otherLayers = dense;
  windowed.kvLayout.windowTokens = otherLayers.kvLayout.windowTokens = 512;
  otherWindow.kvLayout.windowTokens = 1024;
  windowed.kvLayout.windowedLayers = otherWindow.kvLayout.windowedLayers = 0b1100;
  otherLayers.kvLayout.windowedLayers = 0b0110;
  const std::string windowName = persistentCacheNamespace(windowed, model.stateLayout);
  require(windowName != name && persistentCacheNamespace(otherWindow, model.stateLayout) != windowName &&
              persistentCacheNamespace(otherLayers, model.stateLayout) != windowName,
          "a window, or another window or windowed layers, shared a cache namespace");
}

void testWeightBudgetBeforeLoading(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-budget");
  RuntimeResourcesConfig config = budgetConfig(metallibPath, root.path());

  {
    config.memoryPressure = [] { return MemoryPressure::Critical; };
    try {
      auto resources = RuntimeResources::create(config, 0);
      throw std::runtime_error("model load ignored system pressure");
    } catch (const RuntimeResourcesError &error) {
      require(error.failure() == RuntimeResourceFailure::HostCapacity,
              "startup pressure did not remain retryable");
      require(std::string_view(error.what()).find("not enough free memory") !=
                  std::string_view::npos,
              "startup pressure reached the weight loader");
    }
  }
  config.memoryPressure = [] { return MemoryPressure::Warning; };

  // The low ceiling is one byte short of the minimum, so admission must
  // charge the weights and all a model needs beside them. The other ceilings
  // must reach the real loader, whose expected weight files are deliberately
  // absent.
  const uint64_t minimum = minimumBytes(config);
  for (uint64_t ceiling : {minimum - 1, minimum, uint64_t{0}}) {
    config.maximumMemoryBytes = ceiling;
    try {
      auto resources = RuntimeResources::create(config, 0);
      throw std::runtime_error("a model without weights unexpectedly loaded");
    } catch (const RuntimeResourcesError &error) {
      if (ceiling == minimum - 1) {
        require(error.failure() == RuntimeResourceFailure::EngineCapacity,
                "hard weight budget lost its engine-capacity classification");
        const std::string_view text = error.what();
        require(error.stage() == RuntimeResourceStage::MemoryPlanning &&
                    text.find("require " + std::to_string(minimum) + " bytes") !=
                        std::string_view::npos &&
                    text.find("budget is " + std::to_string(minimum - 1) +
                              " bytes") != std::string_view::npos,
                "weight loading began before checking the memory ceiling");
      } else {
        require(error.failure() == RuntimeResourceFailure::Other,
                "missing model file was misclassified as allocation pressure");
      }
    }
  }
  config.maximumMemoryBytes = 0;
  requireReachesModelLoader(config, root.path(),
                            "a sufficient weight budget did not reach the "
                            "model loader");
}

// A state's write to the disk tier stages through a state-sized buffer the
// plan sets aside only when the tier starts: a quota that holds no state
// leaves the tier off and the budget to KV. An explicit quota's staging is
// planned whatever it costs, and the automatic one never costs a start. The
// notices and the refusal name the tier as users know it, the SSD cache.
void testStateStagingNeedsAStartedTier(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-budget");
  RuntimeResourcesConfig config = budgetConfig(metallibPath, root.path());
  const uint64_t minimum = minimumBytes(config);
  const uint64_t stateBytes = config.model.stateLayout.cachedBytes();
  config.maximumMemoryBytes = minimum;
  config.cacheDisk = {.bytes = stateBytes - 1};
  const std::string notice = test::capturedStderr([&] {
    requireReachesModelLoader(config, root.path(),
                              "a quota that holds no state set staging aside");
  });
  require(notice.find("SSD cache off: its quota holds no state of " +
                      std::to_string(stateBytes >> 20) + " MiB") != std::string::npos,
          "the notice of a quota that holds no state did not name the SSD cache");

  // The automatic tier lets a budget with no room for its staging start,
  // and says why it is off.
  config.cacheDisk = {.automatic = true};
  const std::string automatic = test::capturedStderr([&] {
    requireReachesModelLoader(config, root.path(),
                              "the automatic tier's staging refused a start");
  });
  require(automatic.find("SSD cache off: the memory budget has no room for its " +
                         std::to_string(stateBytes >> 20) +
                         " MiB of state staging beside the model") != std::string::npos,
          "the automatic tier did not say the memory budget turned it off");

  config.cacheDisk = {.bytes = stateBytes};
  try {
    auto resources = RuntimeResources::create(config, 0);
    throw std::runtime_error("a model without weights unexpectedly loaded");
  } catch (const RuntimeResourcesError &error) {
    require(error.failure() == RuntimeResourceFailure::EngineCapacity &&
                error.stage() == RuntimeResourceStage::MemoryPlanning &&
                std::string_view(error.what())
                        .find("SSD cache state staging require " +
                              std::to_string(minimum + stateBytes) +
                              " bytes") != std::string_view::npos,
            "a started tier's staging was not counted by name before loading");
  }
  config.maximumMemoryBytes = minimum + stateBytes;
  requireReachesModelLoader(config, root.path(),
                            "a budget with room for the staging did not "
                            "reach the model loader");
}

// The image patch limit is a positive multiple of four up to the
// protocol's per-image ceiling; anything else is refused before the backend
// is created.
void testImagePatchCapIsBounded(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-budget");
  RuntimeResourcesConfig config = budgetConfig(metallibPath, root.path());
  for (const uint32_t patches : {ops::kMaximumImagePatches + 4, 6U}) {
    config.maximumImagePatches = patches;
    try {
      auto resources = RuntimeResources::create(config, 0);
      throw std::runtime_error("an image patch cap outside the protocol's was accepted");
    } catch (const RuntimeResourcesError &error) {
      require(error.stage() == RuntimeResourceStage::Configuration,
              "an invalid image patch cap was not a configuration error");
    }
  }
  config.maximumImagePatches = 4096;
  requireReachesModelLoader(config, root.path(),
                            "a smaller image patch cap did not reach the model loader");
}

// Startup and the governor sample host memory through the config's probe,
// and the automatic SSD cache its volume through another: without either,
// the config is refused before the backend is created.
void testHostMemoryProbeIsRequired(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-budget");
  for (const bool memory : {true, false}) {
    RuntimeResourcesConfig config = budgetConfig(metallibPath, root.path());
    if (memory)
      config.hostMemory = {};
    else
      config.diskVolume = {};
    try {
      auto resources = RuntimeResources::create(config, 0);
      throw std::runtime_error("resources were assembled without a host memory or volume probe");
    } catch (const RuntimeResourcesError &error) {
      require(error.stage() == RuntimeResourceStage::Configuration,
              memory ? "a missing host memory probe was not a configuration error"
                     : "a missing volume probe was not a configuration error");
    }
  }
}

// The 27B under a budget half a GiB above its weights: the weights alone fit,
// but not with what the runtime needs beside them. Startup refuses it before
// any weight is loaded.
void testModelBeyondBudgetIsRefusedBeforeLoading(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-budget");
  RuntimeResourcesConfig config = budgetConfig(metallibPath, root.path());
  config.model = model::makeModelDescriptor("budget-test", model::Qwen3_8Layout{}, test::qwen3_8Draft(),
                                            test::qwen3_8Vision(), model::TargetSource::Safetensors,
                                            model::VisionSource::Safetensors);
  writeCheckpoints(root.path(), config.model);
  config.maximumMemoryBytes = model::streamableWeights(root.path(), config.model, {}).loadedBytes + kGiB / 2;
  try {
    auto resources = RuntimeResources::create(config, 0);
    throw std::runtime_error("a model that cannot fit unexpectedly loaded");
  } catch (const RuntimeResourcesError &error) {
    require(error.failure() == RuntimeResourceFailure::EngineCapacity &&
                error.stage() == RuntimeResourceStage::MemoryPlanning,
            "a model that cannot fit reached the weight loader");
  }
}

// The rule that keeps users off the startup floor: admission weighs
// reclaimable memory against the macOS reserve, never against the model.
// A model far larger than everything reclaimable still starts, because the
// operation guard checks each image's allocation as loading builds the
// residency up. A quarter of the 27B's layers keeps it within the automatic
// budget of a 24 GB Mac.
void testStartupAdmissionIgnoresModelSize(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-budget");
  RuntimeResourcesConfig config = budgetConfig(metallibPath, root.path());
  model::Qwen3_8Layout target;
  target.layers = 16;
  model::DFlashDraftLayout draft = test::qwen3_8Draft();
  draft.targetLayers = {1, 4, 7, 10, 13};
  config.model = model::makeModelDescriptor("budget-test", target, draft, test::qwen3_8Vision(),
                                            model::TargetSource::Safetensors, model::VisionSource::Safetensors);
  writeCheckpoints(root.path(), config.model);
  require(model::streamableWeights(root.path(), config.model, {}).loadedBytes > 3 * kGiB,
          "the model must exceed the sample");
  config.hostMemory = [] { return std::optional<HostMemory>(HostMemory{3 * kGiB, 3 * kGiB}); };
  requireReachesModelLoader(config, root.path(),
                            "a model larger than reclaimable host memory "
                            "refused to start");

  // Below the reserve macOS is the one at risk, so startup waits instead.
  // Unmeasurable telemetry waits the same way.
  for (std::optional<uint64_t> available :
       {std::optional<uint64_t>(64 * kMiB), std::optional<uint64_t>()}) {
    config.hostMemory = [available] {
      return available ? std::optional<HostMemory>(HostMemory{*available, *available}) : std::nullopt;
    };
    try {
      auto resources = RuntimeResources::create(config, 0);
      throw std::runtime_error("model load ignored the macOS reserve");
    } catch (const RuntimeResourcesError &error) {
      require(error.failure() == RuntimeResourceFailure::HostCapacity,
              "exhausted host memory did not remain retryable");
      require(std::string_view(error.what()).find("not enough free memory") !=
                  std::string_view::npos,
              "exhausted host memory reached the weight loader");
    }
  }
}

// The memory plan takes the vision category from what loaded, so a model
// with vision whose loader produced no vision bytes must stop here.
void testLoadedVisionIsRequiredOnlyWithVision() {
  model::LoadedModel loaded;
  loaded.descriptor = model::makeModelDescriptor(
      "loaded-test", model::Qwen3_8Layout{}, test::qwen3_8Draft(),
      test::qwen3_8Vision(), model::TargetSource::Safetensors,
      model::VisionSource::Safetensors);
  model::Qwen3_8Weights target;
  target.actualAllocatedBytes = 1;
  target.manifestFingerprintSha256 = "target";
  loaded.target = std::move(target);
  loaded.draft.actualAllocatedBytes = 1;
  loaded.manifestFingerprintSha256 = "model";
  require(loaded.descriptor.hasVision(), "the test model has no vision");
  rejects([&] { requireLoadedModel(loaded); },
          "loaded model has incomplete allocation accounting",
          "a multimodal model without loaded vision weights was accepted");
  loaded.vision.actualAllocatedBytes = 1;
  requireLoadedModel(loaded);
  loaded.vision.actualAllocatedBytes = 0;
  loaded.descriptor.visionSource = model::VisionSource::None;
  requireLoadedModel(loaded);
}

// Resource assembly names the step it fails at, at its real throw site: a
// host with less than its reserve refuses the start before the weights are
// opened, and the startup retry window retries it. Past the weights the host
// refuses only what loading would (testStartGrowsThroughHostPressure).
void testFailedStepIsNamed(const char *metallibPath) {
  using namespace std::chrono_literals;
  const test::TemporaryDirectory root("splash-assembly");
  RuntimeResourcesConfig config = loadableConfig(metallibPath, root.path(), "assembly-test");
  const auto host = [&](uint64_t available) {
    config.hostMemory = [available] { return std::optional<HostMemory>(HostMemory{available, available}); };
  };
  // Nothing but the host refuses this model. The suite's one complete start
  // also reports the SSD cache a disk quota gives it, by that name: a size of
  // its temporary files' whole volume, which the room the volume has beyond
  // its floor always limits, as that room.
  host(64 * kGiB);
  const std::optional<DiskVolume> temporary = volumeOf(std::filesystem::temp_directory_path());
  require(temporary && temporary->local, "the temporary files' volume is not a local volume measured");
  config.cacheDisk = {.bytes = temporary->sizeBytes};
  const std::string started =
      test::capturedStderr([&] { static_cast<void>(RuntimeResources::create(config, 0)); });
  const size_t at = started.find("SSD cache: up to ");
  const std::string line =
      at == std::string::npos ? std::string() : started.substr(at, started.find('\n', at) - at);
  require(line.find(" of temporary files in ") != std::string::npos &&
              line.find(" (the ") != std::string::npos &&
              line.find(" its volume has beyond the ") != std::string::npos &&
              line.find("; KV pages of ") != std::string::npos &&
              line.find("--max-cache-disk 0 turns it off.") != std::string::npos,
          "a start did not report its SSD cache by that name, or a size its volume limits as the "
          "volume's room");
  config.cacheDisk = {};
  const auto failure = [&](uint64_t available) {
    host(available);
    try {
      static_cast<void>(RuntimeResources::create(config, 0));
    } catch (const RuntimeResourcesError &error) {
      return RuntimeBootstrapError(error).report();
    }
    throw std::runtime_error("resources were assembled on a host short of memory");
  };
  const uint64_t reserve = EngineMemoryPolicy::hostAvailableReserveBytes(
      metal::probeDeviceCapabilities().physicalMemoryBytes);
  const RuntimeBootstrapReport before = failure(reserve / 2);
  require(before.resourceStage == RuntimeResourceStage::ModelLoading &&
              before.resourceFailure == RuntimeResourceFailure::HostCapacity &&
              before.message.find("not enough free memory to start") != std::string::npos,
          "a start the host refused before the weights loaded named another step");
  require(before.message.find("--max-memory") != std::string::npos,
          "a start the host refused did not name --max-memory as a remedy");
  const auto first = StartupRetryWindow::Clock::time_point{};
  require(StartupRetryWindow(30s).retryUntil(before, first) == first + 30s,
          "a start the host refused was not retried");
}

// What a start allocates, the KV runway and then the arenas and the warmup as
// RuntimeBootstrap::start allocates them, is memory a request in service
// needs: neither the warning margin above the spare reserve nor macOS's
// warning refuses it, only what refuses loading, and an allocation the
// engine marks meanwhile leaves the start's mark in place. Once serving
// begins, growth that no request in service needs keeps to both again.
void testStartGrowsThroughHostPressure(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-start-pressure");
  RuntimeResourcesConfig config = loadableConfig(metallibPath, root.path(), "start-pressure-test");
  const uint64_t reserve = EngineMemoryPolicy::hostAvailableReserveBytes(
      metal::probeDeviceCapabilities().physicalMemoryBytes);
  // A host with its reserve but not the warning margin beyond it, then one
  // with ample room while macOS warns.
  for (const bool warning : {false, true}) {
    const uint64_t available = warning ? 64 * kGiB : reserve + kHostWarningMarginBytes / 2;
    config.hostMemory = [available] {
      return std::optional<HostMemory>(HostMemory{available, available});
    };
    config.memoryPressure = [warning] {
      return warning ? MemoryPressure::Warning : MemoryPressure::Normal;
    };
    const std::string host = warning ? "under macOS's warning" : "short of the warning margin";
    std::unique_ptr<RuntimeResources> resources;
    static_cast<void>(
        test::capturedStderr([&] { resources = RuntimeResources::create(config, 0); }));
    const metal::AllocationAdmission admit = resources->memoryGovernor().allocationAdmission();
    const EngineMemoryBreakdown &budget = resources->memoryPlan().breakdown();
    std::unique_ptr<model::RuntimeModel> runtime;
    require(static_cast<bool>(admit(budget.sharedPrefillBytes + budget.sharedDecodeBytes, [&] {
              runtime = model::createRuntime(*resources->modelContext());
            })),
            "the start's arenas waited " + host);
    EngineConfig engine;
    connectToGovernor(engine, resources->memoryGovernor());
    {
      const Serving allocation(engine.serving, true);
    }
    // The warmup's lane state; it throws if refused.
    static_cast<void>(runtime->warmupPrefill(model::ExecutionLimits::prefillTokenBudget));
    static_cast<void>(runtime->warmupDecodeBatch(1));
    resources->beginServing();
    const metal::AllocationResult grown = admit(kMiB, [] {});
    require(!grown && grown.failure == metal::AllocationFailure::HostPressure,
            "growth that no request in service needs went on " + host + " once serving began");
  }
}

// A start checks the host's reserve one last time before Ready, with what
// the engine serves with. Its decode warmups past one lane leave their
// lanes' state idle, which goes back to macOS before Ready, and macOS counts
// it as available only a moment later: a check that still counted it, or
// that did not wait for that moment, would refuse a start the host has room
// for (#572).
void testStartChecksTheReserveWithWhatItServes(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-start-reserve");
  RuntimeBootstrapConfig config;
  config.resources = loadableConfig(metallibPath, root.path(), "start-reserve-test");
  RuntimeMetrics metrics;
  config.nativeLoop.metrics = &metrics;
  // The process's Metal memory at the last check of the host. Once the start
  // has given back a lane's state, the host refuses its next two checks, as
  // macOS would before it counts what Metal freed.
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  const uint64_t lane = config.resources.model.stateLayout.laneBytes();
  uint64_t checked = 0;
  uint64_t peak = 0;
  int refused = 0;
  config.resources.hostMemory = [&, host = config.resources.hostMemory] {
    checked = device.currentAllocatedSize;
    peak = std::max(peak, checked);
    if (checked + lane <= peak && refused < 2) {
      ++refused;
      return std::optional<HostMemory>(HostMemory{0, 0});
    }
    return host();
  };
  std::unique_ptr<RuntimeBootstrap> bootstrap;
  static_cast<void>(test::capturedStderr([&] {
    bootstrap = RuntimeBootstrap::start(config, [](std::span<const uint8_t>) {},
                                        [] { return std::string(); });
  }));
  require(refused == 2, "the start checked the host before it gave back its warmups' idle state");
  // The warmups leave three lanes' state idle beside the lane the engine
  // keeps. Under shader validation (MTL_SHADER_VALIDATION), less than a lane
  // of it leaves Metal's count only a moment later, which the last check may
  // still see.
  require(checked < device.currentAllocatedSize + 2 * lane,
          "the start's last check of the host counted the lanes' state its warmups left idle");
  require(bootstrap->statusJson(metrics.snapshot(), {}).find("\"memory_limited_steps\":[]") !=
              std::string::npos,
          "the start did not warm every decode width");
}

// A model served with YaRN starts and runs as any other, with YaRN all the
// way into its runtime: the start names its factor and the context it
// serves, the runtime's geometry serves that window, its arenas hold YaRN's
// rotary frequencies, and its prefill and decode build the target's RoPE
// tables with the attention factor.
void testYarnRuntime(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-yarn");
  RuntimeResourcesConfig config = loadableConfig(metallibPath, root.path(), "yarn-test");
  config.model = model::servedFor(std::move(config.model), 1'010'000);
  std::unique_ptr<RuntimeResources> resources;
  const std::string started =
      test::capturedStderr([&] { resources = RuntimeResources::create(config, 0); });
  require(started.find("YaRN is on: the target's RoPE is scaled by 3.85284 for 1010000 tokens of context, past the "
                       "native window of 262144. Static YaRN changes answers at every length, so pass a "
                       "--max-context above 262144 only when a request needs it.") != std::string::npos,
          "a start with YaRN did not name its factor and the context it serves");
  const model::RuntimeContext context = *resources->modelContext();
  const auto geometry = model::RuntimeGeometry::from(context.model, kv::Format::Int8, ops::GdnStateFormat::Float32);
  require(geometry.target.ropeScaling == config.model.ropeScaling && geometry.target.contextTokens() == 1'010'000,
          "the runtime's geometry lost YaRN or its window");
  std::array<float, SPLASH_TARGET_ROPE_PAIRS> expected{};
  model::rotaryInverseFrequencies(geometry.target.rotaryTheta, geometry.target.rotaryPairs,
                                  geometry.target.ropeScaling, expected);
  const metal::AllocationAdmission admit = resources->memoryGovernor().allocationAdmission();
  const EngineMemoryBreakdown &budget = resources->memoryPlan().breakdown();
  std::unique_ptr<model::RuntimeModel> runtime;
  require(static_cast<bool>(admit(budget.sharedPrefillBytes + budget.sharedDecodeBytes, [&] {
            const model::PrefillArena arena(context.backend, geometry, context.operators);
            require(std::memcmp(arena.get(model::PrefillTensor::TargetInverseFrequencies).contents(),
                                expected.data(), sizeof(expected)) == 0,
                    "the prefill arena does not hold YaRN's frequencies");
          })),
          "the YaRN prefill arena was refused");
  require(static_cast<bool>(admit(budget.sharedPrefillBytes + budget.sharedDecodeBytes,
                                  [&] { runtime = model::createRuntime(context); })),
          "the YaRN runtime's arenas were refused");
  static_cast<void>(runtime->warmupPrefill(model::ExecutionLimits::prefillTokenBudget));
  static_cast<void>(runtime->warmupDecodeBatch(1));
}

// The SSD cache holds no write back unless a write budget is set; one that
// is set starts with a quarter of a day's.
void testWriteBudgetOnlyWhenSet(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-write-budget");
  RuntimeResourcesConfig config = loadableConfig(metallibPath, root.path(), "write-budget-test");
  config.cacheDisk = {.bytes = kGiB};
  const auto tier = [&] {
    KvTierSnapshot snapshot;
    static_cast<void>(test::capturedStderr([&] {
      snapshot = RuntimeResources::create(config, 0)->cache().snapshot().kvTier;
    }));
    return snapshot;
  };
  const KvTierSnapshot unset = tier();
  require(unset.capacityBytes == kGiB && !unset.writeBudgetBytes &&
              unset.writesGated == DiskWritesGate::No,
          "the SSD cache had a write budget nobody set");
  config.cacheDiskWritesPerDay = 8 * kGiB;
  const KvTierSnapshot set = tier();
  require(set.writeBudgetBytes == 2 * kGiB && set.writesGated == DiskWritesGate::No,
          "a write budget that was set did not start with a quarter of a day's");
}

// Every start removes the caches under its root that nobody used for two
// weeks and keeps the others, one without --persistent-cache or the SSD
// cache too.
void testStaleCachesGoAtEveryStart(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-stale-model"), caches("splash-stale");
  RuntimeResourcesConfig config = loadableConfig(metallibPath, root.path(), "stale-test");
  config.cacheRoot = caches.path() / "prefix-cache";
  const std::string stale(CacheDirectory::kNamespaceDigits, 'a'),
      fresh(CacheDirectory::kNamespaceDigits, 'b');
  for (const std::string &name : {stale, fresh}) {
    auto directory = CacheDirectory::open(config.cacheRoot, name, std::chrono::milliseconds(0));
    std::ofstream(directory->kvSlots()) << "cache";
  }
  const timeval old[2] = {{0, 0}, {1000000000, 0}};
  for (const char *file : {"lock", "kv.slots"})
    require(::utimes((config.cacheRoot / stale / file).c_str(), old) == 0,
            "a cache file could not be aged");
  static_cast<void>(test::capturedStderr([&] { static_cast<void>(RuntimeResources::create(config, 0)); }));
  require(!std::filesystem::exists(config.cacheRoot / stale) &&
              std::filesystem::exists(config.cacheRoot / fresh / "kv.slots"),
          "a start without a persistent cache kept a stale cache under its root, or removed another");
}

// A cache root the engine makes for a persistent cache stays out of Time
// Machine backups; one that was there keeps its own setting.
void testMadeCacheRootStaysOutOfBackups(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-backups-model"), caches("splash-backups");
  RuntimeResourcesConfig config = loadableConfig(metallibPath, root.path(), "backups-test");
  config.cacheDisk = {.bytes = kGiB};
  config.persistentCache = true;
  const auto excluded = [](const std::filesystem::path &path) {
    NSURL *url = [NSURL fileURLWithPath:@(path.c_str()) isDirectory:YES];
    NSNumber *value = nil;
    return [url getResourceValue:&value forKey:NSURLIsExcludedFromBackupKey error:nil] &&
           value.boolValue;
  };
  config.cacheRoot = caches.path() / "made" / "prefix-cache";
  static_cast<void>(test::capturedStderr([&] { static_cast<void>(RuntimeResources::create(config, 0)); }));
  require(std::filesystem::is_directory(config.cacheRoot) && excluded(config.cacheRoot) &&
              !excluded(caches.path() / "made"),
          "the cache root the engine made was not excluded from backups, or its parent was");
  config.cacheRoot = caches.path() / "there";
  std::filesystem::create_directory(config.cacheRoot);
  static_cast<void>(test::capturedStderr([&] { static_cast<void>(RuntimeResources::create(config, 0)); }));
  require(!excluded(config.cacheRoot), "a cache root that was there was excluded from backups");
}

// The automatic tier keeps its staging only where the plan holds the
// requested context beside it. Asked for the context the plan holds without
// the staging but not with it, a start turns the tier off with one line and
// plans as without it.
void testAutomaticTierYieldsToTheContext(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-automatic");
  RuntimeResourcesConfig config = loadableConfig(metallibPath, root.path(), "automatic-test");
  config.diskVolume = reading(localVolume(500 * kGiB));
  uint64_t minimumRequired = 0;
  const auto start = [&](uint32_t requestedContextTokens, uint32_t &contextTokens,
                         bool &tier) {
    return test::capturedStderr([&] {
      auto resources = RuntimeResources::create(config, requestedContextTokens);
      contextTokens = resources->memoryPlan().maximumContextTokens();
      minimumRequired = resources->memoryPlan().breakdown().minimumRequiredBytes;
      tier = resources->cache().snapshot().kvTier.capacityBytes != 0;
    });
  };
  uint32_t without = 0, with = 0, yielded = 0;
  bool tier = false;
  static_cast<void>(start(0, without, tier));
  // A budget whose KV the staging shortens: the plan's least, the staging
  // and a little KV.
  config.maximumMemoryBytes =
      minimumRequired + config.model.stateLayout.cachedBytes() + 64 * kMiB;
  static_cast<void>(start(0, without, tier));
  require(!tier && without, "a start without the SSD cache had one, or no context");
  config.cacheDisk = {.automatic = true};
  static_cast<void>(start(0, with, tier));
  require(tier && with < without,
          "the automatic tier did not start, or its staging cost the plan no context");
  const std::string off = start(without, yielded, tier);
  require(!tier && yielded == without &&
              off.find("SSD cache off: the memory plan cannot hold a " + std::to_string(without) +
                       "-token context beside its state staging") != std::string::npos,
          "the automatic tier kept staging the requested context needs");
}

// The automatic tier's staging is decided by memory alone, so a start serves
// the same context whatever room the volume its files would go to has: a
// relaunch after something else filled the disk announces the context the
// server serves. The volume decides only whether the files open. A volume
// without room, one that cannot be measured or one that is not local leaves
// the tier off with one line and the staging the plan set aside unused; a
// persistent cache whose root has no room keeps temporary files.
void testAutomaticContextIgnoresTheVolume(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-volume"), caches("splash-volume-root");
  RuntimeResourcesConfig config = loadableConfig(metallibPath, root.path(), "volume-test");
  struct Started {
    uint32_t context = 0, planContext = 0;
    uint64_t staging = 0, minimumRequired = 0;
    bool tier = false, persistent = false;
    std::string log;
  };
  const auto start = [&] {
    Started started;
    started.log = test::capturedStderr([&] {
      auto resources = RuntimeResources::create(config, 0);
      started.context = resources->aneFfnOutcome().context;
      started.planContext = resources->memoryPlan().maximumContextTokens();
      started.staging = resources->memoryPlan().breakdown().stateStagingBytes;
      started.minimumRequired = resources->memoryPlan().breakdown().minimumRequiredBytes;
      const CacheSnapshot cache = resources->cache().snapshot();
      started.tier = cache.kvTier.capacityBytes != 0;
      started.persistent = cache.persistent;
    });
    return started;
  };
  const auto offOnce = [](const Started &started, std::string_view reason) {
    const size_t at = started.log.find("SSD cache off: ");
    return at != std::string::npos && started.log.find("SSD cache off", at + 1) == std::string::npos &&
           started.log.find(reason, at) != std::string::npos &&
           started.log.find("; the state staging the plan set aside stays unused.", at) !=
               std::string::npos;
  };
  // A budget whose KV the staging shortens: the plan's least, the staging
  // and a little KV.
  config.maximumMemoryBytes =
      start().minimumRequired + config.model.stateLayout.cachedBytes() + 64 * kMiB;
  const Started off = start();
  config.cacheDisk = {.automatic = true};
  config.diskVolume = reading(localVolume(500 * kGiB));
  const Started room = start();
  require(!off.tier && room.tier && room.staging == config.model.stateLayout.cachedBytes() &&
              room.context == room.planContext && room.context < off.context,
          "the automatic tier did not start beside its staging, or the staging cost no context");
  const std::array<std::pair<std::optional<DiskVolume>, std::string>, 3> refusals{{
      {localVolume(11 * kGiB), "11.0 GiB available on /Volumes/Test is too little beyond the 10.0 GiB"},
      {std::nullopt, "its volume cannot be measured"},
      {DiskVolume{"/Volumes/Share", 500 * kGiB, 1000 * kGiB, false}, "/Volumes/Share is not a local volume"},
  }};
  for (const auto &[volume, reason] : refusals) {
    config.diskVolume = reading(volume);
    const Started refused = start();
    require(!refused.tier && refused.staging == room.staging && refused.context == room.context &&
                refused.planContext == room.planContext && offOnce(refused, reason),
            "a volume without room changed the automatic context, or did not leave the tier off "
            "once (" + reason + ")");
  }
  // A persistent cache's root without room leaves the tier temporary files;
  // with no room for those either, it is off.
  config.persistentCache = true;
  config.cacheRoot = caches.path() / "prefix-cache";
  config.diskVolume = [&](const std::filesystem::path &directory) {
    return std::optional(localVolume(directory == config.cacheRoot ? 11 * kGiB : 500 * kGiB));
  };
  const Started temporary = start();
  require(temporary.tier && !temporary.persistent && temporary.context == room.context &&
              temporary.log.find("Persistent cache off: 11.0 GiB available on /Volumes/Test") !=
                  std::string::npos &&
              temporary.log.find("SSD cache off") == std::string::npos,
          "a persistent cache whose root had no room did not keep temporary files");
  config.diskVolume = reading(localVolume(11 * kGiB));
  const Started neither = start();
  require(!neither.tier && neither.context == room.context &&
              offOnce(neither, "for its root, 11.0 GiB available on /Volumes/Test"),
          "a persistent cache with no room anywhere did not leave the tier off once");
}

// A block-sparse target's context past what memory holds spills to the SSD
// cache, so where the automatic cache's volume has no room for it, a first
// start serves only what memory holds. A relaunch keeps its first engine's
// context whatever room the volume has left since: its spilling plan opens
// the cache's temporary files however little room their volume has.
void testRelaunchKeepsTheSpilledContext(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-relaunch");
  RuntimeResourcesConfig config = flashNextConfig(metallibPath, root.path());
  config.cacheDisk = {.automatic = true};
  config.diskVolume = reading(localVolume(500 * kGiB));
  // A budget whose memory holds less of the window than spilling does.
  config.maximumMemoryBytes = startStreamed(config).minimumRequired + 512 * kMiB;
  const StreamedStart first = startStreamed(config);
  config.diskVolume = reading(localVolume(11 * kGiB));
  const StreamedStart refused = startStreamed(config);
  require(first.tier && !refused.tier && refused.context < first.context &&
              refused.log.find("SSD cache off: 11.0 GiB available on /Volumes/Test") != std::string::npos,
          "a block-sparse target did not spill past what its memory holds, or spilled to an SSD cache "
          "whose volume has no room for it");
  config.relaunchContext = first.context;
  const StreamedStart relaunch = startStreamed(config);
  require(relaunch.tier && relaunch.context >= first.context,
          "a relaunch served less than its first engine's context for want of SSD room");
}

// The engine asks the governor whether the host pauses growth, and its
// serving mark lets a request in service grow through that pause.
void testEngineFollowsTheGovernor(const char *metallibPath) {
  metal::MetalBackend backend(metallibPath);
  constexpr uint64_t kGiB = 1ULL << 30;
  constexpr uint64_t hostReserve = 2 * kGiB;
  std::optional<uint64_t> available = hostReserve + 8 * kGiB;
  const metal::MetalMemoryStats memory = backend.memoryStats();
  MemoryGovernor governor(
      backend, std::max(memory.allocatedBytes, memory.deviceCurrentAllocatedBytes) + kGiB,
      hostReserve, hostReserve,
      [&available] { return std::optional<HostMemory>(HostMemory{*available, *available}); }, 0);
  EngineConfig config;
  connectToGovernor(config, governor);
  require(config.growthPaused && config.serving && !config.growthPaused(),
          "the engine was not connected to the governor");
  const auto admits = [admit = governor.allocationAdmission()] {
    return static_cast<bool>(admit(1024, [] {}));
  };
  // Inside the warning margin the host pauses growth that no request in
  // service needs.
  available = hostReserve + kGiB / 2;
  require(config.growthPaused() && !admits(), "the engine did not see the host's pause");
  config.serving(true);
  require(admits(), "the serving mark did not reach the governor");
  config.serving(false);
  require(!admits(), "the serving mark was not cleared");
}

// Historical retained KV/state/SlotFile assertions, exercised against the
// production owner rather than separate fake cache/backing objects.
void testRetainedIdentityAcrossResidencyMove(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-ownership-model"), caches("splash-ownership-cache");
  auto config = loadableConfig(metallibPath, root.path(), "ownership-test");
  config.cacheDisk = {.bytes = kGiB};
  config.persistentCache = true;
  config.cacheRoot = caches.path();
  std::unique_ptr<RuntimeResources> resources;
  static_cast<void>(test::capturedStderr([&] { resources = RuntimeResources::create(config, 0); }));
  const auto context = *resources->modelContext();
  auto runtime = model::createRuntime(context);
  static_cast<void>(runtime->warmupPrefill(1));
  static_cast<void>(runtime->warmupDecodeBatch(1));
  resources->beginServing(); // Exactly once, including across the owner move.
  require(RuntimeResourcesTestAccess::onProbation(*resources), "persistent probation did not start");
  const auto identities = RuntimeResourcesTestAccess::retained(*resources);
  // The retained persistence queue Engines borrow, through the owner's own API.
  WriteBehind &queue = resources->writeBehind();
  const uint64_t stateBytes = context.stateStorage.actualAllocatedBytes();
  require(stateBytes != 0, "ownership fixture did not allocate retained state");
  std::vector<uint32_t> prompt(65);
  for (uint32_t index = 0; index < prompt.size(); ++index) prompt[index] = 100 + index;
  auto &cache = resources->cache();
  cache.beginRequest(73);
  require(cache.ensureTokens(73, prompt.size()).granted(), "ownership fixture could not acquire KV");
  cache.publishCommittedBlocks(73, prompt, 64, {});
  const auto block = cache.blockAt(73, 64);
  require(block != 0, "ownership fixture did not publish a KV boundary");
  cache.publishCompositeState(block, std::make_shared<RetainedCompositeState>(), false);
  cache.endRequest(73);
  auto slot = RuntimeResourcesTestAccess::slot(*resources);
  require(slot != nullptr, "retained SlotFile could not acquire a slot");
  const auto slotId = slot->id();
  const auto retained = cache.snapshot();
  const auto inspect = [&] {
    require(RuntimeResourcesTestAccess::retained(*resources) == identities,
            "a retained object moved with model residency");
    require(&resources->writeBehind() == &queue,
            "the residency move replaced the retained WriteBehind Engines borrow");
    auto lookup = cache.lookup(prompt, {});
    require(lookup.kvBoundary == 64 && lookup.resumeBoundary() == 64 && lookup.state,
            "retained KV/composite state became unusable without residency");
    require(cache.snapshot().pool.allocatedBytes == retained.pool.allocatedBytes &&
                context.stateStorage.actualAllocatedBytes() == stateBytes && slot->id() == slotId &&
                RuntimeResourcesTestAccess::onProbation(*resources) && resources->backend().healthy(),
            "retained storage, SlotFile or probation changed across residency move");
    std::atomic<size_t> reads{0};
    RuntimeResourcesTestAccess::readers(*resources).run(8, [&](size_t) { ++reads; });
    require(reads == 8, "retained shared readers were lost with residency");
  };
  RuntimeResourcesTestAccess::moved(*resources, inspect);
  // Unwinding a fixture at the same boundary must also restore the owner.
  rejects([&] {
    RuntimeResourcesTestAccess::moved(*resources, [&] { throw std::runtime_error("fixture failure"); });
  }, "fixture failure", "the ownership fixture swallowed a failure");
  require(&resources->modelContext()->model == &context.model &&
              &resources->modelContext()->operators == &context.operators,
          "restoring residency invalidated RuntimeContext borrows");
  // Use the runtime built before the move; its model/plans/governor borrows
  // must remain valid, including the upstream idle-weight release/restore.
  auto *weights = resources->releasableMemory();
  require(weights != nullptr, "idle-weight memory was not restored with residency");
  weights->release();
  const auto admit = resources->memoryGovernor().allocationAdmission();
  const auto optional = resources->memoryGovernor().growthAdmission();
  size_t restores = 0;
  while (!weights->restore(admit, optional))
    require(++restores < 1000, "weight restoration failed to finish after residency move");
  static_cast<void>(runtime->warmupPrefill(1));
  static_cast<void>(runtime->warmupDecodeBatch(1));
  const auto runtimeMemory = runtime->actualRuntimeMemory();
  const auto beforeRuntime = resources->backend().refreshMemoryStats().allocatedBytes;
  runtime.reset(); // Bootstrap's normal runtime -> resources teardown order.
  const auto afterRuntime = resources->backend().refreshMemoryStats().allocatedBytes;
  require(beforeRuntime >= afterRuntime + runtimeMemory.sharedPrefillActualAllocatedBytes +
                              runtimeMemory.sharedDecodeActualAllocatedBytes,
          "destroying RuntimeModel did not release its arenas while retained storage stayed alive");
  require(resources->closePersistentCache(), "persistent cache could not close after ownership move");
}

// Target/draft/vision allocations, image-writer closures, the ANE slot and
// ReleasableMemory really belong to ModelResidency (T009): the residency is
// destroyed as one unit, its idle-weight callbacks before the ANE referents,
// plans and model images/stores/writers it borrows. This isolates that
// boundary; it is not a suspension test.
void testResidencyReleasesAllWeightCategories(const char *metallibPath) {
  constexpr uint64_t probeBytes = 2 * kMiB;
  metal::MetalBackend backend(metallibPath);
  auto retained = backend.allocateBuffer(probeBytes, metal::BufferStorage::Shared, "ownership-probe");
  const uint64_t retainedBytes = backend.refreshMemoryStats().allocatedBytes;
  struct WriterLifetime final {
    metal::MetalBackend &backend;
    bool &destroyedAlive;
    ~WriterLifetime() { destroyedAlive = backend.healthy(); }
  };
  // Failure 0 faults the residency's Storage allocation. Failure 1 faults
  // ReleasableMemory's parts vector inside the residency's Storage construction,
  // after that allocation succeeds. -1 is the ordinary destructor path. The
  // injector only faults this thread.
  for (const int failure : {-1, 0, 1}) {
    bool writerDestroyedAlive = false;
    bool failed = false;
    try {
      model::LoadedModel loaded;
      loaded.images = std::make_shared<model::WeightImages>(backend, "ownership-probe");
      auto lifetime = std::shared_ptr<WriterLifetime>(new WriterLifetime{backend, writerDestroyedAlive});
      {
        const auto file = loaded.images->load({
            .component = "probe", .magic = "T007TEST", .bytes = probeBytes,
            .write = [lifetime = std::move(lifetime)](std::span<uint8_t> bytes,
                                                     const metal::MetalBuffer &) {
              const auto header = model::weightFileHeader("T007TEST", 0, 0);
              std::copy(header.begin(), header.end(), bytes.begin());
            }});
      }
      auto &target = std::get<model::Qwen3_8Weights>(loaded.target);
      target.actualAllocatedBytes = probeBytes;
      ops::NativeRows planes;
      planes.rows = backend.allocateBuffer(probeBytes, metal::BufferStorage::Shared, "ownership-probe");
      target.tokenEmbedding = ops::EmbeddingWeights(1, 1, std::move(planes));
      loaded.draft.actualAllocatedBytes = probeBytes;
      loaded.draft.predecessorCodebook = backend.allocateBuffer(probeBytes, metal::BufferStorage::Shared, "ownership-probe");
      loaded.vision.actualAllocatedBytes = probeBytes;
      loaded.vision.tensors.positionTable = backend.allocateBuffer(probeBytes, metal::BufferStorage::Shared, "ownership-probe");
      const auto resident = backend.refreshMemoryStats().allocatedBytes;
      require(resident >= retainedBytes + 4 * probeBytes, "probe weights were not allocated");
      auto plans = ops::ExecutionPlans(backend.capabilities());
      allocationFailureAfter = failure;
      // ReleasableMemory is now built inside the residency's Storage over its
      // own model and split: a throwing parts allocation unwinds the residency
      // (and its already-moved model and plans) while the retained backend is
      // still live, before any ownership transfer.
      auto residency = RuntimeResourcesTestAccess::make(std::move(loaded), std::move(plans),
                                                       std::unique_ptr<ops::AneFfn>{});
      static_cast<void>(residency);
    } catch (const std::bad_alloc &) {
      failed = true;
    }
    allocationFailureAfter = -1;
    require((failure == -1 || failed) && writerDestroyedAlive && retained && backend.healthy() &&
                backend.refreshMemoryStats().allocatedBytes == retainedBytes,
            "ordinary/partial residency teardown leaked weights or outlived its backend/writer");
  }
}

} // namespace

// The native loop's weights paths are residency-conditional: with the
// residency moved out, a loop built without weights reports absent
// telemetry (never a live measurement, never a dereference) and releases
// nothing; with its weights live, the idle release still gives them back
// once the idle release has passed without a request.
void testWeightsConditionalNativeLoop(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-native-weights");
  auto config = loadableConfig(metallibPath, root.path(), "weights-test");
  std::unique_ptr<RuntimeResources> resources;
  static_cast<void>(test::capturedStderr([&] { resources = RuntimeResources::create(config, 0); }));
  EngineConfig engineConfig;
  connectToGovernor(engineConfig, resources->memoryGovernor());
  engineConfig.maxContext = resources->memoryPlan().maximumContextTokens();
  engineConfig.vocabularySize = config.model.capabilities.vocabularySize;
  engineConfig.spill = resources->spillConfig();
  const auto limits = protocolLimitsFor(config.model.capabilities, engineConfig.maxContext);
  RuntimeMetrics metrics(8);
  auto runtime = model::createRuntime(*resources->modelContext());
  // Absent residency: a loop without weights is constructible and its
  // weightsSnapshot()/releaseIdleWeights()/restore paths stay safe.
  RuntimeResourcesTestAccess::moved(*resources, [&] {
    NativeLoopConfig loopConfig;
    loopConfig.engine = engineConfig;
    loopConfig.metrics = &metrics;
    loopConfig.weightAdmission = resources->memoryGovernor().allocationAdmission();
    loopConfig.growthAdmission = resources->memoryGovernor().growthAdmission();
    NativeRuntime loop(loopConfig, 1.0, resources->cache(), resources->writeBehind(), *runtime,
                       [](std::span<const uint8_t>) {}, [] { return std::string("{}"); }, limits);
    const auto snapshot = loop.weightsSnapshot();
    test::require(!snapshot.released && !snapshot.restoring && snapshot.restores == 0 &&
                      snapshot.restoreFailures == 0 && snapshot.idleReleaseSeconds == 1.0,
                  "a loop without weights reported live weight telemetry");
    loop.releaseIdleWeights();
    test::require(!loop.weightsSnapshot().released && !loop.connectionMustClose() &&
                      loop.engineHealthy(),
                  "the absent-weights control path broke the loop");
  });
  // Live weights: the ordinary idle release still gives them back.
  NativeLoopConfig loopConfig;
  loopConfig.engine = engineConfig;
  loopConfig.metrics = &metrics;
  loopConfig.weights = resources->releasableMemory();
  test::require(loopConfig.weights != nullptr, "weights missing after residency move");
  loopConfig.weightAdmission = resources->memoryGovernor().allocationAdmission();
  loopConfig.growthAdmission = resources->memoryGovernor().growthAdmission();
  double clock = 1000.0;
  loopConfig.monotonicMilliseconds = [&clock] { return clock; };
  NativeRuntime loop(loopConfig, 1.0, resources->cache(), resources->writeBehind(), *runtime,
                     [](std::span<const uint8_t>) {}, [] { return std::string("{}"); }, limits);
  loop.announceReady();
  loop.releaseIdleWeights();
  test::require(!resources->releasableMemory()->released(),
                "weights were released before the idle release passed");
  clock += 2000.0;
  const auto log = test::capturedStderr([&] { loop.releaseIdleWeights(); });
  test::require(resources->releasableMemory()->released() &&
                    log.find("Weights released after") != std::string::npos,
                "the idle release did not give the weights back");
  loop.releaseIdleWeights();
  test::require(resources->releasableMemory()->released(),
                "a second idle pass released the weights again");
}

// [T031 prerequisite] The private stratum a recovery assembles against a
// RETAINED graph (Gate 1). ONE model-bound phase serves both a first assembly
// and a rebuild: with a retained graph it reuses that graph's SSD readers,
// reports its tier as already open rather than opening another, and allocates
// only a stratum, so no second backend, KV pages, state storage, cache, disk
// tier or governor can appear. The serving residency stays live beside the
// candidate while it is built, and the candidate's own RuntimeContext carries
// ITS OWN model, plans and ANE split around THIS graph's retained storage --
// which is what a RuntimeModel built from it executes on. What the checked
// adoption gate refuses, it refuses WITHOUT moving anything, leaving the
// candidate intact for the rollback path: a live slot, another graph's
// identity, or a rebuilt plan whose KV/state geometry is not this graph's.
void testPrivateRecoveryResidencyAgainstRetainedGraph(const char *metallibPath) {
  const test::TemporaryDirectory root("splash-recovery-residency");
  auto config = loadableConfig(metallibPath, root.path(), "recovery-test");
  config.cacheDisk = {.bytes = kGiB};
  std::unique_ptr<RuntimeResources> resources;
  static_cast<void>(test::capturedStderr(
      [&] { resources = RuntimeResources::create(config, 0); }));
  const auto identities = RuntimeResourcesTestAccess::retained(*resources);
  const auto identity = resources->cacheIdentity();
  auto serving = model::createRuntime(*resources->modelContext());
  static_cast<void>(serving->warmupPrefill(1));
  require(resources->modelResident() && resources->releasableMemory(),
          "a serving graph reports no residency");

  std::optional<ModelResidency> privateResidency;
  static_cast<void>(test::capturedStderr(
      [&] { privateResidency = resources->buildModelResidency(config, 0, [] { return false; }); }));
  require(RuntimeResourcesTestAccess::held(*privateResidency) != nullptr,
          "the private residency holds no stratum of its own");
  require(RuntimeResourcesTestAccess::retained(*resources) == identities,
          "a rebuild against a retained graph disturbed a retained object");
  require(resources->modelResident() && resources->releasableMemory(),
          "a rebuild emptied or replaced the serving residency");
  require(resources->backend().healthy(), "a rebuild left the retained backend unhealthy");

  // The same retained storage, this stratum's model: the private context's
  // model, plans and split are the candidate's, its pages, states, caches and
  // growth admission this graph's.
  const auto published = *resources->modelContext();
  const auto privateContext = *resources->modelContext(*privateResidency);
  require(&privateContext.model != &published.model,
          "a private context names the published stratum's model");
  require(&privateContext.kvPages == &published.kvPages &&
              &privateContext.stateStorage == &published.stateStorage &&
              privateContext.blockCache == published.blockCache &&
              privateContext.historyStream == published.historyStream &&
              &privateContext.backend == &published.backend,
          "a private context reached another graph's storage");
  // It runs: one prefill through a RuntimeModel built over the private stratum,
  // admitted by this graph's governor, while the serving runtime still runs.
  auto privateRuntime = model::createRuntime(privateContext);
  static_cast<void>(privateRuntime->warmupPrefill(1));
  privateRuntime.reset();
  require(resources->backend().healthy() &&
              RuntimeResourcesTestAccess::retained(*resources) == identities,
          "a private model's arenas disturbed the retained graph");

  // A cancelled construction retires what it allocated and keeps this graph
  // exactly: the cooperative fence the loader checks is the operation's, and
  // the graph's own startup predicate goes back in place behind it.
  {
    bool refused = false;
    try {
      static_cast<void>(test::capturedStderr(
          [&] { static_cast<void>(resources->buildModelResidency(config, 0, [] { return true; })); }));
    } catch (...) {
      refused = true;
    }
    require(refused && resources->modelResident() &&
                RuntimeResourcesTestAccess::retained(*resources) == identities,
            "a cancelled rebuild disturbed the retained graph");
  }
  // A plan this graph was never assembled with: the same model description with
  // the SSD cache's state staging gone is a different geometry, and the gate
  // refuses before a residency exists.
  {
    auto mismatched = config;
    mismatched.cacheDisk = {.bytes = 0};
    bool refused = false;
    try {
      static_cast<void>(test::capturedStderr(
          [&] { static_cast<void>(resources->buildModelResidency(mismatched, 0, [] { return false; })); }));
    } catch (...) {
      refused = true;
    }
    require(refused && RuntimeResourcesTestAccess::retained(*resources) == identities,
            "a rebuild with another graph's geometry was accepted");
  }

  // The adoption gate over a LIVE slot and another identity: false, the
  // candidate's stratum still whole, nothing of this graph touched.
  auto otherIdentity = identity;
  otherIdentity.buildId = "another-build";
  require(!resources->canAdoptModelResidency(*privateResidency, identity),
          "the gate accepted a stratum over a live one");
  require(!resources->canAdoptModelResidency(*privateResidency, otherIdentity),
          "the gate accepted another build's identity");
  std::optional<ModelResidency> refused = std::move(privateResidency);
  static_cast<void>(test::capturedStderr([&] {
    require(!resources->adoptModelResidency(std::move(*refused), otherIdentity),
            "an unchecked adoption moved a wrong identity in");
    require(RuntimeResourcesTestAccess::held(*refused) != nullptr,
            "a refused adoption consumed the candidate's stratum");
    privateResidency = std::move(refused);
    refused.reset();
  }));

  // The lawful order the lifecycle drives: the safe point moves the SERVING
  // stratum out to the designated disposal path, the checked gate accepts
  // THIS graph's own stratum into the now-empty slot, and the retired stratum
  // is what dies last, after nothing borrows it any more.
  std::optional<ModelResidency> retired;
  static_cast<void>(test::capturedStderr([&] {
    retired = resources->releaseModelResidency();
    require(resources->canAdoptModelResidency(*privateResidency, identity),
            "the gate refused this graph's own stratum over an empty slot");
    require(resources->adoptModelResidency(std::move(*privateResidency), identity),
            "the checked move into the empty slot refused");
    privateResidency.reset();
  }));
  require(resources->modelResident() &&
              &resources->modelContext()->model != &RuntimeResourcesTestAccess::model(*retired),
          "an adopted residency did not become this graph's");
  serving.reset();
  auto rebound = model::createRuntime(*resources->modelContext());
  static_cast<void>(rebound->warmupPrefill(1));
  rebound.reset();
  retired.reset();  // destroyed last: nothing borrows it by now
  require(resources->backend().healthy() &&
              RuntimeResourcesTestAccess::retained(*resources) == identities,
          "the adoption moved a retained object or disturbed the graph");
}

int main(int argc, char **argv) {
  @autoreleasepool {
    try {
      require(argc == 1 || argc == 2, "expected an optional metallib path");
      const std::string metallib = argc == 2 ? argv[1] :
          (std::filesystem::path(argv[0]).parent_path().parent_path() / "splash.metallib").string();
      testResidencyReleasesAllWeightCategories(metallib.c_str());
      testRetainedIdentityAcrossResidencyMove(metallib.c_str());
      testPrivateRecoveryResidencyAgainstRetainedGraph(metallib.c_str());
      testWeightsConditionalNativeLoop(metallib.c_str());
      testLoadedVisionIsRequiredOnlyWithVision();
      testPersistentCacheNamespace();
      testWeightBudgetBeforeLoading(metallib.c_str());
      testStateStagingNeedsAStartedTier(metallib.c_str());
      testImagePatchCapIsBounded(metallib.c_str());
      testHostMemoryProbeIsRequired(metallib.c_str());
      testModelBeyondBudgetIsRefusedBeforeLoading(metallib.c_str());
      testStartupAdmissionIgnoresModelSize(metallib.c_str());
      testFailedStepIsNamed(metallib.c_str());
      testStartGrowsThroughHostPressure(metallib.c_str());
      testStartChecksTheReserveWithWhatItServes(metallib.c_str());
      testYarnRuntime(metallib.c_str());
      testWriteBudgetOnlyWhenSet(metallib.c_str());
      testStaleCachesGoAtEveryStart(metallib.c_str());
      testMadeCacheRootStaysOutOfBackups(metallib.c_str());
      testAutomaticTierYieldsToTheContext(metallib.c_str());
      testAutomaticContextIgnoresTheVolume(metallib.c_str());
      testRelaunchKeepsTheSpilledContext(metallib.c_str());
      testEngineFollowsTheGovernor(metallib.c_str());
      {
        const test::TemporaryDirectory root("splash-moe");
        const RuntimeResourcesConfig moe = moeConfig(metallib.c_str(), root.path());
        testStreamableWeightsAreWhatLoads(moe);
        testAutomaticExpertMemory(moe);
        testVerifyRows(metallib.c_str(), moe);
      }
      std::cout << "runtime resources tests passed\n";
      return EXIT_SUCCESS;
    } catch (const std::exception &error) {
      std::cerr << "runtime resources tests failed: " << error.what() << '\n';
      return EXIT_FAILURE;
    }
  }
}
