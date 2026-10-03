#pragma once

#include "engine/Engine.hpp"
#include "engine/Protocol.hpp"
#include "engine/Status.hpp"

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

class RuntimeBootstrap;

// Shared final admission boundary. NativeRuntime holds the mutex through
// Engine submission; RuntimeBootstrap uses the same mutex to close/open it.
struct NativeAdmissionGate final {
  std::mutex mutex;
  bool inferenceReady = false;
};

struct NativeLoopConfig {
  engine::EngineConfig engine;
  uint64_t engineInstanceId = 1;
  uint32_t maskWordsPerToken = 1;
  // Static pre-residency capability advertised once for this process
  // generation. Zero preserves the direct-test/legacy Engine ceiling.
  uint32_t configuredContextCeiling = 0;
  bool visionSupported = false;
  std::shared_ptr<NativeAdmissionGate> admissionGate;
  RuntimeMetrics *metrics = nullptr;
};

struct NativeLoopClocks {
  std::function<uint64_t()> unixMicros;
  std::function<double()> monotonicMilliseconds;
};

// Translates native protocol messages and events at the Engine boundary.
class NativeRuntime final : private EngineEventSink {
public:
  using ByteSink = std::function<void(std::span<const uint8_t>)>;
  using StatusProvider = std::function<std::string()>;

  // Long-lived protocol/control shell. Inference residency may be published
  // later without replacing this object or its transport generation.
  NativeRuntime(NativeLoopConfig config, ByteSink output,
                StatusProvider statusProvider,
                NativeLoopClocks clocks = {},
                protocol::ProtocolLimits limits = {});
  NativeRuntime(NativeLoopConfig config, engine::Cache &cache,
                model::Model &model, ByteSink output,
                StatusProvider statusProvider, NativeLoopClocks clocks = {},
                protocol::ProtocolLimits limits = {});

  // Engine construction always binds valid, non-null Cache and Model
  // references. The shell owns only the currently published Engine.
  void publishEngine(engine::Cache &cache, model::Model &model);
  // Adopt an already-constructed Engine without consuming it on rejection.
  // Bootstrap uses this to publish the exact Engine assembled in a private
  // recovery candidate.
  [[nodiscard]] bool
  tryPublishEngine(std::unique_ptr<engine::Engine> &candidateEngine);
  void destroyEngine();
  [[nodiscard]] bool hasEngine() const noexcept { return core_ != nullptr; }

  // Processes every complete frame in bytes. False means the connection
  // must close. Request-scoped errors return true and preserve framing.
  bool receive(std::span<const uint8_t> bytes);
  bool finishInput();

  // Executes at most one explicit GPU BatchPlan.
  bool tick();
  // Command-free control work uses the same failure boundary as execution.
  bool runControl(const std::function<bool()> &control);
  void setCompletionNotifier(std::function<void()> notifier) {
    completionNotifier_ = std::move(notifier);
    if (core_)
      core_->setCompletionNotifier(completionNotifier_);
  }

  void observePrefill(uint32_t rows, double wallMilliseconds) {
    if (core_)
      core_->observePrefill(rows, wallMilliseconds);
  }

  void announceReady();

  [[nodiscard]] bool ready() const noexcept { return ready_; }
  [[nodiscard]] bool connectionMustClose() const noexcept {
    return closeConnection_;
  }
  [[nodiscard]] bool engineHealthy() const noexcept { return engineHealthy_; }
  // Code and message of the failure that stopped the engine, for the log.
  [[nodiscard]] const std::string &engineFailure() const noexcept {
    return engineFailure_;
  }
  [[nodiscard]] bool idle() const { return !core_ || core_->idle(); }
  [[nodiscard]] bool commandInFlight() const noexcept {
    return core_ && core_->commandInFlight();
  }
  // Used by the fd event host to block in poll(2) without periodic sleeps,
  // waking for either a request deadline or a deferred resource retry.
  [[nodiscard]] std::optional<double> millisecondsUntilNextWakeup() const;
  [[nodiscard]] engine::EngineSnapshot snapshot() const {
    return core_ ? core_->snapshot() : engine::EngineSnapshot{};
  }
  [[nodiscard]] engine::ResourceWaitSnapshot resourceWaitSnapshot() const {
    return core_ ? core_->resourceWaitSnapshot(clocks_.monotonicMilliseconds())
                 : engine::ResourceWaitSnapshot{};
  }
  [[nodiscard]] MemoryReclaimResult
  reclaimMemory(const MemoryReclaimDirective &directive) {
    return core_ ? core_->reclaimMemory(directive) : MemoryReclaimResult{};
  }
  [[nodiscard]] bool reclaimDeferred() const noexcept {
    return core_ && core_->reclaimDeferred();
  }

private:
  // Bootstrap assembles private recovery Engines with this existing event
  // sink; it never publishes them through NativeRuntime during construction.
  friend class RuntimeBootstrap;
  friend class RuntimeBootstrapTestAccess;

  struct RequestTelemetry {
    double arrivedMilliseconds = 0.0;
    double startedMilliseconds = 0.0;
    std::optional<double> firstTokenMilliseconds;
    std::optional<double> lastTokenMilliseconds;
    uint32_t emittedTokens = 0;
  };

  struct PendingMask {
    uint64_t maskRequestId = 0;
    uint64_t expectedWords = 0;
  };

  bool handle(protocol::Message &message);
  bool handleRequest(protocol::RequestFrame &request);
  bool handleCancel(const protocol::CancelFrame &cancel);
  bool handleMask(const protocol::MaskResponseFrame &mask);
  bool handleStatus(const protocol::StatusRequestFrame &status);
  bool handleMaskIssue(protocol::ProtocolIssue issue);
  bool handleIssue(protocol::ProtocolIssue issue);
  void requestError(uint64_t requestId, std::string code, std::string message,
                    bool retryable = false);
  void engineError(std::string code, std::string message);
  void executionFailed(std::exception_ptr error);
  bool send(protocol::Message message);

  void started(uint64_t requestId, EngineCacheStatus cacheStatus,
               uint32_t matchedTokens, uint32_t stateSlot) override;
  void batchCompleted(WorkKind kind, uint32_t width, uint32_t inputTokens,
                      uint32_t outputTokens, uint32_t draftedTokens,
                      uint32_t acceptedDraftTokens,
                      double wallMilliseconds) override;
  void promptProgress(uint64_t requestId, uint32_t processedTokens) override;
  void tokens(uint64_t requestId, std::span<const uint32_t> values) override;
  void maskRequested(uint64_t requestId,
                     std::span<const uint32_t> simulationTokens) override;
  void completed(uint64_t requestId, EngineFinishReason reason,
                 uint32_t promptTokens, uint32_t completionTokens,
                 std::span<const float> optionLogits) override;
  void failed(uint64_t requestId, std::string code, std::string message,
              bool retryable) override;
  void capacityExhausted(uint64_t requestId, uint32_t requiredKvPages,
                         uint32_t availableKvPages,
                         uint64_t retryAfterMicros) override;

  static NativeLoopClocks defaultClocks();
  static uint64_t durationMicros(double startMilliseconds,
                                 double endMilliseconds);

  NativeLoopConfig config_;
  ByteSink output_;
  StatusProvider statusProvider_;
  std::function<void()> completionNotifier_;
  NativeLoopClocks clocks_;
  protocol::ProtocolLimits limits_;
  protocol::FrameParser parser_;
  std::unique_ptr<engine::Engine> core_;
  std::unordered_map<uint64_t, RequestTelemetry> telemetry_;
  std::unordered_map<uint64_t, PendingMask> pendingMasks_;
  uint64_t nextMaskRequestId_ = 1;
  bool ready_ = false;
  bool closeConnection_ = false;
  bool engineHealthy_ = true;
  std::string engineFailure_;
};

} // namespace splash::engine
