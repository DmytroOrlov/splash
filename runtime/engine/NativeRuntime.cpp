#include "engine/NativeRuntime.hpp"
#include "AwakeClock.hpp"
#include "StderrLine.hpp"
#include "metal/MetalBackend.hpp"

#include <algorithm>
#include <chrono>
#include <iomanip>
#include <limits>
#include <stdexcept>
#include <memory>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

namespace splash::engine {

uint64_t systemUnixMicros() noexcept {
  const auto now = std::chrono::system_clock::now().time_since_epoch();
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::microseconds>(now).count());
}

NativeRuntime::NativeRuntime(NativeLoopConfig config, double idleReleaseSeconds,
                             engine::Cache &cache, WriteBehind &writeBehind,
                             model::Model &model,
                             ByteSink output, StatusProvider statusProvider,
                             protocol::ProtocolLimits limits)
    : config_(std::move(config)), idleReleaseSeconds_(idleReleaseSeconds),
      output_(std::move(output)),
      statusProvider_(std::move(statusProvider)), limits_(limits),
      parser_(limits_), writeBehind_(std::addressof(writeBehind)),
      core_(std::unique_ptr<engine::Engine>(
          new engine::Engine(config_.engine, cache, writeBehind, model,
                              *this))) {
  if (!output_ || !statusProvider_ || !config_.metrics ||
      !config_.weightAdmission || !config_.growthAdmission || !config_.unixMicros ||
      !config_.monotonicMilliseconds)
    throw std::invalid_argument("the native engine loop lacks a component it needs");
  if (!(idleReleaseSeconds_ > 0.0))
    throw std::invalid_argument("the idle release must be positive");
  if (auto issue = protocol::validateLimits(limits_))
    throw std::invalid_argument(issue->describe());
  // [Gate 1 / T019] The witnesses name this loop and the Cache it runs on once,
  // before any lease could be given them; the loop's teardown only disarms them.
  evidence_->loop = this;
  evidence_->cache = &cache;
  cache_ = &cache;
  idleSinceMilliseconds_ = config_.monotonicMilliseconds();
}

// [T024] The Engine-less shell: no Cache, WriteBehind or Model is borrowed, and
// none is invented. The control plane runs; inference reads stay absent until
// the owner's publishEngine (or tryPublishEngine) binds a real retained graph.
NativeRuntime::NativeRuntime(NativeLoopConfig config, double idleReleaseSeconds,
                             ByteSink output, StatusProvider statusProvider,
                             protocol::ProtocolLimits limits)
    : config_(std::move(config)), idleReleaseSeconds_(idleReleaseSeconds),
      output_(std::move(output)),
      statusProvider_(std::move(statusProvider)), limits_(limits),
      parser_(limits_) {
  // The Engine-less shell needs its output, status, metrics and clocks; the
  // weight/growth admissions belong to the retained graph's Engine paths,
  // which this config does not wire (no domain, no governor) and never consults
  // until an adoption (T033) supplies them with a real Engine.
  if (!output_ || !statusProvider_ || !config_.metrics ||
      !config_.unixMicros || !config_.monotonicMilliseconds)
    throw std::invalid_argument("the native engine loop lacks a component it needs");
  if (!(idleReleaseSeconds_ > 0.0))
    throw std::invalid_argument("the idle release must be positive");
  if (auto issue = protocol::validateLimits(limits_))
    throw std::invalid_argument(issue->describe());
  // A model-less shell carries no weights: absent-safe by T009's contract.
  config_.weights = nullptr;
  evidence_->loop = this;  // cache stays null: the retained-IO witness says
                          // "work remains", which no stale binding can clear.
  idleSinceMilliseconds_ = config_.monotonicMilliseconds();
}

bool NativeRuntime::receive(std::span<const uint8_t> bytes) {
  if (closeConnection_)
    return false;
  try {
    size_t offset = 0;
    while (offset < bytes.size() && !closeConnection_) {
      protocol::ParseStep step = parser_.consume(bytes.subspan(offset));
      offset += step.consumedBytes;
      if (step.issue)
        return handleIssue(std::move(*step.issue));
      if (!step.frame)
        continue;
      // The parser is already past a frame it yielded, so a request-scoped
      // decode failure leaves the frames behind it to be processed.
      const protocol::FrameType type = step.frame->type;
      auto decoded = protocol::decodeFrame(std::move(*step.frame), limits_);
      if (decoded) {
        if (!handle(*decoded.value))
          return false;
      } else if (type == protocol::FrameType::MaskResponse &&
                 decoded.issue->failureClass ==
                     protocol::FailureClass::RequestError) {
        if (!handleMaskIssue(std::move(*decoded.issue)))
          return false;
      } else {
        if (type == protocol::FrameType::Request &&
            telemetry_.contains(decoded.issue->requestId)) {
          decoded.issue->failureClass = protocol::FailureClass::ProtocolFatal;
        }
        if (!handleIssue(std::move(*decoded.issue)))
          return false;
      }
    }
  } catch (...) {
    executionFailed(std::current_exception());
    return false;
  }
  return !closeConnection_;
}

bool NativeRuntime::finishInput() {
  if (closeConnection_)
    return false;
  if (auto issue = parser_.finish()) {
    return handleIssue(std::move(*issue));
  }
  return true;
}

bool NativeRuntime::tick() {
  if (closeConnection_ || !engineHealthy_)
    return false;
  try {
    // The engine runs no request until its weights are back, taken back a
    // part per tick so that frames are answered between them. With no Engine
    // published (cold shell, or detached), the tick makes no progress.
    if (restoreStarted_)
      return restoreWeights();
    // With no Engine published (cold shell, or detached), the tick's progress
    // is the retained graph's own persistence service — otherwise its due
    // points and landed transfers would have nobody to run them.
    return core_ ? core_->tick(config_.monotonicMilliseconds())
                 : serviceRetainedPersistence();
  } catch (...) {
    executionFailed(std::current_exception());
  }
  return false;
}

bool NativeRuntime::serviceRetainedPersistence() {
  // No retained graph bound (a cold shell that never published one): no queue
  // to collect or settle. Under Worker/Parked ownership the same answer is
  // for a different reason: this thread may not reach the domain at all, so
  // the queue keeps its points, their order and their due times.
  if (!writeBehind_ || !cache_ || !resourceAuthorityHeld())
    return false;
  // A transfer that landed since the last pass first: its completion is what
  // woke this loop, and the point that started it settles only once it has.
  const bool landed = cache_->pollTransfers();
  // Then the queue's due points, in publication order, on this loop's clock.
  const bool settled = writeBehind_->run(config_.monotonicMilliseconds());
  return landed || settled;
}

bool NativeRuntime::runControl(const std::function<bool()> &control) {
  if (closeConnection_ || !engineHealthy_)
    return false;
  try {
    return control ? control() : false;
  } catch (...) {
    executionFailed(std::current_exception());
  }
  return false;
}

bool NativeRuntime::flushRestorePoints() {
  if (!engineHealthy_)
    return false;
  try {
    // [T028] Neither a Worker nor a Parked interval lets this thread reach the
    // domain at a clean stop: the flush defers, whether the queue is reached
    // through a published Engine or through the graph that outlived one, and
    // it lifts nothing. The caller's budget decides whether the stop waits
    // it out or reports it short; reclaiming terminal ownership is the
    // shutdown/recovery policy (T036), not this path's to invent.
    if (!resourceAuthorityHeld())
      return false;
    if (core_)
      return core_->flushRestorePoints();
    // No Engine published, but the retained graph's queue survives the
    // detach: the flush belongs to that queue, and answering "complete" here
    // would be a lie about durability. A cold shell that never bound a queue
    // has none to wait on.
    if (!writeBehind_)
      return true;
    static_cast<void>(cache_->pollTransfers());
    return writeBehind_->flush();
  } catch (...) {
    executionFailed(std::current_exception());
  }
  return false;
}

void NativeRuntime::releaseIdleWeights() {
  if (config_.monotonicMilliseconds() - idleSinceMilliseconds_ >=
          1000.0 * idleReleaseSeconds_ &&
      releaseWeights())
    logLine("Weights released after ", idleReleaseSeconds_,
            " s without a request; the next request restores them");
}

bool NativeRuntime::releaseWeights() {
  if (!config_.weights || config_.weights->released() || restoreStarted_ ||
      !core_ || !core_->idle())
    return false;
  config_.weights->release();
  return true;
}

bool NativeRuntime::restoreWeights() {
  if (!config_.weights)
    return true;
  bool restored = false;
  try {
    // Memory the requests waiting need: the host's margins do not hold it
    // back, critical pressure and the engine's limit refuse it. What they can
    // do without comes back only while the host has room to spare.
    const Serving serving(config_.engine.serving, !telemetry_.empty());
    restored = config_.weights->restore(config_.weightAdmission, config_.growthAdmission);
  } catch (const metal::MetalAllocationError &refusal) {
    return weightsRefused(refusal.failure());
  }
  restoreRefusedSince_.reset();
  if (!restored)
    return true;
  ++weightRestores_;
  const double now = config_.monotonicMilliseconds();
  idleSinceMilliseconds_ = now;
  logLine("Weights restored in ", std::fixed, std::setprecision(2),
          (now - *restoreStarted_) / 1000.0, " s");
  restoreStarted_.reset();
  return true;
}

// Admission refused the next part of the weights, which stays released. Once
// the resource wait limit has passed since the first refusal after the last
// part that came back, or at once when no request waits, the restore gives
// up: the weights give back the parts that came back, the requests waiting
// fail retryably, and the next request starts over.
bool NativeRuntime::weightsRefused(metal::AllocationFailure failure) {
  if (!telemetry_.empty()) {
    const double now = config_.monotonicMilliseconds();
    if (!restoreRefusedSince_) {
      restoreRefusedSince_ = now;
      logLine("Weights wait for memory to be restored: ",
              metal::allocationFailureName(failure));
    }
    if (now - *restoreRefusedSince_ <
        config_.engine.resourceWaitTimeoutMilliseconds)
      return false;
  }
  if (config_.weights)
    config_.weights->release();
  restoreStarted_.reset();
  restoreRefusedSince_.reset();
  if (telemetry_.empty()) {
    logLine("Weights not restored: no request waits for them");
    return true;
  }
  ++weightRestoreFailures_;
  std::vector<uint64_t> waiting;
  waiting.reserve(telemetry_.size());
  for (const auto &entry : telemetry_)
    waiting.push_back(entry.first);
  const std::string message = resourceTimeoutMessage(failure);
  logLine("Weights not restored, ", waiting.size(), " waiting request",
          waiting.size() == 1 ? "" : "s", " failed: ", message,
          "; the next request restores them");
  for (uint64_t id : waiting)
    core_->failRequest(id, LaneOutcome::ResourceTimeout, message);
  return true;
}

void NativeRuntime::executionFailed(std::exception_ptr failure) {
  if (config_.engineFailed)
    config_.engineFailed();
  try {
    std::rethrow_exception(failure);
  } catch (const metal::MetalBackendError &error) {
    config_.metrics->metalFailed();
    engineError("metal_execution_failed", error.what());
  } catch (const std::exception &error) {
    engineError("engine_execution_failed", error.what());
  } catch (...) {
    engineError("engine_execution_failed", "unknown engine exception");
  }
}

void NativeRuntime::announceReady() {
  if (closeConnection_ || !engineHealthy_) {
    throw std::logic_error("unhealthy engine cannot become ready");
  }
  if (ready_)
    throw std::logic_error("ready was already announced");
  if (!send(protocol::ReadyEvent{model::ExecutionLimits::maximumBatchWidth,
                                 config_.engine.maxContext,
                                 config_.engine.maxImagePatches != 0})) {
    throw std::runtime_error("failed to serialize ready event");
  }
  ready_ = true;
  // The idle release counts from here: warmup is not idleness.
  idleSinceMilliseconds_ = config_.monotonicMilliseconds();
}

// T011 (U-04): gather the loop's wake sources into one poll bound. Every
// source is an absolute point on the loop's monotonic clock: the Engine's
// next timed event (when an Engine is present), the retained persistence
// queue's next point falling due — or, for a step its write budget holds
// back, when that budget admits it again (WriteBehind::nextWakeup, a
// source that outlives any Engine), and a deferred restore retry, one
// backoff after this read. The earliest present point is converted to a
// nonnegative remaining duration once: already due wakes the transport
// at once (a zero poll timeout), and no source at all is no deadline.
std::optional<double> NativeRuntime::nextWakeupBoundMilliseconds(
    double now, std::optional<double> engineWakeup,
    std::optional<double> persistenceWakeup, bool restoreRetryDue) {
  std::optional<double> deadline;
  const auto consider = [&](std::optional<double> point) {
    if (point && (!deadline || *point < *deadline))
      deadline = point;
  };
  consider(engineWakeup);
  consider(persistenceWakeup);
  if (restoreRetryDue)
    consider(now + kResourceRetryBackoffMilliseconds);
  if (!deadline)
    return std::nullopt;
  return std::max(0.0, *deadline - now);
}

std::optional<double> NativeRuntime::millisecondsUntilNextWakeup() const {
  // [T028] The Engine's next event and the retained queue's next point belong
  // to the resource domain: while a residency Worker (or a parked completion)
  // holds that authority, this thread reads neither. The deferred restore retry
  // is this loop's own bookkeeping, so it stays. With both domain sources
  // withheld the poll goes unbounded, which is what the worker's completion or
  // control wake is expected to end — never a zero-timeout spin on an overdue
  // point this thread is not allowed to service.
  const bool authorityHeld = resourceAuthorityHeld();
  return nextWakeupBoundMilliseconds(
      config_.monotonicMilliseconds(),
      authorityHeld && core_ ? core_->nextWakeupMilliseconds()
                             : std::optional<double>{},
      authorityHeld && writeBehind_ ? writeBehind_->nextWakeup()
                                    : std::optional<double>{},
      restoreRefusedSince_.has_value());
}

engine::ResourceWaitSnapshot NativeRuntime::resourceWaitSnapshot() const {
  const double now = config_.monotonicMilliseconds();
  engine::ResourceWaitSnapshot wait =
      core_ ? core_->resourceWaitSnapshot(now) : engine::ResourceWaitSnapshot{};
  if (restoreRefusedSince_) {
    wait.memory += static_cast<uint32_t>(telemetry_.size());
    wait.oldestWaitMilliseconds =
        std::max(wait.oldestWaitMilliseconds, now - *restoreRefusedSince_);
  }
  return wait;
}

void NativeRuntime::closeAdmission() noexcept {
  std::lock_guard admission(admission_.mutex);
  admission_.inferenceReady = false;
}

void NativeRuntime::openAdmission() noexcept {
  std::lock_guard admission(admission_.mutex);
  admission_.inferenceReady = true;
}

bool NativeRuntime::admissionOpen() {
  std::lock_guard admission(admission_.mutex);
  return admission_.inferenceReady;
}

NativeRuntime::~NativeRuntime() {
  // [Gate 1 / T019] Disarm this loop's witnesses before anything else goes.
  // A lease whose authority outlives this loop keeps the four closures it was
  // given: from here each of them answers false rather than reaching a loop,
  // Engine or Cache that has gone. Nothing is destroyed or called back here.
  evidence_->detached.store(true, std::memory_order_release);
}

void NativeRuntime::bindHandoffWitnesses(ResourceDomainLease &lease) {
  // [Gate 1 proof / T019] One category per owner of that work, read through
  // this loop's binding, which the lease's closures keep alive and the loop's
  // teardown disarms. A category whose owner is gone says work remains, so a
  // stale binding can never mint a handoff: it is re-supplied at every safe
  // point, under the Owner interval this lease is bound to.
  const std::shared_ptr<HandoffEvidence> evidence = evidence_;
  // 1. Admission: the native gate itself, closed at the boundary a request
  //    frame would have to cross. A reopened gate refuses here.
  lease.setAdmissionWitness([evidence] {
    return !evidence->detached.load(std::memory_order_acquire) &&
           !evidence->loop->admissionOpen();
  });
  // 2. The request-side drain: the Engine's categories with this loop's own
  //    telemetry entries and owed mask responses folded in (T016).
  lease.setRequestDrainWitness([evidence] {
    return !evidence->detached.load(std::memory_order_acquire) &&
           evidence->loop->requestDrain().drained();
  });
  // 3. The retained graph's IO: the Cache this loop runs on — KV and spill
  //    writes, tier restores and batches, the state write and the transfers
  //    whose IO landed but whose poll has not run (T018).
  lease.setRetainedIoWitness([evidence] {
    return !evidence->detached.load(std::memory_order_acquire) &&
           evidence->cache && evidence->cache->retainedIoIdle();
  });
  // 4. Callbacks and descendants: the Engine's receipt (T017) over the GPU
  //    and host-step closures its backend still owes, the model's Neural
  //    Engine and ANE service work, and the bound completion notifier's seats
  //    and runs. Neither a completed ticket nor `Engine::idle()` stands in for
  //    this: it is read from the objects that hold the closures. With the
  //    Engine absent ([T024] detached shell) the closure owners are gone by
  //    construction — its destructor retired every callback and descendant
  //    before its memory went — so there is nothing owed here to wait on.
  lease.setCallbackRetirementWitness([evidence] {
    return !evidence->detached.load(std::memory_order_acquire) &&
           (!evidence->loop->core_ ||
            evidence->loop->core_->callbacksRetired());
  });
}

std::optional<Quiescence> NativeRuntime::prepareResourceHandoff(
    ResourceDomainLease &lease) {
  // [Gate 1 proof / FR-008, FR-009] Admission closes first, at the native
  // boundary: while the owner looks for work no new request may enter the
  // domain, and a refusal here leaves the gate closed and the lease in its
  // Owner interval, the requests the Engine already holds still owned. It
  // starts no drain, retires no callback, releases no residency and destroys
  // nothing: the four categories below are only what the owner observes.
  closeAdmission();
  bindHandoffWitnesses(lease);
  // The mint belongs to the lease: it evaluates the four outside its authority
  // mutex and re-checks its own mutation count under that mutex, so a category
  // that was never supplied, one that says work remains, or a domain mutation
  // since the look mints nothing. The proof returned is bound to that authority
  // and single-use; the transfer that follows is what consumes it.
  return lease.obtainQuiescence();
}

// [T024] Engine construction always binds valid, non-null Cache, WriteBehind
// and Model references: they belong to the retained graph and must outlive
// this loop and its Engine. Publishing over a published Engine is a defect
// and refused; the bindings (the persistence queue this Engine borrows and
// the handoff evidence's Cache) move with the Engine, and the loop's stored
// completion notifier rebinds onto it.
void NativeRuntime::publishEngine(engine::Cache &cache, WriteBehind &writeBehind,
                                  model::Model &model) {
  if (core_)
    throw std::logic_error("the native loop already publishes an Engine");
  // EngineEventSink is a private base: the upcast to Engine's sink reference
  // must be written in this class's own code, so the Engine is built with new
  // here, not make_unique.
  core_ = std::unique_ptr<engine::Engine>(
      new engine::Engine(config_.engine, cache, writeBehind, model, *this));
  writeBehind_ = std::addressof(writeBehind);
  evidence_->cache = &cache;
  cache_ = &cache;
  if (completionNotifier_)
    core_->setCompletionNotifier(completionNotifier_);
}

// [T024/T031] Adoption without consumption on rejection: refused when this
// shell already publishes an Engine, or the caller handed none. A refused
// adoption leaves the caller's unique_ptr holding its Engine, intact, for
// the caller to destroy in dependency order (the T031 rollback path); an
// accepted one binds it exactly like publishEngine, down to rebinding the
// stored completion notifier.
bool NativeRuntime::tryPublishEngine(
    std::unique_ptr<engine::Engine> &candidateEngine) {
  if (core_ || !candidateEngine)
    return false;
  // The candidate Engine binds its own Cache/WriteBehind/Model by Engine's
  // constructor contract (all must outlive it); this loop's retained-IO witness
  // and persistence-wake source belong to THOSE objects, and only a path that
  // knows them can rebind the bindings (T031's adoption rebinds them when
  // physical adoption into this shell's serving graph is wired). Until then
  // the bindings stay with whatever graph this shell was serving: an adopted
  // Engine never silently re-points the loop's witnesses at another graph's
  // Cache.
  core_ = std::move(candidateEngine);
  if (completionNotifier_)
    core_->setCompletionNotifier(completionNotifier_);
  return true;
}

// [T031 prerequisite] The candidate's private Engine, exactly as a graph start's
// own is built (its config, the Cache and persistence queue it borrows, the
// model it runs, this loop as the event sink) and nothing more: core_ is untouched,
// so the shell publishes no Engine it did not publish, opens no admission and
// rebinds none of its witnesses. A copy of the config is what the candidate's
// construction resolved against ITS OWN graph's governor (connectToGovernor) and
// spill plan, so one loop can serve a published Engine and a candidate Engine
// whose admissions answer to different graphs.
std::unique_ptr<engine::Engine>
NativeRuntime::makePrivateEngine(engine::EngineConfig config, engine::Cache &cache,
                                 WriteBehind &writeBehind, model::Model &model) {
  return std::unique_ptr<engine::Engine>(
      new engine::Engine(std::move(config), cache, writeBehind, model, *this));
}

// [T024 / FR-008, Gate 3 refusal path] The safe-point physical detach.
// Admission closes at the native boundary FIRST: the final native admission
// closes before Engine detachment, and a refusal leaves it closed. The three
// drain barriers are then read from their owners, the same categories the
// handoff witness set evaluates: this loop's request-side drain (T016), the
// retained graph's IO (T018) and the published Engine's callback/descendant
// retirement (T017). Any one standing refuses: null return, the published
// Engine and its bindings exactly as they were, nothing drained or destroyed
// here — the requests the Engine already holds stay owned and keep running.
// On success the Engine is MOVED out, not destroyed: the lifecycle's designated
// residency-worker disposal owns the physical destruction, under its claimed
// Worker interval, off this safe point. This loop then reads Engine-absent:
// the weight borrow it held into that residency goes null (T009 absence-safe
// paths), an in-flight weight restore has nothing left to restore, and the
// handoff witnesses no longer name a published Engine.
std::unique_ptr<engine::Engine> NativeRuntime::destroyEngine() {
  closeAdmission();
  if (!core_)
    return nullptr;  // already detached: nothing to move
  if (!requestDrain().drained())
    return nullptr;  // the request side still owns work
  if (!evidence_->cache || !evidence_->cache->retainedIoIdle())
    return nullptr;  // the retained graph still runs IO
  if (!core_->callbacksRetired())
    return nullptr;  // callbacks or descendants still owed
  auto detached = std::move(core_);
  // Nothing that could still reach the disposable stratum survives the
  // detach on this loop's side: the weights borrow and the restore state.
  config_.weights = nullptr;
  restoreStarted_.reset();
  restoreRefusedSince_.reset();
  return detached;
}

// [T031] The transactional adoption's refusal checks run first, and every
// one of them reads a live witness rather than a flag: an open gate, a
// published Engine, undrained telemetry/masks/restore state, an Engine that
// borrows a different graph than it names, an Owner predicate saying the
// domain is held elsewhere, a window over the ceiling or not positive, or
// missing weights/admissions/failure callback all refuse with the candidate
// untouched. Only after those does anything allocate (the rollback record,
// the config copy for the undo, the idle-clock read, and the WHOLE prepared
// completion-notifier binding — its shared body and three tracker seats —
// prepared on the CANDIDATE Engine before its ownership moves, so a throwing
// preparation still refuses with nothing staged). From the ownership move on
// it is swaps/moves of already-constructed values only: the Engine, its
// graph's pointers and the evidence's Cache, the complete graph-bound config
// (engine settings, weights, admissions, failure callback — while the
// shell's own output, parser, metrics, clocks and wake identity are carried
// over by the copy), fresh-residency timestamps and counters, and the
// notifier binding installed through Engine/Cache/StateCache's non-throwing
// prepared-binding install. What the displaced bindings are comes back out
// of that same install, held in the record until commit or rollback.
bool NativeRuntime::stageAdoption(NativeAdoptionInput &input, std::unique_ptr<StagedAdoption> &staged) {
  if (!input.engineSlot || !*input.engineSlot || core_ || admissionOpen())
    return false;
  if (!input.cache || !input.writeBehind)
    return false;
  engine::Engine &candidateEngine = **input.engineSlot;
  if (candidateEngine.borrowedCache() != input.cache || candidateEngine.borrowedWriteBehind() != input.writeBehind)
    return false;  // the Engine must borrow exactly the graph it names
  if (!input.authorityHeld || !input.authorityHeld())
    return false;
  const uint32_t adoptedContext = candidateEngine.maxContextTokens();
  if (!input.contextCeiling || !adoptedContext || adoptedContext > input.contextCeiling)
    return false;
  if (!input.weights || !input.weightAdmission || !input.growthAdmission || !input.engineFailed)
    return false;  // a model-bearing Engine needs them all
  if (!requestDrain().drained() || restoreStarted_.has_value() || restoreRefusedSince_.has_value())
    return false;  // telemetry, mask obligations and restores drained
  std::unique_ptr<StagedAdoption> record;
  engine::Engine::PreparedCompletionBinding prepared;
  const bool bindNotifier = completionNotifier_ != nullptr;
  double idleNow = 0.0;
  try {
    record = std::make_unique<StagedAdoption>();
    record->loop_ = this;
    record->previousCache_ = cache_;
    record->previousWriteBehind_ = writeBehind_;
    record->previousEvidenceCache_ = evidence_->cache;
    record->previousConfig_ = config_;
    record->previousIdleSince_ = idleSinceMilliseconds_;
    record->previousRestoreStarted_ = restoreStarted_;
    record->previousRestoreRefusedSince_ = restoreRefusedSince_;
    record->previousWeightRestores_ = weightRestores_;
    record->previousWeightRestoreFailures_ = weightRestoreFailures_;
    idleNow = monotonicMilliseconds();
    if (bindNotifier)
      prepared = candidateEngine.prepareCompletionBinding(completionNotifier_);
  } catch (...) {
    // Nothing has moved yet — this is the strong-rollback guarantee's front
    // half: a preparation failure is a plain refusal, and the candidate keeps
    // its Engine (never discarded for a notifier installation failure).
    return false;
  }
  // Staged. Nothing below this point may throw: all of it is moves and
  // swaps of already-constructed values, and the record now holds every
  // displaced binding the undo needs.
  record->notifierStaged_ = bindNotifier;
  core_ = std::move(*input.engineSlot);
  cache_ = input.cache;
  writeBehind_ = input.writeBehind;
  evidence_->cache = input.cache;
  config_.engine = std::move(input.engineConfig);
  config_.weights = input.weights;
  config_.weightAdmission = std::move(input.weightAdmission);
  config_.growthAdmission = std::move(input.growthAdmission);
  config_.engineFailed = std::move(input.engineFailed);
  idleSinceMilliseconds_ = idleNow;
  restoreStarted_.reset();
  restoreRefusedSince_.reset();
  weightRestores_ = 0;
  weightRestoreFailures_ = 0;
  if (record->notifierStaged_)
    record->displacedNotifier_ = core_->installCompletionBinding(std::move(prepared));
  staged = std::move(record);
  return true;
}

// [T031] The undo, called only with a staged record and outside every lifecycle
// lock: the staged Engine moves back out to its candidate (its borrows are
// alive, so it stays ownable), the shell's previous bindings — pointers,
// evidence Cache, whole config, timestamps and counters — are restored, and
// the displaced notifier slots go back through the SAME prepared-binding
// install (nonthrowing), never through setCompletionNotifier. The staged
// binding's copies land in the record and end with it.
std::unique_ptr<engine::Engine> NativeRuntime::rollbackAdoption(std::unique_ptr<StagedAdoption> &&stagedRef) noexcept {
  if (!stagedRef)
    return nullptr;
  StagedAdoption &staged = *stagedRef;
  auto engine = std::move(core_);
  core_.reset();
  cache_ = staged.previousCache_;
  writeBehind_ = staged.previousWriteBehind_;
  evidence_->cache = staged.previousEvidenceCache_;
  config_ = std::move(staged.previousConfig_);
  idleSinceMilliseconds_ = staged.previousIdleSince_;
  restoreStarted_ = staged.previousRestoreStarted_;
  restoreRefusedSince_ = staged.previousRestoreRefusedSince_;
  weightRestores_ = staged.previousWeightRestores_;
  weightRestoreFailures_ = staged.previousWeightRestoreFailures_;
  if (staged.notifierStaged_ && engine)
    static_cast<void>(engine->installCompletionBinding(std::move(staged.displacedNotifier_)));
  stagedRef.reset();
  return engine;
}

// [T031] Commit: the transaction's work is already installed and legal; this
// only drops the rollback record, ending the displaced previous bindings
// beside the graph the adopted Engine runs on.
void NativeRuntime::commitAdoption(std::unique_ptr<StagedAdoption> &&stagedRef) noexcept {
  stagedRef.reset();
}

bool NativeRuntime::handle(protocol::ClientMessage &message) {
  return std::visit(
      [&](auto &typed) -> bool {
        using T = std::decay_t<decltype(typed)>;
        if constexpr (std::is_same_v<T, protocol::RequestFrame>) {
          return handleRequest(typed);
        } else if constexpr (std::is_same_v<T, protocol::CancelFrame>) {
          return handleCancel(typed);
        } else if constexpr (std::is_same_v<T, protocol::MaskResponseFrame>) {
          return handleMask(typed);
        } else if constexpr (std::is_same_v<T, protocol::ReleaseRequestFrame>) {
          return handleRelease(typed);
        } else {
          return handleStatus(typed);
        }
      },
      message);
}

bool NativeRuntime::handleRequest(protocol::RequestFrame &request) {
  if (telemetry_.contains(request.requestId)) {
    return handleIssue({protocol::FailureClass::ProtocolFatal,
                        protocol::IssueCode::InvalidRequestId,
                        request.requestId, "request id is already active"});
  }
  // The final admission boundary: the gate's mutex is held from here through
  // `Engine::submit`, so closure and submission serialize on the actual handover
  // and exactly one of them wins. A closed gate answers the request its own
  // request-scoped frame, and nothing else happens for it: the Engine is not
  // reached, no telemetry, metrics, weight restore or keep-awake transition is
  // recorded, and framing, cancellation and control frames are untouched. The
  // requests already in the Engine keep their ownership; waiting for them is the
  // drain protocol's, not this boundary's.
  // The clocks are injectable callbacks: read them before the mutex is taken,
  // never under it, so a callback that reads or closes admission returns
  // instead of reentering the nonrecursive lock. The timestamps they give
  // are at worst marginally before the linearization point, which can only
  // shorten the deadline's remaining budget, never extend it.
  const uint64_t nowUnix = config_.unixMicros();
  const double nowMonotonic = config_.monotonicMilliseconds();
  std::optional<PendingPowerObservation::Guard> power;
  if (powerObservation_)
    power.emplace(*powerObservation_);
  std::unique_lock<std::mutex> admission(admission_.mutex);
  if (!admission_.inferenceReady || (power && (power->pending() || !power->allowsAdmission()))) {
    admission.unlock();
    if (power) power->unlock();
    requestError(request.requestId, "inference_unavailable",
                 "inference is unavailable");
    return true;
  }
  // [T024] With no Engine published the answer is the same frame for the
  // same reason: nothing may enter a domain the loop is not serving. (The
  // cold Battery/Unknown shell and the detached safe point keep the gate
  // closed anyway; this also refuses an open gate over an absent Engine.)
  if (!core_) {
    admission.unlock();
    if (power) power->unlock();
    requestError(request.requestId, "inference_unavailable",
                 "inference is unavailable");
    return true;
  }
  const uint64_t remaining =
      request.absoluteDeadlineUnixMicros > nowUnix
          ? std::min(request.absoluteDeadlineUnixMicros - nowUnix,
                     request.remainingDeadlineMicros)
          : 0;
  if (!remaining) {
    const LaneOutcomeWire deadline =
        laneOutcomeWire(LaneOutcome::DeadlineExceeded);
    admission.unlock();
    if (power) power->unlock();
    requestError(request.requestId, std::string(deadline.code),
                 std::string(kDeadlineExceededMessage), deadline.retryable);
    return true;
  }

  // The frame dies with this handler, so its large payloads (prompt
  // tokens, image pixels) move into the engine request. Error paths below
  // only read the request id.
  try {
    EngineRequest engineRequest;
    engineRequest.id = request.requestId;
    engineRequest.priority = request.priority;
    engineRequest.prompt = std::move(request.promptTokens);
    engineRequest.generationPromptTokens = request.generationPromptTokens;
    engineRequest.images = std::move(request.imageSpans);
    engineRequest.imagePixels = std::move(request.imagePixels);
    engineRequest.maxNewTokens = request.logicalMaxOutputTokens;
    engineRequest.scoreTokens = std::move(request.scoreTokens);
    engineRequest.sampling = request.sampling;
    engineRequest.constraint = request.constraint;
    engineRequest.flags = request.flags & kRequestFlagBits;
    engineRequest.thinkingBudget = request.thinkingBudget;
    engineRequest.cacheSalt = request.cacheSalt;
    engineRequest.returnProgress =
        request.flags & protocol::kReturnProgressFlag;
    engineRequest.deadlineMilliseconds =
        nowMonotonic + double(remaining) / 1000.0;
    core_->submit(std::move(engineRequest));
  } catch (const std::invalid_argument &error) {
    admission.unlock();
    if (power) power->unlock();
    requestError(request.requestId, "invalid_request", error.what());
    return true;
  }
  // The Engine's request and its native record commit as one unit: closure
  // cannot cut between the submission and the telemetry that answers for it.
  telemetry_.emplace(request.requestId,
                     RequestTelemetry{.arrivedMilliseconds = nowMonotonic});
  admission.unlock();
  if (power) power->unlock();
  if (telemetry_.size() == 1 && config_.holdingRequests)
    config_.holdingRequests(true);
  // Released weights are written back before the engine runs the request
  // (tick()); with no weights configured there is nothing to restore.
  if (config_.weights && config_.weights->released() && !restoreStarted_)
    restoreStarted_ = nowMonotonic;
  return true;
}

bool NativeRuntime::handleCancel(const protocol::CancelFrame &cancel) {
  // Cancel can arrive after the terminal event; it is then a no-op. With no
  // Engine published there is nothing to cancel either.
  if (core_ && telemetry_.contains(cancel.requestId))
    core_->cancel(cancel.requestId);
  return true;
}

bool NativeRuntime::handleMask(const protocol::MaskResponseFrame &mask) {
  if (!telemetry_.contains(mask.requestId)) {
    // A CPU mask calculation can finish after the request ends.
    return true;
  }
  if (!core_)
    return true;
  auto found = pendingMasks_.find(mask.requestId);
  if (found == pendingMasks_.end() ||
      found->second.maskRequestId != mask.maskRequestId ||
      found->second.expectedWords != mask.maskWords.size()) {
    core_->failRequest(mask.requestId, LaneOutcome::InvalidMask,
                       "mask response does not match the pending request");
    return true;
  }
  // Erased before the engine reads the mask: unusable contents fail the
  // request there, and its failure event erases the same entry.
  pendingMasks_.erase(found);
  core_->provideMask(mask.requestId, mask.maskWords);
  return true;
}

bool NativeRuntime::handleStatus(const protocol::StatusRequestFrame &status) {
  std::string json = statusProvider_();
  if (json.empty())
    throw std::runtime_error("empty status document");
  return send(protocol::StatusJsonEvent{status.correlationId, std::move(json)});
}

// The weights go back now, as at the end of the idle release, when the engine
// holds no request and no restore is under way, with the idle release on or
// off; otherwise nothing changes. The answer is the status document either way,
// whose weights section tells the caller which: `released` and not `restoring`
// when they are given back, as a restore leaves them `released` until its last
// image is written back.
bool NativeRuntime::handleRelease(const protocol::ReleaseRequestFrame &release) {
  if (releaseWeights())
    logLine("Weights released on request; the next request restores them");
  return handleStatus(protocol::StatusRequestFrame{release.correlationId});
}

bool NativeRuntime::handleMaskIssue(protocol::ProtocolIssue issue) {
  if (!telemetry_.contains(issue.requestId)) {
    // Once framing establishes the request id, ignore late mask responses
    // for requests that have already ended, including invalid mask contents.
    return true;
  }
  if (core_)
    core_->failRequest(issue.requestId, LaneOutcome::InvalidMask,
                       std::string(protocol::issueCodeName(issue.code)) + ": " +
                           issue.message);
  return !closeConnection_;
}

bool NativeRuntime::handleIssue(protocol::ProtocolIssue issue) {
  const protocol::FailureClass classification = issue.failureClass;
  if (classification == protocol::FailureClass::EngineUnhealthy) {
    engineError(std::string(protocol::issueCodeName(issue.code)),
                std::move(issue.message));
    return false;
  }
  send(protocol::ErrorEvent{
      classification,
      classification == protocol::FailureClass::RequestError ? issue.requestId
                                                             : 0,
      false, std::string(protocol::issueCodeName(issue.code)),
      std::move(issue.message)});
  if (protocol::connectionMustClose(classification)) {
    closeConnection_ = true;
    return false;
  }
  return true;
}

void NativeRuntime::requestError(uint64_t requestId, std::string code,
                                 std::string message, bool retryable,
                                 uint32_t retryAfterSeconds) {
  send(protocol::ErrorEvent{protocol::FailureClass::RequestError, requestId,
                            retryable, std::move(code), std::move(message),
                            retryAfterSeconds});
}

void NativeRuntime::engineError(std::string code, std::string message) {
  if (engineFailure_.empty())
    engineFailure_ = code + ": " + message;
  send(protocol::ErrorEvent{protocol::FailureClass::EngineUnhealthy, 0, false,
                            std::move(code), std::move(message)});
  engineHealthy_ = false;
  closeConnection_ = true;
}

bool NativeRuntime::send(const protocol::EngineEvent &event) {
  if (closeConnection_)
    return false;
  auto serialized = protocol::serializeEvent(event, limits_);
  if (!serialized) {
    // An event the engine cannot put on the wire is an engine defect. Report
    // it once and stop the stream, so the client sees the cause instead of a
    // later frame that contradicts the missing one.
    engineHealthy_ = false;
    closeConnection_ = true;
    if (engineFailure_.empty())
      engineFailure_ = "protocol_encode_failed: " + serialized.issue->message;
    auto report = protocol::serializeEvent(
        protocol::ErrorEvent{protocol::FailureClass::EngineUnhealthy, 0, false,
                             "protocol_encode_failed",
                             serialized.issue->message},
        limits_);
    if (report) {
      try {
        output_(*report.value);
      } catch (...) {
      }
    }
    return false;
  }
  std::string failure;
  try {
    output_(*serialized.value);
    return true;
  } catch (const std::exception &error) {
    failure = error.what();
  } catch (...) {
    failure = "unknown output exception";
  }
  if (engineFailure_.empty())
    engineFailure_ = "output_write_failed: " + failure;
  engineHealthy_ = false;
  closeConnection_ = true;
  return false;
}

void NativeRuntime::batchCompleted(WorkKind kind, uint32_t width,
                                   uint32_t inputTokens, uint32_t outputTokens,
                                   uint32_t draftedTokens,
                                   uint32_t acceptedDraftTokens,
                                   double wallMilliseconds,
                                   double cycleMilliseconds) {
  config_.metrics->batchCompleted(kind, width, inputTokens, outputTokens,
                                  draftedTokens, acceptedDraftTokens,
                                  wallMilliseconds, cycleMilliseconds);
}

void NativeRuntime::started(uint64_t requestId, uint32_t matchedTokens,
                            uint32_t lane) {
  RequestTelemetry &telemetry = telemetry_.at(requestId);
  telemetry.startedMilliseconds = config_.monotonicMilliseconds();
  const auto capacity = publishedContextTokens();
  if (!capacity || !*capacity)
    throw std::runtime_error("start event has no published Engine capacity");
  send(protocol::StartEvent{requestId, lane, matchedTokens, *capacity});
}

void NativeRuntime::promptProgress(uint64_t requestId,
                                   uint32_t processedTokens) {
  const auto &telemetry = telemetry_.at(requestId);
  send(protocol::PromptProgressEvent{
      requestId, processedTokens,
      durationMicros(telemetry.startedMilliseconds.value(),
                     config_.monotonicMilliseconds())});
}

engine::EngineSnapshot NativeRuntime::statusSnapshot() const {
  engine::EngineSnapshot result =
      core_ ? core_->snapshot() : engine::EngineSnapshot{};
  const double now = config_.monotonicMilliseconds();
  for (engine::ActiveRequestSnapshot &request : result.activeRequests)
    if (const auto found = telemetry_.find(request.id); found != telemetry_.end())
      request.ageMilliseconds = now - found->second.arrivedMilliseconds;
  return result;
}

void NativeRuntime::tokens(uint64_t requestId,
                           std::span<const uint32_t> values) {
  RequestTelemetry &telemetry = telemetry_.at(requestId);
  double now = config_.monotonicMilliseconds();
  if (!telemetry.firstTokenMilliseconds) {
    telemetry.firstTokenMilliseconds = now;
  }
  uint32_t offset = telemetry.emittedTokens;
  telemetry.emittedTokens += static_cast<uint32_t>(values.size());
  config_.metrics->tokens(telemetry.arrivedMilliseconds,
                          telemetry.lastTokenMilliseconds,
                          static_cast<uint32_t>(values.size()), now);
  telemetry.lastTokenMilliseconds = now;
  send(protocol::TokensEvent{
      requestId, offset, std::vector<uint32_t>(values.begin(), values.end())});
}

void NativeRuntime::maskRequested(uint64_t requestId,
                                  std::span<const uint32_t> simulationTokens) {
  if (pendingMasks_.contains(requestId)) {
    throw std::logic_error("request already has a pending token mask");
  }
  uint64_t maskRequestId = nextMaskRequestId_++;
  if (!maskRequestId)
    maskRequestId = nextMaskRequestId_++;
  const uint32_t wordsPerToken =
      model::maskWordsPerToken(config_.engine.vocabularySize);
  uint64_t maskRows = uint64_t(simulationTokens.size()) + 1;
  uint64_t expectedWords = uint64_t(wordsPerToken) * maskRows;
  if (!expectedWords || expectedWords > limits_.maxMaskWords) {
    throw std::length_error("token mask dimensions exceed wire limits");
  }
  pendingMasks_.emplace(requestId, PendingMask{maskRequestId, expectedWords});
  send(protocol::MaskRequestEvent{
      requestId, maskRequestId, wordsPerToken,
      std::vector<uint32_t>(simulationTokens.begin(), simulationTokens.end())});
}

void NativeRuntime::completed(uint64_t requestId, EngineFinishReason reason, bool bounded,
                              uint32_t promptTokens, uint32_t completionTokens,
                              uint32_t deduplicatedTokens,
                              std::span<const float> optionLogits,
                              const SpeculativeCounts &speculation) {
  RequestTelemetry &telemetry = telemetry_.at(requestId);
  double now = config_.monotonicMilliseconds();
  // A request that ends before it starts counts from its arrival.
  double started =
      telemetry.startedMilliseconds.value_or(telemetry.arrivedMilliseconds);
  double first = telemetry.firstTokenMilliseconds.value_or(now);
  send(protocol::DoneEvent{
      requestId, reason, promptTokens, completionTokens,
      durationMicros(started, first),
      telemetry.firstTokenMilliseconds ? durationMicros(first, now) : 0,
      durationMicros(telemetry.arrivedMilliseconds, now),
      std::vector<float>(optionLogits.begin(), optionLogits.end()),
      deduplicatedTokens, speculation, bounded});
  ended(requestId, now);
}

void NativeRuntime::failed(uint64_t requestId, LaneOutcome outcome,
                           std::string message, uint32_t retryAfterSeconds) {
  const LaneOutcomeWire wire = laneOutcomeWire(outcome);
  if (outcome == LaneOutcome::CapacityExhausted)
    config_.metrics->capacityFailed();
  requestError(requestId, std::string(wire.code), std::move(message),
               wire.retryable, retryAfterSeconds);
  ended(requestId, config_.monotonicMilliseconds());
}

void NativeRuntime::ended(uint64_t requestId, double now) {
  pendingMasks_.erase(requestId);
  telemetry_.erase(requestId);
  idleSinceMilliseconds_ = now;
  if (telemetry_.empty() && config_.holdingRequests)
    config_.holdingRequests(false);
}

uint64_t NativeRuntime::durationMicros(double startMilliseconds,
                                       double endMilliseconds) {
  if (endMilliseconds <= startMilliseconds)
    return 0;
  double micros = (endMilliseconds - startMilliseconds) * 1000.0;
  if (micros >= double(std::numeric_limits<uint64_t>::max())) {
    return std::numeric_limits<uint64_t>::max();
  }
  return static_cast<uint64_t>(micros);
}

} // namespace splash::engine
