#include "engine/ResourceDomainLease.hpp"

#include <condition_variable>
#include <iostream>
#include <mutex>
#include <memory>
#include <thread>

using namespace splash::engine;

template <class T> concept HasAdopt = requires(T &t, std::thread thread) { t.adopt(std::move(thread)); };
template <class T> concept HasClaim = requires(T &t) { t.claim(); };
static_assert(!HasAdopt<WriterRetirement> && !HasClaim<WriterRetirement>);

struct ThrowOnCopy {
  ThrowOnCopy() = default;
  ThrowOnCopy(const ThrowOnCopy &) { throw std::runtime_error("copy failed"); }
  void operator()() const {}
};

template <class F> bool refuses(F &&f) {
  try { f(); return false; } catch (...) { return true; }
}

int main() {
  bool ok = true;
  auto lease = ResourceDomainLease::acquireForOwner();
  lease.setAdmissionWitness([] { return true; });
  lease.setRequestDrainWitness([] { return true; });
  lease.setRetainedIoWitness([] { return true; });
  lease.setCallbackRetirementWitness([] { return true; });
  lease.check("owner before lend");
  auto proof = lease.obtainQuiescence();
  auto receipt = lease.lendToWriter();
  ok &= refuses([&] { lease.check("unclaimed owner"); });
  ok &= !lease.obtainQuiescence();
  ok &= refuses([&] { (void)lease.transferToWorker(std::move(*proof)); });
  bool unrelatedRefused = false;
  std::thread unrelated([&] { unrelatedRefused = refuses([&] { lease.check("unclaimed outsider"); }); });
  unrelated.join();
  ok &= unrelatedRefused;

  std::mutex mutex;
  std::condition_variable cv;
  bool claimed = false, release = false, writerPassed = false;
  auto capture = std::make_shared<int>(42);
  std::weak_ptr<int> retiredCapture = capture;
  receipt.launch([&, capture] {
    writerPassed = !refuses([&] { lease.check("writer"); });
    { std::lock_guard lock(mutex); claimed = true; }
    cv.notify_all();
    // The body is over; this gate represents the copied notifier.
    { std::unique_lock lock(mutex); cv.wait(lock, [&] { return release; }); }
  });
  capture.reset();
  ok &= refuses([&] { receipt.launch([] {}); });
  { std::unique_lock lock(mutex); cv.wait(lock, [&] { return claimed; }); }
  std::thread reaper([&] { receipt.join(); });
  ok &= writerPassed;
  ok &= refuses([&] { lease.check("active owner"); });
  ok &= !receipt.joined();
  ok &= !retiredCapture.expired();
  ok &= refuses([&] { lease.reclaimWriter(receipt); });
  std::thread other([&] { unrelatedRefused = refuses([&] { lease.check("active outsider"); }); });
  other.join();
  ok &= unrelatedRefused;
  { std::lock_guard lock(mutex); release = true; }
  cv.notify_all();
  reaper.join();
  ok &= refuses([&] { receipt.join(); });
  ok &= receipt.joined();
  ok &= retiredCapture.expired();
  bool wrongOwner = false;
  std::thread wrong([&] { wrongOwner = refuses([&] { lease.reclaimWriter(receipt); }); });
  wrong.join();
  ok &= wrongOwner;
  lease.reclaimWriter(receipt);
  ok &= !receipt.failure();
  lease.check("owner restored");
  ok &= refuses([&] { (void)lease.transferToWorker(std::move(*proof)); });
  ok &= refuses([&] { lease.reclaimWriter(receipt); });
  std::thread after([&] { unrelatedRefused = refuses([&] { lease.check("after outsider"); }); });
  after.join();
  ok &= unrelatedRefused;
  auto nextReceipt = lease.lendToWriter();
  ok &= refuses([&] { lease.reclaimWriter(receipt); });
  auto foreign = ResourceDomainLease::acquireForOwner();
  ok &= refuses([&] { foreign.reclaimWriter(nextReceipt); });
  bool secondPassed = false;
  nextReceipt.launch([&] { secondPassed = !refuses([&] { lease.check("second writer"); }); });
  std::thread secondReaper([&] { nextReceipt.join(); });
  secondReaper.join();
  ok &= secondPassed && nextReceipt.joined();
  ok &= refuses([&] { lease.reclaimWriter(receipt); });
  lease.reclaimWriter(nextReceipt);
  ok &= !nextReceipt.failure();
  auto failed = lease.lendToWriter();
  failed.launch([] { throw std::runtime_error("writer failure"); });
  std::thread failedReaper([&] { failed.join(); });
  failedReaper.join();
  lease.reclaimWriter(failed);
  ok &= static_cast<bool>(failed.failure());
  ok &= refuses([&] { std::rethrow_exception(failed.failure()); });
  auto unstarted = lease.lendToWriter();
  ThrowOnCopy throwing;
  ok &= refuses([&] { unstarted.launch(throwing); });
  ok &= refuses([&] { lease.reclaimWriter(unstarted); });
  lease.cancelUnstartedWriter(unstarted);
  lease.check("owner after launch failure");
  ok &= refuses([&] { unstarted.launch([] {}); });
  std::cout << (ok ? "writer authority passed\n" : "writer authority failed\n");
  return ok ? 0 : 1;
}
