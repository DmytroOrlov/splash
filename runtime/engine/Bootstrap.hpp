#pragma once

#include "AwakeClock.hpp"
#include "engine/MemoryControl.hpp"
#include "engine/NativeRuntime.hpp"
#include "engine/RecoveryCandidate.hpp"
#include "engine/RuntimeResources.hpp"
#include "engine/Status.hpp"
#include "engine/ThermalState.hpp"

#include <chrono>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>

namespace splash::engine {

enum class RuntimeBootstrapStage {
    ResourceAssembly,
    ModelCreation,
    MaximumPrefill,
    PrefillRowClasses,
    DecodeWarmup,
    CompositeStateRestore,
    MemoryAudit,
    Ready,
};

[[nodiscard]] std::string_view runtimeBootstrapStageName(
    RuntimeBootstrapStage stage);

// A report of a successful bootstrap is at stage Ready.
struct RuntimeBootstrapReport {
    RuntimeBootstrapStage stage = RuntimeBootstrapStage::ResourceAssembly;
    // The step of resource assembly that failed; empty past resource assembly.
    std::optional<RuntimeResourceStage> resourceStage;
    RuntimeResourceFailure resourceFailure = RuntimeResourceFailure::Other;
    std::string message;
    WarmupReport warmup;
    MemoryAuditResult memoryAudit;
    std::string budgetDescription;
    // What a start refused for want of memory or context needed against what
    // it had: RuntimeResourcesError::shortfall, or the --max-context check.
    std::optional<protocol::StartShortfall> shortfall;
    // A command of the start failed: a warmup's, or one of resource assembly
    // (RuntimeResourcesError::commandFailed); and whether for want of GPU
    // memory (metal::MetalBackendError::outOfMemory).
    bool commandFailed = false;
    bool commandOutOfMemory = false;

    [[nodiscard]] std::string describe() const;
};

class RuntimeBootstrapError final : public std::runtime_error {
public:
    explicit RuntimeBootstrapError(RuntimeBootstrapReport report);
    explicit RuntimeBootstrapError(const RuntimeResourcesError &error);

    [[nodiscard]] const RuntimeBootstrapReport &report() const noexcept {
        return report_;
    }

private:
    RuntimeBootstrapReport report_;
};

// The failure a start reports in place of Ready (main.mm), classed for the
// server's restart policy and the app's words.
[[nodiscard]] protocol::StartFailedEvent startFailedEvent(
    const RuntimeBootstrapReport &report);

// Startup retries a temporary host or driver allocation failure for a
// bounded time. The window opens at the first such failure, not at process
// start, since a start loads the weights and warms up for a while before
// one; a failure at a later stage, or a later step of resource assembly,
// than the failure that opened the window follows progress and opens a new
// one.
class StartupRetryWindow final {
public:
    using Clock = AwakeClock;

    explicit StartupRetryWindow(Clock::duration length) noexcept
        : length_(length) {}

    // Until when startup may retry after this failure; nothing when the
    // failure is not temporary or its window has closed.
    [[nodiscard]] std::optional<Clock::time_point>
    retryUntil(const RuntimeBootstrapReport &failure, Clock::time_point now);

private:
    Clock::duration length_;
    std::optional<Clock::time_point> deadline_;
    // How far the failure that opened the window got.
    std::pair<RuntimeBootstrapStage, std::optional<RuntimeResourceStage>>
        reached_;
};

// Temporary host/driver allocation failures can recover during startup,
// within supervision::kStartRetryWindow, checked this often. Configuration
// and compute failures, a command's want of GPU memory among them, remain
// immediate and fail-closed.
inline constexpr auto kStartupMemoryRecoveryPoll = std::chrono::seconds(1);

// The wire limits of a model served with maxContext tokens: prompts and
// outputs up to the context, the engine's step and draft query rows, and a
// mask row per draft query and the anchor.
[[nodiscard]] protocol::ProtocolLimits
protocolLimitsFor(const model::ModelCapabilities &capabilities,
                  uint32_t maxContext) noexcept;

// What a model served under `engine` and `limits` (protocolLimitsFor)
// announces in Ready.
[[nodiscard]] protocol::ReadyEvent readyEventFor(
    const model::ModelDescriptor &model, const EngineConfig &engine,
    const protocol::ProtocolLimits &limits);

struct RuntimeBootstrapConfig {
    RuntimeResourcesConfig resources;
    // A relaunch serves its context (RuntimeResourcesConfig::relaunchContext)
    // as far as the memory plan holds it. Otherwise a zero engine maxContext
    // is what the plan holds, as serve's default, and another one larger
    // than the plan holds fails the bootstrap.
    NativeLoopConfig nativeLoop;
    // [T023] The lifecycle power the process begins with, for a model-less
    // cold start: the battery policy's INJECTED initial observation. Real OS
    // registration and the synchronous initial sample belong to T026;
    // startModelLess() establishes the pump from this value alone.
    std::optional<LifecyclePower> initialPower;
    // [T020/T022] Wakes the native control loop after a queued power observation
    // or a residency-worker completion lands, so the owner's pump advances at the
    // next command-free point. The callback must not capture model or Engine
    // residency; the production wiring is transport.controlNotifier(), whose
    // registration is T025/T026's.
    std::function<void()> lifecycleWake;
};

using ActualMemoryReporter = std::function<ActualMemoryReport()>;
using WarmupProgress = std::function<void(const protocol::WarmingEvent &)>;

// The serving runtime: start() returns it built, warmed up and audited, and
// it serves once announceReady() has sent Ready. Everything that can refuse
// a start (StartFailed) runs in start(), so that nothing after Ready can.
class RuntimeBootstrap final {
public:
    // loopMaxTick: the loop's longest tick, which its transport measures,
    // for the status document. Throws std::invalid_argument without it.
    [[nodiscard]] static std::unique_ptr<RuntimeBootstrap> start(
        RuntimeBootstrapConfig config,
        NativeRuntime::ByteSink output,
        std::function<double()> loopMaxTick);

    // [T023] The cold Battery/Unknown startup: a model-less control shell over
    // the SAME native protocol — NO RuntimeResources, no Metal backend, no
    // loaded model, no Engine, no synthetic retained Cache, no warmup or
    // prefix replay. Exactly one ReadyEvent announces control readiness (the
    // loop's, not inference's), native admission starts CLOSED, and the
    // static configured capability (the descriptor's context ceiling and
    // vocabulary) stays available without any model allocation. The pump
    // establishes its lifecycle authority from config.initialPower (the
    // battery policy's injected observation), and the first valid AC intent
    // may request one private residency-worker construction; physical
    // adoption of what a worker builds is the T029–T033 protocol and NOT
    // done here. A Disabled Battery policy never calls this: ordinary
    // upstream start() is untouched.
    [[nodiscard]] static std::unique_ptr<RuntimeBootstrap> startModelLess(
        RuntimeBootstrapConfig config,
        NativeRuntime::ByteSink output,
        NativeRuntime::StatusProvider statusProvider);

    // Completes warmup and validation, at stage Ready. Warmup runs on
    // kvPool's runway (model::ExecutionLimits::warmupKvPages) and holds its
    // pages while it runs (KvPool::RunwayHold): a prefill of the most rows,
    // one of each of `prefillRowClasses` (ops::ExecutionPlans), each decode
    // width that fits and a state restore. `progress` takes the steps done of
    // all (protocol::WarmingEvent) as it begins and as each step ends.
    [[nodiscard]] static RuntimeBootstrapReport requireWarmup(
        const EngineMemoryPlan &memoryPlan,
        std::span<const uint32_t> prefillRowClasses,
        model::RuntimeModel &modelRuntime,
        KvPool &kvPool,
        WarmupProgress progress,
        ActualMemoryReporter memoryReporter);

    RuntimeBootstrap(const RuntimeBootstrap &) = delete;
    RuntimeBootstrap &operator=(const RuntimeBootstrap &) = delete;
    ~RuntimeBootstrap();
    // Terminal teardown boundary, on the native owner thread after transport
    // termination: retire Writer, join the residency worker, return parked
    // authority and dispose unadopted candidates before flushing retained IO.
    // Keeps the loop and retained resources alive; safe to call again.
    void retireForShutdown();

    [[nodiscard]] RuntimeResources &resources() noexcept {
        return *resources_;
    }
    [[nodiscard]] model::RuntimeModel &modelRuntime() noexcept { return *model_; }
    void setPowerObservation(std::shared_ptr<PendingPowerObservation> observation) {
        powerObservation_ = std::move(observation);
        nativeLoop_->setPowerObservation(powerObservation_);
    }
    [[nodiscard]] NativeRuntime &nativeLoop() noexcept {
        return *nativeLoop_;
    }
    void announceReady();
    // [T023/T024] Whether this Bootstrap retains a graph at all: a model-less
    // cold shell holds no RuntimeResources, and after the physical-detach
    // safe point (T024) the RuntimeModel it held has moved to the
    // residency-worker disposal. Every domain-bound read below refuses while
    // these are false; status and the control plane do not need them.
    [[nodiscard]] bool hasResources() const noexcept {
        return resources_ != nullptr;
    }
    [[nodiscard]] bool hasModelRuntime() const noexcept {
        return model_ != nullptr;
    }

    // ---- [T020] The sole native lifecycle-owner pump ----
    // The lifecycle owner's state machine. Only the native safe-point thread
    // advances it: observePower (any thread) records the latest detached
    // observation and wakes the control loop; the pump consumes it and steps
    // the state machine at the next command-free point (advanceLifecycle, run
    // from controlPass). It never loads a model, allocates Metal, joins a
    // worker or releases residency inline: every expensive step is delegated
    // to the single residency worker (T022), and expensive owner-thread work
    // is refused at the domain's own authority while that worker holds it.

    // A power callback's record: only the latest detached value is kept, and
    // only a changed power intent mints a new lifecycle revision. Unknown or
    // Battery power never authorizes new inference or recovery.
    void observePower(LifecyclePower power);
    // An authoritative terminal shutdown intent: it supersedes Draining,
    // Suspended and Recovering, invalidates an in-flight residency-worker
    // operation's intent before teardown joins it, and later power observations
    // never revive the lifecycle. True the first time it is taken.
    [[nodiscard]] bool shutdownLifecycle();
    // The lifecycle's detached, value-owned snapshot. Passive: it never
    // advances the pump, starts nothing and touches no resource domain.
    [[nodiscard]] LifecycleStatusSnapshot lifecycleStatus() const;

    // The control pass the transport runs at a command-free point: it samples
    // the thermal state, advances the lifecycle pump, keeps the disk tier within
    // what its volume leaves it (Cache::keepDiskLimit), and runs the memory
    // control pass (MemoryControl::run). The last two mutate the resource
    // domain, so they run only while this thread holds its authority; while
    // the residency worker or a parked completion holds the domain, the pass
    // stays detached (the full responsive policy is T025's).
    [[nodiscard]] bool controlPass(MemoryPressure pressure);
    // The status document, with the metrics and the loop timing the
    // transport keeps.
    [[nodiscard]] std::string statusJson(const RuntimeMetricsSnapshot &metrics,
                                         const NativeLoopTiming &loop);

private:
    friend class RuntimeBootstrapTestAccess;
    RuntimeBootstrap(std::unique_ptr<RuntimeResources> resources,
                     std::unique_ptr<model::RuntimeModel> modelRuntime,
                     std::unique_ptr<NativeRuntime> nativeLoop,
                     RuntimeBootstrapReport report,
                     std::function<void()> lifecycleWake,
                     uint32_t contextCeiling);

    // Records the thermal state macOS reports for the status document, and
    // logs a change: nothing else tells why serving slowed down. The control
    // pass is the loop's regular tick, so a polled state needs no observer
    // of its own.
    void sampleThermalState();

    // ---- [T020] The owner-side pump steps, all on the safe-point thread ----
    // One safe point: consumes the queued power observation (minting a revision
    // only on a power change, and a newer observation sequence for every value
    // it consumes — [T034] a consumed duplicate is still a new status order)
    // and advances the state machine Ready -> Draining
    // -> Suspended -> Recovering -> Ready, through RecoveryFailed and terminal
    // Shutdown, claiming and fencing a completed worker envelope. It never
    // performs the expensive work; it only starts the residency worker or
    // adopts/reaps what it published.
    void advanceLifecycle();

    // Whether this thread currently holds the graph's own resource-domain
    // authority (the Owner interval): the disk limit and memory control run
    // only while it does.
    [[nodiscard]] bool resourceDomainHeld() noexcept;

    // Rebuilds the published lifecycle snapshot from the pump's fields,
    // bumping observationSequence for every change the caller reports: a
    // state/power change, and every power observation the pump consumes
    // ([T034] including one whose value duplicates the applied power). Called
    // under lifecycleMutex_ by the pump; lifecycleStatus() reads the same fields
    // and versions nothing.
    void publishLifecycle(bool changed);

    // The same snapshot lifecycleStatus()/advanceLifecycle() publish, built
    // from the current pump fields (lifecycleStatus() reads it under
    // lifecycleMutex_).
    [[nodiscard]] LifecycleStatusSnapshot lifecycleSnapshotLocked() const;

    // Returns a claimed envelope's parked Worker token to the Owner interval
    // of the envelope's REAL domain (this thread), then drops it from the
    // envelope; a no-op when the envelope carried none. [T029] The destination
    // is selected by the envelope's own graph identity (a cold candidate's
    // RuntimeResources, a warm completion's retained graph), the token's
    // belonging is checked BEFORE it is consumed, and a mismatched or
    // missing domain fails closed without losing the sole WorkerHandoff.
    void returnHandoffToOwner(CompletionEnvelope &envelope);

    // [T024] The disposable stratum a suspension safe point moved out: the
    // published Engine, this Bootstrap's RuntimeModel and the graph's
    // model-bound residency — moved (never destroyed) on the safe-point thread
    // into the ONE residency-worker operation that physically destroys them,
    // under its claimed Worker interval, in the T021 order
    // Engine -> RuntimeModel -> residency. Owned here only between the safe
    // point and the operation's start (which the pump's own fence makes
    // cannot-fail), and destroyed on the worker either way.
    struct PendingDisposal final {
        std::unique_ptr<engine::Engine> engine;
        std::unique_ptr<model::RuntimeModel> model;
        std::optional<engine::ModelResidency> residency;
        [[nodiscard]] bool empty() const {
            return !engine && !model && !residency;
        }
    };

    // [T024] The safe point's move-out, run only after the four-witness quiescence
    // proof for this graph minted: NativeRuntime::destroyEngine() first (which
    // closes admission and refuses while any drain barrier stands), then the
    // RuntimeModel and the residency out of their owners. Refusal leaves every
    // one published and returns nothing.
    [[nodiscard]] std::unique_ptr<PendingDisposal> detachDisposalAtSafePoint();

    // [T024] The default (no test seam installed) disposal the residency
    // operation runs ON THE WORKER THREAD, under its claimed Worker interval:
    // destroys the moved-out stratum (callbacks -> ANE -> plans -> model order
    // inside each part) and reports the DisposalReceipt, naming the worker
    // thread and the backend's allocation after. Never joined or run from a
    // safe point.
    DisposalReceipt physicalDisposal(PendingDisposal &disposal);

    // [T022] Delegates one disposal / one construction to the single residency
    // worker on the transferred token. The pump never performs the work: it
    // supplies the seam task and the cooperative cancel. False only if a running
    // worker holds the slot, which the pump already rules out. The physical
    // payload of a T024 detachment is not a parameter: it lives in pendingDisposal_
    // between the safe point and the operation (std::function's Task is
    // copyable, so it cannot carry a unique_ptr), and the operation's task ends
    // that ownership on the worker thread.
    [[nodiscard]] bool startResidencyDisposal(WorkerHandoff &&token,
                                             uint64_t revision);
    [[nodiscard]] bool startResidencyConstruction(WorkerHandoff &&token,
                                                  uint64_t revision);
    // [T023/T024] A cold model-less shell has no resource domain to transfer
    // (no lease exists until recovery builds one), so its requested private
    // construction runs on the worker with NO handoff token: nothing in the
    // task can borrow a domain the pump never owned, and the cooperative
    // revision fence still applies. Requested at most once; what a built
    // candidate becomes is the T029–T033 protocol, not this task's.
    [[nodiscard]] bool startColdResidencyConstruction(uint64_t revision);

    // [T031 prerequisite] What a residency worker builds for a recovery, in
    // production: the same construction a fixture's WorkerSeams::build stands
    // in for. COLD assembles its OWN graph (backend, model, plans, split,
    // governor, lease) with RuntimeResources::create and owns it; WARM rebuilds
    // ONLY a private ModelResidency against the RETAINED graph (never a second
    // backend, Cache, KV or WriteBehind) and borrows that graph by identity.
    // Either way the Engine is the loop's own makePrivateEngine: private to the
    // candidate, published nowhere, admission untouched. Throws for a construction
    // that cannot be made (the worker records it as a failed envelope, exactly
    // as it does for any other task exception); cooperative cancellation is
    // checked at every boundary the loader and the arena admission take.
    [[nodiscard]] std::unique_ptr<RecoveryCandidate>
    buildCandidateOnWorker(const WorkerCancellation &cancelled, bool cold,
                           uint64_t revision);

    // [T029] The cold candidate's OWN four-witness quiescence, established on
    // the thread that BUILT its graph (the residency worker), after the last
    // cancellation cleanup: the witness categories read the candidate's own
    // objects (its Engine's request drain and callback retirement, its
    // Cache's retained IO, and for its ingress this shell's admission gate
    // plus "this candidate Engine is not published"), the candidate's own
    // lease mints the proof, and transferToWorker/claim/park on this same
    // thread hand the parked token to the operation's outcome, which the
    // published envelope then carries. Refusal disposes the candidate while
    // this thread still lawfully holds its Owner interval and publishes a
    // failure, never a resource-owning candidate without its mandatory token.
    void bindCandidateHandoffWitnesses(ResourceDomainLease &lease,
                                       RecoveryCandidate &candidate);
    void handoffColdCandidateOnWorker(RecoveryCandidate &candidate,
                                      WorkerOutcome &outcome);

    // [T032] One serial reap of the oldest stale candidate still queued,
    // requested by the pump at a safe point under THIS Owner thread's
    // authority over the envelope's real domain: a cold candidate's OWN lease
    // (through the candidate witnesses above), a warm one the RETAINED graph's
    // (prepareResourceHandoff, plus the candidate's own drain categories read
    // directly before any mint). A fresh proof is required: without one the
    // candidate stays in the pending queue and is retried at a later safe
    // point; the token goes to the ONE existing worker, and reaping never
    // overlaps a construction, another disposal or another reap.
    [[nodiscard]] bool startCandidateReaper(uint64_t revision);

    // [T020/T022] Teardown-only: joins the residency worker whose intent
    // shutdownLifecycle() already invalidated, then claims and fences a
    // completion that landed, returning its parked token so the domain ends
    // the Owner interval before ~ResourceDomainLease. Not a safe point.
    void joinResidencyWorker();
    void drainLifecycleMailbox();

    // [T032] Where a claimed completion's ownership goes: a candidate that
    // still owns residency moves to the pending-reap queue, everything else
    // stays in the retained bookkeeping. A MOVE either way: no destructor of
    // anything physical runs here (the caller holds lifecycleMutex_).
    void retainCompletionLocked(CompletionEnvelope &&envelope);

    // [T031/T033] The REAL two-phase production adoption transaction the pump
    // runs for a candidate its production builder built (no construction seam
    // installed). Phase 1, on the Owner's safe-point thread, OUTSIDE
    // lifecycleMutex_, with admission CLOSED: validate graph identity, capacity
    // and residency compatibility, then physically stage — the Engine and the
    // shell's graph-bound bindings via NativeRuntime::stageAdoption, the warm
    // candidate's private residency into the retained graph, its RuntimeModel
    // into this Bootstrap, and (cold only) this Bootstrap's memory control and
    // the graph's directory serving — every step reversible. Phase 2 reacquires
    // lifecycle synchronization and evaluates the complete final fence; only a
    // still-current AC observation commits: finalize, publish Ready and the
    // exact adopted Engine context, open native admission once, no ReadyEvent
    // re-announcement and no second graph. A boundary throw, a fence failure
    // (Battery/Battery→AC/Shutdown between the phases) or shutdown rolls the
    // WHOLE candidate back outside the lock and queues it to the ONE reaper.
    struct AdoptionStaging final {
        std::unique_ptr<NativeRuntime::StagedAdoption> staged;
        RecoveryCandidate *candidate = nullptr;
        engine::Engine *engine = nullptr;
        model::RuntimeModel *model = nullptr;
        RuntimeResources *graph = nullptr;
        bool cold = false;
        bool residencyMoved = false;
        bool modelMoved = false;
        bool stagedOk = false;
        std::string refusal;
    };

    // [T031] Phase 1. A refusal leaves the candidate exactly as the worker
    // published it (every part still owned) and records the reason.
    [[nodiscard]] bool stageAdoptionTransaction(CompletionEnvelope &envelope, AdoptionStaging &staging);
    // [T031] The undo of a staged transaction, run outside every lock: Engine
    // ownership and every moved part return to the candidate, the shell and
    // the retained graph read exactly as before the staging, and every original
    // object address is unchanged.
    void rollbackAdoptionTransaction(AdoptionStaging &staging) noexcept;
    // [T033] The complete final fence, evaluated under lifecycleMutex_:
    // !shutdown, still Recovering, AC applied with no pending non-AC intent,
    // lifecycle revision AND the raw power-observation generation unchanged
    // since the candidate was claimed, the exact staged Engine/model/graph
    // physically installed, the effective published Engine context valid within
    // contextCeiling_, and native admission still closed.
    [[nodiscard]] bool finalAdoptionFenceOk(const CompletionEnvelope &envelope, const AdoptionStaging &staging, uint64_t capturedRevision, uint64_t capturedGeneration) const;

    // [T022] The single Bootstrap-owned serial residency worker: it performs
    // BOTH asynchronous destructive-residency disposal (suspension side) and
    // asynchronous private-candidate construction (recovery side), all off the
    // native safe point. EXACTLY ONE operation is ever in flight: a construction
    // never overlaps a destructive disposal (the pump never starts a second
    // while one runs, and start() joins only an already-published prior
    // operation). The worker claims the graph's transferred token, does its
    // (seam-supplied) work, parks the token after its last domain-borrowing
    // operation, then publishes exactly one completion envelope and wakes the
    // existing control notifier; it never joins from a safe point (the pump
    // joins an already-completed worker only), and shutdown invalidates the
    // operation's intent before teardown joins it. The expensive disposal
    // construction is a seam until T024/T029-T033 wire it; a running worker is
    // NEVER joined by an ordinary safe-point operation.
    class ResidencyWorker final {
     public:
        // [T032] The task runs on the worker thread AFTER the operation's
        // incoming token has been claimed, and is handed that claimed token
        // (nullptr for a cold construction, which has none): the generic path
        // parks it after the task, but a cold candidate's REAP ends its own
        // domain's interval INSIDE the task — park, return to the candidate's
        // own lease, only then destroy the candidate-owned graph — which leaves
        // the token spent, so run() parks nothing further. Consuming the token
        // in the task is the smallest explicit mechanism that lets the domain
        // return land before the graph it guards is destroyed.
        using Task = std::function<WorkerOutcome(const WorkerCancellation &,
                                                 WorkerHandoff *)>;

        ResidencyWorker() = default;
        ResidencyWorker(const ResidencyWorker &) = delete;
        ResidencyWorker &operator=(const ResidencyWorker &) = delete;
        ~ResidencyWorker();
        // Starts the one in-flight operation. The token is the graph's transferred
        // Owner handoff when one exists; a cold model-less shell starts an
        // operation with NO token ([T023] nothing may borrow a domain the pump
        // never owned) and a cold FIRST candidate then supplies its own interval
        // from its own lease inside its task ([T029]). False while one is still
        // running (a running worker is never joined or restarted here). Reuses
        // the slot only after joining an already-published prior operation.
        // [T029] tokenDomain names the graph a returned token belongs to when
        // the completion's payload cannot (a reap that aborted cooperatively
        // hands back its candidate's token with no candidate payload); null
        // means the retained graph, or none.
        [[nodiscard]] bool start(std::optional<WorkerHandoff> token,
                                 uint64_t revision,
                                 CompletionChannel &channel,
                                 WorkerCancellation cancel, Task task,
                                 RuntimeResources *tokenDomain = nullptr);
        // Whether an operation runs on the worker thread and has not yet
        // published: passive, joins nothing.
        [[nodiscard]] bool running() const;

        // Joins the worker thread if one exists (its intent is already invalid
        // by the only call site, shutdown/teardown): reuses nothing.
        void joinCompleted();

     private:
        void run();  // the worker thread's body

        mutable std::mutex mutex_;
        std::thread thread_;
        CompletionChannel *channel_ = nullptr;
        std::optional<WorkerHandoff> token_;
        RuntimeResources *tokenDomain_ = nullptr;
        uint64_t revision_ = 0;
        Task task_;
        WorkerCancellation cancel_;
        bool running_ = false;
    };

    // Reverse destruction order is loop -> modelRuntime -> resources.
    std::unique_ptr<RuntimeResources> resources_;
    std::unique_ptr<model::RuntimeModel> model_;
    std::unique_ptr<NativeRuntime> nativeLoop_;
    std::string ownerStatusJson();
    std::optional<StatusSample> lastStatusSample_;
    ResourceSnapshot lastRetainedStatus_;
    void rememberRetainedStatus(const metal::MetalMemoryStats &metal);
    bool memoryPublicationPending_ = false;
    std::function<double()> loopMaxTick_ = [] { return 0.0; };
    protocol::ReadyEvent ready_;
    // [T023] Absent in a model-less cold shell: memory pressure control governs
    // the retained domain, which that startup does not have.
    std::optional<MemoryControl> memoryControl_;
    RuntimeBootstrapReport report_;
    ThermalStateReporter thermalState_;

    // [T020-T022] The lifecycle-owner state, declared after the graph it owns
    // and the loop it borrows so the worker is joined and its completed
    // envelopes released before the loop, model and resources; lifecycleMutex_
    // precedes the worker so it is still alive when teardown joins the worker's
    // thread, and the worker is declared last so it is destroyed first.
    std::function<void()> lifecycleWake_;
    CompletionChannel lifecycleMailbox_;
    // The seams a residency operation runs until T024 (physical disposal) and
    // T029-T033 (cold-first candidate + adoption) wire production work. Empty
    // dispose reports the transfer it made; empty build refuses with a failure
    // the pump records without stranding the domain's authority.
    struct WorkerSeams final {
        // Test-only boundary after a real warm build, before mailbox publication.
        // It never substitutes construction, disposal, adoption or authority.
        std::function<void(const RecoveryCandidate &, const WorkerCancellation &)> warmCandidateBuilt;
        std::function<void()> coldHandoffComplete;
        std::function<void()> coldReapClaimed;
        std::function<DisposalReceipt(const WorkerCancellation &)> dispose;
        std::function<std::unique_ptr<RecoveryCandidate>(
            const WorkerCancellation &)> build;
        std::function<bool(const RecoveryCandidate &)> adopt;
        // [T029] The four categories a cold candidate's OWN lease consults
        // (construction and reap alike). Empty installs the production
        // witnesses, which read the candidate's real Engine/Cache and this
        // shell's gate; a fixture supplies deterministic controlled categories
        // so each refusal can be exercised on its own. The lease still mints
        // nothing until every category passes: a seam cannot forge quiescence.
        std::function<void(ResourceDomainLease &, RecoveryCandidate &)>
            candidateWitnesses;
    } workerSeams_;
    mutable std::mutex lifecycleMutex_;
    std::shared_ptr<PendingPowerObservation> powerObservation_;
    std::optional<LifecyclePower> pendingPower_;
    LifecyclePower power_ = LifecyclePower::Unknown;
    // The last pressure controlPass() saw, reported through the detached
    // status path too (the pump's intent source; [T025] it must stay legible
    // with the domain gone).
    MemoryPressure lastPressure_ = MemoryPressure::Normal;
    // Whether any power observation has established lifecycle authority.
    // With none (and no shutdown), the detached snapshot stays fail-closed.
    bool lifecycleAuthorityEstablished_ = false;
    LifecycleState state_ = LifecycleState::Ready;
    bool shutdownRequested_ = false;
    // The owner's pump view of residency, independent of the physical release
    // (T024's): true until a disposal envelope lands, again once a candidate
    // is adopted.
    bool pumpModelResident_ = true;
    // An operation the pump started and has not yet seen a completion for.
    bool workerStarted_ = false;
    bool drainDisposalStarted_ = false;
    // [T032] Whether the started operation is a delegated reap: a cold reap's
    // task ENDS the payload's ownership on the worker thread (the candidate
    // and its graph are gone by the time the completion lands), so the pump
    // cannot tell a reap's completion from the payload alone.
    bool reapOperation_ = false;
    // [T023] A model-less cold shell may request its private residency
    // construction at most once, no matter how many AC intents arrive while
    // the un-adoptable candidate's completion sits retained (T029-T033 own
    // adoption): a second request would strand a second worker slot.
    bool coldConstructionRequested_ = false;
    uint64_t workerRevision_ = 0;
    uint64_t lifecycleRevision_ = 0;
    uint64_t observationSequence_ = 0;
    // [T033] The raw power-observation generation: incremented at observePower
    // RECORD time under lifecycleMutex_, for every observation whatever its
    // value. It is NOT observationSequence_ (which counts published lifecycle
    // snapshots, not asynchronous power observations) and it does not change
    // the existing rule that lifecycleRevision_ mints only when the pump
    // CONSUMES a changed power value. A staging window that swallows a
    // Battery, or a Battery→AC pair whose final value equals the current power,
    // is caught by this counter at the final fence.
    uint64_t powerObservationGeneration_ = 0;
    std::optional<uint64_t> failedRecoveryGeneration_;
    std::string lastLifecycleError_;
    // [FR-024] The context the loop serves, captured at construction for the
    // lifecycle snapshot's ceiling/effective context. [T030] It is only ever
    // the STATIC ceiling: what a Ready snapshot reports as effective comes from
    // the published Engine, never from this capture.
    uint32_t contextCeiling_ = 0;
    // [T031 prerequisite] The resolved startup configuration a recovery builds
    // from, retained by both starts: the model, disk, memory and engine settings
    // as this start resolved them. A cold candidate assembles a graph from the
    // resources half; a warm one rebuilds its stratum from that same model and
    // memory description, which is what the residency adoption gate then proves
    // the same graph. Its sinks and lifecycle wake are NOT re-used: the shell's
    // one loop keeps its own.
    std::optional<RuntimeBootstrapConfig> recoveryConfig_;
    // [T024] The disposable stratum a suspension safe point moved out, held
    // here between that safe point and the delegated operation, whose task
    // ends its ownership ON THE WORKER THREAD (std::function's Task is copyable,
    // so the payload is reached through this member, not captured by the
    // closure). A safe point never destroys it and never takes it back.
    std::unique_ptr<PendingDisposal> pendingDisposal_;
    // [T021/T032] A completed envelope whose revision the pump found stale, or
    // a failure, whose payload owns nothing physical (a receipt, or an empty
    // fixture candidate): retained here; the pump never destroys a candidate
    // at a safe point. Shutdown/teardown is the honest exception for whatever
    // ownership still remains: after shutdown invalidated the intent, the
    // joined worker and the mailbox drain, an unadopted candidate ends its
    // ownership on the teardown thread in the reaper's own order, beside the
    // still-retained graph — the refusal to adopt is logged.
    std::deque<CompletionEnvelope> pendingEnvelopes_;
    // [T032] The bounded pending-reap queue: a claimed completion whose
    // candidate still owns residency (its Engine, RuntimeModel, private
    // residency or candidate-owned RuntimeResources) moves OUT of the
    // bookkeeping above into here — a MOVE, so no expensive destructor ever
    // runs under lifecycleMutex_ — and waits for the one serial reaper, which
    // takes the front at a safe point where the worker slot is free. A
    // candidate is never discarded because a reaper cannot start: it stays
    // queued and is retried at a later safe point or wake. Bounded because
    // the pump never runs a second construction while one is retained.
    std::deque<CompletionEnvelope> pendingReaps_;
    // [T032] The ONE envelope the reaper's delegated operation currently owns,
    // moved here (under the lock, no destructor) between the safe point and
    // the operation like pendingDisposal_, and ended ON THE WORKER THREAD.
    // A cooperatively cancelled reap puts its candidate back in the queue
    // instead.
    std::unique_ptr<CompletionEnvelope> pendingReap_;
    // [T033] The deterministic staging-boundary seam the acceptance tests
    // install: it runs on the pump's Owner thread AFTER physical phase-1
    // staging and BEFORE the final fence, OUTSIDE lifecycleMutex_, and never
    // bypasses the real staging path. What it observes (Battery, a Battery→AC
    // pair, Shutdown, a thrown exception) can only be seen by the final
    // fence. Production never installs it; there is no second state machine,
    // event bus or recovery executor behind it.
    std::function<void()> stagingBoundaryTest_;
    // [T022] Declared last: the single residency worker, destroyed (its thread
    // joined) before every field and object it borrows.
    ResidencyWorker residencyWorker_;
};

using ServingRuntime = RuntimeBootstrap;

}  // namespace splash::engine
