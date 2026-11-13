#include "engine/Bootstrap.hpp"
#include "StderrLine.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <memory>
#include <sstream>
#include <thread>
#include <utility>
#include <unistd.h>
#include <time.h>

namespace splash::engine {
namespace {

bool residencyEvidenceEnabled() noexcept {
  const char *value = std::getenv("SPLASH_RESIDENCY_EVIDENCE");
  return value && std::string_view(value) == "1";
}

// Construct the snapshot while the Owner holds the domain, but write only
// after the lifecycle lock has been released. Logging cannot affect lifecycle.
struct ResidencyEvidence final {
  std::string line;
  ~ResidencyEvidence() { if (!line.empty()) logLine(line); }
  template <typename F> void capture(F &&write) noexcept {
    if (!residencyEvidenceEnabled()) return;
    try {
      std::ostringstream out;
      timespec now{};
      clock_gettime(CLOCK_UPTIME_RAW, &now);
      out << "[SPLASH_RESIDENCY_EVIDENCE] monotonic_us="
          << static_cast<uint64_t>(now.tv_sec) * 1000000 + now.tv_nsec / 1000
          << " pid=" << ::getpid() << ' ';
      write(out);
      line = out.str();
    } catch (...) {}
  }
};

// macOS counts the memory Metal frees as available only a moment later, 0.5
// to 1 s after Metal's own count drops on a 24 GB Mac mini. A start's last
// check of the host's reserve waits up to this long, checking again at this
// interval, for what the start gave back: the lanes its warmups left idle
// and the state of a warmup the host refused.
constexpr auto kMemoryReleaseWait = std::chrono::seconds(2);
constexpr auto kMemoryReleasePoll = std::chrono::milliseconds(100);

RuntimeBootstrapReport reportForPlan(const EngineMemoryPlan &plan) {
  RuntimeBootstrapReport report;
  report.budgetDescription = plan.breakdown().describe();
  return report;
}

RuntimeBootstrapReport
reportForResourceFailure(const RuntimeResourcesError &error) {
  RuntimeBootstrapReport report;
  report.resourceStage = error.stage();
  report.resourceFailure = error.failure();
  report.message = error.what();
  report.budgetDescription = error.budgetDescription();
  return report;
}

[[noreturn]] void fail(RuntimeBootstrapReport report,
                       RuntimeBootstrapStage stage, std::string message) {
  report.stage = stage;
  report.message = std::move(message);
  throw RuntimeBootstrapError(std::move(report));
}

} // namespace

std::string_view runtimeBootstrapStageName(RuntimeBootstrapStage stage) {
  switch (stage) {
  case RuntimeBootstrapStage::ResourceAssembly:
    return "resource_assembly";
  case RuntimeBootstrapStage::ModelCreation:
    return "model_creation";
  case RuntimeBootstrapStage::MaximumPrefill:
    return "maximum_prefill";
  case RuntimeBootstrapStage::DecodeWarmup:
    return "decode_warmup";
  case RuntimeBootstrapStage::CompositeStateRestore:
    return "composite_state_restore";
  case RuntimeBootstrapStage::MemoryAudit:
    return "memory_audit";
  case RuntimeBootstrapStage::AnnounceReady:
    return "announce_ready";
  case RuntimeBootstrapStage::Ready:
    return "ready";
  }
  return "unknown";
}

std::string RuntimeBootstrapReport::describe() const {
  std::ostringstream out;
  out << (stage == RuntimeBootstrapStage::Ready ? "runtime bootstrap ready"
                                                : "runtime bootstrap failed")
      << " [" << runtimeBootstrapStageName(stage);
  if (resourceStage)
    out << '/' << runtimeResourceStageName(*resourceStage);
  out << "]: " << message;
  if (!memoryAudit.message.empty()) {
    out << '\n' << memoryAudit.describe();
  }
  if (!budgetDescription.empty())
    out << '\n' << budgetDescription;
  return out.str();
}

RuntimeBootstrapError::RuntimeBootstrapError(RuntimeBootstrapReport report)
    : std::runtime_error(report.describe()), report_(std::move(report)) {}

RuntimeBootstrapError::RuntimeBootstrapError(const RuntimeResourcesError &error)
    : RuntimeBootstrapError(reportForResourceFailure(error)) {}

std::optional<StartupRetryWindow::Clock::time_point>
StartupRetryWindow::retryUntil(const RuntimeBootstrapReport &failure,
                               Clock::time_point now) {
  if (failure.resourceFailure != RuntimeResourceFailure::HostCapacity &&
      failure.resourceFailure != RuntimeResourceFailure::DriverAllocation)
    return std::nullopt;
  const std::pair reached{failure.stage, failure.resourceStage};
  if (!deadline_ || reached > reached_) {
    deadline_ = now + length_;
    reached_ = reached;
  }
  if (now >= *deadline_)
    return std::nullopt;
  return deadline_;
}

protocol::ProtocolLimits protocolLimitsFor(
    const model::ModelCapabilities &capabilities, uint32_t maxContext) noexcept {
  protocol::ProtocolLimits limits;
  limits.maxPromptTokens = maxContext;
  limits.maxLogicalOutputTokens = maxContext;
  limits.maxTokenBatch = model::ExecutionLimits::maximumStepTokens;
  limits.maxSimulationTokens = model::ExecutionLimits::draftQueryRows;
  limits.maxMaskWords = model::maskWordsPerToken(capabilities.vocabularySize) *
                        (model::ExecutionLimits::draftQueryRows + 1);
  return limits;
}

RuntimeBootstrap::RuntimeBootstrap(std::unique_ptr<RuntimeResources> resources,
                                   std::unique_ptr<model::RuntimeModel> modelRuntime,
                                   std::unique_ptr<NativeRuntime> nativeLoop,
                                   RuntimeBootstrapReport report,
                                   std::function<void()> lifecycleWake,
                                   uint32_t contextCeiling)
    : resources_(std::move(resources)), model_(std::move(modelRuntime)),
      nativeLoop_(std::move(nativeLoop)),
      report_(std::move(report)),
      // [T020] The lifecycle-owner pump begins at Ready over the graph start
      // built: with no power observation yet, the detached snapshot stays
      // fail-closed (lifecycleAuthorityEstablished_ false), the loop's
      // admission stays as start() left it (open), and pumpModelResident_
      // tracks the residency start loaded. lifecycleWake_ is the control
      // notifier; contextCeiling_ is what the loop serves, captured now for
      // the snapshot's effective context.
      lifecycleWake_(std::move(lifecycleWake)),
      contextCeiling_(contextCeiling) {
  // [T023] Memory-pressure control governs the retained domain; a model-less
  // cold shell has none, so it stays absent.
  if (resources_)
    memoryControl_.emplace(resources_->memoryGovernor(), resources_->backend(),
                           *nativeLoop_);
  // [T028] The loop's domain wake sources (Engine::nextWakeupMilliseconds,
  // WriteBehind::nextWakeup) and the clean-stop flush of a retained queue read
  // domain-owned mutable state, so they run only while this bootstrap's Owner
  // thread holds that authority. Bootstrap and its loop share one lifetime, and
  // the predicate is consulted only from the loop's own thread, so it cannot
  // dangle; a loop built without a bootstrap (a standalone fixture) keeps the
  // unbound, ordinary behavior.
  if (nativeLoop_)
    nativeLoop_->setResourceAuthorityHeld([this] { return resourceDomainHeld(); });
  lifecycleMailbox_.setWake(lifecycleWake_);
  sampleThermalState();
}

RuntimeBootstrap::~RuntimeBootstrap() {
  // [T022/T024] Shutdown first: an authoritative terminal intent invalidates
  // any in-flight residency-worker operation BEFORE teardown joins its thread.
  // Then join that worker, then claim and fence any completion that landed,
  // returning a parked token to this teardown thread so the domain's authority
  // ends in the Owner interval BEFORE ~ResourceDomainLease and before the
  // retained backend stops: a completion still held by the worker would
  // otherwise leave a mailbox envelope whose parked token is never returned.
  // Nothing here joins a still-running worker from a safe point; shutdownLifecycle()
  // is not a safe point, and the join is shutdown/teardown only.
  static_cast<void>(shutdownLifecycle());
  joinResidencyWorker();
  drainLifecycleMailbox();
  // A moved-out stratum whose delegated operation never started would be
  // impossible (the pump's slot fence rules it out); if one were ever held
  // here, its ownership ends on this teardown thread beside the still-retained
  // graph, before the backend stops.
  pendingDisposal_.reset();
  // [Hazard B] A retained envelope may own residency: an Engine/RuntimeModel/
  // RuntimeResources candidate that a recovery built but no adoption protocol
  // (T029-T033) could adopt. The mid-lifecycle reaper (T032) resolves that
  // ownership during a live lifecycle; whatever it has NOT reached at teardown
  // is disposed of honestly HERE: on this teardown thread, beside the still-
  // retained storage it was built against and BEFORE the retained backend
  // stops — in the candidate's declaration order (Engine -> RuntimeModel ->
  // private residency -> candidate-owned RuntimeResources), which is exactly
  // the order the reaper owes on the worker. A cold candidate's lease is an
  // Owner interval on this thread by now (its token landed at the shutdown
  // safe point), so its graph dies lawfully. The reap queue and the in-flight
  // reap payload are swept the same way; the refusal to adopt is recorded
  // out loud, never forgotten.
  if (pendingReap_)
    pendingReaps_.push_back(std::move(*pendingReap_));
  pendingReap_.reset();
  for (std::deque<CompletionEnvelope> *queue : {&pendingReaps_, &pendingEnvelopes_})
    for (CompletionEnvelope &envelope : *queue) {
      if (envelope.candidate && envelope.candidate->ownsResidency()) {
        logLine(
            "Shutdown resolves a retained recovery candidate that still owns "
            "residency: the recovery adoption protocol (T029-T033) never adopted "
            "it and the mid-lifecycle candidate reaper (T032) had not reached it "
            "yet, so its ownership ends on this teardown thread in the reaper's "
            "own order, beside the retained graph.");
        envelope.candidate.reset();
      }
    }
  pendingEnvelopes_.clear();
  pendingReaps_.clear();
  // Refuse new commands before the loop, the model and the resources they
  // reach are destroyed. (A model-less cold shell has none of them.)
  if (resources_)
    resources_->backend().stop();
}

std::string RuntimeBootstrap::statusJson(const RuntimeMetricsSnapshot &metrics,
                                         const NativeLoopTiming &loop) {
  // [T024/T025] The detached status: with no graph at all (a model-less cold
  // shell), with the model-bound stratum physically handed to the residency-
  // worker disposal, or while the Worker/parked interval (not this thread)
  // holds the resource domain, no retained-domain read is legitimate here.
  // The T014 emission states ownership and retained counts from this caller's
  // snapshot only — every loaded-model/Engine section null — and refuses
  // snapshots claiming residency or inference readiness, which is exactly the
  // pump view here: lifecycle.modelResident reports the PHYSICAL truth at this
  // observation (the stratum here is gone or going). The same state emits the
  // same bytes: nothing in this path measures live domain state.
  if (!resources_ || !model_ || !resourceDomainHeld()) {
    ResourceSnapshot snapshot;
    snapshot.lifecycle = lifecycleStatus();
    snapshot.lifecycle.modelResident = resources_ && model_ && resourceDomainHeld();
    snapshot.modelTelemetryAvailable = snapshot.lifecycle.modelResident;
    // Retained bytes stay zero: they are this observation's evidence, and this
    // observation never reaches the domain. backendAllocatedBytes stays the
    // default 0 for the same reason the T014 contract gives.
    // [T025] The resource-wait section is the explicit default too, NOT
    // nativeLoop_->resourceWaitSnapshot(): with the Worker interval (or a
    // parked completion) holding the domain, the Engine may still be PUBLISHED
    // on the loop — !resourceDomainHeld() does NOT imply core_ == nullptr, and
    // an injected-worker test path holds authority while leaving the Engine
    // there — so that read would traverse the Engine under another holder's
    // interval. A detached observation reports the domain as UNAVAILABLE
    // (all-zero), the same evidence the zero retained bytes state. The
    // Owner-held full path below keeps its live waits.
    return runtimeStatusJson(snapshot, metrics, lastPressure_,
                             snapshot.lifecycle.lastError,
                             engine::ResourceWaitSnapshot{});
  }
  // Status can arrive during GPU work; allocation/command boundaries and the
  // safe-point pressure monitor already refresh the cached sample.
  metal::MetalBackend &backend = resources_->backend();
  const bool healthy = backend.healthy();
  return runtimeStatusJson(
      resources_->memoryPlan(), nativeLoop_->statusSnapshot(), backend.memoryStats(),
      report_.warmup, report_.memoryAudit, metrics, model_->telemetry(),
      resources_->cacheIdentity(), resources_->memoryGovernor().snapshot(),
      healthy, healthy ? std::string{} : backend.unhealthyReason(),
      nativeLoop_->resourceWaitSnapshot(), loop, nativeLoop_->weightsSnapshot(),
      resources_->aneFfnSnapshot(), thermalState_.state(), resources_->streamedTableStats(),
      resources_->streamedExpertStats(), resources_->kvSpillStatus(), lifecycleStatus());
}

void RuntimeBootstrap::sampleThermalState() {
  const std::string transition = thermalState_.update(queryThermalState());
  if (!transition.empty())
    logLine(transition);
}

// [T020] A power callback's record, from any thread. Only the latest detached
// value is kept (a callback the owner has not yet reached supersedes an older
// one at the same safe point), and the wake is taken outside lifecycleMutex_
// so no callback runs under it. It starts nothing and touches no resource
// domain: the pump consumes the value at the next command-free point.
void RuntimeBootstrap::observePower(LifecyclePower power) {
  std::function<void()> wake;
  {
    std::lock_guard lock(lifecycleMutex_);
    // [T033] Every recorded observation advances the raw power generation,
    // whatever its value: an AC candidate's staging window that swallows a
    // Battery, or a Battery→AC pair whose stored final value matches the
    // applied power, is still visible at the final adoption fence. The pump
    // still mints a lifecycleRevision only when it CONSUMES a changed value.
    ++powerObservationGeneration_;
    pendingPower_ = power;
    wake = lifecycleWake_;
  }
  if (wake)
    wake();
}

[[nodiscard]] bool RuntimeBootstrap::shutdownLifecycle() {
  std::lock_guard lock(lifecycleMutex_);
  if (shutdownRequested_)
    return false;
  nativeLoop_->closeAdmission();
  shutdownRequested_ = true;
  // A terminal intent is a new revision and the Shutdown state: it supersedes
  // Draining, Suspended and Recovering, and an in-flight residency-worker
  // operation's cooperative cancel (which reads shutdownRequested_) sees it.
  ++lifecycleRevision_;
  state_ = LifecycleState::Shutdown;
  lifecycleAuthorityEstablished_ = true;
  pumpModelResident_ = false;
  publishLifecycle(true);
  return true;
}

LifecycleStatusSnapshot RuntimeBootstrap::lifecycleStatus() const {
  auto observation = powerObservation_ ? std::optional{powerObservation_->guard()} : std::nullopt;
  std::lock_guard lock(lifecycleMutex_);
  auto status = lifecycleSnapshotLocked();
  if (observation && (observation->pending() || !observation->allowsAdmission())) {
    status.inferenceReady = false;
    status.effectiveContextTokens.reset();
  }
  return status;
}

// [T020] One safe point on the owner thread. It consumes the queued power
// observation (minting a revision only on a power change) and steps the state
// machine, delegating every expensive step to the single residency worker.
void RuntimeBootstrap::advanceLifecycle() {
  // [Hazard C] One safe point, but the adoption seam must NOT run under
  // lifecycleMutex_: it re-enters the loop's own mutexes (publish/admission),
  // and holding the pump's lock while it runs would invert that order. The
  // claim, retain and fence happen under the lock; the seam call happens after
  // unlocking; only its RESULT is applied under a fresh lock.
  ResidencyEvidence evidence;
  std::unique_lock<std::mutex> lock(lifecycleMutex_);
  CompletionEnvelope *adoptEnvelope = nullptr;
  auto adoptAt = pendingEnvelopes_.end();
  bool productionAdoption = false;
  // [T033] The claim-time capture the final fence compares against: both the
  // lifecycle revision AND the raw power-observation generation.
  uint64_t capturedRevision = 0;
  uint64_t capturedGeneration = 0;

  // 1. Consume the observation: the lifecycle REVISION mints only on a power
  //    change, but the consumed observation always republishes the status
  //    ORDERING. [T034] A duplicate value (AC→AC, Battery→Battery, Unknown→
  //    Unknown) lands at a strictly newer observation sequence: while the
  //    mailbox held the sample, the same (revision, sequence) snapshot read
  //    fail-closed for inference, and a consumer that refuses to overwrite
  //    authority it already saw at one order would keep that negative snapshot
  //    in charge until some later power change. Only a changed value re-enters
  //    the state machine, and Shutdown is terminal: after it, no observation
  //    is consumed and no order is minted.
  if (pendingPower_.has_value() && !shutdownRequested_) {
    const LifecyclePower observed = *pendingPower_;
    pendingPower_.reset();
    if (observed != power_) {
      power_ = observed;
      ++lifecycleRevision_;
      lifecycleAuthorityEstablished_ = true;
    }
    // One increment per consumed observation, whatever its value: the changed
    // branch publishes here instead of separately, so a change is never
    // versioned twice by this step.
    publishLifecycle(true);
  }

  // 2. Terminal Shutdown: claim a completion that already landed (returning
  //    its parked token to this thread) and retain its ownership for the
  //    reaper; it never becomes residency and never reopens.
  if (shutdownRequested_) {
    if (lifecycleMailbox_.held()) {
      auto envelope = *lifecycleMailbox_.claim();
      returnHandoffToOwner(envelope);
      retainCompletionLocked(std::move(envelope));
    }
    return;
  }

  // With no authority yet there is nothing to advance: Ready serving continues
  // until the first observation, and a never-observed lifecycle stays fail-
  // closed in the detached snapshot.
  if (!lifecycleAuthorityEstablished_)
    return;

  switch (state_) {
    case LifecycleState::Ready:
      if (power_ != LifecyclePower::AC) {
        // Battery/Unknown: close native admission BEFORE draining, then start
        // the (delegated) disposal. Closing here is the pump's own observation
        // that inference must stop; the worker never touches admission.
        nativeLoop_->closeAdmission();
        drainDisposalStarted_ = false;
        state_ = LifecycleState::Draining;
        publishLifecycle(true);
      }
      return;

    case LifecycleState::Draining: {
      if (lifecycleMailbox_.held()) {
        auto envelope = *lifecycleMailbox_.claim();
        returnHandoffToOwner(envelope);
        if (envelope.lifecycleRevision != lifecycleRevision_ || envelope.failed) {
          const bool released = envelope.lifecycleRevision != lifecycleRevision_ &&
              power_ == LifecyclePower::AC && !envelope.failed &&
              envelope.disposal && envelope.disposal->complete &&
              !workerSeams_.dispose && resources_ && !model_ &&
              !resources_->modelResident() && !nativeLoop_->hasEngine() &&
              !pendingDisposal_;
          // Superseded or a failed disposal: retain ownership for the reaper;
          // stay Draining and retry the delegated drain at the next safe point.
          retainCompletionLocked(std::move(envelope));
          workerStarted_ = false;
          if (released) {
            pumpModelResident_ = false;
            state_ = LifecycleState::Suspended;
            publishLifecycle(true);
          }
          return;
        }
        // A current disposal envelope landed: the residency is gone (pump view),
        // the domain is back in the Owner interval, publish Suspended. The
        // envelope (its receipt) is retained like every other completion: the
        // pump never drops completions silently.
        if (envelope.disposal && envelope.disposal->complete && envelope.disposal->backendAllocatedBytesAfter && resources_ &&
            !workerSeams_.dispose) {
          evidence.capture([&](auto &out) {
            out << "phase=after_disposal lifecycle_revision=" << envelope.lifecycleRevision
                << " resource_graph_identity=" << resources_.get()
                << " cache_identity=" << &resources_->cache()
                << " write_behind_identity=" << &resources_->writeBehind()
                << " holder=Owner engine_published=" << nativeLoop_->hasEngine()
                << " model_resident=" << resources_->modelResident()
                << " disposal_complete=" << envelope.disposal->complete
                << " released_bytes=" << envelope.disposal->releasedBytes
                << " backend_allocated_bytes_after=" << *envelope.disposal->backendAllocatedBytesAfter;
          });
        }
        pendingEnvelopes_.push_back(std::move(envelope));
        pumpModelResident_ = false;
        workerStarted_ = false;
        state_ = LifecycleState::Suspended;
        publishLifecycle(true);
        return;
      }
      if (workerStarted_)
        return;  // the delegated disposal has not published yet
      // A newer AC intent can cancel a drain only while the published graph
      // is still intact. Once detachment or worker disposal starts, reconcile
      // the receipt and recover through the ordinary suspended path instead.
      if (power_ == LifecyclePower::AC && !drainDisposalStarted_ && !pendingDisposal_ && resources_ && model_ &&
          resources_->modelResident() && nativeLoop_->hasEngine() && resourceDomainHeld()) {
        state_ = LifecycleState::Ready;
        nativeLoop_->openAdmission();
        publishLifecycle(true);
        return;
      }
      // [T025 slot race] A completion claimed at THIS safe point can still
      // belong to a worker whose own frame has not ended: its publish woke
      // the control loop before running_ cleared, so workerStarted_ is already
      // false while the slot is still held. residencyWorker_.running() is
      // the worker's mutex-protected slot condition, checked BEFORE minting
      // any quiescence proof, detaching the stratum or transferring a
      // WorkerHandoff: a token moved into a start() that refuses would strand
      // the authority. Only this Owner thread starts operations (the pump
      // never starts a second while workerStarted_ is true, and no other
      // thread reaches start()), so once this check passes, nothing can take
      // the slot before this safe point's own start() call.
      if (residencyWorker_.running())
        return;  // the prior operation finished publishing but not its frame
      if (pumpModelResident_ && resourceDomainHeld()) {
        auto proof = nativeLoop_->prepareResourceHandoff(
            resources_->resourceAuthority());
        if (!proof)
          return;  // no quiescence at this safe point: nothing moved, retry
                   // at the next one
        if (proof) {
          // [T024] Production suspension detaches the stratum physically at
          // this safe point once the quiescence proof minted: the Engine out
          // of the loop (destroyEngine, which closes admission and reads the
          // drain barriers first), then the RuntimeModel and the residency
          // out of their owners — all MOVED into the disposal payload, none
          // destroyed here. A test seam that owns disposal (the T020-T022
          // delegation tests) keeps the previous move-nothing path.
          if (!workerSeams_.dispose) {
            evidence.capture([&](auto &out) {
              out << "phase=before_detach lifecycle_revision=" << lifecycleRevision_
                  << " resource_graph_identity=" << resources_.get()
                  << " cache_identity=" << &resources_->cache()
                  << " write_behind_identity=" << &resources_->writeBehind()
                  << " holder=Owner engine_published=" << nativeLoop_->hasEngine()
                  << " model_resident=" << resources_->modelResident()
                  << " backend_allocated_bytes_before="
                  << resources_->backend().memoryStats().allocatedBytes;
            });
            pendingDisposal_ = detachDisposalAtSafePoint();
            if (!pendingDisposal_) {
              evidence.line.clear();
              // A drain barrier stood between the witnesses and the detach
              // boundary: the proof is spent, nothing moved, the Engine and
              // graph exactly as they were, retry at the next safe point.
              return;
            }
          }
          auto token = resources_->resourceAuthority().transferToWorker(
              std::move(*proof));
          const uint64_t revision = lifecycleRevision_;
          if (startResidencyDisposal(std::move(token), revision)) {
            workerStarted_ = true;
            drainDisposalStarted_ = true;
            workerRevision_ = revision;
          } else {
            // start() refuses only while a running worker holds the slot, which
            // the running() gate above rules out at this same safe point: a
            // transferred-but-unstarted token would strand the authority, so
            // this cannot happen (only this Owner thread starts operations).
            return;
          }
        }
      } else {
        // Nothing resident to drain: go straight to Suspended.
        state_ = LifecycleState::Suspended;
        publishLifecycle(true);
      }
      return;
    }

    case LifecycleState::Suspended:
    case LifecycleState::RecoveryFailed:
      // [T032] A reap's completion lands here first: claim it, return its token
      // to the domain it ran on, retire the payload whose residency the worker
      // already ended (a cooperatively cancelled reap puts the candidate back
      // in the pending queue instead), and change no lifecycle state: reaping
      // is cleanup, not a serving transition.
      if (workerStarted_ && reapOperation_ && lifecycleMailbox_.held()) {
        auto envelope = *lifecycleMailbox_.claim();
        returnHandoffToOwner(envelope);
        // A reap that aborted cooperatively lands with its candidate INTACT,
        // and the retain below re-queues exactly what still owns physical
        // residency; a completed one lands with only its receipt.
        retainCompletionLocked(std::move(envelope));
        pendingReap_.reset();
        reapOperation_ = false;
        workerStarted_ = false;
        return;
      }
      if (workerStarted_)
        return;
      // [T025 slot race] The same slot condition as the Draining branch, applied
      // BEFORE the recovery proof mint / handoff transfer, before a cold
      // shell's no-token construction request (which shares the slot) and
      // before a delegated reap: a claimed completion whose worker has not
      // ended its own frame defers here, and that worker's terminal wake
      // brings the next safe point.
      if (residencyWorker_.running())
        return;
      // [T032] Pending reaping has priority over beginning another recovery
      // attempt: a stale candidate's ownership waits for this ONE worker, and
      // the pump never starts a construction while a reap is in flight (the
      // slot gate above and workerStarted_ below). A reaper that cannot obtain
      // a fresh proof leaves the candidate queued for a later safe point.
      if (!pendingReaps_.empty()) {
        if (startCandidateReaper(lifecycleRevision_)) {
          workerStarted_ = true;
          workerRevision_ = lifecycleRevision_;
          reapOperation_ = true;
        }
        return;
      }
      // Only AC rebuilds the disposable stratum; Battery/Unknown never
      // authorizes recovery. RecoveryFailed retries only on a fresh AC intent.
      if (power_ != LifecyclePower::AC)
        return;
      if (state_ == LifecycleState::RecoveryFailed && failedRecoveryGeneration_) {
        if (*failedRecoveryGeneration_ == powerObservationGeneration_)
          return;
        failedRecoveryGeneration_.reset();
        coldConstructionRequested_ = false;
      }
      if (!resources_) {
        // [T023] The model-less cold shell has no domain to transfer: an
        // AC intent requests ONE private residency-worker construction, with
        // no handoff token (nothing may borrow a domain this pump never
        // owned) and the cooperative revision fence still applied. Repeated
        // AC intents never ask twice; what the worker builds is retained
        // privately for the T029-T033 protocol.
        if (coldConstructionRequested_)
          return;
        coldConstructionRequested_ = true;
        state_ = LifecycleState::Recovering;
        publishLifecycle(true);
        const uint64_t revision = lifecycleRevision_;
        if (startColdResidencyConstruction(revision)) {
          workerStarted_ = true;
          workerRevision_ = revision;
        }
        return;
      }
      if (resourceDomainHeld()) {
        state_ = LifecycleState::Recovering;
        publishLifecycle(true);
        auto proof = nativeLoop_->prepareResourceHandoff(
            resources_->resourceAuthority());
        if (proof) {
          auto token = resources_->resourceAuthority().transferToWorker(
              std::move(*proof));
          const uint64_t revision = lifecycleRevision_;
          if (startResidencyConstruction(std::move(token), revision)) {
            workerStarted_ = true;
            workerRevision_ = revision;
          }
        } else {
          state_ = LifecycleState::Suspended;
          publishLifecycle(true);
        }
      }
      return;

    case LifecycleState::Recovering: {
      if (lifecycleMailbox_.held()) {
        auto envelope = *lifecycleMailbox_.claim();
        returnHandoffToOwner(envelope);
        workerStarted_ = false;
        const bool current = envelope.lifecycleRevision == lifecycleRevision_;
        const bool ac = power_ == LifecyclePower::AC;
        if (!current || !ac || envelope.failed || !envelope.candidate) {
          // Stale, superseded, failed or empty: never published into serving
          // residency; ownership retained for the reaper (T032), whose queue a
          // candidate that still owns anything physical moves into.
          lastLifecycleError_ =
              envelope.failed ? envelope.failure
              : (!envelope.candidate ? std::string("the residency worker returned no recovery candidate")
                                     : std::string("the recovery intent was superseded"));
          const bool failed = envelope.failed || !envelope.candidate;
          retainCompletionLocked(std::move(envelope));
          if (!ac || !current) {
            state_ = LifecycleState::Suspended;
            if (!current && !resources_)
              coldConstructionRequested_ = false;
            publishLifecycle(true);
          } else if (failed) {
            state_ = LifecycleState::RecoveryFailed;
            failedRecoveryGeneration_ = powerObservationGeneration_;
            publishLifecycle(true);
          }
          return;
        }
        // Current AC candidate: its ownership is retained here either way;
        // publishing into serving residency happens ONLY through an adoption
        // run OUTSIDE lifecycleMutex_ — [Hazard C]. A construction-seam
        // (fixture) candidate is not a production candidate and never enters
        // the real transaction; a production candidate goes through the two-
        // phase physical adoption (T031/T033).
        if (!workerSeams_.adopt) {
          if (workerSeams_.build) {
            // A construction-seam candidate: retained for the reaper exactly
            // as the T029/T032 protocol proved, never adopted. A cold model-
            // less shell records why this candidate cannot go ready.
            if (!resources_) {
              lastLifecycleError_ =
                  "the recovery adoption protocol (T029-T033) refuses a "
                  "construction-seam candidate: the built candidate is "
                  "retained";
              state_ = LifecycleState::RecoveryFailed;
              publishLifecycle(true);
            }
            retainCompletionLocked(std::move(envelope));
            return;
          }
          // [T031/T033] The real production transaction (two-phase, below):
          // capture both fence counters at the claim.
          capturedRevision = lifecycleRevision_;
          capturedGeneration = powerObservationGeneration_;
          pendingEnvelopes_.push_back(std::move(envelope));
          adoptAt = std::prev(pendingEnvelopes_.end());
          productionAdoption = true;
          break;
        }
        pendingEnvelopes_.push_back(std::move(envelope));
        adoptEnvelope = &pendingEnvelopes_.back();  // deque references are stable
        adoptAt = std::prev(pendingEnvelopes_.end());
        capturedRevision = lifecycleRevision_;
        capturedGeneration = powerObservationGeneration_;
        break;                                       // adopt outside the lock
      }
      // [T033] Reconcile an applied non-AC intent: a Recovering pump with no
      // operation in flight (only the production refusal path can rest here
      // while power has moved) goes Suspended rather than pretending inference
      // is ready. With an operation still running, the worker's cooperative
      // cancel and the claim fence above own it.
      if (!workerStarted_ && power_ != LifecyclePower::AC) {
        state_ = LifecycleState::Suspended;
        publishLifecycle(true);
      }
      return;
    }

    case LifecycleState::Shutdown:
      return;
  }

  if (!adoptEnvelope && !productionAdoption)
    return;
  // [Hazard C] Release the pump's lock for the phase that stages physical
  // state (or calls a test's adoption seam), then apply the result under a
  // fresh lock.
  lock.unlock();
  if (productionAdoption) {
    AdoptionStaging staging;
    uint64_t mailboxGeneration = 0;
    bool mailboxInitiallyEligible = true;
    if (powerObservation_) {
      auto observation = powerObservation_->guard();
      mailboxGeneration = observation.generation();
      mailboxInitiallyEligible = !observation.pending() && observation.allowsAdmission();
    }
    CompletionEnvelope &envelope = *adoptAt;
    // [T033] Phase 1 — physical staging on this Owner thread with admission
    // CLOSED, outside lifecycleMutex_. Roll back if any subsequent physical
    // staging operation, including cold serving initialization, throws.
    try {
      staging.stagedOk = stageAdoptionTransaction(envelope, staging);
    } catch (...) {
      rollbackAdoptionTransaction(staging);
      staging.stagedOk = false;
    }
    bool fencePass = staging.stagedOk;
    if (staging.stagedOk && stagingBoundaryTest_) {
      // [T033] The deterministic staging-boundary seam: after real staging,
      // before the fence, outside the lock. A throw here fails the fence; it
      // never leaves a half-published shell.
      try {
        stagingBoundaryTest_();
      } catch (...) {
        fencePass = false;
      }
    }
    if (staging.stagedOk && fencePass) {
      std::optional<PendingPowerObservation::Guard> observation;
      if (powerObservation_)
        observation.emplace(*powerObservation_);
      lock.lock();
      // [T033] Phase 2 — the final eligibility decision under lifecycle
      // synchronization, with the existing lifecycle/admission lock order.
      fencePass = (!observation || (mailboxInitiallyEligible &&
          !observation->pending() && observation->allowsAdmission() &&
          observation->generation() == mailboxGeneration)) &&
          finalAdoptionFenceOk(envelope, staging, capturedRevision, capturedGeneration);
      if (fencePass) {
        // PASS: finalize the transaction (drop the rollback record beside the
        // adopted graph), take the cold candidate's whole graph as this
        // Bootstrap's, clear the candidate from the pending adoption
        // bookkeeping, publish Ready with the exact adopted Engine context,
        // and open native admission once. No ReadyEvent is announced.
        nativeLoop_->commitAdoption(std::move(staging.staged));
        if (staging.cold && envelope.candidate->resources)
          resources_ = std::move(envelope.candidate->resources);
        pumpModelResident_ = true;
        lastLifecycleError_.clear();
        state_ = LifecycleState::Ready;
        nativeLoop_->openAdmission();
        pendingEnvelopes_.erase(adoptAt);
        publishLifecycle(true);
        if (resources_) evidence.capture([&](auto &out) {
          out << "phase=after_recovery lifecycle_revision=" << lifecycleRevision_
              << " resource_graph_identity=" << resources_.get()
              << " cache_identity=" << &resources_->cache()
              << " write_behind_identity=" << &resources_->writeBehind()
              << " holder=Owner engine_published=" << nativeLoop_->hasEngine()
              << " admission_open=" << nativeLoop_->admissionOpen()
              << " model_resident=" << resources_->modelResident()
              << " fence=accepted effective_published_context_tokens="
              << nativeLoop_->publishedContextTokens().value_or(0);
        });
      } else {
        lastLifecycleError_ =
            "the final adoption fence refused: the power intent, revision, "
            "observation generation, installed identity or capacity moved "
            "between staging and publication";
        publishLifecycle(true);
      }
      lock.unlock();
    }
    if (!fencePass) {
      if (staging.stagedOk)
        // [T031] Undo physical staging OUTSIDE lifecycleMutex_: no physical
        // destructor runs under it, and the WHOLE candidate returns intact.
        rollbackAdoptionTransaction(staging);
      lock.lock();
      if (adoptAt != pendingEnvelopes_.end()) {
        CompletionEnvelope &failed = *adoptAt;
        if (failed.candidate && failed.candidate->ownsResidency()) {
          // [T033] A restored candidate goes to the T032 reaper's queue
          // (a MOVE): the ONE worker disposes it at a later safe point.
          pendingReaps_.push_back(std::move(failed));
          pendingEnvelopes_.erase(adoptAt);
        }
      }
      lastLifecycleError_ = staging.stagedOk
          ? (staging.refusal.empty()
                 ? std::string("the staged adoption was refused before publication: the final fence saw a newer power intent, a shutdown or a moved identity")
                 : staging.refusal)
          : "the recovery adoption refused before staging: " + staging.refusal;
      if (!shutdownRequested_) {
        const bool newerAC = powerObservationGeneration_ != capturedGeneration &&
            pendingPower_.value_or(power_) == LifecyclePower::AC;
        state_ = (power_ != LifecyclePower::AC || newerAC)
            ? LifecycleState::Suspended : LifecycleState::RecoveryFailed;
        if (state_ == LifecycleState::RecoveryFailed)
          failedRecoveryGeneration_ = powerObservationGeneration_;
        if (newerAC && !resources_)
          coldConstructionRequested_ = false;
      }
      publishLifecycle(true);
      lock.unlock();
    }
    return;
  }
  if (!adoptEnvelope)
    return;
  bool adopted = false;
  std::string seamFailure;
  try {
    adopted = static_cast<bool>(workerSeams_.adopt(*adoptEnvelope->candidate));
  } catch (const std::exception &error) {
    seamFailure = error.what();
  } catch (...) {
    seamFailure = "the adoption seam threw an unknown exception";
  }
  lock.lock();
  if (!seamFailure.empty()) {
    lastLifecycleError_ = "the recovery adoption seam threw: " + seamFailure;
    publishLifecycle(true);
    return;
  }
  if (shutdownRequested_)
    return;
  if (adopted) {
    // [T033] A test-simulated adoption obeys the SAME final fence: a power
    // or shutdown observation that landed between the claim and publication
    // invalidates it, and `observationSequence_` is not the fence's witness —
    // the raw power-observation generation is.
    const bool fenceOk = !shutdownRequested_ && state_ == LifecycleState::Recovering &&
                         power_ == LifecyclePower::AC &&
                         !(pendingPower_.has_value() && *pendingPower_ != LifecyclePower::AC) &&
                         lifecycleRevision_ == capturedRevision &&
                         powerObservationGeneration_ == capturedGeneration;
    if (!fenceOk) {
      lastLifecycleError_ =
          "the final adoption fence refused the simulated adoption: a power "
          "or shutdown intent moved between the claim and publication";
      publishLifecycle(true);
      return;
    }
    pumpModelResident_ = true;
    state_ = LifecycleState::Ready;
    nativeLoop_->openAdmission();
    lastLifecycleError_.clear();
    publishLifecycle(true);
  }
}

bool RuntimeBootstrap::controlPass(MemoryPressure pressure) {
  sampleThermalState();
  // The pressure the monitor reported this pass: the pump's intent source,
  // and the detached status path's last-known value ([T025] legible with
  // the domain gone).
  lastPressure_ = pressure;
  // [T020] The pump advances at this command-free point on the owner thread.
  advanceLifecycle();
  // [T027] With no Engine published, nothing else services the retained graph's
  // persistence: a detached stratum leaves its due restore points, and the
  // transfers a started write's completion lands, with no tick to run them on.
  // This Owner safe point is where that work is collected, on the loop's own
  // monotonic clock (no second clock), through the loop's own retained-graph
  // bindings, which the detach keeps. A published Engine keeps Engine::tick's
  // responsibility; this pass never duplicates it. Under Worker/Parked ownership
  // neither the transfers nor the queue is touched, and a started asynchronous
  // write reports no settled point.
  bool retainedProgressed = false;
  if (resources_ && nativeLoop_ && !nativeLoop_->hasEngine() &&
      resourceDomainHeld())
    retainedProgressed = nativeLoop_->serviceRetainedPersistence();
  // The disk limit and the memory control pass mutate the resource domain, so
  // they run only while this thread holds its authority; a model-less cold
  // shell has no domain at all. While the residency worker (or a parked
  // completion) owns the domain they are skipped: the control pass stays a
  // detached observation (thermal sample, pump step, status).
  if (memoryControl_ && resourceDomainHeld()) {
    resources_->cache().keepDiskLimit();
    return memoryControl_->run(pressure) || retainedProgressed;
  }
  return retainedProgressed;
}

bool RuntimeBootstrap::resourceDomainHeld() noexcept {
  // No graph (cold shell) means no domain: nothing of the Owner's is held.
  if (!resources_)
    return false;
  return resources_->resourceAuthority().holder() ==
         ResourceDomainAuthority::Holder::Owner;
}

void RuntimeBootstrap::publishLifecycle(bool changed) {
  if (changed)
    ++observationSequence_;
  // The snapshot is rebuilt on every publish; observationSequence advances with
  // a meaningful state/power change, or with a power observation the pump
  // consumed, whatever its value ([T034]). The raw powerObservationGeneration_
  // stays a separate counter: it witnesses observations at record time, and
  // never versions a status the owner has not consumed.
}

LifecycleStatusSnapshot RuntimeBootstrap::lifecycleSnapshotLocked() const {
  LifecycleStatusSnapshot status;
  status.power = power_;
  status.revision = lifecycleRevision_;
  status.observationSequence = observationSequence_;
  status.controlReady = true;  // the control plane is always responsive
  status.configuredContextCeiling = contextCeiling_;
  status.lastError = lastLifecycleError_;
  if (!lifecycleAuthorityEstablished_) {
    // No power observation yet (and no shutdown): fail closed, claiming no
    // inference and no residency change.
    status.state = LifecycleState::RecoveryFailed;
    status.inferenceReady = false;
    status.modelResident = false;
    status.effectiveContextTokens = std::nullopt;
    return status;
  }
  status.state = state_;
  status.modelResident = pumpModelResident_;
  // [FR-002/FR-005] Inference readiness is minted only over a Ready lifecycle
  // on AC power with admission open and a live residency: Battery/Unknown
  // never authorizes it.
  // [T030] The capacity a Ready snapshot advertises is the EXACT published
  // Engine's window, never the ceiling this start captured: a recovery that
  // resolves a different context serves THAT one, and a Ready shell with no
  // Engine published claims no effective context at all (the invariant's
  // ceiling comparison still holds, the Engine's window being at most the
  // capability the configuration admits).
  const auto published =
      nativeLoop_ ? nativeLoop_->publishedContextTokens() : std::nullopt;
  status.inferenceReady =
      state_ == LifecycleState::Ready && power_ == LifecyclePower::AC &&
      pumpModelResident_ && nativeLoop_->admissionOpen() && published.has_value();
  status.effectiveContextTokens =
      status.inferenceReady ? published : std::nullopt;
  return status;
}

// publishLifecycle stores nothing beyond the sequence; the detached snapshot
// is rebuilt on demand by lifecycleStatus()/advanceLifecycle callers. Kept
// as a method so the pump's one place that advances observationSequence_
// is explicit (FR-024: the pump is the sequence's only source).
// [T029] The destination is the envelope's REAL domain, chosen BEFORE the token
// is consumed: the token belongs to whichever graph the operation ran on —
// a cold candidate's own RuntimeResources (its own lease), a warm completion's
// (or a plain disposal's) RETAINED graph — never to whichever graph this
// Bootstrap happens to hold. An envelope that carries no candidate names its
// domain explicitly (a reap that aborted cooperatively returns the candidate's
// token with no candidate payload). A missing domain, or a token that belongs
// to no live graph, fails closed: the sole WorkerHandoff stays intact in the
// envelope, the pump records the error, and nothing is consumed, so the
// authority can still be claimed, parked or returned by its token later.
void RuntimeBootstrap::returnHandoffToOwner(CompletionEnvelope &envelope) {
  if (!envelope.handedOff)
    return;
  RuntimeResources *graph = envelope.tokenDomain;
  if (!graph && envelope.candidate)
    graph = envelope.candidate->authorityGraph();
  if (!graph)
    graph = resources_.get();
  if (!graph || !graph->resourceAuthority().tokenBelongs(*envelope.handedOff)) {
    lastLifecycleError_ =
        "the completion's parked token belongs to no live resource domain: "
        "the authority stays held by its token and was not consumed";
    publishLifecycle(true);
    return;
  }
  graph->resourceAuthority().returnToOwner(std::move(*envelope.handedOff));
  envelope.handedOff.reset();
}

// [T029] The candidate-specific four categories, supplied to the CANDIDATE's
// own lease on the thread that holds it as Owner (the construction thread at
// the handoff, this pump's Owner thread at a reap). Each category reads the
// object that OWNS that work, never a constant:
//  1. Ingress/admission: nothing may enter the private candidate's domain.
//     The only boundary that could feed it is this shell's gate, and this
//     task never publishes a candidate Engine into the shell: the witness
//     reads the gate itself plus whether this exact Engine is published.
//  2. The candidate Engine's request-side drain (T016's receipt), or no
//     Engine at all (none has ever accepted a request).
//  3. The CANDIDATE's own Cache's retained IO (T018's receipt).
//  4. The candidate Engine's callback/descendant retirement (T017's
//     receipt), or nothing to retire when it has no Engine: its closure
//     owners are absent by construction.
// The closures outlive only their graph: a cold lease dies with the candidate
// it owns, and every evaluation of these categories happens while some live
// holder of that same lease is at an Owner interval. A fixture may supply
// controlled categories to exercise one refusal at a time; the lease still
// mints nothing unless all four pass.
void RuntimeBootstrap::bindCandidateHandoffWitnesses(
    ResourceDomainLease &lease, RecoveryCandidate &candidate) {
  if (workerSeams_.candidateWitnesses) {
    workerSeams_.candidateWitnesses(lease, candidate);
    return;
  }
  engine::Engine *engine = candidate.engine.get();
  engine::Cache *cache =
      candidate.resources ? &candidate.resources->cache() : nullptr;
  NativeRuntime *loop = nativeLoop_.get();
  lease.setAdmissionWitness([loop, engine] {
    if (engine)
      return !loop->admissionOpen() && !loop->publishes(*engine);
    return !loop->admissionOpen();
  });
  lease.setRequestDrainWitness([engine] {
    return !engine || engine->requestDrain().drained();
  });
  lease.setRetainedIoWitness([cache] {
    return cache && cache->retainedIoIdle();
  });
  lease.setCallbackRetirementWitness([engine] {
    return !engine || engine->callbacksRetired();
  });
}

// [T029/T032] The cold candidate's own authority transfer, on the thread
// that built (or owns) its graph, exactly once per interval: identify the
// candidate's lease, install its witnesses, mint a fresh proof from that
// lease, transfer to Worker, claim on this same thread, park, and hand the
// parked token to the operation's outcome so the published envelope carries
// candidate and token together. A warm candidate does nothing here: its
// domain came with the operation's incoming token, and it may never obtain a
// second independent authority. Refusal is fail-closed: the candidate is
// disposed of while this thread still lawfully holds its Owner interval (the
// lease dies seeing Owner), and the operation publishes a failure — never a
// resource-owning candidate lacking its mandatory token.
void RuntimeBootstrap::handoffColdCandidateOnWorker(
    RecoveryCandidate &candidate, WorkerOutcome &outcome) {
  RuntimeResources *graph = candidate.authorityGraph();
  if (!candidate.ownsResources()) {
    // Warm: the exact retained graph must be the one this operation is
    // running on, and the candidate adds no authority of its own.
    if (graph && graph != resources_.get())
      throw std::logic_error(
          "a warm candidate borrowed a resource graph other than this "
          "bootstrap's retained one");
    return;
  }
  ResourceDomainLease &lease = graph->resourceAuthority();
  if (lease.holder() != ResourceDomainAuthority::Holder::Owner)
    throw std::logic_error(
        "the cold candidate's own authority is not in an Owner interval on "
        "the construction thread");
  bindCandidateHandoffWitnesses(lease, candidate);
  auto proof = lease.obtainQuiescence();
  if (!proof) {
    // Refuse the handoff: end the candidate's ownership under the authority
    // this thread already holds, in the mandatory order, and report why.
    candidate.engine.reset();
    candidate.model.reset();
    candidate.residency.reset();
    candidate.resources.reset();
    throw std::runtime_error(
        "the cold candidate's own four witnesses refused quiescence at the "
        "construction handoff: its ownership ended under its own Owner "
        "interval and no candidate was published");
  }
  auto token = lease.transferToWorker(std::move(*proof));
  token.claim();
  // No domain-borrowing work follows the build: what the candidate carries
  // was assembled before this point, under this thread's Owner interval.
  outcome.handoff = std::move(token).park();
}

// [T032] One MOVE, no destructor: a completion whose candidate still owns
// anything physical leaves the retained bookkeeping for the serial reaper;
// everything else stays retained as before.
void RuntimeBootstrap::retainCompletionLocked(CompletionEnvelope &&envelope) {
  if (envelope.candidate && envelope.candidate->ownsResidency())
    pendingReaps_.push_back(std::move(envelope));
  else
    pendingEnvelopes_.push_back(std::move(envelope));
}

// [T031] Phase 1 of the production adoption transaction, run on the pump's
// Owner thread with admission CLOSED and lifecycleMutex_ RELEASED. It checks
// every identity the transaction depends on BEFORE anything moves: the
// candidate's Engine must be the one that borrows exactly THIS graph (Cache
// and WriteBehind identity), its window must be positive and within the
// immutable configured ceiling, a warm candidate must borrow THIS retained
// graph and carry a private residency the adoption gate proves against the
// graph's own identity while the published slot stays EMPTY (an adoption
// never replaces a live stratum), a cold candidate must be the whole graph
// with no graph retained here, and that graph's lease must be an Owner interval
// THIS thread holds. Input allocations precede the warm residency move;
// NativeRuntime prepares its own rollback record before moving the Engine.
// Cold serving initialization can throw, so its caller rolls the transaction
// back outside lifecycleMutex_ before handing the candidate to the reaper.
bool RuntimeBootstrap::stageAdoptionTransaction(CompletionEnvelope &envelope, AdoptionStaging &staging) {
  if (!envelope.candidate || !envelope.candidate->ownsResidency()) {
    staging.refusal = "the production adoption candidate owns no recovery residency";
    return false;
  }
  RecoveryCandidate &candidate = *envelope.candidate;
  staging.candidate = &candidate;
  const bool cold = candidate.ownsResources();
  staging.cold = cold;
  engine::Engine *engine = candidate.engine.get();
  model::RuntimeModel *candidateModel = candidate.model.get();
  RuntimeResources *graph = candidate.authorityGraph();
  if (!engine || !candidateModel || !graph || !nativeLoop_) {
    staging.refusal = "the adoption candidate carries no Engine, model or graph";
    return false;
  }
  if (nativeLoop_->hasEngine()) {
    staging.refusal = "the shell already publishes an Engine";
    return false;
  }
  const uint32_t adoptedContext = engine->maxContextTokens();
  if (!adoptedContext) {
    staging.refusal = "the candidate Engine enforces no positive context window";
    return false;
  }
  if (adoptedContext > contextCeiling_) {
    staging.refusal = "the candidate Engine's window (" + std::to_string(adoptedContext) +
                      ") is above the configured ceiling (" +
                      std::to_string(contextCeiling_) + ")";
    return false;
  }
  if (cold) {
    if (resources_ || model_) {
      staging.refusal = "a cold adoption ran where the Bootstrap already retains a graph or model";
      return false;
    }
    if (graph != candidate.resources.get()) {
      staging.refusal = "the cold candidate's authority graph is not the RuntimeResources it owns";
      return false;
    }
  } else {
    if (!resources_ || candidate.borrowedResources != resources_.get() || graph != resources_.get()) {
      staging.refusal = "the warm candidate does not borrow exactly this Bootstrap's retained graph";
      return false;
    }
    if (!candidate.residency) {
      staging.refusal = "the warm adoption candidate carries no private residency";
      return false;
    }
    if (model_ || resources_->modelResident()) {
      staging.refusal = "an incompatible or already-published residency would be replaced";
      return false;
    }
    if (!resources_->canAdoptModelResidency(*candidate.residency, resources_->cacheIdentity())) {
      staging.refusal = "the candidate residency does not match this graph's identity and geometry";
      return false;
    }
  }
  if (graph->resourceAuthority().holder() != ResourceDomainAuthority::Holder::Owner) {
    staging.refusal = "the active Owner does not hold the candidate graph's authority";
    return false;
  }
  if (engine->borrowedCache() != &graph->cache() || engine->borrowedWriteBehind() != &graph->writeBehind()) {
    staging.refusal = "the candidate Engine does not borrow exactly the graph it names";
    return false;
  }
  NativeRuntime::NativeAdoptionInput input;
  input.engineSlot = &candidate.engine;
  input.engineConfig = engine->borrowedConfig();
  input.cache = &graph->cache();
  input.writeBehind = &graph->writeBehind();
  input.weightAdmission = graph->memoryGovernor().allocationAdmission();
  input.growthAdmission = graph->memoryGovernor().growthAdmission();
  input.engineFailed = [graph] { graph->engineFailed(); };
  input.authorityHeld = [graph] {
    return graph->resourceAuthority().holder() == ResourceDomainAuthority::Holder::Owner;
  };
  input.contextCeiling = contextCeiling_;
  // [T031] The residency slot goes first for a warm candidate: the adoption
  // gate re-proves the check above, and the graph's releasable weights are
  // only this graph's once the private stratum is installed in it. Moving
  // ModelResidency never moves its internals, so the identity below is stable.
  if (!cold) {
    if (!resources_->adoptModelResidency(std::move(*candidate.residency), resources_->cacheIdentity())) {
      // The gate proved yes at the check; nothing else runs on this thread
      // between the two. Refuse with everything still intact.
      staging.refusal = "the residency adoption gate refused after staging";
      return false;
    }
    staging.residencyMoved = true;
    candidate.residency.reset();
  }
  ReleasableMemory *releasable = cold ? candidate.resources->releasableMemory()
                                       : resources_->releasableMemory();
  if (!releasable) {
    if (staging.residencyMoved) {
      candidate.residency.emplace(resources_->releaseModelResidency());
      staging.residencyMoved = false;
    }
    staging.refusal = "the adoption graph holds no releasable weights";
    return false;
  }
  input.weights = releasable;
  if (!nativeLoop_->stageAdoption(input, staging.staged)) {
    if (staging.residencyMoved) {
      candidate.residency.emplace(resources_->releaseModelResidency());
      staging.residencyMoved = false;
    }
    staging.refusal =
        "the native shell refused the staged adoption (admission open, an Engine "
        "already published, undrained telemetry/masks/restores, mismatched bindings, "
        "an unheld authority predicate, or a preparation failure)";
    return false;
  }
  // A later fence failure or serving initialization exception returns every
  // moved part through rollbackAdoptionTransaction below.
  model_ = std::move(candidate.model);
  staging.model = model_.get();
  staging.modelMoved = true;
  staging.engine = engine;
  staging.graph = graph;
  if (cold) {
    // [T031] Cold-only deliberate ordering: the new graph's memory control
    // binds to ITS governor/backend/loop now, and its persistent tier's
    // serving mark and probation begin now — off the pump lock, while this
    // Owner thread lawfully holds the graph. A warm adoption touches neither:
    // this Bootstrap's control already governs the retained graph and its
    // tier opened when that graph first started.
    // The construction-only guard captures the worker revision. As with the
    // ordinary startup path, retire it before serving; keep the configured
    // shutdown interrupt instead of retaining that obsolete worker predicate.
    graph->backend().setOperationGuard({});
    graph->backend().setWaitInterrupt(recoveryConfig_->resources.cancelled);
    memoryControl_.emplace(graph->memoryGovernor(), graph->backend(), *nativeLoop_);
    graph->beginServing();
  }
  staging.stagedOk = true;
  return true;
}

// [T031] The transaction's undo, outside every lock: the staged Engine moves
// back to its candidate (never destroyed for a publication failure), the
// RuntimeModel and the adopted residency return, the cold graph's memory
// control resets, and NativeRuntime restores the whole previous shell —
// pointers, evidence Cache, config, timestamps and the displaced notifier
// slots through the SAME non-throwing prepared-binding install. Every retained
// object keeps its original address; nothing physical is destroyed here, and
// the caller moves the restored candidate into the reaper's queue afterwards.
void RuntimeBootstrap::rollbackAdoptionTransaction(AdoptionStaging &staging) noexcept {
  if (!staging.candidate)
    return;
  if (staging.staged)
    staging.candidate->engine = nativeLoop_->rollbackAdoption(std::move(staging.staged));
  if (staging.modelMoved)
    staging.candidate->model = std::move(model_);
  if (staging.residencyMoved && resources_)
    staging.candidate->residency.emplace(resources_->releaseModelResidency());
  if (staging.cold)
    memoryControl_.reset();
}

// [T033] The complete final eligibility fence, evaluated by the pump under
// lifecycleMutex_ after phase 1 staged the candidate physically. Every
// staging-window race is caught here: a Battery intent, a Battery→AC pair whose
// stored value matches the applied power (the raw power-observation generation
// moved even though the revision and pending value did not), a shutdown, a
// moved revision, a superseded identity, or a context that disagrees with the
// published Engine all refuse the commit. An observation arriving AFTER this
// linearization point is a new intent for the next safe point; one arriving
// BEFORE it invalidates the attempt. Admission must still be CLOSED: the
// fence is what opens it.
bool RuntimeBootstrap::finalAdoptionFenceOk(const CompletionEnvelope &envelope, const AdoptionStaging &staging, uint64_t capturedRevision, uint64_t capturedGeneration) const {
  if (shutdownRequested_ || state_ != LifecycleState::Recovering)
    return false;
  if (power_ != LifecyclePower::AC)
    return false;
  if (pendingPower_.has_value() && *pendingPower_ != LifecyclePower::AC)
    return false;  // a pending non-AC intent supersedes this attempt
  if (lifecycleRevision_ != capturedRevision || powerObservationGeneration_ != capturedGeneration)
    return false;
  if (!envelope.candidate || envelope.candidate.get() != staging.candidate)
    return false;  // a different candidate than the one staged
  if (!staging.engine || !nativeLoop_->publishes(*staging.engine))
    return false;  // the staged Engine is not the published one
  if (!staging.graph || staging.engine->borrowedCache() != &staging.graph->cache() ||
      staging.engine->borrowedWriteBehind() != &staging.graph->writeBehind() ||
      staging.graph->resourceAuthority().holder() != ResourceDomainAuthority::Holder::Owner)
    return false;
  if (staging.cold) {
    if (resources_ || !envelope.candidate->resources || envelope.candidate->resources.get() != staging.graph)
      return false;  // the cold graph is still wholly the candidate's until commit
  } else {
    if (resources_.get() != staging.graph || envelope.candidate->borrowedResources != staging.graph ||
        !resources_->modelResident())
      return false;  // the private residency is not physically installed
  }
  if (model_.get() != staging.model)
    return false;  // the staged RuntimeModel is not this Bootstrap's
  const auto published = nativeLoop_->publishedContextTokens();
  if (!published.has_value() || *published != staging.engine->maxContextTokens() || *published > contextCeiling_)
    return false;  // the effective context must be the EXACT published window, within the ceiling
  if (nativeLoop_->admissionOpen())
    return false;  // the fence is what opens admission; an open gate here is a different shell
  return true;
}


// [T024] The safe point's move-out, run only after this graph's quiescence
// proof minted (the same four categories destroyEngine re-reads from their
// owners). Refusal by the drain barriers returns nothing with every part
// published exactly as before; success moves all three out as one payload.
std::unique_ptr<RuntimeBootstrap::PendingDisposal>
RuntimeBootstrap::detachDisposalAtSafePoint() {
  if (!nativeLoop_ || !model_)
    return nullptr;  // no stratum here to move
  auto engine = nativeLoop_->destroyEngine();
  if (!engine)
    return nullptr;  // a drain barrier stands: refuse, move nothing
  auto disposal = std::make_unique<PendingDisposal>();
  disposal->engine = std::move(engine);
  disposal->model = std::move(model_);
  if (resources_->modelResident())
    disposal->residency = resources_->releaseModelResidency();
  return disposal;
}

// [T024 / FR-008] The physical disposal, run ON THE RESIDENCY-WORKER THREAD
// under its claimed Worker interval (the caller's task runs after claim()).
// The payload dies in the T021 order Engine -> RuntimeModel -> residency
// (callbacks -> ANE program -> plans -> model inside the stratum, per the
// RuntimeResources destruction contract); nothing is destroyed on the safe
// point. The receipt names this thread and reports what the retained backend
// has allocated after, which is evidence the stratum's GPU-side bytes left.
DisposalReceipt RuntimeBootstrap::physicalDisposal(PendingDisposal &disposal) {
  std::ostringstream threadName;
  threadName << std::this_thread::get_id();
  const uint64_t before =
      resources_ ? resources_->backend().memoryStats().allocatedBytes : 0;
  disposal.engine.reset();   // Engine first: its borrows stay valid until now
  disposal.model.reset();    // RuntimeModel: it borrows the residency
  disposal.residency.reset();  // stratum: callbacks -> ANE -> plans -> model
  DisposalReceipt receipt;
  receipt.complete = true;
  const uint64_t after =
      resources_ ? resources_->backend().memoryStats().allocatedBytes : 0;
  receipt.releasedBytes = before > after ? before - after : 0;
  receipt.backendAllocatedBytesAfter = after;
  receipt.detail =
      "the model-bound stratum (Engine -> RuntimeModel -> residency) was "
      "destroyed on residency-worker thread " +
      threadName.str();
  return receipt;
}

// [T022] The pump delegates: it supplies the seam task and cooperative
// cancel; the worker runs the (production) expensive work off the safe point.
// [T024] The moved-out payload travels with the operation: whatever happens
// (current intent, cancelled intent), it is destroyed ON THE WORKER THREAD,
// inside the claimed interval — never on the safe point, never adopted back.
bool RuntimeBootstrap::startResidencyDisposal(WorkerHandoff &&token,
                                              uint64_t revision) {
  WorkerCancellation cancel = [this, revision] {
    std::lock_guard lock(lifecycleMutex_);
    return shutdownRequested_ || lifecycleRevision_ != revision;
  };
  // [T024] The payload lives in pendingDisposal_ between this safe point
  // and the operation; std::function's Task is copyable, so it reaches the
  // payload through the Bootstrap, never by moving a unique_ptr into the
  // closure. Whatever the operation does, the payload's ownership ENDS
  // on this worker thread, inside the claimed interval — never on the
  // safe point, never adopted back.
  ResidencyWorker::Task task = [this, revision](const WorkerCancellation &cancelled,
                                      WorkerHandoff *) {
    WorkerOutcome outcome;
    if (!cancelled()) {
      DisposalReceipt receipt;
      if (workerSeams_.dispose) {
        // A test seam's delegated disposal: it reports the transfer it made;
        // the (never populated in that path) payload stays empty.
        receipt = workerSeams_.dispose(cancelled);
      } else if (pendingDisposal_) {
        if (residencyEvidenceEnabled()) {
          ResidencyEvidence start;
          start.capture([&](auto &out) { out << "phase=worker_disposal_start lifecycle_revision=" << revision; });
        }
        receipt = physicalDisposal(*pendingDisposal_);
        if (residencyEvidenceEnabled()) {
          ResidencyEvidence end;
          end.capture([&](auto &out) { out << "phase=worker_disposal_end lifecycle_revision=" << revision; });
        }
      }
      outcome.disposal = std::make_unique<DisposalReceipt>(receipt);
    }
    if (pendingDisposal_)
      pendingDisposal_.reset();
    return outcome;
  };
  return residencyWorker_.start(std::move(token), revision, lifecycleMailbox_,
                                std::move(cancel), std::move(task));
}

bool RuntimeBootstrap::startResidencyConstruction(WorkerHandoff &&token,
                                                  uint64_t revision) {
  WorkerCancellation cancel = [this, revision] {
    std::lock_guard lock(lifecycleMutex_);
    return shutdownRequested_ || lifecycleRevision_ != revision;
  };
  // [T029] A warm construction runs ON the retained graph's claimed Worker
  // interval (its incoming token): the candidate it builds borrows that graph
  // and therefore never obtains a second authority of its own.
  ResidencyWorker::Task task = [this, revision](const WorkerCancellation &cancelled,
                                      WorkerHandoff *) {
    WorkerOutcome outcome;
    if (!cancelled()) {
      // A fixture's seam still stands in for the construction; with none,
      // this operation builds what the production recovery protocol carries.
      if (workerSeams_.build)
        outcome.candidate = workerSeams_.build(cancelled);
      else
        outcome.candidate = buildCandidateOnWorker(cancelled, false, revision);
    }
    if (outcome.candidate)
      handoffColdCandidateOnWorker(*outcome.candidate, outcome);
    return outcome;
  };
  return residencyWorker_.start(std::move(token), revision, lifecycleMailbox_,
                                std::move(cancel), std::move(task));
}

// [T023/T024/T029] The cold shell's requested construction: NO incoming
// handoff token (no domain was ever owned), so the worker runs the task without
// claiming and the ENVELOPE would carry nothing back — except that a cold
// candidate that OWNS its own graph supplies its OWN authority from the
// construction thread itself ([T029] witnesses → fresh proof of its own lease
// → transfer → claim → park), and outcome.handoff is what the published
// envelope then carries. Same serial slot, same cooperative revision fence.
bool RuntimeBootstrap::startColdResidencyConstruction(uint64_t revision) {
  WorkerCancellation cancel = [this, revision] {
    std::lock_guard lock(lifecycleMutex_);
    return shutdownRequested_ || lifecycleRevision_ != revision;
  };
  ResidencyWorker::Task task = [this, revision](const WorkerCancellation &cancelled,
                                      WorkerHandoff *) {
    WorkerOutcome outcome;
    if (!cancelled()) {
      if (workerSeams_.build)
        outcome.candidate = workerSeams_.build(cancelled);
      else
        outcome.candidate = buildCandidateOnWorker(cancelled, true, revision);
    }
    if (outcome.candidate)
      handoffColdCandidateOnWorker(*outcome.candidate, outcome);
    if (outcome.handoff && workerSeams_.coldHandoffComplete)
      workerSeams_.coldHandoffComplete();
    return outcome;
  };
  return residencyWorker_.start(std::nullopt, revision, lifecycleMailbox_,
                                std::move(cancel), std::move(task));
}


// [T031 prerequisite] The production construction one residency worker runs,
// for either lifecycle relationship the candidate type already distinguishes.
// Both paths build a candidate whose Engine is the loop's own makePrivateEngine:
// the shell publishes nothing, opens no admission and rebinds none of its
// witnesses; the candidate carries what it built and destroys it in the order
// its type declares (Engine -> RuntimeModel -> private residency -> graph).
//
// Cold: the shell retains no graph, so the candidate assembles its OWN with
// RuntimeResources::create on this thread, exactly as a first start does —
// backend, streamed stores, plans, split, governor, SSD cache and its own
// ResourceDomainLease, which this thread now holds as that graph's Owner until
// handoffColdCandidateOnWorker moves it. Its context resolves by start()'s own
// rules against ITS OWN plan: a relaunch's context capped by the plan, else the
// calibration its split left, and an explicit --max-context above what its plan
// holds is refused rather than served.
//
// Warm: the shell retains the graph, so NOTHING retained is rebuilt — no
// second backend, Cache, KV, WriteBehind or governor. RuntimeResources-
// :buildModelResidency runs the same model-bound phase against the retained
// graph with the retained SSD readers, reports the tier as already open, alloc-
// only a disposable stratum, and refuses it closed unless the rebuilt model
// identity and the KV/state geometry match this graph's. The candidate then
// borrows that graph by identity and owns only its stratum, its model over
// RuntimeResources::modelContext(privateResidency) and its Engine on the
// retained Cache/WriteBehind.
//
// Any failure leaves nothing behind for the pump to adopt: the candidate is a
// local that unwinds in that order, and the worker records the exception as a
// failed envelope exactly as it does for any other task failure.
std::unique_ptr<RecoveryCandidate>
RuntimeBootstrap::buildCandidateOnWorker(const WorkerCancellation &cancelled,
                                         bool cold, uint64_t revision) {
  if (!recoveryConfig_)
    throw std::logic_error(
        "a recovery construction has no retained startup configuration to build from");
  if (cold && resources_)
    throw std::logic_error("a cold recovery construction ran where a graph is retained");
  if (!cold && (!resources_ || !nativeLoop_))
    throw std::logic_error("a warm recovery construction has no retained graph to borrow");
  // The worker holds the retained domain throughout construction. Match first
  // assembly's essential-allocation mode, and restore its exact prior mark
  // before the worker returns or unwinds. Cold assembly owns its own mode.
  const std::function<bool(bool)> markServing = [this](bool serving) {
    return resources_->memoryGovernor().setServing(serving);
  };
  const Serving warmEssential(markServing, !cold);
  auto candidate = std::make_unique<RecoveryCandidate>();
  candidate->lifecycleRevision = revision;
  const RuntimeBootstrapConfig &base = *recoveryConfig_;
  // The candidate's own engine configuration: the loop's engine settings as
  // this start resolved them, reconnected below to the graph THIS candidate
  // owns or borrows (a cold candidate's governor is its own, and one loop may
  // publish a different graph's Engine than the candidate is building).
  engine::EngineConfig engineConfig = base.nativeLoop.engine;
  const auto &capabilities = base.resources.model.capabilities;
  engineConfig.vocabularySize = capabilities.vocabularySize;
  engineConfig.maxImagePatches =
      base.resources.model.hasVision() ? base.resources.maximumImagePatches : 0;
  engineConfig.maximumPrefillAttentionPairs = std::visit(
      [](const auto &layout) {
        return layout.hasIndexer() ? std::numeric_limits<uint64_t>::max()
                                   : Scheduler::attentionPairs(layout.nativeContextTokens -
                                                                   model::ExecutionLimits::prefillTokenBudget,
                                                               model::ExecutionLimits::prefillTokenBudget);
      },
      base.resources.model.target);

  std::unique_ptr<RuntimeResources> resources;
  if (cold) {
    // The worker's cooperative fence IS this construction's startup predicate:
    // the loader checks it at every boundary the load, plan and split take, and
    // a cancelled construction retires what it allocated in the loader's own
    // order.
    RuntimeResourcesConfig config = base.resources;
    config.cancelled = cancelled;
    resources = RuntimeResources::create(config, engineConfig.maxContext);
    const uint32_t planContext = resources->memoryPlan().maximumContextTokens();
    if (!planContext)
      throw std::runtime_error("a cold candidate's memory plan cannot hold one model token");
    if (!engineConfig.maxContext) {
      if (const uint32_t relaunch = base.resources.relaunchContext; relaunch)
        engineConfig.maxContext = std::min(relaunch, planContext);
      else
        engineConfig.maxContext = resources->aneFfnOutcome().context;
    } else if (engineConfig.maxContext > planContext) {
      throw std::runtime_error("a cold candidate cannot serve the configured --max-context: "
                               "its own memory plan holds less");
    }
  } else {
    // A rebuild reproduces the context the retained plan resolved for this
    // graph, which is the geometry its adoption gate proves; a recovery that
    // resolves a different window is the adoption fence's own decision (T031-
    // T033), taken from a candidate it can then refuse.
    const uint32_t planContext = resources_->memoryPlan().maximumContextTokens();
    if (!planContext)
      throw std::logic_error("a warm recovery has a retained plan that holds no model token");
    if (!engineConfig.maxContext)
      engineConfig.maxContext = planContext;
    else if (engineConfig.maxContext > planContext)
      throw std::runtime_error("a warm candidate cannot serve the configured --max-context: "
                               "the retained plan holds less");
    if (cancelled())
      throw std::runtime_error("recovery construction cancelled");
    // The one stratum, against the retained graph. What it throws already
    // retired only what it allocated.
    candidate->residency = std::make_optional(
        resources_->buildModelResidency(base.resources, engineConfig.maxContext, cancelled));
  }
  if (cancelled())
    throw std::runtime_error("recovery construction cancelled");

  // The arenas this candidate's model needs, admitted through the governor of
  // the graph it owns or borrows exactly where a first start admits its own:
  // a cold candidate's fresh lease answers for its own graph on this thread, a
  // warm one's operation answers on the retained graph's claimed Worker interval.
  RuntimeResources &target = cold ? *resources : *resources_;
  connectToGovernor(engineConfig, target.memoryGovernor());
  engineConfig.spill = target.spillConfig();
  const auto &budget = target.memoryPlan().breakdown();
  std::unique_ptr<model::RuntimeModel> candidateModel;
  std::string refusal;
  const metal::AllocationResult arenas =
      target.memoryGovernor().allocationAdmission()(
          budget.sharedPrefillBytes + budget.sharedDecodeBytes, [&] {
            try {
              // Cold: the candidate graph's own residency. Warm: the private
              // stratum this candidate owns, over the retained backend, KV
              // pages, state storage, caches and growth admission.
              const auto context =
                  cold ? target.modelContext()
                       : target.modelContext(*candidate->residency);
              if (!context)
                throw std::logic_error("model residency is absent where a recovery model is created");
              candidateModel = model::createRuntime(*context);
            } catch (const metal::MetalAllocationError &error) {
              refusal = error.what();
              throw;
            }
          });
  if (!arenas)
    throw metal::MetalAllocationError(
        refusal.empty() ? std::string("unable to admit a recovery candidate's model arenas: ") +
                              metal::allocationFailureName(arenas.failure)
                        : refusal,
        arenas.failure);
  if (cancelled())
    throw std::runtime_error("recovery construction cancelled");

  // Private to the candidate and published nowhere: this loop's event sink,
  // the graph's Cache and persistence queue, and the model built above. The
  // candidate owns what comes back, and its declaration order gives the
  // destruction order the reaper and the rollback both require.
  candidate->engine = nativeLoop_->makePrivateEngine(std::move(engineConfig), target.cache(),
                                                    target.writeBehind(), *candidateModel);
  candidate->model = std::move(candidateModel);
  if (cold)
    candidate->resources = std::move(resources);
  else
    candidate->borrowedResources = resources_.get();
  return candidate;
}

// [T032] One serial reap, requested at a safe point by the pump while THIS
// Owner thread holds the envelope's REAL domain (its parked token was already
// returned there at the claim that retained it). A cold candidate transfers its
// OWN lease, through its OWN four witnesses; a warm one transfers the RETAINED
// graph's authority through the graph's witnesses (prepareResourceHandoff), after
// the candidate's own drain categories are read directly from its objects: a
// candidate that still owes a request or a callback is retried at a later safe
// point, never reaped mid-flight. Without a fresh proof nothing moves: the
// candidate stays in the pending queue. The token goes to the SAME single
// worker that ever runs a construction or a disposal, and never into a worker
// that may refuse its start (the pump's running()/workerStarted_ gates run
// before this call at the same safe point, and only this Owner thread ever
// starts an operation).
bool RuntimeBootstrap::startCandidateReaper(uint64_t revision) {
  if (pendingReaps_.empty() || pendingReap_)
    return false;
  CompletionEnvelope &front = pendingReaps_.front();
  RecoveryCandidate *candidate = front.candidate.get();
  if (!candidate || !candidate->ownsResidency())
    return false;  // nothing physical left to reap
  if (front.handedOff)
    return false;  // its token was never returned: not reapable at this point
  RuntimeResources *graph = candidate->authorityGraph();
  if (!graph)
    return false;
  ResourceDomainLease &lease = graph->resourceAuthority();
  if (lease.holder() != ResourceDomainAuthority::Holder::Owner)
    return false;
  const bool cold = candidate->ownsResources();
  std::optional<Quiescence> proof;
  if (cold) {
    bindCandidateHandoffWitnesses(lease, *candidate);
    proof = lease.obtainQuiescence();
  } else {
    if (graph != resources_.get() || !nativeLoop_)
      return false;  // a warm candidate must borrow THIS graph
    if (engine::Engine *owed = candidate->engine.get()) {
      if (!owed->requestDrain().drained() || !owed->callbacksRetired())
        return false;  // the candidate itself still owes work: retry later
    }
    proof = nativeLoop_->prepareResourceHandoff(lease);
  }
  if (!proof)
    return false;
  auto token = lease.transferToWorker(std::move(*proof));
  // [T032] The payload travels INTO the closure the way the suspended stratum's
  // pending disposal does: std::function's Task must be copyable, so the
  // candidate moves into a shared handle the task owns outright. The worker thread
  // therefore never reads or writes the pump's pendingReap_ member, which stays
  // the mutex-guarded marker of the operation in flight.
  pendingReap_ = std::make_unique<CompletionEnvelope>(std::move(front));
  pendingReaps_.pop_front();
  auto payload = std::make_shared<RecoveryCandidate>(
      std::move(*pendingReap_->candidate));
  WorkerCancellation cancel = [this, revision] {
    std::lock_guard lock(lifecycleMutex_);
    return shutdownRequested_ || lifecycleRevision_ != revision;
  };
  // [T032] The physical reaping, ON THE WORKER THREAD under its claimed
  // Worker interval, in the mandatory order Engine -> RuntimeModel ->
  // private residency. A warm candidate's RETAINED graph is never touched:
  // only the stratum it owned. A cold candidate's OWN graph is different
  // business: its interval must END on this thread in the lease's own
  // contract order — park, return to the candidate's own lease (which binds
  // Owner HERE), and only THEN destroy the candidate-owned RuntimeResources
  // and its lease, which is the one way the lease destructor can lawfully
  // see an Owner interval at the moment the graph goes. Hence the token is
  // consumed inside the task rather than parked by run()'s generic tail.
  ResidencyWorker::Task task = [this, cold, graph, payload](
      const WorkerCancellation &cancelled, WorkerHandoff *token) {
    WorkerOutcome outcome;
    if (cold && workerSeams_.coldReapClaimed)
      workerSeams_.coldReapClaimed();
    if (cancelled()) {
      // The reap aborts whole: the candidate comes back INTACT, every part
      // still owned, and the claim that lands re-queues it with its token.
      outcome.candidate = std::make_unique<RecoveryCandidate>(
          std::move(*payload));
      return outcome;
    }
    RecoveryCandidate &reaped = *payload;
    std::ostringstream threadName;
    threadName << std::this_thread::get_id();
    const uint64_t before = graph->backend().memoryStats().allocatedBytes;
    reaped.engine.reset();  // Engine first: its borrows stay valid until now
    const uint64_t afterEngine = graph->backend().memoryStats().allocatedBytes;
    reaped.model.reset();  // RuntimeModel: it borrows the residency
    reaped.residency.reset();  // private residency, when separately owned
    const uint64_t afterStratum = graph->backend().memoryStats().allocatedBytes;
    if (cold) {
      if (!token) {
        // A cold reap always starts with the candidate's own token.
        throw std::logic_error(
            "a cold candidate reap reached its worker without its token");
      }
      auto parked = std::move(*token).park();
      reaped.resources->resourceAuthority().returnToOwner(std::move(parked));
      outcome.tokenConsumed = true;
      reaped.resources.reset();  // lease dies seeing Owner on this thread
    }
    // What is left of the reaped candidate is a SKELETON (its residency is
    // gone), and it dies with this closure on this thread: no expensive
    // destructor is left for any owner thread to run.
    DisposalReceipt receipt;
    receipt.complete = true;
    receipt.releasedBytes =
        before > afterStratum ? before - afterStratum : 0;
    receipt.backendAllocatedBytesAfter = afterStratum;
    // The per-phase counts are the order evidence the receipts carry: what
    // the backend held before the Engine died, after it, and after the
    // model and any private residency went.
    receipt.detail =
        std::string(cold ? "cold" : "warm") +
        std::string(" candidate stratum destroyed on residency-worker thread ") +
        threadName.str() + " [Engine -> RuntimeModel -> residency" +
        (cold ? " -> candidate-owned RuntimeResources" : "") +
        "][" + std::to_string(before) + "->" + std::to_string(afterEngine) +
        "->" + std::to_string(afterStratum) + "]";
    outcome.disposal = std::make_unique<DisposalReceipt>(receipt);
    return outcome;
  };
  if (!residencyWorker_.start(std::move(token), revision, lifecycleMailbox_,
                              std::move(cancel), std::move(task), graph)) {
    // start() refuses only while a running worker holds the slot, which the
    // pump's own gates ruled out at this same safe point (only this Owner
    // thread starts operations, and the envelope's token was minted here):
    // a transferred-but-unstarted token cannot happen, exactly as the other
    // delegated operations assume. The candidate stays queued either way.
    pendingReap_->candidate = std::make_unique<RecoveryCandidate>(
        std::move(*payload));
    pendingReaps_.push_front(std::move(*pendingReap_));
    pendingReap_.reset();
    return false;
  }
  return true;
}

void RuntimeBootstrap::joinResidencyWorker() {
  // Intent is already terminal (shutdownLifecycle ran before this); joining
  // an in-flight worker here is shutdown/teardown, never an ordinary safe point.
  residencyWorker_.joinCompleted();
}

void RuntimeBootstrap::drainLifecycleMailbox() {
  while (lifecycleMailbox_.held()) {
    auto envelope = *lifecycleMailbox_.claim();
    returnHandoffToOwner(envelope);
    retainCompletionLocked(std::move(envelope));
  }
}

// [T022] ResidencyWorker: exactly one operation on its own thread.
RuntimeBootstrap::ResidencyWorker::~ResidencyWorker() {
  if (thread_.joinable())
    thread_.join();
}

bool RuntimeBootstrap::ResidencyWorker::running() const {
  std::lock_guard lock(mutex_);
  return running_;
}

void RuntimeBootstrap::ResidencyWorker::joinCompleted() {
  std::thread thread;
  {
    std::lock_guard lock(mutex_);
    if (thread_.joinable())
      thread.swap(thread_);
    running_ = false;
  }
  if (thread.joinable())
    thread.join();
}

// Reuses the slot only after an already-published prior operation: a still-
// running worker is never joined or restarted here. A cold model-less shell
// starts with no token: its run() claims nothing; a cold FIRST candidate
// supplies its own interval from the construction thread inside its task
// ([T029]) and the envelope carries that one back.
bool RuntimeBootstrap::ResidencyWorker::start(
    std::optional<WorkerHandoff> token, uint64_t revision,
    CompletionChannel &channel, WorkerCancellation cancel, Task task,
    RuntimeResources *tokenDomain) {
  std::lock_guard lock(mutex_);
  if (thread_.joinable()) {
    if (running_)
      return false;  // an operation is in flight and has not published
    std::thread prior;
    prior.swap(thread_);
    if (prior.joinable())
      prior.join();  // prior published completion: joining it is allowed
  }
  channel_ = &channel;
  token_ = std::move(token);
  // [T029] Which graph a returned token belongs to, when the completion's
  // payload cannot name it (a reap that aborted cooperatively hands its
  // candidate's token back with no candidate in the completion).
  tokenDomain_ = tokenDomain;
  revision_ = revision;
  cancel_ = std::move(cancel);
  task_ = std::move(task);
  running_ = true;
  thread_ = std::thread([this] { run(); });
  return true;
}


void RuntimeBootstrap::ResidencyWorker::run() {
  // The Worker interval binds only through claim(): this thread owns the
  // transferred token for the operation's whole resource-borrowing extent.
  if (token_)
    token_->claim();
  WorkerOutcome outcome;
  bool failed = false;
  std::string failure;
  try {
    // [T032] The task is handed the claimed token (nullptr when the operation
    // has none): the generic path parks it after the task, while a cold
    // candidate's reap ends its own domain inside the task, leaving nothing
    // for this tail to park.
    outcome = task_(cancel_, token_ ? std::addressof(*token_) : nullptr);
  } catch (const std::exception &error) {
    failed = true;
    failure = error.what();
  } catch (...) {
    failed = true;
    failure = "the residency worker threw an unknown exception";
  }
  // Cooperative, revision-fenced cancellation checked before publishing: a
  // Warm candidates are disposed on the worker under the retained graph's
  // claimed authority. A cold candidate must travel with its parked token:
  // only the owner can return that token before reaping its graph.
  if (cancel_() && outcome.candidate && !outcome.candidate->ownsResources())
    outcome.candidate.reset();
  // Drop the closures that could still reach the domain before the mailbox
  // publish, so nothing in this scope touches the transferred domain after it.
  task_ = nullptr;
  cancel_ = nullptr;
  CompletionEnvelope envelope;
  envelope.lifecycleRevision = revision_;
  envelope.tokenDomain = tokenDomain_;
  envelope.candidate = std::move(outcome.candidate);
  envelope.disposal = std::move(outcome.disposal);
  envelope.failed = failed;
  envelope.failure = std::move(failure);
  // [T029] A cold-first construction carries the token of the graph it BUILT:
  // the outcome's own parked handoff, transferred/claimed/parked on this
  // thread, is what the published envelope holds. The three paths are
  // mutually exclusive — an incoming token, a candidate-supplied handoff, or a
  // token the task consumed — so exactly one interval can reach one envelope.
  if (outcome.handoff)
    envelope.handedOff = std::move(*outcome.handoff);
  // The claimed worker parks its token only after its final resource-borrowing
  // operation, and publishes the parked token exactly once. Publishing wakes
  // the existing control notifier (the channel's own wake), so the owner runs
  // its safe point again and claims the envelope.
  if (token_ && !outcome.tokenConsumed) {
    token_ = std::move(*token_).park();
    envelope.handedOff = std::move(*token_);
  }
  token_.reset();
  // [T029] No resource-owning candidate escapes through a tokenless success
  // envelope: its authority is mandatory, and a candidate that owns a graph
  // without an interval of it in the envelope is a defect the pump must see
  // as a failure rather than adopt. Its lease stays wherever it lawfully is.
  if (envelope.candidate && envelope.candidate->ownsResources() &&
      !envelope.handedOff && !failed) {
    envelope.failed = true;
    envelope.failure =
        "a resource-owning candidate reached publication without its "
        "mandatory Worker token";
  }
  static_cast<void>(channel_->publish(std::move(envelope)));

  // [T025 slot race] publish() wakes the Owner BEFORE this worker's own frame
  // ends, so the Owner can claim a completion, return its parked token and
  // reach the next lifecycle operation while running_ is STILL true. That
  // safe point defers (running() is the pump's slot-availability condition),
  // and this terminal wake — taken from the channel, invoked outside mutex_
  // and after running_ = false — guarantees it a fresh safe point once the
  // slot is free, so deferring never strands the pump or loses the
  // operation it deferred. Nothing resource-borrowing runs after the parked
  // token's publish, and no safe point joins this worker.
  std::function<void()> wake = channel_->controlWake();
  {
    std::lock_guard lock(mutex_);
    running_ = false;
  }
  if (wake)
    wake();
}

RuntimeBootstrapReport RuntimeBootstrap::requireWarmupAndAnnounce(
    const EngineMemoryPlan &memoryPlan, model::RuntimeModel &modelRuntime,
    ActualMemoryReporter memoryReporter, NativeRuntime &nativeLoop) {
  RuntimeBootstrapReport report = reportForPlan(memoryPlan);
  auto run = [&](RuntimeBootstrapStage stage, WarmupStepStatus &status,
                 auto &&operation, bool optional = false) {
    model::WarmupStepResult result;
    try {
      result = operation();
    } catch (const metal::MetalAllocationError &error) {
      if (optional) {
        status = WarmupStepStatus::MemoryLimited;
        return model::WarmupStepResult{};
      }
      report.resourceFailure = resourceAllocationFailure(error.failure());
      fail(report, stage,
           std::string(runtimeBootstrapStageName(stage)) +
               " threw: " + error.what());
    } catch (const std::exception &error) {
      fail(report, stage,
           std::string(runtimeBootstrapStageName(stage)) +
               " threw: " + error.what());
    } catch (...) {
      fail(report, stage,
           std::string(runtimeBootstrapStageName(stage)) +
               " threw an unknown exception");
    }
    if (!(result.wallSeconds > 0.0) || !std::isfinite(result.wallSeconds)) {
      std::string message = std::string(runtimeBootstrapStageName(stage)) +
                            " did not complete a real measured path";
      if (!result.detail.empty())
        message += ": " + result.detail;
      fail(report, stage, std::move(message));
    }
    status = WarmupStepStatus::Complete;
    return result;
  };

  model::WarmupStepResult maximumPrefill =
      run(RuntimeBootstrapStage::MaximumPrefill, report.warmup.maximumPrefill,
          [&] {
            return modelRuntime.warmupPrefill(model::ExecutionLimits::prefillTokenBudget);
          });
  nativeLoop.observePrefill(model::ExecutionLimits::prefillTokenBudget,
                           maximumPrefill.wallSeconds * 1000.0, maximumPrefill.hostSeconds * 1000.0);
  report.warmup.maximumPrefillDetail = maximumPrefill.detail;
  const auto &budget = memoryPlan.breakdown();
  // Startup exercises only widths that fit this budget. This is not a
  // serving concurrency limit: the engine still admits lanes dynamically.
  const uint32_t affordableWidth = static_cast<uint32_t>(std::min<uint64_t>(
      model::ExecutionLimits::maximumBatchWidth,
      (budget.dynamicBudgetBytes -
       kvRunwayPages(budget.kvExtentPages) * budget.kvPageBytes) /
          budget.laneStateBytes));
  for (uint32_t width = 1;
       width <= model::ExecutionLimits::maximumBatchWidth; ++width) {
    if (width > affordableWidth ||
        (width > 1 && report.warmup.decodeBatches[width - 2] ==
                          WarmupStepStatus::MemoryLimited)) {
      report.warmup.decodeBatches[width - 1] = WarmupStepStatus::MemoryLimited;
      continue;
    }
    run(RuntimeBootstrapStage::DecodeWarmup,
        report.warmup.decodeBatches[width - 1],
        [&] { return modelRuntime.warmupDecodeBatch(width); }, width > 1);
  }
  run(RuntimeBootstrapStage::CompositeStateRestore,
      report.warmup.compositeStateRestore,
      [&] { return modelRuntime.warmupCompositeStateRestore(); }, true);

  ActualMemoryReport actual;
  try {
    actual = memoryReporter();
  } catch (const metal::MetalAllocationError &error) {
    report.resourceFailure = resourceAllocationFailure(error.failure());
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         std::string("actual memory reporting failed: ") + error.what());
  } catch (const std::exception &error) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         std::string("actual memory reporting failed: ") + error.what());
  } catch (...) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         "actual memory reporting failed with an unknown exception");
  }
  report.memoryAudit = auditActualMemory(memoryPlan, actual);
  if (!report.memoryAudit.valid) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         report.memoryAudit.describe());
  }

  try {
    nativeLoop.announceReady();
  } catch (const std::exception &error) {
    fail(report, RuntimeBootstrapStage::AnnounceReady,
         std::string("ReadyEvent announcement failed: ") + error.what());
  } catch (...) {
    fail(report, RuntimeBootstrapStage::AnnounceReady,
         "ReadyEvent announcement failed with an unknown exception");
  }
  report.stage = RuntimeBootstrapStage::Ready;
  report.message = "required warmup paths and memory audit passed";
  return report;
}

std::unique_ptr<RuntimeBootstrap> RuntimeBootstrap::start(
    RuntimeBootstrapConfig config,
    NativeRuntime::ByteSink output,
    NativeRuntime::StatusProvider statusProvider) {
  std::unique_ptr<RuntimeResources> resources;
  try {
    resources = RuntimeResources::create(config.resources, config.nativeLoop.engine.maxContext);
  } catch (const RuntimeResourcesError &error) {
    throw RuntimeBootstrapError(error);
  }

  RuntimeBootstrapReport base = reportForPlan(resources->memoryPlan());
  const uint32_t planContext =
      resources->memoryPlan().maximumContextTokens();
  if (!planContext) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         "memory plan cannot hold one model token");
  }
  const uint32_t relaunchContext = config.resources.relaunchContext;
  if (!config.nativeLoop.engine.maxContext && relaunchContext) {
    // A relaunch serves the context of the server's first engine, which its
    // split left. A plan that holds less, as once this Mac's memory budget
    // shrank, has the relaunch serve that, and the server, which serves the
    // first engine's context, stops relaunching (server/runtime.py).
    if (relaunchContext > planContext)
      logLine("The memory plan holds ", planContext, " tokens of context, less than the ",
              relaunchContext, " the server's first engine served.");
    config.nativeLoop.engine.maxContext = std::min(relaunchContext, planContext);
  } else if (!config.nativeLoop.engine.maxContext) {
    // The automatic context, which the plan holds and every start of the
    // model on this Mac that takes its calibration serves alike
    // (AneFfnOutcome::context).
    config.nativeLoop.engine.maxContext = resources->aneFfnOutcome().context;
  } else if (config.nativeLoop.engine.maxContext > planContext) {
    // --max-memory sets the budget only below this Mac's own; the SSD cache's
    // room bounds a context whose KV spills (ContextBounds::bound).
    const auto &budget = resources->memoryPlan().breakdown();
    const bool memoryCapped = budget.configuredMemoryLimitBytes &&
                              budget.hardBudgetBytes == budget.configuredMemoryLimitBytes;
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         "--max-context " + std::to_string(config.nativeLoop.engine.maxContext) +
             " exceeds the " + std::to_string(planContext) + " tokens the model and " +
             (budget.contextBounds.bound() == "disk" ? "the SSD cache's room for its KV"
              : memoryCapped                         ? "--max-memory"
                                                     : "this Mac's memory") +
             " allow; omit it or pass at most " + std::to_string(planContext));
  }
  config.nativeLoop.engine.vocabularySize =
      config.resources.model.capabilities.vocabularySize;
  // A prefill command takes no more attention than a full chunk at the end
  // of the native window, which every supported Mac runs within the command
  // watchdog: past it, at depths only YaRN serves, commands take fewer rows.
  // A row of a target with an indexer attends to its top blocks at any depth,
  // and only the indexer's scores grow with it, a hundredth of attention's,
  // so its commands keep their rows.
  constexpr uint32_t chunk = model::ExecutionLimits::prefillTokenBudget;
  config.nativeLoop.engine.maximumPrefillAttentionPairs = std::visit(
      [](const auto &layout) {
        return layout.hasIndexer() ? std::numeric_limits<uint64_t>::max()
                                   : Scheduler::attentionPairs(layout.nativeContextTokens - chunk, chunk);
      },
      config.resources.model.target);
  // Images are admitted up to the server's pixel cap; a model without vision
  // admits none.
  config.nativeLoop.engine.maxImagePatches =
      config.resources.model.hasVision() ? config.resources.maximumImagePatches
                                         : 0;

  std::unique_ptr<model::RuntimeModel> modelRuntime;
  try {
    // The plan's fixed bytes already proved the arenas' sum fits.
    const auto &budget = resources->memoryPlan().breakdown();
    // Admission reports a refusal by its failure alone. One raised while the
    // runtime allocates keeps its own message, which says what to do.
    std::string refusal;
    const metal::AllocationResult arenas =
        resources->memoryGovernor().allocationAdmission()(
            budget.sharedPrefillBytes + budget.sharedDecodeBytes, [&] {
              try {
                const auto context = resources->modelContext();
                if (!context)
                  throw std::logic_error("model residency is absent where modelRuntime is created");
                modelRuntime = model::createRuntime(*context);
              } catch (const metal::MetalAllocationError &error) {
                refusal = error.what();
                throw;
              }
            });
    if (!arenas) {
      throw metal::MetalAllocationError(
          refusal.empty() ? std::string("unable to admit model arenas: ") +
                                metal::allocationFailureName(arenas.failure)
                          : refusal,
          arenas.failure);
    }
  } catch (const metal::MetalAllocationError &error) {
    base.resourceFailure = resourceAllocationFailure(error.failure());
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         std::string("modelRuntime creation failed: ") + error.what());
  } catch (const std::exception &error) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         std::string("modelRuntime creation failed: ") + error.what());
  } catch (...) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         "modelRuntime creation failed with an unknown exception");
  }
  std::unique_ptr<NativeRuntime> nativeLoop;
  try {
    connectToGovernor(config.nativeLoop.engine, resources->memoryGovernor());
    config.nativeLoop.engine.spill = resources->spillConfig();
    config.nativeLoop.weights = resources->releasableMemory();
    config.nativeLoop.weightAdmission = resources->memoryGovernor().allocationAdmission();
    config.nativeLoop.growthAdmission = resources->memoryGovernor().growthAdmission();
    config.nativeLoop.engineFailed = [owner = resources.get()] { owner->engineFailed(); };
    // The parser and engine consume the same resolved ceiling. In automatic
    // mode it cannot be known until resource planning has measured the device.
    nativeLoop = std::make_unique<NativeRuntime>(
        config.nativeLoop, config.resources.idleReleaseSeconds, resources->cache(),
        resources->writeBehind(), *modelRuntime, std::move(output), std::move(statusProvider),
        protocolLimitsFor(config.resources.model.capabilities,
                          config.nativeLoop.engine.maxContext));
  } catch (const metal::MetalAllocationError &error) {
    base.resourceFailure = resourceAllocationFailure(error.failure());
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         std::string("native loop creation failed: ") + error.what());
  } catch (const std::exception &error) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         std::string("native loop creation failed: ") + error.what());
  }

  RuntimeResources *resourcesPointer = resources.get();
  model::RuntimeModel *modelPointer = modelRuntime.get();
  RuntimeBootstrapReport report = requireWarmupAndAnnounce(
      resources->memoryPlan(), *modelRuntime,
      [resourcesPointer, modelPointer] {
        // Audit every attempted warmup before reclaiming idle buffers.
        // Wider batches and cache memory grow on demand after Ready.
        const auto actual = resourcesPointer->actualMemoryReport(
            modelPointer->actualRuntimeMemory());
        if (!actual)
          throw std::logic_error("model residency is absent in the memory audit");
        ActualMemoryReport report = *actual;
        // Keep what the first request starts from: one lane's state buffers
        // and one empty KV extent. No cache data is evicted.
        while (modelPointer->reclaimIdleState(true, model::IdleMemory::Buffers)) {
        }
        static_cast<void>(resourcesPointer->cache().releaseEmptyExtents(true));
        // The last check of the host's reserve before Ready weighs what the
        // engine serves with, not the lanes the optional warmups left idle.
        const auto deadline = AwakeClock::now() + kMemoryReleaseWait;
        for (;;) {
          try {
            resourcesPointer->backend().checkOperation();
            return report;
          } catch (const metal::MetalAllocationError &) {
            if (AwakeClock::now() >= deadline)
              throw;
          }
          std::this_thread::sleep_for(kMemoryReleasePoll);
        }
      },
      *nativeLoop);

  // The per-operation guard RuntimeResources installed is only for startup:
  // once Ready, the engine meets memory pressure between its ticks.
  resources->backend().setOperationGuard({});
  resources->beginServing();
  auto bootstrap = std::unique_ptr<RuntimeBootstrap>(
      new RuntimeBootstrap(std::move(resources), std::move(modelRuntime),
                           std::move(nativeLoop), std::move(report),
                           std::move(config.lifecycleWake),
                           config.nativeLoop.engine.maxContext));
  // [T031 prerequisite] What a later recovery builds from, resolved exactly as
  // this start resolved it (the context, vocabulary, patch limit and attention
  // pairs above). A warm rebuild of a stratum must match the graph the model
  // and memory description it comes from assembled; the sinks and the lifecycle
  // wake are the shell's own and are not rebuilt from here.
  bootstrap->recoveryConfig_ = config;
  return bootstrap;
}

// [T023] The cold Battery/Unknown startup, and the ordinary upstream start()
// untouched above is unchanged by it. Nothing below allocates for a model:
// there is no RuntimeResources, no Metal backend, no loaded model, no Engine
// and no synthetic Cache — just the protocol/control shell, its framing,
// control frames, status and the pump. Native admission is CLOSED before
// the single ReadyEvent: control readiness, never inference. The static
// configured capability comes from the parsed descriptor only (ceiling and
// vocabulary), so /status can answer what the configuration COULD serve
// while it serves nothing.
std::unique_ptr<RuntimeBootstrap> RuntimeBootstrap::startModelLess(
    RuntimeBootstrapConfig config,
    NativeRuntime::ByteSink output,
    NativeRuntime::StatusProvider statusProvider) {
  auto recoveryConfig = config;
  const uint32_t ceiling = config.nativeLoop.engine.maxContext
                               ? config.nativeLoop.engine.maxContext
                               : config.resources.model.capabilities.maximumContextTokens;
  if (!ceiling) {
    RuntimeBootstrapReport report;
    fail(std::move(report), RuntimeBootstrapStage::AnnounceReady,
         "a model-less start needs a context ceiling: pass --max-context or "
         "read one from the descriptor's capabilities");
  }
  if (const uint32_t vocabulary =
          config.resources.model.capabilities.vocabularySize;
      !vocabulary) {
    RuntimeBootstrapReport report;
    fail(std::move(report), RuntimeBootstrapStage::AnnounceReady,
         "a model-less start reads its vocabulary size from the descriptor's "
         "capabilities, and that is zero");
  }
  // The shell advertises static capabilities while inference remains closed.
  config.nativeLoop.engine.maxContext = ceiling;
  config.nativeLoop.engine.vocabularySize =
      config.resources.model.capabilities.vocabularySize;
  config.nativeLoop.engine.maxImagePatches = config.resources.model.hasVision()
      ? config.resources.maximumImagePatches : 0;
  // The domain-bound Engine hooks a graph start wires (governor, spill,
  // weight admission/growth, engineFailed) stay unwrapped defaults: with no
  // domain, the Engine-absent paths never consult them.
  std::unique_ptr<NativeRuntime> nativeLoop;
  try {
    nativeLoop = std::make_unique<NativeRuntime>(
        config.nativeLoop, config.resources.idleReleaseSeconds,
        std::move(output), std::move(statusProvider),
        protocolLimitsFor(config.resources.model.capabilities, ceiling));
  } catch (const std::exception &error) {
    RuntimeBootstrapReport report;
    fail(std::move(report), RuntimeBootstrapStage::AnnounceReady,
         std::string("model-less native loop creation failed: ") + error.what());
  }

  // Admission closes BEFORE the one ReadyEvent: the announcement is the
  // control plane's, and a request at any point from here refuses on its own
  // frame until a recovery adoption protocol (T029-T033) opens it.
  try {
    nativeLoop->closeAdmission();
    nativeLoop->announceReady();
  } catch (const std::exception &error) {
    RuntimeBootstrapReport report;
    fail(std::move(report), RuntimeBootstrapStage::AnnounceReady,
         std::string("model-less ReadyEvent announcement failed: ") + error.what());
  }

  RuntimeBootstrapReport report;
  report.stage = RuntimeBootstrapStage::Ready;
  report.message = "model-less control shell ready: no warmup, no memory audit";
  auto bootstrap = std::unique_ptr<RuntimeBootstrap>(
      new RuntimeBootstrap(nullptr, nullptr, std::move(nativeLoop),
                           std::move(report), std::move(config.lifecycleWake),
                           ceiling));
  // [T031 prerequisite] The cold candidate a first AC intent asks for assembles
  // its OWN graph from exactly the model, memory, disk and engine configuration
  // this shell resolved above (its ceiling, vocabulary and descriptor), on the
  // residency worker's thread. Sinks and wake stay the shell's own.
  bootstrap->recoveryConfig_ = std::move(recoveryConfig);
  {
    // The pump begins with the battery policy's injected observation (T026
    // wires the real OS registration/sample): authority established at once,
    // Suspended over an absent stratum at revision 1 — the first AC intent
    // then has one construction to request.
    std::lock_guard lock(bootstrap->lifecycleMutex_);
    bootstrap->power_ = config.initialPower.value_or(LifecyclePower::Unknown);
    bootstrap->lifecycleAuthorityEstablished_ = config.initialPower.has_value();
    bootstrap->state_ = LifecycleState::Suspended;
    bootstrap->pumpModelResident_ = false;
    bootstrap->lifecycleRevision_ = 1;
    bootstrap->publishLifecycle(true);
  }
  return bootstrap;
}

} // namespace splash::engine
