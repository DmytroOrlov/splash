#include "TestMetalMemory.hpp"
#include "engine/ResourceDomainLease.hpp"
#include <condition_variable>
#include <future>
#include <mutex>
#include <thread>

using namespace splash;
using namespace splash::engine;
template <class F> bool refused(F &&f) { try { f(); return false; } catch (...) { return true; } }

int main() {
  constexpr uint64_t ample = 1ULL << 40;
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, ample, 1, 0, [] { return std::optional<HostMemory>({ample, ample}); }, 0);
  auto lease = ResourceDomainLease::acquireForOwner();
  lease.attach(governor);
  auto admission = governor.allocationAdmission();
  bool ok = refused([&] { (void)admission(1, [] {}); });
  auto claim = governor.ledger().open({.cls = ClaimClass::Floor});
  MemoryLedger &cachedLedger = governor.ledger();
  {
    MemoryGovernor::Scope owner(governor, claim);
    ok &= static_cast<bool>(admission(1, [] {}));
    ok &= refused([&] { (void)lease.lendToWriter(); });
    ok &= refused([&] { (void)admission(1, [] { throw std::runtime_error("failure"); }); });
  }
  auto writer = lease.lendToWriter();
  ok &= refused([&] {
    auto illicit = cachedLedger.open({.cls = ClaimClass::Floor});
    cachedLedger.close(illicit);
  });
  std::mutex mutex;
  std::condition_variable cv;
  bool entered = false, release = false, writerAllowed = false;
  writer.launch([&] {
    MemoryGovernor::Scope scope(governor, claim);
    writerAllowed = static_cast<bool>(admission(1, [] {}));
    { std::lock_guard lock(mutex); entered = true; }
    cv.notify_all();
    std::unique_lock lock(mutex);
    cv.wait(lock, [&] { return release; });
  });
  { std::unique_lock lock(mutex); cv.wait(lock, [&] { return entered; }); }
  ok &= refused([&] { MemoryGovernor::Scope unauthorized(governor, claim); });
  ok &= refused([&] { (void)admission(1, [] {}); });
  (void)governor.snapshot();
  { std::lock_guard lock(mutex); release = true; }
  cv.notify_all();
  std::thread reaper([&] { writer.join(); });
  reaper.join();
  ok &= writerAllowed && writer.joined();
  lease.reclaimWriter(writer);
  ok &= !writer.failure();
  lease.setAdmissionWitness([] { return true; });
  lease.setRequestDrainWitness([] { return true; });
  lease.setRetainedIoWitness([] { return true; });
  lease.setCallbackRetirementWitness([] { return true; });
  auto proof = lease.obtainQuiescence();
  auto worker = lease.transferToWorker(std::move(*proof));
  ok &= refused([&] { (void)cachedLedger.open({.cls = ClaimClass::Floor}); });
  std::promise<WorkerHandoff> returned;
  auto result = returned.get_future();
  std::thread workerThread([token = std::move(worker), &returned, &cachedLedger]() mutable {
    token.claim();
    auto id = cachedLedger.open({.cls = ClaimClass::Floor});
    cachedLedger.close(id);
    returned.set_value(std::move(token).park());
  });
  workerThread.join();
  auto parked = result.get();
  lease.returnToOwner(std::move(parked));
  governor.ledger().close(claim);
  {
    MemoryGovernor survivor(backend, ample, 1, 0, [] { return std::optional<HostMemory>({ample, ample}); }, 0);
    { auto temporary = ResourceDomainLease::acquireForOwner(); temporary.attach(survivor); }
    auto id = survivor.ledger().open({.cls = ClaimClass::Floor});
    survivor.ledger().close(id);
  }
  {
    auto survivor = ResourceDomainLease::acquireForOwner();
    { MemoryGovernor temporary(backend, ample, 1, 0, [] { return std::optional<HostMemory>({ample, ample}); }, 0);
      survivor.attach(temporary); }
  }
  return ok ? 0 : 1;
}
