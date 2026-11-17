// The Battery-native lifecycle assertions: closed admission, handoff witnesses,
// recovery publication and the engineless shell, against the Engine-owned residency
// suspension keeps. Upstream wire framing, requests and telemetry stay in
// native_loop_wire_test.cpp, which also keeps AllocationFailure.hpp: its global
// operator new may be defined in only one translation unit of the binary.

#include "LoopFixture.hpp"
#include "TestCache.hpp"
#include "TestWriteBudget.hpp"
#include "ProtocolPeer.hpp"
#include "TestChecks.hpp"
#include "TestEngine.hpp"
#include "TestExecutor.hpp"
#include "TestKvPool.hpp"
#include "TestRegistry.hpp"
#include "TestStatus.hpp"
#include "engine/Cache.hpp"
#include "engine/NativeRuntime.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <future>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <unistd.h>

using namespace splash;
using namespace splash::engine;

namespace {

using splash::test::Executor;
using splash::test::idle;
using splash::test::LoopFixture;
using splash::test::rejects;
using splash::test::request;
using splash::test::require;
using splash::test::runUntilIdle;
using splash::test::Weights;

// Reentrant clock probes and concurrency gates fail within a fixed process bound.
struct AdmissionDeadline final {
  AdmissionDeadline() { alarm(10); }
  ~AdmissionDeadline() { alarm(0); }
};

struct AdmissionAnswer final {
  // `inference_unavailable` errors for that id.
  uint32_t refused = 0;
  // Every other error for it.
  uint32_t otherErrors = 0;
  uint32_t starts = 0;
  uint32_t terminals = 0;
};

AdmissionAnswer answeredFor(const std::vector<protocol::EngineEvent> &events,
                            uint64_t requestId) {
  AdmissionAnswer answered;
  for (const auto &message : events) {
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
      if (error->requestId != requestId)
        continue;
      if (error->code == "inference_unavailable")
        ++answered.refused;
      else
        ++answered.otherErrors;
    } else if (const auto *start = std::get_if<protocol::StartEvent>(&message))
      answered.starts += start->requestId == requestId;
    else if (const auto *done = std::get_if<protocol::DoneEvent>(&message))
      answered.terminals += done->requestId == requestId;
  }
  return answered;
}

// Admission is the native boundary: a stale readiness observation cannot
// submit work, and an already admitted command remains owned after closure.
void testClosedAdmissionRetainsRequestsAndRequiresExplicitReopen() {
  std::vector<bool> holding;
  engine::NativeLoopConfig config;
  config.holdingRequests = [&](bool value) { holding.push_back(value); };
  LoopFixture fixture(config);
  auto &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  require(loop.admissionOpen(), "initial admission was closed");
  require(loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{11})) &&
              test::answeredStatus(fixture, 11), "initial readiness read failed");
  const bool observedReady = loop.admissionOpen();
  loop.closeAdmission();
  require(observedReady && loop.receive(protocol::peer::serialize(request(91))), "closed gate broke framing");
  uint32_t refused = 0, starts = 0, terminals = 0;
  for (const auto &event : fixture.events()) {
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&event); error && error->requestId == 91) {
      require(error->code == "inference_unavailable" &&
                  error->failureClass == protocol::FailureClass::RequestError,
              "closed admission did not return a request refusal");
      ++refused;
    }
    if (const auto *start = std::get_if<protocol::StartEvent>(&event); start && start->requestId == 91)
      ++starts;
    if (const auto *done = std::get_if<protocol::DoneEvent>(&event); done && done->requestId == 91)
      ++terminals;
  }
  const auto metrics = loop.metricsSnapshot();
  require(refused == 1 && !starts && !terminals && !loop.snapshot().submitted &&
              !metrics.prefillInputTokens && !metrics.ttftSamples && holding.empty() &&
              loop.engineHealthy() && !loop.connectionMustClose(),
          "closed admission submitted work or changed serving telemetry");
  require(loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{12})) &&
              test::answeredStatus(fixture, 12) && !loop.admissionOpen(),
          "status reopened admission");
  loop.openAdmission();
  const auto commandReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(92))) && loop.tick() && loop.commandInFlight(),
          "reopened admission did not start a request");
  loop.closeAdmission();
  require(loop.receive(protocol::peer::serialize(protocol::CancelFrame{92})) && loop.commandInFlight(),
          "closure lost an admitted request or refused cancellation");
  *commandReady = true;
  runUntilIdle(loop);
  require(loop.snapshot().submitted == 1 && loop.snapshot().cancelled == 1 && !loop.admissionOpen(),
          "the admitted request did not retire while admission remained closed");
  loop.openAdmission();
  require(loop.receive(protocol::peer::serialize(request(93))), "explicit reopen failed");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 1 && answeredFor(fixture.events(), 93).starts == 1 &&
              answeredFor(fixture.events(), 93).terminals == 1 &&
              holding == std::vector<bool>({true, false, true, false}),
          "reopened serving lost its completion or keep-awake lifecycle");
}

void testHandoffRequiresClosedAdmissionAndEveryWitness() {
  LoopFixture fixture;
  auto &loop = fixture.loop;
  auto lease = ResourceDomainLease::acquireForOwner();
  loop.announceReady(protocol::peer::kTestReady);
  require(!lease.obtainQuiescence(), "unwitnessed domain minted a proof");
  require(loop.prepareResourceHandoff(lease).has_value() && !loop.admissionOpen(),
          "a quiet graph did not close admission and mint a proof");
  loop.openAdmission();
  require(!lease.obtainQuiescence(), "an open admission gate minted a proof");
  loop.closeAdmission();
  lease.setRetainedIoWitness({});
  require(!lease.obtainQuiescence() && lease.holder() == ResourceDomainAuthority::Holder::Owner,
          "an absent witness minted a proof or moved authority");
}

void testHandoffWaitsForQueuedAndParkedRequests() {
  LoopFixture fixture;
  auto &loop = fixture.loop;
  auto lease = ResourceDomainLease::acquireForOwner();
  loop.announceReady(protocol::peer::kTestReady);
  require(loop.receive(protocol::peer::serialize(request(7))), "queued request was refused");
  require(!loop.prepareResourceHandoff(lease) && !loop.admissionOpen() &&
              lease.holder() == ResourceDomainAuthority::Holder::Owner,
          "a queued request permitted transfer or reopened admission");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 1, "the refused handoff lost the queued request");
  loop.openAdmission();
  const auto commandReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(8))), "parked request was refused");
  for (uint32_t step = 0; step < 8 && !loop.commandInFlight(); ++step)
    static_cast<void>(loop.tick());
  require(loop.commandInFlight() && !loop.prepareResourceHandoff(lease),
          "an outstanding command permitted a handoff");
  *commandReady = true;
  runUntilIdle(loop);
  require(loop.prepareResourceHandoff(lease).has_value(), "the retired graph still refused handoff");
}

void testHandoffProofExpiresAfterDomainMutation() {
  LoopFixture fixture;
  auto &loop = fixture.loop;
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, 40ULL << 30, 2ULL << 30, 2ULL << 30,
                          [] { return test::hostMemory(16ULL << 30); }, 0);
  auto lease = ResourceDomainLease::acquireForOwner();
  lease.attach(backend);
  lease.attach(governor);
  loop.announceReady(protocol::peer::kTestReady);
  auto proof = loop.prepareResourceHandoff(lease);
  require(proof.has_value(), "a quiet graph minted no proof");
  governor.setPressure(MemoryPressure::Critical);
  rejects([&] { static_cast<void>(lease.transferToWorker(std::move(*proof))); },
          "fresh quiescence proof", "a stale proof transferred the domain");
  require(lease.holder() == ResourceDomainAuthority::Holder::Owner && !loop.admissionOpen(),
          "a stale proof moved authority or reopened admission");
  governor.setPressure(MemoryPressure::Normal);
  auto fresh = loop.prepareResourceHandoff(lease);
  require(fresh.has_value(), "the next safe point minted no fresh proof");
  auto worker = lease.transferToWorker(std::move(*fresh));
  rejects([&] { static_cast<void>(lease.transferToWorker(std::move(*fresh))); },
          "unspent quiescence proof", "a proof transferred twice");
  AdmissionDeadline deadline;
  require(worker.holder() == ResourceDomainAuthority::Holder::Worker, "handoff lost Worker authority");
  auto returned = std::async(std::launch::async, [worker = std::move(worker)]() mutable {
    worker.claim();
    return std::move(worker).park();
  });
  require(returned.wait_for(std::chrono::seconds(5)) == std::future_status::ready,
          "Worker did not park within the handoff bound");
  auto parked = returned.get();
  require(parked.holder() == ResourceDomainAuthority::Holder::Parked, "Worker did not park its token");
  lease.returnToOwner(std::move(parked));
  require(!loop.admissionOpen() && loop.prepareResourceHandoff(lease).has_value(),
          "returning authority reopened admission or prevented a new proof");
}

void testCloseAndSubmitHaveOneWinner() {
  AdmissionDeadline deadline;
  {
    LoopFixture fixture;
    auto &loop = fixture.loop;
    loop.announceReady(protocol::peer::kTestReady);
    const auto frame = protocol::peer::serialize(request(1));
    std::promise<void> release;
    auto go = release.get_future().share();
    std::atomic<bool> framingKept{false};
    std::thread submit([&] {
      go.wait();
      framingKept.store(loop.receive(frame), std::memory_order_release);
    });
    std::thread close([&] {
      go.wait();
      loop.closeAdmission();
    });
    release.set_value();
    submit.join();
    close.join();
    uint32_t refused = 0;
    for (const auto &event : fixture.events())
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&event); error && error->requestId == 1) {
        require(error->code == "inference_unavailable",
                "the losing submission received the wrong refusal");
        ++refused;
      }
    const auto answer = answeredFor(fixture.events(), 1);
    require(!answer.otherErrors, "race produced a different request error");
    const auto before = loop.snapshot();
    const bool submitted = before.submitted == 1;
    require(framingKept.load() && submitted != (refused == 1) &&
                !before.completed && !before.cancelled && !before.failed &&
                loop.engineHealthy() && !loop.connectionMustClose(),
            "the close/submit race had two winners or none");
    if (submitted) {
      runUntilIdle(loop);
      const auto after = loop.snapshot();
      require(after.completed + after.cancelled + after.failed == 1 &&
                  answeredFor(fixture.events(), 1).starts == 1 &&
                  answeredFor(fixture.events(), 1).terminals == 1,
              "the admitted request did not reach one terminal state");
    } else {
      require(idle(loop) && !answer.starts && !answer.terminals, "the refused request left work behind");
    }
    require(!loop.admissionOpen() && loop.receive(protocol::peer::serialize(request(2))) &&
                loop.snapshot().submitted == before.submitted &&
                answeredFor(fixture.events(), 2).refused == 1,
            "the race left admission open to a later request");
  }
}


// Battery NativeRuntime assertion parity, using the current Engine-owned residency.
struct GateProbe final {
  engine::NativeRuntime *loop = nullptr;
  double now = 100.0;
  uint64_t gateQueries = 0;
};

struct PersistentLoopFixture final {
  test::WriteBudget budget;
  test::TestKvStorage storage{72, 4096, 4};
  KvPool pool{storage, 0};
  test::TestKvTier tier{true};
  engine::Cache cache{pool, &tier, budget.budget};
  test::RetainedPersistence persistence{cache};
  Executor executor;
  std::shared_ptr<test::OffloadControl> offload = std::make_shared<test::OffloadControl>();
  std::vector<uint8_t> output;
  double &monotonic = budget.now;
  Weights weights;
  engine::NativeRuntime loop{
      {.engine = test::engineConfig({.weights = WeightResidencyConfig{.weights = &weights, .admit = test::admitAll}}),
       .unixMicros = [] { return uint64_t{1'000'000}; },
       .monotonicMilliseconds = [this] { return monotonic; }},
      metal::kResidencyKeepAliveSeconds, cache, persistence, executor,
      [this](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return test::readyStatusJson(); }, protocol::ProtocolLimits{}};

  PersistentLoopFixture() {
    monotonic = 100.0;
    storage.commandInFlight = [this] { return loop.commandInFlight(); };
    tier.transferLimit = 64;
    tier.capacity = 128;
    executor.prefillAnchor = true;
    executor.keptTier = offload;
    executor.keptBudget = budget.budget;
  }
};

void queueOneReplayPoint(PersistentLoopFixture &fixture) {
  fixture.loop.announceReady(protocol::peer::kTestReady);
  auto frame = request(1);
  frame.promptTokens.assign(2060, 7);
  require(fixture.loop.receive(protocol::peer::serialize(frame)),
          "the persistence request closed the connection");
  for (uint32_t step = 0; step < 16 && !fixture.loop.snapshot().writeBehind.waiting; ++step)
    static_cast<void>(fixture.loop.tick());
  require(fixture.loop.snapshot().writeBehind.waiting == 1,
          "the replay point did not wait in the retained queue");
  runUntilIdle(fixture.loop);
}

struct NullSink final : engine::EngineEventSink {
  void batchCompleted(WorkKind, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                      double, double) override {}
  void started(uint64_t, uint32_t, uint32_t) override {}
  void tokens(uint64_t, std::span<const uint32_t>) override {}
  void maskRequested(uint64_t, std::span<const uint32_t>) override {}
  void completed(uint64_t, EngineFinishReason, bool, uint32_t, uint32_t, uint32_t,
                 std::span<const float>, const SpeculativeCounts &) override {}
  void failed(uint64_t, LaneOutcome, std::string, uint32_t) override {}
};

struct ShellFixture {
  explicit ShellFixture(test::PoolShape shape = {}, protocol::ProtocolLimits limits = {})
      : storage(shape.pages, 4096, shape.extentPages),
        pool(storage, shape.runwayPages), cache(pool, nullptr, nullptr),
        persistence(cache),
        loop(NativeLoopConfig{.engine = test::engineConfig({.weights = WeightResidencyConfig{.weights = &weights, .admit = test::admitAll}}),
                              .unixMicros = [] { return uint64_t{1'000'000}; },
                              .monotonicMilliseconds = [this] { return monotonic; }},
             metal::kResidencyKeepAliveSeconds,
             [this](std::span<const uint8_t> bytes) {
               output.insert(output.end(), bytes.begin(), bytes.end());
             },
             [this] { return status(); }, limits) {
    storage.commandInFlight = [this] { return loop.commandInFlight(); };
  }

  test::TestKvStorage storage;
  KvPool pool;
  engine::Cache cache;
  test::RetainedPersistence persistence;
  Executor executor;
  std::vector<uint8_t> output;
  std::function<std::string()> status = test::readyStatusJson;
  double monotonic = 100.0;
  Weights weights;
  engine::NativeRuntime loop;

  // Every event the loop has written.
  std::vector<protocol::EngineEvent> events() const {
    return protocol::peer::decodeEvents(output);
  }
};

struct ThrowingNotifierCopy {
  std::shared_ptr<bool> fail;
  int *calls;
  ThrowingNotifierCopy(std::shared_ptr<bool> flag, int *count) : fail(std::move(flag)), calls(count) {}
  ThrowingNotifierCopy(const ThrowingNotifierCopy &other) : fail(other.fail), calls(other.calls) {
    if (*fail) throw std::runtime_error("injected notifier copy failure");
  }
  void operator()() const { ++*calls; }
};
void testCloseBeforeSubmitStartsNothing() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  require(loop.receive(protocol::peer::serialize(request(1))), "the warm request failed");
  runUntilIdle(loop);
  require(releaseAnswer(fixture, 11).released, "the release did not give the weights back");

  const auto counts = loop.snapshot();
  const auto weightsBefore = loop.weightsSnapshot();
  const auto metricsBefore = loop.metricsSnapshot();
  loop.closeAdmission();
  require(loop.receive(protocol::peer::serialize(request(2))),
          "refusing a request closed the protocol connection");
  require(!loop.tick(), "the closed gate put work in the Engine anyway");

  const auto after = loop.snapshot();
  require(after.submitted == counts.submitted && after.completed == counts.completed &&
              after.cancelled == counts.cancelled && after.failed == counts.failed &&
              after.activeRequests.empty(),
          "the closed gate admitted inference work");
  const auto weights = loop.weightsSnapshot();
  require(weights.released && !weights.restoring &&
              weights.restores == weightsBefore.restores &&
              weights.restoreFailures == weightsBefore.restoreFailures,
          "the refusal wrote the weights back, or counted a restore for them");
  const auto metrics = loop.metricsSnapshot();
  require(metrics.prefillInputTokens == metricsBefore.prefillInputTokens &&
              metrics.decodeOutputTokens == metricsBefore.decodeOutputTokens &&
              metrics.ttftSamples == metricsBefore.ttftSamples &&
              metrics.itlSamples == metricsBefore.itlSamples &&
              metrics.capacityFailures == metricsBefore.capacityFailures,
          "the refusal left serving telemetry behind");
  const auto answered = answeredFor(fixture.events(), 2);
  require(answered.refused == 1 && answered.otherErrors == 0 && answered.starts == 0 &&
              answered.terminals == 0 && loop.engineHealthy() &&
              !loop.connectionMustClose() && !loop.commandInFlight(),
          "the refusal was not the request's own single frame");
}

void testSubmitBeforeCloseKeepsTheAdmittedRequest() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  const auto commandReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(801))) && loop.tick(),
          "the admitted request did not submit its command");
  const auto admitted = loop.snapshot();
  require(admitted.submitted == 1 && admitted.activeRequests.size() == 1 &&
              admitted.activeRequests.front().id == 801 && loop.commandInFlight(),
          "the request was not admitted and running when closure began");

  loop.closeAdmission();
  const auto held = loop.snapshot();
  require(held.submitted == 1 && held.completed == 0 && held.cancelled == 0 &&
              held.failed == 0 && held.activeRequests.size() == 1 &&
              held.activeRequests.front().id == 801 && loop.commandInFlight() &&
              answeredFor(fixture.events(), 801).starts == 1 &&
              answeredFor(fixture.events(), 801).terminals == 0,
          "closure took ownership of the already-admitted request");

  require(loop.receive(protocol::peer::serialize(request(802))),
          "a later frame closed the connection");
  const auto refused = answeredFor(fixture.events(), 802);
  require(loop.snapshot().submitted == 1 && refused.refused == 1 &&
              refused.starts == 0 && refused.terminals == 0 &&
              loop.engineHealthy() && !loop.connectionMustClose() &&
              loop.snapshot().activeRequests.size() == 1 &&
              loop.snapshot().activeRequests.front().id == 801,
          "the later frame reached the model or disturbed request 801");

  *commandReady = true;
  runUntilIdle(loop);
  const auto terminal = answeredFor(fixture.events(), 801);
  require(terminal.starts == 1 && terminal.terminals == 1 &&
              loop.snapshot().completed == 1 && loop.snapshot().failed == 0,
          "closure took the admitted request's one terminal frame away");

  loop.openAdmission();
  require(loop.receive(protocol::peer::serialize(request(803))),
          "the explicit reopen did not serve");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 2, "reopened admission did not resume serving");
}

void testControlAndCancellationSurviveClosedAdmission() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  const auto commandReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(801))) && loop.tick(),
          "the admitted request did not start");
  loop.closeAdmission();

  require(loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{12})) &&
              test::answeredStatus(fixture, 12),
          "a status frame was refused with admission closed");
  require(loop.runControl([] { return true; }),
          "the control pass was refused with admission closed");
  // A mask reply for a request the loop never asked a mask for is ignored
  // rather than answered as a protocol failure, closed or open.
  require(loop.receive(protocol::peer::serialize(
              protocol::MaskResponseFrame{999, 1, {1, 0, 0, 0}})) &&
              loop.engineHealthy() && !loop.connectionMustClose(),
          "a stray mask reply disturbed the closed loop");
  require(loop.receive(protocol::peer::serialize(protocol::CancelFrame{801})) &&
              loop.engineHealthy() && !loop.connectionMustClose() &&
              loop.commandInFlight() && loop.snapshot().activeRequests.size() == 1,
          "the admitted request could not be cancelled with admission closed");
  // A request frame is still refused while that cancellation retires.
  require(loop.receive(protocol::peer::serialize(request(802))) &&
              loop.snapshot().submitted == 1 &&
              answeredFor(fixture.events(), 802).refused == 1,
          "a request frame got in while admission was closed");
  *commandReady = true;
  runUntilIdle(loop);
  const auto cancelled = [&] {
    uint32_t terminals = 0;
    for (const auto &message : fixture.events())
      if (const auto *done = std::get_if<protocol::DoneEvent>(&message);
          done && done->requestId == 801)
        terminals += done->reason == EngineFinishReason::Cancelled;
    return terminals;
  }();
  require(cancelled == 1 && loop.snapshot().cancelled == 1 &&
              answeredFor(fixture.events(), 802).refused == 1 &&
              !loop.admissionOpen(),
          "the closed loop lost the cancelled request's one terminal frame");
}

void testReopenIsExplicit() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  require(loop.receive(protocol::peer::serialize(request(1))) && loop.tick(),
          "the first request did not start");
  runUntilIdle(loop);
  require(releaseAnswer(fixture, 11).released, "the weights were not released");
  const auto commandReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(2))),
          "the second request was not admitted before closure");
  const auto weightsBefore = loop.weightsSnapshot();
  loop.closeAdmission();

  // The restore the already-admitted request needs runs with admission closed.
  require(loop.tick() && loop.weightsSnapshot().restoring,
          "the admitted request did not begin its weights restore");
  *commandReady = true;
  for (uint32_t step = 0; step < 8 && loop.weightsSnapshot().restoring; ++step)
    require(loop.tick(), "the restore under closed admission stalled");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 2 &&
              loop.weightsSnapshot().restores == weightsBefore.restores + 1 &&
              !loop.weightsSnapshot().released,
          "the request admitted before closure did not run once the weights came back");

  // Nothing that reads, answers, restores or idles reopens the gate.
  require(loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{13})) &&
              test::answeredStatus(fixture, 13), "a status read failed");
  static_cast<void>(loop.snapshot());
  static_cast<void>(loop.statusSnapshot());
  static_cast<void>(loop.weightsSnapshot());
  static_cast<void>(loop.resourceWaitSnapshot());
  static_cast<void>(loop.millisecondsUntilNextWakeup());
  loop.releaseIdleWeights();
  require(!loop.admissionOpen(), "a read, an answered frame or a restore reopened admission");
  require(loop.receive(protocol::peer::serialize(request(3))) &&
              loop.snapshot().completed == 2 &&
              answeredFor(fixture.events(), 3).refused == 1,
          "an implicit path admitted a request after closure");

  loop.openAdmission();
  require(loop.receive(protocol::peer::serialize(request(4))),
          "the explicit reopen did not serve");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 3,
          "the explicit reopen did not resume normal serving");
}

void testClockCallbacksQueryAdmissionWithoutReenteringTheGate() {
  AdmissionDeadline deadline;
  GateProbe probe;
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.unixMicros = [&probe] {
    if (probe.loop) {
      ++probe.gateQueries;
      static_cast<void>(probe.loop->admissionOpen());
    }
    return uint64_t{1'000'000};
  };
  config.monotonicMilliseconds = [&probe] {
    if (probe.loop)
      static_cast<void>(probe.loop->admissionOpen());
    return probe.now;
  };
  LoopFixture fixture(config, {}, {}, metal::kResidencyKeepAliveSeconds, test::LoopOptions{.useConfigClocks = true});
  probe.loop = &fixture.loop;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  require(loop.receive(protocol::peer::serialize(request(91))),
          "the clock-querying frame closed the connection");
  runUntilIdle(loop);
  require(probe.gateQueries > 0, "the submission path never read admission from its clock");
  require(loop.snapshot().submitted == 1 &&
              answeredFor(fixture.events(), 91).starts == 1 &&
              answeredFor(fixture.events(), 91).terminals == 1,
          "a clock that queries admission disturbed the submission it served");
  // Closed: the same clock queries again under no lock and the frame is refused.
  loop.closeAdmission();
  require(loop.receive(protocol::peer::serialize(request(92))) &&
              answeredFor(fixture.events(), 92).refused == 1 &&
              loop.snapshot().submitted == 1,
          "the closed gate let the clock-querying frame through or disturbed it");
}

void testCloseInsideTheClockRefusesThatRequest() {
  AdmissionDeadline deadline;
  struct Closer final {
    engine::NativeRuntime *loop = nullptr;
    bool armed = false;
    bool closed = false;
  } probe;
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.unixMicros = [] { return uint64_t{1'000'000}; };
  config.monotonicMilliseconds = [&probe] {
    if (probe.loop && probe.armed && !probe.closed) {
      probe.closed = true;
      probe.loop->closeAdmission();
    }
    return 100.0;
  };
  LoopFixture fixture(config, {}, {}, metal::kResidencyKeepAliveSeconds, test::LoopOptions{.useConfigClocks = true});
  probe.loop = &fixture.loop;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  require(loop.admissionOpen(), "startup did not open admission");
  probe.armed = true;
  require(loop.receive(protocol::peer::serialize(request(91))),
          "the closing-clock frame closed the connection");
  const auto answered = answeredFor(fixture.events(), 91);
  require(probe.closed && !loop.admissionOpen(),
          "the clock closure did not land before the gate check");
  require(answered.refused == 1 && answered.starts == 0 && answered.terminals == 0 &&
              loop.snapshot().submitted == 0 && idle(loop),
          "a close landing inside the clock did not refuse that request's frame");
  require(loop.receive(protocol::peer::serialize(request(92))) &&
              answeredFor(fixture.events(), 92).refused == 1 &&
              loop.snapshot().submitted == 0,
          "the clock closure left admission open for later submissions");
}

void testCloseStartedInsideTheClockRacesTheSubmission() {
  AdmissionDeadline deadline;
  {
    struct Racer final {
      engine::NativeRuntime *loop = nullptr;
      bool armed = false;
      bool launched = false;
      std::thread closer;
      std::promise<void> started;
    } probe;
    engine::NativeLoopConfig config;
    config.engine.maxContext = 1024;
    config.unixMicros = [] { return uint64_t{1'000'000}; };
    config.monotonicMilliseconds = [&probe] {
      if (probe.loop && probe.armed && !probe.launched) {
        probe.launched = true;
        auto started = probe.started.get_future();
        probe.closer = std::thread([&probe] {
          probe.started.set_value();
          probe.loop->closeAdmission();
        });
        require(started.wait_for(std::chrono::seconds(5)) == std::future_status::ready,
                "clock-triggered closer did not start");
      }
      return 100.0;
    };
    LoopFixture fixture(config, {}, {}, metal::kResidencyKeepAliveSeconds, test::LoopOptions{.useConfigClocks = true});
    probe.loop = &fixture.loop;
    engine::NativeRuntime &loop = fixture.loop;
    loop.announceReady(protocol::peer::kTestReady);
    probe.armed = true;
    require(loop.receive(protocol::peer::serialize(request(1))),
            "the racing frame closed the connection");
    probe.closer.join();
    const auto counts = loop.snapshot();
    const auto answered = answeredFor(fixture.events(), 1);
    const bool submitted = counts.submitted == 1;
    const bool refused = answered.refused == 1;
    require(submitted != refused && answered.otherErrors == 0 &&
                loop.engineHealthy() && !loop.connectionMustClose(),
            "the clock-released close and the final submission had two winners, or none");
    if (submitted) {
      // The submission won: the request it admitted keeps ownership and runs
      // to its one normal terminal frame despite the close that landed.
      runUntilIdle(loop);
      require(answeredFor(fixture.events(), 1).starts == 1 &&
                  answeredFor(fixture.events(), 1).terminals == 1 &&
                  loop.snapshot().completed == 1,
              "the close cut the admitted request's ownership short");
    } else {
      require(idle(loop) && answered.starts == 0 && answered.terminals == 0,
              "the losing submission left work behind");
    }
    // Either way admission is closed at the join and stays closed.
    require(loop.receive(protocol::peer::serialize(request(2))) &&
                loop.snapshot().submitted == counts.submitted &&
                answeredFor(fixture.events(), 2).refused == 1,
            "the race left admission open");
  }
}

void testWakeupBoundAggregatesSources() {
  const auto bound = engine::NativeRuntime::nextWakeupBoundMilliseconds;
  // No source at all: no deadline, the transport waits on input, completions
  // or control instead.
  require(!bound(100.0, std::nullopt, std::nullopt, false),
          "an idle loop invented a poll bound");
  // One source: the exact remaining duration.
  require(bound(100.0, 250.0, std::nullopt, false) == 150.0,
          "the engine deadline was not the exact bound");
  require(bound(100.0, std::nullopt, 150.0, false) == 50.0,
          "the retained persistence deadline was not the exact bound without an engine source");
  require(bound(100.0, std::nullopt, std::nullopt, true) ==
              engine::kResourceRetryBackoffMilliseconds,
          "the deferred restore retry was not its own bounded wake");
  require(bound(100.0, 500.0, 600.0, true) == engine::kResourceRetryBackoffMilliseconds,
          "later Engine and persistence sources hid restore retry");
  // Several: the earliest present deadline wins.
  require(bound(100.0, 250.0, 150.0, false) == 50.0,
          "a later engine deadline hid the persistence deadline");
  require(bound(100.0, 120.0, 150.0, true) == 20.0,
          "engine scheduling hid an earlier source");
  // Already due: one immediate wake, never a negative timeout.
  require(bound(100.0, 50.0, std::nullopt, false) == 0.0,
          "a past engine deadline produced a negative bound");
  require(bound(100.0, std::nullopt, 50.0, false) == 0.0,
          "a past persistence deadline produced a negative bound");
}

void testEngineSchedulingStillDrivesTheBound() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  require(!loop.millisecondsUntilNextWakeup(),
          "a fully idle loop with no sources produced a poll bound");
  const auto commandReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(1))) && loop.tick(),
          "the held command was not submitted");
  require(loop.commandInFlight() &&
              loop.millisecondsUntilNextWakeup() == 1000.0,
          "the engine's bounded health wake changed its bound under aggregation");
  *commandReady = true;
  runUntilIdle(loop);
  require(!loop.millisecondsUntilNextWakeup(),
          "the drained engine kept a poll bound");
}

void testRetainedPersistenceDrivesThePollBound() {
  PersistentLoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  queueOneReplayPoint(fixture);
  // The point's due time is the publish moment (the constant test clock)
  // plus the queue's delay; nothing else has a deadline.
  const auto bound = loop.millisecondsUntilNextWakeup();
  require(bound && *bound == engine::WriteBehind::kDelayMilliseconds,
          "the retained persistence point was not the loop's poll bound");
  require(fixture.persistence.nextWakeup() ==
              fixture.monotonic + engine::WriteBehind::kDelayMilliseconds,
          "the retained queue lost its own absolute deadline");
  // Already due: the bound is an immediate wake, never negative.
  fixture.monotonic += engine::WriteBehind::kDelayMilliseconds + 250.0;
  require(loop.millisecondsUntilNextWakeup() == 0.0,
          "a due persistence point did not wake the transport at once");
  // Running it starts the state's write, which the test has not landed: the
  // step stalls on its completion, and a completion wakes the loop itself,
  // so the queue holds no further deadline (no busy polling, no re-timing).
  static_cast<void>(loop.tick());
  require(!loop.millisecondsUntilNextWakeup() &&
              fixture.loop.snapshot().writeBehind.waiting == 1 &&
              fixture.loop.snapshot().writeBehind.durable == 0,
          "the stalled step was dropped, re-timed or kept busy-polling");
  fixture.offload->ready = true;
  for (uint32_t step = 0; step < 16 &&
                      !fixture.loop.snapshot().writeBehind.durable; ++step) {
    static_cast<void>(loop.tick());
    fixture.tier.complete();
  }
  require(fixture.loop.snapshot().writeBehind.durable == 1 &&
              !fixture.persistence.nextWakeup() &&
              !loop.millisecondsUntilNextWakeup(),
          "the landed write did not drain the retained point and its source");
}

// The retained graph owns this deadline even after its Engine is detached.
void testDetachedRetainedPersistenceDrivesThePollBound() {
  PersistentLoopFixture fixture;
  auto &loop = fixture.loop;
  queueOneReplayPoint(fixture);
  require(!loop.serviceRetainedPersistence() && fixture.persistence.snapshot().waiting == 1,
          "NativeRuntime competed with the attached Engine for persistence");
  auto detached = loop.destroyEngine();
  require(detached && !loop.hasEngine() && !loop.publishedContextTokens(), "queued point prevented safe detach");
  detached.reset();
  require(loop.millisecondsUntilNextWakeup() == WriteBehind::kDelayMilliseconds,
          "detaching lost the retained queue's deadline");
  fixture.monotonic += WriteBehind::kDelayMilliseconds - 1.0;
  require(!loop.tick() && loop.millisecondsUntilNextWakeup() == 1.0 && fixture.cache.retainedIoIdle(),
          "detached persistence ran before its absolute deadline");
  fixture.monotonic += 1.0;
  require(loop.millisecondsUntilNextWakeup() == 0.0, "detached due point did not wake immediately");
  static_cast<void>(loop.tick());
  require(!fixture.cache.retainedIoIdle() && !loop.millisecondsUntilNextWakeup() &&
              fixture.persistence.snapshot().waiting == 1 && !fixture.persistence.snapshot().durable,
          "detached persistence busy-polled or prematurely settled its write");
  fixture.offload->ready = true;
  for (unsigned step = 0; step < 16 && !fixture.persistence.snapshot().durable; ++step) {
    fixture.tier.complete();
    static_cast<void>(loop.tick());
  }
  require(fixture.persistence.snapshot().durable == 1 && !fixture.persistence.snapshot().waiting &&
              fixture.cache.retainedIoIdle() && !loop.millisecondsUntilNextWakeup(),
          "detached retained service did not settle exactly once");
}

void testStalledWriteBudgetAdmissionIsTheBound() {
  PersistentLoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  queueOneReplayPoint(fixture);
  // Overdraw the budget, then run the due point into it.
  fixture.budget.spend();
  fixture.monotonic += engine::WriteBehind::kDelayMilliseconds;
  static_cast<void>(loop.tick());
  require(loop.snapshot().writeBehind.waiting == 1 &&
              loop.snapshot().writeBehind.durable == 0,
          "the budget-held point was dropped or written");
  const auto admission = fixture.persistence.nextWakeup();
  const auto bound = loop.millisecondsUntilNextWakeup();
  require(admission && bound && std::abs(*admission - (100.0 + test::WriteBudget::kRefillMilliseconds)) < 1.0,
          "the stalled queue did not report the next budget admission");
  require(*bound == *admission - fixture.monotonic && *bound > 0.0,
          "the loop's bound is not the stalled queue's next budget admission");
  // Once the budget admits again, only the in-flight write waits: its
  // completion wakes the loop, so the poll is unbounded rather than busy.
  const double due = *admission;
  fixture.monotonic = due - 1.0;
  static_cast<void>(loop.tick());
  const auto beforeDue = loop.millisecondsUntilNextWakeup();
  require(beforeDue && std::abs(*beforeDue - 1.0) < 0.001 &&
              fixture.cache.retainedIo().stateWrites == 0 && !fixture.persistence.snapshot().durable,
          "budget-bound persistence started before its admission (bound=" +
              (beforeDue ? std::to_string(*beforeDue) : "none") +
              ", stateWrites=" + std::to_string(fixture.cache.retainedIo().stateWrites) + ")");
  // Advance to the first representable instant after the absolute deadline;
  // the refill's division and multiplication need not round identically.
  fixture.monotonic = std::nextafter(due, std::numeric_limits<double>::infinity());
  require(fixture.budget.budget->admits(false), "budget did not admit at its elapsed deadline");
  // The previously armed admission deadline has elapsed. Once admission is
  // available the budget no longer contributes a retry deadline (as in the
  // historical refill case); this wake's tick starts the retained write.
  require(!loop.millisecondsUntilNextWakeup(), "admitted budget kept a stale retry source");
  static_cast<void>(loop.tick());
  require(!fixture.cache.retainedIoIdle(), "due budget failed to start persistence");
  require(!loop.millisecondsUntilNextWakeup(),
          "the runtime kept polling while only a landing write waits");
  fixture.offload->ready = true;
  for (uint32_t step = 0; step < 16 && !fixture.loop.snapshot().writeBehind.durable; ++step) {
    static_cast<void>(loop.tick());
    fixture.tier.complete();
  }
  require(fixture.loop.snapshot().writeBehind.durable == 1 &&
              !fixture.loop.snapshot().writeBehind.waiting,
          "the admitted write did not drain exactly once");
}

void testHandoffRefusesIOTheRetainedGraphStillRuns() {
  PersistentLoopFixture fixture;
  auto authority = ResourceDomainLease::acquireForOwner();
  engine::NativeRuntime &loop = fixture.loop;
  queueOneReplayPoint(fixture);
  fixture.monotonic += engine::WriteBehind::kDelayMilliseconds;
  static_cast<void>(loop.tick());
  const auto io = fixture.cache.retainedIo();
  require(idle(loop) && !loop.commandInFlight() && !fixture.cache.retainedIoIdle() &&
              io.stateWrites == 1 && io.owed == 0,
          "the loop was not idle with exactly the running state write outstanding");
  require(!loop.prepareResourceHandoff(authority).has_value(),
          "an idle engine minted a handoff over a running state write");
  fixture.offload->ready = true;
  for (uint32_t step = 0; step < 16 && !fixture.loop.snapshot().writeBehind.durable; ++step) {
    static_cast<void>(loop.tick());
    fixture.tier.complete();
  }
  require(fixture.cache.retainedIoIdle() && idle(loop),
          "the state write did not land and get polled");
  require(loop.prepareResourceHandoff(authority).has_value(),
          "the drained write still refused a handoff");
}

void testHandoffRefusesClosuresAndDescendantsPastTheGPU() {
  LoopFixture fixture;
  auto authority = ResourceDomainLease::acquireForOwner();
  engine::NativeRuntime &loop = fixture.loop;
  uint32_t notifierRuns = 0;
  loop.setCompletionNotifier([&] { ++notifierRuns; });
  loop.announceReady(protocol::peer::kTestReady);
  fixture.executor.owedServiceWork = 1;
  require(idle(loop) && !loop.commandInFlight() && fixture.cache.retainedIoIdle(),
          "the graph was otherwise at rest with one unreported Neural Engine job");
  require(!loop.prepareResourceHandoff(authority).has_value(),
          "an unreported Neural Engine job minted a handoff proof");
  fixture.executor.owedServiceWork = 0;
  require(loop.prepareResourceHandoff(authority).has_value(),
          "the reported job still refused a handoff");
  // The completion closure of a command its owner has retired: the fake keeps
  // it the way a real model's command state does, past the command's own
  // completion and past the request's end.
  auto hold = std::make_shared<std::atomic<bool>>(false);
  fixture.executor.holdPrefillUntil = hold;
  loop.openAdmission();
  require(loop.receive(protocol::peer::serialize(request(9))), "the request was refused");
  for (uint32_t step = 0; step < 8 && !loop.commandInFlight(); ++step)
    static_cast<void>(loop.tick());
  require(loop.commandInFlight() && static_cast<bool>(fixture.executor.heldCompletion),
          "the fixture did not park its command with its completion held");
  // The completion handler plays, as Metal's would.
  fixture.executor.heldCompletion();
  *hold = true;
  runUntilIdle(loop);
  require(idle(loop) && !loop.commandInFlight() && fixture.cache.retainedIoIdle() &&
              notifierRuns >= 1,
          "the graph did not drain down to the retained closure alone");
  require(!loop.prepareResourceHandoff(authority).has_value(),
          "a completion closure its holder still keeps minted a handoff proof");
  fixture.executor.heldCompletion = nullptr;
  require(loop.prepareResourceHandoff(authority).has_value(),
          "the closure outlived the command that borrowed it");
}

void testStagedAdoptionBindingsAndPreparationFailure() {
  auto lease = ResourceDomainLease::acquireForOwner();
  ShellFixture fixture({.pages = 512});
  auto &loop = fixture.loop;
  loop.closeAdmission();
  int calls = 0;
  auto fail = std::make_shared<bool>(false);
  std::function<void()> notifier = ThrowingNotifierCopy(fail, &calls);
  loop.setCompletionNotifier(std::move(notifier));
  auto candidate = loop.makePrivateEngine(test::engineConfig({.writerLease = &lease, .weights = WeightResidencyConfig{.weights = &fixture.weights, .admit = test::admitAll}}), fixture.cache,
                                          fixture.persistence, fixture.executor);
  auto *original = candidate.get();
  int oldCalls = 0;
  candidate->setCompletionNotifier([&oldCalls] { ++oldCalls; });
  auto oldSlots = fixture.cache.installCompletionSlots({}, {});
  require(oldSlots.first && oldSlots.second, "original cache bindings absent");
  auto savedOldCache = oldSlots.first;
  auto savedOldState = oldSlots.second;
  static_cast<void>(fixture.cache.installCompletionSlots(std::move(oldSlots.first), std::move(oldSlots.second)));
  const auto oldBindingCount = fixture.cache.notifierBindings();
  engine::NativeRuntime::NativeAdoptionInput input;
  input.engineSlot = &candidate;
  input.engineConfig = candidate->borrowedConfig();
  input.cache = &fixture.cache;
  input.writeBehind = &fixture.persistence;
  input.engineFailed = [] {};
  input.authorityHeld = [] { return true; };
  input.contextCeiling = candidate->maxContextTokens();
  std::unique_ptr<engine::NativeRuntime::StagedAdoption> staged;
  input.contextCeiling = 0;
  require(!loop.stageAdoption(input, staged) && candidate.get() == original && !loop.hasEngine(),
          "capacity refusal consumed the candidate");
  input.contextCeiling = candidate->maxContextTokens();
  *fail = true;
  require(!loop.stageAdoption(input, staged) && candidate.get() == original && !loop.hasEngine(),
          "throwing notifier preparation consumed the candidate");
  require(!staged && !loop.publishedContextTokens() && !loop.admissionOpen() &&
              candidate->borrowedCache() == &fixture.cache &&
              candidate->borrowedWriteBehind() == &fixture.persistence &&
              fixture.cache.notifierBindings() == oldBindingCount,
          "failed preparation changed the shell or candidate graph bindings");
  auto failedSlots = fixture.cache.installCompletionSlots({}, {});
  require(failedSlots.first && failedSlots.second, "failed preparation lost original recipients");
  failedSlots.first();
  failedSlots.second();
  require(oldCalls == 2 && calls == 0, "failed preparation changed notifier recipients");
  oldCalls = 0;
  static_cast<void>(fixture.cache.installCompletionSlots(std::move(failedSlots.first), std::move(failedSlots.second)));
  *fail = false;
  require(loop.stageAdoption(input, staged) && !candidate && loop.publishedEngine() == original,
          "adoption did not stage the candidate");
  auto stagedSlots = fixture.cache.installCompletionSlots({}, {});
  require(stagedSlots.first && stagedSlots.second, "staged cache bindings absent");
  savedOldCache();
  savedOldState();
  stagedSlots.first();
  stagedSlots.second();
  require(oldCalls == 2 && calls == 2, "staged or captured recipients changed");
  static_cast<void>(fixture.cache.installCompletionSlots(std::move(stagedSlots.first), std::move(stagedSlots.second)));
  candidate = loop.rollbackAdoption(std::move(staged));
  auto restored = fixture.cache.installCompletionSlots({}, {});
  require(restored.first && restored.second, "rollback did not restore cache bindings");
  restored.first();
  restored.second();
  require(oldCalls == 4 && calls == 2, "rollback restored the wrong recipients");
  static_cast<void>(fixture.cache.installCompletionSlots(std::move(restored.first), std::move(restored.second)));
  require(fixture.cache.notifierBindings() == oldBindingCount, "rollback changed binding count");
  savedOldCache = {};
  savedOldState = {};
  require(candidate.get() == original && !loop.hasEngine() && !loop.admissionOpen() &&
              candidate->callbacksRetired(), "rollback failed to restore the candidate bindings");
  require(loop.stageAdoption(input, staged), "restored candidate could not be staged again");
  loop.commitAdoption(std::move(staged));
  loop.openAdmission();
  require(loop.receive(protocol::peer::serialize(request(91))), "adopted request was refused");
  runUntilIdle(loop);
  require(calls > 0 && loop.snapshot().completed == 1,
          "adopted Engine did not notify or complete its request");
}

void testEnginelessShellRefusesThenPublishesAndServes() {
  ShellFixture fixture({.pages = 512});
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady(protocol::peer::kTestReady);
  require(!loop.hasEngine(), "the model-less shell started with an Engine");
  require(loop.receive(protocol::peer::serialize(request(11))),
          "the shell refused a request by closing the connection");
  const auto refused = answeredFor(fixture.events(), 11);
  require(refused.refused == 1 && refused.starts == 0 && refused.terminals == 0 &&
              !refused.otherErrors,
          "the Engine-absent shell did not answer one request-scoped frame");
  require(loop.metricsSnapshot().prefillInputTokens == 0,
          "the Engine-absent shell recorded engine telemetry");
  require(loop.tick() == false && loop.flushRestorePoints(),
          "the Engine-absent tick made progress, or its flush found a restore point");

  int notified = 0;
  loop.setCompletionNotifier([&notified] { ++notified; });
  loop.publishEngine(fixture.cache, fixture.persistence, fixture.executor);
  require(loop.hasEngine(), "publishEngine bound no Engine");
  require(loop.receive(protocol::peer::serialize(request(12))),
          "the published shell refused its first request");
  runUntilIdle(loop);
  require(loop.snapshot().submitted == 1 && loop.snapshot().completed == 1,
          "the published Engine did not serve the request");
  require(notified >= 1, "publishEngine lost the loop's stored completion notifier");

  bool threw = false;
  try {
    loop.publishEngine(fixture.cache, fixture.persistence, fixture.executor);
  } catch (const std::logic_error &) {
    threw = true;
  }
  require(threw && loop.hasEngine(),
          "publishEngine published over the published Engine");

  // The detach boundary: the requests this loop holds refuse, then the clean
  // loop moves the Engine out; the Engine's own life ends on another thread.
  require(loop.receive(protocol::peer::serialize(request(13))), "a queued request failed");
  require(!loop.destroyEngine(), "the detach ran with the request side owning work");
  require(loop.hasEngine() && !loop.admissionOpen(),
          "the refused detach dropped the Engine or left admission open");
  runUntilIdle(loop);
  auto detached = loop.destroyEngine();
  require(detached && !loop.hasEngine(), "the clean safe point moved no Engine out");
  require(!loop.admissionOpen(), "the detach left native admission open");

  std::thread::id destructionThread;
  std::thread destroyer(
      [engine = std::move(detached), &destructionThread]() mutable {
        destructionThread = std::this_thread::get_id();
        engine.reset();
      });
  destroyer.join();
  require(destructionThread != std::this_thread::get_id(),
          "the detached Engine's life did not end off the safe-point thread");

  // Engine-absent again: release answers the weights as absent, a cancel is
  // a no-op, and the control plane still answers.
  std::optional<WeightsSnapshot> reported;
  fixture.status = [&] {
    reported = fixture.loop.weightsSnapshot();
    return test::readyStatusJson();
  };
  require(fixture.loop.receive(
              protocol::peer::serialize(protocol::ReleaseRequestFrame{14})) &&
              reported,
          "the Engine-absent loop did not answer a release request with a status document");
  require(!reported->released, "the Engine-absent loop reported weights released");
  require(fixture.loop.receive(protocol::peer::serialize(protocol::CancelFrame{999})),
          "a cancel over an absent Engine closed the connection");
  require(!loop.connectionMustClose() && loop.engineHealthy(),
          "the Engine-absent control plane disturbed the loop");
  unsigned readyCount = 0;
  for (const auto &event : fixture.events())
    readyCount += std::holds_alternative<protocol::ReadyEvent>(event);
  require(readyCount == 1, "Engine publication re-announced process readiness");
}

void testTryPublishEngineKeepsRefusedCandidatesOwnable() {
  NullSink sink;
  // A fresh shell and a live candidate: the adoption is refused because the
  // shell already publishes an Engine — the adoption is staged on top of
  // one. The caller's unique_ptr keeps its Engine.
  ShellFixture publishedEngine({.pages = 512});
  publishedEngine.loop.publishEngine(publishedEngine.cache,
                                     publishedEngine.persistence,
                                     publishedEngine.executor);
  auto firstCandidate = std::unique_ptr<engine::Engine>(
      new engine::Engine(test::engineConfig(), publishedEngine.cache,
                         publishedEngine.persistence, publishedEngine.executor, sink));
  auto *candidateIdentity = firstCandidate.get();
  auto *publishedIdentity = publishedEngine.loop.publishedEngine();
  const auto originalBindings = publishedEngine.cache.notifierBindings();
  require(!publishedEngine.loop.tryPublishEngine(firstCandidate),
          "an already-published shell adopted a second Engine");
  require(firstCandidate.get() == candidateIdentity &&
              firstCandidate->borrowedCache() == &publishedEngine.cache &&
              firstCandidate->borrowedWriteBehind() == &publishedEngine.persistence &&
              publishedEngine.loop.publishedEngine() == publishedIdentity &&
              publishedEngine.cache.notifierBindings() == originalBindings,
          "the refused adoption consumed the caller's Engine or replaced the shell's");
  // The refusal left the caller's Engine intact for the CALLER: destroyed here,
  // in dependency order, its borrowed components still alive.
  firstCandidate.reset();
  // A second fresh shell: an empty adoption publishes nothing...
  ShellFixture emptyCandidateShell({.pages = 512});
  std::unique_ptr<engine::Engine> empty;
  require(!emptyCandidateShell.loop.tryPublishEngine(empty) &&
              !emptyCandidateShell.loop.hasEngine(),
          "an empty adoption published something");
  // ...and the accepted adoption consumes the caller's Engine exactly once.
  ShellFixture adoptedEngine({.pages = 512});
  auto liveCandidate = std::unique_ptr<engine::Engine>(
      new engine::Engine(test::engineConfig(), adoptedEngine.cache,
                         adoptedEngine.persistence, adoptedEngine.executor, sink));
  require(adoptedEngine.loop.tryPublishEngine(liveCandidate) &&
              adoptedEngine.loop.hasEngine() && !liveCandidate,
          "the accepted adoption did not consume the candidate");
  // Current simple publication binds the candidate's retained graph as well.
  auto detached = adoptedEngine.loop.destroyEngine();
  require(detached && !adoptedEngine.loop.hasEngine(),
          "simple publication did not bind the retained graph for safe detach");
}

void testDestroyEngineRefusesRetainedGraphIO() {
  PersistentLoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  queueOneReplayPoint(fixture);
  fixture.monotonic += engine::WriteBehind::kDelayMilliseconds;
  static_cast<void>(loop.tick());
  require(idle(loop) && !fixture.cache.retainedIoIdle(),
          "the fixture left no running retained state write");
  require(!loop.destroyEngine() && loop.hasEngine(),
          "the detach moved the Engine out over a running state write");
  fixture.offload->ready = true;
  for (uint32_t step = 0; step < 16 && !fixture.loop.snapshot().writeBehind.durable;
       ++step) {
    static_cast<void>(loop.tick());
    fixture.tier.complete();
  }
  require(fixture.cache.retainedIoIdle() && idle(loop),
          "the state write did not land and get polled");
  auto detached = loop.destroyEngine();
  require(detached && !loop.hasEngine(),
          "the drained graph still refused the safe-point detach");
  // The moved-out Engine's life ends off the loop entirely: this fixture's
  // retained components outlive it exactly as the lifecycle's worker interval
  // will hold the real one.
  detached.reset();
  require(loop.millisecondsUntilNextWakeup().has_value() == false,
          "the Engine-absent loop still woke for engine events");
}

void testPublishedEngineCapacityIsTheExactWindow() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config, {.pages = 512});
  engine::NativeRuntime &loop = fixture.loop;
  auto ready = protocol::peer::kTestReady;
  ready.maxContextTokens = 1024;
  loop.announceReady(ready);
  const auto window = loop.publishedContextTokens();
  require(window.has_value() && *window == 1024 &&
              *window == loop.snapshot().maximumContextTokens,
          "the published Engine's window is not what the loop reads for a request");

  // One token past THAT window is refused by the Engine, request-scoped: the
  // bound the capacity read advertises, enforced by the same config value.
  auto over = request(21);
  over.promptTokens.resize(*window + 1);
  for (uint32_t index = 0; index < over.promptTokens.size(); ++index)
    over.promptTokens[index] = index + 1;
  require(loop.receive(protocol::peer::serialize(over)),
          "an over-window request closed the connection instead of refusing it");
  runUntilIdle(loop);
  uint32_t refused = 0, started = 0, otherErrors = 0;
  for (const auto &message : fixture.events()) {
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
      if (error->requestId != 21)
        continue;
      error->code == "invalid_request" ? ++refused : ++otherErrors;
    } else if (const auto *start = std::get_if<protocol::StartEvent>(&message))
      started += start->requestId == 21;
  }
  require(refused == 1 && started == 0 && otherErrors == 0,
          "the Engine did not refuse exactly the window its capacity reported");

  // The safe-point detach: the shell holds no Engine, so it claims no capacity
  // at all rather than falling back to anything.
  auto detached = loop.destroyEngine();
  require(detached && !loop.hasEngine() && !loop.publishedContextTokens().has_value(),
          "the detached shell still claimed a context capacity");

  // The candidate's Engine: the loop's own event sink over this Cache, its
  // OWN resolved window, published nowhere. The shell stays Engine-absent and
  // reports no capacity while the candidate's number stands on its own.
  engine::EngineConfig candidateConfig = test::engineConfig();
  candidateConfig.maxContext = 640;
  auto privateEngine = loop.makePrivateEngine(candidateConfig, fixture.cache,
                                             fixture.persistence, fixture.executor);
  require(privateEngine && privateEngine->maxContextTokens() == 640 &&
              !loop.hasEngine() && !loop.publishedContextTokens().has_value(),
          "a private Engine was published, or lost the window it was built with");
  // Candidate order: the Engine dies before the components it borrows, which
  // outlive it in this fixture exactly as in the lifecycle's worker interval.
  require(loop.tryPublishEngine(privateEngine), "candidate publication failed");
  loop.openAdmission();
  require(loop.publishedContextTokens() == 640, "adopted window differs");
  auto valid = request(22);
  require(loop.receive(protocol::peer::serialize(valid)), "valid request failed");
  runUntilIdle(loop);
  auto tooLarge = request(23);
  tooLarge.promptTokens.resize(641, 1);
  require(loop.receive(protocol::peer::serialize(tooLarge)), "refusal closed connection");
  runUntilIdle(loop);
  unsigned readyCount = 0, startCount = 0, refusalCount = 0;
  for (const auto &event : fixture.events()) {
    if (const auto *ready = std::get_if<protocol::ReadyEvent>(&event)) {
      ++readyCount;
      require(ready->maxContextTokens == 1024, "static ceiling changed");
    } else if (const auto *start = std::get_if<protocol::StartEvent>(&event)) {
      if (start->requestId == 22) { ++startCount; require(start->capacityTokens == 640, "wrong adopted capacity"); }
    } else if (const auto *error = std::get_if<protocol::ErrorEvent>(&event)) {
      if (error->requestId == 23 && error->code == "invalid_request") ++refusalCount;
    }
  }
  require(readyCount == 1 && startCount == 1 && refusalCount == 1, "adopted capacity proof failed");
  detached.reset();
}
void testPendingRestoreLifecycle(bool closeAdmission) {
  LoopFixture fixture;
  auto &loop = fixture.loop;
  auto &executor = fixture.executor;
  auto write = std::make_shared<test::OffloadControl>();
  write->ready = true;
  const auto prompt = request(801).promptTokens;
  fixture.cache.beginRequest(800);
  require(fixture.cache.ensureTokens(800, 64).granted(), "restore fixture KV failed");
  fixture.cache.publishCompositeState(test::publishBlocks(fixture.cache, 800, prompt, 64),
                                      std::make_shared<test::OffloadState>(write), false);
  fixture.cache.endRequest(800);
  require(test::stateStep(fixture.cache).gave() && fixture.cache.snapshot().stateCache.bytes == 0,
          "restore fixture did not offload its RAM state");
  loop.announceReady(protocol::peer::kTestReady);
  require(loop.receive(protocol::peer::serialize(request(801))), "restore request failed");
  for (int i = 0; i < 8 && executor.diskReads == 0; ++i)
    static_cast<void>(loop.tick());
  require(executor.diskReads == 1 && executor.requests.contains(801) &&
              executor.requests.at(801).resident && !loop.destroyEngine() && loop.hasEngine(),
          "pending restore did not retain its lane and Engine");
  if (closeAdmission) {
    loop.closeAdmission();
    require(loop.receive(protocol::peer::serialize(request(802))), "closed request broke framing");
    unsigned errors = 0;
    for (const auto &event : fixture.events())
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&event);
          error && error->requestId == 802 && error->code == "inference_unavailable")
        ++errors;
    require(errors == 1 && executor.diskReads == 1 && !executor.requests.contains(802) &&
                executor.requests.at(801).resident && loop.engineHealthy() && !loop.destroyEngine(),
            "closed admission disturbed the pending restore");
  }
  require(loop.receive(protocol::peer::serialize(protocol::CancelFrame{801})), "cancel failed");
  static_cast<void>(loop.tick());
  require(executor.restoreControl->cancelled && executor.requests.contains(801) &&
              executor.requests.at(801).resident && !loop.destroyEngine(),
          "cancel released the lane before restore drained");
  if (closeAdmission) {
    for (const auto &event : fixture.events()) {
      const auto *done = std::get_if<protocol::DoneEvent>(&event);
      const auto *error = std::get_if<protocol::ErrorEvent>(&event);
      require((!done || done->requestId != 801) && (!error || error->requestId != 801),
              "pending restore emitted a terminal event before draining");
    }
  }
  executor.restoreControl->ready = true;
  for (int i = 0; i < 8 && !idle(loop); ++i)
    static_cast<void>(loop.tick());
  require(idle(loop) && !executor.requests.contains(801), "restore did not drain");
  if (closeAdmission) {
    unsigned cancelled = 0;
    unsigned errors = 0;
    unsigned doneCount = 0;
    for (const auto &event : fixture.events()) {
      if (const auto *done = std::get_if<protocol::DoneEvent>(&event); done && done->requestId == 801) {
        ++doneCount;
        cancelled += done->reason == EngineFinishReason::Cancelled;
      }
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&event); error && error->requestId == 801)
        ++errors;
    }
    require(doneCount == 1 && cancelled == 1 && errors == 0,
            "drained restore did not emit exactly one cancelled completion");
  }
  require(static_cast<bool>(loop.destroyEngine()) && !loop.hasEngine(), "drained Engine did not detach");
}

void testPendingRestoreLifecycleClosedAdmission() { testPendingRestoreLifecycle(true); }

} // namespace

std::span<const test::TestCase> batteryTests() {
  static constexpr test::TestCase kTests[] = {
      {"testDetachedRetainedPersistenceDrivesThePollBound", testDetachedRetainedPersistenceDrivesThePollBound},
      {"testCloseBeforeSubmitStartsNothing", testCloseBeforeSubmitStartsNothing},
      {"testSubmitBeforeCloseKeepsTheAdmittedRequest", testSubmitBeforeCloseKeepsTheAdmittedRequest},
      {"testControlAndCancellationSurviveClosedAdmission", testControlAndCancellationSurviveClosedAdmission},
      {"testReopenIsExplicit", testReopenIsExplicit},
      {"testClockCallbacksQueryAdmissionWithoutReenteringTheGate", testClockCallbacksQueryAdmissionWithoutReenteringTheGate},
      {"testCloseInsideTheClockRefusesThatRequest", testCloseInsideTheClockRefusesThatRequest},
      {"testCloseStartedInsideTheClockRacesTheSubmission", testCloseStartedInsideTheClockRacesTheSubmission},
      {"testWakeupBoundAggregatesSources", testWakeupBoundAggregatesSources},
      {"testEngineSchedulingStillDrivesTheBound", testEngineSchedulingStillDrivesTheBound},
      {"testRetainedPersistenceDrivesThePollBound", testRetainedPersistenceDrivesThePollBound},
      {"testStalledWriteBudgetAdmissionIsTheBound", testStalledWriteBudgetAdmissionIsTheBound},
      {"testHandoffRefusesIOTheRetainedGraphStillRuns", testHandoffRefusesIOTheRetainedGraphStillRuns},
      {"testHandoffRefusesClosuresAndDescendantsPastTheGPU", testHandoffRefusesClosuresAndDescendantsPastTheGPU},
      {"testStagedAdoptionBindingsAndPreparationFailure", testStagedAdoptionBindingsAndPreparationFailure},
      {"testEnginelessShellRefusesThenPublishesAndServes", testEnginelessShellRefusesThenPublishesAndServes},
      {"testTryPublishEngineKeepsRefusedCandidatesOwnable", testTryPublishEngineKeepsRefusedCandidatesOwnable},
      {"testDestroyEngineRefusesRetainedGraphIO", testDestroyEngineRefusesRetainedGraphIO},
      {"testPublishedEngineCapacityIsTheExactWindow", testPublishedEngineCapacityIsTheExactWindow},
      {"testPendingRestoreLifecycleClosedAdmission", testPendingRestoreLifecycleClosedAdmission},

      {"testClosedAdmissionRetainsRequestsAndRequiresExplicitReopen", testClosedAdmissionRetainsRequestsAndRequiresExplicitReopen},
      {"testHandoffRequiresClosedAdmissionAndEveryWitness", testHandoffRequiresClosedAdmissionAndEveryWitness},
      {"testHandoffWaitsForQueuedAndParkedRequests", testHandoffWaitsForQueuedAndParkedRequests},
      {"testHandoffProofExpiresAfterDomainMutation", testHandoffProofExpiresAfterDomainMutation},
      {"testCloseAndSubmitHaveOneWinner", testCloseAndSubmitHaveOneWinner},
  };
  return kTests;
}
