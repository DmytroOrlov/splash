#define SPLASH_ENGINE_WRITER_NO_MAIN
#include "engine_writer_test.cpp"
#include "ProtocolPeer.hpp"
#include "TestModel.hpp"
#include "engine/NativeRuntime.hpp"
#include "engine/RuntimeResources.hpp"
#include <future>

namespace {
void fullRegistryReuse() {
  MemoryLedger ledger;
  for (unsigned i = 0; i != 254; ++i) ledger.addAccount("retained", [] { return 0; });
  test::FakeMemory memory({});
  test::FakeElasticPool pool("model", memory, 64, 0, 1, 1, 1);
  std::array<model::ElasticPool *, 1> pools{&pool};
  unsigned calls = 0;
  for (unsigned cycle = 0; cycle != 3; ++cycle) {
    auto registration = ledger.registerModel(pools, [&](uint32_t, bool, bool) { ++calls; return 0; });
    const auto beforeActive = calls;
    auto claim = ledger.open({.cls = ClaimClass::Start});
    (void)ledger.free(claim, {.bytes = 1, .afterStart = true}, 0, MemoryPressure::Normal);
    require(calls > beforeActive, "registered model callback was not used");
    registration.reset();
    const auto before = calls;
    (void)ledger.free(claim, {.bytes = 1, .afterStart = true}, 0, MemoryPressure::Normal);
    require(calls == before && ledger.largestGrowthUnit() == 0, "retired callback or pool remained reachable");
    ledger.close(claim);
  }
  // Removing a superseded generation cannot remove its replacement.
  auto older = ledger.registerModel({}, [&](uint32_t, bool, bool) { throw std::runtime_error("old callback"); return 0; });
  auto newer = ledger.registerModel({}, [](uint32_t, bool, bool) { return 0; });
  older.reset();
  auto claim = ledger.open({.cls = ClaimClass::Start});
  (void)ledger.free(claim, {.bytes = 1, .afterStart = true}, 0, MemoryPressure::Normal);
  ledger.close(claim);

  // Slot reuse must preserve registration priority, independently of IDs.
  MemoryLedger ordered;
  test::FakeElasticPool retained("retained-pool", memory, 64, 0, 1, 1, 1);
  test::FakeElasticPool replacement("replacement", memory, 64, 0, 1, 1, 1);
  auto retired = ordered.registerModel(pools, [](uint32_t, bool, bool) { return 0; });
  ordered.addPool(retained);
  retired.reset();
  std::array<model::ElasticPool *, 1> fresh{&replacement};
  auto registration = ordered.registerModel(fresh, [](uint32_t, bool, bool) { return 0; });
  MemoryGovernorSnapshot status;
  ordered.fill(status, 128);
  require(status.accounts.size() == 3 && status.accounts[1].name == "retained-pool" &&
          status.accounts[2].name == "replacement", "reused slot reordered accounts");
  auto demand = ordered.open({.cls = ClaimClass::InService});
  (void)ordered.free(demand, {.bytes = 1}, 0, MemoryPressure::Normal);
  require(retained.shrinks == 1 && replacement.shrinks == 0, "reused slot changed pool reclaim priority");
  ordered.close(demand);
}

void nativeCycle() {
  constexpr uint64_t ample = 1ULL << 40;
  test::FakeMemory memory({});
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, ample, 1, 0, [] { return std::optional<HostMemory>({ample, ample}); }, 0);
  auto lease = ResourceDomainLease::acquireForOwner(); lease.attach(governor);
  test::TestKvStorage storage(64, 4096, 4);
  KvPool pool(storage, 0); Cache cache(pool, nullptr, nullptr); WriteBehind persistence(cache);
  governor.ledger().addAccount("kv", [&] { return storage.allocatedBytes(); });
  governor.ledger().addAccount("states", [] { return 0; });
  Images images(lease);
  std::unique_ptr<test::Executor> model;
  std::unique_ptr<test::FakeElasticPool> experts;
  const auto buildModel = [&] {
    experts = std::make_unique<test::FakeElasticPool>("model", memory, 64, 0, 1, 1, 1);
    model = std::make_unique<test::Executor>(); model->experts = experts.get();
  };
  double now = 0;
  std::vector<uint8_t> output;
  std::atomic<unsigned> wakes{0};
  auto power = std::make_shared<PendingPowerObservation>([&] { ++wakes; });
  power->recordInitial(LifecyclePower::AC); (void)power->take();
  NativeLoopConfig shell;
  shell.engine = test::engineConfig({.maxContext = 256, .vocabularySize = 64, .governor = &governor, .writerLease = &lease});
  shell.monotonicMilliseconds = [&] { return now; }; shell.unixMicros = [] { return uint64_t{1000}; };
  NativeRuntime loop(shell, 1000, [&](std::span<const uint8_t> bytes) { output.insert(output.end(), bytes.begin(), bytes.end()); },
      [] { return std::string("{}"); }, {});
  loop.setPowerObservation(power); loop.closeAdmission();
  auto ready = protocol::peer::kTestReady; ready.maxContextTokens = 256; loop.announceReady(ready);
  require(!loop.hasEngine() && !loop.publishedContextTokens(), "cold shell invented an Engine");
  require(!loop.serviceRetainedPersistence(), "cold shell invented a retained queue");
  auto config = shell.engine; config.maxContext = 128;
  config.weights = WeightResidencyConfig{.weights = &images, .admit = governor.allocationAdmission()};
  buildModel();
  auto candidate = loop.makePrivateEngine(config, cache, persistence, *model);
  require(candidate->borrowedCache() == &cache && candidate->borrowedWriteBehind() == &persistence &&
          candidate->borrowedConfig().writerLease == &lease, "candidate borrowed a different graph");
  NativeRuntime::NativeAdoptionInput input;
  input.engineSlot = &candidate; input.engineConfig = config; input.cache = &cache; input.writeBehind = &persistence;
  input.engineFailed = [] {}; input.authorityHeld = [&] { return lease.holder() == ResourceDomainAuthority::Holder::Owner; };
  input.contextCeiling = 64;
  std::unique_ptr<NativeRuntime::StagedAdoption> staged;
  require(!loop.stageAdoption(input, staged) && candidate && !loop.hasEngine(), "context ceiling escaped");
  input.contextCeiling = 256;
  require(loop.stageAdoption(input, staged) && !candidate && loop.publishedContextTokens() == 128, "staging failed");
  candidate = loop.rollbackAdoption(std::move(staged));
  require(candidate && !loop.hasEngine() && !loop.publishedContextTokens() && !loop.admissionOpen(), "rollback escaped publication");
  require(loop.tryPublishEngine(candidate) && !candidate && loop.publishedContextTokens() == 128,
          "simple publication failed to retain the candidate context");
  candidate = loop.destroyEngine();
  require(candidate && !loop.hasEngine(), "simple publication lost its retained graph bindings");
  require(loop.stageAdoption(input, staged), "fresh adoption failed after rollback");
  loop.commitAdoption(std::move(staged)); loop.openAdmission();

  DeviceCapabilities device{.macosMajor = 26, .macosMinor = 4, .appleGpuFamily = 9,
      .physicalMemoryBytes = 64ULL << 30, .recommendedMaxWorkingSetBytes = 48ULL << 30,
      .maxBufferLengthBytes = 32ULL << 30, .maxThreadgroupMemoryBytes = 32ULL << 10,
      .maxThreadgroupWidth = 1024, .hasUnifiedMemory = true};
  const auto plan = test::requireMemoryPlan(device, test::modelMemoryProfile(1ULL << 30, 128ULL << 20, 0));
  require(plan.maximumContextTokens() > 0, "automatic memory plan has no context");
  RuntimeCacheIdentity identity; WarmupReport warmup; MemoryAuditResult audit;
  std::optional<StatusSample> publication;
  loop.serveStatus([&] {
    LifecycleStatusSnapshot life;
    life.controlReady = true; life.configuredContextCeiling = 256;
    life.modelResident = loop.hasEngine(); life.power = LifecyclePower::AC; life.state = LifecycleState::Ready;
    auto observation = power->guard();
    life.inferenceReady = life.modelResident && loop.admissionOpen() && !observation.pending() && observation.allowsAdmission();
    if (life.inferenceReady) life.effectiveContextTokens = loop.publishedContextTokens();
    else life.state = life.modelResident ? LifecycleState::Draining : LifecycleState::Suspended;
    if (!life.modelResident) {
      ResourceSnapshot detached; detached.lifecycle = life;
      return runtimeStatusJson(detached, loop.metricsSnapshot(), MemoryPressure::Normal, {}, {});
    }
    if (lease.holder() == ResourceDomainAuthority::Holder::Owner) {
      StatusSample sample; sample.engine = loop.statusSnapshot(); sample.weights = loop.weightsSnapshot();
      sample.memoryGovernor = governor.publishSnapshot(); sample.metalMemory = backend.memoryStats();
      publication = std::move(sample);
    }
    require(publication.has_value(), "Writer had no safe publication");
    auto sample = *publication; sample.lifecycle = life;
    return runtimeStatusJson({plan, identity, warmup, audit}, sample);
  });
  Gate body, notifier;
  images.body = &body;
  loop.setCompletionNotifier([&] { ++wakes; notifier.block(); });
  auto send = [&](protocol::ClientMessage message) { require(loop.receive(protocol::peer::serialize(message)), "control frame failed"); };
  auto drain = [&] {
    body.release(); notifier.release();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while ((loop.commandInFlight() || (loop.publishedEngine() && !loop.publishedEngine()->callbacksRetired())) &&
           std::chrono::steady_clock::now() < deadline) { now += 0.001; (void)loop.tick(); std::this_thread::yield(); }
    require(!loop.commandInFlight(), "native Writer did not retire");
  };
  try {
    send(protocol::ReleaseRequestFrame{1});
    protocol::RequestFrame request; request.requestId = 1; request.promptTokens = {1, 2}; request.logicalMaxOutputTokens = 1;
    request.absoluteDeadlineUnixMicros = 10000001; request.remainingDeadlineMicros = 10000000;
    send(request); (void)loop.tick(); body.wait();
    require(lease.holder() == ResourceDomainAuthority::Holder::Writer && loop.commandInFlight(), "native did not launch graph Writer");
    send(protocol::StatusRequestFrame{2});
    power->record(LifecyclePower::Battery);
    send(protocol::StatusRequestFrame{3});
    request.requestId = 9; send(request);
    send(protocol::CancelFrame{1});
    require(!loop.destroyEngine(), "active Writer detached");
    require(!loop.flushRestorePoints(), "active Writer flushed resources");
    body.release(); notifier.wait();
    require(images.ended && !loop.destroyEngine(), "ended was mistaken for retired");
    drain(); lease.check("native Owner reclaim");
    require(loop.engineHealthy() && loop.requestDrain().drained(), "native failed or lost request settlement");
    unsigned ready = 0, done = 0; bool residentStatus = false, refused = false;
    for (const auto &event : protocol::peer::decodeEvents(output)) {
      ready += std::holds_alternative<protocol::ReadyEvent>(event);
      done += std::holds_alternative<protocol::DoneEvent>(event);
      if (auto *status = std::get_if<protocol::StatusJsonEvent>(&event); status && status->correlationId == 3)
        residentStatus = status->json.find("\"model_resident\":true") != std::string::npos &&
                         status->json.find("\"inference_ready\":false") != std::string::npos;
      if (auto *error = std::get_if<protocol::ErrorEvent>(&event); error && error->requestId == 9) refused = true;
    }
    require(ready == 1 && done == 1 && residentStatus && refused, "Writer status or Battery fencing was lost");
  } catch (...) { drain(); throw; }

  auto detached = loop.destroyEngine(); require(bool(detached), "completed Engine could not detach");
  auto proof = loop.prepareResourceHandoff(lease); require(proof.has_value(), "drained graph could not transfer");
  auto token = lease.transferToWorker(std::move(*proof));
  std::promise<WorkerHandoff> returned; auto parked = returned.get_future();
  std::thread worker([&detached, &model, &experts, &memory, &returned, token = std::move(token)]() mutable {
    token.claim(); detached.reset(); model.reset(); experts.reset(); memory.release("model", 64);
    returned.set_value(std::move(token).park());
  });
  worker.join(); lease.returnToOwner(parked.get());
  const auto absent = governor.publishSnapshot();
  require(absent.accounts.size() == 3 && governor.ledger().largestGrowthUnit() == 0, "model registrations survived disposal");
  auto probe = governor.ledger().open({.cls = ClaimClass::Start});
  (void)governor.ledger().free(probe, {.bytes = 1, .afterStart = true}, 0, MemoryPressure::Normal);
  governor.ledger().close(probe);
  require(!loop.serviceRetainedPersistence(), "idle retained graph unexpectedly progressed");
  buildModel(); candidate = loop.makePrivateEngine(config, cache, persistence, *model);
  require(governor.publishSnapshot().accounts.size() == 4, "fresh model did not register its pool");
  candidate.reset(); model.reset(); experts.reset(); memory.release("model", 64);
  require(governor.publishSnapshot().accounts.size() == 3, "cancelled candidate leaked registrations");
}

void shutdownWriter(bool fatal) {
  constexpr uint64_t ample = 1ULL << 40;
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, ample, 1, 0, [] { return std::optional<HostMemory>({ample, ample}); }, 0);
  auto lease = ResourceDomainLease::acquireForOwner(); lease.attach(governor);
  Images images(lease);
  test::TestKvStorage storage(64, 4096, 4);
  KvPool pool(storage, 0); Cache cache(pool, nullptr, nullptr); WriteBehind persistence(cache);
  test::Executor model;
  NativeLoopConfig config;
  config.engine = test::engineConfig({.maxContext = 1024, .vocabularySize = 64,
      .governor = &governor, .writerLease = &lease});
  config.engine.weights = WeightResidencyConfig{.weights = &images, .admit = governor.allocationAdmission()};
  unsigned failures = 0;
  config.engineFailed = [&] { lease.check("failure callback after reclaim"); ++failures; };
  config.unixMicros = [] { return uint64_t{1000}; }; config.monotonicMilliseconds = [] { return 0.0; };
  Gate body, notifier;
  NativeRuntime loop(config, 1000, cache, persistence, model, [](auto) {}, [] { return std::string("{}"); }, {});
  struct Cleanup {
    NativeRuntime &loop;
    Gate &body, &notifier;
    ~Cleanup() { body.release(); notifier.release(); loop.retireWeightWriterForShutdown(); }
  } cleanup{loop, body, notifier};
  loop.announceReady(protocol::peer::kTestReady);
  images.body = &body;
  loop.setCompletionNotifier([&] { notifier.block(); });
  require(loop.receive(protocol::peer::serialize(protocol::ReleaseRequestFrame{1})), "shutdown release failed");
  protocol::RequestFrame request; request.requestId = 1; request.promptTokens = {1, 2}; request.logicalMaxOutputTokens = 1;
  request.absoluteDeadlineUnixMicros = 10000001; request.remainingDeadlineMicros = 10000000;
  require(loop.receive(protocol::peer::serialize(request)), "shutdown request failed");
  (void)loop.tick(); body.wait();
  loop.closeAdmission();
  require(loop.receive(protocol::peer::serialize(protocol::CancelFrame{1})), "shutdown cancel failed");
  if (fatal) {
    (void)loop.runControl([]() -> bool { throw std::runtime_error("fatal control failure during Writer"); });
    require(!loop.engineHealthy() && !failures, "resource failure callback ran under Writer authority");
  }
  // The Owner waits only at terminal teardown. W1::join still executes on
  // Engine's independent reaper, including the blocked copied notifier.
  std::thread release([&] { body.release(); notifier.release(); });
  loop.retireWeightWriterForShutdown();
  release.join();
  lease.check("shutdown reclaimed Owner");
  require(!loop.commandInFlight() && loop.publishedEngine()->callbacksRetired(), "shutdown left an armed interval");
  (void)loop.tick();
  if (fatal) {
    loop.openAdmission();
    require(failures == 1 && !loop.admissionOpen(), "fatal stream revived or failure callback was lost");
  } else
    require(loop.requestDrain().drained() && !loop.admissionOpen(), "shutdown revived admission or lost cancellation");
}

void normalACServing() {
  constexpr uint64_t ample = 1ULL << 40;
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, ample, 1, 0, [] { return std::optional<HostMemory>({ample, ample}); }, 0);
  auto lease = ResourceDomainLease::acquireForOwner(); lease.attach(governor);
  Images images(lease);
  test::TestKvStorage storage(64, 4096, 4);
  KvPool pool(storage, 0); Cache cache(pool, nullptr, nullptr); WriteBehind persistence(cache);
  test::Executor model;
  NativeLoopConfig config;
  config.engine = test::engineConfig({.maxContext = 1024, .vocabularySize = 64,
      .governor = &governor, .writerLease = &lease});
  config.engine.weights = WeightResidencyConfig{.weights = &images, .admit = governor.allocationAdmission()};
  double now = 0;
  config.unixMicros = [] { return uint64_t{1000}; }; config.monotonicMilliseconds = [&] { return now; };
  unsigned ready = 0, done = 0, errors = 0;
  protocol::peer::EventReader reader;
  NativeRuntime loop(config, 1000, cache, persistence, model, [&](std::span<const uint8_t> bytes) {
    for (const auto &event : reader.feed(bytes)) {
      ready += std::holds_alternative<protocol::ReadyEvent>(event);
      done += std::holds_alternative<protocol::DoneEvent>(event);
      errors += std::holds_alternative<protocol::ErrorEvent>(event);
    }
  }, [] { return std::string("{}"); }, {});
  struct Cleanup { NativeRuntime &loop; ~Cleanup() { loop.retireWeightWriterForShutdown(); } } cleanup{loop};
  loop.announceReady(protocol::peer::kTestReady);
  require(loop.receive(protocol::peer::serialize(protocol::ReleaseRequestFrame{1})), "AC release failed");
  protocol::RequestFrame request; request.requestId = 1; request.promptTokens = {1, 2}; request.logicalMaxOutputTokens = 1;
  request.absoluteDeadlineUnixMicros = 10000001; request.remainingDeadlineMicros = 10000000;
  require(loop.receive(protocol::peer::serialize(request)), "AC request failed");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!done && loop.engineHealthy() && std::chrono::steady_clock::now() < deadline) {
    now += 0.001; (void)loop.tick(); std::this_thread::yield();
  }
  require(ready == 1 && done == 1 && !errors && images.writes == 1 && loop.weightsSnapshot().restores == 1,
          "ordinary AC request did not restore and complete through Engine");
}
}

int main() {
  fullRegistryReuse(); nativeCycle(); shutdownWriter(false); shutdownWriter(true); normalACServing();
  std::cout << "native lifecycle/ledger: PASS\n";
}
