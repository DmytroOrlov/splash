#include "StderrLine.hpp"
#include "engine/MemoryPlan.hpp"
#include "engine/FdTransport.hpp"
#include "engine/Bootstrap.hpp"
#include "engine/PowerSource.hpp"
#include "engine/Status.hpp"
#include "model/Model.hpp"
#include "model/ModelDescriptor.hpp"

#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <charconv>
#include <csignal>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <limits.h>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#ifndef SPLASH_BUILD_ID
#error "production build requires the generated BuildIdentity.hpp"
#endif

namespace splash {
namespace {

// Temporary host/driver allocation failures can recover during startup.
// Preserve the desktop reserve and bound retries; configuration and compute
// failures remain immediate and fail-closed.
constexpr auto kStartupMemoryRecoveryTimeout = std::chrono::seconds(30);
constexpr auto kStartupMemoryRecoveryPoll = std::chrono::seconds(1);
class UsageError final : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

struct NativeArguments final {
  std::filesystem::path modelRoot;
  model::ModelDescriptor model;
  uint32_t maxContext = 0;
  uint64_t maxMemoryBytes = 0;
  uint64_t maxCacheDiskBytes = 0;
  kv::Format kvFormat = kv::Format::Int8;
  double decodeShare = engine::EngineConfig{}.decodeShare;
  bool pauseOnBattery = false;
};

// One observer spans bootstrap and serving. The dispatch queue only records
// pressure and wakes control; all allocation/reclaim decisions stay on the
// native thread. RAII also covers failed or interrupted startup.
class MemoryPressureMonitor final {
public:
  explicit MemoryPressureMonitor(std::function<void()> notify)
      : pending_(std::make_shared<std::atomic<engine::MemoryPressure>>(
            engine::MemoryPressure::Normal)),
        queue_(dispatch_queue_create("com.splash.memory-pressure",
                                     DISPATCH_QUEUE_SERIAL)) {
    source_ = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN |
            DISPATCH_MEMORYPRESSURE_CRITICAL, queue_);
    if (!source_)
      throw std::runtime_error("unable to create memory-pressure monitor");
    const auto pending = pending_;
    const auto source = source_;
    dispatch_source_set_event_handler(source_, ^{
      const unsigned long event = dispatch_source_get_data(source);
      engine::MemoryPressure pressure = engine::MemoryPressure::Normal;
      if (event & DISPATCH_MEMORYPRESSURE_CRITICAL)
        pressure = engine::MemoryPressure::Critical;
      else if (event & DISPATCH_MEMORYPRESSURE_WARN)
        pressure = engine::MemoryPressure::Warning;
      pending->store(pressure, std::memory_order_release);
      notify();
    });
    dispatch_activate(source_);
    timer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue_);
    if (!timer_) {
      dispatch_source_cancel(source_);
      dispatch_sync(queue_, ^{});
      throw std::runtime_error("unable to create memory-pressure timer");
    }
    // Notifications are coarse. The same safe-point control handler also
    // samples live host headroom twice a second, without dispatch-thread IO.
    dispatch_source_set_timer(
        timer_, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
        500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer_, ^{ notify(); });
    dispatch_activate(timer_);
  }
  ~MemoryPressureMonitor() {
    dispatch_source_cancel(timer_);
    dispatch_source_cancel(source_);
    dispatch_sync(queue_, ^{});
  }
  MemoryPressureMonitor(const MemoryPressureMonitor &) = delete;
  MemoryPressureMonitor &operator=(const MemoryPressureMonitor &) = delete;
  [[nodiscard]] engine::MemoryPressure pressure() const noexcept {
    // Notifications select individual processes and may arrive late. Sample
    // the current system level at the same safe points as host availability.
    return engine::querySystemMemoryPressure().value_or(
        pending_->load(std::memory_order_acquire));
  }

private:
  std::shared_ptr<std::atomic<engine::MemoryPressure>> pending_;
  dispatch_queue_t queue_;
  dispatch_source_t source_;
  dispatch_source_t timer_;
};

class PowerObservationTeardown final {
public:
  PowerObservationTeardown(
      std::unique_ptr<engine::PowerSource> &powerSource,
      std::unique_ptr<engine::RuntimeBootstrap> &bootstrap) noexcept
      : powerSource_(powerSource), bootstrap_(bootstrap) {}
  PowerObservationTeardown(const PowerObservationTeardown &) = delete;
  PowerObservationTeardown &operator=(const PowerObservationTeardown &) =
      delete;
  ~PowerObservationTeardown() {
    if (powerSource_)
      powerSource_->stop();
    if (bootstrap_) {
      try {
        static_cast<void>(bootstrap_->shutdownLifecycle());
      } catch (...) {
      }
    }
  }

private:
  std::unique_ptr<engine::PowerSource> &powerSource_;
  std::unique_ptr<engine::RuntimeBootstrap> &bootstrap_;
};

void printUsage(std::string_view executable) {
  writeStderrLine(
      "usage: " + std::string(executable) +
      " serve-native TARGET_DIRECTORY DRAFT_DIRECTORY"
      " MAX_CONTEXT|auto MAX_MEMORY_BYTES|auto [MAX_CACHE_DISK_BYTES]"
      " [--kv-format int8|bf16] [--decode-share SHARE]"
      " [--pause-on-battery]");
}

template <typename T>
bool parsePositive(std::string_view value, T &result) {
  const char *end = value.data() + value.size();
  auto parsed = std::from_chars(value.data(), end, result);
  return parsed.ec == std::errc{} && parsed.ptr == end && result != 0;
}

uint64_t parseMaxMemory(std::string_view value) {
  if (value == "auto")
    return 0;
  uint64_t result = 0;
  if (!parsePositive(value, result))
    throw UsageError("MAX_MEMORY_BYTES must be auto or a positive integer");
  return result;
}

uint32_t parseMaxContext(std::string_view value,
                         const model::ModelCapabilities &capabilities) {
  if (value == "auto")
    return 0;
  uint32_t result = 0;
  if (!parsePositive(value, result) ||
      result > capabilities.maximumContextTokens) {
    throw UsageError("MAX_CONTEXT must be auto or an integer in [1, " +
                     std::to_string(capabilities.maximumContextTokens) + "]");
  }
  return result;
}

double parseDecodeShare(std::string_view value) {
  double result = 0.0;
  const char *end = value.data() + value.size();
  auto parsed = std::from_chars(value.data(), end, result);
  if (parsed.ec != std::errc{} || parsed.ptr != end || !std::isfinite(result) ||
      result < 0.0)
    throw UsageError("--decode-share requires a nonnegative number");
  return result;
}

std::filesystem::path canonicalDirectory(std::string_view argument,
                                         std::string_view label) {
  std::error_code error;
  std::filesystem::path path =
      std::filesystem::canonical(std::filesystem::path(argument), error);
  if (error || !std::filesystem::is_directory(path, error) || error) {
    throw UsageError(std::string(label) + " must name an existing directory");
  }
  return path;
}

std::filesystem::path requireModelRoot(std::string_view targetArgument,
                                       std::string_view draftArgument) {
  std::filesystem::path target =
      canonicalDirectory(targetArgument, "TARGET_DIRECTORY");
  std::filesystem::path draft =
      canonicalDirectory(draftArgument, "DRAFT_DIRECTORY");
  if (target.filename() != "target" || draft.filename() != "draft" ||
      target.parent_path() != draft.parent_path()) {
    throw UsageError(
        "TARGET_DIRECTORY and DRAFT_DIRECTORY must be the target/ and "
        "draft/ subdirectories of one model root");
  }
  return target.parent_path();
}

void parseNativeOptions(NativeArguments &result, int argc, char **argv,
                        int next) {
  if (next < argc && !std::string_view(argv[next]).starts_with("--")) {
    const std::string_view quota(argv[next++]);
    if (quota != "0" && !parsePositive(quota, result.maxCacheDiskBytes))
      throw UsageError("MAX_CACHE_DISK_BYTES must be a nonnegative integer");
  }
  // Options follow as --name value pairs; a missing value fails its check.
  for (; next < argc;) {
    const std::string_view option(argv[next]);
    if (option == "--pause-on-battery") {
      result.pauseOnBattery = true;
      ++next;
      continue;
    }
    const std::string_view value(next + 1 < argc ? argv[next + 1] : "");
    if (option == "--kv-format") {
      if (value != "int8" && value != "bf16")
        throw UsageError("--kv-format requires int8 or bf16");
      result.kvFormat = value == "int8" ? kv::Format::Int8 : kv::Format::BFloat16;
    } else if (option == "--decode-share") {
      result.decodeShare = parseDecodeShare(value);
    } else {
      throw UsageError("unexpected argument " + std::string(option));
    }
    next += 2;
  }
}

NativeArguments parseArguments(int argc, char **argv) {
  if (argc < 6 || std::string_view(argv[1]) != "serve-native") {
    throw UsageError("expected the serve-native command");
  }
  NativeArguments result;
  parseNativeOptions(result, argc, argv, 6);
  result.modelRoot = requireModelRoot(argv[2], argv[3]);
  result.model = model::inspectModelPackage(result.modelRoot);
  result.maxContext = parseMaxContext(argv[4], result.model.capabilities);
  result.maxMemoryBytes = parseMaxMemory(argv[5]);
  return result;
}

struct BatteryPolicySetup final {
  std::unique_ptr<engine::PowerSource> powerSource;
  std::shared_ptr<engine::PendingPowerObservation> pendingPower;
  std::optional<engine::LifecyclePower> initialPower;
};

using PowerSourceFactory =
    std::function<std::unique_ptr<engine::PowerSource>()>;

BatteryPolicySetup setupBatteryPolicy(
    bool enabled, const PowerSourceFactory &makePowerSource,
    const std::function<void()> &wake) {
  BatteryPolicySetup setup;
  if (!enabled)
    return setup;

  setup.powerSource = makePowerSource();
  setup.pendingPower =
      std::make_shared<engine::PendingPowerObservation>(wake);
  setup.powerSource->start([pending = setup.pendingPower](
                               engine::LifecyclePower observation) {
    pending->record(observation);
  });
  // Register notifications first, then take a truthful synchronous sample.
  // Both this value and later callbacks use the same latest-value handoff.
  setup.pendingPower->recordInitial(setup.powerSource->current());
  // Consume the authoritative initial observation before choosing whether to
  // enter expensive inference bootstrap. A newer observer callback cannot be
  // overwritten by recordInitial and remains queued for the native safe point.
  setup.initialPower = setup.pendingPower->take().value_or(
      engine::LifecyclePower::Unknown);
  return setup;
}

bool shouldStartModelLess(
    bool pauseOnBattery,
    std::optional<engine::LifecyclePower> initialPower) noexcept {
  return pauseOnBattery &&
         initialPower.value_or(engine::LifecyclePower::Unknown) !=
             engine::LifecyclePower::AC;
}

std::filesystem::path executablePath() {
  uint32_t size = PATH_MAX;
  std::vector<char> buffer(size);
  if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
    buffer.resize(size);
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
      throw std::runtime_error("could not resolve executable path");
    }
  }
  std::error_code error;
  std::filesystem::path path = std::filesystem::canonical(buffer.data(), error);
  if (error) {
    throw std::runtime_error("could not canonicalize executable path: " +
                             error.message());
  }
  return path;
}

uint64_t engineInstanceId() {
  uint64_t process = static_cast<uint64_t>(getpid());
  uint64_t clock = static_cast<uint64_t>(
      std::chrono::steady_clock::now().time_since_epoch().count());
  uint64_t result = (process << 32) ^ clock;
  return result ? result : 1;
}

engine::RuntimeBootstrapConfig
bootstrapConfig(const NativeArguments &arguments) {
  const model::ModelCapabilities &capabilities = arguments.model.capabilities;
  const uint32_t maskWordsPerToken =
      (capabilities.vocabularySize + 31) / 32;
  engine::RuntimeBootstrapConfig config;
  config.resources.metallibPath =
      executablePath().parent_path() / "splash.metallib";
  config.resources.modelRoot = arguments.modelRoot;
  config.resources.model = arguments.model;
  config.resources.buildId = SPLASH_BUILD_ID;
  config.resources.maximumMemoryBytes = arguments.maxMemoryBytes;
  config.resources.maximumCacheDiskBytes = arguments.maxCacheDiskBytes;
  config.resources.kvFormat = arguments.kvFormat;
  config.nativeLoop.engine.maxContext = arguments.maxContext;
  config.nativeLoop.engine.decodeShare = arguments.decodeShare;
  config.nativeLoop.engineInstanceId = engineInstanceId();
  config.nativeLoop.configuredContextCeiling =
      arguments.maxContext ? arguments.maxContext
                           : capabilities.maximumContextTokens;
  config.nativeLoop.visionSupported = arguments.model.hasVision();
  config.nativeLoop.maskWordsPerToken = maskWordsPerToken;
  config.protocolLimits.maxTokenBatch =
      model::ExecutionLimits::maximumStepTokens;
  config.protocolLimits.maxSimulationTokens = capabilities.draftQueryRows;
  config.protocolLimits.maxMaskWords =
      maskWordsPerToken * (capabilities.draftQueryRows + 1);
  return config;
}

// SIGTERM, SIGINT and SIGHUP end the transport loop instead of killing the
// process, so the KV backing is released one extent at a time by the normal
// destructors. An inherited ignored SIGHUP (nohup) stays ignored, as it does
// for the server. SIGPIPE is ignored: a closed parent pipe surfaces as EPIPE,
// which the transport already reports as an I/O failure.
std::atomic<engine::FdTransport *> gShutdownTransport{nullptr};

void requestShutdownFromSignal(int) {
  const int savedErrno = errno;
  if (engine::FdTransport *transport =
          gShutdownTransport.load(std::memory_order_acquire)) {
    transport->requestShutdown();
  }
  errno = savedErrno;
}

// Keep shutdown idempotent through process teardown. Detach the transport before
// it is destroyed; later stop signals remain harmless until process exit.
class ShutdownSignals final {
public:
  explicit ShutdownSignals(engine::FdTransport &transport) {
    gShutdownTransport.store(&transport, std::memory_order_release);
    struct sigaction action {};
    action.sa_handler = requestShutdownFromSignal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    for (const int number : {SIGTERM, SIGINT, SIGHUP}) {
      struct sigaction inherited {};
      if (number == SIGHUP && sigaction(number, nullptr, &inherited) == 0 &&
          inherited.sa_handler == SIG_IGN)
        continue;
      sigaction(number, &action, nullptr);
    }
    std::signal(SIGPIPE, SIG_IGN);
  }
  ShutdownSignals(const ShutdownSignals &) = delete;
  ShutdownSignals &operator=(const ShutdownSignals &) = delete;
  ~ShutdownSignals() {
    gShutdownTransport.store(nullptr, std::memory_order_release);
  }
};

int runNative(const NativeArguments &arguments) {
  engine::FdTransport transport(STDIN_FILENO, STDOUT_FILENO);
  ShutdownSignals signals(transport);
  MemoryPressureMonitor pressureMonitor(transport.controlNotifier());
  engine::RuntimeMetrics metrics;
  engine::RuntimeBootstrap *published = nullptr;
  std::unique_ptr<engine::RuntimeBootstrap> bootstrap;
  BatteryPolicySetup batteryPolicy = setupBatteryPolicy(
      arguments.pauseOnBattery,
      [] { return engine::makeSystemPowerSource(); },
      transport.controlNotifier());
  auto &powerSource = batteryPolicy.powerSource;
  auto &pendingPower = batteryPolicy.pendingPower;
  PowerObservationTeardown observerTeardown(powerSource, bootstrap);
  auto statusProvider = [&]() -> std::string {
    if (!published) {
      engine::ResourceSnapshot detached;
      detached.lifecycle.configuredContextCeiling =
          arguments.maxContext ? arguments.maxContext
                               : arguments.model.capabilities.maximumContextTokens;
      detached.lifecycle.controlReady = published &&
                                        published->nativeLoop().ready();
      detached.lifecycle.state = engine::LifecycleState::RecoveryFailed;
      return engine::runtimeStatusJson(
          detached, metrics.snapshot(), pressureMonitor.pressure(), {},
          published ? published->nativeLoop().resourceWaitSnapshot()
                    : engine::ResourceWaitSnapshot{});
    }
    if (!published->hasResources()) {
      return engine::runtimeStatusJson(
          published->detachedResourceSnapshot(), metrics.snapshot(),
          pressureMonitor.pressure(), {},
          published->nativeLoop().resourceWaitSnapshot());
    }
    if (!published->hasModelRuntime()) {
      return engine::runtimeStatusJson(
          published->detachedResourceSnapshot(), metrics.snapshot(),
          pressureMonitor.pressure(), {},
          published->nativeLoop().resourceWaitSnapshot());
    }
    engine::RuntimeResources &resources = published->resources();
    // Status can arrive during GPU work; allocation/command boundaries and
    // the safe-point pressure monitor already refresh the cached sample.
    metal::MetalBackend &backend = resources.backend();
    bool healthy = backend.healthy();
    return engine::runtimeStatusJson(
        published->lifecycleStatus(), resources.memoryPlan(),
        published->nativeLoop().snapshot(),
        backend.memoryStats(), published->report().warmup,
        published->report().memoryAudit, metrics.snapshot(),
        published->modelRuntime().telemetry(),
        resources.cacheIdentity(),
        resources.memoryGovernor().snapshot(), healthy,
        healthy ? std::string{} : backend.unhealthyReason(),
        published->nativeLoop().resourceWaitSnapshot());
  };

  engine::StartupRetryWindow recovery(kStartupMemoryRecoveryTimeout);
  bool reportedRecoveryWait = false;
  while (!bootstrap) {
    if (transport.shutdownRequested())
      return static_cast<int>(engine::NativeProcessExit::CleanEof);
    engine::RuntimeBootstrapConfig config = bootstrapConfig(arguments);
    config.lifecycleWake = transport.controlNotifier();
    config.resources.memoryPressure = [&] { return pressureMonitor.pressure(); };
    config.resources.cancelled = [&] { return transport.shutdownRequested(); };
    config.nativeLoop.metrics = &metrics;
    try {
      if (!shouldStartModelLess(arguments.pauseOnBattery,
                                batteryPolicy.initialPower)) {
        bootstrap = engine::RuntimeBootstrap::start(
            std::move(config), transport.outputSink(), statusProvider);
      } else {
        // Battery and Unknown both fail closed before any RuntimeResources,
        // ModelPackage, RuntimeModel, or Engine construction.
        bootstrap = engine::RuntimeBootstrap::startModelLess(
            std::move(config), transport.outputSink(), statusProvider);
      }
    } catch (const engine::RuntimeBootstrapError &error) {
      if (transport.shutdownRequested())
        return static_cast<int>(engine::NativeProcessExit::CleanEof);
      const auto now = std::chrono::steady_clock::now();
      const auto recoveryDeadline = recovery.retryUntil(error.report(), now);
      if (!recoveryDeadline)
        throw;
      if (!reportedRecoveryWait) {
        writeStderrLine(
            "Waiting for sufficient available memory to start; "
            "the macOS reserve remains protected...");
        reportedRecoveryWait = true;
      }
      const auto resumeAt = std::min(
          now + std::chrono::steady_clock::duration(kStartupMemoryRecoveryPoll),
          *recoveryDeadline);
      while (std::chrono::steady_clock::now() < resumeAt &&
             !transport.shutdownRequested()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
      }
    }
  }
  if (transport.shutdownRequested())
    return static_cast<int>(engine::NativeProcessExit::CleanEof);
  published = bootstrap.get();
  if (batteryPolicy.initialPower)
    static_cast<void>(published->observePower(*batteryPolicy.initialPower));

  transport.setControlHandler([&pressureMonitor, pendingPower, published,
                               memoryReporter = engine::MemoryStatusReporter{},
                               pressurePolicy =
                                   engine::MemoryPressurePolicy{}]() mutable {
    if (pendingPower) {
      if (const auto observation = pendingPower->take())
        static_cast<void>(published->observePower(*observation));
      static_cast<void>(published->beginSuspend());
      const engine::SuspendProgress suspendProgress =
          published->advanceSuspend();
      const bool suspendNeedsAnotherSafePoint =
          suspendProgress == engine::SuspendProgress::WaitingForDrain;
      if (suspendNeedsAnotherSafePoint)
        return true;
      const engine::RecoveryProgress recoveryProgress =
          published->advanceRecovery();
      if (recoveryProgress == engine::RecoveryProgress::Building)
        return false;
    }
    if (!published->hasResources())
      return false;
    engine::MemoryPressure pressure = pressureMonitor.pressure();
    engine::RuntimeResources &resources = published->resources();
    engine::MemoryGovernor &governor = resources.memoryGovernor();
    governor.setPressure(pressure);
    const double now = std::chrono::duration<double, std::milli>(
                           std::chrono::steady_clock::now().time_since_epoch())
                           .count();
    static_cast<void>(resources.backend().refreshMemoryStats());
    const auto memory = governor.snapshot();
    const engine::ResourceWaitSnapshot wait =
        published->nativeLoop().resourceWaitSnapshot();
    const std::string diagnostic =
        memoryReporter.update(wait, memory.growthAllowed);
    if (!diagnostic.empty())
      writeStderrLine(diagnostic);
    engine::MemoryReclaimDirective directive =
        pressurePolicy.update(memory, now, wait.memory || wait.suspended);
    if (!directive.reclaimEmptyKvExtents)
      return false;
    const engine::MemoryReclaimResult reclaim =
        published->nativeLoop().reclaimMemory(directive);
    pressurePolicy.reclaimed(directive, reclaim);
    governor.reclaimed(reclaim.outcome);
    static_cast<void>(resources.backend().refreshMemoryStats());
    // KV backing is returned one extent at a time, and a target that
    // transfers held back continues as they land. Ask to run again at the
    // next command-free point meanwhile, so the rest follows without a
    // burst of kernel work.
    return published->nativeLoop().reclaimDeferred() ||
           reclaim.outcome == engine::ReclaimOutcome::Pending;
  });
  // Resolve the synchronous sample on the native owner thread before the
  // transport accepts its first queued request. Later changes use the same
  // control callback and safe-point operations below.
  if (pendingPower) {
    if (const auto observation = pendingPower->take())
      static_cast<void>(published->observePower(*observation));
    static_cast<void>(published->beginSuspend());
    static_cast<void>(published->advanceSuspend());
  }
  const auto exit = transport.run(bootstrap->nativeLoop());
  switch (exit) {
  case engine::NativeProcessExit::CleanEof:
    break;
  case engine::NativeProcessExit::ProtocolFailure:
    writeStderrLine(
        "error: native transport stopped after a protocol failure");
    break;
  case engine::NativeProcessExit::EngineFailure:
    writeStderrLine(
        "error: native transport stopped after an engine failure (" +
        bootstrap->nativeLoop().engineFailure() + ")");
    break;
  case engine::NativeProcessExit::IoFailure:
    writeStderrLine(
        "error: native transport stopped after an I/O failure");
    break;
  }
  return static_cast<int>(exit);
}

void printBootstrapError(const engine::RuntimeBootstrapReport &report) {
  writeStderrLine("error: " + report.describe());
  if (!report.memoryPlanJson.empty())
    writeStderrLine("memory_plan_json: " + report.memoryPlanJson);
}

// The engine's device rule, which the launcher runs before any download:
// serve-native applies it only once the model is prepared.
int checkDevice() {
  const auto message = metal::probeDeviceCapabilities().validationMessage();
  if (!message)
    return 0;
  writeStderrLine("error: " + *message);
  return static_cast<int>(engine::NativeProcessExit::EngineFailure);
}

} // namespace
} // namespace splash

#ifndef SPLASH_NATIVE_MAIN_TEST
int main(int argc, char **argv) {
  @autoreleasepool {
    try {
      if (argc == 2 && std::string_view(argv[1]) == "device-check")
        return splash::checkDevice();
      splash::NativeArguments arguments = splash::parseArguments(argc, argv);
      return splash::runNative(arguments);
    } catch (const splash::UsageError &error) {
      splash::writeStderrLine(std::string("error: ") + error.what());
      splash::printUsage(argc > 0 ? argv[0] : "splash");
      return static_cast<int>(
          splash::engine::NativeProcessExit::ProtocolFailure);
    } catch (const splash::engine::RuntimeBootstrapError &error) {
      splash::printBootstrapError(error.report());
      return static_cast<int>(
          splash::engine::NativeProcessExit::EngineFailure);
    } catch (const std::system_error &error) {
      splash::writeStderrLine(
          std::string("error: native runtime I/O failed: ") + error.what());
      return static_cast<int>(splash::engine::NativeProcessExit::IoFailure);
    } catch (const std::exception &error) {
      splash::writeStderrLine(std::string("error: ") + error.what());
      return static_cast<int>(
          splash::engine::NativeProcessExit::EngineFailure);
    }
  }
}
#endif
