#include "engine/Bootstrap.hpp"
#include "engine/StartupLog.hpp"
#include "model/PreparedWeights.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>
#include <utility>

namespace splash::engine {
namespace {

RuntimeBootstrapReport reportForPlan(const EngineMemoryPlan &plan) {
  RuntimeBootstrapReport report;
  report.memoryPlanJson = plan.toStatusJson();
  report.budgetDescription = plan.breakdown().describe();
  return report;
}

RuntimeBootstrapReport
reportForResourceFailure(const RuntimeResourcesError &error) {
  RuntimeBootstrapReport report;
  report.resourceFailure = error.failure();
  report.message = error.message();
  report.warmup.error = report.message;
  report.memoryPlanJson = error.statusJson();
  report.budgetDescription = error.budgetDescription();
  return report;
}

[[noreturn]] void fail(RuntimeBootstrapReport report,
                       RuntimeBootstrapStage stage, std::string message) {
  report.ready = false;
  report.stage = stage;
  report.message = std::move(message);
  report.warmup.error = report.message;
  throw RuntimeBootstrapError(std::move(report));
}

void requireRecoveryHeadroom(
    const MemoryGovernor::HostAvailableMemoryProvider &hostAvailableMemory,
    uint64_t reserveBytes, MemoryPressure pressure) {
  const std::optional<uint64_t> available = hostAvailableMemory();
  if (!available || *available <= reserveBytes ||
      pressure == MemoryPressure::Critical) {
    std::ostringstream message;
    message << "not enough free memory to recover: ";
    if (!available)
      message << "reclaimable host memory cannot be measured";
    else
      message << (*available / kMiB) << " MiB reclaimable, "
              << (reserveBytes / kMiB)
              << " MiB protected for macOS, system pressure "
              << memoryPressureName(pressure);
    message << "; close memory-heavy applications and retry";
    throw metal::MetalAllocationError(message.str(),
                                      metal::AllocationFailure::HostPressure);
  }
}

class ClearOperationGuard final {
public:
  explicit ClearOperationGuard(metal::MetalBackend &backend) noexcept
      : backend_(backend) {}
  ~ClearOperationGuard() { backend_.setOperationGuard({}); }
  ClearOperationGuard(const ClearOperationGuard &) = delete;
  ClearOperationGuard &operator=(const ClearOperationGuard &) = delete;

private:
  metal::MetalBackend &backend_;
};

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
  case RuntimeBootstrapStage::DraftVerifyCommit:
    return "draft_verify_commit";
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
  out << (ready ? "runtime bootstrap ready" : "runtime bootstrap failed")
      << " [" << runtimeBootstrapStageName(stage) << "]: " << message;
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
  if (!deadline_ || failure.stage > stage_) {
    deadline_ = now + length_;
    stage_ = failure.stage;
  }
  if (now >= *deadline_)
    return std::nullopt;
  return deadline_;
}

bool memoryMayNotHold(const EngineMemoryPlan &plan,
                      uint64_t hostAvailableBytes, uint32_t contextTokens) {
  const uint64_t held = EngineMemoryPolicy::hostAvailableReserveBytes(
                            plan.breakdown().physicalMemoryBytes) +
                        kHostWarningMarginBytes;
  return plan.contextTokensWithin(
             hostAvailableBytes > held ? hostAvailableBytes - held : 0) <
         contextTokens;
}

RuntimeBootstrap::RuntimeBootstrap(std::unique_ptr<RuntimeResources> resources,
                                   std::unique_ptr<ModelPackageResidency> modelResidency,
                                   std::unique_ptr<model::RuntimeModel> modelRuntime,
                                   std::unique_ptr<NativeRuntime> nativeLoop,
                                   RuntimeBootstrapReport report,
                                   LifecycleStatusSnapshot lifecycle,
                                   std::shared_ptr<NativeAdmissionGate> admissionGate,
                                   std::optional<RecoverySpec> recoverySpec)
    : resources_(std::move(resources)),
      modelResidency_(std::move(modelResidency)),
      model_(std::move(modelRuntime)),
      nativeLoop_(std::move(nativeLoop)), report_(std::move(report)),
      admissionGate_(std::move(admissionGate)),
      lifecycle_(std::move(lifecycle)),
      recoverySpec_(std::move(recoverySpec)) {}

bool RuntimeBootstrap::observePower(LifecyclePower power) {
  if (!validLifecyclePower(power))
    throw std::invalid_argument("invalid lifecycle power observation");
  std::lock_guard lock(lifecycleMutex_);
  if (lifecycle_.state == LifecycleState::Shutdown || lifecycle_.power == power)
    return false;
  if (lifecycle_.revision == std::numeric_limits<uint64_t>::max())
    throw std::overflow_error("lifecycle intent revision exhausted");
  if (admissionGate_) {
    std::lock_guard gateLock(admissionGate_->mutex);
    admissionGate_->inferenceReady = false;
  }
  ++lifecycle_.revision;
  lifecycle_.power = power;
  lifecycle_.inferenceReady = false;
  if (power == LifecyclePower::Unknown) {
    lifecycle_.state = LifecycleState::RecoveryFailed;
    lifecycle_.lastError = "power source is unknown";
  } else {
    lifecycle_.lastError.clear();
    if (power == LifecyclePower::Battery) {
      if (lifecycle_.state == LifecycleState::Ready) {
        lifecycle_.state = LifecycleState::Draining;
      } else if (!lifecycle_.modelResident && !resources_ && !model_ &&
                 !modelResidency_ && nativeLoop_ && nativeLoop_->ready()) {
        // A battery cold start has no residency to drain. It is already in
        // the same model-less suspended state reached after destructive
        // release, with the control shell and generation still live.
        lifecycle_.state = LifecycleState::Suspended;
      }
    } else {
      const bool publishedResidency =
          lifecycle_.modelResident && lifecycle_.controlReady && model_ &&
          modelResidency_ && nativeLoop_ && nativeLoop_->ready() &&
          nativeLoop_->hasEngine() && nativeLoop_->engineHealthy() &&
          lifecycle_.effectiveContextTokens &&
          *lifecycle_.effectiveContextTokens > 0 &&
          *lifecycle_.effectiveContextTokens <=
              lifecycle_.configuredContextCeiling;
      if (publishedResidency) {
        lifecycle_.state = LifecycleState::Ready;
        lifecycle_.controlReady = true;
        lifecycle_.inferenceReady = true;
        if (admissionGate_) {
          std::lock_guard gateLock(admissionGate_->mutex);
          admissionGate_->inferenceReady = true;
        }
      }
    }
  }
  return true;
}

bool RuntimeBootstrap::publishLifecycleStatus(LifecycleStatusSnapshot status) {
  std::lock_guard lock(lifecycleMutex_);
  if (lifecycle_.state == LifecycleState::Shutdown ||
      status.revision != lifecycle_.revision || status.power != lifecycle_.power ||
      !validLifecycleStatus(status))
    return false;
  lifecycle_ = std::move(status);
  if (admissionGate_) {
    std::lock_guard gateLock(admissionGate_->mutex);
    admissionGate_->inferenceReady = lifecycle_.inferenceReady;
  }
  return true;
}

bool RuntimeBootstrap::publishRecoveryCandidate() {
  const auto publication = publishRecoveryResidency();
  return publication && finalizeRecoveryPublication(*publication);
}

std::optional<RuntimeBootstrap::RecoveryPublication>
RuntimeBootstrap::publishRecoveryResidency() {
  RecoveryCandidate *observedCandidate = nullptr;
  uint64_t candidateRevision = 0;
  uint32_t effectiveContext = 0;
  {
    std::lock_guard candidateLock(recoveryMutex_);
    if (!recoveryCandidate_ || !recoveryCandidate_->modelResidency ||
        !recoveryCandidate_->model || !recoveryCandidate_->engine)
      return std::nullopt;
    observedCandidate = recoveryCandidate_.get();
    candidateRevision = observedCandidate->lifecycleRevision;
    // This is the candidate Engine's actual serving limit. The startup
    // report is historical and may describe a different recovery context.
    effectiveContext =
        observedCandidate->engine->snapshot().maximumContextTokens;
  }

  std::unique_ptr<RecoveryCandidate> discardedCandidate;
  RecoveryPublication publication;
  {
    // Keep the established lifecycle -> admission lock order. The candidate
    // lock is held only across validation and unique_ptr movements.
    std::unique_lock lifecycleLock(lifecycleMutex_);
    std::unique_lock candidateLock(recoveryMutex_);
    if (!recoveryCandidate_ || recoveryCandidate_.get() != observedCandidate)
      return std::nullopt;

    auto discard = [&] {
      discardedCandidate = std::move(recoveryCandidate_);
    };
    auto failCurrentRecovery = [&](const char *message) {
      if (admissionGate_) {
        std::lock_guard gateLock(admissionGate_->mutex);
        admissionGate_->inferenceReady = false;
      }
      lifecycle_.state = LifecycleState::RecoveryFailed;
      lifecycle_.controlReady = nativeLoop_ && nativeLoop_->ready();
      lifecycle_.inferenceReady = false;
      lifecycle_.modelResident = false;
      lifecycle_.lastError = message;
      discard();
    };

    if (lifecycle_.state == LifecycleState::Shutdown ||
        candidateRevision != lifecycle_.revision) {
      // A stale candidate cannot affect the newer intent or its admission.
      discard();
      return std::nullopt;
    }
    if (lifecycle_.power != LifecyclePower::AC)
      return std::nullopt;

    if (!effectiveContext ||
        effectiveContext > lifecycle_.configuredContextCeiling) {
      failCurrentRecovery(
          "recovery Engine effective context is zero or exceeds the configured ceiling");
      return std::nullopt;
    }

    bool admissionOpen = false;
    if (admissionGate_) {
      std::lock_guard gateLock(admissionGate_->mutex);
      admissionOpen = admissionGate_->inferenceReady;
    }
    const bool recoverableState =
        lifecycle_.state == LifecycleState::Suspended ||
        lifecycle_.state == LifecycleState::RecoveryFailed;
    if (!recoverableState || !lifecycle_.controlReady ||
        !validLifecycleStatus(lifecycle_) || !admissionGate_ ||
        !nativeLoop_ || !nativeLoop_->ready() || admissionOpen ||
        lifecycle_.inferenceReady || lifecycle_.modelResident ||
        nativeLoop_->hasEngine() || model_ || modelResidency_) {
      failCurrentRecovery(
          "recovery publication requires current AC intent and a closed model-less runtime");
      return std::nullopt;
    }

    // Transfer dependencies first; the Engine continues to point at the same
    // RuntimeModel and retained Cache objects. Roll back these noexcept moves
    // if NativeRuntime's exact-Engine adoption precondition refuses.
    const bool transfersResources = recoveryCandidate_->resources != nullptr;
    if (transfersResources) {
      if (resources_) {
        failCurrentRecovery(
            "cold recovery candidate unexpectedly replaced retained resources");
        return std::nullopt;
      }
      resources_ = std::move(recoveryCandidate_->resources);
    }
    modelResidency_ = std::move(recoveryCandidate_->modelResidency);
    model_ = std::move(recoveryCandidate_->model);
    if (!nativeLoop_->tryPublishEngine(recoveryCandidate_->engine)) {
      recoveryCandidate_->model = std::move(model_);
      recoveryCandidate_->modelResidency = std::move(modelResidency_);
      // RuntimeResources owns the Cache borrowed by this Engine. Return the
      // just-transferred cold base graph to the private candidate on refusal.
      if (transfersResources) {
        recoveryCandidate_->resources = std::move(resources_);
      }
      failCurrentRecovery(
          "NativeRuntime refused the private recovery Engine publication");
      return std::nullopt;
    }

    publication = RecoveryPublication{
        .engine = nativeLoop_->core_.get(),
        .model = model_.get(),
        .modelResidency = modelResidency_.get(),
        .lifecycleRevision = candidateRevision,
        .effectiveContextTokens = effectiveContext,
    };
    recoveryCandidate_.reset();

    // Physical residency is now published while inference remains closed.
    lifecycle_.state = LifecycleState::Recovering;
    lifecycle_.controlReady = true;
    lifecycle_.modelResident = true;
    lifecycle_.inferenceReady = false;
    lifecycle_.effectiveContextTokens = effectiveContext;
    lifecycle_.lastError.clear();
  }
  return publication;
}

bool RuntimeBootstrap::finalizeRecoveryPublication(
    const RecoveryPublication &publication) {
  std::lock_guard lifecycleLock(lifecycleMutex_);
  if (!admissionGate_)
    return false;
  std::lock_guard gateLock(admissionGate_->mutex);

  const bool currentIntent =
      nativeLoop_ && lifecycle_.state != LifecycleState::Shutdown &&
      lifecycle_.revision == publication.lifecycleRevision &&
      lifecycle_.power == LifecyclePower::AC;
  if (!currentIntent) {
    // A battery or shutdown intent that won after physical publication keeps
    // the newly published residency closed for its matching lifecycle path.
    admissionGate_->inferenceReady = false;
    return false;
  }

  const engine::EngineSnapshot engineSnapshot = nativeLoop_->snapshot();
  const bool exactResidency =
      nativeLoop_->core_.get() == publication.engine &&
      model_.get() == publication.model &&
      modelResidency_.get() == publication.modelResidency;
  const bool contextConsistent =
      publication.effectiveContextTokens > 0 &&
      publication.effectiveContextTokens <=
          lifecycle_.configuredContextCeiling &&
      lifecycle_.effectiveContextTokens &&
      *lifecycle_.effectiveContextTokens ==
          publication.effectiveContextTokens &&
      engineSnapshot.maximumContextTokens ==
          publication.effectiveContextTokens;
  if (!exactResidency || !contextConsistent ||
      !nativeLoop_->engineHealthy() ||
      lifecycle_.state != LifecycleState::Recovering ||
      !lifecycle_.modelResident || lifecycle_.inferenceReady ||
      admissionGate_->inferenceReady) {
    admissionGate_->inferenceReady = false;
    lifecycle_.state = LifecycleState::RecoveryFailed;
    lifecycle_.controlReady = nativeLoop_ && nativeLoop_->ready();
    lifecycle_.modelResident = exactResidency;
    lifecycle_.inferenceReady = false;
    lifecycle_.lastError =
        "published recovery residency failed its final revision, health, or context fence";
    return false;
  }

  lifecycle_.state = LifecycleState::Ready;
  lifecycle_.controlReady = true;
  lifecycle_.modelResident = true;
  lifecycle_.inferenceReady = true;
  lifecycle_.lastError.clear();
  if (!validLifecycleStatus(lifecycle_)) {
    lifecycle_.state = LifecycleState::RecoveryFailed;
    lifecycle_.inferenceReady = false;
    lifecycle_.lastError =
        "recovery lifecycle became inconsistent before admission opened";
    admissionGate_->inferenceReady = false;
    return false;
  }

  // This is the final serving step. The effective context and Ready lifecycle
  // are already visible before the admission boundary opens.
  admissionGate_->inferenceReady = true;
  return true;
}

bool RuntimeBootstrap::shutdownLifecycle() {
  std::lock_guard lock(lifecycleMutex_);
  if (lifecycle_.state == LifecycleState::Shutdown)
    return false;
  if (lifecycle_.revision == std::numeric_limits<uint64_t>::max())
    throw std::overflow_error("lifecycle intent revision exhausted");
  if (admissionGate_) {
    std::lock_guard gateLock(admissionGate_->mutex);
    admissionGate_->inferenceReady = false;
  }
  ++lifecycle_.revision;
  lifecycle_.state = LifecycleState::Shutdown;
  lifecycle_.controlReady = false;
  lifecycle_.inferenceReady = false;
  lifecycle_.lastError.clear();
  return true;
}

bool RuntimeBootstrap::beginSuspend() {
  std::lock_guard lock(lifecycleMutex_);
  if (lifecycle_.state == LifecycleState::Shutdown ||
      lifecycle_.power != LifecyclePower::Battery)
    return false;
  if (suspendPhase_ != SuspendPhase::None)
    return suspendRevision_ == lifecycle_.revision;
  if (!lifecycle_.modelResident || !lifecycle_.controlReady ||
      !nativeLoop_->ready() || !modelResidency_ || !model_ ||
      !nativeLoop_->hasEngine())
    return false;

  // Match observePower/publishLifecycleStatus lock order and close the final
  // admission point before exposing Draining. Existing Engine/model work is
  // left intact for the native safe point to drain.
  if (admissionGate_) {
    std::lock_guard gateLock(admissionGate_->mutex);
    admissionGate_->inferenceReady = false;
  }
  lifecycle_.state = LifecycleState::Draining;
  lifecycle_.controlReady = true;
  lifecycle_.inferenceReady = false;
  lifecycle_.modelResident = true;
  suspendRevision_ = lifecycle_.revision;
  suspendPhase_ = SuspendPhase::Draining;
  return true;
}

SuspendProgress RuntimeBootstrap::advanceSuspend() {
  const bool engineDrained =
      nativeLoop_->idle() && !nativeLoop_->commandInFlight();
  const bool transfersInFlight =
      resources_ && resources_->cache().transfersInFlight();
  return advanceSuspendObserved(engineDrained, transfersInFlight);
}

RecoveryProgress RuntimeBootstrap::advanceRecovery() {
  struct RecoveryEligibility {
    uint64_t revision = 0;
    bool eligible = false;
    bool hasRecoverySpec = false;
    RecoverySpec spec;
  };
  const auto inspectEligibility = [this] {
    RecoveryEligibility current;
    std::lock_guard lifecycleLock(lifecycleMutex_);
    bool admissionOpen = false;
    if (admissionGate_) {
      std::lock_guard gateLock(admissionGate_->mutex);
      admissionOpen = admissionGate_->inferenceReady;
    }
    const bool recoverableState =
        lifecycle_.state == LifecycleState::Suspended ||
        lifecycle_.state == LifecycleState::RecoveryFailed;
    current.eligible =
        lifecycle_.state != LifecycleState::Shutdown &&
        lifecycle_.power == LifecyclePower::AC && recoverableState &&
        !lifecycle_.inferenceReady && !lifecycle_.modelResident &&
        !admissionOpen && !modelResidency_ && !model_ &&
        !(nativeLoop_ && nativeLoop_->hasEngine());
    current.revision = lifecycle_.revision;
    if (current.eligible && recoverySpec_) {
      current.hasRecoverySpec = true;
      current.spec = *recoverySpec_;
    }
    return current;
  };

  std::function<void(uint64_t)> testBuilder;
  std::thread completedWorker;
  uint64_t completedRevision = 0;
  std::string buildError;
  bool completed = false;
  bool builderInstalled = false;
  bool workerInFlight = false;
  {
    std::lock_guard recoveryLock(recoveryMutex_);
    testBuilder = recoveryBuilderForTesting_;
    builderInstalled = static_cast<bool>(testBuilder);
    workerInFlight = recoveryWorkerInFlight_;
    if (!workerInFlight && recoveryWorkerDone_) {
      completed = true;
      completedRevision = recoveryWorkerRevision_;
      recoveryWorkerRevision_ = 0;
      buildError = std::move(recoveryBuildError_);
      recoveryBuildError_.clear();
      recoveryWorkerDone_ = false;
      completedWorker = std::move(recoveryWorker_);
    }
  }

  // Never join work that may still be loading a package or allocating Metal
  // resources. Battery/Shutdown safe points simply leave it for its worker
  // cancellation checks and completion wake.
  if (workerInFlight) {
    const RecoveryEligibility current = inspectEligibility();
    if (!current.eligible)
      return RecoveryProgress::Idle;
    return RecoveryProgress::Building;
  }

  // The done flag is published only after the worker has finished candidate
  // construction. Joining this already-completed thread is non-blocking with
  // respect to model loading and is deliberately outside both state locks.
  if (completedWorker.joinable())
    completedWorker.join();

  RecoveryEligibility current = inspectEligibility();
  bool completionIsCurrent =
      completed && current.eligible && current.revision == completedRevision;
  if (completed) {
    std::unique_ptr<RecoveryCandidate> discardedCandidate;
    {
      std::lock_guard recoveryLock(recoveryMutex_);
      // The detached build snapshot is only needed while its worker runs or
      // until this safe point consumes its result.
      recoveryBuildSnapshot_.reset();
      if (!completionIsCurrent || !buildError.empty())
        discardedCandidate = std::move(recoveryCandidate_);
      if (!completionIsCurrent && recoveryAttemptRevision_ &&
          *recoveryAttemptRevision_ == completedRevision)
        recoveryAttemptRevision_.reset();
      recoveryBuildError_.clear();
    }
    // RecoveryCandidate explicitly destroys Engine -> RuntimeModel -> package.
    // Keep that potentially expensive destruction outside recoveryMutex_.
    discardedCandidate.reset();

    if (!completionIsCurrent) {
      // Re-evaluate after reaping. A newer AC intent may begin a fresh build
      // in this same safe point; Battery, Unknown, Shutdown and non-recoverable
      // states remain idle.
      current = inspectEligibility();
      if (!current.eligible)
        return RecoveryProgress::Idle;
    } else if (!buildError.empty()) {
      std::lock_guard lifecycleLock(lifecycleMutex_);
      if (lifecycle_.revision != completedRevision ||
          lifecycle_.power != LifecyclePower::AC ||
          lifecycle_.state == LifecycleState::Shutdown)
        return RecoveryProgress::Superseded;
      lifecycle_.state = LifecycleState::RecoveryFailed;
      lifecycle_.controlReady = nativeLoop_ && nativeLoop_->ready();
      lifecycle_.inferenceReady = false;
      lifecycle_.modelResident = false;
      lifecycle_.lastError = std::move(buildError);
      return RecoveryProgress::Failed;
    } else {
      bool candidateReady = false;
      {
        std::lock_guard recoveryLock(recoveryMutex_);
        candidateReady = recoveryCandidate_ != nullptr;
      }
      if (!candidateReady) {
        std::lock_guard lifecycleLock(lifecycleMutex_);
        if (lifecycle_.revision != completedRevision ||
            lifecycle_.power != LifecyclePower::AC ||
            lifecycle_.state == LifecycleState::Shutdown)
          return RecoveryProgress::Superseded;
        lifecycle_.state = LifecycleState::RecoveryFailed;
        lifecycle_.controlReady = nativeLoop_ && nativeLoop_->ready();
        lifecycle_.inferenceReady = false;
        lifecycle_.modelResident = false;
        lifecycle_.lastError = "recovery worker produced no candidate";
        return RecoveryProgress::Failed;
      }
      if (publishRecoveryCandidate())
        return RecoveryProgress::Ready;
      const LifecycleStatusSnapshot after = lifecycleStatus();
      if (after.state == LifecycleState::Shutdown ||
          after.power != LifecyclePower::AC ||
          after.revision != completedRevision)
        return RecoveryProgress::Superseded;
      return RecoveryProgress::Failed;
    }
  }

  if (!current.eligible)
    return RecoveryProgress::Idle;
  const uint64_t currentRevision = current.revision;
  RecoverySpec spec = std::move(current.spec);
  const bool hasRecoverySpec = current.hasRecoverySpec;
  if (!resources_ &&
      !(hasRecoverySpec && spec.initializeResourcesIfAbsent) &&
      !builderInstalled)
    return RecoveryProgress::Idle;
  if (!hasRecoverySpec && !builderInstalled)
    return RecoveryProgress::Idle;

  // A candidate installed directly by the private test seam still follows
  // the production safe-point publication path.
  bool candidateAlreadyBuilt = false;
  {
    std::lock_guard recoveryLock(recoveryMutex_);
    candidateAlreadyBuilt = recoveryCandidate_ != nullptr;
    if (!candidateAlreadyBuilt) {
      if (recoveryAttemptRevision_ &&
          *recoveryAttemptRevision_ == currentRevision)
        return RecoveryProgress::Failed;
      if (recoveryWorkerInFlight_)
        return RecoveryProgress::Building;
    }
  }
  if (candidateAlreadyBuilt)
    return publishRecoveryCandidate() ? RecoveryProgress::Ready
                                      : RecoveryProgress::Failed;

  ResourceSnapshot buildSnapshot;
  try {
    buildSnapshot = detachedResourceSnapshot();
  } catch (const std::exception &error) {
    std::lock_guard lifecycleLock(lifecycleMutex_);
    if (lifecycle_.revision == currentRevision &&
        lifecycle_.power == LifecyclePower::AC &&
        lifecycle_.state != LifecycleState::Shutdown) {
      lifecycle_.state = LifecycleState::RecoveryFailed;
      lifecycle_.controlReady = nativeLoop_ && nativeLoop_->ready();
      lifecycle_.inferenceReady = false;
      lifecycle_.modelResident = false;
      lifecycle_.lastError = error.what();
    }
    return RecoveryProgress::Failed;
  }

  const auto wake = spec.lifecycleWake;
  const bool startedForCurrentRevision = [&] {
    const LifecycleStatusSnapshot now = lifecycleStatus();
    return now.state != LifecycleState::Shutdown &&
           now.revision == currentRevision &&
           now.power == LifecyclePower::AC;
  }();
  if (!startedForCurrentRevision)
    return RecoveryProgress::Superseded;

  bool candidateAppeared = false;
  {
    std::unique_lock recoveryLock(recoveryMutex_);
    if (recoveryWorkerInFlight_)
      return RecoveryProgress::Building;
    if (recoveryWorkerDone_ || recoveryWorker_.joinable())
      return RecoveryProgress::Building;
    candidateAppeared = recoveryCandidate_ != nullptr;
    if (!candidateAppeared) {
      recoveryBuildSnapshot_ = std::move(buildSnapshot);
      recoveryWorkerRevision_ = currentRevision;
      recoveryAttemptRevision_ = currentRevision;
      recoveryWorkerInFlight_ = true;
      recoveryBuildError_.clear();
      try {
        recoveryWorker_ = std::thread(
            [this, currentRevision, spec = std::move(spec), testBuilder,
             wake]() mutable {
              std::string error;
              try {
                if (testBuilder)
                  testBuilder(currentRevision);
                else
                  buildRecoveryCandidate(currentRevision, std::move(spec));
              } catch (const std::exception &exception) {
                error = exception.what();
              } catch (...) {
                error = "unknown recovery build failure";
              }
              {
                std::lock_guard lock(recoveryMutex_);
                recoveryBuildError_ = std::move(error);
                recoveryWorkerInFlight_ = false;
                recoveryWorkerDone_ = true;
              }
              if (wake) {
                try {
                  wake();
                } catch (...) {
                }
              }
            });
      } catch (const std::exception &error) {
        recoveryWorkerInFlight_ = false;
        recoveryAttemptRevision_.reset();
        recoveryBuildSnapshot_.reset();
        const std::string message = error.what();
        recoveryLock.unlock();
        std::lock_guard lifecycleLock(lifecycleMutex_);
        if (lifecycle_.revision == currentRevision &&
            lifecycle_.power == LifecyclePower::AC &&
            lifecycle_.state != LifecycleState::Shutdown) {
          lifecycle_.state = LifecycleState::RecoveryFailed;
          lifecycle_.controlReady = nativeLoop_ && nativeLoop_->ready();
          lifecycle_.inferenceReady = false;
          lifecycle_.modelResident = false;
          lifecycle_.lastError = message;
        }
        return RecoveryProgress::Failed;
      }
    }
  }
  if (candidateAppeared)
    return publishRecoveryCandidate() ? RecoveryProgress::Ready
                                      : RecoveryProgress::Failed;
  return RecoveryProgress::Building;
}

SuspendProgress RuntimeBootstrap::advanceSuspendObserved(
    bool engineDrained, bool transfersInFlight) {
  uint64_t capturedRevision = 0;
  {
    std::lock_guard lock(lifecycleMutex_);
    if (suspendPhase_ == SuspendPhase::None)
      return SuspendProgress::Idle;
    if (suspendPhase_ == SuspendPhase::DestructiveRelease)
      return SuspendProgress::WaitingForDrain;
    if (lifecycle_.revision != suspendRevision_ ||
        lifecycle_.state == LifecycleState::Shutdown) {
      suspendPhase_ = SuspendPhase::None;
      return SuspendProgress::Superseded;
    }
    capturedRevision = suspendRevision_;
  }

  // This is the only pre-destructive work step. Engine::tick drives request
  // tickets, model::RuntimeModel::submitTransfers, and Cache::pollTransfers.
  // Cache IO is a separate barrier: Engine::idle() does not imply it is clear.
  if (!engineDrained || transfersInFlight) {
    static_cast<void>(nativeLoop_->tick());
    return SuspendProgress::WaitingForDrain;
  }

  // The destructive release commits only after this last short revision
  // check. No lifecycle/admission lock spans Engine or residency destruction.
  {
    std::lock_guard lock(lifecycleMutex_);
    if (lifecycle_.revision != capturedRevision ||
        lifecycle_.state == LifecycleState::Shutdown) {
      suspendPhase_ = SuspendPhase::None;
      return SuspendProgress::Superseded;
    }
    suspendPhase_ = SuspendPhase::DestructiveRelease;
  }

  try {
    nativeLoop_->destroyEngine();
  } catch (const std::logic_error &) {
    // NativeRuntime is the final authority for request/ticket telemetry that
    // its public idle() query does not expose. A rejected destroy is still
    // pre-destructive; retry at a later safe point.
    std::lock_guard lock(lifecycleMutex_);
    if (lifecycle_.revision != capturedRevision ||
        lifecycle_.state == LifecycleState::Shutdown) {
      suspendPhase_ = SuspendPhase::None;
      return SuspendProgress::Superseded;
    }
    suspendPhase_ = SuspendPhase::Draining;
    return SuspendProgress::WaitingForDrain;
  }

  // Keep this exact order: Engine borrowers, RuntimeModel, then the package
  // residency. RuntimeResources and its cache/KV/state/backend graph survive.
  model_.reset();
  modelResidency_.reset();

  // Residency is now physically absent even if a newer power intent arrived
  // while destruction ran. Update only these factual fields; the lifecycle
  // state/revision remain owned by the existing publication fence below.
  {
    std::lock_guard lock(lifecycleMutex_);
    lifecycle_.inferenceReady = false;
    lifecycle_.modelResident = false;
  }

  ResourceSnapshot released;
  try {
    released = detachedResourceSnapshot();
  } catch (...) {
    std::lock_guard lock(lifecycleMutex_);
    suspendPhase_ = SuspendPhase::None;
    return SuspendProgress::ReleaseFailed;
  }
  if (!validResourceSnapshot(released) || nativeLoop_->hasEngine() || model_ ||
      modelResidency_ || released.modelPackageResident ||
      released.modelPackageResidentBytes || released.runtimeResident ||
      released.runtimeResidentBytes || released.modelTelemetryAvailable) {
    std::lock_guard lock(lifecycleMutex_);
    suspendPhase_ = SuspendPhase::None;
    return SuspendProgress::ReleaseFailed;
  }

  LifecycleStatusSnapshot suspended = released.lifecycle;
  suspended.power = LifecyclePower::Battery;
  suspended.state = LifecycleState::Suspended;
  suspended.revision = capturedRevision;
  suspended.controlReady = true;
  suspended.inferenceReady = false;
  suspended.modelResident = false;
  const bool published = publishLifecycleStatus(std::move(suspended));
  if (!published) {
    LifecycleStatusSnapshot recoverable;
    bool reconcileCurrentAc = false;
    {
      std::lock_guard lock(lifecycleMutex_);
      if (lifecycle_.revision > capturedRevision &&
          lifecycle_.power == LifecyclePower::AC &&
          lifecycle_.state == LifecycleState::Draining &&
          !lifecycle_.modelResident &&
          lifecycle_.state != LifecycleState::Shutdown) {
        recoverable = lifecycle_;
        recoverable.state = LifecycleState::Suspended;
        recoverable.controlReady = nativeLoop_ && nativeLoop_->ready();
        recoverable.inferenceReady = false;
        recoverable.modelResident = false;
        reconcileCurrentAc = true;
      }
    }
    if (reconcileCurrentAc)
      static_cast<void>(publishLifecycleStatus(std::move(recoverable)));
  }
  {
    std::lock_guard lock(lifecycleMutex_);
    suspendPhase_ = SuspendPhase::None;
  }
  return published ? SuspendProgress::Suspended : SuspendProgress::Superseded;
}

ResourceSnapshot RuntimeBootstrap::detachedResourceSnapshot() const {
  if (nativeLoop_->hasEngine() || model_ || modelResidency_)
    throw std::logic_error(
        "detached resource snapshot requires released model residency");

  ResourceSnapshot snapshot;
  snapshot.lifecycle = lifecycleStatus();
  snapshot.modelPackageResident = false;
  snapshot.modelPackageResidentBytes.reset();
  snapshot.runtimeResident = false;
  snapshot.runtimeResidentBytes.reset();
  snapshot.modelTelemetryAvailable = false;

  if (!resources_) {
    if (!validResourceSnapshot(snapshot))
      throw std::logic_error("empty detached resource snapshot is inconsistent");
    return snapshot;
  }

  std::optional<ResourceSnapshot> cachedRecoverySnapshot;
  {
    std::lock_guard recoveryLock(recoveryMutex_);
    if (recoveryWorkerInFlight_ && recoveryBuildSnapshot_)
      cachedRecoverySnapshot = recoveryBuildSnapshot_;
  }
  if (cachedRecoverySnapshot) {
    cachedRecoverySnapshot->lifecycle = lifecycleStatus();
    if (!validResourceSnapshot(*cachedRecoverySnapshot))
      throw std::logic_error(
          "cached detached resource snapshot became inconsistent");
    return *cachedRecoverySnapshot;
  }

  metal::MetalMemoryStats memory = resources_->backend().refreshMemoryStats();
  if (memory.sparseResidentBytes >
      std::numeric_limits<uint64_t>::max() - memory.allocatedBytes)
    throw std::overflow_error("detached backend memory accounting overflows");
  snapshot.backendAllocatedBytes =
      memory.allocatedBytes + memory.sparseResidentBytes;

  const CacheSnapshot cache = resources_->cache().snapshot();
  snapshot.retainedCacheBytes = cache.stateCache.bytes;
  snapshot.retainedKvBytes = cache.pool.residentBackingBytes;
  snapshot.retainedStateBytes = resources_->stateStorage().actualAllocatedBytes();
  if (!validResourceSnapshot(snapshot))
    throw std::logic_error("detached resource snapshot is inconsistent");
  return snapshot;
}

std::unique_ptr<RuntimeBootstrap::RecoveryCandidate>
RuntimeBootstrap::makeRecoveryCandidate(
    std::unique_ptr<ModelPackageResidency> modelResidency,
    std::unique_ptr<model::RuntimeModel> model, Cache &cache,
    const EngineConfig &config, uint64_t lifecycleRevision,
    std::unique_ptr<RuntimeResources> resources) {
  if (!nativeLoop_ || nativeLoop_->hasEngine() || modelResidency_ || model_ ||
      !modelResidency || !model)
    throw std::logic_error(
        "private recovery candidate requires a model-less native loop and complete residency");

  auto candidate = std::make_unique<RecoveryCandidate>();
  candidate->resources = std::move(resources);
  candidate->modelResidency = std::move(modelResidency);
  candidate->model = std::move(model);
  candidate->lifecycleRevision = lifecycleRevision;
  // NativeRuntime remains the sole protocol event sink. Engine construction
  // is direct, so this candidate is never inserted into NativeRuntime::core_.
  candidate->engine = std::make_unique<Engine>(
      config, cache, *candidate->model,
      static_cast<EngineEventSink &>(*nativeLoop_));
  return candidate;
}

void RuntimeBootstrap::buildRecoveryCandidate(uint64_t capturedRevision,
                                              RecoverySpec spec) {
  {
    std::lock_guard lock(lifecycleMutex_);
    bool admissionOpen = false;
    if (admissionGate_) {
      std::lock_guard gateLock(admissionGate_->mutex);
      admissionOpen = admissionGate_->inferenceReady;
    }
    const bool recoverableState =
        lifecycle_.state == LifecycleState::Suspended ||
        lifecycle_.state == LifecycleState::RecoveryFailed;
    if ((!resources_ && !spec.initializeResourcesIfAbsent) || !nativeLoop_ ||
        !recoverableState ||
        lifecycle_.revision != capturedRevision ||
        lifecycle_.power != LifecyclePower::AC || lifecycle_.inferenceReady ||
        lifecycle_.modelResident || admissionOpen || modelResidency_ || model_ ||
        nativeLoop_->hasEngine() || !nativeLoop_->ready()) {
      throw std::logic_error(
          "recovery candidate requires AC intent and suspended model-less residency");
    }
  }
  {
    std::lock_guard lock(recoveryMutex_);
    if (recoveryCandidate_)
      throw std::logic_error("a private recovery candidate already exists");
  }
  const auto pressure = spec.memoryPressure;
  const auto processCancelled = spec.cancelled;
  const auto cancelled = [this, capturedRevision, processCancelled] {
    if (processCancelled && processCancelled())
      return true;
    std::lock_guard lock(lifecycleMutex_);
    return lifecycle_.state == LifecycleState::Shutdown ||
           lifecycle_.revision != capturedRevision ||
           lifecycle_.power != LifecyclePower::AC;
  };
  const auto hostAvailableMemory = spec.hostAvailableMemory;

  // Only the explicitly marked battery-cold path may create a base graph
  // here. It remains a local candidate resource until the common publication
  // fence adopts it; the control owner never waits for this work.
  std::unique_ptr<RuntimeResources> candidateResources;
  RuntimeResources *resources = resources_.get();
  if (!resources) {
    if (!spec.initializeResourcesIfAbsent)
      throw std::logic_error(
          "cold recovery has no authorization to initialize RuntimeResources");
    RuntimeResourcesConfig resourceConfig = spec.resources;
    resourceConfig.memoryPressure = pressure;
    resourceConfig.cancelled = cancelled;
    resourceConfig.hostAvailableMemory = hostAvailableMemory;
    candidateResources = RuntimeResources::create(resourceConfig);
    resources = candidateResources.get();
  }
  if (!resources)
    throw std::logic_error("recovery has no RuntimeResources graph");

  const DeviceCapabilities &device = resources->backend().capabilities();
  const uint64_t hostReserveBytes =
      EngineMemoryPolicy::hostAvailableReserveBytes(device.physicalMemoryBytes);
  const uint64_t preparationReserveBytes =
      hostReserveBytes + model::kWeightPreparationWorkspaceBytes;
  auto admitMetalOperation = [pressure, cancelled, hostAvailableMemory,
                              hostReserveBytes] {
    if (cancelled())
      throw metal::MetalBackendError("recovery cancelled");
    requireRecoveryHeadroom(
        hostAvailableMemory, hostReserveBytes,
        pressure ? pressure() : MemoryPressure::Normal);
  };
  auto admitWeightPreparation = [pressure, cancelled, hostAvailableMemory,
                                 preparationReserveBytes] {
    if (cancelled())
      throw metal::MetalBackendError("recovery cancelled");
    const MemoryPressure current =
        pressure ? pressure() : MemoryPressure::Normal;
    if (current != MemoryPressure::Normal)
      throw metal::MetalAllocationError(
          "weight preparation requires normal memory pressure",
          metal::AllocationFailure::HostPressure);
    requireRecoveryHeadroom(hostAvailableMemory, preparationReserveBytes,
                            current);
  };

  std::unique_ptr<ModelPackageResidency> candidateResidency;
  std::unique_ptr<model::RuntimeModel> candidateModel;
  std::unique_ptr<RecoveryCandidate> candidate;
  resources->backend().setOperationGuard(admitMetalOperation);
  ClearOperationGuard clearGuard(resources->backend());

  if (cancelled())
    throw metal::MetalBackendError("recovery cancelled");

  if (candidateResources) {
    candidateResidency = candidateResources->takeModelPackageResidency();
    if (!candidateResidency)
      throw std::logic_error(
          "cold RuntimeResources did not provide ModelPackage residency");
  } else {
    model::ModelPackage package = model::loadModelPackage(
        resources->backend(), spec.modelRoot, spec.model,
        std::move(admitWeightPreparation));
    requireLoadedModel(package);
    const RuntimeCacheIdentity candidateIdentity = makeRuntimeCacheIdentity(
        package.manifestFingerprintSha256, package.targetManifestFingerprint(),
        spec.buildId, package.targetKvLayout(spec.kvFormat));
    if (candidateIdentity.namespaceSha256 !=
        resources->cacheIdentity().namespaceSha256) {
      throw std::invalid_argument(
          "reloaded model package does not match the retained cache namespace");
    }
    candidateResidency = std::make_unique<ModelPackageResidency>(
        std::move(package));
  }

  const model::ModelMemoryPlan &modelMemory = resources->modelMemoryPlan();
  if (modelMemory.sharedDecodePlannedAllocatedBytes >
      std::numeric_limits<uint64_t>::max() -
          modelMemory.sharedPrefillPlannedAllocatedBytes) {
    throw std::overflow_error(
        "recovery RuntimeModel shared allocation reservation overflows");
  }
  const uint64_t modelBytes =
      modelMemory.sharedPrefillPlannedAllocatedBytes +
      modelMemory.sharedDecodePlannedAllocatedBytes;
  metal::AllocationFailure failure;
  auto reservation = resources->memoryGovernor().tryReserve(modelBytes,
                                                            &failure);
  if (!reservation) {
    throw metal::MetalAllocationError(
        std::string("unable to reserve recovery model arenas: ") +
            metal::allocationFailureName(failure),
        failure);
  }
  candidateModel = model::createRuntime(
      resources->modelContext(*candidateResidency));
  reservation->commit();

  EngineConfig candidateEngineConfig = spec.engine;
  const uint32_t automaticContext = resources->memoryPlan().maximumContextTokens();
  if (!automaticContext)
    throw std::invalid_argument(
        "memory plan cannot hold one model token during recovery");
  if (!candidateEngineConfig.maxContext) {
    candidateEngineConfig.maxContext = automaticContext;
  } else if (candidateEngineConfig.maxContext > automaticContext) {
    throw std::invalid_argument(
        "configured context exceeds the memory-planned recovery ceiling");
  }
  candidateEngineConfig.vocabularySize =
      spec.model.capabilities.vocabularySize;
  candidateEngineConfig.maxImagePatches =
      spec.model.hasVision() ? spec.resources.maximumImagePatches : 0;
  candidateEngineConfig.growthPaused =
      [governor = &resources->memoryGovernor()] {
        return !governor->snapshot().hostGrowthAllowed;
      };

  candidate = makeRecoveryCandidate(
      std::move(candidateResidency), std::move(candidateModel),
      resources->cache(), candidateEngineConfig, capturedRevision,
      std::move(candidateResources));
  // The last guarded allocation may have completed just as Battery or
  // Shutdown superseded this recovery. Keep the completed candidate local so
  // its Engine/model/package are destroyed before it can become private
  // Bootstrap residency.
  if (cancelled())
    throw metal::MetalBackendError("recovery cancelled");
  {
    std::lock_guard lock(recoveryMutex_);
    if (recoveryCandidate_)
      throw std::logic_error("a private recovery candidate already exists");
    recoveryCandidate_ = std::move(candidate);
  }
}

RuntimeBootstrap::~RuntimeBootstrap() {
  // Invalidate private work before joining it. The worker checks this revision
  // between guarded load/allocation steps and can never publish on teardown.
  try {
    static_cast<void>(shutdownLifecycle());
  } catch (...) {
  }
  if (recoveryWorker_.joinable())
    recoveryWorker_.join();
  // Candidate Engine/model/package borrowers must go before the retained base
  // backend is stopped or destroyed.
  recoveryCandidate_.reset();
  // Cancel unsubmitted dependency waits before the loop destroys its tickets.
  if (resources_)
    resources_->backend().stop();
}

std::unique_ptr<RuntimeBootstrap> RuntimeBootstrap::startModelLess(
    RuntimeBootstrapConfig config, NativeRuntime::ByteSink output,
    NativeRuntime::StatusProvider statusProvider) {
  const uint32_t configuredContextCeiling =
      config.nativeLoop.configuredContextCeiling
          ? config.nativeLoop.configuredContextCeiling
          : config.nativeLoop.engine.maxContext;
  if (!configuredContextCeiling)
    throw std::invalid_argument(
        "model-less control shell requires configured context ceiling");
  auto admissionGate = config.nativeLoop.admissionGate
                           ? config.nativeLoop.admissionGate
                           : std::make_shared<NativeAdmissionGate>();
  config.nativeLoop.admissionGate = admissionGate;
  EngineConfig deferredEngine = config.nativeLoop.engine;
  auto nativeLoop = std::make_unique<NativeRuntime>(
      std::move(config.nativeLoop), std::move(output),
      std::move(statusProvider), NativeLoopClocks{}, config.protocolLimits);
  // A model-less shell is already control-ready for this process generation.
  // Inference readiness remains false and is published only through status.
  nativeLoop->announceReady();
  RuntimeBootstrapReport report;
  report.stage = RuntimeBootstrapStage::ResourceAssembly;
  report.message = "model-less control shell constructed";
  LifecycleStatusSnapshot lifecycle;
  lifecycle.configuredContextCeiling = configuredContextCeiling;
  lifecycle.controlReady = nativeLoop->ready();
  lifecycle.lastError = "power source is unknown";
  RecoverySpec recoverySpec;
  recoverySpec.resources = config.resources;
  recoverySpec.initializeResourcesIfAbsent = true;
  recoverySpec.modelRoot = config.resources.modelRoot;
  recoverySpec.model = config.resources.model;
  recoverySpec.kvFormat = config.resources.kvFormat;
  recoverySpec.buildId = config.resources.buildId;
  recoverySpec.memoryPressure = config.resources.memoryPressure;
  recoverySpec.cancelled = config.resources.cancelled;
  recoverySpec.hostAvailableMemory =
      config.resources.hostAvailableMemory
          ? config.resources.hostAvailableMemory
          : MemoryGovernor::HostAvailableMemoryProvider(
                queryHostAvailableMemory);
  recoverySpec.lifecycleWake = std::move(config.lifecycleWake);
  recoverySpec.engine = std::move(deferredEngine);
  return std::unique_ptr<RuntimeBootstrap>(new RuntimeBootstrap(
      nullptr, nullptr, nullptr, std::move(nativeLoop), std::move(report),
      std::move(lifecycle), std::move(admissionGate),
      std::move(recoverySpec)));
}

RuntimeBootstrapReport RuntimeBootstrap::requireWarmupAndAnnounce(
    const EngineMemoryPlan &memoryPlan, model::RuntimeModel &modelRuntime,
    ActualMemoryReporter memoryReporter, NativeRuntime &nativeLoop) {
  RuntimeBootstrapReport report = reportForPlan(memoryPlan);
  if (!memoryReporter) {
    fail(std::move(report), RuntimeBootstrapStage::MemoryAudit,
         "actual memory reporter is required");
  }
  if (nativeLoop.ready()) {
    fail(std::move(report), RuntimeBootstrapStage::AnnounceReady,
         "native loop announced ready before bootstrap");
  }
  if (!nativeLoop.engineHealthy()) {
    fail(std::move(report), RuntimeBootstrapStage::AnnounceReady,
         "native loop is unhealthy before warmup");
  }

  uint64_t estimatedPeakBytes = 0;
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
    if (!result.completed || !result.estimatedPeakBytes ||
        !(result.wallSeconds > 0.0) || !std::isfinite(result.wallSeconds)) {
      std::string message = std::string(runtimeBootstrapStageName(stage)) +
                            " did not complete a real measured path";
      if (!result.detail.empty())
        message += ": " + result.detail;
      fail(report, stage, std::move(message));
    }
    estimatedPeakBytes =
        std::max(estimatedPeakBytes, result.estimatedPeakBytes);
    status = WarmupStepStatus::Complete;
    return result;
  };

  model::WarmupStepResult maximumPrefill =
      run(RuntimeBootstrapStage::MaximumPrefill, report.warmup.maximumPrefill,
          [&] {
            return modelRuntime.warmupPrefill(model::ExecutionLimits::prefillTokenBudget);
          });
  nativeLoop.observePrefill(model::ExecutionLimits::prefillTokenBudget,
                           maximumPrefill.wallSeconds * 1000.0);
  report.warmup.maximumPrefillDetail = maximumPrefill.detail;
  const auto &budget = memoryPlan.breakdown();
  // Startup exercises only widths that fit this budget. This is not a
  // serving concurrency limit: the engine still admits lanes dynamically.
  const uint32_t affordableWidth = static_cast<uint32_t>(std::min<uint64_t>(
      model::ExecutionLimits::maximumBatchWidth,
      (budget.dynamicBudgetBytes - budget.kvExtentBytes) /
          budget.activeStateCellBytes));
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
  run(RuntimeBootstrapStage::DraftVerifyCommit, report.warmup.draftVerifyCommit,
      [&] { return modelRuntime.warmupDraftVerifyCommit(); });
  run(RuntimeBootstrapStage::CompositeStateRestore,
      report.warmup.compositeStateRestore,
      [&] { return modelRuntime.warmupCompositeStateRestore(); }, true);

  ActualMemoryReport actual;
  try {
    actual = memoryReporter(estimatedPeakBytes);
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
  report.warmup.actualPeakBytes = actual.devicePeakAllocatedBytes;
  report.memoryAudit = auditActualMemory(memoryPlan, actual);
  if (!report.memoryAudit.valid) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         report.memoryAudit.describe());
  }
  report.warmup.memoryBudgetValidated = true;
  if (!report.warmup.ready()) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         "warmup report is incomplete after memory validation");
  }

  try {
    nativeLoop.announceReady();
  } catch (const std::exception &error) {
    fail(report, RuntimeBootstrapStage::AnnounceReady,
         std::string("binary ReadyEvent announcement failed: ") + error.what());
  } catch (...) {
    fail(report, RuntimeBootstrapStage::AnnounceReady,
         "binary ReadyEvent announcement failed with an unknown exception");
  }
  if (!nativeLoop.ready()) {
    fail(report, RuntimeBootstrapStage::AnnounceReady,
         "native loop did not enter ready state");
  }
  report.ready = true;
  report.stage = RuntimeBootstrapStage::Ready;
  report.message = "required warmup paths and memory audit passed";
  report.warmup.error.clear();
  return report;
}

std::unique_ptr<RuntimeBootstrap> RuntimeBootstrap::start(
    RuntimeBootstrapConfig config,
    NativeRuntime::ByteSink output,
    NativeRuntime::StatusProvider statusProvider) {
  auto admissionGate = config.nativeLoop.admissionGate
                           ? config.nativeLoop.admissionGate
                           : std::make_shared<NativeAdmissionGate>();
  config.nativeLoop.admissionGate = admissionGate;
  std::unique_ptr<RuntimeResources> resources;
  try {
    resources = RuntimeResources::create(config.resources);
  } catch (const RuntimeResourcesError &error) {
    throw RuntimeBootstrapError(error);
  }
  std::unique_ptr<ModelPackageResidency> modelResidency =
      resources->takeModelPackageResidency();
  if (!modelResidency) {
    throw std::logic_error(
        "resource assembly did not publish model package residency");
  }

  RuntimeBootstrapReport base = reportForPlan(resources->memoryPlan());
  const uint32_t automaticContext =
      resources->memoryPlan().maximumContextTokens();
  if (!automaticContext) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         "memory plan cannot hold one model token");
  }
  if (!config.nativeLoop.engine.maxContext) {
    config.nativeLoop.engine.maxContext = automaticContext;
  } else if (config.nativeLoop.engine.maxContext > automaticContext) {
    // --max-memory sets the budget only below this Mac's own.
    const auto &budget = resources->memoryPlan().breakdown();
    const bool memoryCapped = budget.configuredMemoryLimitBytes &&
                              budget.hardBudgetBytes == budget.configuredMemoryLimitBytes;
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         "--max-context " + std::to_string(config.nativeLoop.engine.maxContext) +
             " exceeds the " + std::to_string(automaticContext) + " tokens the model and " +
             (memoryCapped ? "--max-memory" : "this Mac's memory") +
             " allow; omit it or pass at most " + std::to_string(automaticContext));
  }
  // Without the disk tier a request that runs out of memory cannot publish
  // its progress checkpoints and replays its prompt.
  const std::optional<uint64_t> hostAvailable =
      resources->hostAvailableAtStart();
  if (!config.resources.maximumCacheDiskBytes && hostAvailable &&
      memoryMayNotHold(resources->memoryPlan(), *hostAvailable,
                       config.nativeLoop.engine.maxContext)) {
    logKernelStartup("The ", *hostAvailable / kMiB,
                     " MiB this Mac had available at startup may not hold a ",
                     config.nativeLoop.engine.maxContext,
                     "-token request; one that runs out of memory is suspended"
                     " and replays its prompt. --max-cache-disk SIZE keeps its"
                     " progress and cached prefixes on SSD.");
  }
  // The parser and engine consume the same resolved ceiling. In automatic
  // mode these limits cannot be known until resource planning has measured
  // the device and built the immutable page pool.
  config.protocolLimits.maxPromptTokens = config.nativeLoop.engine.maxContext;
  config.protocolLimits.maxLogicalOutputTokens =
      config.nativeLoop.engine.maxContext;
  config.nativeLoop.engine.vocabularySize =
      config.resources.model.capabilities.vocabularySize;
  // Images fit the vision scratch; a model without vision admits none.
  config.nativeLoop.engine.maxImagePatches =
      config.resources.model.hasVision() ? config.resources.maximumImagePatches
                                         : 0;

  std::unique_ptr<model::RuntimeModel> modelRuntime;
  try {
    const model::ModelMemoryPlan &modelMemory =
        resources->modelMemoryPlan();
    if (modelMemory.sharedDecodePlannedAllocatedBytes >
        std::numeric_limits<uint64_t>::max() -
            modelMemory.sharedPrefillPlannedAllocatedBytes) {
      throw std::overflow_error(
          "modelRuntime shared allocation reservation overflows");
    }
    const uint64_t modelBytes =
        modelMemory.sharedPrefillPlannedAllocatedBytes +
        modelMemory.sharedDecodePlannedAllocatedBytes;
    metal::AllocationFailure failure;
    auto reservation = resources->memoryGovernor().tryReserve(modelBytes, &failure);
    if (!reservation) {
      throw metal::MetalAllocationError(
          std::string("unable to reserve model arenas: ") +
              metal::allocationFailureName(failure), failure);
    }
    modelRuntime =
        model::createRuntime(resources->modelContext(*modelResidency));
    reservation->commit();
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
    config.nativeLoop.engine.growthPaused =
        [governor = &resources->memoryGovernor()] {
          return !governor->snapshot().hostGrowthAllowed;
        };
    nativeLoop = std::make_unique<NativeRuntime>(
        config.nativeLoop, resources->cache(), *modelRuntime,
        std::move(output), std::move(statusProvider), NativeLoopClocks{},
        config.protocolLimits);
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
      [resourcesPointer, modelPointer,
       packagePointer = modelResidency.get()](uint64_t estimatedPeakBytes) {
        resourcesPointer->backend().checkOperation();
        // Audit every attempted warmup before reclaiming idle buffers.
        // Wider batches and cache backing grow on demand after Ready.
        ActualMemoryReport report = resourcesPointer->actualMemoryReport(
            *packagePointer,
            modelPointer->actualRuntimeMemory(), estimatedPeakBytes);
        // Keep one lane's worth of warm buffers for the first request.
        static_cast<void>(resourcesPointer->stateStorage().releaseIdle(2, 1));
        resourcesPointer->cache().releaseUnusedKvBacking();
        resourcesPointer->memoryGovernor().markServingFootprint();
        return report;
      },
      *nativeLoop);

  // The per-operation guard RuntimeResources installed is only for startup:
  // once Ready, the engine meets memory pressure between its ticks.
  resources->backend().setOperationGuard({});
  LifecycleStatusSnapshot lifecycle;
  lifecycle.power = LifecyclePower::Unknown;
  lifecycle.state = LifecycleState::RecoveryFailed;
  lifecycle.controlReady = nativeLoop->ready();
  lifecycle.modelResident = true;
  lifecycle.configuredContextCeiling =
      config.nativeLoop.configuredContextCeiling
          ? config.nativeLoop.configuredContextCeiling
          : config.resources.model.capabilities.maximumContextTokens;
  lifecycle.effectiveContextTokens = config.nativeLoop.engine.maxContext;
  lifecycle.lastError = "power source is unknown";
  RecoverySpec recoverySpec;
  recoverySpec.resources = config.resources;
  recoverySpec.initializeResourcesIfAbsent = false;
  recoverySpec.modelRoot = config.resources.modelRoot;
  recoverySpec.model = config.resources.model;
  recoverySpec.kvFormat = config.resources.kvFormat;
  recoverySpec.buildId = config.resources.buildId;
  recoverySpec.memoryPressure = config.resources.memoryPressure;
  recoverySpec.cancelled = config.resources.cancelled;
  recoverySpec.hostAvailableMemory =
      config.resources.hostAvailableMemory
          ? config.resources.hostAvailableMemory
          : MemoryGovernor::HostAvailableMemoryProvider(
                queryHostAvailableMemory);
  recoverySpec.lifecycleWake = std::move(config.lifecycleWake);
  // growthPaused captures only the retained MemoryGovernor in RuntimeResources.
  // The main-process pressure/cancellation callbacks point to process-lifetime
  // observers; none of these callbacks captures released model residency.
  recoverySpec.engine = config.nativeLoop.engine;
  return std::unique_ptr<RuntimeBootstrap>(new RuntimeBootstrap(
      std::move(resources), std::move(modelResidency), std::move(modelRuntime),
      std::move(nativeLoop), std::move(report), std::move(lifecycle),
      std::move(admissionGate), std::move(recoverySpec)));
}

} // namespace splash::engine
