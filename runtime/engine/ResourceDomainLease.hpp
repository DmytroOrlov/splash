#pragma once

#include "ResourceAuthority.hpp"

#include <cassert>
#include <cstdint>
#include <exception>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace splash::engine {

class MemoryGovernor;
class ResourceDomainLease;
class WriterRetirement;

// The exclusive authority of one resource domain: the Metal backend and the
// memory governor whose allocations share the engine's budget (and, once the
// rest of Workstream C lands, the KV tier, StateCache publication and budgeted
// disk writes bound through this same seam). Exactly one holder owns it at
// any instant, along the chain Owner → Worker → Parked → Owner. Every
// operation that mutates the domain's shared device/host memory or destructive
// storage state checks this authority at call time: an operation from any
// other thread, or a callback captured before a transfer, is refused while
// another holder holds. Passive reads (status, metrics, health, the governor's
// snapshot) never consult it, and an unbound backend or governor behaves
// exactly as upstream: the authority exists only where a lease bound it, and
// clearing a per-operation guard (MetalBackend::setOperationGuard) can neither
// install nor remove it.
//
// The holder is a token, never a flag: the lease cannot be copied, a moved-
// from handle refuses to act, and migrating Owner to Worker consumes a freshly
// minted Quiescence proof, obtainable only when every registered witness of
// all four contract categories (admission closure, request/engine drain,
// retained-state IO drain, callback/descendant retirement) says its category
// is at rest. Until a category's real witness is wired (T016-T019), its slot
// is unfilled and no proof mints; a fixture that supplies a witness is
// evidence for that fixture alone, and no caller can flip a "quiescence
// satisfied" bool.
//
// Each holder interval binds one thread: the Owner lease records the acquiring
// thread, a Worker interval binds only through WorkerHandoff::claim(), and returnToOwner rebinds
// the receiving thread; every flip is taken under the authority mutex, which
// is the transfer's synchronization edge. No GPU or model work and no witness
// callback ever runs under that mutex: witnesses are evaluated before the lock
// that flips the holder, and the check itself records only the thread and
// holder.
class ResourceDomainAuthority final : public metal::ResourceAuthority {
 public:
  enum class Holder : uint8_t { Owner, Worker, Parked, Writer };

  ResourceDomainAuthority(const ResourceDomainAuthority &) = delete;
  ResourceDomainAuthority &operator=(const ResourceDomainAuthority &) = delete;

  [[nodiscard]] Holder holder() const noexcept {
    std::lock_guard lock(mutex_);
    return holder_;
  }

  // The operation's witness: throws metal::MetalBackendError unless the
  // caller's thread holds the authority for the current holder interval. A
  // Parked or unclaimed Worker authority refuses every gated operation.
  [[noreturn]] void throwRefusal(std::string_view operation) const;
  void check(std::string_view operation) const override {
    std::lock_guard lock(mutex_);
    checkLocked(operation);
  }

 private:
  // Caller holds mutex_, so a successful check can be paired atomically with
  // an in-flight witness before any holder transition.
  void checkLocked(std::string_view operation) const {
    const std::thread::id caller = std::this_thread::get_id();
    if (holder_ == Holder::Owner) {
      if (caller != boundThread_)
        throwRefusal(operation);
      ++nextProof_;
      return;
    }
    if (holder_ == Holder::Worker && boundThread_ != std::thread::id{} &&
        caller == boundThread_) {
      ++nextProof_;
      return;
    }
    if (holder_ == Holder::Writer && boundThread_ == caller &&
        writerAuthority_ == this && writerThreadGeneration_ == writerGeneration_) {
      ++nextProof_;
      return;
    }
    throwRefusal(operation);
  }

 public:

  // Binds one MetalBackend to this authority (a backend already bound to a
  // different authority is refused; idempotent per backend), and unlinks a
  // surface being destroyed or unbound. Both sides clear their pointer once
  // the other is gone, so the protocol holds under either destruction order.
  void attachBackend(metal::AuthorityBinding *backend) const;
  void detachBackend(metal::AuthorityBinding *backend) const override;
  // The governor half, defined with MemoryGovernor's members.
  void attachGovernor(MemoryGovernor *governor) const;
  void detachGovernor(MemoryGovernor *governor) const;

  ~ResourceDomainAuthority();

 private:
  friend class ResourceDomainLease;
  friend class WorkerHandoff;
  friend class Quiescence;
  friend class WriterRetirement;
  friend class MemoryGovernor;
  friend class MemoryLedger;

  mutable std::mutex mutex_;
  mutable Holder holder_ = Holder::Owner;
  mutable std::thread::id boundThread_;  // {} while the interval is unbound
  mutable uint64_t nextProof_ = 0;
  mutable uint64_t admissionsInFlight_ = 0;
  mutable uint64_t writerGeneration_ = 0;
  mutable std::thread::id writerOwner_;
  mutable bool writerJoined_ = false;
  static thread_local const ResourceDomainAuthority *writerAuthority_;
  static thread_local uint64_t writerThreadGeneration_;
  mutable std::vector<metal::AuthorityBinding *> backends_;
  mutable std::vector<MemoryGovernor *> governors_;
  // The four contract witnesses; an unfilled slot never passes.
  mutable std::function<bool()> admissionWitness_;
  mutable std::function<bool()> requestDrainWitness_;
  mutable std::function<bool()> retainedIoWitness_;
  mutable std::function<bool()> callbackRetirementWitness_;

  ResourceDomainAuthority() = default;
};

// This handle alone can join the claimed thread and publish its receipt.
class WriterRetirement final {
 public:
  WriterRetirement(const WriterRetirement &) = delete;
  WriterRetirement &operator=(const WriterRetirement &) = delete;
  WriterRetirement(WriterRetirement &&) noexcept = default;
  WriterRetirement &operator=(WriterRetirement &&) = delete;
  ~WriterRetirement();
  void launch(std::function<void()> body);
  void join();
  [[nodiscard]] bool joined() const;
  [[nodiscard]] std::exception_ptr failure() const;
 private:
  friend class ResourceDomainLease;
  WriterRetirement(std::shared_ptr<const ResourceDomainAuthority> authority, uint64_t generation)
      : authority_(std::move(authority)), generation_(generation) {}
  std::shared_ptr<const ResourceDomainAuthority> authority_;
  uint64_t generation_;
  struct Result { std::exception_ptr failure; };
  std::shared_ptr<Result> result_;
  bool joining_ = false;
  bool reclaimed_ = false;
  std::thread writer_;
};

// A quiescence proof: minted only by obtainQuiescence(), move-only, single-
// use, bound to the authority that minted it.
class Quiescence final {
 public:
  Quiescence(const Quiescence &) = delete;
  Quiescence &operator=(const Quiescence &) = delete;
  Quiescence(Quiescence &&other) noexcept { *this = std::move(other); }
  Quiescence &operator=(Quiescence &&other) noexcept {
    if (this != &other) {
      authority_ = std::exchange(other.authority_, nullptr);
      proof_ = std::exchange(other.proof_, 0);
      spent_ = std::exchange(other.spent_, true);
    }
    return *this;
  }
  ~Quiescence() = default;

 private:
  friend class ResourceDomainLease;
  friend class ResourceDomainAuthority;

  Quiescence() = default;

  // Retain identity so a later domain cannot reuse a dead authority address.
  std::shared_ptr<const ResourceDomainAuthority> authority_;
  uint64_t proof_ = 0;
  bool spent_ = false;
};

// The authority in the worker's hands, and, once parked, in a completion
// envelope's: movable, never copyable; refused for every gated operation
// while Parked. Returning it to the owner is the only way out of a Parked
// interval (after the worker itself parks).
class WorkerHandoff final {
 public:
  WorkerHandoff(const WorkerHandoff &) = delete;
  WorkerHandoff &operator=(const WorkerHandoff &) = delete;
  WorkerHandoff(WorkerHandoff &&) = default;
  // Assigning onto a handle that still holds a token is refused before either
  // side is consumed: the overwritten token is the only way back out of a
  // Worker or Parked interval, so dropping it would orphan the authority
  // with no handle left to claim, park or return it. Assigning onto a
  // moved-from handle stays the supported way to restore one.
  WorkerHandoff &operator=(WorkerHandoff &&other);
  ~WorkerHandoff() = default;

  [[nodiscard]] ResourceDomainAuthority::Holder holder() const noexcept {
    return authority_ ? authority_->holder()
                      : ResourceDomainAuthority::Holder::Parked;
  }

  // Only possession of this token can bind the previously unclaimed Worker
  // interval. Ordinary resource access cannot claim it. Claims are one-shot.
  void claim();
  // The claimed worker ends its interval before publishing this Parked token.
  [[nodiscard]] WorkerHandoff park() &&;

 private:
  friend class ResourceDomainLease;
  friend class ResourceDomainAuthority;

  WorkerHandoff() = default;

  ResourceDomainLease *ownerHandle_ = nullptr;
  std::shared_ptr<const ResourceDomainAuthority> authority_;
};

// The Owner-side handle of the authority: acquired exactly once per resource
// domain and attached to every surface the domain covers. Noncopyable and
// move-only; a moved-from handle refuses to act, no operation may conjure an
// implicit lease of its own, and a live handle is never assigned over.
class ResourceDomainLease final {
 public:
  ResourceDomainLease(const ResourceDomainLease &) = delete;
  ResourceDomainLease &operator=(const ResourceDomainLease &) = delete;
  ResourceDomainLease(ResourceDomainLease &&other) noexcept;
  // Assigning onto a handle that still holds the authority is refused before
  // either side is consumed: the discarded handle is what its destructor
  // would have checked for a returned Owner interval and what unbinds the
  // surfaces this domain covers, so overwriting a live Owner, Worker or Parked
  // handle would destroy its authority unseen and leave a bound backend or
  // governor ungated. Assigning onto a moved-from handle stays supported.
  ResourceDomainLease &operator=(ResourceDomainLease &&other);
  // Asserts that the Owner interval ends with no holder-side work in progress
  // (a Worker or Parked interval outliving its handle is a defect), then
  // unbinds every surface this domain covers.
  ~ResourceDomainLease();

  // The only way a domain comes into being: bound to the acquiring thread as
  // the Owner interval's thread.
  [[nodiscard]] static ResourceDomainLease acquireForOwner();
  void check(std::string_view operation) const;

  // Binds a surface to this domain's authority; a surface already bound to a
  // different authority is refused. The bound surfaces consult the authority
  // on every gated operation afterwards, whatever any per-operation guard
  // their caller later sets.
  void attach(metal::AuthorityBinding &backend) const;
  void attach(MemoryGovernor &governor) const;

  [[nodiscard]] ResourceDomainAuthority::Holder holder() const noexcept {
    return authority_ ? authority_->holder()
                       : ResourceDomainAuthority::Holder::Parked;
  }

  // [T029/T032] Whether a token in hand belongs to THIS domain's authority
  // (passive: it consumes nothing and flips no holder). The owner consults it
  // before returnToOwner, so a token of another domain, a moved-from token or
  // a token already spent fails closed with the token intact instead of
  // reaching the consuming path.
  [[nodiscard]] bool tokenBelongs(const WorkerHandoff &token) const noexcept {
    if (!live_ || !authority_ || !token.authority_)
      return false;
    return token.authority_.get() == authority_.get();
  }

  // Supplies one of the four contract witnesses. The production wiring is
  // owed to T016-T019 (the admission gate, the Engine request drain,
  // StateCache/KV-tier IO receipts, the Metal/ANE retirement receipts); the
  // lease refuses to migrate authority until every category passes.
  void setAdmissionWitness(std::function<bool()> witness) const;
  void setRequestDrainWitness(std::function<bool()> witness) const;
  void setRetainedIoWitness(std::function<bool()> witness) const;
  void setCallbackRetirementWitness(std::function<bool()> witness) const;

  // Evaluates the witnesses outside the authority mutex. Null unless the
  // caller thread holds the Owner interval and all four categories pass.
  [[nodiscard]] std::optional<Quiescence> obtainQuiescence() const;

  // Owner to Worker: consumes one freshly minted proof of this authority.
  [[nodiscard]] WorkerHandoff transferToWorker(Quiescence &&proof);
  [[nodiscard]] WriterRetirement lendToWriter();
  void reclaimWriter(WriterRetirement &receipt);
  void cancelUnstartedWriter(WriterRetirement &receipt);
  // Parked back to Owner, on the thread that will serve again; rebinds the
  // Owner interval to that thread.
  void returnToOwner(WorkerHandoff &&handedOff);

 private:
  friend class WorkerHandoff;
  friend class ResourceDomainAuthority;

  std::shared_ptr<const ResourceDomainAuthority> authority_;
  bool live_ = false;  // false once moved from

  void setWitness(std::function<bool()> &slot,
                  std::function<bool()> witness) const;

  [[noreturn]] void refused(std::string_view action) const;

  ResourceDomainLease(std::shared_ptr<const ResourceDomainAuthority> authority,
                      bool live) noexcept;
};

} // namespace splash::engine
