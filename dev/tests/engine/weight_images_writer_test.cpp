#include "engine/ResourceDomainLease.hpp"
#include "TestWriterPort.hpp"
#include "model/WeightImages.hpp"
#include <condition_variable>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>

using namespace splash;
template <class F> bool refuses(F &&f) { try { f(); return false; } catch (...) { return true; } }
struct Notifier {
  std::shared_ptr<bool> fail;
  explicit Notifier(std::shared_ptr<bool> value) : fail(std::move(value)) {}
  Notifier(const Notifier &other) : fail(other.fail) { if (*fail) throw std::runtime_error("copy failed"); }
  void operator()() const {}
};

int main(int argc, char **argv) {
  bool ok = true, loading = true, bodyEnded = false, releaseNotifier = false, throwBody = false;
  bool ownerScope = false, writerScope = false, scopeOrder = true, notifierOutsideScope = true;
  constexpr int claimId = 37;
  int observedClaim = 0;
  std::mutex mutex;
  std::condition_variable cv;
  metal::MetalBackend backend(argc > 1 ? argv[1] : "unused.metallib");
  auto lease = engine::ResourceDomainLease::acquireForOwner();
  lease.attach(backend);
  model::WeightImages images(backend, "test");
  auto file = images.load({.component="test", .magic="testfile", .bytes=16 * 1024,
      .write=[&](auto bytes, const auto &) {
        const auto header = model::weightFileHeader("testfile", 0, 0);
        std::copy(header.begin(), header.end(), bytes.begin());
        lease.check("image writer");
        if (!loading) scopeOrder &= writerScope && !ownerScope && observedClaim == claimId;
        if (throwBody) throw metal::MetalAllocationError("writer refused", metal::AllocationFailure::HostPressure);
        if (!loading) { std::lock_guard lock(mutex); bodyEnded = true; cv.notify_all(); }
      }});
  (void)file;
  images.enableExternalWriter();
  images.setWeightWriteScope([&](const std::function<void()> &write) {
    scopeOrder &= !ownerScope && !writerScope;
    writerScope = true;
    observedClaim = claimId;
    struct Exit { bool &scope; ~Exit() { scope = false; } } exit{writerScope};
    write();
  });
  images.setCompletionNotifier([&] {
    notifierOutsideScope &= !writerScope;
    std::unique_lock lock(mutex);
    cv.wait(lock, [&] { return releaseNotifier; });
  });
  images.release();
  loading = false;
  auto admit = [](uint64_t, const std::function<void()> &work) -> metal::AllocationResult { work(); return {}; };
  ownerScope = true;
  ok &= !images.restore(admit) && images.hasPreparedWriter() && images.writing();
  ownerScope = false;
  auto receipt = lease.lendToWriter();
  TestWriterPort port(lease, receipt);
  images.launchPreparedWriter(port);
  { std::unique_lock lock(mutex); cv.wait(lock, [&] { return bodyEnded; }); }
  std::thread reaper([&] { receipt.join(); });
  ok &= refuses([&] { lease.check("owner during writer"); });
  ok &= refuses([&] { images.release(); });
  ok &= refuses([&] { (void)images.restore(admit); });
  bool outsiderRefused = false;
  std::thread outsider([&] { outsiderRefused = refuses([&] { lease.check("outsider"); }); });
  outsider.join();
  ok &= outsiderRefused;
  ok &= !receipt.joined() && !images.finishPreparedWriter();
  { std::lock_guard lock(mutex); releaseNotifier = true; }
  cv.notify_all();
  reaper.join();
  ok &= images.finishPreparedWriter() && !images.writerIntervalActive();
  ok &= scopeOrder && notifierOutsideScope;
  ok &= images.restore(admit);
  lease.check("owner after reclaim");
  images.release();
  auto refuse = [](uint64_t, const std::function<void()> &) -> metal::AllocationResult {
    return metal::AllocationFailure::EngineBudget;
  };
  ok &= refuses([&] { (void)images.restore(refuse); });
  ok &= !images.hasPreparedWriter();
  ok &= !images.restore(admit) && images.hasPreparedWriter();
  auto failCopy = std::make_shared<bool>(false);
  images.setCompletionNotifier(Notifier(failCopy));
  *failCopy = true;
  auto cancelled = lease.lendToWriter();
  TestWriterPort cancelledPort(lease, cancelled);
  ok &= refuses([&] { images.launchPreparedWriter(cancelledPort); });
  lease.cancelUnstartedWriter(cancelled);
  images.cancelPreparedWriter();
  images.setCompletionNotifier({});
  ok &= !images.writerIntervalActive();
  ok &= !images.restore(admit);
  throwBody = true;
  auto second = lease.lendToWriter();
  TestWriterPort secondPort(lease, second);
  images.launchPreparedWriter(secondPort);
  std::thread secondReaper([&] { second.join(); });
  secondReaper.join();
  bool allocationFailure = false;
  try { (void)images.finishPreparedWriter(); }
  catch (const metal::MetalAllocationError &error) {
    allocationFailure = error.failure() == metal::AllocationFailure::HostPressure;
  }
  ok &= allocationFailure && !images.writerIntervalActive();
  throwBody = false;
  ok &= !images.restore(admit);
  auto third = lease.lendToWriter();
  TestWriterPort thirdPort(lease, third);
  images.launchPreparedWriter(thirdPort);
  std::thread thirdReaper([&] { third.join(); });
  thirdReaper.join();
  ok &= images.finishPreparedWriter() && images.restore(admit);
  return ok ? 0 : 1;
}
