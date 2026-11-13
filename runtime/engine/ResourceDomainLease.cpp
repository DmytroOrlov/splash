#include "engine/ResourceDomainLease.hpp"

#include "engine/MemoryGovernor.hpp"
#include "model/WeightMemory.hpp"

#include <algorithm>
#include <cassert>
#include <exception>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

namespace splash::engine {

thread_local const ResourceDomainAuthority *ResourceDomainAuthority::writerAuthority_ = nullptr;
thread_local uint64_t ResourceDomainAuthority::writerThreadGeneration_ = 0;

WriterRetirement ResourceDomainLease::lendToWriter() {
  if (!live_ || !authority_)
    refused("lend to writer");
  std::lock_guard lock(authority_->mutex_);
  if (authority_->holder_ != ResourceDomainAuthority::Holder::Owner ||
      authority_->boundThread_ != std::this_thread::get_id() ||
      authority_->admissionsInFlight_ || authority_->writerGeneration_ == UINT64_MAX)
    throw std::logic_error("writer lending requires the bound Owner");
  const auto generation = ++authority_->writerGeneration_;
  authority_->writerOwner_ = authority_->boundThread_;
  authority_->writerJoined_ = false;
  ++authority_->nextProof_;
  authority_->holder_ = ResourceDomainAuthority::Holder::Writer;
  authority_->boundThread_ = {};
  return WriterRetirement(authority_, generation);
}

WriterRetirement::~WriterRetirement() {
  // Emergency lifetime backstop; normal control paths use join on a reaper.
  if (writer_.joinable()) writer_.join();
}

void WriterRetirement::launch(std::function<void()> body) {
  if (!authority_ || !body)
    throw std::logic_error("invalid writer launch");
  auto result = std::make_shared<Result>();
  auto authority = authority_;
  const auto generation = generation_;
  // The trampoline cannot take this mutex until writer_ owns its thread.
  std::lock_guard lock(authority->mutex_);
  if (authority_->holder_ != ResourceDomainAuthority::Holder::Writer ||
      authority_->writerGeneration_ != generation_ ||
      authority_->writerOwner_ != std::this_thread::get_id() ||
      writer_.joinable() || result_)
    throw std::logic_error("only the lending Owner can launch once");
  writer_ = std::thread([authority, generation, result, body = std::move(body)]() mutable {
    {
      std::lock_guard gate(authority->mutex_);
      authority->boundThread_ = std::this_thread::get_id();
      ResourceDomainAuthority::writerAuthority_ = authority.get();
      ResourceDomainAuthority::writerThreadGeneration_ = generation;
    }
    try { body(); } catch (...) { result->failure = std::current_exception(); }
    // Destroy callable captures while the trampoline still holds authority.
    body = {};
    ResourceDomainAuthority::writerAuthority_ = nullptr;
    ResourceDomainAuthority::writerThreadGeneration_ = 0;
  });
  result_ = std::move(result);
}

void WriterRetirement::join() {
  if (!authority_)
    throw std::logic_error("invalid writer join");
  {
    std::lock_guard lock(authority_->mutex_);
    if (authority_->holder_ != ResourceDomainAuthority::Holder::Writer ||
        authority_->writerGeneration_ != generation_ || authority_->writerJoined_ ||
        joining_ || !writer_.joinable() ||
        authority_->writerOwner_ == std::this_thread::get_id() ||
        writer_.get_id() == std::this_thread::get_id())
      throw std::logic_error("join requires the claimed writer and a reaper");
    joining_ = true;
  }
  try {
    writer_.join();
  } catch (...) {
    std::lock_guard lock(authority_->mutex_);
    joining_ = false;
    throw;
  }
  std::lock_guard lock(authority_->mutex_);
  authority_->boundThread_ = {};
  authority_->writerJoined_ = true;
}

std::exception_ptr WriterRetirement::failure() const {
  if (!reclaimed_) throw std::logic_error("writer has not been reclaimed");
  return result_->failure;
}

bool WriterRetirement::joined() const {
  if (!authority_) return false;
  std::lock_guard lock(authority_->mutex_);
  return authority_->holder_ == ResourceDomainAuthority::Holder::Writer &&
         authority_->writerGeneration_ == generation_ && authority_->writerJoined_;
}

void ResourceDomainLease::reclaimWriter(WriterRetirement &receipt) {
  if (!live_ || !authority_ || receipt.authority_.get() != authority_.get())
    throw std::logic_error("foreign writer receipt");
  std::lock_guard lock(authority_->mutex_);
  if (authority_->holder_ != ResourceDomainAuthority::Holder::Writer ||
      authority_->writerGeneration_ != receipt.generation_ || !authority_->writerJoined_ ||
      authority_->writerOwner_ != std::this_thread::get_id())
    throw std::logic_error("writer has not joined or caller is not Owner");
  authority_->boundThread_ = authority_->writerOwner_;
  authority_->holder_ = ResourceDomainAuthority::Holder::Owner;
  ++authority_->nextProof_;
  receipt.reclaimed_ = true;
  receipt.authority_.reset();
}

void ResourceDomainLease::cancelUnstartedWriter(WriterRetirement &receipt) {
  if (!live_ || !authority_ || receipt.authority_.get() != authority_.get())
    throw std::logic_error("foreign writer receipt");
  std::lock_guard lock(authority_->mutex_);
  if (authority_->holder_ != ResourceDomainAuthority::Holder::Writer ||
      authority_->writerGeneration_ != receipt.generation_ ||
      authority_->writerOwner_ != std::this_thread::get_id() ||
      receipt.result_)
    throw std::logic_error("writer already started");
  authority_->boundThread_ = authority_->writerOwner_;
  authority_->holder_ = ResourceDomainAuthority::Holder::Owner;
  ++authority_->nextProof_;
  receipt.authority_.reset();
}

void ResourceDomainLease::check(std::string_view operation) const {
  if (!live_ || !authority_) refused("check authority");
  authority_->check(operation);
}

void ResourceDomainAuthority::throwRefusal(std::string_view operation) const {
  throw metal::MetalBackendError(
      std::string("resource-domain authority refused ") + std::string(operation) +
      ": only the current holder thread of the bound resource domain may perform "
      "it");
}

ResourceDomainAuthority::~ResourceDomainAuthority() {
  std::lock_guard lock(mutex_);
  for (auto *backend : backends_)
    backend->authority_ = nullptr;
  for (auto *governor : governors_)
    governor->authority_ = nullptr;
}

void ResourceDomainAuthority::attachBackend(metal::AuthorityBinding *backend) const {
  std::lock_guard lock(mutex_);
  if (backend->authority_ && backend->authority_ != this)
    throw std::logic_error(
        "MetalBackend is already bound to another resource domain's authority");
  for (auto *bound : backends_)
    if (bound == backend)
      return;
  backends_.push_back(backend);
  backend->authority_ = this;
}

void ResourceDomainAuthority::detachBackend(metal::AuthorityBinding *backend) const {
  std::lock_guard lock(mutex_);
  backends_.erase(std::remove(backends_.begin(), backends_.end(), backend),
                  backends_.end());
  if (backend->authority_ == this)
    backend->authority_ = nullptr;
}

void ResourceDomainAuthority::attachGovernor(MemoryGovernor *governor) const {
  std::lock_guard lock(mutex_);
  if (governor->authority_ && governor->authority_ != this)
    throw std::logic_error(
        "MemoryGovernor is already bound to another resource domain's authority");
  for (auto *bound : governors_)
    if (bound == governor)
      return;
  governor->authority_ = this;
  governors_.push_back(governor);
}

void ResourceDomainAuthority::detachGovernor(MemoryGovernor *governor) const {
  std::lock_guard lock(mutex_);
  governors_.erase(std::remove(governors_.begin(), governors_.end(), governor),
                   governors_.end());
  if (governor->authority_ == this)
    governor->authority_ = nullptr;
}

ResourceDomainLease ResourceDomainLease::acquireForOwner() {
  std::shared_ptr<const ResourceDomainAuthority> authority(
      new ResourceDomainAuthority());
  authority->boundThread_ = std::this_thread::get_id();
  return ResourceDomainLease(std::move(authority), true);
}

void ResourceDomainLease::attach(metal::AuthorityBinding &backend) const {
  if (!live_ || !authority_)
    refused("attach");
  authority_->attachBackend(&backend);
}

void ResourceDomainLease::attach(MemoryGovernor &governor) const {
  if (!live_ || !authority_)
    refused("attach");
  authority_->attachGovernor(&governor);
}

void ResourceDomainLease::setAdmissionWitness(std::function<bool()> witness) const {
  if (!live_ || !authority_)
    refused("supply a witness");
  setWitness(authority_->admissionWitness_, std::move(witness));
}

void ResourceDomainLease::setRequestDrainWitness(std::function<bool()> witness) const {
  if (!live_ || !authority_)
    refused("supply a witness");
  setWitness(authority_->requestDrainWitness_, std::move(witness));
}

void ResourceDomainLease::setRetainedIoWitness(std::function<bool()> witness) const {
  if (!live_ || !authority_)
    refused("supply a witness");
  setWitness(authority_->retainedIoWitness_, std::move(witness));
}

void ResourceDomainLease::setCallbackRetirementWitness(std::function<bool()> witness) const {
  if (!live_ || !authority_)
    refused("supply a witness");
  setWitness(authority_->callbackRetirementWitness_, std::move(witness));
}

void ResourceDomainLease::setWitness(
    std::function<bool()> &slot,
    std::function<bool()> witness) const {
  std::lock_guard lock(authority_->mutex_);
  if (authority_->holder_ != ResourceDomainAuthority::Holder::Owner ||
      authority_->boundThread_ != std::this_thread::get_id())
    refused("supply a witness");
  slot = std::move(witness);
  ++authority_->nextProof_;
}

std::optional<Quiescence> ResourceDomainLease::obtainQuiescence() const {
  if (!live_ || !authority_)
    refused("obtain a quiescence proof");
  const ResourceDomainAuthority *authority = authority_.get();
  uint64_t proof = 0;
  std::function<bool()> admission, request, retained, callbacks;
  {
    // Decide the mint under the mutex, but run no witness under it.
    std::lock_guard lock(authority->mutex_);
    if (authority->holder_ != ResourceDomainAuthority::Holder::Owner ||
        std::this_thread::get_id() != authority->boundThread_ ||
        !authority->admissionWitness_ || !authority->requestDrainWitness_ ||
        !authority->retainedIoWitness_ || !authority->callbackRetirementWitness_)
      return std::nullopt;
    proof = ++authority->nextProof_;
    admission = authority->admissionWitness_;
    request = authority->requestDrainWitness_;
    retained = authority->retainedIoWitness_;
    callbacks = authority->callbackRetirementWitness_;
  }
  const auto pass = [](const std::function<bool()> &witness) {
    if (!witness)
      return false;
    try {
      return witness();
    } catch (...) {
      return false;
    }
  };
  if (!pass(admission) ||
      !pass(request) ||
      !pass(retained) ||
      !pass(callbacks))
    return std::nullopt;
  std::lock_guard lock(authority->mutex_);
  if (authority->holder_ != ResourceDomainAuthority::Holder::Owner ||
      authority->boundThread_ != std::this_thread::get_id() ||
      authority->nextProof_ != proof || authority->admissionsInFlight_)
    return std::nullopt;
  Quiescence minted;
  minted.authority_ = authority_;
  minted.proof_ = proof;
  return minted;
}

WorkerHandoff ResourceDomainLease::transferToWorker(Quiescence &&proof) {
  if (!live_ || !authority_)
    refused("transfer authority");
  if (!proof.authority_ || proof.authority_.get() != authority_.get() || proof.spent_)
    throw std::logic_error(
        "transferToWorker needs an unspent quiescence proof of this authority");
  const ResourceDomainAuthority *authority = authority_.get();
  {
    std::lock_guard lock(authority->mutex_);
    if (authority->holder_ != ResourceDomainAuthority::Holder::Owner ||
        std::this_thread::get_id() != authority->boundThread_ ||
        proof.proof_ != authority->nextProof_ || authority->admissionsInFlight_)
      throw std::logic_error(
          "resource-domain authority transfers require the owner thread and "
          "a fresh quiescence proof minted at this safe point");
    proof.spent_ = true;
    proof.authority_ = nullptr;
    ++authority->nextProof_;
    authority->holder_ = ResourceDomainAuthority::Holder::Worker;
    authority->boundThread_ = std::thread::id();  // the worker claims its own
  }
  WorkerHandoff handedOff;
  handedOff.ownerHandle_ = this;
  handedOff.authority_ = authority_;
  return handedOff;
}

void ResourceDomainLease::returnToOwner(WorkerHandoff &&handedOff) {
  if (!live_ || !authority_)
    refused("return authority");
  const ResourceDomainAuthority *authority = authority_.get();
  const auto &token = handedOff.authority_;
  if (!token || token.get() != authority)
    throw std::logic_error(
        "returnToOwner was handed authority of another resource domain");
  {
    std::lock_guard lock(authority->mutex_);
    if (authority->holder_ != ResourceDomainAuthority::Holder::Parked)
      throw std::logic_error("returnToOwner requires a valid Parked token");
    ++authority->nextProof_;
    authority->holder_ = ResourceDomainAuthority::Holder::Owner;
    authority->boundThread_ = std::this_thread::get_id();
  }
  // The returned token is spent: the handle chain holds the authority again.
  handedOff.authority_.reset();
}

void WorkerHandoff::claim() {
  if (!authority_)
    throw std::logic_error("claim() on a moved-from worker handoff");
  std::lock_guard lock(authority_->mutex_);
  if (authority_->holder_ != ResourceDomainAuthority::Holder::Worker ||
      authority_->boundThread_ != std::thread::id{})
    throw std::logic_error("claim() requires an unclaimed Worker token");
  authority_->boundThread_ = std::this_thread::get_id();
}

WorkerHandoff WorkerHandoff::park() && {
  if (!authority_)
    throw std::logic_error("park() was called on a moved-from worker handoff");
  const ResourceDomainAuthority *authority = authority_.get();
  std::lock_guard lock(authority->mutex_);
  if (authority->holder_ != ResourceDomainAuthority::Holder::Worker ||
      authority->boundThread_ == std::thread::id{} ||
      authority->boundThread_ != std::this_thread::get_id() ||
      authority->admissionsInFlight_)
    throw std::logic_error(
        "park() needs the authority in the worker's hands, once per handoff");
  authority->holder_ = ResourceDomainAuthority::Holder::Parked;
  authority->boundThread_ = std::thread::id();
  return std::move(*this);
}

// The same handle-overwrite rule as the Owner handle: a live token is the
// only handle on a Worker or Parked interval, so assigning over it would
// strand that interval with no way to claim, park or return it. Both sides
// keep their tokens when the assignment is refused.
WorkerHandoff &WorkerHandoff::operator=(WorkerHandoff &&other) {
  if (authority_)
    throw std::logic_error(
        "worker handoff move assignment onto a handle that still holds authority: "
        "only an emptied token may take another's");
  if (this == &other)
    return *this;
  ownerHandle_ = other.ownerHandle_;
  authority_ = std::move(other.authority_);
  other.ownerHandle_ = nullptr;
  other.authority_.reset();
  return *this;
}

ResourceDomainLease::~ResourceDomainLease() {
  if (live_ && authority_) {
    assert(authority_->holder() == ResourceDomainAuthority::Holder::Owner &&
           "a resource domain's authority must return to its owner before the "
           "lease dies");
  }
  // The last handle takes the domain down, which unbinds every surface.
}

// A handle that still holds the authority is never assigned over: nothing of
// either side is consumed before the refusal, so both domains keep their
// handles, their attached surfaces and their holder interval. Moving into an
// emptied handle is how a test restores one, and stays exactly as valid as
// move construction: the same authority arrives and no surface is rebound.
ResourceDomainLease &ResourceDomainLease::operator=(ResourceDomainLease &&other) {
  if (live_ && authority_)
    refused("move-assign over a handle that still holds the authority");
  if (this == &other)
    return *this;
  authority_ = std::move(other.authority_);
  live_ = other.live_;
  other.live_ = false;
  other.authority_.reset();
  return *this;
}

ResourceDomainLease::ResourceDomainLease(ResourceDomainLease &&other) noexcept
    : authority_(std::move(other.authority_)), live_(other.live_) {
  other.live_ = false;
  other.authority_.reset();
}

void ResourceDomainLease::refused(std::string_view action) const {
  throw std::logic_error(std::string("resource-domain lease action (") +
                         std::string(action) +
                         ") on a handle that does not hold the authority");
}

ResourceDomainLease::ResourceDomainLease(
    std::shared_ptr<const ResourceDomainAuthority> authority, bool live) noexcept
    : authority_(std::move(authority)), live_(live) {}

} // namespace splash::engine
