#pragma once

#include "engine/MemoryPlan.hpp"
#include "engine/Engine.hpp"
#include "metal/MetalBackend.hpp"
#include "engine/MemoryGovernor.hpp"
#include "engine/MemoryAudit.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <deque>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace splash::model {
struct ModelTelemetry;
} // namespace splash::model

namespace splash::engine {

struct RuntimeCacheIdentity;

// Lifecycle status is copied into detached snapshots so it remains readable
// while the inference residency (and therefore Engine) is absent.
enum class LifecyclePower { Unknown, AC, Battery };
enum class LifecycleState {
  Ready,
  Draining,
  Suspended,
  Recovering,
  RecoveryFailed,
  Shutdown,
};

[[nodiscard]] inline const char *lifecyclePowerName(
    LifecyclePower power) noexcept {
  switch (power) {
  case LifecyclePower::Unknown: return "unknown";
  case LifecyclePower::AC: return "ac";
  case LifecyclePower::Battery: return "battery";
  }
  return "unknown";
}

[[nodiscard]] inline const char *lifecycleStateName(
    LifecycleState state) noexcept {
  switch (state) {
  case LifecycleState::Ready: return "ready";
  case LifecycleState::Draining: return "draining";
  case LifecycleState::Suspended: return "suspended";
  case LifecycleState::Recovering: return "recovering";
  case LifecycleState::RecoveryFailed: return "recovery_failed";
  case LifecycleState::Shutdown: return "shutdown";
  }
  return "shutdown";
}

[[nodiscard]] inline bool validLifecyclePower(LifecyclePower power) noexcept {
  return power == LifecyclePower::Unknown || power == LifecyclePower::AC ||
         power == LifecyclePower::Battery;
}

[[nodiscard]] inline bool validLifecycleState(LifecycleState state) noexcept {
  return state == LifecycleState::Ready || state == LifecycleState::Draining ||
         state == LifecycleState::Suspended ||
         state == LifecycleState::Recovering ||
         state == LifecycleState::RecoveryFailed ||
         state == LifecycleState::Shutdown;
}

struct LifecycleStatusSnapshot {
  LifecyclePower power = LifecyclePower::Unknown;
  LifecycleState state = LifecycleState::RecoveryFailed;
  uint64_t revision = 0;
  bool controlReady = false;
  bool inferenceReady = false;
  bool modelResident = false;
  uint32_t configuredContextCeiling = 0;
  std::optional<uint32_t> effectiveContextTokens;
  std::string lastError;
};

// This value contains no owning or borrowed runtime pointers. An unknown power
// source is representable, but can never authorize inference readiness.
[[nodiscard]] inline bool validLifecycleStatus(
    const LifecycleStatusSnapshot &status) noexcept {
  if (!validLifecyclePower(status.power) || !validLifecycleState(status.state) ||
      !status.configuredContextCeiling)
    return false;
  if (status.inferenceReady) {
    return status.controlReady && status.state == LifecycleState::Ready &&
           status.power == LifecyclePower::AC && status.modelResident &&
           status.effectiveContextTokens &&
           *status.effectiveContextTokens > 0 &&
           *status.effectiveContextTokens <= status.configuredContextCeiling;
  }
  if (status.state == LifecycleState::Ready ||
      (status.state == LifecycleState::Suspended && status.modelResident)) {
    return false;
  }
  return !status.effectiveContextTokens ||
         (*status.effectiveContextTokens > 0 &&
          *status.effectiveContextTokens <= status.configuredContextCeiling);
}

struct ResourceSnapshot {
  LifecycleStatusSnapshot lifecycle;
  uint64_t backendAllocatedBytes = 0;
  bool modelPackageResident = false;
  std::optional<uint64_t> modelPackageResidentBytes;
  bool runtimeResident = false;
  std::optional<uint64_t> runtimeResidentBytes;
  uint64_t retainedCacheBytes = 0;
  uint64_t retainedKvBytes = 0;
  uint64_t retainedStateBytes = 0;
  bool modelTelemetryAvailable = false;
};

[[nodiscard]] inline bool validResourceSnapshot(
    const ResourceSnapshot &snapshot) noexcept {
  return validLifecycleStatus(snapshot.lifecycle) &&
         (!snapshot.lifecycle.modelResident ||
          (snapshot.modelPackageResident && snapshot.runtimeResident)) &&
         (!snapshot.runtimeResident || snapshot.modelPackageResident) &&
         snapshot.modelTelemetryAvailable == snapshot.lifecycle.modelResident &&
         (snapshot.modelPackageResident ||
          !snapshot.modelPackageResidentBytes) &&
         (snapshot.runtimeResident || !snapshot.runtimeResidentBytes);
}

enum class WarmupStepStatus { Pending, Complete, MemoryLimited };

struct WarmupReport {
  WarmupStepStatus maximumPrefill = WarmupStepStatus::Pending;
  std::array<WarmupStepStatus, model::ExecutionLimits::maximumBatchWidth>
      decodeBatches{};
  WarmupStepStatus draftVerifyCommit = WarmupStepStatus::Pending;
  WarmupStepStatus compositeStateRestore = WarmupStepStatus::Pending;
  // Exact executor-selected kernel geometry for the fixed 2048-row path.
  std::string maximumPrefillDetail;
  uint64_t actualPeakBytes = 0;
  std::string error;
  bool memoryBudgetValidated = false;

  [[nodiscard]] bool ready() const noexcept {
    const auto optionalComplete = [](WarmupStepStatus status) {
      return status == WarmupStepStatus::Complete ||
             status == WarmupStepStatus::MemoryLimited;
    };
    return error.empty() && memoryBudgetValidated &&
           maximumPrefill == WarmupStepStatus::Complete &&
           decodeBatches[0] == WarmupStepStatus::Complete &&
           draftVerifyCommit == WarmupStepStatus::Complete &&
           std::all_of(decodeBatches.begin() + 1, decodeBatches.end(),
                       optionalComplete) &&
           optionalComplete(compositeStateRestore);
  }
};

// Most recently completed real batch of one work kind. Status queries during
// GPU work retain this sample until the next same-kind batch completes.
struct RuntimeBatchMetricsSnapshot {
  bool valid = false;
  uint32_t width = 0;
  uint32_t inputTokens = 0;
  uint32_t outputTokens = 0;
  uint32_t draftedTokens = 0;
  uint32_t acceptedDraftTokens = 0;
  double wallMilliseconds = 0.0;
  double tokensPerSecond = 0.0;
};

struct RuntimeMetricsSnapshot {
  double ttftP50Milliseconds = 0.0;
  double ttftP95Milliseconds = 0.0;
  uint32_t ttftSamples = 0;
  double itlP50Milliseconds = 0.0;
  double itlP95Milliseconds = 0.0;
  uint32_t itlSamples = 0;
  double prefillTokensPerSecond = 0.0;
  double decodeTokensPerSecond = 0.0;
  // Lifetime native batch counters. Consumers take two status snapshots and
  // subtract them to measure one isolated workload without conflating TTFT
  // with transport latency.
  uint64_t prefillInputTokens = 0;
  double prefillWallMilliseconds = 0.0;
  uint64_t decodeOutputTokens = 0;
  double decodeWallMilliseconds = 0.0;
  uint64_t draftedTokens = 0;
  uint64_t acceptedDraftTokens = 0;
  double draftAcceptanceRate = 0.0;
  uint64_t capacityFailures = 0;
  uint64_t metalFailures = 0;
  RuntimeBatchMetricsSnapshot currentPrefillBatch;
  RuntimeBatchMetricsSnapshot currentDecodeBatch;
};

// Single-owner metrics accumulator for the native event loop. It stores a
// bounded latency window and lifetime throughput/correctness counters and
// emits the snapshot consumed by runtimeStatusJson().
class RuntimeMetrics final {
public:
  explicit RuntimeMetrics(uint32_t latencyWindow = 4096);

  void tokens(double submittedMilliseconds,
              std::optional<double> previousTokenMilliseconds,
              uint32_t count, double nowMilliseconds);
  void batchCompleted(WorkKind kind, uint32_t width, uint32_t inputTokens,
                      uint32_t outputTokens, uint32_t draftedTokens,
                      uint32_t acceptedDraftTokens, double wallMilliseconds);
  void capacityFailed();
  void metalFailed();

  [[nodiscard]] RuntimeMetricsSnapshot snapshot() const;

private:
  void append(std::deque<double> &samples, double value);
  static double percentile(const std::deque<double> &samples, double fraction);

  uint32_t latencyWindow_ = 0;
  std::deque<double> ttftMilliseconds_;
  std::deque<double> itlMilliseconds_;
  uint64_t prefillTokens_ = 0;
  uint64_t decodeTokens_ = 0;
  double prefillWallMilliseconds_ = 0.0;
  double decodeWallMilliseconds_ = 0.0;
  uint64_t draftedTokens_ = 0;
  uint64_t acceptedDraftTokens_ = 0;
  uint64_t capacityFailures_ = 0;
  uint64_t metalFailures_ = 0;
  RuntimeBatchMetricsSnapshot currentPrefillBatch_;
  RuntimeBatchMetricsSnapshot currentDecodeBatch_;
};

inline RuntimeMetrics::RuntimeMetrics(uint32_t latencyWindow)
    : latencyWindow_(latencyWindow) {
  if (!latencyWindow_)
    throw std::invalid_argument("latency window must be non-zero");
}

inline void RuntimeMetrics::tokens(
    double submittedMilliseconds,
    std::optional<double> previousTokenMilliseconds, uint32_t count,
    double nowMilliseconds) {
  if (!count || !std::isfinite(submittedMilliseconds) ||
      !std::isfinite(nowMilliseconds) ||
      nowMilliseconds < submittedMilliseconds) {
    throw std::invalid_argument("invalid metrics token event");
  }
  if (!previousTokenMilliseconds) {
    append(ttftMilliseconds_, nowMilliseconds - submittedMilliseconds);
  } else if (std::isfinite(*previousTokenMilliseconds) &&
             nowMilliseconds >= *previousTokenMilliseconds) {
    append(itlMilliseconds_,
           (nowMilliseconds - *previousTokenMilliseconds) / count);
  } else {
    throw std::invalid_argument("metrics token clock moved backwards");
  }
}

inline void RuntimeMetrics::batchCompleted(
    WorkKind kind, uint32_t width, uint32_t inputTokens,
    uint32_t outputTokens, uint32_t draftedTokens,
    uint32_t acceptedDraftTokens, double wallMilliseconds) {
  if (!width || !std::isfinite(wallMilliseconds) || wallMilliseconds < 0.0 ||
      acceptedDraftTokens > draftedTokens) {
    throw std::invalid_argument("invalid completed batch metrics");
  }
  RuntimeBatchMetricsSnapshot current{
      true,          width,         inputTokens, outputTokens,
      draftedTokens, acceptedDraftTokens, wallMilliseconds, 0.0,
  };
  if (kind == WorkKind::Prefill) {
    prefillTokens_ += inputTokens;
    prefillWallMilliseconds_ += wallMilliseconds;
    if (wallMilliseconds > 0.0)
      current.tokensPerSecond = double(inputTokens) * 1000.0 / wallMilliseconds;
    currentPrefillBatch_ = current;
  } else {
    decodeTokens_ += outputTokens;
    decodeWallMilliseconds_ += wallMilliseconds;
    draftedTokens_ += draftedTokens;
    acceptedDraftTokens_ += acceptedDraftTokens;
    if (wallMilliseconds > 0.0)
      current.tokensPerSecond = double(outputTokens) * 1000.0 / wallMilliseconds;
    currentDecodeBatch_ = current;
  }
}

inline void RuntimeMetrics::capacityFailed() {
  if (capacityFailures_ != std::numeric_limits<uint64_t>::max())
    ++capacityFailures_;
}

inline void RuntimeMetrics::metalFailed() {
  if (metalFailures_ != std::numeric_limits<uint64_t>::max())
    ++metalFailures_;
}

inline RuntimeMetricsSnapshot RuntimeMetrics::snapshot() const {
  RuntimeMetricsSnapshot result;
  result.ttftP50Milliseconds = percentile(ttftMilliseconds_, 0.50);
  result.ttftP95Milliseconds = percentile(ttftMilliseconds_, 0.95);
  result.ttftSamples = static_cast<uint32_t>(ttftMilliseconds_.size());
  result.itlP50Milliseconds = percentile(itlMilliseconds_, 0.50);
  result.itlP95Milliseconds = percentile(itlMilliseconds_, 0.95);
  result.itlSamples = static_cast<uint32_t>(itlMilliseconds_.size());
  if (prefillWallMilliseconds_ > 0.0) {
    result.prefillTokensPerSecond =
        double(prefillTokens_) * 1000.0 / prefillWallMilliseconds_;
  }
  if (decodeWallMilliseconds_ > 0.0) {
    result.decodeTokensPerSecond =
        double(decodeTokens_) * 1000.0 / decodeWallMilliseconds_;
  }
  result.prefillInputTokens = prefillTokens_;
  result.prefillWallMilliseconds = prefillWallMilliseconds_;
  result.decodeOutputTokens = decodeTokens_;
  result.decodeWallMilliseconds = decodeWallMilliseconds_;
  result.draftedTokens = draftedTokens_;
  result.acceptedDraftTokens = acceptedDraftTokens_;
  if (draftedTokens_) {
    result.draftAcceptanceRate =
        double(acceptedDraftTokens_) / double(draftedTokens_);
  }
  result.capacityFailures = capacityFailures_;
  result.metalFailures = metalFailures_;
  result.currentPrefillBatch = currentPrefillBatch_;
  result.currentDecodeBatch = currentDecodeBatch_;
  return result;
}

inline void RuntimeMetrics::append(std::deque<double> &samples, double value) {
  if (!std::isfinite(value) || value < 0.0)
    return;
  if (samples.size() == latencyWindow_)
    samples.pop_front();
  samples.push_back(value);
}

inline double RuntimeMetrics::percentile(const std::deque<double> &samples,
                                         double fraction) {
  if (samples.empty())
    return 0.0;
  std::vector<double> sorted(samples.begin(), samples.end());
  std::sort(sorted.begin(), sorted.end());
  const size_t index =
      static_cast<size_t>(std::ceil(fraction * sorted.size())) - 1;
  return sorted[std::min(index, sorted.size() - 1)];
}

// Emits only transitions; retry counts and queue depth do not produce logs.
class MemoryStatusReporter final {
public:
  [[nodiscard]] std::string update(const ResourceWaitSnapshot &wait,
                                    bool growthAllowed);
private:
  unsigned state_ = 0;
};

// Single source for /status and native protocol status events.
[[nodiscard]] std::string runtimeStatusJson(
    const LifecycleStatusSnapshot &lifecycle,
    const EngineMemoryPlan &plan, const EngineSnapshot &core,
    const metal::MetalMemoryStats &metalMemory, const WarmupReport &warmup,
    const MemoryAuditResult &memoryAudit, const RuntimeMetricsSnapshot &metrics,
    const model::ModelTelemetry &executorTelemetry,
    const RuntimeCacheIdentity &cacheIdentity,
    const MemoryGovernorSnapshot &memoryGovernor, bool metalHealthy,
    std::string metalFailureReason = {},
    const ResourceWaitSnapshot &resourceWait = {});

// Status for a control generation that has no published Engine. Only detached
// lifecycle/resource observations and process-local metrics are accepted, so
// passive status reads cannot keep or reconstruct model residency.
[[nodiscard]] std::string runtimeStatusJson(
    const ResourceSnapshot &resources, const RuntimeMetricsSnapshot &metrics,
    MemoryPressure memoryPressure, std::string failureReason = {},
    const ResourceWaitSnapshot &resourceWait = {});

} // namespace splash::engine
