#pragma once

#include "engine/Engine.hpp"
#include "engine/ModelResidency.hpp"
#include "engine/ResourceDomainLease.hpp"
#include "engine/Status.hpp"

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace splash::model { class RuntimeModel; }

namespace splash::engine {

class RuntimeResources;

// [T021] The ownership representation of one private recovery cycle: what a
// residency worker built or destroyed, the Worker-handoff token that carried
// the domain into that worker and back (the owner's own ResourceDomainLease is
// never duplicated or replaced by any of this), and the one mailbox the owner
// claims it from at a safe point. None of these types adopt, publish or reopen
// anything: physical adoption into serving residency is E's (T024/T033) and
// reaping of a superseded candidate is T032's; this header only carries
// ownership. The lifecycleRevision it records is what the owner fences on.

// What one destructive disposal reported: how much it gave back, what the
// domain reads allocated now, and how the pass ended. A worker that ran no
// physical release before T024 still reports the transfer it made.
struct DisposalReceipt final {
  bool complete = false;
  uint64_t releasedBytes = 0;
  std::optional<uint64_t> backendAllocatedBytesAfter;
  std::string detail;
};

// [T021/T029] The private candidate a recovery built, and WHICH graph its
// authority travels on. Declaration order is the reverse of destruction, so
// the Engine the candidate carries goes first, then the RuntimeModel (which
// owns the ModelResidency since T009), then a PRIVATE disposable ModelResidency
// when the candidate owns one separately, then a candidate-owned
// RuntimeResources: Engine -> RuntimeModel -> private residency ->
// candidate-owned RuntimeResources.
//
// [T029] Two distinct graph relationships, distinguished by identity rather
// than a flag a caller may flip:
//  - Cold: `resources` OWNS the graph the recovery assembled, its Metal
//    backend, governor and lease included. `borrowedResources` stays null.
//  - Warm: `resources` stays null and `borrowedResources` is the exact
//    retained RuntimeResources the candidate borrows; the candidate may own a
//    private ModelResidency of its own but never a replacement Cache/KV/
//    WriteBehind graph, and no shared ownership of RuntimeResources exists
//    anywhere in this type.
// Nothing here constructs either graph or hands one to a loop; physical
// adoption into serving residency is T024/T033's and reaping of a superseded
// candidate is T032's.
struct RecoveryCandidate final {
  std::unique_ptr<RuntimeResources> resources;
  std::optional<ModelResidency> residency;
  std::unique_ptr<model::RuntimeModel> model;
  std::unique_ptr<Engine> engine;
  uint64_t lifecycleRevision = 0;
  // The warm candidate's non-owning graph identity: the ORIGINAL retained
  // RuntimeResources whose Cache/KV/WriteBehind/backend this candidate borrows
  // while it owns its own disposable stratum. Null for a cold candidate.
  RuntimeResources *borrowedResources = nullptr;

  // [T029] The one graph whose lease this candidate's authority travels on:
  // the candidate-owned graph when cold, the borrowed retained graph when
  // warm. It never falls back to any other graph (a Bootstrap's retained
  // graph, for instance, is reached only by a caller that holds it): a cold
  // candidate answers with its own `resources` and nothing else.
  [[nodiscard]] RuntimeResources *authorityGraph() const noexcept {
    return resources ? resources.get() : borrowedResources;
  }
  // True only when the candidate carries its own RuntimeResources (and
  // therefore its own lease): the cold case. A warm candidate borrows, and
  // its authority came with the operation that ran on the retained graph.
  [[nodiscard]] bool ownsResources() const noexcept {
    return resources != nullptr;
  }
  // Whether the candidate still owns anything physical at all: the
  // reaper's eligibility test (T032), and the reason an empty synthetic
  // fixture is never treated as a production candidate.
  [[nodiscard]] bool ownsResidency() const noexcept {
    return engine || model || residency || resources;
  }

  RecoveryCandidate();
  RecoveryCandidate(const RecoveryCandidate &) = delete;
  RecoveryCandidate &operator=(const RecoveryCandidate &) = delete;
  RecoveryCandidate(RecoveryCandidate &&) noexcept;
  RecoveryCandidate &operator=(RecoveryCandidate &&) noexcept;
  ~RecoveryCandidate();
};

// The payload one residency-worker operation produced: at most one of a built
// candidate (recovery side) or a disposal receipt (suspension side).
struct WorkerOutcome final {
  std::unique_ptr<RecoveryCandidate> candidate;
  std::unique_ptr<DisposalReceipt> disposal;
  // [T029] A cold-first construction carries the token of the graph IT BUILT
  // (its own lease, transferred, claimed and parked on the construction thread)
  // out with its payload: a cold operation has no incoming token to park, and
  // a resource-owning candidate may never be published without it.
  std::optional<WorkerHandoff> handoff;
  // [T032] The one case where the operation's INCOMING token is ended inside
  // the task rather than parked by the worker's tail: a cold candidate's
  // reap returns that token to the candidate's own lease so the lease can die
  // on this thread. The worker must then not park a token it no longer holds.
  bool tokenConsumed = false;
};

// [T021] Exactly one completion envelope per residency-worker operation: the
// operation's captured lifecycleRevision, its payload if any, and the Worker
// handoff parked by the worker on the same domain (no second backend or
// governor authority anywhere in it), plus how it ended. Move-only through the
// WorkerHandoff; copying is refused at compile time.
struct CompletionEnvelope final {
  uint64_t lifecycleRevision = 0;
  std::unique_ptr<RecoveryCandidate> candidate;
  std::unique_ptr<DisposalReceipt> disposal;
  std::optional<WorkerHandoff> handedOff;
  bool failed = false;
  std::string failure;
  // [T029] Which graph the parked token belongs to, when the envelope's
  // payload does not itself say: a cold candidate names its own, but a
  // delegated reap that aborted cooperatively returns the candidate's token
  // with no candidate payload in its completion. Non-owning, and consulted
  // BEFORE the token is consumed (a mismatch fails closed and keeps the
  // token). Null means the operation ran on this Bootstrap's retained graph.
  RuntimeResources *tokenDomain = nullptr;

  CompletionEnvelope() = default;
  CompletionEnvelope(const CompletionEnvelope &) = delete;
  CompletionEnvelope &operator=(const CompletionEnvelope &) = delete;
  CompletionEnvelope(CompletionEnvelope &&) = default;
  CompletionEnvelope &operator=(CompletionEnvelope &&) = default;
  ~CompletionEnvelope() = default;
};

// [T021] The synchronized publish -> claim channel between one residency worker
// and the lifecycle owner. The worker PUBLISHES exactly one envelope (a second
// publish before the owner claims is a defect and refused), then wakes the
// control notifier; the owner CLAIMS it once, only at a safe point. The
// channel's mutex is the transfer's edge: everything the worker did to the
// domain before publishing is visible to the owner after claiming, and nothing
// in the envelope may be reached by the worker after the publish.
class CompletionChannel final {
 public:
  CompletionChannel() = default;
  CompletionChannel(const CompletionChannel &) = delete;
  CompletionChannel &operator=(const CompletionChannel &) = delete;

  // The control notifier the worker wakes after publishing; the transport's
  // existing controlNotifier, so a completed operation wakes the loop for its
  // next command-free point. Never called under the channel's lock.
  void setWake(std::function<void()> wake);

  // False when a completion already waits unclaimed: one envelope at a time.
  [[nodiscard]] bool publish(CompletionEnvelope &&envelope);

  // Takes the waiting completion out (move), empty when none landed.
  [[nodiscard]] std::optional<CompletionEnvelope> claim();

  [[nodiscard]] bool held() const noexcept;

  // The stored control notifier itself, taken under the channel's lock only
  // for the residency worker's TERMINAL bookkeeping: after it clears its own
  // running slot, this fresh wake (invoked by the worker outside every mutex,
  // never under the channel's or the worker's lock) gives the owner a safe
  // point at which the freed slot is visible. A publication that already
  // woke the owner while the worker still finished its own frame must not
  // leave the pump waiting for a wake that never comes.
  [[nodiscard]] std::function<void()> controlWake() const;

 private:
  mutable std::mutex mutex_;
  std::function<void()> wake_;
  std::optional<CompletionEnvelope> envelope_;
};

inline void CompletionChannel::setWake(std::function<void()> wake) {
  std::lock_guard lock(mutex_);
  wake_ = std::move(wake);
}

inline bool CompletionChannel::publish(CompletionEnvelope &&envelope) {
  std::function<void()> wake;
  {
    std::lock_guard lock(mutex_);
    if (envelope_.has_value())
      return false;  // one completion at a time
    envelope_ = std::move(envelope);
    wake = wake_;
  }
  // Outside the lock: the worker never runs a control callback under the
  // channel's edge.
  if (wake)
    wake();
  return true;
}

inline std::optional<CompletionEnvelope> CompletionChannel::claim() {
  std::lock_guard lock(mutex_);
  std::optional<CompletionEnvelope> claimed;
  claimed.swap(envelope_);
  return claimed;
}

inline bool CompletionChannel::held() const noexcept {
  std::lock_guard lock(mutex_);
  return envelope_.has_value();
}

inline std::function<void()> CompletionChannel::controlWake() const {
  // A copy of the notifier: read under the lock, invoked by the caller outside
  // it. Nothing runs here but the read.
  std::lock_guard lock(mutex_);
  return wake_;
}

// How a residency worker's task asks whether its own intent is still current
// (cooperative, revision-fenced cancellation): true once the lifecycle revision
// moved or the lifecycle shut down.
using WorkerCancellation = std::function<bool()>;

}  // namespace splash::engine
