#pragma once

#include "AwakeClock.hpp"
#include "engine/Engine.hpp"
#include "engine/Protocol.hpp"
#include "engine/RuntimeMetrics.hpp"
#include "engine/PowerSource.hpp"
#include "engine/ResourceDomainLease.hpp"
#include "engine/Status.hpp"
#include "model/WeightMemory.hpp"

#include <cstdint>
#include <exception>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <unordered_map>
#include <utility>

namespace splash::engine {

// The clocks a native loop reads unless told others: the system clock in
// Unix microseconds, which a request's absolute deadline is on, and the awake
// clock in milliseconds (awakeMilliseconds), which it measures every duration
// on.
[[nodiscard]] uint64_t systemUnixMicros() noexcept;

// Serving weight restoration belongs solely to EngineConfig::weights.
// The control shell needs no model/weights binding; both forms need clocks.
struct NativeLoopConfig {
  engine::EngineConfig engine;
  // Told true when the engine takes a request while it holds none, and false
  // when its last request ends; the process keeps the Mac from idle sleep in
  // between (main.mm). It must not throw. Empty where nothing needs to know.
  std::function<void(bool)> holdingRequests;
  // Told when the engine's own work fails (its failure boundary below caught
  // an exception, or an event it made does not fit the wire), before the
  // failure is reported. It must not throw. Empty where nothing needs to know.
  std::function<void()> engineFailed;
  std::function<uint64_t()> unixMicros = systemUnixMicros;
  std::function<double()> monotonicMilliseconds = awakeMilliseconds;
};

// The final admission boundary (FR-005/FR-009's structure): one mutex with the
// inference flag under it, which the loop holds from the closed check through
// `Engine::submit`. A closure that wins that race therefore refuses the frame
// before the Engine sees it, and a submission that wins is committed before
// closure may begin: the two serialize on the real handover, not on parsing or
// on an earlier readiness read. Closure is not a drain and not a retirement:
// it neither waits for the requests already admitted nor takes their ownership
// away. Nothing that can call back runs under this mutex: the config's
// injectable clocks are read before it is taken, the submission's own queries
// (Model::prefillGroupRows/prefillPasses) are plain data, and every error
// answer, keep-awake transition and weight-restore transition happens after
// the lock is let go. Only the loop's own explicit operations open or close it.
struct NativeAdmissionGate final {
  std::mutex mutex;
  // Open from normal startup, which leaves a loop nobody closes exactly the
  // loop it was before the gate existed.
  bool inferenceReady = true;
};

// Translates native protocol messages and events at the Engine boundary.
//
// The engine's failure boundary. Every received frame, tick(), runControl()
// and flushRestorePoints() run inside it: an exception is reported once as an
// EngineUnhealthy ErrorEvent (metal_execution_failed for MetalBackendError,
// else engine_execution_failed), the connection closes and the process exits.
// An output write that fails closes the connection and leaves the engine
// healthy.
// Request-scoped problems never arrive as exceptions here except
// std::invalid_argument from Engine::submit.
class NativeRuntime final : private EngineEventSink {
public:
  using ByteSink = std::function<void(std::span<const uint8_t>)>;
  using StatusProvider = std::function<std::string()>;

  // idleReleaseSeconds is the engine's idle release
  // (RuntimeResourcesConfig::idleReleaseSeconds): positive, and infinite
  // where the weights stay.
  // Cache and its WriteBehind must outlive this loop and its Engine.
  NativeRuntime(NativeLoopConfig config, double idleReleaseSeconds,
                engine::Cache &cache, WriteBehind &writeBehind,
                model::Model &model, ByteSink output,
                StatusProvider statusProvider, protocol::ProtocolLimits limits);
  // [T024] The same long-lived protocol/control shell with no Engine published
  // yet: no Cache, WriteBehind or Model is borrowed until publishEngine() binds
  // one. The loop's control plane (framing, control frames, status, cancellation,
  // admission, the pump's lifecycle reads) runs over this shell; inference paths
  // read absent rather than reaching an Engine that is not there. This is the
  // cold Battery/Unknown startup's shape (T023); no synthetic Cache is invented
  // for it.
  NativeRuntime(NativeLoopConfig config, double idleReleaseSeconds,
                ByteSink output, StatusProvider statusProvider,
                protocol::ProtocolLimits limits);
  // Marks this loop's handoff evidence detached before anything else goes
  // (see HandoffEvidence): a lease that outlives the loop keeps its four slots
  // answering false from here on instead of reaching a loop, Engine or Cache
  // that is gone.
  ~NativeRuntime();
  void serveStatus(StatusProvider provider);

  // Processes every complete frame in bytes. False means the connection
  // must close. Request-scoped errors return true and preserve framing.
  bool receive(std::span<const uint8_t> bytes);
  bool finishInput();

  // Executes at most one explicit GPU BatchPlan, or takes back one part of
  // the released weights (Engine::tick).
  bool tick();
  // Command-free control work uses the same failure boundary as execution.
  bool runControl(const std::function<bool()> &control);
  // [T027/T028] The retained graph's own persistence service, for a shell with no
  // Engine published to run it: it collects the transfers a started write's
  // completion has landed, then runs the queue's due points, on this loop's
  // clock, and reports real progress only for a landed transfer or a settled
  // point. It is the same service Engine::tick performs for a published Engine
  // (never both at once), and it reaches the domain only while the calling
  // thread holds its authority: under a Worker or Parked interval it neither
  // collects nor starts nor settles anything, leaving the queue exactly as it
  // was — not dropped, not re-timed, not re-ordered — until the Owner returns.
  // Called from the lifecycle owner's control pass (the Owner safe point) and,
  // with no Engine published, from this loop's tick, where the completion wake
  // that lands a write is what the loop is waiting on.
  bool serviceRetainedPersistence();
  // At a clean stop (Engine::flushRestorePoints). False until no restore
  // point is left, and once the engine has failed.
  bool flushRestorePoints();
  void retireWeightWriterForShutdown();
  // Releases the weights once the engine has held no request for the idle
  // release since it became ready (Engine::releaseIdleWeights). Runs between
  // commands, in the control pass.
  void releaseIdleWeights();
  void setCompletionNotifier(std::function<void()> notifier) {
    // [T024] Stored as the loop's own: a detached Engine that goes away does
    // not lose the notifier, and a later publishEngine rebinds it. The FdTransport
    // binds its controlNotifier wake here (see FdTransport::run), which captures
    // only that wake's shared state: no cycle back to this loop, and the closure
    // is released with the loop, never outliving Bootstrap teardown.
    completionNotifier_ = std::move(notifier);
    if (core_)
      core_->setCompletionNotifier(completionNotifier_);
  }

  // Sends the warm-up's `progress`, before announceReady, once the engine holds its weights.
  void announceWarming(const protocol::WarmingEvent &progress);
  // Sends `ready` (readyEventFor), once, and starts the idle release's count.
  void announceReady(const protocol::ReadyEvent &ready);

  // [T027/T028] The lifecycle owner's authority predicate, bound by RuntimeBootstrap
  // to its own resourceDomainHeld(). Under Worker/Parked ownership of the retained
  // domain, this thread must not read the domain's wake sources (Engine::nextWakeup
  // -Milliseconds and WriteBehind::nextWakeup) nor reach the retained queue at a
  // clean stop: both answer "no domain wake / not flushable now", and the loop
  // resumes on the worker's completion or control wake, exactly where the
  // deferred work was left. Unbound — a standalone shell fixture with no lease
  // in play — keeps the ordinary upstream behavior.
  void setResourceAuthorityHeld(std::function<bool()> held) {
    resourceAuthorityHeld_ = std::move(held);
  }

  // [T024] The shell owns the currently published Engine, or none. Engine
  // construction always binds valid, non-null Cache, WriteBehind and Model
  // references: they belong to the retained graph and must outlive this loop
  // and its Engine. Publishing an already-published Engine is a defect and
  // refused; a published Engine rebinds this loop's stored completion notifier.
  void publishEngine(engine::Cache &cache, WriteBehind &writeBehind,
                     model::Model &model);
  // [T024/T031] Adopt an already-constructed Engine without consuming it on
  // rejection: refused when one is already published or the candidate is
  // empty; the caller's unique_ptr keeps its Engine intact either way.
  [[nodiscard]] bool tryPublishEngine(std::unique_ptr<engine::Engine> &candidateEngine);
  // Whether an inference Engine is published on this shell right now. Passive.
  [[nodiscard]] bool hasEngine() const noexcept { return core_ != nullptr; }
  // [T029] Whether THIS exact Engine is the one this shell publishes
  // (passive). A private recovery candidate's ingress witness needs it: the
  // candidate's domain can only take admission traffic through a shell that
  // publishes it, and before T031/T033 nothing publishes a candidate Engine.
  [[nodiscard]] bool publishes(const engine::Engine &candidateEngine) const noexcept {
    return core_.get() == &candidateEngine;
  }
  // [T030] The exact context the published Engine enforces, absent-safe: no
  // Engine published means no capacity to report, so a request-telemetry reader
  // never falls back to the ReadyEvent's ceiling or the descriptor's. Passive:
  // it waits for nothing, and config_'s window cannot change after construction.
  [[nodiscard]] std::optional<uint32_t> publishedContextTokens() const noexcept {
    return publishedContext_;
  }
  // [T031 prerequisite] A recovery candidate's PRIVATE Engine: built over THIS
  // loop's event sink (its protocol events reach the same transport) but bound
  // to the CANDIDATE's Cache/WriteBehind/Model and the EngineConfig its own
  // construction resolved. It is never installed in core_: no admission opens,
  // nothing is announced, and none of this loop's bindings or witnesses move;
  // the caller owns what comes back and destroys it in candidate order. Engine
  // is built with new because EngineEventSink is a private base and only this
  // class may write the upcast to Engine's sink reference.
  [[nodiscard]] std::unique_ptr<engine::Engine>
  makePrivateEngine(engine::EngineConfig config, engine::Cache &cache,
                    WriteBehind &writeBehind, model::Model &model);
  // [T024 / FR-008 Gate 3 refusal path] The physical-detach half of the
  // lifecycle's suspension, run at the owner's safe point. Its first act is
  // closing admission at the native boundary: the final native admission
  // closes before Engine detachment. It then refuses (null return, the published
  // Engine and gate exactly as they were, admission left closed) while any
  // drain barrier is unmet: the request-side drain (T016), the retained graph's
  // IO (T018) or the callback/descendant retirement (T017). On success it MOVES
  // the Engine out to the caller — it does not destruct it here: the
  // residency-worker disposal the safe point hands it to owns the physical
  // destruction (under the Worker interval, off the safe point). After it,
  // the weight borrows, the completion notifier and the handoff witnesses no
  // longer name a published Engine; the stored notifier stays for a later
  // publishEngine. Requests the Engine still holds are never touched.
  [[nodiscard]] std::unique_ptr<engine::Engine> destroyEngine();

  // [T031] The input for ONE staged (transactional) adoption of a recovery
  // candidate's Engine into this shell, beyond what tryPublishEngine could
  // ever do: the candidate's Engine by its holder (moved only on success),
  // the exact Cache and WriteBehind it must borrow, the complete EngineConfig
  // THAT Engine enforces (so the shell's config and the published Engine can
  // never disagree), the adoption graph's releasable weights, governor
  // admissions and failure callback, the graph's Owner-authority predicate,
  // and the immutable configured ceiling the adopted window may not exceed.
  // A refusal consumes nothing: the candidate's holder keeps its Engine.
  struct NativeAdoptionInput final {
    std::unique_ptr<engine::Engine> *engineSlot = nullptr;
    engine::EngineConfig engineConfig;
    engine::Cache *cache = nullptr;
    WriteBehind *writeBehind = nullptr;
    std::function<void()> engineFailed;
    std::function<bool()> authorityHeld;
    uint32_t contextCeiling = 0;
  };
  // [T031] The staged adoption's rollback record: every previous shell binding
  // — Engine ownership, the Cache/WriteBehind pointers, the handoff evidence's
  // Cache, the whole graph-bound config (engine settings, weights, admissions,
  // failure callback), the idle/restore timestamps and counters, and the
  // displaced Engine/Cache/StateCache notifier slots — retained until the
  // transaction commits or rolls back. Opaque to callers.
  class StagedAdoption final {
   public:
    ~StagedAdoption() = default;

   private:
    friend class NativeRuntime;
    NativeRuntime *loop_ = nullptr;
    WriteBehind *previousWriteBehind_ = nullptr;
    engine::Cache *previousCache_ = nullptr;
    const engine::Cache *previousEvidenceCache_ = nullptr;
    NativeLoopConfig previousConfig_;
    std::optional<uint32_t> previousContext_;
    engine::Engine::PreparedCompletionBinding displacedNotifier_;
    bool notifierStaged_ = false;
  };

  // [T031] The reversible half of transactional adoption, run on the lifecycle
  // Owner's safe-point thread with admission CLOSED. It first REFUSES (false,
  // record stays empty, nothing moved) unless: admission is closed; no Engine
  // is published; this loop's request telemetry, mask obligations, restore
  // state and callbacks are drained; the candidate Engine's borrowed Cache/
  // WriteBehind are exactly the ones named; the Owner predicate says the
  // graph's authority is held here; the adopted window is positive and within
  // the given ceiling; and the weights, admissions and failure callback the
  // model-bearing shell needs are supplied. Then every potentially throwing
  // preparation (the record, the config copy, the clock read and the whole
  // prepared completion-notifier binding) happens, and from the Engine's
  // ownership move on only non-throwing swaps/moves run: the Engine, the
  // graph pointers, the evidence's Cache, the complete config, the fresh-
  // residency timestamps/counters, and the installed notifier binding.
  [[nodiscard]] bool stageAdoption(NativeAdoptionInput &input, std::unique_ptr<StagedAdoption> &staged);
  // [T031] The undo: moves the staged Engine back out to the caller (its
  // borrows never died, so it stays ownable by the candidate) and restores
  // every displaced shell binding — including the previous notifier slots,
  // reinstalled through the same non-throwing prepared-binding install, never
  // through another allocating setter.
  [[nodiscard]] std::unique_ptr<engine::Engine> rollbackAdoption(std::unique_ptr<StagedAdoption> &&staged) noexcept;
  // [T031] The commit: drops only the rollback record; the displaced previous
  // bindings end here, beside the graph the adopted Engine was built on.
  void commitAdoption(std::unique_ptr<StagedAdoption> &&staged) noexcept;
  // [T031/T033] The exact Engine this shell publishes (null when none): the
  // fence's and the acceptance tests' identity witness. Passive.
  [[nodiscard]] engine::Engine *publishedEngine() noexcept { return core_.get(); }

  // The lifecycle owner's (RuntimeBootstrap's) side of the admission boundary.
  // Both take the gate's mutex, so this waits for a submission already under
  // way, and returns before the Engine could be handed another: from the moment
  // it returns, a later request frame is refused at the native boundary. It
  // starts no drain, releases no residency and destroys nothing here, and it
  // leaves the requests the Engine already holds owned and running; the drain
  // protocol that follows is what waits for them.
  void setPowerObservation(std::shared_ptr<PendingPowerObservation> observation) {
    powerObservation_ = std::move(observation);
  }
  void closeAdmission() noexcept;
  // Opens admission again. Only this does: no status read, answered frame,
  // completed request, restored weight or observed power reopens it, and closing
  // an already closed gate, or opening an open one, changes nothing.
  void openAdmission() noexcept;
  // Whether a request frame would be admitted now. Reading it opens nothing.
  [[nodiscard]] bool admissionOpen();

  // [Gate 1 proof / FR-008, FR-009, T019] The owner's side of a resource-domain
  // handoff of the graph this loop runs on. Its first act is closing admission
  // at the native boundary: while the owner looks for work, nothing new may
  // enter the domain, and that closure stays closed when the look refuses. It
  // then binds this loop's own four witnesses to the owner lease and asks that
  // lease to mint a quiescence proof — the gate it owns (this boundary), the
  // request-side drain (NativeRuntime::requestDrain, T016), the retained graph's
  // IO (Cache::retainedIoIdle, T018) and the callbacks and descendants the Engine
  // still owes (Engine::callbacksRetired, T017: GPU/host closures, the bound
  // notifier, the model's Neural Engine descendants). Each is read from the
  // object that owns that work: no count is duplicated here, no flag stands in
  // for one, and none of them is satisfied by `Engine::idle()` or by completed
  // GPU tickets. The lease evaluates the four outside its authority mutex and
  // re-checks its own mutation count under that mutex, so a category that was
  // never supplied, one that says work remains, or a domain mutation after the
  // look all mint nothing; the returned proof is bound to this authority,
  // single-use and consumed by the transfer that follows. Nothing here drains,
  // retires, detaches or destroys anything: a refusal leaves the Owner interval
  // exactly as it was, with admission closed and the requests the Engine already
  // holds owned.
  [[nodiscard]] std::optional<Quiescence> prepareResourceHandoff(
      ResourceDomainLease &lease);

  [[nodiscard]] bool connectionMustClose() const noexcept {
    return closeConnection_;
  }
  [[nodiscard]] bool engineHealthy() const noexcept { return engineHealthy_; }
  // Code and message of the failure that stopped the engine, for the log.
  [[nodiscard]] const std::string &engineFailure() const noexcept {
    return engineFailure_;
  }
  [[nodiscard]] bool commandInFlight() const noexcept {
    return core_ && core_->commandInFlight();
  }
  // [Gate 2] The request-side drain witness at the native boundary: the
  // Engine's own categories (Engine::requestDrain, T016) with the loop's
  // per-request records added to them. Both are request-side owners: a
  // request's telemetry entry is erased only after its terminal frame
  // (NativeRuntime::ended), and a mask response the server still owes keeps
  // the loop's half of that wait. Neither count is taken for any other
  // category's: this says nothing about retained KV/state writes (Gate 3) or
  // retired GPU/host callbacks and ANE descendants (Gate 4).
  [[nodiscard]] engine::Engine::RequestDrain requestDrain() const {
    auto drain = core_ ? core_->requestDrain() : engine::Engine::RequestDrain{};
    // One entry per request the loop still describes.
    drain.records += static_cast<uint32_t>(telemetry_.size());
    // One per mask the loop asked the server for and has not been given.
    drain.masks += static_cast<uint32_t>(pendingMasks_.size());
    return drain;
  }
  // How long FdTransport may block in poll(2): the earliest of the loop's
  // wake sources, converted to a nonnegative remaining duration once, and
  // without a limit when it has none — the Engine's next timed event
  // (Engine::nextWakeupMilliseconds), the retained persistence queue's
  // next point falling due or stalled write-budget admission
  // (WriteBehind::nextWakeup), and a deferred restore retry one backoff
  // after the read. The persistence source belongs to the retained graph:
  // it needs no Engine to be representable.
  [[nodiscard]] std::optional<double> millisecondsUntilNextWakeup() const;
  // The aggregation itself, testable on its own: absolute points on the
  // loop's clock in, one nonnegative duration (or no deadline) out.
  [[nodiscard]] static std::optional<double>
  nextWakeupBoundMilliseconds(double now, std::optional<double> engineWakeup,
                              std::optional<double> persistenceWakeup,
                              bool restoreRetryDue);

  [[nodiscard]] engine::EngineSnapshot snapshot() const {
    return core_ ? core_->snapshot() : engine::EngineSnapshot{};
  }
  // The snapshot /status reports: each live request's age counted from its
  // arrival, on the runtime's clock.
  [[nodiscard]] engine::EngineSnapshot statusSnapshot() const;
  // The weights as the loop holds them; absent weights read as held (not
  // released), which `idleReleaseSeconds` keeps reporting, so a consumer
  // distinguishes them by the loop being built without weights, not by a
  // live released measurement.
  [[nodiscard]] WeightsSnapshot weightsSnapshot() const { return core_ ? core_->weightsSnapshot() : WeightsSnapshot{idleReleaseSeconds_}; }
  [[nodiscard]] RuntimeMetricsSnapshot metricsSnapshot() const { return metrics_.snapshot(); }
  [[nodiscard]] engine::ResourceWaitSnapshot resourceWaitSnapshot() const;
  [[nodiscard]] double monotonicMilliseconds() const {
    return config_.monotonicMilliseconds();
  }
  void collectLandings(double now) { if (core_) core_->collectLandings(now); }

private:
  struct RequestTelemetry {
    double arrivedMilliseconds = 0.0;
    double deadlineMilliseconds = 0.0;
    // Empty until the engine starts the request (EngineEventSink::started).
    std::optional<double> startedMilliseconds;
    std::optional<double> firstTokenMilliseconds;
    std::optional<double> lastTokenMilliseconds;
    uint32_t emittedTokens = 0;
    // What held it before its first token, as the engine counted it
    // (EngineEventSink::firstTokenParts).
    TtftParts ttftParts{};
  };

  struct PendingMask {
    uint64_t maskRequestId = 0;
    uint64_t expectedWords = 0;
  };

  bool handle(protocol::ClientMessage &message);
  bool handleRequest(protocol::RequestFrame &request);
  [[nodiscard]] bool resourceAuthorityHeld() const { if (resourceAuthorityHeld_) return resourceAuthorityHeld_();
    const auto *lease = core_ ? core_->borrowedConfig().writerLease : config_.engine.writerLease;
    return !lease || lease->holder() == ResourceDomainAuthority::Holder::Owner; }
  [[nodiscard]] bool weightsHeld() const { return !core_ || core_->weightsHeld(); }
  bool handleCancel(const protocol::CancelFrame &cancel);
  bool handleStop(const protocol::StopFrame &stop);
  bool handleMask(const protocol::MaskResponseFrame &mask);
  bool handleStatus(const protocol::StatusRequestFrame &status);
  bool handleRelease(const protocol::ReleaseRequestFrame &release);
  bool handleMaskIssue(protocol::ProtocolIssue issue);
  bool handleIssue(protocol::ProtocolIssue issue);
  void requestError(uint64_t requestId, std::string code, std::string message,
                    bool retryable = false, uint32_t retryAfterSeconds = 0);
  void engineError(std::string code, std::string message);
  void executionFailed(std::exception_ptr error);
  bool send(const protocol::EngineEvent &event);
  // After a request's terminal event: the engine no longer holds it.
  void ended(uint64_t requestId);
  void bindHandoffWitnesses(ResourceDomainLease &lease);

  void started(uint64_t requestId, uint32_t matchedTokens,
               uint32_t lane) override;
  void batchCompleted(WorkKind kind, uint32_t width, uint32_t inputTokens,
                      uint32_t outputTokens, uint32_t draftedTokens,
                      uint32_t acceptedDraftTokens, double wallMilliseconds,
                      double cycleMilliseconds) override;
  void promptProgress(uint64_t requestId, uint32_t processedTokens) override;
  void firstTokenParts(uint64_t requestId, const TtftParts &parts) override;
  void tokens(uint64_t requestId, std::span<const uint32_t> values) override;
  void maskRequested(uint64_t requestId,
                     std::span<const uint32_t> simulationTokens) override;
  void completed(uint64_t requestId, EngineFinishReason reason, bool bounded,
                 uint32_t promptTokens, uint32_t completionTokens,
                 uint32_t deduplicatedTokens,
                 std::span<const float> optionLogits,
                 const SpeculativeCounts &speculation) override;
  void failed(uint64_t requestId, LaneOutcome outcome,
              std::string message, uint32_t retryAfterSeconds) override;

  static uint64_t durationMicros(double startMilliseconds,
                                 double endMilliseconds);

  // [Gate 1 proof / T019] What the lease's four witness closures read through.
  // It is shared: this loop owns it, and every closure a lease has been given
  // keeps it alive too, so an authority that outlives the loop never dangles —
  // its categories read false from `detached` instead of reaching a loop, Engine
  // or Cache already gone. The pointers it names are written once, in the
  // constructor, and only the loop's own thread reads them: a lease evaluates
  // its witnesses at the Owner interval's safe point, which is the thread this
  // loop is torn down on, so no evaluation overlaps the teardown that sets
  // `detached`. Nothing here is a flag a caller may clear to let a witness pass:
  // the categories read the gate, the drain, the Cache and the Engine.
  struct HandoffEvidence final {
    std::atomic<bool> detached{false};
    // The gate, the request-side drain and the Engine's callbacks.
    NativeRuntime *loop = nullptr;
    // The retained graph's IO; outlives the loop by this loop's contract.
    const engine::Cache *cache = nullptr;
  };
  std::shared_ptr<HandoffEvidence> evidence_{std::make_shared<HandoffEvidence>()};
  // [T028] Bound by the owning lifecycle (RuntimeBootstrap); empty means no
  // lease is in play over this loop and the wake sources read as they always
  // did. See resourceAuthorityHeld().
  std::function<bool()> resourceAuthorityHeld_;
  std::shared_ptr<PendingPowerObservation> powerObservation_;
  NativeAdmissionGate admission_;
  NativeLoopConfig config_;
  std::optional<uint32_t> publishedContext_;
  double idleReleaseSeconds_;
  ByteSink output_;
  StatusProvider statusProvider_;
  protocol::ProtocolLimits limits_;
  protocol::FrameParser parser_;
  RuntimeMetrics metrics_;
  // The persistence queue the Engine borrows, kept for the retained graph:
  // its next wake point is a poll source even where no Engine is (T011/U-04).
  // Null where the shell was built without a retained graph (T023 cold start):
  // no persistence point exists to wake for until publishEngine binds one.
  WriteBehind *writeBehind_ = nullptr;
  // The queue's own Cache, bound with the queue: the clean-stop flush of a
  // queue that outlived a detached Engine lands its transfers through it.
  engine::Cache *cache_ = nullptr;
  // [T024] The one Engine this shell currently publishes, or none. Every
  // Engine-scoped path reads absence instead of reaching a destroyed Engine;
  // only the lifecycle's designated safe-point detach (destroyEngine) moves
  // this out, and only the owner's publishEngine/tryPublishEngine put one in.
  std::unique_ptr<engine::Engine> core_;
  // [T024] The loop's completion notifier: stored here so detaching the Engine
  // that currently carries it loses nothing, and the next Engine rebinds it.
  std::function<void()> completionNotifier_;
  std::unordered_map<uint64_t, RequestTelemetry> telemetry_;
  std::unordered_map<uint64_t, PendingMask> pendingMasks_;
  uint64_t nextMaskRequestId_ = 1;
  bool ready_ = false;
  bool closeConnection_ = false;
  bool engineHealthy_ = true;
  bool deferredEngineFailure_ = false;
  void reportEngineFailure();
  void flushEngineFailure();
  std::string engineFailure_;
};

} // namespace splash::engine
