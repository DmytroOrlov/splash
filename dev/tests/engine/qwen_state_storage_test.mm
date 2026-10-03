#include "engine/MemoryGovernor.hpp"
#include "engine/Cache.hpp"
#include "engine/Engine.hpp"
#include "tests/engine/AllocationFailure.hpp"
#include "TestImmediateTicket.hpp"
#include "model/QwenState.hpp"
#include "ops/PageStorage.hpp"

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <future>
#include <chrono>
#include <new>
#include <iostream>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
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
constexpr model::DraftStateLayout kDraftState{5, 8, 2'048, 128};
constexpr model::CompositeStateLayout kStateLayout{kTargetState, kDraftState};

void require(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}

template <typename Exception = std::exception>
void requireThrows(const std::function<void()> &operation,
                   const char *message) {
  try {
    operation();
  } catch (const Exception &) {
    return;
  }
  throw std::runtime_error(message);
}

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

// Every byte of one parity's state, in the order its disk copy holds them.
std::vector<std::vector<uint8_t>> stateImage(const model::QwenSlotBuffers &buffers,
                                             uint32_t parity) {
  std::vector<std::vector<uint8_t>> image{bytesOf(buffers.gdn[parity].stateBase)};
  for (const auto &layer : buffers.draft) {
    image.push_back(bytesOf(layer.keys));
    image.push_back(bytesOf(layer.values));
  }
  return image;
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
  EngineCacheStatus cacheStatus = EngineCacheStatus::Miss;
  uint32_t matchedTokens = 0;
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
                      uint32_t, uint32_t, uint32_t, double) override {
    if (kind == WorkKind::Prefill)
      prefillRows += inputTokens;
  }
  void started(uint64_t requestId, EngineCacheStatus cacheStatus,
               uint32_t matchedTokens, uint32_t) override {
    startedEvents.push_back({requestId, cacheStatus, matchedTokens});
  }
  void promptProgress(uint64_t requestId, uint32_t tokens) override {
    progressEvents.push_back({requestId, tokens});
  }
  void tokens(uint64_t, std::span<const uint32_t>) override {}
  void maskRequested(uint64_t, std::span<const uint32_t>) override {}
  void completed(uint64_t requestId, EngineFinishReason reason,
                 uint32_t promptTokens, uint32_t completionTokens,
                 std::span<const float>) override {
    doneEvents.push_back({requestId, reason, promptTokens, completionTokens});
  }
  void failed(uint64_t requestId, std::string, std::string, bool) override {
    failedRequests.push_back(requestId);
  }
  void capacityExhausted(uint64_t requestId, uint32_t, uint32_t,
                         uint64_t) override {
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
  uint32_t promptOffset = 0;
  uint32_t tokenCount = 0;
};

struct RestoredQwenValues final {
  uint64_t requestId = 0;
  uint32_t boundary = 0;
  model::QwenLogicalLengths lengths;
  uint32_t gdnMarker = 0;
  uint32_t recurrentMarker = 0;
  uint32_t draftKeyMarker = 0;
  uint32_t draftValueMarker = 0;
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
      if (states_.metadata(slot).assigned)
        continue;
      const auto admission = states_.tryActivateSlot(slot, request.id);
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
  void restore(uint64_t requestId, uint32_t,
               std::shared_ptr<const CompositeState> state,
               bool restoreDraftState) override {
    states_.restore(slotFor(requestId), *state, restoreDraftState);
    rememberRestored(requestId, 0);
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
            {item.requestId, item.promptOffset, item.tokenCount});
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
  bool canSnapshotToDisk() const noexcept override {
    return states_.canSnapshotToDisk();
  }
  std::unique_ptr<StateOffload>
  snapshotToDisk(uint64_t requestId,
                 std::function<void()> completion) override {
    return states_.snapshotToDisk(slotFor(requestId), std::move(completion));
  }
  uint64_t reclaimIdleState(bool keepLane) noexcept override {
    return states_.releaseIdle(keepLane ? model::QwenStateStorage::kLaneCells : 0,
                               keepLane ? 1 : 0);
  }
  void provideMask(uint64_t, std::span<const uint32_t>) override {}
  void end(uint64_t requestId) override {
    auto found = owners_.find(requestId);
    if (found == owners_.end())
      throw std::logic_error("Qwen test runtime ended an unknown lane");
    const uint32_t slot = found->second;
    states_.releaseSlot(slot, requestId);
    owners_.erase(found);
    laneEvents.push_back({requestId, false, slot});
  }

  model::WarmupStepResult warmupPrefill(uint32_t) override { return {}; }
  model::WarmupStepResult warmupDecodeBatch(uint32_t) override { return {}; }
  model::WarmupStepResult warmupDraftVerifyCommit() override { return {}; }
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
    const auto &buffers = states_.buffers(slot);
    const uint32_t parity = states_.metadata(slot).activeParity;
    successfulRestores.push_back(
        {requestId, boundary, states_.metadata(slot).lengths,
         word(buffers.gdn[parity].stateBase),
         word(buffers.gdn[parity].recurrentBase),
         word(buffers.draft[0].keys), word(buffers.draft[0].values)});
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
  require(kStateLayout.activeCellBytes() == 350'224'384,
          "per-slot byte formula is wrong");
  require(uint64_t{model::ExecutionLimits::maximumBatchWidth} *
                  kStateLayout.activeCellBytes() ==
              1'400'897'536,
          "four-slot byte formula is wrong");
  require(kStateLayout.cachedBytes() == 196'083'712,
          "prefix byte formula is wrong");
}

void testOffloadAllocationFailure(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  constexpr model::CompositeStateLayout layout{{1, 3, 128, 1, 128, 128},
                                               {1, 1, 2048, 4}};
  auto file = std::make_shared<model::SlotFile>(layout.cachedBytes(), 3 * layout.cachedBytes());
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout, file);
  require(static_cast<bool>(storage.tryActivateSlot(0, 1)), "fault source activation failed");
  storage.updateLengths(0, {4096, 2048, 2048, 0});
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
    const bool pending = !file->idle();
    release.set_value();
    auto result = attempt.get();
    while (!file->idle()) std::this_thread::yield();
    require(!(result.failed && returned && pending),
            "allocation failure released staging before the submitted write drained");
    if (!result.failed) {
      require(result.transfer && result.transfer->finish(),
              "offload did not recover after allocation failures");
      return;
    }
    require(file->usedBytes() == layout.cachedBytes(),
            "failed offload leaked its disk quota");
  }
  throw std::runtime_error("offload allocation failure sweep never reached success");
}

void testDiskRestore(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  model::QwenStateStorage storage(
      backend, governor.allocationAdmission(), kStateLayout,
      std::make_shared<model::SlotFile>(kStateLayout.cachedBytes(), kStateLayout.cachedBytes()));
  require(static_cast<bool>(storage.tryActivateSlot(0, 123)), "disk source activation failed");
  const auto &buffers = storage.buffers(0);
  // Every byte of the state travels through the file; markers alone would
  // not notice a misplaced or truncated span.
  fill(buffers.gdn[0].stateBase, 1);
  word(buffers.gdn[0].stateBase) = 0x12345678;
  for (size_t layer = 0; layer < buffers.draft.size(); ++layer) {
    fill(buffers.draft[layer].keys, 2 + 2 * layer);
    fill(buffers.draft[layer].values, 3 + 2 * layer);
    word(buffers.draft[layer].keys) = 100 + layer;
    word(buffers.draft[layer].values) = 200 + layer;
  }
  const auto images = stateImage(buffers, 0);
  storage.updateLengths(0, {4096, 2048, 2048, 0});
  auto source = storage.snapshot(0);
  auto write = source->offload({});
  require(write != nullptr, "disk offload not admitted");
  auto disk = write->state();
  require(disk && !disk->residentBytes(), "disk state retained resident allocation");
  // The write owns its copy: the source buffers are free before it finishes.
  source.reset();
  require(storage.idleCells() == 1 && storage.idleRings() == 1,
          "demotion did not return the source buffers at once");
  static_cast<void>(storage.releaseIdle(0, 0));
  require(finishWhenReady(*write), "disk write failed");
  write.reset();
  const auto beforeRestore = storage.actualAllocatedBytes();
  word(buffers.gdn[0].stateBase) = 0;
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
  require(stateImage(buffers, 0) == images, "disk restore did not reproduce every state byte");
  require(word(buffers.gdn[0].stateBase) == 0x12345678 &&
              storage.metadata(0).lengths.targetTokens == 4096,
          "disk state changed target values or metadata");
  for (size_t layer = 0; layer < buffers.draft.size(); ++layer) {
    require(word(buffers.draft[layer].keys) == 100 + layer &&
                word(buffers.draft[layer].values) == 200 + layer,
            "disk state changed draft values");
  }

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
              storage.metadata(0).lengths.draftBase == 4096,
          "skipped draft restore retained stale context");
  auto promoted = read->snapshot();
  require(promoted && promoted->residentBytes() == kStateLayout.cachedBytes(),
          "completed disk restore could not create a resident snapshot");
  require(storage.metadata(0).lengths.draftLength == 0,
          "promotion changed the executing request's draft plan");
  word(buffers.gdn[0].stateBase) = 0;
  for (auto &layer : buffers.draft) {
    word(layer.keys) = 0;
    word(layer.values) = 0;
  }
  storage.restore(0, *promoted, true);
  require(word(buffers.gdn[0].stateBase) == 0x12345678 &&
              storage.metadata(0).lengths.hasCompleteDraftWindow(2048),
          "promotion lost the original complete state when execution skipped draft");
  for (size_t layer = 0; layer < buffers.draft.size(); ++layer)
    require(word(buffers.draft[layer].keys) == 100 + layer &&
                word(buffers.draft[layer].values) == 200 + layer,
            "promotion aliased mutable active buffers");
  require(stateImage(buffers, 0) == images,
          "promoted snapshot did not reproduce every state byte");
  read.reset();
  disk.reset();
  promoted.reset();
  storage.releaseSlot(0, 123);
}

void testRetainableQwenMatchingPrefixGraph(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 4}};
  constexpr kv::Layout kvLayout{1, 1, 16, kv::Format::BFloat16};
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  kv::PageStorage pageStorage(backend, governor.allocationAdmission(), kvLayout,
                              kvLayout.backingExtentPages());
  KvPool kvPool(pageStorage);
  Cache cache(kvPool, CacheNamespace{});
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout);

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
      cache.publishCommittedBlocks(seedRequest, prompt, boundary);
  require(terminalBlock != 0 &&
              cache.blockAt(seedRequest, boundary) == terminalBlock,
          "exact committed prompt did not publish its terminal KV block");

  require(static_cast<bool>(storage.tryActivateSlot(0, seedRequest)),
          "matching-prefix source lane activation failed");
  const auto &source = storage.buffers(0);
  word(source.gdn[0].convolutionBase) = 0x11223344;
  word(source.gdn[0].recurrentBase) = 0x55667788;
  word(source.draft[0].keys) = 0x10203040;
  word(source.draft[0].values) = 0x50607080;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});
  std::shared_ptr<const model::QwenCompositeState> snapshot =
      storage.snapshot(0);
  require(snapshot && snapshot->bytes() == layout.cachedBytes(),
          "Qwen snapshot is missing or has the wrong retained footprint");
  const void *sourceGdn = source.gdn[0].stateBase.contents();
  const void *sourceDraft = source.draft[0].keys.contents();
  require(sourceGdn && sourceDraft,
          "Qwen source lane does not expose its allocated buffers");

  cache.publishCompositeState(terminalBlock, snapshot);
  cache.endRequest(seedRequest);
  auto published = cache.snapshot();
  require(published.stateCache.entries == 1 &&
              published.stateCache.bytes == layout.cachedBytes() &&
              published.stateCache.pinned == 0,
          "matching KV block did not account one unpinned Qwen publication");

  // Releasing the lane and its idle pool buffers must leave the independent
  // composite backing live and accounted by both Qwen storage and Metal.
  word(source.gdn[0].convolutionBase) = 0xf1f2f3f4;
  word(source.gdn[0].recurrentBase) = 0xf5f6f7f8;
  word(source.draft[0].keys) = 0xf9fafbfc;
  word(source.draft[0].values) = 0xfdfeff00;
  storage.releaseSlot(0, seedRequest);
  static_cast<void>(storage.releaseIdle(0, 0));
  require(storage.actualAllocatedBytes() >= layout.cachedBytes() &&
              backend.memoryStats().allocatedBytes >= layout.cachedBytes(),
          "cached Qwen backing was reclaimed with its source lane");

  cache.beginRequest(lookupRequest);
  auto lookup = cache.lookup(prompt);
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

  require(static_cast<bool>(storage.tryActivateSlot(1, lookupRequest)),
          "matching-prefix destination lane activation failed");
  const auto &destination = storage.buffers(1);
  word(destination.gdn[1].convolutionBase) = 0xaabbccdd;
  word(destination.gdn[1].recurrentBase) = 0xeeff0011;
  const auto destinationInactive = bytesOf(destination.gdn[1].stateBase);
  storage.restore(1, *leased, true);
  require(storage.metadata(1).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              storage.metadata(1).activeParity == 0,
          "leased Qwen state did not restore its logical draft window");
  require(word(destination.gdn[0].convolutionBase) == 0x11223344 &&
              word(destination.gdn[0].recurrentBase) == 0x55667788 &&
              word(destination.draft[0].keys) == 0x10203040 &&
              word(destination.draft[0].values) == 0x50607080,
          "leased Qwen state lost target GDN or draft key/value data");
  require(sameBytes(destination.gdn[1].stateBase, destinationInactive),
          "Qwen restore overwrote inactive parity");

  lookup.state.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "releasing the Cache lookup lease did not unpin Qwen state");
  storage.releaseSlot(1, lookupRequest);
  cache.endRequest(lookupRequest);
}

void testQwenCacheOffloadWarmLookup(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 4}};
  constexpr kv::Layout kvLayout{1, 1, 16, kv::Format::BFloat16};
  auto budget = std::make_shared<model::DiskBudget>(layout.cachedBytes());
  auto file = std::make_shared<model::SlotFile>(layout.cachedBytes(), budget);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  kv::PageStorage pageStorage(backend, governor.allocationAdmission(), kvLayout,
                              kvLayout.backingExtentPages());
  KvPool kvPool(pageStorage);
  Cache cache(kvPool, CacheNamespace{}, nullptr, budget);
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
      cache.publishCommittedBlocks(seedRequest, prompt, boundary);
  require(terminalBlock != 0,
          "offload fixture did not publish the terminal KV block");
  require(static_cast<bool>(storage.tryActivateSlot(0, seedRequest)),
          "offload source lane activation failed");
  const auto &source = storage.buffers(0);
  word(source.gdn[0].convolutionBase) = 0x21324354;
  word(source.gdn[0].recurrentBase) = 0x65768798;
  word(source.draft[0].keys) = 0x31425364;
  word(source.draft[0].values) = 0x758697a8;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});
  auto snapshot = storage.snapshot(0);
  require(snapshot != nullptr,
          "offload fixture could not snapshot the real Qwen lane");
  cache.publishCompositeState(terminalBlock, snapshot);
  snapshot.reset();
  cache.endRequest(seedRequest);

  cache.beginRequest(lookupRequest);
  auto pinned = cache.lookup(prompt);
  require(pinned.kvBoundary == boundary && pinned.state &&
              pinned.state->boundary() == boundary,
          "matching-prefix lookup did not find the pinned Qwen state");
  auto pinnedQwen =
      std::dynamic_pointer_cast<const model::QwenCompositeState>(
          pinned.state->state());
  require(pinnedQwen && cache.snapshot().stateCache.pinned == 1,
          "lookup did not lease and pin the concrete Qwen publication");
  require(!cache.reclaimOneState() && !cache.transfersInFlight() &&
              cache.stateResident(terminalBlock) && file->usedBytes() == 0,
          "reclaim started an offload or removed a pinned Qwen state");
  require(static_cast<bool>(storage.tryActivateSlot(1, lookupRequest)),
          "pinned-state verification lane activation failed");
  storage.restore(1, *pinnedQwen, true);
  require(word(storage.buffers(1).gdn[0].convolutionBase) == 0x21324354 &&
              word(storage.buffers(1).gdn[0].recurrentBase) == 0x65768798 &&
              word(storage.buffers(1).draft[0].keys) == 0x31425364 &&
              word(storage.buffers(1).draft[0].values) == 0x758697a8 &&
              storage.metadata(1).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary},
          "pinned lookup state was not usable for a complete Qwen restore");
  storage.releaseSlot(1, lookupRequest);
  pinned.state.reset();
  pinnedQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "releasing the lookup lease did not unpin the Qwen state");

  require(cache.reclaimOneState(),
          "unpinned Qwen state was not accepted for disk offload");
  auto pending = cache.snapshot();
  require(!cache.stateResident(terminalBlock) &&
              pending.stateCache.entries == 1 && pending.stateCache.bytes == 0 &&
              pending.stateCache.diskBytes == layout.cachedBytes() &&
              pending.stateCache.offloads == 1 && cache.transfersInFlight(),
          "accepted offload did not transfer ownership to its staging-backed ticket");
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
              disk.stateCache.offloadFailures == 0 && file->idle() &&
              file->usedBytes() == layout.cachedBytes(),
          "completed offload did not leave a successful disk-only publication");

  auto warm = cache.lookup(prompt);
  require(warm.kvBoundary == boundary && warm.state &&
              warm.state->boundary() == boundary,
          "same-process lookup did not rediscover the disk-backed state");
  auto warmQwen = std::dynamic_pointer_cast<const model::QwenCompositeState>(
      warm.state->state());
  require(warmQwen && warmQwen->residentBytes() == 0 &&
              cache.snapshot().stateCache.pinned == 1,
          "warm lookup did not lease a disk-backed Qwen state");
  require(static_cast<bool>(storage.tryActivateSlot(2, lookupRequest)),
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
              word(storage.buffers(2).gdn[0].convolutionBase) == 0x21324354 &&
              word(storage.buffers(2).gdn[0].recurrentBase) == 0x65768798 &&
              word(storage.buffers(2).draft[0].keys) == 0x31425364 &&
              word(storage.buffers(2).draft[0].values) == 0x758697a8,
          "disk warm restore lost target recurrent or draft state");
  restore.reset();
  storage.releaseSlot(2, lookupRequest);
  warm.state.reset();
  warmQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "releasing the warm lookup lease did not unpin the disk state");
  cache.endRequest(lookupRequest);
}

void testQwenAsyncOffloadFailureDoesNotPublishWarmState(
    metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 4}};
  constexpr kv::Layout kvLayout{1, 1, 16, kv::Format::BFloat16};
  auto budget = std::make_shared<model::DiskBudget>(layout.cachedBytes());
  auto file = std::make_shared<model::SlotFile>(layout.cachedBytes(), budget);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  kv::PageStorage pageStorage(backend, governor.allocationAdmission(), kvLayout,
                              kvLayout.backingExtentPages());
  KvPool kvPool(pageStorage);
  Cache cache(kvPool, CacheNamespace{}, nullptr, budget);
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
      cache.publishCommittedBlocks(seedRequest, prompt, boundary);
  require(terminalBlock != 0,
          "async failure fixture did not publish its terminal KV block");
  require(static_cast<bool>(storage.tryActivateSlot(0, seedRequest)),
          "async failure source lane activation failed");
  const auto &source = storage.buffers(0);
  word(source.gdn[0].convolutionBase) = convolutionMarker;
  word(source.gdn[0].recurrentBase) = recurrentMarker;
  word(source.draft[0].keys) = draftKeysMarker;
  word(source.draft[0].values) = draftValuesMarker;
  storage.updateLengths(0, lengths);
  const auto sourceIsIntact = [&] {
    return storage.metadata(0).lengths == lengths &&
           word(source.gdn[0].convolutionBase) == convolutionMarker &&
           word(source.gdn[0].recurrentBase) == recurrentMarker &&
           word(source.draft[0].keys) == draftKeysMarker &&
           word(source.draft[0].values) == draftValuesMarker;
  };

  auto state = storage.snapshot(0);
  require(state != nullptr && state->residentBytes() == layout.cachedBytes(),
          "async failure fixture could not make a resident Qwen snapshot");
  cache.publishCompositeState(terminalBlock, state);
  state.reset();
  cache.beginRequest(lookupRequest);

  auto initialLookup = cache.lookup(prompt);
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

    require(cache.reclaimOneState(),
            "StateCache did not accept asynchronous Qwen offload");
    const CacheSnapshot accepted = cache.snapshot();
    require(cache.transfersInFlight() &&
                accepted.stateCache.offloads == beforeOffload.offloads + 1 &&
                !cache.stateResident(terminalBlock) &&
                accepted.stateCache.bytes == 0,
            "accepted offload did not transfer the RAM publication to its in-flight write");

    auto pendingLookup = cache.lookup(prompt);
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
              file->idle() && !file->writable() && file->usedBytes() == 0,
          "failed async Qwen completion remained published or retained its SlotFile quota");

  auto cold = cache.lookup(prompt);
  require(cold.kvBoundary == boundary && !cold.state && cold.lostState,
          "failed async Qwen state did not fall cold at its retained KV boundary");
  cold.state.reset();
  require(sourceIsIntact(),
          "failed asynchronous offload changed the original live Qwen source lane");

  auto retrySnapshot = storage.snapshot(0);
  require(retrySnapshot != nullptr &&
              retrySnapshot->residentBytes() == layout.cachedBytes(),
          "valid source lane could not produce a fresh RAM retry snapshot");
  cache.publishCompositeState(terminalBlock, retrySnapshot);
  retrySnapshot.reset();
  auto retry = cache.lookup(prompt);
  require(retry.kvBoundary == boundary && retry.state &&
              retry.state->boundary() == boundary &&
              cache.stateResident(terminalBlock),
          "fresh RAM retry publication was not reusable at the retained boundary");
  auto retryQwen = std::dynamic_pointer_cast<const model::QwenCompositeState>(
      retry.state->state());
  require(retryQwen != nullptr && retryQwen->residentBytes() == layout.cachedBytes() &&
              sourceIsIntact() &&
              static_cast<bool>(storage.tryActivateSlot(1, lookupRequest)),
          "fresh Cache retry did not retain the original resident Qwen state");
  storage.restore(1, *retryQwen, true);
  require(storage.metadata(1).lengths == lengths &&
              word(storage.buffers(1).gdn[0].convolutionBase) ==
                  convolutionMarker &&
              word(storage.buffers(1).gdn[0].recurrentBase) == recurrentMarker &&
              word(storage.buffers(1).draft[0].keys) == draftKeysMarker &&
              word(storage.buffers(1).draft[0].values) == draftValuesMarker,
          "fresh RAM retry did not restore the original Qwen markers and lengths");

  storage.releaseSlot(1, lookupRequest);
  retry.state.reset();
  retryQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "retry lookup lease was not released after source verification");
  storage.releaseSlot(0, seedRequest);
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
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 4}};
  constexpr kv::Layout kvLayout{1, 1, 16, kv::Format::BFloat16};
  constexpr uint32_t boundary = 64;
  constexpr uint32_t sourceGdn = 0x11223344;
  constexpr uint32_t sourceRecurrent = 0x55667788;
  constexpr uint32_t sourceDraftKeys = 0x10203040;
  constexpr uint32_t sourceDraftValues = 0x50607080;
  constexpr uint64_t seedRequest = 7400;
  constexpr uint64_t warmRequest = 7401;
  constexpr uint64_t failedRequest = 7402;
  constexpr uint64_t retryRequest = 7403;

  auto budget = std::make_shared<model::DiskBudget>(layout.cachedBytes());
  auto file = std::make_shared<model::SlotFile>(layout.cachedBytes(), budget);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  kv::PageStorage pageStorage(backend, governor.allocationAdmission(), kvLayout,
                              kvLayout.backingExtentPages());
  KvPool kvPool(pageStorage);
  Cache cache(kvPool, CacheNamespace{}, nullptr, budget);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout,
                                  file);

  std::vector<uint32_t> prompt(boundary + 5);
  for (uint32_t i = 0; i < prompt.size(); ++i)
    prompt[i] = 0x6000 + i * 31;
  cache.beginRequest(seedRequest);
  require(cache.ensureTokens(seedRequest, boundary).granted(),
          "Engine Qwen fixture could not allocate the retained KV prefix");
  const uint64_t terminalBlock =
      cache.publishCommittedBlocks(seedRequest, prompt, boundary);
  require(terminalBlock != 0 &&
              cache.blockAt(seedRequest, boundary) == terminalBlock,
          "Engine Qwen fixture did not publish its complete retained KV page");
  require(static_cast<bool>(storage.tryActivateSlot(0, seedRequest)),
          "Engine Qwen fixture could not activate its source lane");
  const auto &source = storage.buffers(0);
  word(source.gdn[0].stateBase) = sourceGdn;
  word(source.gdn[0].recurrentBase) = sourceRecurrent;
  word(source.draft[0].keys) = sourceDraftKeys;
  word(source.draft[0].values) = sourceDraftValues;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});
  require(cache.publishStateToDisk(
              terminalBlock,
              [&](std::function<void()> completion) {
                return storage.snapshotToDisk(0, std::move(completion));
              }),
          "real Qwen state was not admitted to the retained disk tier");
  while (cache.transfersInFlight()) {
    static_cast<void>(cache.pollTransfers());
    if (cache.transfersInFlight())
      std::this_thread::yield();
  }
  storage.releaseSlot(0, seedRequest);
  cache.endRequest(seedRequest);
  require(file->idle() && file->usedBytes() == layout.cachedBytes(),
          "retained Qwen SlotFile publication did not finish");

  CacheLookup precondition = cache.lookup(prompt);
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
  Engine engine(config, cache, model, events);

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
              warmStarted.front().cacheStatus == EngineCacheStatus::PrefixHit &&
              warmStarted.front().matchedTokens == boundary,
          "warm Engine Started event did not report the retained boundary");
  const auto warmProgress = progressFor(events, warmRequest);
  require(warmProgress.size() >= 2 && warmProgress.front().tokens == boundary,
          "warm Engine progress did not begin at the retained boundary");
  const auto warmWork = prefillWorkFor(model, warmRequest);
  require(!warmWork.empty() && warmWork.front().promptOffset == boundary,
          "first warm Engine prefill did not start at the retained boundary");
  uint64_t warmRows = 0;
  for (const auto &work : warmWork) {
    require(work.promptOffset >= boundary,
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
              model.successfulRestores.back().draftKeyMarker ==
                  sourceDraftKeys &&
              model.successfulRestores.back().draftValueMarker ==
                  sourceDraftValues,
          "real FileRestore did not restore GDN, recurrent, draft, and logical state");

  // A successful optional promotion may add a RAM copy. Drop only that
  // redundant copy so Proof B again exercises the same immutable disk source.
  require(cache.reclaimOneState(),
          "could not return the successful warm promotion to disk-only form");
  CacheLookup diskAgain = cache.lookup(prompt);
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
  require(file->idle(),
          "restore completion observer ran before SlotFile IO became idle");
  require(startedFor(events, failedRequest).empty(),
          "failed restore admission published Started before finish()");
  const uint32_t failedSlot = model.slotFor(failedRequest);
  const uint32_t activeParity = storage.metadata(failedSlot).activeParity;
  auto *destinationBytes = static_cast<uint8_t *>(
      storage.buffers(failedSlot).gdn[activeParity].stateBase.contents());
  require(destinationBytes != nullptr,
          "failed restore destination is not CPU-visible");
  destinationBytes[0] ^= 0x01;
  require(engine.tick(11.0),
          "Engine did not consume and recover from failed FileRestore");
  require(model.successfulRestores.size() == 1,
          "failed FileRestore committed or exposed a destination snapshot");
  const auto failedStarted = startedFor(events, failedRequest);
  require(failedStarted.size() == 1 &&
              failedStarted.front().cacheStatus == EngineCacheStatus::Miss &&
              failedStarted.front().matchedTokens == 0,
          "failed FileRestore emitted a warm PrefixHit instead of cold fallback");
  finishEngineRequest(engine, 12.0,
                      "failed-restore request did not finish its cold fallback");
  const auto failedDone = doneFor(events, failedRequest);
  require(failedDone.size() == 1 && failedDone.front().promptTokens == prompt.size(),
          "failed-restore request did not complete after cold fallback");
  const auto failedWork = prefillWorkFor(model, failedRequest);
  require(!failedWork.empty() && failedWork.front().promptOffset == 0,
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
              cacheAfterFailure.stateCache.pinned == 0 && file->idle() &&
              file->usedBytes() == layout.cachedBytes(),
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
  CacheLookup retryable = cache.lookup(prompt);
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
              retryStarted.front().cacheStatus == EngineCacheStatus::PrefixHit &&
              retryStarted.front().matchedTokens == boundary,
          "later warm retry did not publish a PrefixHit at the retained boundary");
  const auto retryProgress = progressFor(events, retryRequest);
  require(retryProgress.size() >= 2 &&
              retryProgress.front().tokens == boundary,
          "later warm retry progress did not start at the retained boundary");
  const auto retryWork = prefillWorkFor(model, retryRequest);
  require(!retryWork.empty() && retryWork.front().promptOffset == boundary,
          "later warm retry replayed prefill from zero");
  uint64_t retryRows = 0;
  for (const auto &work : retryWork) {
    require(work.promptOffset >= boundary,
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
              model.successfulRestores.back().draftKeyMarker ==
                  sourceDraftKeys &&
              model.successfulRestores.back().draftValueMarker ==
                  sourceDraftValues,
          "later warm retry did not restore the original Qwen source values");
  require(file->idle() && file->usedBytes() == layout.cachedBytes(),
          "successful retry damaged the retained SlotFile source");
}

void testCorruptQwenDiskPayloadFallsBackCold(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 4}};
  constexpr kv::Layout kvLayout{1, 1, 16, kv::Format::BFloat16};
  constexpr uint32_t boundary = 64;
  constexpr uint64_t seedRequest = 7301;
  constexpr uint64_t restoreRequest = 7302;
  auto budget = std::make_shared<model::DiskBudget>(layout.cachedBytes());
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  kv::PageStorage pageStorage(backend, governor.allocationAdmission(), kvLayout,
                              kvLayout.backingExtentPages());
  KvPool kvPool(pageStorage);
  const auto before = unlinkedRegularDescriptors();
  auto file = std::make_shared<model::SlotFile>(layout.cachedBytes(), budget);
  const auto after = unlinkedRegularDescriptors();
  std::vector<int> added;
  std::set_difference(after.begin(), after.end(), before.begin(), before.end(),
                      std::back_inserter(added));
  require(added.size() == 1,
          "could not uniquely identify the Qwen SlotFile descriptor");
  const int descriptor = added.front();

  Cache cache(kvPool, CacheNamespace{}, nullptr, budget);
  model::QwenStateStorage storage(backend, governor.allocationAdmission(), layout,
                                  file);
  std::vector<uint32_t> prompt(boundary + 1);
  for (uint32_t i = 0; i < prompt.size(); ++i)
    prompt[i] = 0x4000 + i * 29;
  cache.beginRequest(seedRequest);
  require(cache.ensureTokens(seedRequest, boundary).granted(),
          "corruption fixture could not allocate a KV page");
  const uint64_t terminalBlock =
      cache.publishCommittedBlocks(seedRequest, prompt, boundary);
  require(terminalBlock != 0,
          "corruption fixture did not publish its KV terminal block");
  require(static_cast<bool>(storage.tryActivateSlot(0, seedRequest)),
          "corruption source lane activation failed");
  const auto &source = storage.buffers(0);
  word(source.gdn[0].stateBase) = 0x12345678;
  word(source.draft[0].keys) = 0x23456789;
  word(source.draft[0].values) = 0x3456789a;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});

  require(cache.publishStateToDisk(
              terminalBlock,
              [&](std::function<void()> completion) {
                return storage.snapshotToDisk(0, std::move(completion));
              }),
          "real Qwen state did not publish to disk");
  while (cache.transfersInFlight())
    static_cast<void>(cache.pollTransfers());
  require(file->usedBytes() == layout.cachedBytes() && file->idle(),
          "Qwen disk publication did not complete into its slot");

  auto warm = cache.lookup(prompt);
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

  require(static_cast<bool>(storage.tryActivateSlot(1, restoreRequest)),
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
  auto cold = cache.lookup(prompt);
  require(cold.kvBoundary == boundary && !cold.state,
          "corrupt composite state remained available to exact-prompt lookup");
  require(cold.lostState,
          "discarded corrupt state was not reported as a lost-state cold miss");
  cache.endRequest(seedRequest);
  cache.endRequest(restoreRequest);
}

void testQwenQuotaRefusalDoesNotPublishAndRetries(metal::MetalBackend &backend) {
  constexpr model::CompositeStateLayout layout{
      {1, 3, 128, 1, 128, 128}, {1, 1, 2048, 4}};
  constexpr kv::Layout kvLayout{1, 1, 16, kv::Format::BFloat16};
  auto budget = std::make_shared<model::DiskBudget>(layout.cachedBytes());
  auto file = std::make_shared<model::SlotFile>(layout.cachedBytes(), budget);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  kv::PageStorage pageStorage(backend, governor.allocationAdmission(), kvLayout,
                              kvLayout.backingExtentPages());
  KvPool kvPool(pageStorage);
  Cache cache(kvPool, CacheNamespace{}, nullptr, budget);
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
      cache.publishCommittedBlocks(seedRequest, prompt, boundary);
  require(terminalBlock != 0,
          "quota fixture did not publish the terminal KV block");
  require(static_cast<bool>(storage.tryActivateSlot(0, seedRequest)),
          "quota source lane activation failed");
  const auto &source = storage.buffers(0);
  word(source.gdn[0].convolutionBase) = 0x41526374;
  word(source.gdn[0].recurrentBase) = 0x8596a7b8;
  word(source.draft[0].keys) = 0x51627384;
  word(source.draft[0].values) = 0x95a6b7c8;
  storage.updateLengths(0, {boundary, 0, boundary, boundary});
  auto occupiedSlot = file->acquire();
  require(occupiedSlot && file->usedBytes() == layout.cachedBytes(),
          "could not deterministically occupy the sole Qwen disk slot");

  const auto before = cache.snapshot().stateCache;
  const bool refused = cache.publishStateToDisk(
      terminalBlock,
      [&](std::function<void()> completion) {
        return storage.snapshotToDisk(0, std::move(completion));
      });
  const auto afterRefusal = cache.snapshot();
  require(!refused && afterRefusal.stateCache.entries == before.entries &&
              afterRefusal.stateCache.publications == before.publications &&
              afterRefusal.stateCache.diskBytes == before.diskBytes &&
              !afterRefusal.stateCache.bytes && !cache.transfersInFlight() &&
              file->usedBytes() == layout.cachedBytes(),
          "quota refusal created a StateCache publication or transfer");
  auto coldLookup = cache.lookup(prompt);
  require(coldLookup.kvBoundary == boundary && !coldLookup.state,
          "quota refusal produced a false warm state in exact-prompt lookup");
  require(storage.metadata(0).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              word(source.gdn[0].convolutionBase) == 0x41526374 &&
              word(source.gdn[0].recurrentBase) == 0x8596a7b8 &&
              word(source.draft[0].keys) == 0x51627384 &&
              word(source.draft[0].values) == 0x95a6b7c8,
          "quota refusal damaged the retryable source lane");
  coldLookup.state.reset();
  occupiedSlot.reset();
  require(file->usedBytes() == 0,
          "releasing the quota holder did not restore the slot budget");

  const bool accepted = cache.publishStateToDisk(
      terminalBlock,
      [&](std::function<void()> completion) {
        return storage.snapshotToDisk(0, std::move(completion));
      });
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
  auto warm = cache.lookup(prompt);
  require(warm.kvBoundary == boundary && warm.state &&
              warm.state->boundary() == boundary,
          "retry publication was not discoverable through the same KV prefix");
  auto warmQwen = std::dynamic_pointer_cast<const model::QwenCompositeState>(
      warm.state->state());
  require(warmQwen && warmQwen->residentBytes() == 0,
          "retry publication did not produce a disk-backed Qwen state");
  require(static_cast<bool>(storage.tryActivateSlot(1, lookupRequest)),
          "quota retry restore lane activation failed");
  bool committed = false;
  auto restore = storage.beginRestore(1, *warmQwen, true, {},
                                      [&] { committed = true; });
  require(restore != nullptr && finishWhenReady(*restore) && committed,
          "retry publication did not restore from its disk snapshot");
  require(storage.metadata(1).lengths ==
                  model::QwenLogicalLengths{boundary, 0, boundary, boundary} &&
              word(storage.buffers(1).gdn[0].convolutionBase) == 0x41526374 &&
              word(storage.buffers(1).gdn[0].recurrentBase) == 0x8596a7b8 &&
              word(storage.buffers(1).draft[0].keys) == 0x51627384 &&
              word(storage.buffers(1).draft[0].values) == 0x95a6b7c8,
          "quota retry restore lost target recurrent or draft state");
  restore.reset();
  storage.releaseSlot(1, lookupRequest);
  warm.state.reset();
  warmQwen.reset();
  require(cache.snapshot().stateCache.pinned == 0,
          "releasing the quota retry lease did not unpin its state");
  storage.releaseSlot(0, seedRequest);
  cache.endRequest(seedRequest);
  cache.endRequest(lookupRequest);
}

// A lane whose state no cache slot can hold writes it from its own cells: no
// cache buffer is taken, the disk copy restores every byte of the active
// parity, one write holds the staging buffer at a time, and a full quota
// refuses until a disk copy is dropped.
void testDirectDiskSnapshot(metal::MetalBackend &backend) {
  MemoryGovernor governor(backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  model::QwenStateStorage storage(
      backend, governor.allocationAdmission(), kStateLayout,
      std::make_shared<model::SlotFile>(kStateLayout.cachedBytes(), kStateLayout.cachedBytes()));
  require(storage.canSnapshotToDisk(), "a state file that holds one state refuses writes");
  require(static_cast<bool>(storage.tryActivateSlot(0, 321)), "lane activation failed");
  const auto &buffers = storage.buffers(0);
  storage.swapParity(0);
  fill(buffers.gdn[0].stateBase, 8);
  fill(buffers.gdn[1].stateBase, 7);
  word(buffers.gdn[1].stateBase) = 0x0badf00d;
  for (size_t layer = 0; layer < buffers.draft.size(); ++layer) {
    fill(buffers.draft[layer].keys, 20 + 2 * layer);
    fill(buffers.draft[layer].values, 21 + 2 * layer);
  }
  const auto inactive = bytesOf(buffers.gdn[0].stateBase);
  const auto images = stateImage(buffers, 1);
  storage.updateLengths(0, {4096, 2048, 2048, 0});
  const uint64_t before = storage.actualAllocatedBytes();
  auto write = storage.snapshotToDisk(0, {});
  require(write != nullptr, "direct disk snapshot was not admitted");
  require(storage.actualAllocatedBytes() == before && storage.idleCells() == 0 &&
              storage.idleRings() == 0,
          "direct disk snapshot took a cache slot");
  auto disk = write->state();
  require(disk && !disk->residentBytes() && disk->bytes() == kStateLayout.cachedBytes(),
          "the ticket does not carry a disk copy");
  // The write reads staging, so the lane may move on at once; one write
  // holds the staging buffer at a time.
  word(buffers.gdn[1].stateBase) = 0;
  requireThrows<std::logic_error>([&] { static_cast<void>(storage.snapshotToDisk(0, {})); },
                                  "a second write joined the one in flight");
  require(finishWhenReady(*write), "direct disk write failed");
  write.reset();
  require(storage.snapshotToDisk(0, {}) == nullptr, "a full quota admitted a second state");

  fill(buffers.gdn[1].stateBase, 99);
  for (const auto &layer : buffers.draft) {
    fill(layer.keys, 98);
    fill(layer.values, 97);
  }
  storage.updateLengths(0, {});
  bool committed = false;
  auto read = storage.beginRestore(0, *disk, true, {}, [&] { committed = true; });
  require(finishWhenReady(*read) && committed, "restore of the direct disk copy failed");
  read.reset();
  require(stateImage(buffers, 1) == images &&
              word(buffers.gdn[1].stateBase) == 0x0badf00d &&
              storage.metadata(0).lengths.targetTokens == 4096,
          "the disk copy did not reproduce the lane's active state");
  require(sameBytes(buffers.gdn[0].stateBase, inactive), "the inactive parity was touched");
  disk.reset();
  auto again = storage.snapshotToDisk(0, {});
  require(again != nullptr, "the dropped disk copy did not free its quota");
  require(finishWhenReady(*again), "the second direct disk write failed");
  again.reset();
  storage.releaseSlot(0, 321);
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
  testRetainableQwenMatchingPrefixGraph(backend);
  testQwenCacheOffloadWarmLookup(backend);
  testQwenAsyncOffloadFailureDoesNotPublishWarmState(backend);
  testQwenDiskRestoreTransactionThroughEngine(backend);
  testCorruptQwenDiskPayloadFallsBackCold(backend);
  testQwenQuotaRefusalDoesNotPublishAndRetries(backend);
  MemoryGovernor governor(
      backend, backend.capabilities().recommendedMaxWorkingSetBytes, 1);
  // Switched off to prove that a pooled cache slot needs no new admission.
  bool admitNewAllocations = true;
  auto admitState = [&governor, &admitNewAllocations](
                        uint64_t bytes,
                        const std::function<void()> &allocate) {
    if (!admitNewAllocations)
      return false;
    auto reservation = governor.tryReserve(bytes);
    if (!reservation)
      return false;
    allocate();
    reservation->commit();
    return true;
  };
  constexpr kv::Layout kvLayout{16, 4, 256};
  kv::PageStorage pageStorage(backend, governor.allocationAdmission(),
                                kvLayout,
                                kvLayout.sparseMappingBatchPages());
  uint64_t beforeStorage = backend.memoryStats().allocatedBytes;
  uint64_t observedStorageActual = 0;
  uint64_t observedSlotActual = 0;
  uint64_t observedPrefixActual = 0;

  {
    QwenStateStorage storage(backend, admitState, kStateLayout);
    observedStorageActual = storage.actualAllocatedBytes();
    observedSlotActual = storage.actualSlotBytes(0);
    require(storage.actualAllocatedBytes() == 0 &&
                backend.memoryStats().allocatedBytes == beforeStorage,
            "state cells were allocated eagerly");
    for (uint32_t slot = 0;
         slot < model::ExecutionLimits::maximumBatchWidth;
         ++slot) {
      require(!storage.metadata(slot).assigned, "slot was assigned eagerly");
      require(storage.actualSlotBytes(slot) == 0,
              "idle slot has physical backing before activation");
    }
    requireThrows<std::out_of_range>(
        [&] { static_cast<void>(storage.buffers(4)); },
        "storage exposed more than four slots");

    require(storage.tryActivateSlot(0, 101) && storage.tryActivateSlot(1, 202),
            "state cell activation failed");
    observedStorageActual = storage.actualAllocatedBytes();
    observedSlotActual = storage.actualSlotBytes(0);
    require(observedSlotActual >= kStateLayout.activeCellBytes(),
            "activated slot allocation is below declared bytes");
    require(storage.actualSlotBytes(1) == observedSlotActual &&
                storage.actualAllocatedBytes() == 2 * observedSlotActual,
            "activated slot accounting is not incremental");

    const auto &slot0 = storage.buffers(0);
    const auto &slot1 = storage.buffers(1);
    void *stableGdnBase = slot0.gdn[0].stateBase.contents();
    void *stableConvBase = slot0.gdn[0].convolutionBase.contents();
    void *stableDraftBase = slot0.draft[0].keys.contents();
    require(stableGdnBase && stableConvBase && stableDraftBase,
            "stable slot buffers are not CPU-visible");
    require(stableGdnBase != slot1.gdn[0].stateBase.contents(),
            "two slots alias one GDN allocation");
    require(slot0.gdn[0].convolutionLayers[1].contents() ==
                static_cast<uint8_t *>(stableConvBase) +
                    kTargetState.convolutionLayerBytes(),
            "GDN layer view offset is wrong");
    require(slot0.gdn[0].stateBase.sizeBytes() ==
                    kTargetState.cellBytes() &&
                slot0.draft.size() == kDraftState.layers &&
                slot0.draft[0].keys.sizeBytes() == kDraftState.tensorBytes(),
            "split state-buffer sizes are wrong");

    require(storage.metadata(0).assigned &&
                storage.metadata(0).requestId == 101 &&
                storage.metadata(0).activeParity == 0,
            "slot activation metadata is wrong");
    requireThrows<std::logic_error>(
        [&] { static_cast<void>(storage.tryActivateSlot(0, 303)); },
        "double slot activation was accepted");

    // Hot metadata updates must leave every buffer and marker untouched.
    word(slot0.gdn[0].convolutionBase) = 0x10101010;
    word(slot0.gdn[1].convolutionBase) = 0x21212121;
    word(slot0.gdn[1].recurrentBase) = 0x31313131;
    word(slot0.draft[0].keys) = 0x41414141;
    word(slot0.draft[4].values,
         kDraftState.tensorBytes() - sizeof(uint32_t)) = 0x51515151;
    QwenLogicalLengths lengths{2'048, 0, 2'048, 0};
    storage.updateLengths(0, lengths);
    require(storage.metadata(0).lengths.draftCommitCursor == 0,
            "draft ring cursor is wrong");
    require(storage.metadata(0).lengths.draftLength == 2'048,
            "draft resident length is wrong");
    require(word(slot0.gdn[1].convolutionBase) == 0x21212121 &&
                word(slot0.draft[0].keys) == 0x41414141,
            "length update copied or cleared hot state");
    storage.swapParity(0);
    require(storage.metadata(0).activeParity == 1,
            "parity swap did not select parity one");
    require(word(slot0.gdn[0].convolutionBase) == 0x10101010 &&
                word(slot0.gdn[1].convolutionBase) == 0x21212121,
            "parity swap copied hot state");

    // Publication copies the lane's active-parity GDN cell and its draft
    // ring into a cache slot the governor admits. The lane keeps its own
    // cells: no address changes, no aliasing, no parity handoff.
    const uint64_t beforePrefix = backend.memoryStats().allocatedBytes;
    const uint64_t storageBeforePrefix = storage.actualAllocatedBytes();
    void *laneActiveGdnBase = slot0.gdn[1].stateBase.contents();
    std::shared_ptr<const QwenCompositeState> prefix = storage.snapshot(0);
    require(prefix != nullptr, "snapshot could not obtain a cache slot");
    observedPrefixActual = backend.memoryStats().allocatedBytes - beforePrefix;
    require(prefix->bytes() == kStateLayout.cachedBytes(),
            "cached state footprint is not the declared cached bytes");
    require(observedPrefixActual >= kStateLayout.cachedBytes() &&
                storage.actualAllocatedBytes() ==
                    storageBeforePrefix + observedPrefixActual,
            "cache slot allocation is below declared bytes or unaccounted");
    require(slot0.gdn[1].stateBase.contents() == laneActiveGdnBase &&
                slot0.gdn[0].stateBase.contents() == stableGdnBase &&
                slot0.draft[0].keys.contents() == stableDraftBase,
            "snapshot moved or aliased the lane's own cells");
    require(storage.metadata(0).activeParity == 1 &&
                storage.metadata(0).lengths == lengths,
            "snapshot changed the lane's metadata");

    // The cached copy is independent of the lane: writes to the lane's
    // active cell or draft ring after publication never reach a restore.
    word(slot0.gdn[1].convolutionBase) = 0xa1a1a1a1;
    word(slot0.gdn[1].recurrentBase) = 0xa2a2a2a2;
    word(slot0.draft[0].keys) = 0xa3a3a3a3;
    word(slot1.gdn[0].convolutionBase) = 0xb0b0b0b0;
    word(slot1.gdn[1].convolutionBase) = 0xb1b1b1b1;
    word(slot1.draft[0].keys) = 0xb2b2b2b2;
    void *destinationGdnBase = slot1.gdn[0].stateBase.contents();
    void *destinationDraftBase = slot1.draft[0].keys.contents();
    storage.restore(1, *prefix, true);

    require(storage.metadata(1).requestId == 202 &&
                storage.metadata(1).activeParity == 0 &&
                storage.metadata(1).lengths == lengths,
            "restore lost owner, changed parity, or lengths");
    require(slot1.gdn[0].stateBase.contents() == destinationGdnBase &&
                slot1.draft[0].keys.contents() == destinationDraftBase,
            "restore replaced the destination's buffers");
    require(word(slot1.gdn[0].convolutionBase) == 0x21212121 &&
                word(slot1.gdn[0].recurrentBase) == 0x31313131,
            "restore did not deliver the pre-mutation GDN snapshot");
    require(word(slot1.gdn[1].convolutionBase) == 0xb1b1b1b1,
            "restore overwrote inactive parity");
    require(
        word(slot1.draft[0].keys) == 0x41414141 &&
            word(slot1.draft[4].values, kDraftState.tensorBytes() -
                                            sizeof(uint32_t)) == 0x51515151,
        "restore did not deliver the pre-mutation draft ring snapshot");
    require(word(slot0.gdn[1].convolutionBase) == 0xa1a1a1a1 &&
                word(slot0.gdn[1].recurrentBase) == 0xa2a2a2a2 &&
                word(slot0.draft[0].keys) == 0xa3a3a3a3,
            "restore wrote back into the source lane");

    // A suffix that will rebuild a full 2048-token window restores only GDN.
    // A cached draft ring must not consume a 40 MiB copy merely to be
    // overwritten by the next prefill commands.
    storage.swapParity(1);
    word(slot1.draft[0].keys) = 0xd2d2d2d2;
    storage.restore(1, *prefix, false);
    require(word(slot1.gdn[storage.metadata(1).activeParity].convolutionBase) ==
                0x21212121,
            "GDN-only restore did not restore convolution state");
    require(word(slot1.draft[0].keys) == 0xd2d2d2d2,
            "GDN-only restore copied an obsolete draft ring");
    require(storage.metadata(1).lengths.targetTokens == 2048 &&
                storage.metadata(1).lengths.draftLength == 0 &&
                storage.metadata(1).lengths.draftBase == 2048,
            "GDN-only restore exposed stale draft metadata");
    // Cancellation releases ownership and returns the lane's buffers to the
    // pool. Reactivation takes them back in the same order and initializes
    // every state that can be read at logical length zero.
    void *reusableGdnBase = slot0.gdn[0].stateBase.contents();
    void *reusableDraftBase = slot0.draft[0].keys.contents();
    word(slot0.gdn[0].convolutionBase) = 0xc1c1c1c1;
    word(slot0.gdn[0].recurrentBase) = 0xc2c2c2c2;
    storage.releaseSlot(0, 101);
    require(!storage.metadata(0).assigned && storage.metadata(0).requestId == 0,
            "cancellation did not release metadata");
    require(storage.idleCells() == 2 && storage.idleRings() == 1 &&
                storage.actualSlotBytes(0) == 0,
            "released lane buffers did not return to the pool");
    requireThrows<std::logic_error>([&] { storage.swapParity(0); },
                                    "unassigned slot accepted a parity update");
    require(static_cast<bool>(storage.tryActivateSlot(0, 303)), "state cell reuse failed");
    require(storage.idleCells() == 0 && storage.idleRings() == 0,
            "reactivation left pooled buffers behind");
    require(slot0.gdn[0].stateBase.contents() == reusableGdnBase &&
                slot0.draft[0].keys.contents() == reusableDraftBase,
            "slot reuse changed stable buffer addresses");
    require(storage.metadata(0).requestId == 303 &&
                storage.metadata(0).activeParity == 0 &&
                storage.metadata(0).lengths == QwenLogicalLengths{},
            "slot reuse did not reset logical state");
    require(word(slot0.gdn[0].convolutionBase) == 0 &&
                word(slot0.gdn[0].recurrentBase) == 0,
            "slot reuse did not initialize readable state");

    // Rejected publications fail before any cache slot is taken or admitted.
    const uint64_t beforeRejected = storage.actualAllocatedBytes();
    storage.updateLengths(0, {128, 0, 127, 127});
    requireThrows<std::invalid_argument>(
        [&] { static_cast<void>(storage.snapshot(0)); },
        "snapshot accepted divergent target/draft lengths");
    requireThrows<std::invalid_argument>(
        [&] {
          storage.updateLengths(0, {129, 0, 129, 129});
          static_cast<void>(storage.snapshot(0));
        },
        "unaligned prefix snapshot was accepted");
    require(storage.actualAllocatedBytes() == beforeRejected,
            "rejected snapshot allocated or consumed a cache slot");
    requireThrows<std::logic_error>([&] { storage.releaseSlot(0, 404); },
                                    "slot release accepted the wrong owner");

    const uint64_t beforeSuspend = storage.actualAllocatedBytes();
    const uint64_t releasedSlotBytes = storage.actualSlotBytes(0);
    storage.releaseSlot(0, 303);
    require(storage.releaseIdle(0, 0) == releasedSlotBytes,
            "recomputation preemption retained active backing");
    require(!storage.metadata(0).assigned && storage.actualSlotBytes(0) == 0 &&
                storage.actualAllocatedBytes() == beforeSuspend - releasedSlotBytes,
            "preempted GDN or draft bytes remain outside the cache");
    require(storage.tryActivateSlot(0, 303) &&
                storage.metadata(0).assigned &&
                storage.metadata(0).lengths == QwenLogicalLengths{} &&
                word(slot0.gdn[0].convolutionBase) == 0 &&
                word(slot0.gdn[0].recurrentBase) == 0,
            "recomputation did not start from a fresh empty state");

    // Dropping a cached state returns its buffers to the storage's pool rather
    // than freeing them: accounting stays flat, and the next publication takes
    // the pooled buffers without a governor admission. Only releaseIdle
    // returns pooled bytes to macOS.
    const uint64_t beforeDrop = storage.actualAllocatedBytes();
    const uint64_t backendBeforeDrop = backend.memoryStats().allocatedBytes;
    prefix.reset();
    require(storage.actualAllocatedBytes() == beforeDrop &&
                backend.memoryStats().allocatedBytes == backendBeforeDrop,
            "dropped cached state freed its slot instead of pooling it");
    storage.updateLengths(0, lengths);
    word(slot0.gdn[0].convolutionBase) = 0xe1e1e1e1;
    word(slot0.gdn[0].recurrentBase) = 0xe2e2e2e2;
    word(slot0.draft[0].keys) = 0xe3e3e3e3;
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
    storage.restore(1, *pooled, true);
    require(storage.metadata(1).activeParity == 1 &&
                storage.metadata(1).lengths == lengths &&
                word(slot1.gdn[1].convolutionBase) == 0xe1e1e1e1 &&
                word(slot1.gdn[1].recurrentBase) == 0xe2e2e2e2 &&
                word(slot1.draft[0].keys) == 0xe3e3e3e3,
            "reused cache slot served stale contents");
    require(word(slot1.gdn[0].convolutionBase) == 0x21212121,
            "restore from the reused slot overwrote inactive parity");
    pooled.reset();
    require(storage.actualAllocatedBytes() == beforeDrop,
            "second dropped cached state was freed instead of pooled");
    require(storage.releaseIdle(0, 0) == observedPrefixActual &&
                storage.actualAllocatedBytes() ==
                    beforeDrop - observedPrefixActual,
            "releaseIdle did not free the pooled cache slot");
    require(storage.metadata(0).assigned && storage.metadata(1).assigned &&
                storage.actualSlotBytes(0) == observedSlotActual &&
                storage.actualSlotBytes(1) == observedSlotActual,
            "pool reclaim touched active lane cells");

    // A live cached state survives its lane's release and reclaim; only its
    // drop plus a later reclaim frees the slot together with idle cells.
    std::shared_ptr<const QwenCompositeState> retained = storage.snapshot(1);
    require(retained != nullptr, "retained snapshot could not admit a slot");
    require(storage.actualAllocatedBytes() ==
                2 * observedSlotActual + observedPrefixActual,
            "retained snapshot accounting is wrong");
    storage.releaseSlot(0, 303);
    storage.releaseSlot(1, 202);
    require(storage.idleCells() == 4 && storage.idleRings() == 2,
            "released lane buffers are missing from the pool");
    retained.reset();
    require(storage.idleCells() == 5 && storage.idleRings() == 3,
            "dropped cached state did not return its buffers to the pool");
    // Releasing down to one lane's worth keeps two cells and one ring warm.
    require(storage.releaseIdle(2, 1) ==
                observedSlotActual + observedPrefixActual &&
                storage.idleCells() == 2 && storage.idleRings() == 1,
            "partial idle release did not keep the requested buffers");
    require(storage.releaseIdle(0, 0) == observedSlotActual,
            "idle lane buffers were not reclaimed");
    require(storage.idleCells() == 0 && storage.idleRings() == 0,
            "reclaimed buffers remain pooled");
    require(storage.actualAllocatedBytes() == 0,
            "reclaimed state cells remain accounted");
  }
  require(backend.memoryStats().allocatedBytes == beforeStorage,
          "destroyed state slots remained in actual allocation count");

  std::cout << "qwen state storage tests passed: slot_declared="
            << kStateLayout.activeCellBytes()
            << " slot_actual=" << observedSlotActual << " four_slots_declared="
            << uint64_t{model::ExecutionLimits::maximumBatchWidth} *
                   kStateLayout.activeCellBytes()
            << " four_slots_actual=" << observedStorageActual
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
