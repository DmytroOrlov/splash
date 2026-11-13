#pragma once

#include "engine/AneFfnStartup.hpp"
#include "engine/Engine.hpp"
#include "engine/MemoryAudit.hpp"
#include "engine/MemoryGovernor.hpp"
#include "engine/MemoryPlan.hpp"
#include "engine/RuntimeMetrics.hpp"
#include "engine/ThermalState.hpp"
#include "engine/WeightResidency.hpp"
#include "metal/MetalBackend.hpp"
#include "model/ExpertStoreStats.hpp"
#include "model/KvReadStats.hpp"
#include "model/Model.hpp"
#include "model/SparseRowStore.hpp"

#include <array>
#include <optional>
#include <string>

namespace splash::engine {

struct RuntimeCacheIdentity;
struct NativeLoopTiming { double maxTickMilliseconds = 0.0; };

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
  // [FR-024 / T020] Published by the lifecycle owner's pump, one per
  // meaningful lifecycle state change; monotonic within the process generation
  // it was minted in. Its three-domain ordering with (processGeneration,
  // lifecycleRevision) is T038's; the pump is its only source.
  uint64_t observationSequence = 0;
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
  uint64_t retainedCacheBytes = 0; // physical KV + state backing, each counted once
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
  // A prefill of each class of chunk (ops::ExecutionPlans::prefillRowClasses).
  WarmupStepStatus prefillRowClasses = WarmupStepStatus::Pending;
  std::array<WarmupStepStatus, model::ExecutionLimits::maximumBatchWidth>
      decodeBatches{};
  WarmupStepStatus compositeStateRestore = WarmupStepStatus::Pending;
  // Exact executor-selected kernel geometry for the fixed 2048-row path.
  std::string maximumPrefillDetail;
};

// What the start fixed, which every status document reports: held by
// reference, so a StatusStart lives no longer than the values it names.
struct StatusStart final {
  const EngineMemoryPlan &plan;
  const RuntimeCacheIdentity &cacheIdentity;
  const WarmupReport &warmup;
  const MemoryAuditResult &memoryAudit;
};

// One sample of the serving runtime, taken on the loop thread.
struct StatusSample final {
  // A spill-capable target's KV on the SSD cache (kv_spill): what the cache
  // holds and did, and its readers' memory and reads.
  struct KvSpill final {
    KvSpillSnapshot cache;
    std::optional<model::KvBlockCacheStats> blockCache;
    std::optional<model::KvHistoryStreamStats> historyStream;
  };

  EngineSnapshot engine;
  ResourceWaitSnapshot resourceWait;
  WeightsSnapshot weights;
  RuntimeMetricsSnapshot metrics;
  model::ModelTelemetry telemetry;
  metal::MetalMemoryStats metalMemory;
  bool metalHealthy = true;
  // Why Metal failed; empty while it is healthy.
  std::string metalFailureReason;
  // metal::MetalBackend::pipelinesCreatedWhileServing.
  uint64_t pipelinesCreatedWhileServing = 0;
  MemoryGovernorSnapshot memoryGovernor;
  AneFfnSnapshot aneFfn;
  ThermalState thermalState = ThermalState::Nominal;
  // The loop's longest tick, which its transport measures.
  double loopMaxTickMilliseconds = 0.0;
  std::optional<model::SparseRowStats> streamedTable;
  std::optional<model::ExpertStoreStats> streamedExperts;
  // None for a target that keeps its KV in memory.
  std::optional<KvSpill> kvSpill;
  std::optional<LifecycleStatusSnapshot> lifecycle;
};

// Single source for /status and native protocol status events.
[[nodiscard]] std::string runtimeStatusJson(const StatusStart &start, const StatusSample &sample);
// Status while the model-bound stratum is absent and the retained graph
// (Cache, KV, persistence and backing) is not: the ownership and retained byte
// counts it states are the caller's snapshot evidence (ResourceSnapshot), and
// every section scoped to a loaded model or an Engine is null rather than a
// value this observation never measured. It refuses a snapshot that claims
// residency or inference readiness: only the Engine-borne status above can
// report a live model. T037 gives this model-less field shape its wire contract
// (the server codec, the golden document and the Python reading).
[[nodiscard]] std::string runtimeStatusJson(const ResourceSnapshot &resources,
                                            const RuntimeMetricsSnapshot &metrics,
                                            MemoryPressure memoryPressure,
                                            std::string failureReason,
                                            const ResourceWaitSnapshot &resourceWait);

} // namespace splash::engine
