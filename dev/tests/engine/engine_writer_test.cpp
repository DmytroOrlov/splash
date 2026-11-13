#include "TestMetalMemory.hpp"
#include "TestExecutor.hpp"
#include "TestKvPool.hpp"
#include "engine/ResourceDomainLease.hpp"
#include "engine/ReleasableMemory.hpp"
#include <condition_variable>
#include <chrono>
#include <thread>
#include <iostream>

using namespace splash;
using namespace splash::engine;
using test::require;

struct Events : EngineEventSink {
  unsigned completedCount = 0, failedCount = 0;
  std::unordered_map<uint64_t, EngineFinishReason> reasons;
  void batchCompleted(WorkKind, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double) override {}
  void started(uint64_t, uint32_t, uint32_t) override {}
  void tokens(uint64_t, std::span<const uint32_t>) override {}
  void maskRequested(uint64_t, std::span<const uint32_t>) override {}
  void completed(uint64_t id, EngineFinishReason reason, bool, uint32_t, uint32_t, uint32_t,
                 std::span<const float>, const SpeculativeCounts &) override { ++completedCount; reasons[id] = reason; }
  void failed(uint64_t, LaneOutcome, std::string, uint32_t) override { ++failedCount; }
};
EngineRequest request(uint64_t id, std::vector<uint32_t> prompt) {
  EngineRequest r; r.id = id; r.prompt = std::move(prompt); r.maxNewTokens = 1; r.deadlineMilliseconds = 10000; return r;
}

struct Gate {
  std::mutex mutex;
  std::condition_variable cv;
  bool entered = false, open = false;
  void block() {
    std::unique_lock lock(mutex); entered = true; cv.notify_all();
    cv.wait(lock, [&] { return open; });
  }
  void wait() {
    std::unique_lock lock(mutex);
    require(cv.wait_for(lock, std::chrono::seconds(5), [&] { return entered; }), "gate timed out");
  }
  void release() { std::lock_guard lock(mutex); open = true; cv.notify_all(); }
};
template <class F> bool refuses(F &&f) { try { f(); return false; } catch (...) { return true; } }
struct ExtraReceiver final : model::WeightMemory {
  std::function<void()> notifier;
  bool released() const noexcept override { return false; }
  void release() override {}
  bool restore(const metal::AllocationAdmission &) override { return true; }
  void setCompletionNotifier(std::function<void()> f) override { notifier = std::move(f); }
  void completionRecipients(std::vector<model::WeightMemory *> &out) override { out.push_back(this); }
  void swapCompletionNotifier(std::function<void()> &f) noexcept override { notifier.swap(f); }
  uint32_t notifierBindings() const noexcept override { return notifier ? 1 : 0; }
};
// Controlled WeightMemory mechanism, exercising production Engine, Scope,
// WeightResidency and authenticated W1. No inference or real model is loaded.
struct Images final : model::WeightMemory {
  ResourceDomainLease &lease;
  metal::AllocationAdmission admit;
  model::WeightWriteScope scope;
  std::function<void()> notifier;
  model::WriterRetirementPort *receipt = nullptr;
  bool missing = false, prepared = false, taken = false, failLaunch = false, failWrite = false;
  std::atomic<bool> ended{false};
  std::atomic<unsigned> writes{0};
  std::exception_ptr failure;
  Gate *body = nullptr;
  Images(ResourceDomainLease &l) : lease(l) {}
  bool released() const noexcept override { return missing; }
  void release() override { require(!writerIntervalActive(), "released active writer"); missing = true; taken = false; }
  bool restore(const metal::AllocationAdmission &a) override {
    lease.check("prepare owner");
    require(!writerIntervalActive(), "restore before retirement");
    if (taken) { missing = false; return true; }
    require(bool(a(1, [] {})), "Owner scope absent");
    admit = a; prepared = true; taken = true; return false;
  }
  void enableExternalWriter() override {}
  void setWeightWriteScope(model::WeightWriteScope value) override { scope = std::move(value); }
  bool hasPreparedWriter() const noexcept override { return prepared; }
  bool writerIntervalActive() const noexcept override { return prepared || receipt; }
  bool writing() const noexcept override { return writerIntervalActive(); }
  void launchPreparedWriter(model::WriterRetirementPort &r) override {
    if (failLaunch) throw std::runtime_error("launch failure");
    r.launch([this, notify = notifier, run = scope] {
      try {
        run([&] {
          lease.check("authenticated writer");
          require(bool(admit(1, [] {})), "Writer scope or retained claim absent");
          ++writes;
          if (body) body->block();
          if (failWrite) throw metal::MetalAllocationError("write refused", metal::AllocationFailure::HostPressure);
        });
      } catch (...) { failure = std::current_exception(); }
      ended = true;
      if (notify) notify();
    });
    receipt = &r; prepared = false;
  }
  bool finishPreparedWriter() override {
    if (!receipt->joined()) return false;
    receipt->reclaim();
    auto error = failure ? failure : receipt->failure();
    failure = {}; receipt = nullptr;
    if (error) { taken = false; std::rethrow_exception(error); }
    return true;
  }
  void cancelPreparedWriter() override { prepared = false; taken = false; }
  void setCompletionNotifier(std::function<void()> f) override { notifier = std::move(f); }
  void completionRecipients(std::vector<model::WeightMemory *> &out) override { out.push_back(this); }
  void swapCompletionNotifier(std::function<void()> &f) noexcept override { notifier.swap(f); }
  uint32_t notifierBindings() const noexcept override { return notifier ? 1 : 0; }
};

void run(int failureMode) {
  constexpr uint64_t ample = 1ULL << 40;
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, ample, 1, 0, [] { return std::optional<HostMemory>({ample, ample}); }, 0);
  auto lease = ResourceDomainLease::acquireForOwner(); lease.attach(governor);
  Images images(lease);
  ExtraReceiver extra;
  ReleasableMemory parts({&images, &extra}, std::nullopt);
  test::TestKvStorage storage(64, 4096, 4);
  KvPool pool(storage, 0); Cache cache(pool, nullptr, nullptr); WriteBehind persistence(cache);
  test::Executor model; Events events;
  EngineConfig config = test::engineConfig(); config.governor = &governor; config.writerLease = &lease;
  config.weights = WeightResidencyConfig{.weights = &parts, .admit = governor.allocationAdmission()};
  Gate body, notify;
  // Open every gate even if an assertion fails; drain/reclaim before Engine
  // teardown so test cleanup never relies on W1's emergency destructor join.
  Engine engine(config, cache, persistence, model, events);
  double now = 0;
  auto drain = [&] {
    body.release(); notify.release();
    const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while ((engine.commandInFlight() || !engine.callbacksRetired()) && std::chrono::steady_clock::now() < until) {
      now += 0.001;
      try { (void)engine.tick(now); } catch (...) {}
      std::this_thread::yield();
    }
    require(!engine.commandInFlight() && engine.callbacksRetired(), "retirement did not complete");
  };
  try {
    std::atomic<unsigned> oldCalls{0}, newCalls{0};
    engine.setCompletionNotifier([&] {
      ++oldCalls;
      require(refuses([&] { (void)governor.allocationAdmission()(1, [] {}); }), "Writer Scope leaked into notifier");
      notify.block();
      if (failureMode == 3) throw std::runtime_error("notifier failure");
    });
    // Construct a callable successfully, then make its preparation copy fail.
    std::function<void()> bad = [] {};
    // std::function's move construction does not copy the target.
    struct MoveOnlyPreparation {
      MoveOnlyPreparation() = default;
      MoveOnlyPreparation(MoveOnlyPreparation &&) noexcept = default;
      MoveOnlyPreparation(const MoveOnlyPreparation &) { throw std::runtime_error("copy failed"); }
      void operator()() const {}
    };
    bad = MoveOnlyPreparation{};
    require(refuses([&] { (void)engine.prepareCompletionBinding(bad); }), "preparation failure not exercised");
    require(engine.callbacksRetired(), "failed preparation changed bindings");
    {
      auto prepared = engine.prepareCompletionBinding([&] { ++newCalls; });
      auto previous = engine.installCompletionBinding(std::move(prepared));
      auto displaced = engine.installCompletionBinding(std::move(previous));
    }
    require(engine.callbacksRetired(), "rollback leaked a notifier seat");
    images.body = &body; images.failLaunch = failureMode == 1; images.failWrite = failureMode == 2;
    require(engine.releaseWeights(0), "release failed");
    engine.submit(request(1, {1, 2}));
    if (failureMode == 1) {
      require(refuses([&] { (void)engine.tick(0); }), "launch unexpectedly succeeded");
      lease.check("Owner after failed launch");
      require(!images.writerIntervalActive(), "prepared launch not cancelled");
      images.failLaunch = false;
    }
    (void)engine.tick(0); body.wait();
    require(refuses([&] { lease.check("former Owner"); }), "Owner kept authority");
    require(refuses([&] { (void)governor.ledger(); }), "Owner mutated ledger");
    require(engine.commandInFlight() && !engine.callbacksRetired(), "active Writer retired early");
    auto expiring = request(3, {1, 2}); expiring.deadlineMilliseconds = 0.5;
    engine.submit(std::move(expiring));
    engine.provideMask(1, {});
    engine.cancel(1); (void)engine.tick(1);
    require(events.completedCount == 0 && events.failedCount == 0, "cancel settled during write");
    require(!engine.releaseWeights(1) && !engine.flushRestorePoints(), "released active resources");
    body.release(); notify.wait();
    require(images.ended && engine.commandInFlight() && !engine.callbacksRetired(), "ended counted as retired");
    (void)engine.tick(1); require(events.completedCount == 0, "notifier interval settled");
    drain(); lease.check("Owner reclaimed");
    require(events.completedCount + events.failedCount == 2, "deferred terminal intent not settled exactly once");
    require(newCalls == 0, "rollback lost previous weight notifier");
    if (!failureMode || failureMode == 1) {
      require(events.reasons.at(1) == EngineFinishReason::Cancelled, "deferred cancellation lost");
      require(engine.releaseWeights(++now), "second release failed");
      engine.submit(request(2, {1, 2})); (void)engine.tick(++now); engine.cancel(2); drain();
      require(images.writes == 2, "second Writer generation missing");
      require(events.completedCount + events.failedCount == 3, "duplicate or missing request completion");
    }
  } catch (...) { drain(); throw; }
}

void noLease() {
  constexpr uint64_t ample = 1ULL << 40;
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, ample, 1, 0, [] { return std::optional<HostMemory>({ample, ample}); }, 0);
  test::Weights weights;
  test::TestKvStorage storage(64, 4096, 4);
  KvPool pool(storage, 0); Cache cache(pool, nullptr, nullptr); WriteBehind persistence(cache);
  test::Executor model; Events events;
  auto config = test::engineConfig(); config.governor = &governor;
  config.weights = WeightResidencyConfig{.weights = &weights, .admit = governor.allocationAdmission()};
  Engine engine(config, cache, persistence, model, events);
  require(engine.releaseWeights(0), "standalone release failed");
  engine.submit(request(1, {1, 2})); (void)engine.tick(0); engine.cancel(1);
  for (unsigned i = 1; i <= test::Weights::kImages + 1; ++i) (void)engine.tick(i);
  require(engine.weightsHeld() && !engine.commandInFlight() && weights.restores == test::Weights::kImages &&
          events.reasons.at(1) == EngineFinishReason::Cancelled, "standalone restoration changed");
}

#ifndef SPLASH_ENGINE_WRITER_NO_MAIN
int main() {
  for (int mode = 0; mode != 4; ++mode) run(mode);
  noLease();
  std::cout << "engine writer: PASS\n";
}
#endif
