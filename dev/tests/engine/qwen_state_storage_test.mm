#include "Checked.hpp"
#include "engine/MemoryGovernor.hpp"
#include "engine/Cache.hpp"
#include "engine/Engine.hpp"
#include "tests/engine/AllocationFailure.hpp"
#include "tests/engine/ClaimScope.hpp"
#include "TestImmediateTicket.hpp"
#include "TestCache.hpp"
#include "TestKvPool.hpp"
#include "engine/WriteBehind.hpp"
#include "model/QwenState.hpp"
#include "tests/engine/TestChecks.hpp"

#include <unistd.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <future>
#include <chrono>
#include <new>
#include <iostream>
#include <limits>
#include <cstring>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include <set>
#include <algorithm>
#include <array>
#include <iterator>
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>
#include <unordered_map>
#include <utility>

using namespace splash;
using namespace splash::engine;

namespace {

constexpr model::GdnStateLayout kTargetState{48, 3, 10'240, 48, 128, 128};
constexpr model::DraftStateLayout kDraftState{5, 8, 128, 5120};
constexpr model::CompositeStateLayout kStateLayout{kTargetState, kDraftState};
constexpr uint64_t kStateSlotBytes = model::SlotFile::slotBytesFor(kStateLayout.cachedBytes());

using splash::test::rejects;
using splash::test::require;

uint32_t &word(const metal::MetalBuffer &buffer, uint64_t byteOffset = 0) {
  require(byteOffset + sizeof(uint32_t) <= buffer.sizeBytes(),
          "test marker is outside buffer");
  auto *bytes = static_cast<uint8_t *>(buffer.contents());
  require(bytes != nullptr, "test buffer is not CPU-visible");
  return *reinterpret_cast<uint32_t *>(bytes + byteOffset);
}

void fill(const metal::MetalBuffer &buffer, uint64_t seed) {
  auto *bytes = static_cast<uint8_t *>(buffer.contents());
  require(bytes != nullptr, "test buffer is not CPU-visible");
  uint64_t x = seed | 1;
  for (uint64_t i = 0; i < buffer.sizeBytes(); ++i) {
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    bytes[i] = static_cast<uint8_t>(x);
  }
}

std::vector<uint8_t> bytesOf(const metal::MetalBuffer &buffer) {
  auto *bytes = static_cast<const uint8_t *>(buffer.contents());
  return std::vector<uint8_t>(bytes, bytes + buffer.sizeBytes());
}

bool sameBytes(const metal::MetalBuffer &buffer, const std::vector<uint8_t> &image) {
  return image.size() == buffer.sizeBytes() &&
         std::memcmp(buffer.contents(), image.data(), image.size()) == 0;
}

// Every byte of a lane's current state, in the order its disk copy holds
// them: its current GDN cell and its context window.
std::vector<std::vector<uint8_t>> stateImage(const model::QwenStateStorage &storage,
                                             uint32_t lane) {
  return {bytesOf(storage.current(lane).stateBase), bytesOf(storage.window(lane))};
}

// The lengths of a lane at `tokens` whose rings and window hold the last
// draft window, as a published state's are.
model::QwenLogicalLengths published(uint64_t tokens) {
  const uint32_t window = static_cast<uint32_t>(std::min<uint64_t>(tokens, 2048));
  return {tokens, tokens - window, window, tokens};
}

// Every pooled buffer the storage returns to macOS, one reclaim step at a
// time, as the engine releases them.
uint64_t releaseAllIdle(model::QwenStateStorage &storage, bool keepLane) {
  uint64_t released = 0;
  while (const uint64_t buffer = storage.releaseOneIdle(keepLane))
    released += buffer;
  return released;
}

template <typename Ticket> bool finishWhenReady(Ticket &ticket) {
  while (!ticket.ready()) std::this_thread::yield();
  return ticket.finish();
}

std::set<int> unlinkedRegularDescriptors() {
  std::set<int> descriptors;
  for (int descriptor = 0; descriptor < getdtablesize(); ++descriptor) {
    struct stat info {};
    if (fstat(descriptor, &info) == 0 && S_ISREG(info.st_mode) &&
        info.st_nlink == 0)
      descriptors.insert(descriptor);
  }
  return descriptors;
}

struct EngineStarted final {
  uint64_t requestId = 0;
  uint32_t matchedTokens = 0;
  uint32_t lane = 0;
};

struct EngineDone final {
  uint64_t requestId = 0;
  EngineFinishReason reason = EngineFinishReason::Length;
  uint32_t promptTokens = 0;
  uint32_t completionTokens = 0;
};

struct EngineProgress final {
  uint64_t requestId = 0;
  uint32_t tokens = 0;
};

class QwenEngineEventCollector final : public EngineEventSink {
public:
  void batchCompleted(WorkKind kind, uint32_t, uint32_t inputTokens,
                      uint32_t, uint32_t, uint32_t, double, double) override {
    if (kind == WorkKind::Prefill)
      prefillRows += inputTokens;
  }
  void started(uint64_t requestId, uint32_t matchedTokens, uint32_t lane) override {
    startedEvents.push_back({requestId, matchedTokens, lane});
  }
  void promptProgress(uint64_t requestId, uint32_t tokens) override {
    progressEvents.push_back({requestId, tokens});
  }
  void tokens(uint64_t, std::span<const uint32_t>) override {}
  void maskRequested(uint64_t, std::span<const uint32_t>) override {}
  void completed(uint64_t requestId, EngineFinishReason reason,
                 bool, uint32_t promptTokens, uint32_t completionTokens, uint32_t,
                 std::span<const float>, const SpeculativeCounts &) override {
    doneEvents.push_back({requestId, reason, promptTokens, completionTokens});
  }
  void failed(uint64_t requestId, LaneOutcome, std::string, uint32_t) override {
    failedRequests.push_back(requestId);
  }

  uint64_t prefillRows = 0;
  std::vector<EngineStarted> startedEvents;
  std::vector<EngineProgress> progressEvents;
  std::vector<EngineDone> doneEvents;
  std::vector<uint64_t> failedRequests;
};

struct EnginePrefillWork final {
  uint64_t requestId = 0;
  uint64_t logicalPosition = 0;
  uint32_t tokenCount = 0;
};

struct RestoredQwenValues final {
  uint64_t requestId = 0;
  uint32_t boundary = 0;
  model::QwenLogicalLengths lengths;
  uint32_t gdnMarker = 0;
  uint32_t recurrentMarker = 0;
  uint32_t windowMarker0 = 0;
  uint32_t windowMarker4 = 0;
};

// This adapter supplies deterministic inference steps while all lane ownership,
// state snapshots, and restore IO go through the production QwenStateStorage.
class QwenEngineTestRuntimeModel final : public model::RuntimeModel {
public:
  explicit QwenEngineTestRuntimeModel(model::QwenStateStorage &states)
      : states_(states) {}

  StateAdmission begin(const ModelRequest &request) override {
    for (uint32_t slot = 0; slot < model::ExecutionLimits::maximumBatchWidth;
         ++slot) {
      if (states_.metadata(slot).assigned())
        continue;
      const auto admission = states_.tryActivateLane(slot, request.id);
      if (!admission)
        return {{}, StateFailure::MemoryPressure, admission.failure};
      owners_.emplace(request.id, slot);
      laneEvents.push_back({request.id, true, slot});
      return {slot, StateFailure::None};
    }
    return {{}, StateFailure::ConcurrencyLimit};
  }
  void suspend(uint64_t requestId) override { end(requestId); }
  StateAdmission resume(const ModelRequest &request) override {
    return begin(request);
  }
  std::unique_ptr<StateRestore>
  beginRestore(uint64_t requestId, uint32_t boundary,
               std::shared_ptr<const CompositeState> state,
               bool restoreDraftState,
               std::function<void()> completion) override {
    auto ioObserver = std::exchange(nextRestoreIoObserver, {});
    auto wrappedCompletion =
        [ioObserver = std::move(ioObserver),
         completion = std::move(completion)]() mutable {
          if (ioObserver)
            ioObserver->set_value();
          if (completion)
            completion();
        };
    return states_.beginRestore(
        slotFor(requestId), *state, restoreDraftState,
        std::move(wrappedCompletion), [this, requestId, boundary] {
          rememberRestored(requestId, boundary);
        });
  }
  void setDraftContextPlan(uint64_t, DraftContextPlan) override {}
  std::unique_ptr<ModelBatchTicket>
  submit(const BatchPlan &plan, std::span<const ModelBatchItem> items,
         std::function<void()> completion) override {
    std::vector<ModelStepResult> results;
    results.reserve(items.size());
    for (const ModelBatchItem &item : items) {
      if (plan.kind == WorkKind::Prefill) {
        prefillWork.push_back(
            {item.requestId, item.logicalPosition, item.tokenCount});
      }
      ModelStepResult result;
      result.requestId = item.requestId;
      if (plan.kind == WorkKind::Prefill) {
        result.consumedPromptTokens = item.tokenCount;
      } else {
        result.outputTokens.push_back(7);
      }
      results.push_back(std::move(result));
    }
    return test::immediateTicket(std::move(results), completion);
  }
  std::shared_ptr<const CompositeState>
  snapshot(uint64_t requestId) override {
    return states_.snapshot(slotFor(requestId));
  }
  bool canSnapshotToDisk(bool inUse) const noexcept override {
    return states_.canSnapshotToDisk(inUse);
  }
  std::unique_ptr<StateOffload>
  snapshotToDisk(uint64_t requestId,
                 std::function<void()> completion) override {
    return states_.snapshotToDisk(slotFor(requestId), std::move(completion));
  }
  std::shared_ptr<StateReservation> reserveState(uint64_t requestId, uint32_t, metal::AllocationFailure &refusal) override {
    static_cast<void>(slotFor(requestId));
    return states_.reserve(refusal);
  }
  std::optional<uint32_t> statesToActivate() const noexcept override { return states_.statesToActivate(); }
  uint64_t idleBufferBytes(uint32_t count, bool afterStart, bool keepLane) const noexcept override { return states_.idleBytes(count, afterStart, keepLane); }
  uint64_t releaseIdleBuffer(bool keepLane) noexcept override { return states_.releaseOneIdle(keepLane); }
  std::optional<std::string> provideMask(uint64_t, std::span<const uint32_t>) override { return std::nullopt; }
  void end(uint64_t requestId) override {
    auto found = owners_.find(requestId);
    if (found == owners_.end())
      throw std::logic_error("Qwen test runtime ended an unknown lane");
    const uint32_t slot = found->second;
    states_.releaseLane(slot, requestId);
    owners_.erase(found);
    laneEvents.push_back({requestId, false, slot});
  }

  model::WarmupStepResult warmupPrefill(uint32_t) override { return {}; }
  model::WarmupStepResult warmupDecodeBatch(uint32_t) override { return {}; }
  model::WarmupStepResult warmupCompositeStateRestore() override { return {}; }
  model::ModelMemoryActual actualRuntimeMemory() const override { return {}; }
  model::ModelTelemetry telemetry() const noexcept override { return {}; }

  [[nodiscard]] uint32_t slotFor(uint64_t requestId) const {
    auto found = owners_.find(requestId);
    if (found == owners_.end())
      throw std::logic_error("Qwen test runtime has no lane for request");
    return found->second;
  }

  void rememberNextRestoreIo(std::shared_ptr<std::promise<void>> observer) {
    nextRestoreIoObserver = std::move(observer);
  }

  std::vector<EnginePrefillWork> prefillWork;
  struct LaneEvent final {
    uint64_t requestId;
    bool began;
    uint32_t slot;
  };
  std::vector<LaneEvent> laneEvents;
  std::vector<RestoredQwenValues> successfulRestores;
  std::shared_ptr<std::promise<void>> nextRestoreIoObserver;

private:
  void rememberRestored(uint64_t requestId, uint32_t boundary) {
    const uint32_t slot = slotFor(requestId);
    successfulRestores.push_back(
        {requestId, boundary, states_.metadata(slot).lengths,
         word(states_.current(slot).stateBase),
         word(states_.current(slot).recurrentLayers[0]),
         word(states_.window(slot)), word(states_.window(slot), 4)});
  }

  model::QwenStateStorage &states_;
  std::unordered_map<uint64_t, uint32_t> owners_;
};

void testLayoutFormulas() {
  require(kTargetState.convolutionLayerBytes() == 65'536,
          "GDN convolution layer formula is wrong");
  require(kTargetState.convolutionBytes() == 3'145'728,
          "GDN convolution parity formula is wrong");
  require(kTargetState.recurrentLayerBytes() == 3'145'728,
          "GDN recurrent layer formula is wrong");
  require(kTargetState.recurrentBytes() == 150'994'944,
          "GDN recurrent parity formula is wrong");
  require(kDraftState.tensorBytes() == 4'194'304,
          "draft tensor formula is wrong");
  require(kDraftState.ringBytes() == 41'943'040,
          "draft state formula is wrong");
  // 2048 rows of 5120 4-bit codes and 80 fp16 scale-minimum pairs.
  require(kDraftState.windowBytes() == 5'898'240,
          "context window formula is wrong");
  require(kStateLayout.laneBytes() == 356'122'624,
          "per-lane byte formula is wrong");
  require(uint64_t{model::ExecutionLimits::maximumBatchWidth} *
                  kStateLayout.laneBytes() ==
              1'424'490'496,
          "four-lane byte formula is wrong");
  require(kStateLayout.cachedBytes() == 160'038'912,
          "prefix byte formula is wrong");
  // A bf16 recurrent state takes half the bytes; the convolution rows keep
  // theirs.
  model::CompositeStateLayout bfloat = kStateLayout;
  bfloat.target.format = ops::GdnStateFormat::BFloat16;
  require(bfloat.target.recurrentLayerBytes() == 1'572'864 &&
              bfloat.target.convolutionBytes() == 3'145'728 &&
              bfloat.laneBytes() == 205'127'680 && bfloat.cachedBytes() == 84'541'440,
          "bf16 state byte formula is wrong");
}

void testOffloadAllocationFailure(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  // What a case's storage allocates through the governor is a start's, in
  // its Floor claim (design/M.md L7).
  const test::ClaimScope start(governor, ClaimClass::Floor);
  constexpr model::CompositeStateLayout layout{{1, 3, 128, 1, 128, 128},
                                               {1, 1, 4, 128}};
  const uint64_t slotBytes = model::SlotFile::slotBytesFor(layout.cachedBytes());
  auto budget = std::make_shared<model::DiskBudget>(3 * slotBytes);
  auto file = std::make_shared<model::SlotFile>(slotBytes, budget);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout, file);
  require(static_cast<bool>(storage.tryActivateLane(0, 1)), "fault source activation failed");
  storage.updateLengths(0, published(4096));
  auto source = storage.snapshot(0);
  auto held = file->acquire();
  std::vector<std::byte> bytes(layout.cachedBytes());
  struct Result {
    bool failed;
    std::unique_ptr<StateOffload> transfer;
  };
  for (int failure = 0; failure < 64; ++failure) {
    // Keep the worker behind a barrier so a submitted write cannot finish
    // before the failure path has either drained it or returned unsafely.
    auto reached = std::make_shared<std::promise<void>>();
    std::promise<void> release;
    auto released = release.get_future().share();
    auto barrier = file->read(held, {bytes}, [reached, released] {
      reached->set_value();
      released.wait();
    });
    reached->get_future().wait();
    auto attempt = std::async(std::launch::async, [&] {
      allocationFailureAfter = failure;
      try {
        auto transfer = source->offload({});
        allocationFailureAfter = -1;
        return Result{false, std::move(transfer)};
      } catch (const std::bad_alloc &) {
        allocationFailureAfter = -1;
        return Result{true, {}};
      }
    });
    const bool returned = attempt.wait_for(std::chrono::milliseconds(100)) ==
                          std::future_status::ready;
    // The offload's slot is still held: its write waits behind the barrier.
    const bool pending = budget->usedBytes() > slotBytes;
    release.set_value();
    auto result = attempt.get();
    require(!(result.failed && returned && pending),
            "allocation failure released staging before the submitted write drained");
    if (!result.failed) {
      require(result.transfer && result.transfer->finish(),
              "offload did not recover after allocation failures");
      return;
    }
    require(budget->usedBytes() == slotBytes,
            "failed offload leaked its disk quota");
  }
  throw std::runtime_error("offload allocation failure sweep never reached success");
}

void testDiskRestore(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  model::QwenStateStorage storage(
      backend, governor.allocationAdmission(), kStateLayout,
      std::make_shared<model::SlotFile>(kStateSlotBytes,
                                        std::make_shared<model::DiskBudget>(kStateSlotBytes)));
  require(static_cast<bool>(storage.tryActivateLane(0, 123)), "disk source activation failed");
  const model::GdnParityBuffers &gdn = storage.current(0);
  const metal::MetalBuffer &window = storage.window(0);
  const metal::MetalBuffer &keys = storage.draft(0)[0].keys;
  // Every byte of the state travels through the file; markers alone would
  // not notice a misplaced or truncated span.
  fill(gdn.stateBase, 1);
  word(gdn.stateBase) = 0x12345678;
  fill(window, 2);
  word(window) = 0x0c0c0c0c;
  const auto images = stateImage(storage, 0);
  storage.updateLengths(0, published(4096));
  auto source = storage.snapshot(0);
  auto write = source->offload({});
  require(write != nullptr, "disk offload not admitted");
  auto disk = write->state();
  require(disk && !disk->residentBytes(), "disk state retained resident allocation");
  // The write owns its copy: the source buffers are free before it finishes.
  source.reset();
  require(storage.idleCells() == 1 && storage.idleWindows() == 1 && storage.idleRings() == 0,
          "demotion did not return the source buffers at once");
  releaseAllIdle(storage, false);
  require(finishWhenReady(*write), "disk write failed");
  write.reset();
  const auto beforeRestore = storage.actualAllocatedBytes();
  word(gdn.stateBase) = 0;
  // The rings are the runtime's to compute from the window again.
  word(keys) = 0x5a5a5a5a;
  storage.updateLengths(0, {});
  uint32_t commits = 0;
  auto read = storage.beginRestore(0, *disk, true, {}, [&] { ++commits; });
  require(read && commits == 0, "disk restore committed before IO was consumed");
  require(finishWhenReady(*read) && commits == 1, "disk restore failed");
  require(storage.actualAllocatedBytes() == beforeRestore,
          "restore allocated a second state");
  require(read->finish() && commits == 1,
          "successful disk restore was not commit-once");
  require(storage.actualAllocatedBytes() == beforeRestore,
          "repeated finish allocated another state");
  auto successfulSnapshot = read->snapshot();
  require(successfulSnapshot != nullptr,
          "successful disk restore did not expose its snapshot");
  successfulSnapshot.reset();
  read.reset();
  releaseAllIdle(storage, false);
  require(storage.actualAllocatedBytes() == beforeRestore, "restore allocated a second state");
  require(stateImage(storage, 0) == images, "disk restore did not reproduce every state byte");
  require(word(gdn.stateBase) == 0x12345678 &&
              storage.metadata(0).lengths.targetTokens == 4096,
          "disk state changed target values or metadata");
  require(word(window) == 0x0c0c0c0c && word(keys) == 0x5a5a5a5a,
          "disk state changed the window, or a restore wrote the rings");

  std::promise<void> readCompleted;
  auto completed = readCompleted.get_future();
  commits = 0;
  read = storage.beginRestore(
      0, *disk, true, [&] { readCompleted.set_value(); }, [&] { ++commits; });
  require(read != nullptr, "completed-IO cancellation restore was not created");
  completed.wait();
  require(read->ready(), "restore completion callback preceded ready IO");
  read->cancel();
  require(!read->finish() && commits == 0 && !read->snapshot(),
          "cancelling completed IO allowed FileRestore to commit");
  read.reset();

  read = storage.beginRestore(0, *disk, false, {}, [] {});
  require(finishWhenReady(*read) && storage.metadata(0).lengths.draftLength == 0 &&
              storage.metadata(0).lengths.draftBase == 4096 &&
              storage.metadata(0).lengths.windowEnd == 4096,
          "skipped draft restore retained stale context");
  auto promoted = read->snapshot();
  require(promoted && promoted->residentBytes() == kStateLayout.cachedBytes(),
          "completed disk restore could not create a resident snapshot");
  require(storage.metadata(0).lengths.draftLength == 0,
          "promotion changed the executing request's draft plan");
  word(gdn.stateBase) = 0;
  word(window) = 0;
  bool committed = false;
  require(!storage.beginRestore(0, *promoted, true, {}, [&] { committed = true; }) &&
              committed,
          "a resident restore returned a read or did not commit");
  require(word(gdn.stateBase) == 0x12345678 &&
              storage.metadata(0).lengths.hasCompleteDraftWindow(2048),
          "promotion lost the original complete state when execution skipped draft");
  require(word(window) == 0x0c0c0c0c, "promotion aliased mutable active buffers");
  require(stateImage(storage, 0) == images,
          "promoted snapshot did not reproduce every state byte");
  read.reset();
  disk.reset();
  promoted.reset();
  storage.releaseLane(0, 123);
}

void testRetainableQwenMatchingPrefixGraph(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 64}};
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1, queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  test::TestKvStorage kvStorage{128, 4096, 4};
  KvPool kvPool{kvStorage, 0};
  Cache cache(kvPool, nullptr, nullptr);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout, nullptr);

  constexpr uint64_t seedRequest = 7001;
  constexpr uint64_t lookupRequest = 7002;
  constexpr uint32_t boundary = 64;
  std::vector<uint32_t> prompt(boundary + 1);
  for (uint32_t i = 0; i < prompt.size(); ++i)
    prompt[i] = 0x1000 + i * 17;

  cache.beginRequest(seedRequest);
  require(cache.ensureTokens(seedRequest, boundary).granted(),
          "matching-prefix fixture could not allocate a KV page");
  const uint64_t terminalBlock =
      test::publishBlocks(cache, seedRequest, prompt, boundary, {});
  require(terminalBlock != 0 &&
              cache.blockAt(seedRequest, boundary) == terminalBlock,
          "exact committed prompt did not publish its terminal KV block");

  require(static_cast<bool>(storage.tryActivateLane(0, seedRequest)),
          "matching-prefix source lane activation failed");

  word(storage.current(0).convolutionLayers[0]) = 0x11223344;
  word(storage.current(0).recurrentLayers[0]) = 0x55667788;
  word(storage.draft(0)[0].keys) = 0x10203040;
  word(storage.draft(0)[0].values) = 0x50607080;
  word(storage.window(0)) = 0x10203040;
  word(storage.window(0), 4) = 0x50607080;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});
  std::shared_ptr<const model::QwenCompositeState> snapshot =
      storage.snapshot(0);
  require(snapshot && snapshot->bytes() == layout.cachedBytes(),
          "Qwen snapshot is missing or has the wrong retained footprint");
  const void *sourceGdn = storage.current(0).stateBase.contents();
  const void *sourceDraft = storage.draft(0)[0].keys.contents();
  require(sourceGdn && sourceDraft,
          "Qwen source lane does not expose its allocated buffers");

  cache.publishCompositeState(terminalBlock, snapshot, false);
  cache.endRequest(seedRequest);
  auto published = cache.snapshot();
  require(published.stateCache.entries == 1 &&
              published.stateCache.bytes == layout.cachedBytes() &&
              published.stateCache.pinned == 0,
          "matching KV block did not account one unpinned Qwen publication");

  // Releasing the lane and its idle pool buffers must leave the independent
  // composite backing live and accounted by both Qwen storage and Metal.
  word(storage.current(0).convolutionLayers[0]) = 0xf1f2f3f4;
  word(storage.current(0).recurrentLayers[0]) = 0xf5f6f7f8;
  word(storage.draft(0)[0].keys) = 0xf9fafbfc;
  word(storage.draft(0)[0].values) = 0xfdfeff00;
  storage.releaseLane(0, seedRequest);
  static_cast<void>(releaseAllIdle(storage, false));
  require(storage.actualAllocatedBytes() >= layout.cachedBytes() &&
              backend.memoryStats().allocatedBytes >= layout.cachedBytes(),
          "cached Qwen backing was reclaimed with its source lane");

  cache.beginRequest(lookupRequest);
  auto lookup = cache.lookup(prompt, {});
  require(lookup.kvBoundary == boundary && lookup.state &&
              lookup.resumeBoundary() == boundary &&
              lookup.state->boundary() == boundary,
          "same prompt did not find the state at its exact KV boundary");
  auto leased = std::dynamic_pointer_cast<const model::QwenCompositeState>(
      lookup.state->state());
  require(leased && leased.get() == snapshot.get(),
          "Cache lookup did not lease the published concrete Qwen state");
  require(cache.snapshot().stateCache.pinned == 1,
          "Cache lookup did not pin the state publication");

  require(static_cast<bool>(storage.tryActivateLane(1, lookupRequest)),
          "matching-prefix destination lane activation failed");

  word(storage.next(1).convolutionLayers[0]) = 0xaabbccdd;
  word(storage.next(1).recurrentLayers[0]) = 0xeeff0011;
  const auto destinationInactive = bytesOf(storage.next(1).stateBase);
  require(!storage.beginRestore(1, *leased, true, {}, [] {}), "resident restore unexpectedly started IO");
  require(storage.metadata(1).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              storage.metadata(1).activeParity == 0,
          "leased Qwen state did not restore its logical draft window");
  require(word(storage.current(1).convolutionLayers[0]) == 0x11223344 &&
              word(storage.current(1).recurrentLayers[0]) == 0x55667788 &&
              word(storage.window(1)) == 0x10203040 &&
              word(storage.window(1), 4) == 0x50607080,
          "leased Qwen state lost target GDN or draft key/value data");
  require(sameBytes(storage.next(1).stateBase, destinationInactive),
          "Qwen restore overwrote inactive parity");

  lookup.state.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "releasing the Cache lookup lease did not unpin Qwen state");
  storage.releaseLane(1, lookupRequest);
  cache.endRequest(lookupRequest);
}

void testQwenCacheOffloadWarmLookup(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 64}};
  auto budget = std::make_shared<model::DiskBudget>(model::SlotFile::slotBytesFor(layout.cachedBytes()));
  auto file = std::make_shared<model::SlotFile>(model::SlotFile::slotBytesFor(layout.cachedBytes()), budget);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1, queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  test::TestKvStorage kvStorage{128, 4096, 4};
  KvPool kvPool{kvStorage, 0};
  Cache cache(kvPool, nullptr, budget);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout,
                                  file);

  constexpr uint64_t seedRequest = 7101;
  constexpr uint64_t lookupRequest = 7102;
  constexpr uint32_t boundary = 64;
  std::vector<uint32_t> prompt(boundary + 1);
  for (uint32_t i = 0; i < prompt.size(); ++i)
    prompt[i] = 0x2000 + i * 19;

  cache.beginRequest(seedRequest);
  require(cache.ensureTokens(seedRequest, boundary).granted(),
          "offload fixture could not allocate a KV page");
  const uint64_t terminalBlock =
      test::publishBlocks(cache, seedRequest, prompt, boundary, {});
  require(terminalBlock != 0,
          "offload fixture did not publish the terminal KV block");
  require(static_cast<bool>(storage.tryActivateLane(0, seedRequest)),
          "offload source lane activation failed");

  word(storage.current(0).convolutionLayers[0]) = 0x21324354;
  word(storage.current(0).recurrentLayers[0]) = 0x65768798;
  word(storage.draft(0)[0].keys) = 0x31425364;
  word(storage.draft(0)[0].values) = 0x758697a8;
  word(storage.window(0)) = 0x31425364;
  word(storage.window(0), 4) = 0x758697a8;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});
  auto snapshot = storage.snapshot(0);
  require(snapshot != nullptr,
          "offload fixture could not snapshot the real Qwen lane");
  cache.publishCompositeState(terminalBlock, snapshot, false);
  snapshot.reset();
  cache.endRequest(seedRequest);

  cache.beginRequest(lookupRequest);
  auto pinned = cache.lookup(prompt, {});
  require(pinned.kvBoundary == boundary && pinned.state &&
              pinned.state->boundary() == boundary,
          "matching-prefix lookup did not find the pinned Qwen state");
  auto pinnedQwen =
      std::dynamic_pointer_cast<const model::QwenCompositeState>(
          pinned.state->state());
  require(pinnedQwen && cache.snapshot().stateCache.pinned == 1,
          "lookup did not lease and pin the concrete Qwen publication");
  require(!test::stateStep(cache).gave() && !cache.transfersInFlight() &&
              cache.stateResident(terminalBlock) && budget->usedBytes() == 0,
          "reclaim started an offload or removed a pinned Qwen state");
  require(static_cast<bool>(storage.tryActivateLane(1, lookupRequest)),
          "pinned-state verification lane activation failed");
  require(!storage.beginRestore(1, *pinnedQwen, true, {}, [] {}), "resident restore unexpectedly started IO");
  require(word(storage.current(1).convolutionLayers[0]) == 0x21324354 &&
              word(storage.current(1).recurrentLayers[0]) == 0x65768798 &&
              word(storage.window(1)) == 0x31425364 &&
              word(storage.window(1), 4) == 0x758697a8 &&
              storage.metadata(1).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary},
          "pinned lookup state was not usable for a complete Qwen restore");
  storage.releaseLane(1, lookupRequest);
  pinned.state.reset();
  pinnedQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "releasing the lookup lease did not unpin the Qwen state");

  require(test::stateStep(cache).gave(),
          "unpinned Qwen state was not accepted for disk offload");
  auto pending = cache.snapshot();
  require(!cache.stateResident(terminalBlock) &&
              pending.stateCache.entries == 1 && pending.stateCache.bytes == 0 &&
              pending.stateCache.diskBytes == layout.cachedBytes() &&
              pending.stateCache.offloads == 1 && cache.transfersInFlight(),
          "accepted offload did not transfer ownership to its staging-backed ticket");
  auto pendingLookup = cache.lookup(prompt, {});
  require(pendingLookup.kvBoundary == boundary && !pendingLookup.state,
          "successful-path offload became reusable before completion was collected");
  bool completed = false;
  while (!completed) {
    static_cast<void>(cache.pollTransfers());
    completed = !cache.transfersInFlight();
    if (!completed)
      std::this_thread::yield();
  }
  auto disk = cache.snapshot();
  require(disk.stateCache.entries == 1 && disk.stateCache.bytes == 0 &&
              disk.stateCache.diskBytes == layout.cachedBytes() &&
              disk.stateCache.offloadFailures == 0 && !cache.transfersInFlight() &&
              budget->usedBytes() == model::SlotFile::slotBytesFor(layout.cachedBytes()),
          "completed offload did not leave a successful disk-only publication");

  auto warm = cache.lookup(prompt, {});
  require(warm.kvBoundary == boundary && warm.state &&
              warm.state->boundary() == boundary,
          "same-process lookup did not rediscover the disk-backed state");
  auto warmQwen = std::dynamic_pointer_cast<const model::QwenCompositeState>(
      warm.state->state());
  require(warmQwen && warmQwen->residentBytes() == 0 &&
              cache.snapshot().stateCache.pinned == 1,
          "warm lookup did not lease a disk-backed Qwen state");
  require(static_cast<bool>(storage.tryActivateLane(2, lookupRequest)),
          "disk warm-restore destination activation failed");
  bool committed = false;
  auto restore = storage.beginRestore(2, *warmQwen, true, {},
                                      [&] { committed = true; });
  require(restore != nullptr,
          "disk Qwen warm restore did not start a StateRestore");
  require(finishWhenReady(*restore) && committed,
          "disk Qwen StateRestore did not complete and commit");
  require(storage.metadata(2).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              word(storage.current(2).convolutionLayers[0]) == 0x21324354 &&
              word(storage.current(2).recurrentLayers[0]) == 0x65768798 &&
              word(storage.window(2)) == 0x31425364 &&
              word(storage.window(2), 4) == 0x758697a8,
          "disk warm restore lost target recurrent or draft state");
  restore.reset();
  storage.releaseLane(2, lookupRequest);
  warm.state.reset();
  warmQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "releasing the warm lookup lease did not unpin the disk state");
  cache.endRequest(lookupRequest);
}

void testQwenAsyncOffloadFailureDoesNotPublishWarmState(
    metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 64}};
  auto budget = std::make_shared<model::DiskBudget>(model::SlotFile::slotBytesFor(layout.cachedBytes()));
  auto file = std::make_shared<model::SlotFile>(model::SlotFile::slotBytesFor(layout.cachedBytes()), budget);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1, queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  test::TestKvStorage kvStorage{128, 4096, 4};
  KvPool kvPool{kvStorage, 0};
  Cache cache(kvPool, nullptr, budget);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout,
                                  file);

  constexpr uint64_t seedRequest = 7151;
  constexpr uint64_t lookupRequest = 7152;
  constexpr uint32_t boundary = 64;
  constexpr uint32_t convolutionMarker = 0x13572468;
  constexpr uint32_t recurrentMarker = 0x24681357;
  constexpr uint32_t draftKeysMarker = 0x35792468;
  constexpr uint32_t draftValuesMarker = 0x46813579;
  constexpr model::QwenLogicalLengths lengths{boundary, 0, boundary, boundary};
  std::vector<uint32_t> prompt(boundary + 1);
  for (uint32_t i = 0; i < prompt.size(); ++i)
    prompt[i] = 0x4100 + i * 29;

  cache.beginRequest(seedRequest);
  require(cache.ensureTokens(seedRequest, boundary).granted(),
          "async failure fixture could not allocate its KV boundary");
  const uint64_t terminalBlock =
      test::publishBlocks(cache, seedRequest, prompt, boundary, {});
  require(terminalBlock != 0,
          "async failure fixture did not publish its terminal KV block");
  require(static_cast<bool>(storage.tryActivateLane(0, seedRequest)),
          "async failure source lane activation failed");

  word(storage.current(0).convolutionLayers[0]) = convolutionMarker;
  word(storage.current(0).recurrentLayers[0]) = recurrentMarker;
  word(storage.draft(0)[0].keys) = draftKeysMarker;
  word(storage.draft(0)[0].values) = draftValuesMarker;
  word(storage.window(0)) = draftKeysMarker;
  word(storage.window(0), 4) = draftValuesMarker;
  storage.updateLengths(0, lengths);
  const auto sourceIsIntact = [&] {
    return storage.metadata(0).lengths == lengths &&
           word(storage.current(0).convolutionLayers[0]) == convolutionMarker &&
           word(storage.current(0).recurrentLayers[0]) == recurrentMarker &&
           word(storage.draft(0)[0].keys) == draftKeysMarker &&
           word(storage.draft(0)[0].values) == draftValuesMarker;
  };

  auto state = storage.snapshot(0);
  require(state != nullptr && state->residentBytes() == layout.cachedBytes(),
          "async failure fixture could not make a resident Qwen snapshot");
  cache.publishCompositeState(terminalBlock, state, false);
  state.reset();
  cache.beginRequest(lookupRequest);

  auto initialLookup = cache.lookup(prompt, {});
  require(initialLookup.kvBoundary == boundary && initialLookup.state &&
              initialLookup.state->boundary() == boundary &&
              cache.stateResident(terminalBlock) && !cache.transfersInFlight(),
          "RAM Qwen state was not discoverable before asynchronous reclaim");
  auto initialQwen =
      std::dynamic_pointer_cast<const model::QwenCompositeState>(
          initialLookup.state->state());
  require(initialQwen != nullptr && sourceIsIntact(),
          "initial lookup did not retain the live Qwen source state");
  initialLookup.state.reset();
  initialQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "initial lookup lease was not released before reclaim");

  struct RestoreFileSizeLimit final {
    rlimit original{};
    ~RestoreFileSizeLimit() {
      if (::setrlimit(RLIMIT_FSIZE, &original) != 0)
        std::abort();
    }
  };

  const auto beforeOffload = cache.snapshot().stateCache;
  {
    rlimit originalFileSizeLimit{};
    require(::getrlimit(RLIMIT_FSIZE, &originalFileSizeLimit) == 0,
            "getrlimit(RLIMIT_FSIZE) failed for async offload test");
    const rlim_t halfState = static_cast<rlim_t>(layout.cachedBytes() / 2);
    const rlim_t softLimit =
        originalFileSizeLimit.rlim_max == RLIM_INFINITY
            ? halfState
            : std::min(halfState, originalFileSizeLimit.rlim_max);
    require(softLimit > 0 &&
                static_cast<uint64_t>(softLimit) < layout.cachedBytes(),
            "RLIMIT_FSIZE hard limit cannot represent a positive value smaller than one Qwen state");
    RestoreFileSizeLimit restoreLimit{originalFileSizeLimit};
    rlimit constrained = originalFileSizeLimit;
    constrained.rlim_cur = softLimit;
    require(::setrlimit(RLIMIT_FSIZE, &constrained) == 0,
            "setrlimit(RLIMIT_FSIZE) could not install the deterministic Qwen write limit");

    require(test::stateStep(cache).gave(),
            "StateCache did not accept asynchronous Qwen offload");
    const CacheSnapshot accepted = cache.snapshot();
    require(cache.transfersInFlight() &&
                accepted.stateCache.offloads == beforeOffload.offloads + 1 &&
                !cache.stateResident(terminalBlock) &&
                accepted.stateCache.bytes == 0,
            "accepted offload did not transfer the RAM publication to its in-flight write");

    auto pendingLookup = cache.lookup(prompt, {});
    require(pendingLookup.kvBoundary == boundary && !pendingLookup.state,
            "exact-prompt lookup exposed the pending disk object as reusable Qwen state");
    pendingLookup.state.reset();

    while (cache.transfersInFlight()) {
      static_cast<void>(cache.pollTransfers());
      if (cache.transfersInFlight())
        std::this_thread::yield();
    }
  }

  const CacheSnapshot failed = cache.snapshot();
  require(failed.stateCache.offloadFailures ==
                  beforeOffload.offloadFailures + 1 &&
              !cache.transfersInFlight() && failed.stateCache.entries == 0 &&
              failed.stateCache.diskBytes == 0 &&
              failed.stateCache.publications ==
                  beforeOffload.publications &&
              !cache.transfersInFlight() && !file->writable() && budget->usedBytes() == 0,
          "failed async Qwen completion remained published or retained its SlotFile quota");

  auto cold = cache.lookup(prompt, {});
  require(cold.kvBoundary == boundary && !cold.state && cold.lostState,
          "failed async Qwen state did not fall cold at its retained KV boundary");
  cold.state.reset();
  require(sourceIsIntact(),
          "failed asynchronous offload changed the original live Qwen source lane");

  auto retrySnapshot = storage.snapshot(0);
  require(retrySnapshot != nullptr &&
              retrySnapshot->residentBytes() == layout.cachedBytes(),
          "valid source lane could not produce a fresh RAM retry snapshot");
  cache.publishCompositeState(terminalBlock, retrySnapshot, false);
  retrySnapshot.reset();
  auto retry = cache.lookup(prompt, {});
  require(retry.kvBoundary == boundary && retry.state &&
              retry.state->boundary() == boundary &&
              cache.stateResident(terminalBlock),
          "fresh RAM retry publication was not reusable at the retained boundary");
  auto retryQwen = std::dynamic_pointer_cast<const model::QwenCompositeState>(
      retry.state->state());
  require(retryQwen != nullptr && retryQwen->residentBytes() == layout.cachedBytes() &&
              sourceIsIntact() &&
              static_cast<bool>(storage.tryActivateLane(1, lookupRequest)),
          "fresh Cache retry did not retain the original resident Qwen state");
  require(!storage.beginRestore(1, *retryQwen, true, {}, [] {}), "resident restore unexpectedly started IO");
  require(storage.metadata(1).lengths == lengths &&
              word(storage.current(1).convolutionLayers[0]) ==
                  convolutionMarker &&
              word(storage.current(1).recurrentLayers[0]) == recurrentMarker &&
              word(storage.window(1)) == draftKeysMarker &&
              word(storage.window(1), 4) == draftValuesMarker,
          "fresh RAM retry did not restore the original Qwen markers and lengths");

  storage.releaseLane(1, lookupRequest);
  retry.state.reset();
  retryQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "retry lookup lease was not released after source verification");
  storage.releaseLane(0, seedRequest);
  cache.endRequest(seedRequest);
  cache.endRequest(lookupRequest);
}

std::vector<EnginePrefillWork>
prefillWorkFor(const QwenEngineTestRuntimeModel &model, uint64_t requestId) {
  std::vector<EnginePrefillWork> work;
  std::copy_if(model.prefillWork.begin(), model.prefillWork.end(),
               std::back_inserter(work), [requestId](const auto &entry) {
                 return entry.requestId == requestId;
               });
  return work;
}

std::vector<EngineStarted>
startedFor(const QwenEngineEventCollector &events, uint64_t requestId) {
  std::vector<EngineStarted> started;
  std::copy_if(events.startedEvents.begin(), events.startedEvents.end(),
               std::back_inserter(started), [requestId](const auto &entry) {
                 return entry.requestId == requestId;
               });
  return started;
}

std::vector<EngineProgress>
progressFor(const QwenEngineEventCollector &events, uint64_t requestId) {
  std::vector<EngineProgress> progress;
  std::copy_if(events.progressEvents.begin(), events.progressEvents.end(),
               std::back_inserter(progress), [requestId](const auto &entry) {
                 return entry.requestId == requestId;
               });
  return progress;
}

std::vector<EngineDone>
doneFor(const QwenEngineEventCollector &events, uint64_t requestId) {
  std::vector<EngineDone> done;
  std::copy_if(events.doneEvents.begin(), events.doneEvents.end(),
               std::back_inserter(done), [requestId](const auto &entry) {
                 return entry.requestId == requestId;
               });
  return done;
}

void finishEngineRequest(Engine &engine, double now,
                         const char *failureMessage) {
  for (unsigned step = 0; step < 12 && !engine.idle(); ++step)
    static_cast<void>(engine.tick(now + step));
  require(engine.idle(), failureMessage);
}

EngineRequest qwenEngineRequest(uint64_t id,
                                const std::vector<uint32_t> &prompt) {
  EngineRequest request;
  request.id = id;
  request.prompt = prompt;
  request.generationPromptTokens = static_cast<uint32_t>(prompt.size() - 1);
  request.maxNewTokens = 1;
  request.deadlineMilliseconds = 100'000;
  request.returnProgress = true;
  return request;
}

void testQwenDiskRestoreTransactionThroughEngine(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 64}};
  constexpr uint32_t boundary = 64;
  constexpr uint32_t sourceGdn = 0x11223344;
  constexpr uint32_t sourceRecurrent = 0x55667788;
  constexpr uint32_t sourceDraftKeys = 0x10203040;
  constexpr uint32_t sourceDraftValues = 0x50607080;
  constexpr uint64_t seedRequest = 7400;
  constexpr uint64_t warmRequest = 7401;
  constexpr uint64_t failedRequest = 7402;
  constexpr uint64_t retryRequest = 7403;

  auto budget = std::make_shared<model::DiskBudget>(model::SlotFile::slotBytesFor(layout.cachedBytes()));
  auto file = std::make_shared<model::SlotFile>(model::SlotFile::slotBytesFor(layout.cachedBytes()), budget);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1, queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  test::TestKvStorage kvStorage{128, 4096, 4};
  KvPool kvPool{kvStorage, 0};
  Cache cache(kvPool, nullptr, budget);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout,
                                  file);

  std::vector<uint32_t> prompt(boundary + 5);
  for (uint32_t i = 0; i < prompt.size(); ++i)
    prompt[i] = 0x6000 + i * 31;
  cache.beginRequest(seedRequest);
  require(cache.ensureTokens(seedRequest, boundary).granted(),
          "Engine Qwen fixture could not allocate the retained KV prefix");
  const uint64_t terminalBlock =
      test::publishBlocks(cache, seedRequest, prompt, boundary, {});
  require(terminalBlock != 0 &&
              cache.blockAt(seedRequest, boundary) == terminalBlock,
          "Engine Qwen fixture did not publish its complete retained KV page");
  require(static_cast<bool>(storage.tryActivateLane(0, seedRequest)),
          "Engine Qwen fixture could not activate its source lane");

  word(storage.current(0).stateBase) = sourceGdn;
  word(storage.current(0).recurrentLayers[0]) = sourceRecurrent;
  word(storage.window(0)) = sourceDraftKeys;
  word(storage.window(0), 4) = sourceDraftValues;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});
  require(cache.publishStateToDisk(
              terminalBlock,
              [&](std::function<void()> completion) {
                return storage.snapshotToDisk(0, std::move(completion));
              }, false),
          "real Qwen state was not admitted to the retained disk tier");
  while (cache.transfersInFlight()) {
    static_cast<void>(cache.pollTransfers());
    if (cache.transfersInFlight())
      std::this_thread::yield();
  }
  storage.releaseLane(0, seedRequest);
  cache.endRequest(seedRequest);
  require(!cache.transfersInFlight() && budget->usedBytes() == model::SlotFile::slotBytesFor(layout.cachedBytes()),
          "retained Qwen SlotFile publication did not finish");

  CacheLookup precondition = cache.lookup(prompt, {});
  require(precondition.kvBoundary == boundary && precondition.state &&
              precondition.state->boundary() == boundary,
          "Cache lookup did not find the retained Qwen state at its KV boundary");
  auto retainedQwen =
      std::dynamic_pointer_cast<const model::QwenCompositeState>(
          precondition.state->state());
  require(retainedQwen && retainedQwen->residentBytes() == 0,
          "retained Qwen source is not disk-backed");
  const CompositeState *retainedSource = retainedQwen.get();
  precondition.state.reset();

  QwenEngineTestRuntimeModel model(storage);
  QwenEngineEventCollector events;
  EngineConfig config;
  config.maxContext = 1024;
  config.vocabularySize = 65'536;
  config.governor = &governor;
  engine::WriteBehind persistence(cache);
  Engine engine(config, cache, persistence, model, events);

  // Proof A: the first ordinary Engine admission restores the real disk state
  // and starts actual model work after the retained page boundary.
  auto warmIo = std::make_shared<std::promise<void>>();
  auto warmIoDone = warmIo->get_future();
  model.rememberNextRestoreIo(warmIo);
  engine.submit(qwenEngineRequest(warmRequest, prompt));
  require(engine.tick(0.0), "warm Engine request did not begin admission");
  warmIoDone.wait();
  require(startedFor(events, warmRequest).empty(),
          "Engine published a warm Started event before restore finish");
  require(engine.tick(1.0), "warm Engine restore safe point did not progress");
  finishEngineRequest(engine, 2.0,
                      "warm Engine request did not finish after Qwen restore");
  const auto afterWarm = engine.snapshot();
  require(afterWarm.cacheHits == 1 && afterWarm.reusedTokens == boundary &&
              afterWarm.coldMisses == 0,
          "warm Engine admission did not count exactly its retained boundary");
  const auto warmStarted = startedFor(events, warmRequest);
  require(warmStarted.size() == 1 &&
              warmStarted.front().matchedTokens == boundary,
          "warm Engine Started event did not report the retained boundary");
  const auto warmProgress = progressFor(events, warmRequest);
  require(warmProgress.size() >= 2 && warmProgress.front().tokens == boundary,
          "warm Engine progress did not begin at the retained boundary");
  const auto warmWork = prefillWorkFor(model, warmRequest);
  require(!warmWork.empty() && warmWork.front().logicalPosition == boundary,
          "first warm Engine prefill did not start at the retained boundary");
  uint64_t warmRows = 0;
  for (const auto &work : warmWork) {
    require(work.logicalPosition >= boundary,
            "warm Engine replayed a preserved-prefix prefill row");
    warmRows += work.tokenCount;
  }
  require(warmRows == prompt.size() - boundary &&
              events.prefillRows == warmRows,
          "warm Engine prefill rows did not equal only the nonempty suffix");
  const auto warmDone = doneFor(events, warmRequest);
  require(warmDone.size() == 1 &&
              warmDone.front().reason == EngineFinishReason::Length,
          "warm Engine request did not reach one successful Done event");
  require(model.successfulRestores.size() == 1 &&
              model.successfulRestores.back().requestId == warmRequest &&
              model.successfulRestores.back().boundary == boundary &&
              model.successfulRestores.back().lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              model.successfulRestores.back().gdnMarker == sourceGdn &&
              model.successfulRestores.back().recurrentMarker ==
                  sourceRecurrent &&
              model.successfulRestores.back().windowMarker0 ==
                  sourceDraftKeys &&
              model.successfulRestores.back().windowMarker4 ==
                  sourceDraftValues,
          "real FileRestore did not restore GDN, recurrent, draft, and logical state");

  // A successful optional promotion may add a RAM copy. Drop only that
  // redundant copy so Proof B again exercises the same immutable disk source.
  require(test::stateStep(cache).gave(),
          "could not return the successful warm promotion to disk-only form");
  CacheLookup diskAgain = cache.lookup(prompt, {});
  require(diskAgain.kvBoundary == boundary && diskAgain.state &&
              diskAgain.state->state().get() == retainedSource &&
              diskAgain.state->state()->residentBytes() == 0,
          "warm proof did not leave the original retained disk source in Cache");
  diskAgain.state.reset();

  // Proof B: wait for the actual SlotFile read, alter only the destination,
  // and let Engine consume FileRestore::finish() at its next safe point.
  const auto beforeFailure = engine.snapshot();
  const auto cacheBeforeFailure = cache.snapshot();
  auto failedIo = std::make_shared<std::promise<void>>();
  auto failedIoDone = failedIo->get_future();
  model.rememberNextRestoreIo(failedIo);
  engine.submit(qwenEngineRequest(failedRequest, prompt));
  require(engine.tick(10.0), "failure-proof request did not start Qwen restore");
  failedIoDone.wait();
  require(!cache.transfersInFlight(),
          "restore completion observer ran before SlotFile IO became idle");
  require(startedFor(events, failedRequest).empty(),
          "failed restore admission published Started before finish()");
  const uint32_t failedSlot = model.slotFor(failedRequest);
  auto *destinationBytes = static_cast<uint8_t *>(
      storage.current(failedSlot).stateBase.contents());
  require(destinationBytes != nullptr,
          "failed restore destination is not CPU-visible");
  destinationBytes[0] ^= 0x01;
  require(engine.tick(11.0),
          "Engine did not consume and recover from failed FileRestore");
  require(model.successfulRestores.size() == 1,
          "failed FileRestore committed or exposed a destination snapshot");
  const auto failedStarted = startedFor(events, failedRequest);
  require(failedStarted.size() == 1 &&
              failedStarted.front().matchedTokens == 0,
          "failed FileRestore emitted a warm PrefixHit instead of cold fallback");
  finishEngineRequest(engine, 12.0,
                      "failed-restore request did not finish its cold fallback");
  const auto failedDone = doneFor(events, failedRequest);
  require(failedDone.size() == 1 && failedDone.front().promptTokens == prompt.size(),
          "failed-restore request did not complete after cold fallback");
  const auto failedWork = prefillWorkFor(model, failedRequest);
  require(!failedWork.empty() && failedWork.front().logicalPosition == 0,
          "failed-restore request did not fall back to cold prefill from zero");
  uint64_t failedRows = 0;
  for (const auto &work : failedWork)
    failedRows += work.tokenCount;
  require(failedRows == prompt.size(),
          "cold fallback did not submit the full prompt after restore failure");
  const auto afterFailure = engine.snapshot();
  require(afterFailure.cacheHits == beforeFailure.cacheHits &&
              afterFailure.reusedTokens == beforeFailure.reusedTokens &&
              afterFailure.coldMisses == beforeFailure.coldMisses + 1,
          "failed restore was counted as warm before its cold fallback");
  const auto cacheAfterFailure = cache.snapshot();
  require(cacheAfterFailure.stateCache.entries ==
                  cacheBeforeFailure.stateCache.entries &&
              cacheAfterFailure.stateCache.diskBytes == layout.cachedBytes() &&
              cacheAfterFailure.stateCache.invalidations ==
                  cacheBeforeFailure.stateCache.invalidations &&
              cacheAfterFailure.stateCache.promotions ==
                  cacheBeforeFailure.stateCache.promotions &&
              cacheAfterFailure.stateCache.publications ==
                  cacheBeforeFailure.stateCache.publications &&
              cacheAfterFailure.stateCache.pinned == 0 && !cache.transfersInFlight() &&
              budget->usedBytes() == model::SlotFile::slotBytesFor(layout.cachedBytes()),
          "failed destination restore invalidated, promoted, or mutated the source");
  std::vector<QwenEngineTestRuntimeModel::LaneEvent> failedLaneEvents;
  std::copy_if(model.laneEvents.begin(), model.laneEvents.end(),
               std::back_inserter(failedLaneEvents), [failedRequest](const auto &entry) {
                 return entry.requestId == failedRequest;
               });
  require(failedLaneEvents.size() == 4 && failedLaneEvents[0].began &&
              !failedLaneEvents[1].began && failedLaneEvents[2].began &&
              !failedLaneEvents[3].began &&
              failedLaneEvents[0].slot == failedLaneEvents[1].slot &&
              failedLaneEvents[2].slot == failedLaneEvents[3].slot,
          "failed destination lane was not released before the cold retry");
  CacheLookup retryable = cache.lookup(prompt, {});
  require(retryable.kvBoundary == boundary && retryable.state &&
              retryable.state->boundary() == boundary &&
              retryable.state->state().get() == retainedSource &&
              retryable.state->state()->residentBytes() == 0,
          "valid immutable source was not discoverable after cold fallback");
  retryable.state.reset();

  // Proof C: a new request retries that same disk object without corruption.
  const auto beforeRetry = engine.snapshot();
  auto retryIo = std::make_shared<std::promise<void>>();
  auto retryIoDone = retryIo->get_future();
  model.rememberNextRestoreIo(retryIo);
  engine.submit(qwenEngineRequest(retryRequest, prompt));
  require(engine.tick(20.0), "later warm request did not start Qwen restore");
  retryIoDone.wait();
  require(engine.tick(21.0), "later warm restore safe point did not progress");
  finishEngineRequest(engine, 22.0,
                      "later warm retry did not finish after valid FileRestore");
  const auto afterRetry = engine.snapshot();
  require(afterRetry.cacheHits == beforeRetry.cacheHits + 1 &&
              afterRetry.reusedTokens == beforeRetry.reusedTokens + boundary &&
              afterRetry.coldMisses == beforeRetry.coldMisses,
          "later warm retry did not reuse exactly the retained boundary");
  const auto retryStarted = startedFor(events, retryRequest);
  require(retryStarted.size() == 1 &&
              retryStarted.front().matchedTokens == boundary,
          "later warm retry did not publish a PrefixHit at the retained boundary");
  const auto retryProgress = progressFor(events, retryRequest);
  require(retryProgress.size() >= 2 &&
              retryProgress.front().tokens == boundary,
          "later warm retry progress did not start at the retained boundary");
  const auto retryWork = prefillWorkFor(model, retryRequest);
  require(!retryWork.empty() && retryWork.front().logicalPosition == boundary,
          "later warm retry replayed prefill from zero");
  uint64_t retryRows = 0;
  for (const auto &work : retryWork) {
    require(work.logicalPosition >= boundary,
            "later warm retry submitted preserved-prefix rows");
    retryRows += work.tokenCount;
  }
  require(retryRows == prompt.size() - boundary,
          "later warm retry prefill included preserved-prefix rows");
  const auto retryDone = doneFor(events, retryRequest);
  require(retryDone.size() == 1 && retryDone.front().promptTokens == prompt.size(),
          "later warm retry did not produce one successful Done event");
  require(model.successfulRestores.size() == 2 &&
              model.successfulRestores.back().requestId == retryRequest &&
              model.successfulRestores.back().boundary == boundary &&
              model.successfulRestores.back().lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              model.successfulRestores.back().gdnMarker == sourceGdn &&
              model.successfulRestores.back().recurrentMarker ==
                  sourceRecurrent &&
              model.successfulRestores.back().windowMarker0 ==
                  sourceDraftKeys &&
              model.successfulRestores.back().windowMarker4 ==
                  sourceDraftValues,
          "later warm retry did not restore the original Qwen source values");
  require(!cache.transfersInFlight() && budget->usedBytes() == model::SlotFile::slotBytesFor(layout.cachedBytes()),
          "successful retry damaged the retained SlotFile source");
}

void testCorruptQwenDiskPayloadFallsBackCold(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 64}};
  constexpr uint32_t boundary = 64;
  constexpr uint64_t seedRequest = 7301;
  constexpr uint64_t restoreRequest = 7302;
  auto budget = std::make_shared<model::DiskBudget>(model::SlotFile::slotBytesFor(layout.cachedBytes()));
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1, queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  test::TestKvStorage kvStorage{128, 4096, 4};
  KvPool kvPool{kvStorage, 0};
  const auto before = unlinkedRegularDescriptors();
  auto file = std::make_shared<model::SlotFile>(model::SlotFile::slotBytesFor(layout.cachedBytes()), budget);
  const auto after = unlinkedRegularDescriptors();
  std::vector<int> added;
  std::set_difference(after.begin(), after.end(), before.begin(), before.end(),
                      std::back_inserter(added));
  require(added.size() == 1,
          "could not uniquely identify the Qwen SlotFile descriptor");
  const int descriptor = added.front();

  Cache cache(kvPool, nullptr, budget);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout,
                                  file);
  std::vector<uint32_t> prompt(boundary + 1);
  for (uint32_t i = 0; i < prompt.size(); ++i)
    prompt[i] = 0x4000 + i * 29;
  cache.beginRequest(seedRequest);
  require(cache.ensureTokens(seedRequest, boundary).granted(),
          "corruption fixture could not allocate a KV page");
  const uint64_t terminalBlock =
      test::publishBlocks(cache, seedRequest, prompt, boundary, {});
  require(terminalBlock != 0,
          "corruption fixture did not publish its KV terminal block");
  require(static_cast<bool>(storage.tryActivateLane(0, seedRequest)),
          "corruption source lane activation failed");

  word(storage.current(0).stateBase) = 0x12345678;
  word(storage.draft(0)[0].keys) = 0x23456789;
  word(storage.draft(0)[0].values) = 0x3456789a;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});

  require(cache.publishStateToDisk(
              terminalBlock,
              [&](std::function<void()> completion) {
                return storage.snapshotToDisk(0, std::move(completion));
              }, false),
          "real Qwen state did not publish to disk");
  while (cache.transfersInFlight())
    static_cast<void>(cache.pollTransfers());
  require(budget->usedBytes() == model::SlotFile::slotBytesFor(layout.cachedBytes()) && !cache.transfersInFlight(),
          "Qwen disk publication did not complete into its slot");

  auto warm = cache.lookup(prompt, {});
  require(warm.kvBoundary == boundary && warm.state,
          "same prompt did not lease the completed disk Qwen state");
  auto warmQwen = std::dynamic_pointer_cast<const model::QwenCompositeState>(
      warm.state->state());
  require(warmQwen && warmQwen->residentBytes() == 0,
          "published corruption fixture is not disk-only");

  uint8_t original = 0;
  require(pread(descriptor, &original, 1, 0) == 1,
          "could not read one payload byte for corruption injection");
  const uint8_t corrupted = original ^ 0x01;
  require(pwrite(descriptor, &corrupted, 1, 0) == 1,
          "could not write one corrupted payload byte");

  require(static_cast<bool>(storage.tryActivateLane(1, restoreRequest)),
          "corruption destination lane activation failed");
  bool committed = false;
  auto restore = storage.beginRestore(1, *warmQwen, true, {},
                                      [&] { committed = true; });
  require(restore != nullptr,
          "corrupted disk Qwen state did not create a restore ticket");
  while (!restore->ready()) std::this_thread::yield();
  require(!restore->finish() && !committed && !restore->snapshot(),
          "same-length corrupted Qwen payload was committed or promoted");
  require(!restore->finish() && !committed && !restore->snapshot(),
          "failed Qwen restore became successful on a repeated finish");

  const CompositeState *badState = warmQwen.get();
  cache.discardState(terminalBlock, badState);
  restore.reset();
  warm.state.reset();
  warmQwen.reset();
  auto cold = cache.lookup(prompt, {});
  require(cold.kvBoundary == boundary && !cold.state,
          "corrupt composite state remained available to exact-prompt lookup");
  require(cold.lostState,
          "discarded corrupt state was not reported as a lost-state cold miss");
  cache.endRequest(seedRequest);
  cache.endRequest(restoreRequest);
}

void testQwenQuotaRefusalDoesNotPublishAndRetries(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 64}};
  auto budget = std::make_shared<model::DiskBudget>(model::SlotFile::slotBytesFor(layout.cachedBytes()));
  auto file = std::make_shared<model::SlotFile>(model::SlotFile::slotBytesFor(layout.cachedBytes()), budget);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1, queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  test::TestKvStorage kvStorage{128, 4096, 4};
  KvPool kvPool{kvStorage, 0};
  Cache cache(kvPool, nullptr, budget);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout,
                                  file);

  constexpr uint64_t seedRequest = 7201;
  constexpr uint64_t lookupRequest = 7202;
  constexpr uint32_t boundary = 64;
  std::vector<uint32_t> prompt(boundary + 1);
  for (uint32_t i = 0; i < prompt.size(); ++i)
    prompt[i] = 0x3000 + i * 23;
  cache.beginRequest(seedRequest);
  require(cache.ensureTokens(seedRequest, boundary).granted(),
          "quota fixture could not allocate a KV page");
  const uint64_t terminalBlock =
      test::publishBlocks(cache, seedRequest, prompt, boundary, {});
  require(terminalBlock != 0,
          "quota fixture did not publish the terminal KV block");
  require(static_cast<bool>(storage.tryActivateLane(0, seedRequest)),
          "quota source lane activation failed");

  word(storage.current(0).convolutionLayers[0]) = 0x41526374;
  word(storage.current(0).recurrentLayers[0]) = 0x8596a7b8;
  word(storage.draft(0)[0].keys) = 0x51627384;
  word(storage.draft(0)[0].values) = 0x95a6b7c8;
  word(storage.window(0)) = 0x51627384;
  word(storage.window(0), 4) = 0x95a6b7c8;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});
  auto occupiedSlot = file->acquire();
  require(occupiedSlot && budget->usedBytes() == model::SlotFile::slotBytesFor(layout.cachedBytes()),
          "could not deterministically occupy the sole Qwen disk slot");

  const auto before = cache.snapshot().stateCache;
  const bool refused = cache.publishStateToDisk(
      terminalBlock,
      [&](std::function<void()> completion) {
        return storage.snapshotToDisk(0, std::move(completion));
      }, false);
  const auto afterRefusal = cache.snapshot();
  require(!refused && afterRefusal.stateCache.entries == before.entries &&
              afterRefusal.stateCache.publications == before.publications &&
              afterRefusal.stateCache.diskBytes == before.diskBytes &&
              !afterRefusal.stateCache.bytes && !cache.transfersInFlight() &&
              budget->usedBytes() == model::SlotFile::slotBytesFor(layout.cachedBytes()),
          "quota refusal created a StateCache publication or transfer");
  auto coldLookup = cache.lookup(prompt, {});
  require(coldLookup.kvBoundary == boundary && !coldLookup.state,
          "quota refusal produced a false warm state in exact-prompt lookup");
  require(storage.metadata(0).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              word(storage.current(0).convolutionLayers[0]) == 0x41526374 &&
              word(storage.current(0).recurrentLayers[0]) == 0x8596a7b8 &&
              word(storage.draft(0)[0].keys) == 0x51627384 &&
              word(storage.draft(0)[0].values) == 0x95a6b7c8,
          "quota refusal damaged the retryable source lane");
  coldLookup.state.reset();
  occupiedSlot.reset();
  require(budget->usedBytes() == 0,
          "releasing the quota holder did not restore the slot budget");

  const bool accepted = cache.publishStateToDisk(
      terminalBlock,
      [&](std::function<void()> completion) {
        return storage.snapshotToDisk(0, std::move(completion));
      }, false);
  require(accepted && cache.transfersInFlight() &&
              cache.snapshot().stateCache.publications ==
                  before.publications + 1,
          "retry of the same source lane was not accepted as one publication");
  bool completed = false;
  while (!completed) {
    static_cast<void>(cache.pollTransfers());
    completed = !cache.transfersInFlight();
    if (!completed)
      std::this_thread::yield();
  }
  auto warm = cache.lookup(prompt, {});
  require(warm.kvBoundary == boundary && warm.state &&
              warm.state->boundary() == boundary,
          "retry publication was not discoverable through the same KV prefix");
  auto warmQwen = std::dynamic_pointer_cast<const model::QwenCompositeState>(
      warm.state->state());
  require(warmQwen && warmQwen->residentBytes() == 0,
          "retry publication did not produce a disk-backed Qwen state");
  require(static_cast<bool>(storage.tryActivateLane(1, lookupRequest)),
          "quota retry restore lane activation failed");
  bool committed = false;
  auto restore = storage.beginRestore(1, *warmQwen, true, {},
                                      [&] { committed = true; });
  require(restore != nullptr && finishWhenReady(*restore) && committed,
          "retry publication did not restore from its disk snapshot");
  require(storage.metadata(1).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              word(storage.current(1).convolutionLayers[0]) == 0x41526374 &&
              word(storage.current(1).recurrentLayers[0]) == 0x8596a7b8 &&
              word(storage.window(1)) == 0x51627384 &&
              word(storage.window(1), 4) == 0x95a6b7c8,
          "quota retry restore lost target recurrent or draft state");
  restore.reset();
  storage.releaseLane(1, lookupRequest);
  warm.state.reset();
  warmQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "releasing the quota retry lease did not unpin its state");
  storage.releaseLane(0, seedRequest);
  cache.endRequest(seedRequest);
  cache.endRequest(lookupRequest);
}

// A lane whose state no cache slot can hold writes it from its own cells: no
// cache buffer is taken, the disk copy restores every byte of the active
// parity, and a full quota refuses until a disk copy is dropped.
void testDirectDiskSnapshot(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  model::QwenStateStorage storage(
      backend, governor.allocationAdmission(), kStateLayout,
      std::make_shared<model::SlotFile>(kStateSlotBytes,
                                        std::make_shared<model::DiskBudget>(kStateSlotBytes)));
  require(storage.canSnapshotToDisk(false), "a state file that holds one state refuses writes");
  require(static_cast<bool>(storage.tryActivateLane(0, 321)), "lane activation failed");
  storage.swapParity(0);
  const model::GdnParityBuffers &current = storage.current(0);
  const model::GdnParityBuffers &next = storage.next(0);
  fill(next.stateBase, 8);
  fill(current.stateBase, 7);
  word(current.stateBase) = 0x0badf00d;
  fill(storage.window(0), 20);
  const auto inactive = bytesOf(next.stateBase);
  const auto images = stateImage(storage, 0);
  storage.updateLengths(0, published(4096));
  const uint64_t before = storage.actualAllocatedBytes();
  auto write = storage.snapshotToDisk(0, {});
  require(write != nullptr, "direct disk snapshot was not admitted");
  require(storage.actualAllocatedBytes() == before && storage.idleCells() == 0 &&
              storage.idleWindows() == 0,
          "direct disk snapshot took a cache slot");
  auto disk = write->state();
  require(disk && !disk->residentBytes() && disk->bytes() == kStateLayout.cachedBytes(),
          "the ticket does not carry a disk copy");
  // The write reads staging, so the lane may move on at once.
  word(current.stateBase) = 0;
  require(finishWhenReady(*write), "direct disk write failed");
  write.reset();
  require(storage.snapshotToDisk(0, {}) == nullptr, "a full quota admitted a second state");

  fill(current.stateBase, 99);
  fill(storage.window(0), 98);
  storage.updateLengths(0, {});
  bool committed = false;
  auto read = storage.beginRestore(0, *disk, true, {}, [&] { committed = true; });
  require(finishWhenReady(*read) && committed, "restore of the direct disk copy failed");
  read.reset();
  require(stateImage(storage, 0) == images &&
              word(current.stateBase) == 0x0badf00d &&
              storage.metadata(0).lengths.targetTokens == 4096,
          "the disk copy did not reproduce the lane's active state");
  require(sameBytes(next.stateBase, inactive), "the inactive parity was touched");
  disk.reset();
  auto again = storage.snapshotToDisk(0, {});
  require(again != nullptr, "the dropped disk copy did not free its quota");
  require(finishWhenReady(*again), "the second direct disk write failed");
  again.reset();
  storage.releaseLane(0, 321);
}

// A state's write, from a lane or from a cached copy, takes its slot from
// the write budget. Overdrawn, the budget holds back writes not in use
// until it refills, and lets those in use pass.
void testStateWritesDrawOnTheWriteBudget(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  double now = 0.0;
  auto budget = std::make_shared<model::DiskBudget>(4 * kStateSlotBytes, [&now] { return now; });
  // Two slots a day, half a slot at once.
  budget->setWriteBudget(2 * kStateSlotBytes);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), kStateLayout,
                                  std::make_shared<model::SlotFile>(kStateSlotBytes, budget));
  require(static_cast<bool>(storage.tryActivateLane(0, 456)), "lane activation failed");
  storage.updateLengths(0, published(4096));
  auto cached = storage.snapshot(0);
  require(cached && storage.canSnapshotToDisk(false) && cached->canOffload(false),
          "a write budget with room held a state back");
  auto write = storage.snapshotToDisk(0, {});
  require(write && finishWhenReady(*write), "the lane's state was not written");
  require(!storage.canSnapshotToDisk(false) && storage.canSnapshotToDisk(true) &&
              !cached->canOffload(false) && cached->canOffload(true),
          "an overdrawn write budget did not hold back only what is not in use");
  now = 86'400'000.0 / 4 + 1.0;
  require(storage.canSnapshotToDisk(false) && cached->canOffload(false),
          "the write budget did not admit writes once it refilled");
  write.reset();
  cached.reset();
  storage.releaseLane(0, 456);
}

// A state need not fill its slot: it comes back exactly from a slot one host
// page larger than an aligned state and from the rounded-up slot of a state
// that is not aligned. slot_file_test checks that a write stores only the
// pages its state reaches.
void testStateSmallerThanSlot(metal::MetalBackend &backend) {
  constexpr model::GdnStateLayout target{1, 3, 128, 1, 128, 128};
  constexpr model::CompositeStateLayout aligned{target, {1, 1, 4, 128}};
  constexpr model::CompositeStateLayout unaligned{target, {1, 1, 1, 64}};
  static_assert(aligned.cachedBytes() % kHostPageBytes == 0 &&
                unaligned.cachedBytes() % kHostPageBytes != 0);
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  for (const auto &[layout, slotBytes] :
       {std::pair{aligned, aligned.cachedBytes() + kHostPageBytes},
        std::pair{unaligned, model::SlotFile::slotBytesFor(unaligned.cachedBytes())}}) {
    model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout,
                                    std::make_shared<model::SlotFile>(
                                        slotBytes, std::make_shared<model::DiskBudget>(slotBytes)));
    require(static_cast<bool>(storage.tryActivateLane(0, 77)), "lane activation failed");
    const model::GdnParityBuffers &gdn = storage.current(0);
    fill(gdn.stateBase, 31);
    fill(storage.window(0), 32);
    const auto images = stateImage(storage, 0);
    storage.updateLengths(0, published(4096));
    auto write = storage.snapshotToDisk(0, {});
    require(write && finishWhenReady(*write), "a state did not reach a larger slot");
    auto disk = write->state();
    write.reset();

    fill(gdn.stateBase, 34);
    fill(storage.window(0), 35);
    storage.updateLengths(0, {});
    auto read = storage.beginRestore(0, *disk, true, {}, [] {});
    require(read && finishWhenReady(*read) && stateImage(storage, 0) == images,
            "a state did not come back exactly from a larger slot");
    read.reset();
    disk.reset();
    storage.releaseLane(0, 77);
  }
}

// A persistent tier keeps a written state's slot and label for the next
// process, whose storage takes the state back from its boundary alone: it
// restores every byte, with the lengths of a cached state's complete draft
// window, and a state whose slot changed after its record fails its
// restore.
void testPersistentStateComesBack(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  std::string name = (std::filesystem::temp_directory_path() / "splash-states-XXXXXX").string();
  require(::mkdtemp(name.data()) != nullptr, "temporary directory could not be made");
  const std::filesystem::path directory = name;
  const model::SlotFile::Persistence persistence{directory / "state.slots",
                                                 directory / "state.records", {}, 8};
  const auto budget = std::make_shared<model::DiskBudget>(2 * kStateSlotBytes);
  std::vector<std::vector<uint8_t>> images;
  {
    auto file = std::make_shared<model::SlotFile>(kStateSlotBytes, budget, persistence);
    file->finishAdoption();
    model::QwenStateStorage storage(backend, governor.allocationAdmission(), kStateLayout, file);
    require(static_cast<bool>(storage.tryActivateLane(0, 5)), "lane activation failed");
    std::vector<std::shared_ptr<const CompositeState>> kept;
    for (uint64_t seed : {40, 50}) {
      fill(storage.current(0).stateBase, seed);
      fill(storage.window(0), seed + 1);
      if (images.empty())
        images = stateImage(storage, 0);
      storage.updateLengths(0, published(4096));
      auto write = storage.snapshotToDisk(0, {});
      require(write != nullptr, "a state write was refused");
      kept.push_back(write->state());
      kept.back()->label(std::vector<std::byte>(8, std::byte{static_cast<uint8_t>(seed)}));
      require(finishWhenReady(*write), "a state write failed");
    }
    require(file->synchronize({})->wait(), "the state file did not synchronize");
    file->seal();
    storage.releaseLane(0, 5);
  }
  {
    // The second state's slot changes after its record was written.
    std::fstream slots(directory / "state.slots", std::ios::in | std::ios::out | std::ios::binary);
    slots.seekp(static_cast<std::streamoff>(kStateSlotBytes + 100));
    slots.put('\x7f');
  }
  auto file = std::make_shared<model::SlotFile>(kStateSlotBytes, budget, persistence);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), kStateLayout, file);
  const std::vector<model::SlotRecord> records = file->records();
  require(records.size() == 2 && records[0].label == std::vector<std::byte>(8, std::byte{40}),
          "the next process did not find both labelled states");
  rejects([&] { static_cast<void>(storage.adopt(records[0], 4100)); },
          "composite snapshot requires equal page-aligned committed lengths",
          "a state was taken back at a boundary off a page");
  auto intact = storage.adopt(records[0], 4096);
  auto changed = storage.adopt(records[1], 4096);
  file->finishAdoption();
  require(intact && !intact->residentBytes() && intact->bytes() == kStateLayout.cachedBytes(),
          "a state taken back is not a disk copy of the layout");
  require(static_cast<bool>(storage.tryActivateLane(0, 6)), "lane activation failed");
  fill(storage.current(0).stateBase, 99);
  auto read = storage.beginRestore(0, *intact, true, {}, [] {});
  require(read && finishWhenReady(*read) && stateImage(storage, 0) == images &&
              storage.metadata(0).lengths == published(4096),
          "a state taken back did not restore every byte and its lengths");
  require(!changed, "a state whose slot changed was adopted");
  read.reset();
  storage.releaseLane(0, 6);
  std::error_code ignored;
  std::filesystem::remove_all(directory, ignored);
}

// A persistent tier's copy of a state that stays in RAM is written from the
// RAM copy's own buffers: no staging, and the RAM copy keeps them. The disk
// copy restores every byte.
void testPersistKeepsTheRamCopy(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  model::QwenStateStorage storage(
      backend, governor.allocationAdmission(), kStateLayout,
      std::make_shared<model::SlotFile>(kStateSlotBytes,
                                        std::make_shared<model::DiskBudget>(kStateSlotBytes)));
  require(static_cast<bool>(storage.tryActivateLane(0, 7)), "lane activation failed");
  fill(storage.current(0).stateBase, 60);
  fill(storage.window(0), 61);
  const auto images = stateImage(storage, 0);
  storage.updateLengths(0, published(4096));
  const auto source = storage.snapshot(0);
  const uint64_t allocated = storage.actualAllocatedBytes();
  auto write = source->persist({});
  require(write && !write->state()->residentBytes() &&
              source->residentBytes() == kStateLayout.cachedBytes() &&
              storage.actualAllocatedBytes() == allocated,
          "a persisted state staged its write or gave up its RAM copy");
  require(!source->persist({}), "a second copy was admitted past the quota");
  require(finishWhenReady(*write), "the persisted state's write failed");
  fill(storage.current(0).stateBase, 99);
  auto read = storage.beginRestore(0, *write->state(), true, {}, [] {});
  require(read && finishWhenReady(*read) && stateImage(storage, 0) == images &&
              storage.metadata(0).lengths == published(4096),
          "the persisted copy did not restore every byte and its lengths");
  read.reset();
  storage.releaseLane(0, 7);
}

// A state a prefill command captures takes its cache slot before the command
// runs: the pool's buffers, one admission for what the pool lacks, nothing
// on a refusal, whose cause it reports. copyWindow() fills the slot's window alone and copyState()
// the lane's whole state. Sealing moves the slot into the cached state, which
// carries the tier's file and staging as a snapshot does, and leaves the
// reservation empty: a dropped reservation returns what it still holds, so
// each buffer goes back to the pool once, and nothing once its storage is
// gone.
void testReservations(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  bool admitNew = true;
  uint32_t admissions = 0;
  const metal::AllocationAdmission admit = [admit = governor.allocationAdmission(), &admitNew, &admissions](
                                               uint64_t bytes, const std::function<void()> &allocate)
      -> metal::AllocationResult {
    if (!admitNew)
      return metal::AllocationFailure::EngineBudget;
    const metal::AllocationResult result = admit(bytes, allocate);
    admissions += static_cast<bool>(result);
    return result;
  };
  constexpr model::CompositeStateLayout layout{{1, 3, 128, 1, 128, 128}, {1, 1, 4, 128}};
  const uint64_t slotBytes = model::SlotFile::slotBytesFor(layout.cachedBytes());
  const uint64_t beforeStorage = backend.memoryStats().allocatedBytes;
  std::shared_ptr<model::QwenStateReservation> outlives;
  {
    model::QwenStateStorage storage(
        backend, admit, layout,
        std::make_shared<model::SlotFile>(slotBytes, std::make_shared<model::DiskBudget>(slotBytes)));
    require(static_cast<bool>(storage.tryActivateLane(0, 9)), "lane activation failed");
    fill(storage.current(0).stateBase, 70);
    fill(storage.window(0), 71);
    storage.updateLengths(0, published(4096));
    const auto images = stateImage(storage, 0);
    const uint64_t laneBytes = storage.actualAllocatedBytes();

    admitNew = false;
    metal::AllocationFailure refusal;
    require(!storage.reserve(refusal) && refusal == metal::AllocationFailure::EngineBudget &&
                storage.actualAllocatedBytes() == laneBytes,
            "a refused reservation allocated its slot or lost its cause");
    admitNew = true;
    auto reservation = storage.reserve(refusal);
    require(reservation && refusal == metal::AllocationFailure::None && admissions == 2 &&
                storage.actualAllocatedBytes() > laneBytes &&
                storage.idleCells() == 0 && storage.idleWindows() == 0,
            "a reservation did not take one admission for its slot");
    const uint64_t slotted = storage.actualAllocatedBytes();
    reservation.reset();
    require(storage.idleCells() == 1 && storage.idleWindows() == 1 &&
                storage.actualAllocatedBytes() == slotted,
            "a dropped reservation did not return its slot to the pool");
    admitNew = false;
    reservation = storage.reserve(refusal);
    require(reservation && storage.idleCells() == 0 && storage.idleWindows() == 0,
            "a reservation did not take the pooled slot without an admission");
    admitNew = true;

    // The window alone, then the whole state.
    const model::QwenCachedBuffers buffers = reservation->buffers();
    fill(buffers.gdn->buffers().stateBase, 72);
    const auto cell = bytesOf(buffers.gdn->buffers().stateBase);
    storage.copyWindow(0, *reservation);
    require(sameBytes(buffers.window->buffer(), images[1]) &&
                sameBytes(buffers.gdn->buffers().stateBase, cell),
            "copyWindow did not copy the lane's window alone");
    storage.copyState(0, *reservation);
    require(sameBytes(buffers.gdn->buffers().stateBase, images[0]) &&
                sameBytes(buffers.window->buffer(), images[1]),
            "copyState did not copy the lane's cell and window");

    // A refused seal leaves the reservation as it was.
    rejects([&] { static_cast<void>(storage.seal(*reservation, {4096, 2048, 2048, 4000})); },
            "a composite snapshot needs the context window of its draft rings",
            "a state was sealed behind its context window");
    std::shared_ptr<const model::QwenCompositeState> state = storage.seal(*reservation, published(4096));
    rejects([&] { static_cast<void>(reservation->buffers()); }, "a sealed state reservation holds no buffers",
            "a sealed reservation still held its buffers");
    rejects([&] { static_cast<void>(storage.seal(*reservation, published(4096))); },
            "composite state buffers are empty", "a reservation was sealed twice");
    reservation.reset();
    require(storage.idleCells() == 0 && storage.idleWindows() == 0,
            "a sealed reservation returned the buffers its state holds");
    require(state->canOffload(false), "a sealed state cannot be written to the disk tier");
    auto write = state->offload({});
    require(write && finishWhenReady(*write), "a sealed state's disk write failed");
    fill(storage.current(0).stateBase, 99);
    fill(storage.window(0), 98);
    auto read = storage.beginRestore(0, *write->state(), true, {}, [] {});
    require(read && finishWhenReady(*read) && stateImage(storage, 0) == images &&
                storage.metadata(0).lengths == published(4096),
            "a sealed state's disk copy did not restore every byte and its lengths");
    read.reset();
    write.reset();
    state.reset();
    require(storage.idleCells() == 1 && storage.idleWindows() == 1 &&
                storage.actualAllocatedBytes() == slotted,
            "a dropped sealed state did not return its slot to the pool once");

    // Another storage's reservation is refused.
    model::QwenStateStorage other(backend, admit, layout, nullptr);
    auto foreign = other.reserve(refusal);
    rejects([&] { static_cast<void>(storage.seal(*foreign, published(4096))); },
            "a state reservation of another storage", "a foreign reservation was sealed");
    outlives = storage.reserve(refusal);
    storage.releaseLane(0, 9);
  }
  // Its storage went first: the reservation frees its buffers.
  outlives.reset();
  require(backend.memoryStats().allocatedBytes == beforeStorage,
          "a reservation that outlived its storage kept its buffers");
}

// A target without GDN layers (attention alone) keeps no GDN state: its
// layout has no GDN dimensions, its cells no bytes, and a lane and a state
// hold the draft's buffers alone. Every lane and state shares one empty cell,
// which Metal allocates nothing for and the pool never holds, so no idle
// cell is counted, a start lacks no cell a state could give and a reclaim
// releases rings and windows. A state copies, writes, reads and restores
// its window alone.
void testAttentionOnlyTarget(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{{}, kDraftState};
  static_assert(layout.valid() && layout.target.cellBytes() == 0 &&
                layout.laneBytes() == kDraftState.ringBytes() + kDraftState.windowBytes() &&
                layout.cachedBytes() == kDraftState.windowBytes());
  static_assert(model::GdnStateLayout{.format = ops::GdnStateFormat::BFloat16}.valid() &&
                !model::GdnStateLayout{.convolutionHistory = 3}.valid() &&
                !model::GdnStateLayout{48, 3, 10'240, 48, 128, 0}.valid());
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  uint32_t admissions = 0;
  const metal::AllocationAdmission admit = [admit = governor.allocationAdmission(), &admissions](
                                               uint64_t bytes, const std::function<void()> &allocate) {
    ++admissions;
    return admit(bytes, allocate);
  };
  const uint64_t slotBytes = model::SlotFile::slotBytesFor(layout.cachedBytes());
  const uint64_t beforeStorage = backend.memoryStats().allocatedBytes;
  {
    model::QwenStateStorage storage(
        backend, admit, layout,
        std::make_shared<model::SlotFile>(slotBytes, std::make_shared<model::DiskBudget>(slotBytes)));
    require(storage.actualAllocatedBytes() == 0 && storage.stagingBytes() == layout.cachedBytes(),
            "an attention-only storage allocated a cell or stages more than a window");
    require(static_cast<bool>(storage.tryActivateLane(0, 1)) && admissions == 1 &&
                storage.actualAllocatedBytes() >= layout.laneBytes(),
            "an attention-only lane did not take its rings and window in one admission");
    const model::GdnParityBuffers &current = storage.current(0);
    require(&current == &storage.next(0) && !current.stateBase && current.convolutionLayers.empty() &&
                current.recurrentLayers.empty() && !current.auxiliary,
            "an attention-only lane's cells are not the one empty cell");
    storage.clearForColdStart(0);
    fill(storage.window(0), 31);
    const std::vector<uint8_t> window = bytesOf(storage.window(0));
    storage.updateLengths(0, published(4096));
    storage.swapParity(0);

    // A state takes a window alone, and gives it back alone.
    auto state = storage.snapshot(0);
    require(state && state->bytes() == layout.cachedBytes() && admissions == 2,
            "an attention-only state did not take a window alone");
    require(static_cast<bool>(storage.tryActivateLane(1, 2)), "a second attention-only lane did not start");
    fill(storage.window(1), 32);
    bool committed = false;
    require(!storage.beginRestore(1, *state, true, {}, [&] { committed = true; }) && committed &&
                sameBytes(storage.window(1), window) && storage.metadata(1).lengths == published(4096),
            "an attention-only state did not restore its window and lengths");
    state.reset();
    require(storage.idleCells() == 0 && storage.idleWindows() == 1 && storage.idleRings() == 0,
            "a dropped attention-only state did not return its window alone");
    const uint64_t pooled = storage.actualAllocatedBytes();
    const uint32_t admitted = admissions;
    metal::AllocationFailure refusal;
    auto reservation = storage.reserve(refusal);
    require(reservation && admissions == admitted && storage.idleWindows() == 0 &&
                storage.actualAllocatedBytes() == pooled,
            "an attention-only reservation did not take the pooled window alone");
    storage.copyState(1, *reservation);
    require(sameBytes(reservation->buffers().window->buffer(), window),
            "an attention-only state's copy did not take the lane's window");
    state = storage.seal(*reservation, published(4096));
    reservation.reset();

    // On disk a state is its window.
    auto write = state->offload({});
    require(write && finishWhenReady(*write) && write->state()->bytes() == layout.cachedBytes(),
            "an attention-only state's disk write failed");
    fill(storage.window(0), 33);
    auto read = storage.beginRestore(0, *write->state(), true, {}, [] {});
    require(read && finishWhenReady(*read) && sameBytes(storage.window(0), window),
            "an attention-only state's disk copy did not restore its window");
    read.reset();
    write.reset();
    state.reset();

    // Released lanes leave rings and windows, and no cell, to reclaim.
    storage.releaseLane(0, 1);
    storage.releaseLane(1, 2);
    require(storage.idleCells() == 0 && storage.idleRings() == 2 && storage.idleWindows() == 3 &&
                storage.statesToActivate() == 0 &&
                storage.idleBytes(1, false, true) == kDraftState.ringBytes() + 3 * kDraftState.windowBytes(),
            "released attention-only lanes pooled a cell, lost a buffer or counted a cell's bytes");
    const uint64_t idle = storage.idleBytes(0, false, false);
    require(idle > 0 && releaseAllIdle(storage, false) == idle && storage.actualAllocatedBytes() == 0 &&
                storage.idleRings() == 0 && storage.idleWindows() == 0,
            "an attention-only pool kept buffers past reclaim, or released other than its idle bytes");
  }
  require(backend.memoryStats().allocatedBytes == beforeStorage,
          "an attention-only storage's buffers outlived it");
}

// A lane's start allocates startBytes, the lane's buffers the pool lacks,
// and the states its claims then evict leave idleBytes after the start to
// release: they refill the lane's buffers the start took from the pool
// first. From an empty pool and from pools holding none to two lanes'
// buffers and none to two states' cells and windows, with none to three
// states evicted.
void testStartBytes(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
                          queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  for (uint32_t pooledLanes = 0; pooledLanes < 3; ++pooledLanes) {
    for (uint32_t pooledStates = 0; pooledStates < 3; ++pooledStates) {
      for (uint32_t evicted = 0; evicted < 4; ++evicted) {
        model::QwenStateStorage storage(backend, governor.allocationAdmission(), kStateLayout, nullptr);
        metal::AllocationFailure refusal;
        std::vector<std::shared_ptr<model::QwenStateReservation>> cached, pooled;
        for (uint32_t each = 0; each < evicted; ++each)
          cached.push_back(storage.reserve(refusal));
        for (uint32_t lane = 0; lane < pooledLanes; ++lane)
          require(static_cast<bool>(storage.tryActivateLane(lane, lane + 1)), "a pool lane did not start");
        for (uint32_t each = 0; each < pooledStates; ++each)
          pooled.push_back(storage.reserve(refusal));
        for (uint32_t lane = 0; lane < pooledLanes; ++lane)
          storage.releaseLane(lane, lane + 1);
        const bool reserved = std::ranges::all_of(cached, [](const auto &state) { return state != nullptr; }) &&
                              std::ranges::all_of(pooled, [](const auto &state) { return state != nullptr; });
        pooled.clear();
        const std::string name = std::to_string(evicted) + " evicted states beside " + std::to_string(pooledLanes) +
                                 " pooled lanes and " + std::to_string(pooledStates) + " pooled states";
        require(reserved && storage.idleRings() == pooledLanes && storage.idleWindows() == pooledLanes + pooledStates,
                "the fixture of " + name + " did not hold its states and pool");
        const uint64_t charged = storage.startBytes();
        const uint64_t credited = storage.idleBytes(evicted, true, true);
        const uint64_t before = storage.actualAllocatedBytes();
        require(static_cast<bool>(storage.tryActivateLane(0, 9)), "the start of " + name + " failed");
        require(storage.actualAllocatedBytes() == before + charged,
                "the start of " + name + " did not allocate what it was charged");
        cached.clear();
        require(releaseAllIdle(storage, true) == credited,
                "the states evicted after the start of " + name + " did not release what was counted");
        storage.releaseLane(0, 9);
      }
    }
  }
}

void run(const std::string &metallib) {
  using model::QwenCompositeState;
  using model::QwenLogicalLengths;
  using model::QwenStateStorage;

  testLayoutFormulas();
  metal::MetalBackend backend(metallib);
  testOffloadAllocationFailure(backend);
  testDiskRestore(backend);
  testDirectDiskSnapshot(backend);
  testStateWritesDrawOnTheWriteBudget(backend);
  testStateSmallerThanSlot(backend);
  testPersistentStateComesBack(backend);
  testPersistKeepsTheRamCopy(backend);
  testReservations(backend);
  testAttentionOnlyTarget(backend);
  testStartBytes(backend);
  testRetainableQwenMatchingPrefixGraph(backend);
  testQwenCacheOffloadWarmLookup(backend);
  testQwenAsyncOffloadFailureDoesNotPublishWarmState(backend);
  testQwenDiskRestoreTransactionThroughEngine(backend);
  testCorruptQwenDiskPayloadFallsBackCold(backend);
  testQwenQuotaRefusalDoesNotPublishAndRetries(backend);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1, 1,
      queryHostMemory, 0);
  const test::ClaimScope start(governor, ClaimClass::Floor);
  // Switched off to prove that a pooled cache slot needs no new admission;
  // the count is of the admissions granted.
  bool admitNewAllocations = true;
  uint32_t admissions = 0;
  auto admitState = [admit = governor.allocationAdmission(), &admitNewAllocations,
                     &admissions](uint64_t bytes, const std::function<void()> &allocate)
      -> metal::AllocationResult {
    if (!admitNewAllocations)
      return metal::AllocationFailure::EngineBudget;
    const metal::AllocationResult result = admit(bytes, allocate);
    if (result)
      ++admissions;
    return result;
  };
  uint64_t beforeStorage = backend.memoryStats().allocatedBytes;
  uint64_t observedStorageActual = 0;
  uint64_t observedLaneActual = 0;
  uint64_t observedPrefixActual = 0;

  {
    QwenStateStorage storage(backend, admitState, kStateLayout, nullptr);
    require(storage.actualAllocatedBytes() == 0 &&
                backend.memoryStats().allocatedBytes == beforeStorage,
            "lane state was allocated eagerly");
    for (uint32_t lane = 0;
         lane < model::ExecutionLimits::maximumBatchWidth;
         ++lane)
      require(!storage.metadata(lane).assigned(), "lane was assigned eagerly");
    rejects([&] { static_cast<void>(storage.current(4)); }, "invalid Qwen lane",
            "storage exposed more than four lanes");

    require(static_cast<bool>(storage.tryActivateLane(0, 101)),
            "lane activation failed");
    observedLaneActual = storage.actualAllocatedBytes();
    require(observedLaneActual >= kStateLayout.laneBytes(),
            "activated lane allocation is below declared bytes");
    require(storage.tryActivateLane(1, 202) &&
                storage.actualAllocatedBytes() == 2 * observedLaneActual,
            "activated lane accounting is not incremental");
    observedStorageActual = storage.actualAllocatedBytes();

    // A lane's accessors read the cells it holds now: at parity p, current()
    // is its cell p and next() its cell p ^ 1.
    void *stableGdnBase = storage.current(0).stateBase.contents();
    void *stableDraftBase = storage.draft(0)[0].keys.contents();
    require(stableGdnBase && stableDraftBase,
            "stable lane buffers are not CPU-visible");
    require(stableGdnBase != storage.current(1).stateBase.contents(),
            "two lanes alias one GDN allocation");
    require(storage.current(0).convolutionLayers[1].contents() ==
                    static_cast<uint8_t *>(stableGdnBase) +
                        kTargetState.convolutionLayerBytes() &&
                storage.current(0).recurrentLayers[1].contents() ==
                    static_cast<uint8_t *>(stableGdnBase) +
                        kTargetState.convolutionBytes() +
                        kTargetState.recurrentLayerBytes(),
            "GDN layer view offset is wrong");
    require(storage.current(0).stateBase.sizeBytes() ==
                    kTargetState.cellBytes() &&
                storage.draft(0).size() == kDraftState.layers &&
                storage.draft(0)[0].keys.sizeBytes() == kDraftState.tensorBytes() &&
                storage.window(0).sizeBytes() == kDraftState.windowBytes(),
            "split state-buffer sizes are wrong");

    require(storage.metadata(0).requestId == 101 &&
                storage.metadata(0).activeParity == 0,
            "lane activation metadata is wrong");
    rejects([&] { static_cast<void>(storage.tryActivateLane(0, 303)); },
            "Qwen lane is already assigned",
            "double lane activation was accepted");

    // Hot metadata updates must leave every buffer and marker untouched.
    word(storage.current(0).convolutionLayers[0]) = 0x10101010;
    word(storage.next(0).convolutionLayers[0]) = 0x21212121;
    word(storage.next(0).recurrentLayers[0]) = 0x31313131;
    const uint64_t windowTail = kDraftState.windowBytes() - sizeof(uint32_t);
    word(storage.window(0)) = 0x41414141;
    word(storage.window(0), windowTail) = 0x51515151;
    QwenLogicalLengths lengths{2'048, 0, 2'048, 2'048};
    storage.updateLengths(0, lengths);
    require(storage.metadata(0).lengths.draftLength == 2'048,
            "draft resident length is wrong");
    require(word(storage.next(0).convolutionLayers[0]) == 0x21212121 &&
                word(storage.window(0)) == 0x41414141,
            "length update copied or cleared hot state");
    storage.swapParity(0);
    require(storage.metadata(0).activeParity == 1,
            "parity swap did not select parity one");
    require(word(storage.next(0).convolutionLayers[0]) == 0x10101010 &&
                word(storage.current(0).convolutionLayers[0]) == 0x21212121,
            "parity swap copied hot state or kept the current cell");

    // Publication copies the lane's active-parity GDN cell and its context
    // window into a cache slot the governor admits. The lane keeps its own
    // cells: no address changes, no aliasing, no parity handoff.
    const uint64_t beforePrefix = backend.memoryStats().allocatedBytes;
    const uint64_t storageBeforePrefix = storage.actualAllocatedBytes();
    void *laneActiveGdnBase = storage.current(0).stateBase.contents();
    std::shared_ptr<const QwenCompositeState> prefix = storage.snapshot(0);
    require(prefix != nullptr, "snapshot could not obtain a cache slot");
    observedPrefixActual = backend.memoryStats().allocatedBytes - beforePrefix;
    require(prefix->bytes() == kStateLayout.cachedBytes(),
            "cached state footprint is not the declared cached bytes");
    require(observedPrefixActual >= kStateLayout.cachedBytes() &&
                storage.actualAllocatedBytes() ==
                    storageBeforePrefix + observedPrefixActual,
            "cache slot allocation is below declared bytes or unaccounted");
    require(storage.current(0).stateBase.contents() == laneActiveGdnBase &&
                storage.next(0).stateBase.contents() == stableGdnBase &&
                storage.draft(0)[0].keys.contents() == stableDraftBase,
            "snapshot moved or aliased the lane's own cells");
    require(storage.metadata(0).activeParity == 1 &&
                storage.metadata(0).lengths == lengths,
            "snapshot changed the lane's metadata");

    // The cached copy is independent of the lane: writes to the lane's
    // active cell or window after publication never reach a restore, which
    // leaves the rings to the runtime.
    word(storage.current(0).convolutionLayers[0]) = 0xa1a1a1a1;
    word(storage.current(0).recurrentLayers[0]) = 0xa2a2a2a2;
    word(storage.window(0)) = 0xa3a3a3a3;
    word(storage.current(1).convolutionLayers[0]) = 0xb0b0b0b0;
    word(storage.next(1).convolutionLayers[0]) = 0xb1b1b1b1;
    word(storage.draft(1)[0].keys) = 0xb2b2b2b2;
    void *destinationGdnBase = storage.current(1).stateBase.contents();
    void *destinationDraftBase = storage.draft(1)[0].keys.contents();
    require(!storage.beginRestore(1, *prefix, true, {}, [] {}),
            "a resident restore returned a read");

    require(storage.metadata(1).requestId == 202 &&
                storage.metadata(1).activeParity == 0 &&
                storage.metadata(1).lengths == lengths,
            "restore lost owner, changed parity, or lengths");
    require(storage.current(1).stateBase.contents() == destinationGdnBase &&
                storage.draft(1)[0].keys.contents() == destinationDraftBase,
            "restore replaced the destination's buffers");
    require(word(storage.current(1).convolutionLayers[0]) == 0x21212121 &&
                word(storage.current(1).recurrentLayers[0]) == 0x31313131,
            "restore did not deliver the pre-mutation GDN snapshot");
    require(word(storage.next(1).convolutionLayers[0]) == 0xb1b1b1b1,
            "restore overwrote inactive parity");
    require(word(storage.window(1)) == 0x41414141 &&
                word(storage.window(1), windowTail) == 0x51515151,
            "restore did not deliver the pre-mutation context window");
    require(word(storage.draft(1)[0].keys) == 0xb2b2b2b2,
            "a restore wrote the rings, which the runtime computes from the window");
    require(word(storage.current(0).convolutionLayers[0]) == 0xa1a1a1a1 &&
                word(storage.current(0).recurrentLayers[0]) == 0xa2a2a2a2 &&
                word(storage.window(0)) == 0xa3a3a3a3,
            "restore wrote back into the source lane");

    // A suffix that will capture a full 2048-token window restores only GDN:
    // the window is not copied to be overwritten by the next prefill.
    storage.swapParity(1);
    word(storage.window(1)) = 0xd2d2d2d2;
    require(!storage.beginRestore(1, *prefix, false, {}, [] {}),
            "a resident restore returned a read");
    require(word(storage.current(1).convolutionLayers[0]) == 0x21212121,
            "GDN-only restore did not restore convolution state");
    require(word(storage.window(1)) == 0xd2d2d2d2,
            "GDN-only restore copied an obsolete context window");
    require(storage.metadata(1).lengths.targetTokens == 2048 &&
                storage.metadata(1).lengths.draftLength == 0 &&
                storage.metadata(1).lengths.draftBase == 2048 &&
                storage.metadata(1).lengths.windowEnd == 2048,
            "GDN-only restore exposed stale draft metadata");
    // Cancellation releases ownership and returns the lane's buffers to the
    // pool. Reactivation takes them back in the same order and as they are:
    // only a cold start clears the current cell, which a restore would
    // overwrite instead.
    const uint64_t tailWord = kTargetState.cellBytes() - sizeof(uint32_t);
    void *reusableGdnBase = storage.next(0).stateBase.contents();
    void *reusableDraftBase = storage.draft(0)[0].keys.contents();
    word(storage.next(0).convolutionLayers[0]) = 0xc1c1c1c1;
    word(storage.next(0).recurrentLayers[0]) = 0xc2c2c2c2;
    word(storage.next(0).stateBase, tailWord) = 0xc3c3c3c3;
    storage.releaseLane(0, 101);
    require(!storage.metadata(0).assigned(), "cancellation did not release metadata");
    require(storage.idleCells() == 2 && storage.idleRings() == 1 &&
                storage.idleWindows() == 1 && storage.statesToActivate() == 0,
            "released lane buffers did not return to the pool");
    rejects([&] { storage.swapParity(0); }, "Qwen lane is not assigned",
            "unassigned lane accepted a parity update");
    require(static_cast<bool>(storage.tryActivateLane(0, 303)), "lane reuse failed");
    require(storage.idleCells() == 0 && storage.idleRings() == 0 &&
                storage.idleWindows() == 0,
            "reactivation left pooled buffers behind");
    require(storage.current(0).stateBase.contents() == reusableGdnBase &&
                storage.draft(0)[0].keys.contents() == reusableDraftBase,
            "lane reuse changed stable buffer addresses");
    require(storage.metadata(0).requestId == 303 &&
                storage.metadata(0).activeParity == 0 &&
                storage.metadata(0).lengths == QwenLogicalLengths{},
            "lane reuse did not reset logical state");
    require(word(storage.current(0).convolutionLayers[0]) == 0xc1c1c1c1 &&
                word(storage.current(0).recurrentLayers[0]) == 0xc2c2c2c2 &&
                word(storage.current(0).stateBase, tailWord) == 0xc3c3c3c3,
            "activation touched the pooled cell it took");
    storage.clearForColdStart(0);
    require(word(storage.current(0).convolutionLayers[0]) == 0 &&
                word(storage.current(0).recurrentLayers[0]) == 0 &&
                word(storage.current(0).stateBase, tailWord) == 0,
            "a cold start left readable state in the current cell");
    // A lane whose request found a row that is not finite clears every
    // layer's ring keys and values before its release.
    const model::DFlashDraftRingLayer &lastRing = storage.draft(0).back();
    const uint64_t ringTail = lastRing.values.sizeBytes() - sizeof(uint32_t);
    word(storage.draft(0)[0].keys) = 0xe1e1e1e1;
    word(storage.draft(0)[0].values) = 0xe2e2e2e2;
    word(lastRing.keys) = 0xe3e3e3e3;
    word(lastRing.values, ringTail) = 0xe4e4e4e4;
    storage.clearDraftRings(0);
    require(word(storage.draft(0)[0].keys) == 0 && word(storage.draft(0)[0].values) == 0 &&
                word(lastRing.keys) == 0 && word(lastRing.values, ringTail) == 0,
            "the lane's draft rings were not cleared");

    // Rejected publications fail before any cache slot is taken or admitted.
    const uint64_t beforeRejected = storage.actualAllocatedBytes();
    storage.updateLengths(0, {128, 0, 127});
    rejects([&] { storage.clearForColdStart(0); }, "a cold start begins at logical length zero",
            "a lane past length zero was cleared for a cold start");
    rejects([&] { static_cast<void>(storage.snapshot(0)); },
            "composite snapshot requires equal page-aligned committed lengths",
            "snapshot accepted divergent target/draft lengths");
    rejects(
        [&] {
          storage.updateLengths(0, {129, 0, 129});
          static_cast<void>(storage.snapshot(0));
        },
        "composite snapshot requires equal page-aligned committed lengths",
        "unaligned prefix snapshot was accepted");
    // Decode writes the rings alone: a lane past that has no window to keep.
    rejects(
        [&] {
          storage.updateLengths(0, {2'048, 0, 2'048, 2'040});
          static_cast<void>(storage.snapshot(0));
        },
        "a composite snapshot needs the context window of its draft rings",
        "a snapshot was taken behind its context window");
    rejects([&] { storage.updateLengths(0, {2'048, 0, 2'040, 2'048}); }, "invalid draft ring metadata",
            "a window past the rings was accepted");
    require(storage.actualAllocatedBytes() == beforeRejected,
            "rejected snapshot allocated or consumed a cache slot");

    // A decode step leaves the rows it retained pending on the lane's tape:
    // until the lane's next decode step folds them in, its cell does not hold
    // its state, which neither a snapshot, a restore nor a prefill step reads.
    storage.updateLengths(0, {2'048, 0, 2'048, 2'048});
    const uint32_t parity = storage.metadata(0).activeParity;
    for (const uint32_t retained : {0U, model::ExecutionLimits::targetVerifyRows + 1})
      rejects([&] { storage.swapDecodeParity(0, retained); }, "a decode step retains one to all of its rows",
              "a decode step retained no rows or more than its rows");
    storage.swapDecodeParity(0, 3);
    require(storage.metadata(0).pendingRows == 3 && storage.metadata(0).activeParity != parity,
            "a decode step's swap lost its retained rows");
    rejects([&] { static_cast<void>(storage.snapshot(0)); }, "Qwen lane state has decoded rows pending",
            "a snapshot read a cell without its retained rows");
    rejects([&] { static_cast<void>(storage.snapshotToDisk(0, {})); }, "Qwen lane state has decoded rows pending",
            "a disk snapshot read a cell without its retained rows");
    rejects([&] { static_cast<void>(storage.beginRestore(0, *prefix, true, {}, [] {})); },
            "Qwen lane state has decoded rows pending", "a restore overwrote a cell with pending rows");
    rejects([&] { storage.swapParity(0); }, "Qwen lane state has decoded rows pending",
            "a prefill step followed a decode step's pending rows");
    storage.swapDecodeParity(0, model::ExecutionLimits::targetVerifyRows);
    require(storage.metadata(0).pendingRows == model::ExecutionLimits::targetVerifyRows &&
                storage.metadata(0).activeParity == parity,
            "the next decode step's swap did not take its own retained rows");
    rejects([&] { storage.releaseLane(0, 404); }, "Qwen lane owner mismatch",
            "lane release accepted the wrong owner");

    const uint64_t beforeSuspend = storage.actualAllocatedBytes();
    storage.releaseLane(0, 303);
    require(releaseAllIdle(storage, false) == observedLaneActual,
            "recomputation preemption retained active backing");
    require(!storage.metadata(0).assigned() &&
                storage.actualAllocatedBytes() == beforeSuspend - observedLaneActual,
            "preempted GDN or draft bytes remain outside the cache");
    require(storage.tryActivateLane(0, 303) &&
                storage.metadata(0).assigned() &&
                storage.metadata(0).lengths == QwenLogicalLengths{} &&
                !storage.metadata(0).pendingRows,
            "recomputation did not start from a fresh empty state");

    // Dropping a cached state returns its buffers to the storage's pool rather
    // than freeing them: accounting stays flat, and the next publication takes
    // the pooled buffers without a governor admission. Only releasing idle
    // buffers returns pooled bytes to macOS.
    const uint64_t beforeDrop = storage.actualAllocatedBytes();
    const uint64_t backendBeforeDrop = backend.memoryStats().allocatedBytes;
    prefix.reset();
    require(storage.actualAllocatedBytes() == beforeDrop &&
                backend.memoryStats().allocatedBytes == backendBeforeDrop,
            "dropped cached state freed its slot instead of pooling it");
    storage.updateLengths(0, lengths);
    word(storage.current(0).convolutionLayers[0]) = 0xe1e1e1e1;
    word(storage.current(0).recurrentLayers[0]) = 0xe2e2e2e2;
    word(storage.window(0)) = 0xe3e3e3e3;
    admitNewAllocations = false;
    std::shared_ptr<const QwenCompositeState> pooled = storage.snapshot(0);
    require(pooled != nullptr, "snapshot did not reuse the pooled cache slot");
    require(pooled->bytes() == kStateLayout.cachedBytes() &&
                storage.actualAllocatedBytes() == beforeDrop &&
                backend.memoryStats().allocatedBytes == backendBeforeDrop,
            "pooled cache slot reuse allocated new buffers");
    require(storage.snapshot(0) == nullptr,
            "snapshot with an empty pool bypassed the governor");
    require(storage.actualAllocatedBytes() == beforeDrop,
            "denied snapshot leaked cache slot bytes");
    admitNewAllocations = true;
    require(!storage.beginRestore(1, *pooled, true, {}, [] {}),
            "a resident restore returned a read");
    require(storage.metadata(1).activeParity == 1 &&
                storage.metadata(1).lengths == lengths &&
                word(storage.current(1).convolutionLayers[0]) == 0xe1e1e1e1 &&
                word(storage.current(1).recurrentLayers[0]) == 0xe2e2e2e2 &&
                word(storage.window(1)) == 0xe3e3e3e3,
            "reused cache slot served stale contents");
    require(word(storage.next(1).convolutionLayers[0]) == 0x21212121,
            "restore from the reused slot overwrote inactive parity");
    pooled.reset();
    require(storage.actualAllocatedBytes() == beforeDrop,
            "second dropped cached state was freed instead of pooled");
    require(releaseAllIdle(storage, false) == observedPrefixActual &&
                storage.actualAllocatedBytes() ==
                    beforeDrop - observedPrefixActual,
            "releasing idle buffers did not free the pooled cache slot");
    require(storage.metadata(0).assigned() && storage.metadata(1).assigned() &&
                storage.actualAllocatedBytes() == 2 * observedLaneActual,
            "pool reclaim touched active lane cells");

    // A live cached state survives its lane's release and reclaim; only its
    // drop plus a later reclaim frees the slot together with idle cells.
    std::shared_ptr<const QwenCompositeState> retained = storage.snapshot(1);
    require(retained != nullptr, "retained snapshot could not admit a slot");
    require(storage.actualAllocatedBytes() ==
                2 * observedLaneActual + observedPrefixActual,
            "retained snapshot accounting is wrong");
    storage.releaseLane(0, 303);
    storage.releaseLane(1, 202);
    require(storage.idleCells() == 4 && storage.idleRings() == 2 &&
                storage.idleWindows() == 2,
            "released lane buffers are missing from the pool");
    // What releasing down to one lane's worth frees once the cached state is
    // dropped, counted before at the layout's sizes: a lane's buffers and the
    // state's cell and window.
    const uint64_t idle = storage.idleBytes(1, false, true);
    require(idle == kStateLayout.laneBytes() + kStateLayout.cachedBytes(),
            "the idle bytes a dropped state would leave are not the layout's");
    retained.reset();
    require(storage.idleCells() == 5 && storage.idleRings() == 2 &&
                storage.idleWindows() == 3 && storage.idleBytes(0, false, true) == idle,
            "dropped cached state did not return its cell and window to the pool");
    // Releasing down to one lane's worth keeps two cells, the rings and a
    // window warm, and frees no less than was counted.
    const uint64_t released = releaseAllIdle(storage, true);
    require(released == observedLaneActual + observedPrefixActual && released >= idle &&
                storage.idleCells() == 2 && storage.idleRings() == 1 &&
                storage.idleWindows() == 1 && storage.idleBytes(0, false, true) == 0,
            "partial idle release did not keep the requested buffers");
    require(releaseAllIdle(storage, false) == observedLaneActual,
            "idle lane buffers were not reclaimed");
    require(storage.idleCells() == 0 && storage.idleRings() == 0 &&
                storage.idleWindows() == 0,
            "reclaimed buffers remain pooled");
    // No cached state holds rings: without idle rings no number of states
    // makes up a lane.
    require(storage.actualAllocatedBytes() == 0 &&
                !storage.statesToActivate(),
            "reclaimed state cells remain accounted");

    // An activation asks the governor once for everything the pool lacks:
    // a refusal allocates nothing and leaves the pool as it was.
    admitNewAllocations = false;
    require(!storage.tryActivateLane(0, 505) && !storage.metadata(0).assigned() &&
                storage.actualAllocatedBytes() == 0 &&
                !storage.statesToActivate(),
            "a denied activation allocated part of its lane");
    admitNewAllocations = true;
    uint32_t admitted = admissions;
    require(static_cast<bool>(storage.tryActivateLane(0, 505)) &&
                admissions == admitted + 1 &&
                storage.actualAllocatedBytes() == observedLaneActual,
            "an activation asked the governor for its buffers one by one");
    // With one cell, the rings and a window in the pool the lane lacks a
    // cell: a refusal leaves them pooled, and the retry is admitted that cell
    // alone.
    storage.releaseLane(0, 505);
    require(storage.releaseOneIdle(false) != 0 && storage.idleCells() == 1 &&
                storage.idleRings() == 1 && storage.idleWindows() == 1 &&
                storage.statesToActivate() == 1,
            "fixture pool does not hold one cell, the rings and a window");
    const uint64_t pooledBytes = storage.actualAllocatedBytes();
    admitNewAllocations = false;
    require(!storage.tryActivateLane(0, 506) && storage.idleCells() == 1 &&
                storage.idleRings() == 1 && storage.idleWindows() == 1 &&
                storage.actualAllocatedBytes() == pooledBytes,
            "a denied activation took or dropped the pooled buffers");
    admitNewAllocations = true;
    admitted = admissions;
    require(static_cast<bool>(storage.tryActivateLane(0, 506)) &&
                admissions == admitted + 1 && storage.idleCells() == 0 &&
                storage.idleRings() == 0 && storage.idleWindows() == 0 &&
                storage.actualAllocatedBytes() == observedLaneActual,
            "the retry did not take the pooled buffers and one admission for the rest");
    storage.releaseLane(0, 506);
    require(releaseAllIdle(storage, false) == observedLaneActual &&
                storage.actualAllocatedBytes() == 0,
            "the lane's buffers were not reclaimed");
    // What else a request's start allocates joins the lane's admission: one
    // call for both, and a refusal builds neither.
    bool extraBuilt = false;
    const auto buildExtra = [&] { extraBuilt = true; };
    admitNewAllocations = false;
    require(!storage.tryActivateLane(0, 507, 4096, buildExtra) && !extraBuilt &&
                storage.actualAllocatedBytes() == 0,
            "a refused start built what came with its lane");
    admitNewAllocations = true;
    admitted = admissions;
    require(static_cast<bool>(storage.tryActivateLane(0, 507, 4096, buildExtra)) &&
                extraBuilt && admissions == admitted + 1 &&
                storage.actualAllocatedBytes() == observedLaneActual,
            "a start was not admitted in one piece");
    storage.releaseLane(0, 507);
    require(releaseAllIdle(storage, false) == observedLaneActual &&
                storage.actualAllocatedBytes() == 0,
            "the started lane's buffers were not reclaimed");
  }
  require(backend.memoryStats().allocatedBytes == beforeStorage,
          "destroyed state lanes remained in actual allocation count");

  std::cout << "qwen state storage tests passed: lane_declared="
            << kStateLayout.laneBytes()
            << " lane_actual=" << observedLaneActual << " four_lanes_declared="
            << uint64_t{model::ExecutionLimits::maximumBatchWidth} *
                   kStateLayout.laneBytes()
            << " four_lanes_actual=" << observedStorageActual
            << " composite_declared=" << kStateLayout.cachedBytes()
            << " prefix_actual=" << observedPrefixActual << '\n';
}

} // namespace

int main(int argc, const char **argv) {
  if (argc != 2) {
    std::cerr << "usage: qwen_state_storage_test METALLIB\n";
    return EXIT_FAILURE;
  }
  @autoreleasepool {
    try {
      run(argv[1]);
      return EXIT_SUCCESS;
    } catch (const std::exception &error) {
      std::cerr << "qwen state storage test failed: " << error.what() << '\n';
      return EXIT_FAILURE;
    }
  }
}
