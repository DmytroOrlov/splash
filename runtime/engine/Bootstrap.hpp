#pragma once

#include "engine/NativeRuntime.hpp"
#include "engine/RuntimeResources.hpp"
#include "engine/Status.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>

namespace splash::engine {

enum class RuntimeBootstrapStage {
    ResourceAssembly,
    ModelCreation,
    MaximumPrefill,
    DecodeWarmup,
    DraftVerifyCommit,
    CompositeStateRestore,
    MemoryAudit,
    AnnounceReady,
    Ready,
};

[[nodiscard]] std::string_view runtimeBootstrapStageName(
    RuntimeBootstrapStage stage);

struct RuntimeBootstrapReport {
    bool ready = false;
    RuntimeBootstrapStage stage = RuntimeBootstrapStage::ResourceAssembly;
    RuntimeResourceFailure resourceFailure = RuntimeResourceFailure::Other;
    std::string message;
    WarmupReport warmup;
    MemoryAuditResult memoryAudit;
    // Always present once an immutable plan exists. On planning failure this
    // is the full BudgetValidationStatus JSON instead.
    std::string memoryPlanJson;
    std::string budgetDescription;

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

// Startup retries a temporary host or driver allocation failure for a
// bounded time. The window opens at the first such failure, not at process
// start, since a cold start can prepare weights for minutes before one; a
// failure at a later stage than the last one follows progress and opens a
// new window.
class StartupRetryWindow final {
public:
    using Clock = std::chrono::steady_clock;

    explicit StartupRetryWindow(Clock::duration length) noexcept
        : length_(length) {}

    // Until when startup may retry after this failure; nothing when the
    // failure is not temporary or its window has closed.
    [[nodiscard]] std::optional<Clock::time_point>
    retryUntil(const RuntimeBootstrapReport &failure, Clock::time_point now);

private:
    Clock::duration length_;
    std::optional<Clock::time_point> deadline_;
    RuntimeBootstrapStage stage_ = RuntimeBootstrapStage::ResourceAssembly;
};

// Whether memory may not hold a request of contextTokens: the plan within
// what the host had available at startup, beyond its reserve and the warning
// margin, holds less. The estimate is conservative, since macOS compresses
// other applications further once the engine loads.
[[nodiscard]] bool memoryMayNotHold(const EngineMemoryPlan &plan,
                                    uint64_t hostAvailableBytes,
                                    uint32_t contextTokens);

struct RuntimeBootstrapConfig {
    RuntimeResourcesConfig resources;
    // A zero engine maxContext is what the memory plan holds, as serve's
    // default; a larger one than that fails the bootstrap.
    NativeLoopConfig nativeLoop{.engine = {.maxContext = 0}};
    protocol::ProtocolLimits protocolLimits;
    // Process/base-lifetime wake used when private recovery work completes.
    // The callback must not capture model or Engine residency.
    std::function<void()> lifecycleWake;
};

enum class SuspendProgress {
  Idle,
  WaitingForDrain,
  Suspended,
  Superseded,
  ReleaseFailed,
};

enum class RecoveryProgress {
  Idle,
  Building,
  Ready,
  Failed,
  Superseded,
};

using ActualMemoryReporter =
    std::function<ActualMemoryReport(uint64_t estimatedWarmupPeakBytes)>;

// Complete owner returned only after the real loop has emitted its binary
// ReadyEvent. No partially warmed instance escapes start().
class RuntimeBootstrap final {
public:
    [[nodiscard]] static std::unique_ptr<RuntimeBootstrap> start(
        RuntimeBootstrapConfig config,
        NativeRuntime::ByteSink output,
        NativeRuntime::StatusProvider statusProvider);

    // Constructs the long-lived protocol/control shell without allocating
    // inference residency. The native loop remains usable for status/control
    // traffic and can publish an Engine once its dependencies exist.
    [[nodiscard]] static std::unique_ptr<RuntimeBootstrap> startModelLess(
        RuntimeBootstrapConfig config,
        NativeRuntime::ByteSink output,
        NativeRuntime::StatusProvider statusProvider);

    // Completes warmup and validation before announcing readiness.
    [[nodiscard]] static RuntimeBootstrapReport requireWarmupAndAnnounce(
        const EngineMemoryPlan &memoryPlan,
        model::RuntimeModel &modelRuntime,
        ActualMemoryReporter memoryReporter,
        NativeRuntime &nativeLoop);

    RuntimeBootstrap(const RuntimeBootstrap &) = delete;
    RuntimeBootstrap &operator=(const RuntimeBootstrap &) = delete;
    ~RuntimeBootstrap();

    [[nodiscard]] RuntimeResources &resources() {
        if (!resources_)
            throw std::logic_error("model-less bootstrap has no RuntimeResources");
        return *resources_;
    }
    [[nodiscard]] RuntimeResources *resourcesIfPresent() noexcept {
        return resources_.get();
    }
    [[nodiscard]] bool hasResources() const noexcept {
        return resources_ != nullptr;
    }
    [[nodiscard]] bool hasModelRuntime() const noexcept {
        return model_ != nullptr;
    }
    [[nodiscard]] ModelPackageResidency &modelPackageResidency() {
        if (!modelResidency_)
            throw std::logic_error("model-less bootstrap has no ModelPackage");
        return *modelResidency_;
    }
    [[nodiscard]] model::RuntimeModel &modelRuntime() {
        if (!model_)
            throw std::logic_error("model-less bootstrap has no RuntimeModel");
        return *model_;
    }
    [[nodiscard]] model::RuntimeModel *modelRuntimeIfPresent() noexcept {
        return model_.get();
    }
    [[nodiscard]] LifecycleStatusSnapshot lifecycleStatus() const {
        std::lock_guard lock(lifecycleMutex_);
        return lifecycle_;
    }
    // Power observations create monotonically revised intent only when the
    // value changes. Unknown power closes lifecycle inference readiness.
    bool observePower(LifecyclePower power);
    // Publish only work built for the current intent revision.
    bool publishLifecycleStatus(LifecycleStatusSnapshot status);
    // Publish the current private recovery candidate, then open final
    // inference admission only after the revision and residency fence holds.
    [[nodiscard]] bool publishRecoveryCandidate();
    // Shutdown is an authoritative terminal intent; later power observations
    // cannot supersede it.
    bool shutdownLifecycle();
    // Closes final inference admission for the current battery intent and
    // starts a pumpable drain. This never waits for Engine or IO completion.
    bool beginSuspend();
    // Advances one native safe point and, once both drain barriers hold,
    // releases model residency and publishes Suspended through the revision
    // fence.
    [[nodiscard]] SuspendProgress advanceSuspend();
    // Starts private recovery construction on one Bootstrap-owned worker and
    // publishes only completed current-revision candidates on this safe point.
    [[nodiscard]] RecoveryProgress advanceRecovery();
    // Snapshot of the retained graph after model residency has been released.
    [[nodiscard]] ResourceSnapshot detachedResourceSnapshot() const;
    [[nodiscard]] NativeRuntime &nativeLoop() noexcept {
        return *nativeLoop_;
    }
    [[nodiscard]] const RuntimeBootstrapReport &report() const noexcept {
        return report_;
    }

private:
    friend class RuntimeBootstrapTestAccess;

    // Detached, value-owned inputs for reloading the same package and Engine
    // after the current residency stratum has been destroyed. Callback inputs
    // have process/base lifetime; none owns model residency.
    struct RecoverySpec final {
        RuntimeResourcesConfig resources;
        // Battery cold start has no retained base graph. Its first AC attempt
        // creates that graph privately before using the same candidate path.
        bool initializeResourcesIfAbsent = false;
        std::filesystem::path modelRoot;
        model::ModelDescriptor model;
        kv::Format kvFormat = kv::Format::Int8;
        std::string buildId;
        std::function<MemoryPressure()> memoryPressure;
        std::function<bool()> cancelled;
        MemoryGovernor::HostAvailableMemoryProvider hostAvailableMemory;
        std::function<void()> lifecycleWake;
        EngineConfig engine;
    };

    // Declaration order gives reverse destruction as Engine -> RuntimeModel
    // -> ModelPackageResidency. The candidate remains private Bootstrap state.
    struct RecoveryCandidate final {
        // Present only when this is the first AC initialization after a
        // model-less cold start. It outlives every borrower below.
        std::unique_ptr<RuntimeResources> resources;
        std::unique_ptr<ModelPackageResidency> modelResidency;
        std::unique_ptr<model::RuntimeModel> model;
        std::unique_ptr<Engine> engine;
        uint64_t lifecycleRevision = 0;

        ~RecoveryCandidate() {
            engine.reset();
            model.reset();
            modelResidency.reset();
            resources.reset();
        }
    };

    struct RecoveryPublication final {
        Engine *engine = nullptr;
        model::RuntimeModel *model = nullptr;
        ModelPackageResidency *modelResidency = nullptr;
        uint64_t lifecycleRevision = 0;
        uint32_t effectiveContextTokens = 0;
    };

    enum class SuspendPhase { None, Draining, DestructiveRelease };

    [[nodiscard]] SuspendProgress advanceSuspendObserved(
        bool engineDrained, bool transfersInFlight);
    [[nodiscard]] std::optional<RecoveryPublication>
    publishRecoveryResidency();
    [[nodiscard]] bool finalizeRecoveryPublication(
        const RecoveryPublication &publication);
    void buildRecoveryCandidate(uint64_t capturedRevision, RecoverySpec spec);
    [[nodiscard]] std::unique_ptr<RecoveryCandidate> makeRecoveryCandidate(
        std::unique_ptr<ModelPackageResidency> modelResidency,
        std::unique_ptr<model::RuntimeModel> model,
        Cache &cache, const EngineConfig &config,
        uint64_t lifecycleRevision,
        std::unique_ptr<RuntimeResources> resources = nullptr);

    RuntimeBootstrap(std::unique_ptr<RuntimeResources> resources,
                     std::unique_ptr<ModelPackageResidency> modelResidency,
                     std::unique_ptr<model::RuntimeModel> modelRuntime,
                     std::unique_ptr<NativeRuntime> nativeLoop,
                     RuntimeBootstrapReport report,
                     LifecycleStatusSnapshot lifecycle,
                     std::shared_ptr<NativeAdmissionGate> admissionGate,
                     std::optional<RecoverySpec> recoverySpec = std::nullopt);

    // Reverse destruction order is loop -> RuntimeModel -> ModelPackage -> base.
    std::unique_ptr<RuntimeResources> resources_;
    std::unique_ptr<ModelPackageResidency> modelResidency_;
    std::unique_ptr<model::RuntimeModel> model_;
    std::unique_ptr<NativeRuntime> nativeLoop_;
    RuntimeBootstrapReport report_;
    std::shared_ptr<NativeAdmissionGate> admissionGate_;
    mutable std::mutex lifecycleMutex_;
    LifecycleStatusSnapshot lifecycle_;
    SuspendPhase suspendPhase_ = SuspendPhase::None;
    uint64_t suspendRevision_ = 0;
    std::optional<RecoverySpec> recoverySpec_;
    mutable std::mutex recoveryMutex_;
    std::unique_ptr<RecoveryCandidate> recoveryCandidate_;
    std::thread recoveryWorker_;
    bool recoveryWorkerInFlight_ = false;
    bool recoveryWorkerDone_ = false;
    uint64_t recoveryWorkerRevision_ = 0;
    std::optional<uint64_t> recoveryAttemptRevision_;
    std::string recoveryBuildError_;
    std::optional<ResourceSnapshot> recoveryBuildSnapshot_;
    // Installed only by RuntimeBootstrapTestAccess; production always uses
    // buildRecoveryCandidate() above.
    std::function<void(uint64_t)> recoveryBuilderForTesting_;
};

}  // namespace splash::engine
