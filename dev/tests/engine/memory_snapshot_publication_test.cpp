#include "TestMetalMemory.hpp"
#include "engine/ResourceDomainLease.hpp"

#include <atomic>
#include <barrier>
#include <condition_variable>
#include <iostream>
#include <thread>

using namespace splash;
using namespace splash::engine;

namespace {
void require(bool condition) {
  if (!condition) throw std::runtime_error("snapshot publication assertion failed");
}
template <class F> bool refuses(F &&f) {
  try { f(); return false; } catch (...) { return true; }
}
struct Gate {
  std::mutex mutex;
  std::condition_variable cv;
  bool entered = false, released = false;
  void block() {
    std::unique_lock lock(mutex);
    entered = true;
    cv.notify_all();
    cv.wait(lock, [&] { return released; });
  }
  void wait() {
    std::unique_lock lock(mutex);
    cv.wait(lock, [&] { return entered; });
  }
  void release() {
    std::lock_guard lock(mutex);
    released = true;
    cv.notify_all();
  }
};
struct Pool final : model::ElasticPool {
  uint64_t bytes = 0;
  mutable std::atomic<unsigned> reads{0};
  Gate gate;
  model::PoolState state() const override {
    ++reads;
    return {.name = "pool", .currentBytes = bytes, .capBytes = 64,
            .growUnitBytes = bytes < 64 ? 64U : 0U};
  }
  uint64_t release(uint64_t) override { return 0; }
  metal::AllocationResult grow(const metal::AllocationAdmission &) override {
    bytes = 32; // A real, deliberately incomplete external mutation.
    gate.block();
    bytes = 64;
    return {};
  }
};

void run(bool governorPath) {
  constexpr uint64_t ample = 1ULL << 40;
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, ample, 1, 0,
      [] { return std::optional<HostMemory>({ample, ample}); }, 0);
  require(governor.snapshot().accounts.size() == 1); // Defined initial value.
  auto lease = ResourceDomainLease::acquireForOwner();
  lease.attach(governor);
  MemoryLedger &cached = governor.ledger();
  auto pool = std::make_unique<Pool>();
  cached.addPool(*pool);
  cached.setReturning([] { return Returning{.owedBytes = 9}; }, {});
  const auto a = governor.publishSnapshot();
  require(a.accounts.size() == 2 && a.accounts[1].currentBytes == 0 && a.owed.bytes == 9);
  auto writer = lease.lendToWriter();
  std::barrier metadataStart(2);
  writer.launch([&] {
    if (governorPath) {
      governor.growToTargets(1000, MemoryPressure::Normal);
    } else {
      cached.addAccount("extra", [] { return 7; });
      require(cached.grow(ample, {.admits = [](uint64_t, uint64_t) { return true; },
          .grow = [](ClaimId, model::ElasticPool &p) { return p.grow({}); }}));
    }
    metadataStart.arrive_and_wait();
    for (unsigned i = 0; i < 500; ++i) {
      const auto claim = cached.open({.cls = ClaimClass::Floor});
      cached.update(claim, {.cls = ClaimClass::Growth});
      cached.close(claim);
    }
  });
  pool->gate.wait();
  require(refuses([&] { (void)cached.open({.cls = ClaimClass::Floor}); }));
  // publishSnapshot takes the historical governor mutex. Test its refusal
  // only on the direct path; the governor path intentionally holds that lock.
  if (!governorPath) require(refuses([&] { governor.publishSnapshot(); }));
  const auto reads = pool->reads.load();
  std::thread reader([&] {
    for (unsigned i = 0; i < 200; ++i) {
      const auto s = governor.snapshot();
      require(s.accounts.size() == 2 && s.accounts[1].currentBytes == 0 &&
              s.accounts[1].grows == 0 && s.claims.waiting == 0 && s.owed.bytes == 9 &&
              s.chargedBytes == a.chargedBytes && s.headroomBytes == a.headroomBytes);
    }
  });
  reader.join(); // Must finish BEFORE the callback is released.
  require(pool->reads == reads); // No passive model callback invocation.
  pool->gate.release();
  std::thread metadataReader([&] {
    metadataStart.arrive_and_wait();
    for (unsigned i = 0; i < 500; ++i) {
      const auto s = governor.snapshot();
      const auto &row = s.accounts[1];
      require((row.currentBytes == 0 && row.grows == 0) ||
              (governorPath && row.currentBytes == 64 && row.grows == 1));
    }
  });
  metadataReader.join();
  std::thread reaper([&] { writer.join(); });
  reaper.join();
  lease.reclaimWriter(writer);
  require(!writer.failure());
  const auto b = governor.publishSnapshot();
  require(b.accounts.size() == (governorPath ? 2U : 3U) &&
          b.accounts[1].currentBytes == 64 && b.accounts[1].grows == 1 && b.owed.bytes == 9);
  require(governor.snapshot().accounts[1].currentBytes == 64);

  // Status owns names/numbers: even after a callback referent is destroyed,
  // a passive shutdown read cannot revisit it. No further live publication.
  pool.reset();
  require(governor.snapshot().accounts[1].name == "pool" &&
          governor.snapshot().accounts[1].currentBytes == 64);
}
}

int main() {
  run(false); // Cached ledger, Writer interval and explicit Owner publication.
  run(true);  // Historical governor mutex held throughout a real pool.grow.
  MemoryLedger standalone;
  const auto claim = standalone.open({.cls = ClaimClass::Floor});
  standalone.update(claim, {.cls = ClaimClass::Growth});
  standalone.close(claim);
  std::cout << "snapshot publication: PASS\n";
}
