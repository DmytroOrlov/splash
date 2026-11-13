#include "AllocationFailure.hpp"
#include "ProtocolPeer.hpp"
#include "TestChecks.hpp"
#include "TestCache.hpp"
#include "TestEngine.hpp"
#include "TestExecutor.hpp"
#include "TestKvPool.hpp"
#include "TestKvTier.hpp"
#include "TestMetalMemory.hpp"
#include "TestStatus.hpp"
#include "TestWriteBudget.hpp"
#include "engine/Cache.hpp"
#include "engine/MemoryControl.hpp"
#include "engine/NativeRuntime.hpp"
#include "engine/ReleasableMemory.hpp"
#include "metal/CommandWatchdog.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <future>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>
#include <unistd.h>

using namespace splash;
using namespace splash::engine;

namespace {

using splash::test::Executor;
using splash::test::rejects;
using splash::test::require;
using splash::test::Weights;

// A host whose spare memory is all its available memory.
std::optional<HostMemory> hostMemory(std::optional<uint64_t> bytes) {
  if (!bytes)
    return std::nullopt;
  return HostMemory{*bytes, *bytes};
}

// Every submitted request has ended and no command is in flight.
bool idle(const engine::NativeRuntime &loop) {
  const EngineSnapshot counts = loop.snapshot();
  return counts.submitted == counts.completed + counts.cancelled + counts.failed &&
         !loop.commandInFlight();
}

protocol::RequestFrame request(uint64_t id, uint32_t maxOutputTokens = 1) {
  protocol::RequestFrame result;
  result.requestId = id;
  result.priority = RequestPriority::Foreground;
  result.constraint = ConstraintMode::None;
  result.absoluteDeadlineUnixMicros = 2'000'000;
  result.remainingDeadlineMicros = 1'000'000;
  result.logicalMaxOutputTokens = maxOutputTokens;
  result.promptTokens.resize(65);
  for (uint32_t i = 0; i < result.promptTokens.size(); ++i) {
    result.promptTokens[i] = i + 1;
  }
  return result;
}

protocol::RequestFrame scoreRequest(uint64_t id, uint32_t promptTokens) {
  protocol::RequestFrame result = request(id, 0);
  result.promptTokens.resize(promptTokens);
  for (uint32_t i = 0; i < result.promptTokens.size(); ++i)
    result.promptTokens[i] = i + 1;
  result.scoreTokens = {10, 20, 30};
  return result;
}

void runUntilIdle(engine::NativeRuntime &loop) {
  for (uint32_t step = 0; step < 32 && !idle(loop); ++step) {
    static_cast<void>(loop.tick());
  }
  require(idle(loop), "native loop did not become idle");
}

// The KV pool under the loop: `pages` pages in extents of `extentPages`, of
// which the first `runwayPages` are allocated up front.
struct PoolShape {
  uint32_t pages = 32;
  uint32_t extentPages = 4;
  uint32_t runwayPages = pages;
};

// A native loop over the fake model, collecting the bytes it writes. Its
// config is completed with the engine's (test::engineConfig), and the
// fixture's metrics and weights, each weight allocation admitted, the
// optional growth too (test::admitAll), where the test gave none; the
// weights' idle release is production's unless the test gives one. Its unix
// clock stands still and its awake clock reads `monotonic`, advanced by
// `clockStep` on every read.
struct LoopFixture {
  explicit LoopFixture(NativeLoopConfig config = {}, PoolShape shape = {},
                       protocol::ProtocolLimits limits = {},
                       double idleReleaseSeconds = metal::kResidencyKeepAliveSeconds,
                       bool useConfigClocks = false)
      : storage(shape.pages, 4096, shape.extentPages),
        pool(storage, shape.runwayPages), cache(pool, nullptr, nullptr),
        persistence(cache),
        loop(clocked(std::move(config), useConfigClocks), idleReleaseSeconds, cache, persistence,
            executor,
            [this](std::span<const uint8_t> bytes) {
              if (writeFailure)
                throw *writeFailure;
              output.insert(output.end(), bytes.begin(), bytes.end());
            },
            [this] { return status(); }, limits) {
    storage.commandInFlight = [this] { return loop.commandInFlight(); };
  }

  // Every event the loop has written.
  std::vector<protocol::EngineEvent> events() const {
    return protocol::peer::decodeEvents(output);
  }

  NativeLoopConfig clocked(NativeLoopConfig config, bool useConfigClocks) {
    config.engine = test::engineConfig(std::move(config.engine));
    if (!config.metrics)
      config.metrics = &metrics;
    if (!config.weights)
      config.weights = &weights;
    if (!config.weightAdmission)
      config.weightAdmission = test::admitAll;
    if (!config.growthAdmission)
      config.growthAdmission = test::admitAll;
    if (!useConfigClocks) {
      config.unixMicros = [] { return uint64_t{1'000'000}; };
      config.monotonicMilliseconds = [this] { return monotonic += clockStep; };
    }
    return config;
  }

  test::TestKvStorage storage;
  KvPool pool;
  engine::Cache cache;
  // The persistence queue this loop's Engine borrows: retained beside the
  // Cache, declared after it and before the loop, as every Engine over this
  // Cache shares it.
  test::RetainedPersistence persistence;
  Executor executor;
  std::vector<uint8_t> output;
  // Thrown by every write while set, as by a closed output pipe.
  std::optional<std::system_error> writeFailure;
  // What the loop answers a status request with.
  std::function<std::string()> status = test::readyStatusJson;
  double monotonic = 100.0;
  double clockStep = 0.0;
  RuntimeMetrics metrics;
  Weights weights;
  engine::NativeRuntime loop;
};

void testPromptProgress() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 8192;
  LoopFixture fixture(config, {.pages = 512});
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  fixture.clockStep = 0.25;
  loop.announceReady();
  auto submit = [&](uint64_t id, bool enabled) {
    auto input = request(id);
    input.flags = enabled ? protocol::kReturnProgressFlag : 0;
    input.promptTokens.resize(4097);
    for (uint32_t i = 0; i < input.promptTokens.size(); ++i)
      input.promptTokens[i] = i + 1;
    require(loop.receive(protocol::peer::serialize(input)),
            "progress request failed");
  };

  const auto commandsReady = executor.holdCommands();
  submit(1, true);
  require(loop.tick() && loop.commandInFlight(), "prefill was not submitted");
  for (int i = 0; i < 3; ++i)
    static_cast<void>(loop.tick());
  uint32_t count = 0;
  for (const auto &message : fixture.events()) {
    if (const auto *event =
            std::get_if<protocol::PromptProgressEvent>(&message)) {
      require(event->processedTokens == 0,
              "unfinished command advanced progress");
      ++count;
    }
  }
  require(count == 1, "missing initial progress or repeated pending progress");
  *commandsReady = true;
  runUntilIdle(loop);
  submit(2, true);
  runUntilIdle(loop);
  submit(3, false);
  runUntilIdle(loop);

  std::unordered_map<uint64_t, uint32_t> processed;
  std::unordered_map<uint64_t, uint64_t> elapsed;
  std::unordered_map<uint64_t, bool> tokensSeen;
  uint32_t coldUpdates = 0;
  for (const auto &message : fixture.events()) {
    if (const auto *event =
            std::get_if<protocol::PromptProgressEvent>(&message)) {
      require(event->requestId != 3, "default path emitted progress");
      require(!tokensSeen[event->requestId],
              "progress arrived after generation");
      const bool first = !processed.contains(event->requestId);
      require(first || event->processedTokens > processed[event->requestId],
              "progress repeated or moved backwards");
      require(event->processedTokens <= 4097 &&
                  event->elapsedMicros >= elapsed[event->requestId],
              "progress overflow or elapsed time regression");
      if (first)
        require(event->processedTokens == (event->requestId == 1 ? 0 : 4096),
                "initial progress did not include the cache hit");
      processed[event->requestId] = event->processedTokens;
      elapsed[event->requestId] = event->elapsedMicros;
      coldUpdates += event->requestId == 1;
    } else if (const auto *event =
                   std::get_if<protocol::TokensEvent>(&message)) {
      if (event->requestId != 3)
        require(processed[event->requestId] == 4097,
                "generation started before prompt progress completed");
      tokensSeen[event->requestId] = true;
    }
  }
  require(coldUpdates >= 3 && tokensSeen[1] && tokensSeen[2] && tokensSeen[3],
          "missing incremental progress or terminal output");

  fixture.output.clear();
  *commandsReady = false;
  submit(4, true);
  require(loop.tick() && loop.commandInFlight(),
          "cancel test needs pending work");
  require(loop.receive(protocol::peer::serialize(protocol::CancelFrame{4})),
          "cancel request failed");
  *commandsReady = true;
  runUntilIdle(loop);
  count = 0;
  bool cancelled = false;
  for (const auto &message : fixture.events()) {
    if (std::holds_alternative<protocol::PromptProgressEvent>(message))
      ++count;
    if (const auto *event = std::get_if<protocol::DoneEvent>(&message))
      cancelled = event->reason == EngineFinishReason::Cancelled;
  }
  require(count == 1 && cancelled,
          "cancelled prefill published further progress");
}

// /status active_requests: a live request's phase, prompt progress, output
// budget and age since its arrival, until it finishes.
void testSnapshotReportsLiveRequests() {
  engine::NativeLoopConfig config;
  LoopFixture fixture(config, {.pages = 512});
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  const auto commandsReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(7, 4))), "request failed");
  require(loop.tick() && loop.commandInFlight(), "prefill was not submitted");
  fixture.monotonic += 250.0;
  const std::vector<engine::ActiveRequestSnapshot> active = loop.statusSnapshot().activeRequests;
  require(active.size() == 1 && active[0].id == 7 && active[0].phase == engine::Phase::Prefill &&
              active[0].priority == RequestPriority::Foreground && active[0].promptTokens == 65 &&
              active[0].promptProcessed == 0 && active[0].generatedTokens == 0 &&
              active[0].maxNewTokens == 4 && active[0].ageMilliseconds == 250.0,
          "a prefilling request's progress or age is wrong");
  *commandsReady = true;
  runUntilIdle(loop);
  require(loop.statusSnapshot().activeRequests.empty(), "a finished request is still reported");
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
  executor.beginGrowthBlocked = [&] { return fixture.cache.snapshot().stateCache.bytes != 0; };
  loop.announceReady();
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

void testWireLifecycleAndCacheHit() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  fixture.clockStep = 0.25;

  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(request(1))),
          "cold request wire failed");
  require(loop.tick() && loop.commandInFlight(),
          "status regression requires a pending command");
  require(
      loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{77})),
      "in-flight status request failed");
  const auto pendingMessages = fixture.events();
  require(loop.commandInFlight() &&
              std::any_of(pendingMessages.begin(), pendingMessages.end(),
                          [](const auto &message) {
                            const auto *event =
                                std::get_if<protocol::StatusJsonEvent>(&message);
                            return event && event->correlationId == 77;
                          }),
          "status waited for or drained the pending command");
  runUntilIdle(loop);
  require(loop.receive(protocol::peer::serialize(request(2))),
          "junction request wire failed");
  runUntilIdle(loop);
  require(loop.receive(protocol::peer::serialize(request(3))),
          "restored request wire failed");
  runUntilIdle(loop);
  auto messages = fixture.events();
  uint32_t misses = 0;
  uint32_t hits = 0;
  uint32_t tokens = 0;
  uint32_t done = 0;
  bool statusSeen = false;
  for (const auto &message : messages) {
    if (const auto *start = std::get_if<protocol::StartEvent>(&message)) {
      if (!start->matchedPromptTokens) {
        ++misses;
      } else {
        ++hits;
        require(start->matchedPromptTokens == 64,
                "prefix hit did not replay one token");
      }
    } else if (const auto *emitted =
                   std::get_if<protocol::TokensEvent>(&message)) {
      tokens += emitted->tokens.size();
    } else if (std::holds_alternative<protocol::DoneEvent>(message)) {
      ++done;
    } else if (const auto *reported =
                   std::get_if<protocol::StatusJsonEvent>(&message)) {
      statusSeen = reported->correlationId == 77;
    }
  }
  require(misses == 1 && hits == 2 && executor.restored == 128,
          "cold/latest-replay/hit classification is wrong");
  require(tokens == 3 && done == 3 && statusSeen,
          "native lifecycle events are incomplete");
}

// The request's generation prompt reaches the engine: its replay state, which
// an identical retry resumes from, ends before it.
void testGenerationPromptBoundsTheReplayState() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  fixture.clockStep = 0.25;
  loop.announceReady();
  for (uint64_t id : {1, 2}) {
    auto input = request(id);
    input.generationPromptTokens = 2;
    require(loop.receive(protocol::peer::serialize(input)),
            "generation prompt request wire failed");
    runUntilIdle(loop);
  }
  std::vector<uint32_t> matched;
  for (const auto &message : fixture.events()) {
    if (const auto *start = std::get_if<protocol::StartEvent>(&message))
      matched.push_back(start->matchedPromptTokens);
  }
  require(matched == std::vector<uint32_t>{0, 32},
          "the replay state did not end before the generation prompt");
}

// A request's cache salt reaches the engine: the same prompt under another
// salt starts cold and under its own salt resumes. A Done event reports the
// tokens a request read from blocks another request computed, and a salt no
// other request uses reads none.
void testCacheSaltAndDeduplicationCrossTheWire() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  fixture.clockStep = 0.25;
  loop.announceReady();
  const auto send = [&](protocol::RequestFrame input) {
    require(loop.receive(protocol::peer::serialize(input)), "salted request wire failed");
    runUntilIdle(loop);
  };
  for (const auto &[id, salt] : {std::pair<uint64_t, uint64_t>{1, 7}, {2, 8}, {3, 7}}) {
    auto input = request(id);
    input.cacheSalt = {salt, 0};
    send(input);
  }
  // An unsalted longer prompt, then two with its first three blocks' tokens
  // and no state there: one unsalted, one under a salt no other request uses.
  auto longer = request(4, 8);
  longer.promptTokens.resize(129);
  for (uint32_t i = 0; i < longer.promptTokens.size(); ++i)
    longer.promptTokens[i] = 1000 + i;
  send(longer);
  for (const auto &[id, salt] : {std::pair<uint64_t, uint64_t>{5, 0}, {6, 99}}) {
    auto branch = longer;
    branch.requestId = id;
    branch.cacheSalt = {salt, 0};
    std::fill(branch.promptTokens.begin() + 100, branch.promptTokens.end(), 7);
    send(branch);
  }
  std::unordered_map<uint64_t, uint32_t> matched, deduplicated;
  for (const auto &message : fixture.events()) {
    if (const auto *start = std::get_if<protocol::StartEvent>(&message))
      matched[start->requestId] = start->matchedPromptTokens;
    if (const auto *done = std::get_if<protocol::DoneEvent>(&message))
      deduplicated[done->requestId] = done->deduplicatedTokens;
  }
  require(matched.at(1) == 0 && matched.at(2) == 0 && matched.at(3) > 0,
          "a request's cache salt did not reach the engine");
  require(matched.at(5) == 0 && deduplicated.at(5) > 0 && matched.at(6) == 0 &&
              deduplicated.at(6) == 0,
          "a Done event did not carry the tokens read from another request's blocks");
}

// A request's flags reach the model with the rest of its request.
void testRequestFlagsReachTheModel() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  fixture.clockStep = 0.25;
  loop.announceReady();
  for (uint64_t id : {1, 2}) {
    auto input = request(id);
    input.flags = id == 2 ? RequestIgnoreEndOfSequence : 0;
    require(loop.receive(protocol::peer::serialize(input)),
            "flagged request wire failed");
    runUntilIdle(loop);
  }
  require(executor.beganFlags ==
              std::unordered_map<uint64_t, uint32_t>{
                  {1, 0}, {2, RequestIgnoreEndOfSequence}},
          "request flags did not reach the model");
}

// The penalties cross the wire to the model with the rest of the sampling;
// greedy requests carry them too.
void testSamplingReachesTheModel() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  fixture.clockStep = 0.25;
  loop.announceReady();
  auto greedy = request(1);
  greedy.sampling = {0.0f, 1.0f, 0, 1.5f, 0.0f, 1.1f, 0.2f};
  auto sampled = request(2);
  sampled.sampling = {0.7f, 0.8f, 20, -0.5f, 2.0f, 0.9f, 0.05f};
  sampled.sampling.seed = 77;
  for (const auto &input : {greedy, sampled}) {
    require(loop.receive(protocol::peer::serialize(input)),
            "sampled request wire failed");
    runUntilIdle(loop);
  }
  require(executor.beganSampling.at(1) == greedy.sampling &&
              executor.beganSampling.at(2) == sampled.sampling,
          "a penalty, min_p or the seed did not reach the model");
}

// A header without the magic, and an event the engine sends itself: neither
// is a client frame, so framing is lost and the connection closes.
void testFatalFramingClosesConnection() {
  const auto event = protocol::serializeEvent(protocol::StatusJsonEvent{1, "{}"},
                                              protocol::ProtocolLimits{});
  require(static_cast<bool>(event), "status event encoding failed");
  for (const auto &[invalid, code] :
       {std::pair{std::vector<uint8_t>(protocol::kFrameHeaderBytes), "bad_magic"},
        std::pair{*event.value, "unknown_frame_type"}}) {
    LoopFixture fixture({}, {.pages = 8});
    engine::NativeRuntime &loop = fixture.loop;
    require(!loop.receive(invalid), "bad frame did not close connection");
    require(loop.connectionMustClose() && loop.engineHealthy(),
            "protocol failure was misclassified as engine failure");
    const auto events = fixture.events();
    const auto *error = events.size() == 1
                            ? std::get_if<protocol::ErrorEvent>(&events.front())
                            : nullptr;
    require(error &&
                error->failureClass == protocol::FailureClass::ProtocolFatal &&
                error->code == code,
            "a frame that is not a client frame was not reported as fatal");
  }
}

// A request rejected while it is decoded is a request-scoped error: the
// frames behind it in the same read, whole or cut by the read boundary, must
// still be processed.
void testRequestErrorKeepsFraming() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  protocol::ProtocolLimits limits;
  limits.maxLogicalOutputTokens = 1;
  LoopFixture fixture(config, {}, limits);
  engine::NativeRuntime &loop = fixture.loop;

  loop.announceReady();
  // Errors, completions and status answers so far; every error must be the
  // rejected request's own.
  const auto events = [&] {
    std::array<uint32_t, 3> counts{};
    for (const protocol::EngineEvent &message : fixture.events()) {
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
        require(error->failureClass == protocol::FailureClass::RequestError &&
                    error->requestId == 9,
                "rejected request was not reported as its own error");
      }
      counts[0] += std::holds_alternative<protocol::ErrorEvent>(message);
      counts[1] += std::holds_alternative<protocol::DoneEvent>(message);
      counts[2] += std::holds_alternative<protocol::StatusJsonEvent>(message);
    }
    return counts;
  };

  const auto rejected = protocol::peer::serialize(request(9, 2));
  const auto first = protocol::peer::serialize(request(1));
  const auto status =
      protocol::peer::serialize(protocol::StatusRequestFrame{77});
  std::vector<uint8_t> read = rejected;
  read.insert(read.end(), first.begin(), first.end());
  read.insert(read.end(), status.begin(), status.end());
  require(loop.receive(read), "request-scoped error closed the connection");
  runUntilIdle(loop);
  require(events() == std::array<uint32_t, 3>{1, 1, 1},
          "frames behind a rejected request were dropped");

  const auto second = protocol::peer::serialize(request(2));
  const size_t half = second.size() / 2;
  read = rejected;
  read.insert(read.end(), second.begin(), second.begin() + half);
  require(loop.receive(read) &&
              loop.receive(std::span<const uint8_t>(second).subspan(half)),
          "cut frame behind a rejected request closed the connection");
  runUntilIdle(loop);
  require(events() == std::array<uint32_t, 3>{2, 2, 1} && loop.engineHealthy(),
          "cut frame behind a rejected request was not reassembled");
}

void testCapacityFailureHasOneTerminalFrame() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config, {.pages = 4, .extentPages = 1, .runwayPages = 1});
  engine::NativeRuntime &loop = fixture.loop;
  fixture.storage.budgetPages = 1;

  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(request(3))),
          "capacity request wire failed");
  runUntilIdle(loop);

  uint32_t capacity = 0;
  uint32_t errors = 0;
  uint32_t done = 0;
  for (const protocol::EngineEvent &message : fixture.events()) {
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
      ++errors;
      capacity += error->failureClass == protocol::FailureClass::RequestError &&
                  !error->retryable &&
                  error->code ==
                      laneOutcomeWire(LaneOutcome::CapacityExhausted).code;
    }
    done += std::holds_alternative<protocol::DoneEvent>(message);
  }
  require(capacity == 1 && errors == 1 && done == 0,
          "capacity failure emitted more than one terminal frame");
  require(loop.engineHealthy(),
          "request-scoped capacity failure made the engine unhealthy");
}

void testCommandWatchdogAndPendingHealthWake() {
  metal::CommandWatchdog generations(120.0);
  generations.start(1, 0.0);
  generations.complete(1);
  require(!generations.expired(1000.0), "completed command retained a deadline");
  generations.start(2, 10.0);
  generations.complete(1);
  require(!generations.expired(129.999) && generations.expired(130.0),
          "stale completion cleared a newer command deadline");
  // A command's progress (its host steps) moves its deadline a timeout on,
  // and another command's moves nothing.
  metal::CommandWatchdog progressing(120.0);
  progressing.start(3, 0.0);
  progressing.progress(3, 100.0);
  progressing.progress(2, 200.0);
  require(!progressing.expired(219.999) && progressing.expired(220.0),
          "a command's progress did not move its deadline, or another's did");

  for (bool gpuCompleted : {false, true}) {
    LoopFixture fixture;
    engine::NativeRuntime &loop = fixture.loop;
    Executor &executor = fixture.executor;
    double &now = fixture.monotonic;
    now = 0.0;
    const auto commandReady = executor.holdCommands();
    // The model lane each request holds, given back: once, at its terminal
    // boundary (and never while its command is still parked).
    uint32_t laneReleases = 0;
    executor.laneReleased = [&] { ++laneReleases; };
    metal::CommandWatchdog watchdog(120.0);
    executor.submitObserver = [&] { watchdog.start(1, now / 1000.0); };
    executor.healthCheck = [&] {
      if (watchdog.expired(now / 1000.0))
        throw metal::MetalBackendError("test command completion timeout");
    };
    loop.announceReady();
    auto input = request(1);
    input.absoluteDeadlineUnixMicros = 601'000'000;
    input.remainingDeadlineMicros = 600'000'000;
    require(loop.receive(protocol::peer::serialize(input)) && loop.tick(),
            "watchdog fixture did not submit its command");
    // The held ModelBatchTicket keeps its admitted lane: the request reached the
    // model, the Engine still owns it, and nothing has given the lane back.
    // That the Engine cannot be destroyed under that pending ticket is the drain
    // barrier's proof (T016/T024), which this gate-only loop has no seam for yet.
    require(loop.commandInFlight() && !idle(loop) &&
                executor.beganFlags.contains(1) && laneReleases == 0,
            "held ModelBatchTicket did not retain its admitted model lane");
    require(loop.receive(protocol::peer::serialize(protocol::CancelFrame{1})) &&
                loop.millisecondsUntilNextWakeup() == 1000.0,
            "cancelled in-flight command lost its bounded health wake");
    now = 119'999.0;
    require(!loop.tick() && loop.engineHealthy() && loop.commandInFlight(),
            "watchdog failed a command before its safety deadline");
    if (gpuCompleted)
      watchdog.complete(1);
    now = 120'000.0;
    require(!loop.tick(), "held command unexpectedly completed");
    if (gpuCompleted) {
      require(loop.engineHealthy() && loop.commandInFlight(),
              "a model-side wait was mistaken for a pending GPU command");
      *commandReady = true;
      require(loop.tick() && idle(loop), "completed GPU ownership did not drain");
      require(laneReleases == 1,
              "terminal ModelBatchTicket retained the request lane");
    } else {
      uint32_t errors = 0;
      for (const auto &message : fixture.events()) {
        if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
          require(error->requestId == 0 &&
                      error->failureClass == protocol::FailureClass::EngineUnhealthy &&
                      error->code == "metal_execution_failed",
                  "watchdog timeout lost structured engine failure");
          ++errors;
        }
      }
      require(errors == 1 && loop.connectionMustClose() &&
                  loop.commandInFlight() && !idle(loop),
              "watchdog released command ownership or emitted duplicate failures");
    }
  }

  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  require(!loop.tick() && idle(loop) && !loop.millisecondsUntilNextWakeup(),
          "fully idle engine retained a polling wake");
}

void testDuplicateLiveRequestClosesWithoutAmbiguousError() {
  for (bool malformed : {false, true}) {
    protocol::ProtocolLimits limits;
    limits.maxLogicalOutputTokens = 1;
    LoopFixture fixture({}, {}, limits);
    engine::NativeRuntime &loop = fixture.loop;
    loop.announceReady();
    require(loop.receive(protocol::peer::serialize(request(1))) && loop.tick(),
            "live duplicate fixture did not start");
    require(!loop.receive(
                protocol::peer::serialize(request(1, malformed ? 2 : 1))) &&
                loop.connectionMustClose() && loop.snapshot().submitted == 1,
            "duplicate live request was accepted");
    uint32_t errors = 0;
    for (const auto &message : fixture.events()) {
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
        require(error->requestId == 0 &&
                    error->failureClass == protocol::FailureClass::ProtocolFatal,
                "duplicate id produced an ambiguous error for the active request");
        ++errors;
      }
    }
    require(errors == 1, "duplicate id produced multiple terminal errors");
  }
}

// The protocol frees an id when its request ends. A cancel and a new request
// for that id in one input start the new request while the engine still
// holds the cancelled one's finished entry.
void testCancelledIdIsReusableInTheSameInput() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(request(7, 4))) &&
              loop.tick() && loop.tick() && !loop.commandInFlight(),
          "the first request did not start");
  std::vector<uint8_t> input =
      protocol::peer::serialize(protocol::CancelFrame{7});
  const std::vector<uint8_t> again = protocol::peer::serialize(request(7));
  input.insert(input.end(), again.begin(), again.end());
  require(loop.receive(input),
          "a cancel and a request for one id closed the connection");
  runUntilIdle(loop);
  std::vector<EngineFinishReason> done;
  uint32_t errors = 0;
  for (const auto &message : fixture.events()) {
    if (const auto *event = std::get_if<protocol::DoneEvent>(&message))
      done.push_back(event->reason);
    errors += std::holds_alternative<protocol::ErrorEvent>(message);
  }
  require(errors == 0 &&
              done == std::vector<EngineFinishReason>{
                          EngineFinishReason::Cancelled,
                          EngineFinishReason::Stop},
          "a cancelled id was not reusable in the same input");
}

void testControlFailureUsesExecutionBoundary() {
  for (bool metalFailure : {false, true}) {
    LoopFixture fixture;
    engine::NativeRuntime &loop = fixture.loop;
    loop.announceReady();
    require(loop.runControl([] { return true; }) && loop.engineHealthy(),
            "ordinary deferred control work failed");
    require(!loop.runControl([&]() -> bool {
              if (metalFailure)
                throw metal::MetalBackendError("control test");
              throw std::runtime_error("control test");
            }), "failed control work requested another retry");
    uint32_t errors = 0;
    for (const auto &message : fixture.events()) {
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
        require(error->requestId == 0 &&
                    error->failureClass == protocol::FailureClass::EngineUnhealthy &&
                    error->code == (metalFailure ? "metal_execution_failed"
                                                : "engine_execution_failed"),
                "control exception lost structured failure classification");
        ++errors;
      }
    }
    require(errors == 1 && !loop.engineHealthy() && loop.connectionMustClose(),
            "control exception did not terminate the unhealthy engine");
  }
}

// A frame whose handling throws stops the engine through the same boundary
// as tick(): one EngineUnhealthy event, whatever was thrown, with a Metal
// failure named and counted, and the engine's failure told once.
void testFrameFailureUsesExecutionBoundary() {
  enum class Thrown { Standard, Metal, Foreign };
  for (const Thrown thrown : {Thrown::Standard, Thrown::Metal, Thrown::Foreign}) {
    RuntimeMetrics metrics;
    engine::NativeLoopConfig config;
    config.metrics = &metrics;
    uint32_t told = 0;
    config.engineFailed = [&told] { ++told; };
    LoopFixture fixture(config, {.pages = 8});
    engine::NativeRuntime &loop = fixture.loop;
    fixture.status = [thrown]() -> std::string {
      if (thrown == Thrown::Standard)
        throw std::runtime_error("status test");
      if (thrown == Thrown::Metal)
        throw metal::MetalBackendError("status test");
      throw 42;
    };
    loop.announceReady();
    require(!loop.receive(protocol::peer::serialize(
                protocol::StatusRequestFrame{77})) &&
                !loop.engineHealthy() && loop.connectionMustClose(),
            "a failed status frame did not stop the engine");
    uint32_t errors = 0;
    for (const auto &message : fixture.events()) {
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
        require(error->requestId == 0 &&
                    error->failureClass == protocol::FailureClass::EngineUnhealthy &&
                    error->code == (thrown == Thrown::Metal
                                        ? "metal_execution_failed"
                                        : "engine_execution_failed"),
                "a frame exception lost its engine failure classification");
        ++errors;
      }
    }
    require(errors == 1 && told == 1 &&
                metrics.snapshot().metalFailures == (thrown == Thrown::Metal ? 1U : 0U),
            "a frame exception was reported, told or counted other than once");
  }
}

// The loop checks its protocol limits once, when it is built; the codec and
// the parser rely on them.
void testInvalidLimitsAreRejectedAtConstruction() {
  protocol::ProtocolLimits limits;
  limits.maxMaskWords = 0;
  rejects([&] { LoopFixture fixture({}, {.pages = 8}, limits); }, "limit_exceeded",
          "the loop accepted invalid protocol limits");
}

// The loop refuses a config without its metrics, their admissions or its clocks
// (NativeRuntime's constructor). Its weights may be absent, which is the
// residency-conditional contract T009 settled and `runtime-resources`' own
// null-weights case proves: a loop built without weights is built, not refused.
void testLoopNeedsItsComponents() {
  for (const int lacking : {0, 1, 2, 3}) {
    test::TestKvStorage storage(8, 4096, 4);
    KvPool pool(storage, 8);
    engine::Cache cache(pool, nullptr, nullptr);
    test::RetainedPersistence persistence(cache);
    Executor executor;
    RuntimeMetrics runtimeMetrics;
    NativeLoopConfig config{.engine = test::engineConfig(),
                            .metrics = lacking == 0 ? nullptr : &runtimeMetrics,
                            .weightAdmission = lacking == 1 ? nullptr : test::admitAll,
                            .growthAdmission = lacking == 2 ? nullptr : test::admitAll,
                            .unixMicros = lacking == 3 ? std::function<uint64_t()>()
                                                       : [] { return uint64_t{1'000'000}; }};
    rejects([&] {
      engine::NativeRuntime(std::move(config), metal::kResidencyKeepAliveSeconds, cache,
                            persistence, executor, [](std::span<const uint8_t>) {},
                            test::readyStatusJson, protocol::ProtocolLimits{});
    }, "the native engine loop lacks a component it needs",
            "a loop without its metrics, their admissions or its clocks was built");
  }
  // Absent weights, every other component there: built, and its weights paths
  // stay absent-safe.
  test::TestKvStorage storage(32, 4096, 4);
  KvPool pool(storage, 32);
  engine::Cache cache(pool, nullptr, nullptr);
  test::RetainedPersistence persistence(cache);
  Executor executor;
  RuntimeMetrics runtimeMetrics;
  engine::NativeRuntime loop(
      NativeLoopConfig{.engine = test::engineConfig(),
                       .metrics = &runtimeMetrics,
                       .weightAdmission = test::admitAll,
                       .growthAdmission = test::admitAll,
                       .unixMicros = [] { return uint64_t{1'000'000}; },
                       .monotonicMilliseconds = [] { return 100.0; }},
      metal::kResidencyKeepAliveSeconds, cache, persistence, executor,
      [](std::span<const uint8_t>) {}, test::readyStatusJson,
      protocol::ProtocolLimits{});
  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(request(1))),
          "a loop without weights refused an admitted request");
  runUntilIdle(loop);
  require(loop.snapshot().submitted == 1 && loop.snapshot().completed == 1 &&
              !loop.weightsSnapshot().restoring && loop.engineHealthy() &&
              !loop.connectionMustClose(),
          "the weights-free loop served its request other than normally");
  loop.closeAdmission();
  require(!loop.admissionOpen() && loop.receive(protocol::peer::serialize(request(2))) &&
              loop.snapshot().submitted == 1,
          "the weights-free loop lost its admission boundary");
  loop.openAdmission();
  require(loop.admissionOpen(), "the weights-free loop could not reopen admission");
}

// An exception while the engine admits a request is engine-fatal: nothing
// below the engine rolls back, and the loop reports it once.
void testAdmissionExceptionStopsTheEngineOnce() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  fixture.executor.beginObserver = [] { throw std::runtime_error("begin failed"); };
  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(request(1))),
          "admission fixture was refused");
  require(!loop.tick() && !loop.engineHealthy() && loop.connectionMustClose(),
          "an admission exception did not stop the engine");
  uint32_t errors = 0;
  for (const auto &message : fixture.events()) {
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
      require(error->requestId == 0 &&
                  error->failureClass == protocol::FailureClass::EngineUnhealthy &&
                  error->code == "engine_execution_failed" &&
                  error->message == "begin failed",
              "an admission exception lost its engine failure");
      ++errors;
    }
  }
  require(errors == 1, "an admission exception was reported more than once");
}

// Every path that stops the engine keeps its reason for the exit log, not
// only the ones that report through engineError().
void testEngineFailureNamesItsReason() {
  {
    LoopFixture fixture({}, {.pages = 8});
    engine::NativeRuntime &loop = fixture.loop;
    const std::system_error closed(EPIPE, std::generic_category(),
                                   "write(native output)");
    loop.announceReady();
    fixture.writeFailure = closed;
    require(!loop.receive(
                protocol::peer::serialize(protocol::StatusRequestFrame{77})) &&
                !loop.engineHealthy() && loop.connectionMustClose(),
            "a failed output write did not stop the engine");
    require(loop.engineFailure() ==
                std::string("output_write_failed: ") + closed.what(),
            "a failed output write left the engine failure unnamed");
  }
  {
    LoopFixture fixture({}, {.pages = 8});
    engine::NativeRuntime &loop = fixture.loop;
    loop.announceReady();
    const auto frame = protocol::peer::serialize(request(1));
    // A header and one payload byte: the parser's first allocation is the
    // payload buffer, and it fails.
    allocationFailureAfter = 0;
    const bool received = loop.receive(std::span<const uint8_t>(
        frame.data(), protocol::kFrameHeaderBytes + 1));
    allocationFailureAfter = -1;
    uint32_t errors = 0;
    for (const auto &message : fixture.events()) {
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
        require(error->failureClass ==
                        protocol::FailureClass::EngineUnhealthy &&
                    error->code == "allocation_failure",
                "an inbound allocation failure lost its classification");
        ++errors;
      }
    }
    require(!received && errors == 1 && !loop.engineHealthy() &&
                loop.connectionMustClose(),
            "an inbound allocation failure did not stop the engine");
    require(loop.engineFailure() ==
                "allocation_failure: allocation failed while receiving frame "
                "payload",
            "an inbound allocation failure left the engine failure unnamed");
  }
}

void testOutOfVocabularyTokensStayRequestScoped() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.engine.vocabularySize = 128;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  std::vector<protocol::RequestFrame> invalid;
  for (uint32_t token : {128U, std::numeric_limits<uint32_t>::max()}) {
    invalid.push_back(request(9));
    invalid.back().promptTokens.back() = token;
  }
  invalid.push_back(scoreRequest(9, 65));
  invalid.back().scoreTokens.back() = 128;
  for (const protocol::RequestFrame &frame : invalid) {
    require(loop.receive(protocol::peer::serialize(frame)),
            "out-of-vocabulary token closed the native connection");
  }
  auto valid = request(1);
  valid.promptTokens.back() = 127;
  require(loop.receive(protocol::peer::serialize(valid)),
          "valid request after invalid tokens was rejected");
  runUntilIdle(loop);
  uint32_t errors = 0, done = 0;
  for (const auto &message : fixture.events()) {
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
      require(error->requestId == 9 && error->code == "invalid_request" &&
                  error->failureClass == protocol::FailureClass::RequestError,
              "out-of-vocabulary token did not produce its own request error");
      ++errors;
    }
    done += std::holds_alternative<protocol::DoneEvent>(message);
  }
  require(errors == invalid.size() && done == 1 && loop.engineHealthy() &&
              loop.snapshot().submitted == 1,
          "invalid tokens reached admission or prevented subsequent completion");
}

// Whether Ready announces vision for an engine admitting images of up to
// `maxImagePatches` patches.
bool announcedVision(uint32_t maxImagePatches) {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.engine.maxImagePatches = maxImagePatches;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  const auto announced = fixture.events();
  const auto *ready = announced.size() == 1
                          ? std::get_if<protocol::ReadyEvent>(&announced.front())
                          : nullptr;
  require(ready, "announceReady did not send exactly one Ready event");
  return ready->vision;
}

void testReadyAnnouncesVisionWhenImagesAreAdmitted() {
  require(announcedVision(ops::kMaximumImagePatches),
          "Ready did not announce vision for an engine that admits images");
  require(!announcedVision(0),
          "Ready announced vision for an engine serving without it");
}

// Without vision, or past the server's per-image patch cap, an image request
// fails by itself and the engine keeps serving.
void testImageRequestBeyondVisionStaysRequestScoped() {
  // The image below has 64 patches.
  const std::pair<uint32_t, std::string_view> cases[] = {
      {0, "this model is serving without vision"},
      {32, "image has more patches than the server's pixel cap allows"}};
  for (const auto &[maxImagePatches, expected] : cases) {
    engine::NativeLoopConfig config;
    config.engine.maxContext = 1024;
    config.engine.maxImagePatches = maxImagePatches;
    LoopFixture fixture(config);
    engine::NativeRuntime &loop = fixture.loop;
    loop.announceReady();
    auto image = request(9);
    image.imageSpans = {{8, 16, 8, 8, 1, 2}};
    image.imagePixels.assign(image.imageSpans[0].pixelBytes(), 1);
    for (const protocol::RequestFrame &frame : {image, request(1)}) {
      require(loop.receive(protocol::peer::serialize(frame)),
              "image request closed the native connection");
    }
    runUntilIdle(loop);
    uint32_t errors = 0, done = 0;
    for (const auto &message : fixture.events()) {
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
        require(error->requestId == 9 && error->code == "invalid_request" &&
                    error->failureClass ==
                        protocol::FailureClass::RequestError &&
                    error->message == expected,
                "image request did not produce its own vision error");
        ++errors;
      }
      done += std::holds_alternative<protocol::DoneEvent>(message);
    }
    require(errors == 1 && done == 1 && loop.engineHealthy() &&
                loop.snapshot().submitted == 1,
            "image request reached admission or stopped the engine");
  }
}

// A verify step can retain every row and add the terminal anchor; the wire
// limit the production binary derives from ExecutionLimits must carry that
// step in one TokensEvent, and an event that cannot be encoded must surface
// as an engine error rather than a silently shorter stream.
void testStepTokensFitTheWire() {
  for (uint32_t limit : {model::ExecutionLimits::maximumStepTokens, 1U}) {
    engine::NativeLoopConfig config;
    config.engine.maxContext = 1024;
    protocol::ProtocolLimits limits;
    limits.maxTokenBatch = limit;
    LoopFixture fixture(config, {}, limits);
    engine::NativeRuntime &loop = fixture.loop;
    Executor &executor = fixture.executor;
    executor.decodeTokens = model::ExecutionLimits::maximumStepTokens;

    loop.announceReady();
    require(loop.receive(
                protocol::peer::serialize(request(5, executor.decodeTokens))),
            "step request wire failed");
    runUntilIdle(loop);

    uint32_t streamed = 0;
    std::optional<uint32_t> completion;
    uint32_t encodeErrors = 0;
    for (const protocol::EngineEvent &message : fixture.events()) {
      if (const auto *emitted = std::get_if<protocol::TokensEvent>(&message)) {
        streamed += emitted->tokens.size();
      } else if (const auto *done = std::get_if<protocol::DoneEvent>(&message)) {
        completion = done->completionTokens;
      } else if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
        encodeErrors += error->code == "protocol_encode_failed" &&
                        error->failureClass ==
                            protocol::FailureClass::EngineUnhealthy;
      }
    }
    if (limit >= executor.decodeTokens) {
      require(streamed == executor.decodeTokens && completion == streamed &&
                  !encodeErrors && loop.engineHealthy(),
              "a full step with its terminal anchor did not fit one event");
    } else {
      require(!streamed && !completion && encodeErrors == 1 &&
                  !loop.engineHealthy() && loop.connectionMustClose(),
              "an unencodable event was not reported as an engine error");
      require(loop.engineFailure().starts_with("protocol_encode_failed: "),
              "an unencodable event left the engine failure unnamed");
    }
  }
}

void testScoreRequestCompletesAfterFullPrompt() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 8192;
  LoopFixture fixture(config, {.pages = 512});
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(scoreRequest(9, 3000))),
          "score request failed");
  runUntilIdle(loop);

  uint32_t tokensEvents = 0;
  uint32_t doneCount = 0;
  for (const protocol::EngineEvent &message : fixture.events()) {
    if (std::holds_alternative<protocol::TokensEvent>(message))
      ++tokensEvents;
    if (const auto *done = std::get_if<protocol::DoneEvent>(&message)) {
      ++doneCount;
      require(done->requestId == 9, "score done id mismatch");
      require(done->completionTokens == 0, "score done emitted completion");
      require(done->decodeMicros == 0, "score done reported decode time");
      require(done->promptTokens == 3000, "score done prompt count mismatch");
      require(done->optionLogits.size() == 3, "score done logit count mismatch");
      require(done->optionLogits[0] == 0.5f && done->optionLogits[1] == 1.5f &&
                  done->optionLogits[2] == 2.5f,
              "score done logits are not in request order");
      require(done->reason == EngineFinishReason::Stop,
              "score done reason is not stop");
    }
  }
  require(doneCount == 1 && tokensEvents == 0,
          "score request did not complete without generating tokens");
}

void testCancelledScoreReturnsEmptyLogits() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  const auto commandReady = executor.holdCommands();
  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(scoreRequest(11, 65))),
          "cancel-score request failed");
  require(loop.tick() && loop.commandInFlight(), "score prefill was not held");
  protocol::CancelFrame cancel{11};
  require(loop.receive(protocol::peer::serialize(cancel)),
          "score cancel failed");
  *commandReady = true;
  runUntilIdle(loop);

  uint32_t doneCount = 0;
  for (const protocol::EngineEvent &message : fixture.events()) {
    if (const auto *done = std::get_if<protocol::DoneEvent>(&message)) {
      ++doneCount;
      require(done->reason == EngineFinishReason::Cancelled,
              "cancelled score did not report Cancelled");
      require(done->optionLogits.empty(),
              "cancelled score returned logits");
      require(done->completionTokens == 0, "cancelled score emitted tokens");
    }
  }
  require(doneCount == 1, "cancelled score did not emit Done");
}

// A request's prefill time runs from when the engine starts it, even when
// its clock reads zero then, not from its arrival.
void testPrefillTimeCountsFromTheStart() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  fixture.monotonic = -2.0;
  require(loop.receive(protocol::peer::serialize(request(1))), "request wire failed");
  fixture.monotonic = 0.0;
  require(loop.tick() && loop.snapshot().submitted == 1 && loop.commandInFlight(),
          "the request did not start");
  fixture.monotonic = 3.0;
  runUntilIdle(loop);
  std::optional<protocol::DoneEvent> done;
  for (const protocol::EngineEvent &message : fixture.events())
    if (const auto *event = std::get_if<protocol::DoneEvent>(&message))
      done = *event;
  require(done && done->prefillMicros == 3000 && done->wallMicros == 5000,
          "a request started at time zero counted its prefill from its arrival");
}

struct ScoreBesideChat final {
  uint32_t publishedBlocks = 0;
  uint32_t failures = 0;
  uint32_t completions = 0;
  uint32_t tokens = 0;
  uint32_t scoreChunks = 0;
  uint32_t widestBatch = 0;
  uint64_t failedRequest = 0;
  std::string failureCode;
  bool requestScoped = false;
  bool scoreCompleted = false;
  bool scoreEmittedTokens = false;
  bool healthy = false;
  bool slotsReleased = false;
};

// Runs one score request beside one ordinary chat request in a single batch,
// then a third request afterwards. The score's final prompt chunk either
// returns logits or reports a non-finite one.
ScoreBesideChat runScoreBesideChat(bool invalidScore) {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 8192;
  LoopFixture fixture(config, {.pages = 512});
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  if (invalidScore)
    executor.invalidScores.insert(21);
  loop.announceReady();

  // Whole KV pages, so the last prompt chunk is the one that publishes the
  // final block: beside the chat's 65 rows the first command takes all but
  // the last of them. The chat lane deliberately does not share this prefix.
  auto scored = scoreRequest(
      21, model::ExecutionLimits::prefillTokenBudget - 2 * KvCache::pageTokens);
  for (uint32_t index = 0; index < scored.promptTokens.size(); ++index)
    scored.promptTokens[index] = 1000 + index;
  require(loop.receive(protocol::peer::serialize(scored)),
          "score request wire failed");
  require(loop.receive(protocol::peer::serialize(request(22))),
          "batched chat request wire failed");
  runUntilIdle(loop);

  ScoreBesideChat result;
  result.publishedBlocks = fixture.cache.snapshot().pool.pagesPrefix;
  result.healthy = loop.engineHealthy() && !loop.connectionMustClose();
  result.slotsReleased = !executor.requests.contains(21) && !executor.requests.contains(22);
  result.scoreChunks = executor.prefillChunks[21];
  result.widestBatch = std::ranges::max(executor.prefillWidths);

  require(loop.receive(protocol::peer::serialize(request(23))),
          "post-batch request wire failed");
  runUntilIdle(loop);

  for (const protocol::EngineEvent &message : fixture.events()) {
    if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
      ++result.failures;
      result.failedRequest = error->requestId;
      result.failureCode = error->code;
      result.requestScoped =
          error->failureClass == protocol::FailureClass::RequestError;
    } else if (const auto *emitted =
                   std::get_if<protocol::TokensEvent>(&message)) {
      result.scoreEmittedTokens |= emitted->requestId == 21;
      result.tokens += static_cast<uint32_t>(emitted->tokens.size());
    } else if (const auto *done = std::get_if<protocol::DoneEvent>(&message)) {
      ++result.completions;
      result.scoreCompleted |= done->requestId == 21;
    }
  }
  return result;
}

void testInvalidScoreFailsOneRequestAndKeepsTheBatch() {
  const ScoreBesideChat healthy = runScoreBesideChat(false);
  const ScoreBesideChat failed = runScoreBesideChat(true);

  require(healthy.widestBatch == 2 && failed.widestBatch == 2,
          "the score and the chat never shared one batch");
  require(healthy.scoreChunks >= 2 && failed.scoreChunks >= 2,
          "the score prefill never chunked, so nothing isolates its last step");
  require(healthy.failures == 0 && healthy.completions == 3 &&
              !healthy.scoreEmittedTokens,
          "the baseline score batch did not complete cleanly");

  require(failed.healthy, "a non-finite score logit took the whole engine down");
  require(failed.failures == 1 && failed.requestScoped &&
              failed.failedRequest == 21 &&
              failed.failureCode == "model_result_invalid",
          "the non-finite score logit was not a per-request failure");
  require(!failed.scoreCompleted && !failed.scoreEmittedTokens,
          "the failed score still produced a result");
  require(failed.completions == 2 && failed.tokens == healthy.tokens,
          "the failed score took its batch partner or the next request along");
  require(failed.slotsReleased, "the failed score kept its model slot");
  // Chunks before the failing one keep their blocks, exactly as they do for a
  // cancelled request. Only the failed step must publish nothing.
  require(failed.publishedBlocks + 1 == healthy.publishedBlocks,
          "the failed step published its KV block");
}

// A constrained request's initial token mask crosses the native protocol.
// Only the response to the pending mask request, with one row of the
// configured width, reaches the model, and the request goes on to its first
// cycle's verify mask. Any other response fails that request alone, and one
// that arrives after the request ended, cancelled or timed out waiting for
// it, is ignored.
void testConstrainedMaskExchange() {
  enum class Reply {
    Valid,
    WrongMaskId,
    WrongWordCount,
    EmptyRow,
    Malformed,
    AfterCancel,
    AfterTimeout
  };
  for (Reply reply :
       {Reply::Valid, Reply::WrongMaskId, Reply::WrongWordCount,
        Reply::EmptyRow, Reply::Malformed, Reply::AfterCancel,
        Reply::AfterTimeout}) {
    engine::NativeLoopConfig config;
    config.engine.maxContext = 1024;
    // Three mask words per token; the prompt's tokens stay in vocabulary.
    config.engine.vocabularySize = 96;
    LoopFixture fixture(config);
    engine::NativeRuntime &loop = fixture.loop;
    Executor &executor = fixture.executor;
    double &now = fixture.monotonic;
    loop.announceReady();
    const auto send = [&](const protocol::ClientMessage &message) {
      require(loop.receive(protocol::peer::serialize(message)),
              "mask exchange message closed the connection");
    };
    auto constrained = request(7);
    constrained.priority = RequestPriority::Background;
    constrained.constraint = ConstraintMode::TokenMask;
    constrained.absoluteDeadlineUnixMicros = 601'000'000;
    constrained.remainingDeadlineMicros = 600'000'000;
    send(constrained);
    while (loop.tick()) {
    }
    std::optional<protocol::MaskRequestEvent> asked;
    for (const auto &message : fixture.events()) {
      if (const auto *event = std::get_if<protocol::MaskRequestEvent>(&message))
        asked = *event;
    }
    require(asked && asked->requestId == 7 && asked->maskRequestId &&
                asked->wordsPerMask == 3 && asked->simulationTokens.empty(),
            "constrained request did not ask for one initial mask row");

    protocol::MaskResponseFrame response{7, asked->maskRequestId, {1, 0, 0}};
    if (reply == Reply::WrongMaskId)
      ++response.maskRequestId;
    if (reply == Reply::WrongWordCount)
      response.maskWords.push_back(0);
    if (reply == Reply::EmptyRow)
      response.maskWords = {0, 0, 0};
    if (reply == Reply::AfterCancel) {
      send(protocol::CancelFrame{7});
      runUntilIdle(loop);
    }
    if (reply == Reply::AfterTimeout) {
      now += 5000.0;
      runUntilIdle(loop);
    }
    if (reply == Reply::Malformed) {
      // The frame claims one more mask word than it carries.
      auto wire = protocol::peer::serialize(response);
      ++wire[protocol::kFrameHeaderBytes + 16];
      require(loop.receive(wire),
              "malformed mask response closed the connection");
    } else {
      send(response);
    }
    if (reply == Reply::Valid) {
      // Drafting starts once the first token is selected: the first cycle
      // asks for its verify mask, a row for each draft token and the anchor.
      std::optional<protocol::MaskRequestEvent> verify;
      for (uint32_t step = 0; step < 32 && !verify; ++step) {
        static_cast<void>(loop.tick());
        for (const auto &message : fixture.events()) {
          const auto *event = std::get_if<protocol::MaskRequestEvent>(&message);
          if (event && event->maskRequestId != asked->maskRequestId)
            verify = *event;
        }
      }
      require(verify && verify->requestId == 7 && verify->wordsPerMask == 3 &&
                  verify->simulationTokens.size() == 8,
              "the first constrained cycle did not ask for its verify mask");
      protocol::MaskResponseFrame rows{7, verify->maskRequestId, {}};
      for (size_t row = 0; row <= verify->simulationTokens.size(); ++row)
        rows.maskWords.insert(rows.maskWords.end(), {1, 0, 0});
      send(rows);
    }
    runUntilIdle(loop);

    std::optional<EngineFinishReason> done;
    std::vector<std::string> errors;
    std::string errorMessage;
    uint32_t maskRequests = 0;
    for (const auto &message : fixture.events()) {
      if (const auto *event = std::get_if<protocol::DoneEvent>(&message))
        done = event->reason;
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&message)) {
        require(error->requestId == 7 &&
                    error->failureClass == protocol::FailureClass::RequestError,
                "mask response failure was not the request's own error");
        errors.push_back(error->code);
        errorMessage = error->message;
      }
      maskRequests += std::holds_alternative<protocol::MaskRequestEvent>(message);
    }
    require(maskRequests == (reply == Reply::Valid ? 2U : 1U) && loop.engineHealthy() &&
                !loop.connectionMustClose() && !executor.requests.contains(7),
            "mask exchange stopped the engine or kept the request's slot");
    if (reply == Reply::Valid) {
      require(done == EngineFinishReason::Stop && errors.empty() &&
                  executor.providedMasks == 2,
              "valid masks did not let the request finish");
    } else if (reply == Reply::AfterCancel) {
      require(done == EngineFinishReason::Cancelled && errors.empty() &&
                  executor.providedMasks == 0,
              "mask response after cancellation was not ignored");
    } else if (reply == Reply::AfterTimeout) {
      require(!done && errors == std::vector<std::string>{"mask_timeout"} &&
                  executor.providedMasks == 0,
              "mask response after its timeout was not ignored");
    } else {
      require(!done &&
                  errors == std::vector<std::string>{"invalid_mask_response"} &&
                  executor.providedMasks == 0,
              "mismatched mask response did not fail only its request");
      require(reply != Reply::Malformed ||
                  errorMessage.starts_with("invalid_payload_length: "),
              "a malformed mask response lost its decoding issue");
    }
  }
}

// Between commands the control pass runs what the host's pressure asks for:
// with nothing waiting, a paced pass toward the warning margin, which keeps
// the resume point and the empty runway extent, and nothing past it; nothing
// once the host recovers; and under critical pressure every cache entry and
// extent. None waits for a transfer.
void testControlPassReclaimsUnderHostPressure() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  const engine::Cache &resources = fixture.cache;
  const KvPool &pool = fixture.pool;
  loop.announceReady();
  // Two finished requests with different prompts leave two replay states.
  for (uint64_t id : {1, 2}) {
    auto input = request(id);
    for (uint32_t &token : input.promptTokens)
      token += static_cast<uint32_t>(100 * id);
    require(loop.receive(protocol::peer::serialize(input)),
            "control pass request failed");
    runUntilIdle(loop);
  }
  require(resources.snapshot().stateCache.entries == 2,
          "the fixture did not cache two replay states");

  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  std::optional<uint64_t> available = hostReserve + kHostWarningMarginBytes / 2;
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  MemoryControl control(governor, backend, loop);
  require(!control.run(MemoryPressure::Normal), "a paced pass waited for a transfer");
  const auto paced = resources.snapshot();
  require(paced.stateCache.entries == 1 && paced.stateCache.evictions == 1 &&
              paced.pool.reclaimableBytes == 4 * 4096,
          "host pressure did not evict toward its target, keeping the resume "
          "point and the runway extent");

  // Past the warning margin the hysteresis still holds the pressure, but a
  // pass that nothing waits for evicts nothing there: the state a third
  // request caches stays beside the resume point.
  auto third = request(3);
  for (uint32_t &token : third.promptTokens)
    token += 300;
  require(loop.receive(protocol::peer::serialize(third)), "control pass request failed");
  runUntilIdle(loop);
  available = hostReserve + kHostWarningMarginBytes + kHostWarningMarginBytes / 2;
  fixture.monotonic += 1000.0;
  require(!control.run(MemoryPressure::Normal) &&
              governor.snapshot().pressure == MemoryPressure::Warning &&
              resources.snapshot().stateCache.entries == 2,
          "a pass that nothing waited for evicted past the warning margin");

  available = hostReserve + kHostRecoveryMarginBytes + kHostWarningMarginBytes;
  const uint64_t releases = pool.snapshot().extentReleases;
  // The host's recovery lifts the pressure, so no pass runs: the untargeted
  // pass the settle window would otherwise run finds nothing to take either.
  require(!control.run(MemoryPressure::Normal) &&
              governor.snapshot().pressure == MemoryPressure::Normal &&
              resources.snapshot().stateCache.entries == 2 &&
              pool.snapshot().extentReleases == releases,
          "a recovered host still reclaimed");

  require(!control.run(MemoryPressure::Critical), "a critical pass waited for a transfer");
  const auto critical = resources.snapshot();
  require(critical.stateCache.entries == 0 && critical.pool.pagesPrefix == 0 &&
              critical.pool.pagesAllocated == 0,
          "critical pressure did not empty the cache and release every extent");
}

// macOS's warning asks caches to give memory back: however much room the
// host has, a control pass under it returns cache, keeping the resume point
// and the runway extent while nothing waits, and pauses growth. Once the
// level is normal again growth resumes and no pass runs: the state a later
// request caches stays beside the resume point.
void testControlPassGivesCacheBackUnderSystemWarning() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  const engine::Cache &resources = fixture.cache;
  const KvPool &pool = fixture.pool;
  loop.announceReady();
  // Finished requests with different prompts leave a replay state each.
  const auto finish = [&](uint64_t id) {
    auto input = request(id);
    for (uint32_t &token : input.promptTokens)
      token += static_cast<uint32_t>(100 * id);
    require(loop.receive(protocol::peer::serialize(input)), "control pass request failed");
    runUntilIdle(loop);
  };
  finish(1);
  finish(2);
  require(resources.snapshot().stateCache.entries == 2,
          "the fixture did not cache two replay states");

  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  const std::optional<uint64_t> available = hostReserve + (16ULL << 30);
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  MemoryControl control(governor, backend, loop);
  require(!control.run(MemoryPressure::Warning), "a pass under macOS's warning waited for a transfer");
  const auto warned = resources.snapshot();
  require(warned.stateCache.entries == 1 && warned.stateCache.evictions == 1 &&
              warned.pool.reclaimableBytes == 4 * 4096 && !governor.snapshot().hostGrowthAllowed,
          "macOS's warning did not give cache back, keeping the resume point and the runway "
          "extent, or left growth open");

  finish(3);
  fixture.monotonic += 1000.0;
  const uint64_t releases = pool.snapshot().extentReleases;
  require(!control.run(MemoryPressure::Normal) && governor.snapshot().hostGrowthAllowed &&
              resources.snapshot().stateCache.entries == 2 &&
              pool.snapshot().extentReleases == releases,
          "a pass ran once macOS's level was normal again");
}

// A start marks what it allocates as memory a request in service needs until
// serving begins. An allocation the engine marks meanwhile restores the mark
// it found, so the start's mark outlives it, and once serving begins the
// engine's marks still end with their allocations.
void testServingMarkRestoresTheMarkItFound() {
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  const std::optional<uint64_t> available = hostReserve + (16ULL << 30);
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  // Under macOS's warning only the mark admits growth.
  governor.setPressure(MemoryPressure::Warning);
  const auto admits = [&governor] {
    return static_cast<bool>(governor.allocationAdmission()(4096, [] {}));
  };
  const std::function<bool(bool)> mark = [&governor](bool serving) {
    return governor.setServing(serving);
  };
  static_cast<void>(governor.setServing(true));
  {
    const Serving allocation(mark, true);
    require(admits(), "an allocation the engine marked was refused");
  }
  require(admits(), "an allocation the engine marked ended the start's mark");
  static_cast<void>(governor.setServing(false));
  {
    const Serving allocation(mark, true);
    require(admits(), "an allocation the engine marked was refused once serving began");
  }
  require(!admits(), "an allocation the engine marked left its mark behind");
}

// The control pass tells the governor whether a request waits for memory:
// only for one does growth wait for the recovery margin while the host's
// headroom sits between the margins.
void testControlPassHoldsGrowthForAWaitingRequest() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  // A finished request leaves cache a pass can free.
  require(loop.receive(protocol::peer::serialize(request(1))), "the first request failed");
  runUntilIdle(loop);
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  // A page short of the recovery margin, after growth the host refused.
  std::optional<uint64_t> available = hostReserve + kHostRecoveryMarginBytes - 4096;
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  require(!governor.allocationAdmission()(kHostWarningMarginBytes, [] {}),
          "growth past the warning margin was admitted");
  MemoryControl control(governor, backend, loop);
  static_cast<void>(control.run(MemoryPressure::Normal));
  require(governor.snapshot().pressure == MemoryPressure::Warning &&
              governor.snapshot().hostGrowthAllowed,
          "growth waited for the recovery margin with no request waiting");

  // The host refuses the next request's lane, which then waits for memory.
  fixture.executor.beginGrowthBlocked = [] { return true; };
  fixture.executor.beginAllocationFailure = metal::AllocationFailure::HostPressure;
  require(loop.receive(protocol::peer::serialize(request(2))) && !loop.tick() &&
              loop.resourceWaitSnapshot().memory == 1,
          "the request did not wait for memory");
  // The next control pass finds it waiting.
  static_cast<void>(control.run(MemoryPressure::Normal));
  require(!governor.snapshot().hostGrowthAllowed,
          "growth did not wait for the recovery margin while a request waited");

  // Its retry, within its deadline, finds its lane.
  fixture.executor.beginGrowthBlocked = {};
  fixture.monotonic += 2 * engine::kResourceRetryBackoffMilliseconds;
  runUntilIdle(loop);
  static_cast<void>(control.run(MemoryPressure::Normal));
  require(loop.snapshot().completed == 2 && governor.snapshot().hostGrowthAllowed,
          "the hold outlived the waiting request");
}

bool answeredStatus(const LoopFixture &fixture, uint64_t correlationId) {
  const auto events = fixture.events();
  return std::any_of(events.begin(), events.end(), [&](const auto &message) {
    const auto *event = std::get_if<protocol::StatusJsonEvent>(&message);
    return event && event->correlationId == correlationId;
  });
}

// Sends a release request and returns the weights' snapshot its answer reports:
// the status document that answers it is written from the loop's snapshot of the
// moment (RuntimeBootstrap::statusJson).
WeightsSnapshot releaseAnswer(LoopFixture &fixture, uint64_t correlationId) {
  std::optional<WeightsSnapshot> reported;
  fixture.status = [&] {
    reported = fixture.loop.weightsSnapshot();
    return test::readyStatusJson();
  };
  require(fixture.loop.receive(
              protocol::peer::serialize(protocol::ReleaseRequestFrame{correlationId})) &&
              answeredStatus(fixture, correlationId) && reported,
          "a release request was not answered with a status document");
  fixture.status = test::readyStatusJson;
  return *reported;
}

// The control pass between commands releases the weights once the engine has
// held no request for the idle release, counted from Ready or from the end of
// the last request however long it ran, never while one is there. A request
// waits while they are written back, an image per tick, so the loop answers
// frames between them, and the images all come back even when it is cancelled,
// while memory admits them (testRefusedRestoreWaitsForMemory). A restore that
// fails other than for memory stops the engine. What the engine gives back
// while idle without a Neural Engine split, ReleasableMemory over the images
// alone, is the images: the test runs through it when `releasable`.
void testIdleWeightsAreReleasedAndRestored(bool releasable) {
  constexpr double kIdleReleaseSeconds = 2.0;
  constexpr double idleRelease = 1000.0 * kIdleReleaseSeconds;
  Weights weights;
  ReleasableMemory memory({&weights}, std::nullopt);
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.weights = releasable ? static_cast<model::WeightMemory *>(&memory) : &weights;
  LoopFixture fixture(config, {}, {}, kIdleReleaseSeconds);
  engine::NativeRuntime &loop = fixture.loop;
  fixture.executor.beginObserver = [&] {
    require(!weights.released(), "the model began a request on released weights");
  };
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, 40ULL << 30, 2ULL << 30, 2ULL << 30,
                          [] { return hostMemory(64ULL << 30); }, 0);
  MemoryControl control(governor, backend, loop);
  const auto idlePass = [&](double elapsed) {
    fixture.monotonic += elapsed;
    static_cast<void>(control.run(MemoryPressure::Normal));
    return weights.released();
  };
  // Warmup before Ready is not idleness.
  fixture.monotonic += 10 * idleRelease;
  loop.announceReady();
  require(!idlePass(idleRelease - 1), "weights were released before the idle release passed");
  require(idlePass(1), "idle weights were kept past the idle release");
  require(loop.weightsSnapshot().released && loop.weightsSnapshot().restores == 0 &&
              loop.weightsSnapshot().idleReleaseSeconds == kIdleReleaseSeconds,
          "the weights' snapshot did not report their release");

  require(loop.receive(protocol::peer::serialize(request(1))) && weights.restores == 0,
          "weights were written back before a tick");
  require(loop.tick() && weights.restores == 1 && weights.released(),
          "a tick did not write back one image");
  require(loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{77})) &&
              answeredStatus(fixture, 77),
          "the loop did not answer status while it restored the weights");
  while (weights.released())
    require(loop.tick(), "a tick did not write back an image");
  require(weights.restores == Weights::kImages, "an image was written back twice");
  require(!loop.weightsSnapshot().released && loop.weightsSnapshot().restores == 1,
          "the weights' snapshot did not count one restore");
  require(!idlePass(2 * idleRelease), "weights were released under a request");
  runUntilIdle(loop);

  require(loop.receive(protocol::peer::serialize(request(2))), "a second request failed");
  // It runs past the idle release, without a control pass between commands.
  fixture.clockStep = idleRelease;
  runUntilIdle(loop);
  fixture.clockStep = 0;
  require(!idlePass(0), "weights were released as soon as a long request ended");
  require(idlePass(idleRelease), "weights were kept past the idle release after a request");

  require(loop.receive(protocol::peer::serialize(request(3))) && loop.tick() &&
              loop.receive(protocol::peer::serialize(protocol::CancelFrame{3})),
          "a request cancelled while the weights came back failed");
  while (weights.released())
    require(loop.tick(), "a cancelled request stopped its weights coming back");
  require(weights.restores == 2 * Weights::kImages, "an image was written back twice");
  // The transport ticks again after a tick that progressed: the engine then
  // lets the cancelled request go.
  static_cast<void>(loop.tick());

  require(idlePass(idleRelease), "weights were kept past the idle release after a cancel");
  weights.failRestore = true;
  require(loop.receive(protocol::peer::serialize(request(4))) && !loop.tick(),
          "a failed restore kept the engine running");
  const auto events = fixture.events();
  require(std::any_of(events.begin(), events.end(),
                      [](const auto &message) {
                        const auto *error = std::get_if<protocol::ErrorEvent>(&message);
                        return error &&
                               error->failureClass == protocol::FailureClass::EngineUnhealthy &&
                               error->message.find("weights restore test") != std::string::npos;
                      }) &&
              !loop.engineHealthy() && loop.connectionMustClose(),
          "a failed restore did not stop the engine");
}

// A store of streamed experts (model::ExpertStore), the part after the images,
// goes back with them and comes back in one restore after their last; a
// release during a restore gives back what came back.
void testReleasableMemoryRestoresTheExpertsAfterTheImages() {
  Weights weights;
  struct Experts final : model::WeightMemory {
    bool held = true;
    uint32_t restores = 0;
    [[nodiscard]] bool released() const noexcept override { return !held; }
    void release() override { held = false; }
    bool restore(const metal::AllocationAdmission &, const metal::AllocationAdmission &) override {
      require(!held, "a held arena was restored");
      held = true;
      ++restores;
      return true;
    }
  } experts;
  ReleasableMemory memory({&weights, &experts}, std::nullopt);
  const metal::AllocationAdmission admit = [](uint64_t, const std::function<void()> &operation) {
    operation();
    return metal::AllocationResult{};
  };
  memory.release();
  require(memory.released() && weights.released() && experts.released(),
          "the release kept the images or the arena");
  for (uint32_t image = 0; image < Weights::kImages; ++image)
    require(!memory.restore(admit, admit) && experts.released(),
            "the arena came back before the last image");
  require(!weights.released() && memory.released(), "the restore ended without the arena");
  require(memory.restore(admit, admit) && !memory.released() && experts.restores == 1,
          "the arena did not come back in one restore after the images");
  memory.release();
  require(!memory.restore(admit, admit) && weights.held() == 1,
          "a restore did not write the first image back");
  memory.release();
  require(weights.held() == 0 && experts.released() && experts.restores == 1,
          "a release during a restore kept what came back");
}

// With the Neural Engine split, the idle release gives back the images, then
// the split's program. A request waits while the images are written back, an
// image per tick, and the program is loaded in one tick more, before the
// request begins. A program that does not load again stops the split, never
// the engine (ops::AneFfn::restore): the request runs. The stopped split gives
// back what a load that ran late may have left once, at the next idle
// release, and loads nothing, so that the images alone come back after that.
void testIdleReleaseRestoresTheSplitLast() {
  constexpr double kIdleReleaseSeconds = 2.0;
  constexpr double idleRelease = 1000.0 * kIdleReleaseSeconds;
  Weights weights;
  // The split's program: whether it is loaded, whether the split released
  // it, the times it was loaded again, and whether the split stopped, as one
  // whose program does not load again (`failLoad`) does.
  bool loaded = true, released = false, stopped = false, failLoad = false;
  uint32_t loads = 0;
  ReleasableMemory memory(
      {&weights}, ReleasableMemory::Split{
                   [&] {
                     require(weights.released(),
                             "the split's program was unloaded before the images were released");
                     if (released)
                       return false;
                     released = true;
                     loaded = false;
                     return true;
                   },
                   [&] {
                     require(!weights.released() && !loaded,
                             "the split's program was loaded before every image was written back");
                     if (!released || stopped)
                       return;
                     released = false;
                     ++loads;
                     if (failLoad)
                       stopped = true;
                     else
                       loaded = true;
                   }});
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.weights = &memory;
  LoopFixture fixture(config, {}, {}, kIdleReleaseSeconds);
  engine::NativeRuntime &loop = fixture.loop;
  fixture.executor.beginObserver = [&] {
    require(!weights.released() && (loaded || stopped),
            "the model began a request before the split's program was back");
  };
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, 40ULL << 30, 2ULL << 30, 2ULL << 30,
                          [] { return hostMemory(64ULL << 30); }, 0);
  MemoryControl control(governor, backend, loop);
  const auto idlePass = [&] {
    fixture.monotonic += idleRelease;
    static_cast<void>(control.run(MemoryPressure::Normal));
    return memory.released();
  };
  // Sends request `id`, which ends the idle, and ticks once per image, the
  // request waiting: true while it still waits after the last image.
  const auto imagesBack = [&](uint64_t id) {
    require(loop.receive(protocol::peer::serialize(request(id))), "a request was refused");
    for (uint32_t image = 0; image < Weights::kImages; ++image)
      require(loop.tick() && loop.snapshot().completed == id - 1,
              "a request ran before every image was written back");
    return loop.weightsSnapshot().restores == id - 1;
  };
  loop.announceReady();

  require(idlePass() && !loaded, "the idle release kept the split's program");
  require(imagesBack(1) && !loaded && !memory.released(),
          "the restore ended with the last image, before the split's program");
  // The weights are no longer released, but the restore is still under way: a
  // release request leaves it alone, and its answer reports it.
  const WeightsSnapshot answer = releaseAnswer(fixture, 1);
  require(!answer.released && answer.restoring && !memory.released() && !loaded,
          "a release request before the split's program was back was answered as a release");
  require(loop.tick() && loaded && loads == 1 && loop.weightsSnapshot().restores == 1,
          "the tick after the last image did not load the split's program");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 1, "the request did not run once the program was back");

  failLoad = true;
  require(idlePass() && !loaded, "the idle release kept the split's program");
  require(imagesBack(2) && loop.tick() && stopped && loads == 2 &&
              loop.weightsSnapshot().restores == 2 && loop.engineHealthy(),
          "a program that did not load again failed the restore");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 2, "the request did not run after the split stopped");

  require(idlePass() && released, "the stopped split kept what its program may hold");
  require(imagesBack(3) && loop.tick() && loads == 2 && loop.weightsSnapshot().restores == 3,
          "a stopped split's program was loaded again");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 3 && loop.engineHealthy(),
          "a request after the split stopped did not run");
  require(idlePass(), "the idle release kept the images once the split stopped");
  require(!imagesBack(4) && loads == 2 && loop.weightsSnapshot().restores == 4,
          "the images did not come back alone once the stopped split had given its program back");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 4, "a later request did not run");
}

// A restore takes the weights' memory under the governor's admission as
// memory the requests waiting need: the host's margins do not refuse it, and
// critical pressure does. A refused restore keeps the parts that came back
// and makes no progress; the loop tries again after the retry backoff, and
// every request waits for memory, as their resource wait reports, for the
// resource wait limit from the first refusal after the last part that came
// back. Memory that comes back in time lets the restore go on. Once the limit
// passes, every request waiting fails retryably and the weights give back the
// parts that came back, the split's program still released for the next
// restore to load last; the engine stays up, and the next request starts
// over, its wait counted afresh. A refused restore that no request waits for
// any more takes no memory past the host's margins: it gives up at once and
// counts no failure.
void testRefusedRestoreWaitsForMemory() {
  constexpr double kIdleReleaseSeconds = 2.0;
  constexpr double kWaitLimit = 400.0;
  constexpr uint64_t kReserve = 2ULL << 30;
  constexpr uint64_t kHostMemory = 64ULL << 30;
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  uint64_t hostAvailable = kHostMemory;
  MemoryGovernor governor(backend, 40ULL << 30, kReserve, kReserve,
                          [&] { return hostMemory(hostAvailable); }, 0);
  Weights weights;
  uint32_t programReleases = 0, programLoads = 0;
  ReleasableMemory memory({&weights}, ReleasableMemory::Split{[&] {
                                                             ++programReleases;
                                                             return true;
                                                           },
                                                           [&] { ++programLoads; }});
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.engine.resourceWaitTimeoutMilliseconds = kWaitLimit;
  config.engine.serving = [&](bool serving) { return governor.setServing(serving); };
  config.weights = &memory;
  config.weightAdmission = governor.allocationAdmission();
  LoopFixture fixture(config, {}, {}, kIdleReleaseSeconds);
  engine::NativeRuntime &loop = fixture.loop;
  MemoryControl control(governor, backend, loop);
  const auto pass = [&](MemoryPressure pressure, double elapsed = 0.0) {
    fixture.monotonic += elapsed;
    static_cast<void>(control.run(pressure));
  };
  const auto errorOf = [&](uint64_t id) -> std::optional<protocol::ErrorEvent> {
    for (const auto &message : fixture.events())
      if (const auto *error = std::get_if<protocol::ErrorEvent>(&message);
          error && error->requestId == id)
        return *error;
    return std::nullopt;
  };
  loop.announceReady();

  pass(MemoryPressure::Normal, 1000.0 * kIdleReleaseSeconds);
  require(memory.released() && programReleases == 1, "idle weights were kept");
  hostAvailable = kReserve + (512ULL << 20);
  require(governor.allocationAdmission()(Weights::kImageBytes, [] {}).failure ==
              metal::AllocationFailure::HostPressure,
          "the host's margin admitted memory no request needs");
  require(loop.receive(protocol::peer::serialize(request(1))) && loop.tick() &&
              weights.held() == 1,
          "the host's margin held back weights a request waits for");

  pass(MemoryPressure::Critical);
  require(!loop.tick() && weights.held() == 1 && weights.restores == 1,
          "critical pressure admitted the weights' memory");
  require(loop.millisecondsUntilNextWakeup() == engine::kResourceRetryBackoffMilliseconds &&
              loop.resourceWaitSnapshot().memory == 1,
          "the request behind a refused restore did not wait for memory");
  fixture.monotonic += kWaitLimit - 1.0;
  require(!loop.tick() && weights.held() == 1 && !errorOf(1) && loop.engineHealthy() &&
              loop.resourceWaitSnapshot().oldestWaitMilliseconds == kWaitLimit - 1.0,
          "a refused restore gave up before the resource wait limit");
  hostAvailable = kHostMemory;
  pass(MemoryPressure::Normal);
  runUntilIdle(loop);
  require(loop.snapshot().completed == 1 && weights.restores == Weights::kImages &&
              programLoads == 1 && loop.weightsSnapshot().restores == 1,
          "the restore did not go on once memory came back");

  pass(MemoryPressure::Normal, 1000.0 * kIdleReleaseSeconds);
  require(memory.released() && programReleases == 2 &&
              loop.receive(protocol::peer::serialize(request(2))) && loop.tick() &&
              weights.held() == 1,
          "the second restore did not write back its first image");
  pass(MemoryPressure::Critical);
  require(!loop.tick(), "critical pressure admitted the second image");
  require(loop.receive(protocol::peer::serialize(request(4))) && !loop.tick() &&
              loop.resourceWaitSnapshot().memory == 2,
          "a request that came during a refused restore did not wait for memory");
  fixture.monotonic += 0.75 * kWaitLimit;
  pass(MemoryPressure::Normal);
  require(loop.tick() && weights.held() == 2, "the second image did not come back");
  pass(MemoryPressure::Critical);
  require(!loop.tick(), "critical pressure admitted the third image");
  fixture.monotonic += 0.75 * kWaitLimit;
  require(!loop.tick() && weights.held() == 2 && !errorOf(2) && !errorOf(4),
          "the resource wait limit did not restart once a part came back");
  fixture.monotonic += 0.25 * kWaitLimit;
  require(loop.tick(), "a restore past the resource wait limit made no progress");
  for (uint64_t id : {2, 4}) {
    const std::optional<protocol::ErrorEvent> error = errorOf(id);
    require(error && error->failureClass == protocol::FailureClass::RequestError &&
                error->code == "resource_timeout" && error->retryable &&
                error->message.find("macOS is short of memory") != std::string::npos,
            "a request behind a restore that gave up did not fail retryably");
  }
  require(memory.released() && weights.held() == 0 && programReleases == 2 &&
              loop.weightsSnapshot().restoreFailures == 1 &&
              loop.resourceWaitSnapshot().memory == 0 && loop.engineHealthy() &&
              !loop.connectionMustClose(),
          "a restore that gave up kept what came back, released the program again or stopped "
          "the engine");

  pass(MemoryPressure::Normal);
  static_cast<void>(loop.tick());
  require(weights.held() == 0, "a restore went on after it gave up");

  pass(MemoryPressure::Critical);
  require(loop.receive(protocol::peer::serialize(request(3))) && !loop.tick() && !errorOf(3) &&
              loop.resourceWaitSnapshot().memory == 1,
          "the next request did not wait for memory afresh");
  pass(MemoryPressure::Normal);
  runUntilIdle(loop);
  require(loop.snapshot().completed == 2 && weights.restores == 2 * Weights::kImages + 2 &&
              programLoads == 2 && loop.weightsSnapshot().restores == 2,
          "the next request did not restore the weights from the first image");

  pass(MemoryPressure::Normal, 1000.0 * kIdleReleaseSeconds);
  require(memory.released() && loop.receive(protocol::peer::serialize(request(5))) &&
              loop.tick() && weights.held() == 1,
          "the last restore did not write back its first image");
  pass(MemoryPressure::Critical);
  require(!loop.tick() && loop.receive(protocol::peer::serialize(protocol::CancelFrame{5})),
          "a refused restore's request could not be cancelled");
  hostAvailable = kReserve + (512ULL << 20);
  pass(MemoryPressure::Normal);
  require(loop.tick() && memory.released() && weights.held() == 0 &&
              loop.weightsSnapshot().restoreFailures == 1 &&
              !loop.millisecondsUntilNextWakeup(),
          "a refused restore no request waits for took memory past the host's margin, went "
          "on, or counted a failure");
}

// With --idle-release off the control pass never releases the weights,
// however long the engine holds no request, but a release request still does,
// and the next request restores them.
void testIdleReleaseOffReleasesOnlyOnRequest() {
  Weights weights;
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.weights = &weights;
  LoopFixture fixture(config, {}, {}, std::numeric_limits<double>::infinity());
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  fixture.monotonic += 1e12;
  loop.releaseIdleWeights();
  require(!weights.released(), "weights were released with the idle release off");
  const WeightsSnapshot answer = releaseAnswer(fixture, 5);
  require(weights.released() && answer.released && !answer.restoring &&
              answer.idleReleaseSeconds == std::numeric_limits<double>::infinity(),
          "a release request did not release the weights with the idle release off");
  require(loop.receive(protocol::peer::serialize(request(1))), "the request after the release failed");
  runUntilIdle(loop);
  require(!weights.released() && weights.restores == Weights::kImages,
          "the request did not restore the weights released with the idle release off");
  // An idle release that is not positive is refused.
  for (double seconds : {0.0, -1.0, std::numeric_limits<double>::quiet_NaN()}) {
    rejects([&] { LoopFixture refusedFixture(config, {}, {}, seconds); },
            "the idle release must be positive",
            "an idle release that is not positive was accepted");
  }
}

// A release request gives the weights back now, as the idle release does, when
// the engine holds no request and no restore is under way, and otherwise leaves
// them as they are. Either way its answer reports what the engine did: released
// and not restoring only once the weights are given back; a restore under way,
// which leaves them released until its last image, as restoring. The next
// request restores them as after the idle release.
void testReleaseRequestGivesTheWeightsBackWhenIdle() {
  Weights weights;
  ReleasableMemory memory({&weights}, std::nullopt);
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.weights = &memory;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  require(!weights.released(), "the weights were released before any release request");

  WeightsSnapshot answer = releaseAnswer(fixture, 5);
  require(weights.released() && answer.released && !answer.restoring && answer.restores == 0,
          "an idle engine did not release its weights on request");
  // A second release request changes nothing, and is answered as the first.
  answer = releaseAnswer(fixture, 6);
  require(weights.released() && answer.released && !answer.restoring,
          "releasing released weights again failed");

  // A request restores them, an image per tick. A release request during the
  // restore leaves it alone, and its answer reports the restore.
  require(loop.receive(protocol::peer::serialize(request(1))) && loop.tick() &&
              weights.held() == 1,
          "the request did not start the restore");
  answer = releaseAnswer(fixture, 7);
  require(weights.held() == 1 && answer.released && answer.restoring,
          "a release request during the restore released the weights, or its answer did not "
          "report the restore");
  while (weights.released())
    require(loop.tick(), "a tick did not write back an image");
  require(weights.restores == Weights::kImages, "the restore was disturbed by a release request");

  // With a request in service the weights stay.
  require(loop.receive(protocol::peer::serialize(request(2))), "a second request failed");
  answer = releaseAnswer(fixture, 8);
  require(!weights.released() && !answer.released && !answer.restoring,
          "the weights were released under a request");
  runUntilIdle(loop);
  answer = releaseAnswer(fixture, 9);
  require(weights.released() && answer.released && !answer.restoring,
          "the engine did not release once its request ended");
}

// The loop reports that it holds requests from the first it takes to the end
// of its last, the span the process keeps the Mac from idle sleep for.
void testHoldingRequestsSpansFirstToLastRequest() {
  std::vector<bool> reported;
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.holdingRequests = [&](bool held) { reported.push_back(held); };
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  require(reported.empty(), "a loop without requests reported holding one");
  require(loop.receive(protocol::peer::serialize(request(1))) &&
              loop.receive(protocol::peer::serialize(request(2))),
          "two requests failed");
  require(reported == std::vector<bool>{true}, "two requests did not share one span");
  runUntilIdle(loop);
  require(reported == std::vector<bool>{true, false},
          "the span did not end with the last request");
  // A cancelled request completes; a request whose deadline passes fails.
  require(loop.receive(protocol::peer::serialize(request(3))) && loop.tick() &&
              loop.receive(protocol::peer::serialize(protocol::CancelFrame{3})),
          "a cancelled request failed");
  runUntilIdle(loop);
  require(reported == std::vector<bool>{true, false, true, false},
          "a cancelled request did not end its span");
  require(loop.receive(protocol::peer::serialize(request(4, 64))), "request 4 failed");
  fixture.monotonic += 5000.0;
  runUntilIdle(loop);
  require(reported == std::vector<bool>{true, false, true, false, true, false},
          "a request that failed did not end its span");
  // One refused on arrival is never held.
  protocol::RequestFrame expired = request(5);
  expired.absoluteDeadlineUnixMicros = 1'000'000;
  require(loop.receive(protocol::peer::serialize(expired)) && reported.size() == 6,
          "a request refused on arrival was held");
}

// The reporter logs a change in what requests wait for, never a retry or the
// depth of a queue.
void testMemoryStatusReporterLogsTransitionsOnly() {
  ResourceWaitSnapshot wait{.memory = 2, .concurrency = 1, .heldBehindRefusal = 4,
                            .restoring = 1, .suspended = 1,
                            .oldestWaitMilliseconds = 1250.0, .draining = true};
  MemoryStatusReporter reporter;
  require(reporter.update({}, true).empty(), "healthy idle engine logged pressure");
  require(!reporter.update(wait, false).empty(), "pressure transition was silent");
  ++wait.memory;
  wait.oldestWaitMilliseconds += 1000;
  require(reporter.update(wait, false).empty(), "pressure retries flooded the log");
  wait = {};
  wait.concurrency = 4;
  require(!reporter.update(wait, true).empty(), "end of memory wait was silent");
  require(reporter.update(wait, true).empty(), "concurrency queue logged pressure");
  // The refused request is deferred for scheduling, out of the memory
  // count, while it still holds the others back.
  wait.heldBehindRefusal = 2;
  const std::string held = reporter.update(wait, true);
  require(held.find("held=2") != std::string::npos &&
              held.find("cleared") == std::string::npos,
          "requests held behind a refusal were reported as no wait");
}

// Ticks until no command is in flight, where the transport runs the control
// pass.
void settleCommand(engine::NativeRuntime &loop) {
  for (uint32_t step = 0; step < 8 && loop.commandInFlight(); ++step)
    static_cast<void>(loop.tick());
  require(!loop.commandInFlight(), "the command in flight did not complete");
}

// A control pass the policy asks nothing of takes back one chunk of the
// expert store toward its cap while memory is ample: the host has the
// recovery margin to spare beyond the chunk, or the idle engine returns the
// rest to the system first, no request waits for memory, the weights are
// neither released nor being restored, and the cool-down after reclaim last
// gave a chunk back has passed. Beside a resident lane it takes only room
// the engine's limit has free, and asks for none it lacks.
void testControlPassGrowsTheExpertStoreWhenMemoryIsAmple() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  loop.announceReady();
  constexpr uint64_t chunk = 1ULL << 30;
  executor.expertChunks = {chunk};
  executor.releasedExpertChunks = {chunk, chunk, chunk};
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  constexpr uint64_t limit = 40ULL << 30;
  // Half the chunk short of the recovery margin, which the empty extents
  // the idle engine returns do not cover.
  std::optional<uint64_t> available = hostReserve + kHostRecoveryMarginBytes + chunk / 2;
  MemoryGovernor governor(backend, limit, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  MemoryControl control(governor, backend, loop);
  const auto pass = [&](double elapsed = 0.0) {
    fixture.monotonic += elapsed;
    require(!control.run(MemoryPressure::Normal), "a pass waited for a transfer");
    return executor.expertChunks.size();
  };
  require(pass() == 1 && executor.expertGrowthAttempts == 0,
          "the store grew without the recovery margin to spare beyond its chunk");
  available = hostReserve + (16ULL << 30);
  require(pass() == 2, "a pass with memory to spare did not take one chunk back");

  // A request waiting for memory holds the growth back.
  executor.beginGrowthBlocked = [] { return true; };
  executor.beginAllocationFailure = metal::AllocationFailure::HostPressure;
  require(loop.receive(protocol::peer::serialize(request(1))) && !loop.tick() &&
              loop.resourceWaitSnapshot().memory == 1,
          "the request did not wait for memory");
  require(pass() == 2, "the store grew while a request waited for memory");
  executor.beginGrowthBlocked = {};
  fixture.monotonic += 2 * engine::kResourceRetryBackoffMilliseconds;
  runUntilIdle(loop);

  // Beside a resident lane only room the engine's limit has free.
  auto running = request(2, 900);
  for (uint32_t &token : running.promptTokens)
    token += 200;
  fixture.executor.decodeFinishes = false;
  require(loop.receive(protocol::peer::serialize(running)), "the long request failed");
  for (uint32_t step = 0; step < 8; ++step)
    static_cast<void>(loop.tick());
  settleCommand(loop);
  require(fixture.executor.requests.contains(2) && fixture.executor.requests.at(2).resident,
          "the long request did not decode");
  test::metalStatistics().allocatedBytes = limit - chunk / 2;
  const uint32_t attempts = executor.expertGrowthAttempts;
  require(pass() == 2 && executor.expertGrowthAttempts == attempts,
          "growth beside a resident lane asked for room the engine's limit lacked");
  test::metalStatistics().allocatedBytes = limit - 2 * chunk;
  require(pass() == 3, "growth beside a resident lane did not take free room");
  test::metalStatistics().allocatedBytes = 0;
  fixture.executor.decodeFinishes = true;
  runUntilIdle(loop);

  // A host short of the warning margin takes a chunk back; the store grows
  // again only once the cool-down after it has passed.
  available = hostReserve + kHostWarningMarginBytes / 2;
  require(pass() == 2 && loop.expertReleases() == 1,
          "a short host did not take a chunk of the store");
  available = hostReserve + (16ULL << 30);
  require(pass(1000.0) == 2 && pass(kExpertGrowthCooldownMilliseconds - 1001.0) == 2,
          "the store grew back within the cool-down after a chunk went");
  require(pass(1.0) == 3, "the store did not grow back after the cool-down");

  // Released weights hold the growth back, until their restore is over.
  executor.releasedExpertChunks.push_back(chunk);
  executor.expertChunks.pop_back();
  require(!releaseAnswer(fixture, 9).restoring && fixture.weights.released(),
          "the weights were not released");
  require(pass() == 2, "the store grew while the weights were released");
  require(loop.receive(protocol::peer::serialize(request(3))) && loop.tick() &&
              fixture.weights.released() && pass() == 2,
          "the store grew while the weights were being restored");
  runUntilIdle(loop);
  require(!fixture.weights.released() && pass() == 3,
          "the store did not grow once the weights were back");
}

// A conversation that finishes leaves its replay point, and a prompt of its
// own shares no prefix with another's.
void finishConversation(LoopFixture &fixture, uint64_t id) {
  auto input = request(id);
  for (uint32_t &token : input.promptTokens)
    token += static_cast<uint32_t>(100 * id);
  require(fixture.loop.receive(protocol::peer::serialize(input)), "a conversation failed");
  runUntilIdle(fixture.loop);
}

// The pool of the exchange tests: extents of two pages, one allocated up
// front as the runway, and chunks of the expert store of two extents' bytes.
constexpr PoolShape kExchangePool{.pages = 64, .extentPages = 2, .runwayPages = 2};
constexpr uint64_t kExchangeExtentBytes = 2 * 4096;
constexpr uint64_t kExchangeChunkBytes = 2 * kExchangeExtentBytes;

// With no request in the engine, a control pass whose host's headroom lacks
// a chunk of the expert store beyond the recovery margin exchanges cache for
// it: the engine returns the cache nothing in use holds to the system,
// releasing the extents it empties, until what it returned covers the
// chunk, and keeps the resume point; the governor's growth admission counts
// those bytes as the host's already and admits the chunk, which the host's
// headroom alone does not. One chunk comes back per pass. Without such
// cache none does.
void testIdleControlPassExchangesCacheForTheExpertStore() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config, kExchangePool);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  const engine::Cache &resources = fixture.cache;
  const KvPool &pool = fixture.pool;
  loop.announceReady();
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  constexpr uint64_t chunk = kExchangeChunkBytes;
  // Between the warning margin and the recovery margin.
  const std::optional<uint64_t> available =
      hostReserve + kHostWarningMarginBytes + kHostWarningMarginBytes / 2;
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  MemoryControl control(governor, backend, loop);
  executor.expertAdmission = governor.growthAdmission();
  executor.expertChunks = {chunk};
  executor.releasedExpertChunks = {chunk, chunk};
  const auto pass = [&] {
    require(!control.run(MemoryPressure::Normal), "a pass waited for a transfer");
    return executor.expertChunks.size();
  };
  require(pass() == 1 && executor.expertGrowthAttempts == 0 &&
              pool.snapshot().allocatedBytes == kExchangeExtentBytes,
          "the store grew with no cache to return for it, or the runway extent went");

  for (uint64_t id = 1; id <= 6; ++id)
    finishConversation(fixture, id);
  const auto before = resources.snapshot();
  const uint64_t buffers = executor.reclaimedIdleStateBytes;
  require(pass() == 2 && executor.releasedExpertChunks.size() == 1,
          "an idle pass did not exchange cache for one chunk of the store");
  const auto after = resources.snapshot();
  const uint64_t extents = before.pool.allocatedBytes - after.pool.allocatedBytes;
  require(extents + executor.reclaimedIdleStateBytes - buffers >= chunk && extents <= chunk &&
              after.pool.extentReleases > before.pool.extentReleases &&
              after.stateCache.entries < before.stateCache.entries,
          "the exchange did not release about a chunk of cache to the system");
  require(!governor.growthAdmission()(chunk, [] {}),
          "the host's headroom alone admitted the chunk, or the exchange's credit outlived it");
  require(pass() == 3 && pass() == 3, "the store did not grow a chunk per pass up to its cap");
  const uint64_t releases = pool.snapshot().extentReleases;
  require(pass() == 3 && pool.snapshot().extentReleases == releases,
          "a store at its cap took cache");
  const uint64_t hits = loop.snapshot().cacheHits;
  finishConversation(fixture, 6);
  require(loop.snapshot().cacheHits == hits + 1,
          "the newest conversation did not resume from the state the exchange kept");
}

// The exchange waits where the store's growth does: beside a resident
// request, which takes only the host's headroom beyond the margin, while a
// request waits for memory, within the cool-down after a chunk went, and
// under macOS's pressure, whose passes give cache back but take no chunk
// back. None returns cache for the store or asks for a chunk.
void testExpertExchangeWaitsWhereGrowthDoes() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config, kExchangePool);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  const engine::Cache &resources = fixture.cache;
  const KvPool &pool = fixture.pool;
  loop.announceReady();
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  constexpr uint64_t chunk = kExchangeChunkBytes;
  // The host lacks the whole chunk beyond the recovery margin.
  const uint64_t between = hostReserve + kHostWarningMarginBytes + kHostWarningMarginBytes / 2;
  std::optional<uint64_t> available = between;
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  MemoryControl control(governor, backend, loop);
  executor.expertAdmission = governor.growthAdmission();
  executor.expertChunks = {chunk};
  executor.releasedExpertChunks = {chunk, chunk};
  for (uint64_t id = 1; id <= 6; ++id)
    finishConversation(fixture, id);
  // A pass that neither took a chunk back nor asked for one, and, unless
  // its pressure gives cache back, returned none.
  const auto waits = [&](MemoryPressure pressure = MemoryPressure::Normal) {
    const size_t chunks = executor.expertChunks.size();
    const uint32_t attempts = executor.expertGrowthAttempts;
    const uint64_t releases = pool.snapshot().extentReleases;
    require(!control.run(pressure), "a pass waited for a transfer");
    return executor.expertChunks.size() <= chunks && executor.expertGrowthAttempts == attempts &&
           (pressure != MemoryPressure::Normal || pool.snapshot().extentReleases == releases);
  };

  // Beside a resident lane.
  auto running = request(20, 900);
  for (uint32_t &token : running.promptTokens)
    token += 2000;
  executor.decodeFinishes = false;
  require(loop.receive(protocol::peer::serialize(running)), "the long request failed");
  for (uint32_t step = 0; step < 8; ++step)
    static_cast<void>(loop.tick());
  settleCommand(loop);
  require(executor.requests.contains(20) && executor.requests.at(20).resident,
          "the long request did not decode");
  require(waits(), "the exchange took cache beside a resident lane");
  executor.decodeFinishes = true;
  runUntilIdle(loop);

  // While a request waits for memory: the host has the recovery margin it
  // waits for, beside half a chunk.
  available = hostReserve + kHostRecoveryMarginBytes + chunk / 2;
  executor.beginGrowthBlocked = [] { return true; };
  executor.beginAllocationFailure = metal::AllocationFailure::HostPressure;
  require(loop.receive(protocol::peer::serialize(request(21))) && !loop.tick() &&
              loop.resourceWaitSnapshot().memory == 1,
          "the request did not wait for memory");
  require(waits(), "the exchange took cache while a request waited for memory");
  executor.beginGrowthBlocked = {};
  fixture.monotonic += 2 * engine::kResourceRetryBackoffMilliseconds;
  runUntilIdle(loop);

  // Within the cool-down after a short host took the store's chunks.
  available = hostReserve + kHostWarningMarginBytes / 2;
  require(!control.run(MemoryPressure::Normal) && executor.expertChunks.empty() &&
              loop.expertReleases() != 0,
          "a short host did not take the store's chunks");
  for (uint64_t id = 7; id <= 12; ++id)
    finishConversation(fixture, id);
  available = hostReserve + kHostRecoveryMarginBytes + chunk / 2;
  fixture.monotonic += kExpertGrowthCooldownMilliseconds - 1.0;
  require(waits(), "the exchange took cache within the cool-down");
  fixture.monotonic += 1.0;
  require(!control.run(MemoryPressure::Normal) && executor.expertChunks.size() == 1,
          "the exchange did not take a chunk back after the cool-down");

  // Under macOS's warning and critical pressure.
  available = between;
  require(waits(MemoryPressure::Warning) && resources.snapshot().stateCache.entries != 0,
          "the store took a chunk back under macOS's warning");
  require(waits(MemoryPressure::Critical), "the store took a chunk back under critical pressure");
}

// An idle pass whose cache cannot cover what the host lacks of a chunk of the
// expert store leaves that cache in place: the idle buffers beyond a lane's
// and every entry nothing in use holds return less than the chunk, so the
// chunk stays out, and an exchange that buys no chunk evicts nothing.
void testExpertExchangeKeepsCacheThatCannotCoverTheChunk() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config, kExchangePool);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  const engine::Cache &resources = fixture.cache;
  loop.announceReady();
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  // More than the whole pool and every cached state's buffers.
  constexpr uint64_t chunk = 1ULL << 30;
  // The host lacks the whole chunk beyond the recovery margin.
  const std::optional<uint64_t> available =
      hostReserve + kHostWarningMarginBytes + kHostWarningMarginBytes / 2;
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  MemoryControl control(governor, backend, loop);
  executor.expertAdmission = governor.growthAdmission();
  executor.expertChunks = {chunk};
  executor.releasedExpertChunks = {chunk};
  for (uint64_t id = 1; id <= 6; ++id)
    finishConversation(fixture, id);
  const auto before = resources.snapshot();
  require(before.stateCache.entries > 1, "the fixture kept no cache beside the resume point");
  const uint32_t attempts = executor.expertGrowthAttempts;
  require(!control.run(MemoryPressure::Normal), "a pass waited for a transfer");
  require(executor.expertChunks.size() == 1 && executor.expertGrowthAttempts == attempts,
          "the store asked for a chunk the cache could not cover");
  const auto after = resources.snapshot();
  require(after.stateCache.entries == before.stateCache.entries &&
              after.pool.allocatedBytes == before.pool.allocatedBytes &&
              after.pool.extentReleases == before.pool.extentReleases,
          "an exchange that bought no chunk evicted cache");
}

// The chunk takes from the engine only the room its limit has free. With no
// request in the engine the pass exchanges cache for what the limit lacks of
// it, as for what the host lacks, and the extents the exchange releases make
// the room. Where both lack some of the chunk, what the exchange returns adds
// to both, so it returns the larger lack alone. Without cache that covers
// the lack the pass neither takes cache nor asks for the chunk.
void testExpertExchangeCoversTheEngineLimit() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config, kExchangePool);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  const engine::Cache &resources = fixture.cache;
  loop.announceReady();
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  constexpr uint64_t limit = 40ULL << 30;
  constexpr uint64_t chunk = kExchangeChunkBytes;
  // More than the whole pool and every cached state's buffers.
  constexpr uint64_t large = 1ULL << 30;
  // The host has the chunk and more to spare.
  constexpr uint64_t ample = hostReserve + (16ULL << 30);
  std::optional<uint64_t> available = ample;
  MemoryGovernor governor(backend, limit, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  MemoryControl control(governor, backend, loop);
  executor.expertAdmission = governor.growthAdmission();
  executor.expertChunks = {chunk};
  executor.releasedExpertChunks = {large, chunk, chunk};
  // The pool's extents are the backend's memory, which the governor charges.
  fixture.storage.released = [] { test::metalStatistics().allocatedBytes -= kExchangeExtentBytes; };
  // A pass while the engine's limit lacks `lacked` of the next chunk: whether
  // it took the chunk back, and how many extents the cache released for it.
  const auto pass = [&](uint64_t lacked) {
    test::metalStatistics().allocatedBytes = limit - (executor.expertGrowthBytes() - lacked);
    const size_t chunks = executor.expertChunks.size();
    const uint64_t releases = resources.snapshot().pool.extentReleases;
    require(!control.run(MemoryPressure::Normal), "a pass waited for a transfer");
    return std::pair{executor.expertChunks.size() > chunks,
                     resources.snapshot().pool.extentReleases - releases};
  };
  uint32_t attempts = executor.expertGrowthAttempts;
  require(pass(kExchangeExtentBytes) == std::pair{false, uint64_t{0}} &&
              executor.expertGrowthAttempts == attempts,
          "the store asked for a chunk the engine's limit lacked with no cache to make room");

  for (uint64_t id = 1; id <= 6; ++id)
    finishConversation(fixture, id);
  const auto [grown, released] = pass(kExchangeExtentBytes);
  require(grown && released != 0,
          "an idle pass did not exchange cache for the room the engine's limit lacked");
  const uint64_t hits = loop.snapshot().cacheHits;
  finishConversation(fixture, 6);
  require(loop.snapshot().cacheHits == hits + 1,
          "the newest conversation did not resume from the state the exchange kept");

  // The host lacks one extent of the chunk beyond the recovery margin, the
  // engine's limit the whole chunk, two extents.
  available = hostReserve + kHostRecoveryMarginBytes + chunk - kExchangeExtentBytes;
  require(pass(chunk) == std::pair{true, uint64_t{2}},
          "an exchange did not return the larger of what the host and the engine's limit lacked");
  available = ample;

  const uint32_t entries = resources.snapshot().stateCache.entries;
  attempts = executor.expertGrowthAttempts;
  require(pass(large) == std::pair{false, uint64_t{0}} && executor.expertGrowthAttempts == attempts &&
              resources.snapshot().stateCache.entries == entries,
          "an exchange that could not cover what the engine's limit lacked took cache");
}

// An exchange whose chunk is refused after all, as by memory another process
// took meanwhile, leaves what it returned with the system and takes no more
// than the chunk lacked: the next pass's sample shows those bytes, and the
// chunk comes back from them without taking cache again.
void testRefusedExchangeLeavesItsBytesToTheNextPass() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config, kExchangePool);
  engine::NativeRuntime &loop = fixture.loop;
  Executor &executor = fixture.executor;
  const engine::Cache &resources = fixture.cache;
  loop.announceReady();
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  constexpr uint64_t chunk = kExchangeChunkBytes;
  // The host has the recovery margin and nothing beyond it: it lacks the
  // whole chunk.
  std::optional<uint64_t> available = hostReserve + kHostRecoveryMarginBytes;
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [&available] { return hostMemory(available); }, 0);
  MemoryControl control(governor, backend, loop);
  executor.expertAdmission = governor.growthAdmission();
  executor.expertChunks = {chunk};
  executor.releasedExpertChunks = {chunk};
  // The host refuses the first chunk asked for and admits every later one.
  bool askedBefore = false;
  executor.expertGrowthRoom = [&askedBefore] { return std::exchange(askedBefore, true); };
  executor.expertGrowthRefusal = metal::AllocationFailure::HostPressure;
  for (uint64_t id = 1; id <= 6; ++id)
    finishConversation(fixture, id);

  const auto before = resources.snapshot();
  const uint64_t buffers = executor.reclaimedIdleStateBytes;
  const uint32_t attempts = executor.expertGrowthAttempts;
  require(!control.run(MemoryPressure::Normal), "a pass waited for a transfer");
  const auto after = resources.snapshot();
  const uint64_t returned = before.pool.allocatedBytes - after.pool.allocatedBytes +
                            executor.reclaimedIdleStateBytes - buffers;
  require(executor.expertChunks.size() == 1 && executor.expertGrowthAttempts == attempts + 1 &&
              returned >= chunk && after.stateCache.entries > 1,
          "a refused exchange did not return the chunk's bytes alone");

  available = *available + returned;
  require(!control.run(MemoryPressure::Normal) && executor.expertChunks.size() == 2 &&
              resources.snapshot().pool.extentReleases == after.pool.extentReleases &&
              resources.snapshot().stateCache.entries == after.stateCache.entries,
          "the next pass took cache again for the bytes the refused exchange returned");
}

// The store's chunks above its floor are the model's (Executor::
// expertChunks): a release gives them back with the floor, and a restore
// takes the floor back under the admission of what is needed (`floors`
// counts those), then each chunk while the optional growth's grants it.
struct StoreMemory final : model::WeightMemory {
  explicit StoreMemory(Executor *&model) : model(model) {}
  [[nodiscard]] bool released() const noexcept override { return out; }
  void release() override {
    while (!model->expertChunks.empty()) {
      model->releasedExpertChunks.push_back(model->expertChunks.back());
      model->expertChunks.pop_back();
    }
    out = true;
  }
  bool restore(const metal::AllocationAdmission &admit,
               const metal::AllocationAdmission &optional) override {
    if (const metal::AllocationResult admitted = admit(kFloorBytes, [] {}); !admitted)
      throw metal::MetalAllocationError("the store's floor was refused", admitted.failure);
    ++floors;
    while (!model->releasedExpertChunks.empty() &&
           optional(model->releasedExpertChunks.back(), [] {})) {
      model->expertChunks.push_back(model->releasedExpertChunks.back());
      model->releasedExpertChunks.pop_back();
    }
    out = false;
    return true;
  }
  static constexpr uint64_t kFloorBytes = 1ULL << 28;
  Executor *&model;
  bool out = false;
  uint32_t floors = 0;
};

// The expert store's idle restore takes its floor back as memory the
// request waiting needs, and each chunk above it only while the optional
// growth's admission grants it (model::ExpertStore::restore): a chunk refused
// stays released, the request waiting runs at once, and the control pass
// grows the store back toward its cap, a chunk per pass, once memory is
// ample.
void testShrunkRestoreGrowsBackAfterTheRequest() {
  Executor *model = nullptr;
  StoreMemory store(model);
  // Admission grants the first chunk of each restore and refuses the rest.
  uint32_t granted = 0;
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.weights = &store;
  config.growthAdmission = [&](uint64_t, const std::function<void()> &allocate) {
    if (granted++)
      return metal::AllocationResult{metal::AllocationFailure::EngineBudget};
    allocate();
    return metal::AllocationResult{};
  };
  LoopFixture fixture(config);
  model = &fixture.executor;
  engine::NativeRuntime &loop = fixture.loop;
  constexpr uint64_t chunk = 1ULL << 30;
  fixture.executor.expertChunks = {chunk, chunk, chunk};
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t hostReserve = 2ULL << 30;
  MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                          [] { return hostMemory(hostReserve + (16ULL << 30)); }, 0);
  MemoryControl control(governor, backend, loop);
  loop.announceReady();
  require(!releaseAnswer(fixture, 1).restoring && store.released() &&
              fixture.executor.releasedExpertChunks.size() == 3,
          "the store was not released");
  require(loop.receive(protocol::peer::serialize(request(1))), "the request failed");
  runUntilIdle(loop);
  require(loop.snapshot().completed == 1 && loop.resourceWaitSnapshot().memory == 0 &&
              store.floors == 1 && fixture.executor.expertChunks.size() == 1,
          "a refused chunk above the floor held the restore back");
  for (size_t chunks = 2; chunks <= 3; ++chunks) {
    require(!control.run(MemoryPressure::Normal) && fixture.executor.expertChunks.size() == chunks,
            "the control pass did not grow the restored store a chunk per pass");
  }
}

// Under the governor's admissions (Bootstrap's), the restore takes the
// chunks above the floor back only while the host has each and the recovery
// margin to spare, under no pressure, whatever the serving mark a request
// waiting sets: on a host short of that only the floor comes back, and the
// request runs; on an ample host the store comes back at its cap.
void testRestoreTakesChunksOnlyFromAHostWithRoomToSpare() {
  constexpr uint64_t chunk = 1ULL << 30;
  constexpr uint64_t hostReserve = 2ULL << 30;
  for (const bool ample : {false, true}) {
    Executor *model = nullptr;
    StoreMemory store(model);
    test::metalStatistics() = {};
    metal::MetalBackend backend("unused");
    // The floor fits beside the warning margin; a chunk does not beside the
    // recovery margin unless the host is ample.
    const uint64_t spare = ample ? 3 * chunk + kHostRecoveryMarginBytes
                                 : chunk + kHostRecoveryMarginBytes - 4096;
    MemoryGovernor governor(backend, 40ULL << 30, hostReserve, hostReserve,
                            [&] { return hostMemory(hostReserve + spare); }, 0);
    engine::NativeLoopConfig config;
    config.engine.maxContext = 1024;
    config.engine.serving = [&governor](bool serving) { return governor.setServing(serving); };
    config.weights = &store;
    config.weightAdmission = governor.allocationAdmission();
    config.growthAdmission = governor.growthAdmission();
    LoopFixture fixture(config);
    model = &fixture.executor;
    fixture.executor.expertChunks = {chunk, chunk, chunk};
    fixture.loop.announceReady();
    require(!releaseAnswer(fixture, 1).restoring && store.released(), "the store was not released");
    require(fixture.loop.receive(protocol::peer::serialize(request(1))), "the request failed");
    runUntilIdle(fixture.loop);
    require(fixture.loop.snapshot().completed == 1 && store.floors == 1 &&
                fixture.executor.expertChunks.size() == (ample ? 3U : 0U),
            ample ? "an ample host did not restore the store at its cap"
                  : "a host short of a chunk and the recovery margin took one back in a restore");
  }
}

// ---------------------------------------------------------------------------
//
// The admission boundary (Gate 1's structure, FR-005/FR-009): the loop holds
// the gate's mutex from the closed check through `Engine::submit`, so closure
// and submission race on the real handover. These cases re-home the historical
// Battery gate cases (`testLifecycleAdmissionGateIsFinalNativeBoundary` and
// `testAdmissionCloseRejectsLaterRequestWhileAdmittedRestoreDrains`) onto the
// current request path and fixtures; the historical `destroyEngine`/`hasEngine`
// refusals, and `testCancelledRestoreRetainsEngineUntilTicketDrains`, belong to
// the drain barriers and the published-Engine seams (T016/T024) and are not
// claimed here: nothing below proves a request drain, IO quiescence or a
// callback retirement.

// How the loop answered one request id: its own frames, and whether the Engine
// ever started or finished it.
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

// The historical case: the gate is the last thing the native loop decides about
// a request frame, and around it the loop serves exactly as it did before the
// gate existed.
void testAdmissionGateIsFinalNativeBoundary() {
  std::vector<bool> keepAwake;
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  config.holdingRequests = [&](bool holding) { keepAwake.push_back(holding); };
  LoopFixture fixture(config);
  engine::NativeRuntime &loop = fixture.loop;
  const auto send = [&](uint64_t id) {
    require(loop.receive(protocol::peer::serialize(request(id))),
            "an admission frame closed the protocol connection");
  };
  loop.announceReady();
  require(loop.admissionOpen(), "normal startup closed inference admission");

  loop.closeAdmission();
  require(!loop.admissionOpen(), "closing admission did not take effect");
  send(91);
  require(loop.snapshot().submitted == 0 && idle(loop),
          "a closed admission gate admitted inference work");
  const auto refused = answeredFor(fixture.events(), 91);
  require(refused.refused == 1 && refused.otherErrors == 0 &&
              refused.starts == 0 && refused.terminals == 0,
          "the closed gate did not answer the request with one unavailable frame");
  require(loop.engineHealthy() && !loop.connectionMustClose() && keepAwake.empty() &&
              fixture.metrics.snapshot().prefillInputTokens == 0 &&
              fixture.metrics.snapshot().ttftSamples == 0,
          "an admission refusal disturbed the loop, its keep-awake or its metrics");

  loop.openAdmission();
  require(loop.admissionOpen(), "an explicit reopen did not take effect");
  send(92);
  runUntilIdle(loop);
  require(loop.snapshot().submitted == 1 && loop.snapshot().completed == 1 &&
              answeredFor(fixture.events(), 92).starts == 1 &&
              answeredFor(fixture.events(), 92).terminals == 1,
          "an open gate did not serve the request normally");
  require(keepAwake == std::vector<bool>{true, false},
          "the served request lost its keep-awake transitions");
  loop.closeAdmission();
  send(93);
  require(loop.snapshot().submitted == 1 && loop.snapshot().completed == 1 &&
              answeredFor(fixture.events(), 93).refused == 1 &&
              answeredFor(fixture.events(), 93).starts == 0 &&
              answeredFor(fixture.events(), 93).terminals == 0 &&
              keepAwake == std::vector<bool>{true, false},
          "a closed gate allowed a later frame through");
}

// A closure that wins before submission starts nothing on the loop's behalf:
// no Engine admission, no weight restore, no metrics, no keep-awake edge.
void testCloseBeforeSubmitStartsNothing() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(request(1))), "the warm request failed");
  runUntilIdle(loop);
  require(releaseAnswer(fixture, 11).released, "the release did not give the weights back");

  const auto counts = loop.snapshot();
  const auto weightsBefore = loop.weightsSnapshot();
  const auto metricsBefore = fixture.metrics.snapshot();
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
  const auto metrics = fixture.metrics.snapshot();
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

// A submission that wins the race keeps its request owned: closure afterwards
// refuses later frames, never takes the admitted request's completion away,
// and an explicit reopen resumes serving.
void testSubmitBeforeCloseKeepsTheAdmittedRequest() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
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

// A closure and a submission racing each other have exactly one winner: the
// loser waits on the same mutex the submission runs under.
void testCloseAndSubmitHaveOneWinner() {
  for (uint32_t round = 0; round < 32; ++round) {
    LoopFixture fixture;
    engine::NativeRuntime &loop = fixture.loop;
    loop.announceReady();
    const std::vector<uint8_t> frame = protocol::peer::serialize(request(1));
    std::atomic<bool> go(false);
    // An exception escaping a thread would end the process: the frame's own
    // answer is checked on the thread that owns the fixture.
    std::atomic<bool> framingKept(false);
    std::thread submit([&] {
      while (!go.load(std::memory_order_acquire))
        std::this_thread::yield();
      framingKept.store(loop.receive(frame), std::memory_order_release);
    });
    std::thread closer([&] {
      while (!go.load(std::memory_order_acquire))
        std::this_thread::yield();
      loop.closeAdmission();
    });
    // Both are released together; which one takes the mutex first is left to
    // the race, and no assertion below depends on how long either waits.
    go.store(true, std::memory_order_release);
    submit.join();
    closer.join();
    require(framingKept.load(), "the racing request frame closed the connection");

    const auto counts = loop.snapshot();
    const auto answered = answeredFor(fixture.events(), 1);
    const bool submitted = counts.submitted == 1;
    const bool refused = answered.refused == 1;
    require(submitted != refused && answered.otherErrors == 0 &&
                counts.completed + counts.cancelled + counts.failed == 0 &&
                loop.engineHealthy() && !loop.connectionMustClose(),
            "the close/submit race showed two winners, or none");
    if (submitted) {
      // The submission won: the request it admitted stays owned and runs out.
      runUntilIdle(loop);
      require(loop.snapshot().completed + loop.snapshot().cancelled +
                  loop.snapshot().failed == 1,
              "the winning request did not reach its terminal boundary");
    } else {
      require(idle(loop), "the losing submission left work behind");
    }
    // Closure is closed at the join either way, and it stays closed.
    require(loop.receive(protocol::peer::serialize(request(2))) &&
                loop.snapshot().submitted == counts.submitted &&
                answeredFor(fixture.events(), 2).refused == 1,
            "the race left admission open");
  }
}

// What the client read is an observation of a moment, not a capability it keeps
// across it: a request queued on `inference_ready=true` still meets the native
// gate once closure has landed.
void testStaleReadyObservationCannotBypassTheGate() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{11})) &&
              answeredStatus(fixture, 11),
          "the client's readiness read failed");
  const bool clientObservedReady = loop.admissionOpen();
  require(clientObservedReady, "the client did not observe admission open");

  loop.closeAdmission();
  // The request the client queued on that observation, sent after closure.
  require(loop.receive(protocol::peer::serialize(request(7))),
          "the queued request closed the connection");
  const auto answered = answeredFor(fixture.events(), 7);
  require(loop.snapshot().submitted == 0 && answered.refused == 1 &&
              answered.starts == 0 && answered.terminals == 0 &&
              loop.engineHealthy() && !loop.connectionMustClose(),
          "a stale ready observation bypassed the native gate");

  // The status read that follows closure answers, and reopens nothing.
  require(loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{12})) &&
              answeredStatus(fixture, 12) && !loop.admissionOpen(),
          "a status read reopened admission");
  require(loop.receive(protocol::peer::serialize(request(8))) &&
              loop.snapshot().submitted == 0 &&
              answeredFor(fixture.events(), 8).refused == 1,
          "the read after closure reopened admission");
}

// Admission closed is not the connection closed, nor the control path closed:
// status, control work, mask replies and cancellation keep working, and only
// request frames are refused.
void testControlAndCancellationSurviveClosedAdmission() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  const auto commandReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(801))) && loop.tick(),
          "the admitted request did not start");
  loop.closeAdmission();

  require(loop.receive(protocol::peer::serialize(protocol::StatusRequestFrame{12})) &&
              answeredStatus(fixture, 12),
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

// Only the loop's own operation opens admission again: reads, answered frames,
// a completed request, a weights restore and an idle release reopen nothing.
void testReopenIsExplicit() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
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
              answeredStatus(fixture, 13), "a status read failed");
  static_cast<void>(loop.snapshot());
  static_cast<void>(loop.statusSnapshot());
  static_cast<void>(loop.weightsSnapshot());
  static_cast<void>(loop.resourceWaitSnapshot());
  static_cast<void>(loop.millisecondsUntilNextWakeup());
  loop.releaseIdleWeights();
  loop.openAdmission();
  loop.closeAdmission();
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

// ---- T010 correction: the injectable clocks are callbacks, and they run
// outside the gate's mutex. A callback that queries or closes admission
// returns instead of reentering the nonrecursive lock; a closure landing
// inside the clock is seen by that same frame's own gate check.
// `alarm` turns a reentering lock into a failed run, never a hang.

// A clock pair that reads the gate through a loop the config cannot name yet.
struct GateProbe final {
  engine::NativeRuntime *loop = nullptr;
  double now = 100.0;
  uint64_t gateQueries = 0;
};

void testClockCallbacksQueryAdmissionWithoutReenteringTheGate() {
  alarm(10);
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
  LoopFixture fixture(config, {}, {}, metal::kResidencyKeepAliveSeconds, true);
  probe.loop = &fixture.loop;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
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
  alarm(0);
}

// A closure that lands inside an injected clock is already visible to that
// request's own gate check: the clock runs before the mutex is taken, so the
// close wins the whole frame, and later submissions stay refused.
void testCloseInsideTheClockRefusesThatRequest() {
  alarm(10);
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
  LoopFixture fixture(config, {}, {}, metal::kResidencyKeepAliveSeconds, true);
  probe.loop = &fixture.loop;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
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
  alarm(0);
}

// The close thread is released by the submission's own clock read: it starts
// at the last moment before that submission reaches the gate. Either side may
// legally take the mutex first, and exactly one of them wins every round; a
// submission that wins keeps its request owned to its normal terminal event.
void testCloseStartedInsideTheClockRacesTheSubmission() {
  for (uint32_t round = 0; round < 16; ++round) {
    struct Racer final {
      engine::NativeRuntime *loop = nullptr;
      bool armed = false;
      bool launched = false;
      std::thread closer;
    } probe;
    engine::NativeLoopConfig config;
    config.engine.maxContext = 1024;
    config.unixMicros = [] { return uint64_t{1'000'000}; };
    config.monotonicMilliseconds = [&probe] {
      if (probe.loop && probe.armed && !probe.launched) {
        probe.launched = true;
        probe.closer = std::thread([runtime = probe.loop] { runtime->closeAdmission(); });
      }
      return 100.0;
    };
    LoopFixture fixture(config, {}, {}, metal::kResidencyKeepAliveSeconds, true);
    probe.loop = &fixture.loop;
    engine::NativeRuntime &loop = fixture.loop;
    loop.announceReady();
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

// ---- T011 (U-04): the poll bound folds every wake source the loop has into
// the earliest present absolute deadline on the loop's clock.

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

// The Engine's own scheduling keeps driving the same bound it had alone:
// none when idle, the health wake while a command is in flight, none again
// once it drains. (A non-persistent Cache contributes no persistence source.)
void testEngineSchedulingStillDrivesTheBound() {
  LoopFixture fixture;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
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

// A loop whose Cache has a persistent tier and a test write budget: its
// requests publish restore points into the retained queue, and that queue's
// deadlines are the runtime's poll sources with no engine source present.
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
  double monotonic = 100.0;
  RuntimeMetrics metrics;
  Weights weights;
  engine::NativeRuntime loop{
      {.engine = test::engineConfig(),
       .metrics = &metrics,
       .weights = &weights,
       .weightAdmission = test::admitAll,
       .growthAdmission = test::admitAll,
       .unixMicros = [] { return uint64_t{1'000'000}; },
       .monotonicMilliseconds = [this] { return monotonic; }},
      metal::kResidencyKeepAliveSeconds, cache, persistence, executor,
      [this](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return test::readyStatusJson(); }, protocol::ProtocolLimits{}};

  PersistentLoopFixture() {
    storage.commandInFlight = [this] { return loop.commandInFlight(); };
    tier.transferLimit = 64;
    tier.capacity = 128;
    executor.prefillAnchor = true;
    executor.keptTier = offload;
  }
};

// Publishes one 2060-token replay point and drains the request that made it.
void queueOneReplayPoint(PersistentLoopFixture &fixture) {
  fixture.loop.announceReady();
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

// With the request finished and no command in flight, the Engine has no timed
// event of its own: the retained queue's next due point alone is the bound,
// stays representable from the queue itself, and an already-due point wakes
// the transport at once.
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

// A step the write budget holds back has its next budget admission as the
// loop's bound: the runtime surfaces the stalled queue's own deadline rather
// than inventing a poll cadence.
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
  require(admission && bound && std::abs(*admission - test::WriteBudget::kRefillMilliseconds) < 1.0,
          "the stalled queue did not report the next budget admission");
  require(*bound == *admission - fixture.monotonic && *bound > 0.0,
          "the loop's bound is not the stalled queue's next budget admission");
  // Once the budget admits again, only the in-flight write waits: its
  // completion wakes the loop, so the poll is unbounded rather than busy.
  fixture.budget.refill();
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

// [T019 / Gate 1, FR-008, FR-009] The four witnesses the native loop supplies
// to one owner lease: its own admission gate, its request-side drain (T016),
// the Cache's retained IO (T018) and the Engine's callbacks and descendants
// (T017). Every refusal below names a category the owner itself observes at
// work while the other three are clean, so neither `Engine::idle()` nor a
// completed GPU ticket stands in for a witness, and nothing is a flag a caller
// could clear. The owner's preparation closes admission first, and a refusal
// leaves its Owner interval and the closed gate exactly as they were.
//
// The two mutation surfaces of the domain these tests lease: a backend built
// with no device, and a governor whose mutating operations demand — and record
// — the lease's current holder thread.
struct DomainSurfaces final {
  static constexpr uint64_t kLimitBytes = 40ULL << 30;
  static constexpr uint64_t kReserveBytes = 2ULL << 30;
  metal::MetalBackend backend{"unused"};
  std::optional<uint64_t> available{16ULL << 30};
  MemoryGovernor governor;
  // The Owner interval of this domain, bound to the test's thread.
  ResourceDomainLease authority{ResourceDomainLease::acquireForOwner()};

  DomainSurfaces()
      : governor{backend, kLimitBytes, kReserveBytes, kReserveBytes,
                 [this] { return hostMemory(available); }, 0} {
    authority.attach(backend);
    authority.attach(governor);
  }
};

// A lease with a category nobody supplied, and one whose gate was reopened
// after its owner closed it: both mint nothing, and an emptied slot counts as
// absent rather than as passing.
void testHandoffNeedsEveryWitnessAndAnOpenGateRefuses() {
  LoopFixture fixture;
  DomainSurfaces domain;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  require(idle(loop), "the graph was not at rest before its handoff was asked for");
  require(!domain.authority.obtainQuiescence().has_value(),
          "an owner lease with an unwitnessed category minted a handoff");
  // The preparation closes admission at the native boundary before it looks,
  // so its own look is over a gate it has already closed.
  require(loop.prepareResourceHandoff(domain.authority).has_value(),
          "a fully retired graph minted no proof at its first safe point");
  require(!loop.admissionOpen(), "the preparation left admission open");
  // The gate witness is evidence about the real gate, not a constant: reopen
  // it and those same four slots mint nothing.
  loop.openAdmission();
  require(loop.admissionOpen() && !domain.authority.obtainQuiescence().has_value(),
          "a reopened admission gate still minted a handoff");
  // An emptied category is an absent one.
  loop.closeAdmission();
  domain.authority.setRetainedIoWitness({});
  require(!domain.authority.obtainQuiescence().has_value(),
          "an empty retained-IO slot minted a handoff");
  require(domain.authority.holder() == ResourceDomainAuthority::Holder::Owner,
          "a refused mint moved the owner interval");
}

// A request the loop admitted but has not finished, and a command parked in the
// model: the drain's witness refuses, the owner keeps its authority and its
// closed gate, and the requests the Engine holds stay owned and finish.
void testHandoffRefusesRequestsStillOwnedByTheEngine() {
  LoopFixture fixture;
  DomainSurfaces domain;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  require(loop.receive(protocol::peer::serialize(request(7))), "the queued request was refused");
  require(!loop.prepareResourceHandoff(domain.authority).has_value(),
          "a queued request minted a handoff proof");
  require(!loop.admissionOpen() &&
              domain.authority.holder() == ResourceDomainAuthority::Holder::Owner,
          "a refused preparation reopened admission or moved the Owner interval");
  runUntilIdle(loop);
  const auto drained = loop.snapshot();
  require(drained.submitted == 1 && drained.completed == 1,
          "the refused handoff disturbed the request the loop held");
  // Parked command: the engine owes its ticket and the drain sees it.
  loop.openAdmission();
  const auto commandReady = fixture.executor.holdCommands();
  require(loop.receive(protocol::peer::serialize(request(8))), "the parked-command request was refused");
  for (uint32_t step = 0; step < 8 && !loop.commandInFlight(); ++step)
    static_cast<void>(loop.tick());
  require(loop.commandInFlight(), "the fixture did not park its command");
  require(!loop.prepareResourceHandoff(domain.authority).has_value(),
          "a parked command minted a handoff proof");
  *commandReady = true;
  runUntilIdle(loop);
  require(loop.prepareResourceHandoff(domain.authority).has_value(),
          "the drained graph still refused a handoff");
}

// Every request ended, no command in flight, the engine idle: the retained
// graph is still running a state write, and only landing it and polling it
// retires that category. The Engine's own counters read clean throughout.
void testHandoffRefusesIOTheRetainedGraphStillRuns() {
  PersistentLoopFixture fixture;
  DomainSurfaces domain;
  engine::NativeRuntime &loop = fixture.loop;
  queueOneReplayPoint(fixture);
  fixture.monotonic += engine::WriteBehind::kDelayMilliseconds;
  static_cast<void>(loop.tick());
  const auto io = fixture.cache.retainedIo();
  require(idle(loop) && !loop.commandInFlight() && !fixture.cache.retainedIoIdle() &&
              io.stateWrites == 1 && io.owed == 0,
          "the loop was not idle with exactly the running state write outstanding");
  require(!loop.prepareResourceHandoff(domain.authority).has_value(),
          "an idle engine minted a handoff over a running state write");
  fixture.offload->ready = true;
  for (uint32_t step = 0; step < 16 && !fixture.loop.snapshot().writeBehind.durable; ++step) {
    static_cast<void>(loop.tick());
    fixture.tier.complete();
  }
  require(fixture.cache.retainedIoIdle() && idle(loop),
          "the state write did not land and get polled");
  require(loop.prepareResourceHandoff(domain.authority).has_value(),
          "the drained write still refused a handoff");
}

// The GPU work and the requests are done, yet the graph still owes callbacks
// and descendants: the Neural Engine jobs its model has not reported, then the
// completion closure a command its owner has retired still holds. Each alone
// refuses; neither is visible in any idleness count.
void testHandoffRefusesClosuresAndDescendantsPastTheGPU() {
  LoopFixture fixture;
  DomainSurfaces domain;
  engine::NativeRuntime &loop = fixture.loop;
  uint32_t notifierRuns = 0;
  loop.setCompletionNotifier([&] { ++notifierRuns; });
  loop.announceReady();
  fixture.executor.owedServiceWork = 1;
  require(idle(loop) && !loop.commandInFlight() && fixture.cache.retainedIoIdle(),
          "the graph was otherwise at rest with one unreported Neural Engine job");
  require(!loop.prepareResourceHandoff(domain.authority).has_value(),
          "an unreported Neural Engine job minted a handoff proof");
  fixture.executor.owedServiceWork = 0;
  require(loop.prepareResourceHandoff(domain.authority).has_value(),
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
  require(!loop.prepareResourceHandoff(domain.authority).has_value(),
          "a completion closure its holder still keeps minted a handoff proof");
  fixture.executor.heldCompletion = nullptr;
  require(loop.prepareResourceHandoff(domain.authority).has_value(),
          "the closure outlived the command that borrowed it");
}

// All four categories at rest: one proof is minted, transfers once, and the
// domain comes back to its owner, where the next safe point mints a fresh one.
void testHandoffMintsOneProofPerSafePoint() {
  LoopFixture fixture;
  DomainSurfaces domain;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  auto proof = loop.prepareResourceHandoff(domain.authority);
  require(proof.has_value(), "a fully retired graph minted no handoff proof");
  require(!loop.admissionOpen() && !loop.commandInFlight() && idle(loop),
          "the minting safe point was not a closed-gate quiet one");
  auto handedOff = domain.authority.transferToWorker(std::move(*proof));
  require(handedOff.holder() == ResourceDomainAuthority::Holder::Worker,
          "the transferred authority is not in a worker's hands");
  rejects([&] { static_cast<void>(domain.authority.transferToWorker(std::move(*proof))); },
          "unspent quiescence proof",
          "the same quiescence proof was consumable twice");
  // The worker claims its own interval, ends it, and the owner takes the
  // authority back on the thread that will serve again.
  std::future<WorkerHandoff> parked{std::async(
      std::launch::async,
      [token = std::move(handedOff)]() mutable {
        token.claim();
        return std::move(token).park();
      })};
  auto back = parked.get();
  require(back.holder() == ResourceDomainAuthority::Holder::Parked,
          "the handoff the worker published is not Parked");
  domain.authority.returnToOwner(std::move(back));
  require(domain.authority.holder() == ResourceDomainAuthority::Holder::Owner,
          "the returned domain is not owned again");
  require(!loop.admissionOpen(), "the handoff round trip reopened admission");
  require(loop.prepareResourceHandoff(domain.authority).has_value(),
          "the returned domain could not mint a fresh proof at its next safe point");
}

// A proof minted at a safe point is refused once the owner mutates the domain
// it leased again; only a proof minted after that mutation transfers.
void testHandoffProofGoesStaleOnALaterDomainMutation() {
  LoopFixture fixture;
  DomainSurfaces domain;
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
  auto proof = loop.prepareResourceHandoff(domain.authority);
  require(proof.has_value(), "a fully retired graph minted no handoff proof");
  // The governor this lease bounds is a mutation surface of this domain: its
  // mutating operations demand the holder thread and record the holder interval.
  static_cast<void>(domain.governor.setServing(true));
  rejects([&] { static_cast<void>(domain.authority.transferToWorker(std::move(*proof))); },
          "fresh quiescence proof",
          "a proof outlived a later mutation of its own domain");
  static_cast<void>(domain.governor.setServing(false));
  require(domain.authority.holder() == ResourceDomainAuthority::Holder::Owner,
          "the refused transfer moved the owner interval");
  auto fresh = loop.prepareResourceHandoff(domain.authority);
  require(fresh.has_value(), "the domain could not mint at the new safe point");
  auto handedOff = domain.authority.transferToWorker(std::move(*fresh));
  std::future<WorkerHandoff> parked{std::async(
      std::launch::async,
      [token = std::move(handedOff)]() mutable {
        token.claim();
        return std::move(token).park();
      })};
  domain.authority.returnToOwner(parked.get());
  require(domain.authority.holder() == ResourceDomainAuthority::Holder::Owner,
          "the domain did not return to its owner");
}

// ---- [T024] publishEngine / tryPublishEngine / destroyEngine ----

// A sink for a test-built Engine adopted through tryPublishEngine: an adopted
// Engine reaches this shell only as a caller's unique_ptr, and its events go
// to its own sink.
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

// The same retained components as LoopFixture, but the loop starts as the
// model-less shell: no Engine until the test publishes one.
struct ShellFixture {
  explicit ShellFixture(PoolShape shape = {}, protocol::ProtocolLimits limits = {})
      : storage(shape.pages, 4096, shape.extentPages),
        pool(storage, shape.runwayPages), cache(pool, nullptr, nullptr),
        persistence(cache),
        loop(NativeLoopConfig{.engine = test::engineConfig(),
                              .metrics = &metrics,
                              .weights = &weights,
                              .weightAdmission = test::admitAll,
                              .growthAdmission = test::admitAll,
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
  RuntimeMetrics metrics;
  Weights weights;
  engine::NativeRuntime loop;

  // Every event the loop has written.
  std::vector<protocol::EngineEvent> events() const {
    return protocol::peer::decodeEvents(output);
  }
};

// [T024] The Engine-absent shell answers inference requests with the same
// request-scoped refusal frame the closed gate gives, touches no Engine
// telemetry, and then — through publishEngine — serves normally, rebinding the
// loop's stored completion notifier onto the Engine it just published.
struct ThrowingNotifierCopy {
  std::shared_ptr<bool> fail;
  int *calls;
  ThrowingNotifierCopy(std::shared_ptr<bool> flag, int *count) : fail(std::move(flag)), calls(count) {}
  ThrowingNotifierCopy(const ThrowingNotifierCopy &other) : fail(other.fail), calls(other.calls) {
    if (*fail) throw std::runtime_error("injected notifier copy failure");
  }
  void operator()() const { ++*calls; }
};

void testStagedAdoptionBindingsAndPreparationFailure() {
  ShellFixture fixture({.pages = 512});
  auto &loop = fixture.loop;
  loop.closeAdmission();
  int calls = 0;
  auto fail = std::make_shared<bool>(false);
  std::function<void()> notifier = ThrowingNotifierCopy(fail, &calls);
  loop.setCompletionNotifier(std::move(notifier));
  auto candidate = loop.makePrivateEngine(test::engineConfig(), fixture.cache,
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
  input.weights = &fixture.weights;
  input.weightAdmission = test::admitAll;
  input.growthAdmission = test::admitAll;
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
  loop.announceReady();
  require(!loop.hasEngine(), "the model-less shell started with an Engine");
  require(loop.receive(protocol::peer::serialize(request(11))),
          "the shell refused a request by closing the connection");
  const auto refused = answeredFor(fixture.events(), 11);
  require(refused.refused == 1 && refused.starts == 0 && refused.terminals == 0 &&
              !refused.otherErrors,
          "the Engine-absent shell did not answer one request-scoped frame");
  require(fixture.metrics.snapshot().prefillInputTokens == 0,
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
}

// [T024/T031] A refused adoption consumes nothing: the caller keeps its Engine
// and destroys it itself; an accepted one binds into the shell without ever
// re-pointing the shell's witnesses at the candidate's graph.
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
  require(!publishedEngine.loop.tryPublishEngine(firstCandidate),
          "an already-published shell adopted a second Engine");
  require(firstCandidate != nullptr && publishedEngine.loop.hasEngine(),
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
  // The adopted Engine borrows the candidate graph's Cache; the shell's own
  // retained-IO witness still names no Cache (only T031's physical adoption
  // rebinds it), so the detach boundary refuses over it and the adopted
  // Engine stays intact.
  require(!adoptedEngine.loop.destroyEngine() &&
              adoptedEngine.loop.hasEngine(),
          "the detach ran over an adopted Engine whose witnesses were not rebound");
}

// [T024] A retained graph still running IO refuses the detach as firmly as the
// handoff witness set does; when the write lands, the same boundary detaches.
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

// [T030] FR-023 pre-wire (Gate 3): the window the published Engine enforces is
// the exact number a per-request capacity reader takes, and it is the same
// number `submit` refuses a longer prompt at -- never a ceiling a ReadyEvent
// carried, the descriptor's capability, or a caller's hope. The read is absent-
// safe: a detached shell reports NOTHING. And what a recovery candidate's PRIVATE
// Engine carries travels with the CANDIDATE alone: building it publishes nothing,
// so the shell's own read is untouched while its window is not this shell's.
void testPublishedEngineCapacityIsTheExactWindow() {
  engine::NativeLoopConfig config;
  config.engine.maxContext = 1024;
  LoopFixture fixture(config, {.pages = 512});
  engine::NativeRuntime &loop = fixture.loop;
  loop.announceReady();
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

} // namespace

int main() {
  try {
    testWireLifecycleAndCacheHit();
    testSnapshotReportsLiveRequests();
    testGenerationPromptBoundsTheReplayState();
    testCacheSaltAndDeduplicationCrossTheWire();
    testRequestFlagsReachTheModel();
    testSamplingReachesTheModel();
    testPromptProgress();
    testCapacityFailureHasOneTerminalFrame();
    testFatalFramingClosesConnection();
    testInvalidLimitsAreRejectedAtConstruction();
    testLoopNeedsItsComponents();
    testRequestErrorKeepsFraming();
    testCommandWatchdogAndPendingHealthWake();
    testDuplicateLiveRequestClosesWithoutAmbiguousError();
    testCancelledIdIsReusableInTheSameInput();
    // The historical Battery gate cases, re-homed onto the current request path.
    testAdmissionGateIsFinalNativeBoundary();
    testCloseBeforeSubmitStartsNothing();
    testSubmitBeforeCloseKeepsTheAdmittedRequest();
    testCloseAndSubmitHaveOneWinner();
    testStaleReadyObservationCannotBypassTheGate();
    testControlAndCancellationSurviveClosedAdmission();
    for (int repetition = 0; repetition < 20; ++repetition) {
      testPendingRestoreLifecycle(false);
      testPendingRestoreLifecycle(true);
    }
    testReopenIsExplicit();
    // The T010 clock-reentrancy correction.
    testClockCallbacksQueryAdmissionWithoutReenteringTheGate();
    testCloseInsideTheClockRefusesThatRequest();
    testCloseStartedInsideTheClockRacesTheSubmission();
    // The T011 (U-04) wake-source aggregation.
    testWakeupBoundAggregatesSources();
    testEngineSchedulingStillDrivesTheBound();
    testRetainedPersistenceDrivesThePollBound();
    testStalledWriteBudgetAdmissionIsTheBound();
    testControlFailureUsesExecutionBoundary();
    testAdmissionExceptionStopsTheEngineOnce();
    testFrameFailureUsesExecutionBoundary();
    testEngineFailureNamesItsReason();
    testOutOfVocabularyTokensStayRequestScoped();
    testReadyAnnouncesVisionWhenImagesAreAdmitted();
    testImageRequestBeyondVisionStaysRequestScoped();
    testStepTokensFitTheWire();
    testScoreRequestCompletesAfterFullPrompt();
    testCancelledScoreReturnsEmptyLogits();
    testPrefillTimeCountsFromTheStart();
    testInvalidScoreFailsOneRequestAndKeepsTheBatch();
    testConstrainedMaskExchange();
    testControlPassReclaimsUnderHostPressure();
    testControlPassGivesCacheBackUnderSystemWarning();
    testServingMarkRestoresTheMarkItFound();
    testControlPassHoldsGrowthForAWaitingRequest();
    testIdleWeightsAreReleasedAndRestored(false);
    testIdleWeightsAreReleasedAndRestored(true);
    testReleasableMemoryRestoresTheExpertsAfterTheImages();
    testIdleReleaseRestoresTheSplitLast();
    testRefusedRestoreWaitsForMemory();
    testControlPassGrowsTheExpertStoreWhenMemoryIsAmple();
    testIdleControlPassExchangesCacheForTheExpertStore();
    testExpertExchangeWaitsWhereGrowthDoes();
    testExpertExchangeKeepsCacheThatCannotCoverTheChunk();
    testExpertExchangeCoversTheEngineLimit();
    testRefusedExchangeLeavesItsBytesToTheNextPass();
    testShrunkRestoreGrowsBackAfterTheRequest();
    testRestoreTakesChunksOnlyFromAHostWithRoomToSpare();
    testIdleReleaseOffReleasesOnlyOnRequest();
    testReleaseRequestGivesTheWeightsBackWhenIdle();
    testHoldingRequestsSpansFirstToLastRequest();
    testMemoryStatusReporterLogsTransitionsOnly();
    // The T019 four-witness handoff precondition at the native boundary (Gate 1
    // proof), added on top of the upstream and historical registrations above.
    testHandoffNeedsEveryWitnessAndAnOpenGateRefuses();
    testHandoffRefusesRequestsStillOwnedByTheEngine();
    testHandoffRefusesIOTheRetainedGraphStillRuns();
    testHandoffRefusesClosuresAndDescendantsPastTheGPU();
    testHandoffMintsOneProofPerSafePoint();
    testHandoffProofGoesStaleOnALaterDomainMutation();
    // [T024] The detachable Engine surface: model-less shell publish/refusal frames,
    // adoption that consumes nothing when refused, and the safe-point detach's
    // drain barriers with the Engine's life ending off the safe point.
    testEnginelessShellRefusesThenPublishesAndServes();
    testStagedAdoptionBindingsAndPreparationFailure();
    testTryPublishEngineKeepsRefusedCandidatesOwnable();
    testDestroyEngineRefusesRetainedGraphIO();
    testPublishedEngineCapacityIsTheExactWindow();
    std::cout << "native engine loop tests passed\n";
    return EXIT_SUCCESS;
  } catch (const std::exception &error) {
    std::cerr << "native engine loop tests failed: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
