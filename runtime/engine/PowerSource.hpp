#pragma once

#include "engine/Status.hpp"

#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>

namespace splash::engine {

// Reports the source currently powering the system. Implementations observe
// and report only; lifecycle policy belongs to RuntimeBootstrap.
class PowerSource {
public:
  using Callback = std::function<void(LifecyclePower)>;

  virtual ~PowerSource() = default;
  [[nodiscard]] virtual LifecyclePower current() const noexcept = 0;
  virtual void start(Callback callback) = 0;
  virtual void stop() noexcept = 0;
};

// The production macOS IOPowerSources adapter.
[[nodiscard]] std::unique_ptr<PowerSource> makeSystemPowerSource();

// Callback threads only record the latest detached value and wake the native
// control loop. RuntimeBootstrap consumes it later at a native safe point.
class PendingPowerObservation final {
public:
  explicit PendingPowerObservation(std::function<void()> wake)
      : wake_(std::move(wake)) {}

  void recordInitial(LifecyclePower power) noexcept;
  void record(LifecyclePower power) noexcept;
  [[nodiscard]] std::optional<LifecyclePower> take() noexcept;

private:
  std::mutex mutex_;
  std::function<void()> wake_;
  std::optional<LifecyclePower> latest_;
  bool pending_ = false;
  bool initialSampleRecorded_ = false;
  bool observerCallbackSeen_ = false;
};

} // namespace splash::engine
