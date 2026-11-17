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

// Test seam: dispatch the real notification handler on the adapter's run loop.
namespace testing {
void enqueueSystemPowerNotification(PowerSource &source);
bool systemPowerObserverStopped(PowerSource &source);
void invokeSystemPowerNotification(PowerSource &source);
} // namespace testing


// Callback threads only record the latest detached value and wake the native
// control loop. RuntimeBootstrap consumes it later at a native safe point.
class PendingPowerObservation final {
public:
  explicit PendingPowerObservation(std::function<void()> wake)
      : wake_(std::move(wake)) {}

  void recordInitial(LifecyclePower power) noexcept;
  void record(LifecyclePower power) noexcept;
  [[nodiscard]] std::optional<LifecyclePower> take() noexcept;

  // Serializes callback recording with publication and request admission.
  class Guard final {
  public:
    explicit Guard(PendingPowerObservation &owner)
        : owner_(owner), lock_(owner.mutex_) {}
    [[nodiscard]] uint64_t generation() const { return owner_.generation_; }
    [[nodiscard]] bool pending() const { return owner_.pending_; }
    [[nodiscard]] bool allowsAdmission() const {
      return owner_.latest_ == LifecyclePower::AC;
    }
    void unlock() { lock_.unlock(); }
  private:
    PendingPowerObservation &owner_;
    std::unique_lock<std::mutex> lock_;
  };
  [[nodiscard]] Guard guard() { return Guard(*this); }

private:
  std::mutex mutex_;
  std::function<void()> wake_;
  std::optional<LifecyclePower> latest_;
  uint64_t generation_ = 0;
  bool pending_ = false;
  bool initialSampleRecorded_ = false;
  bool observerCallbackSeen_ = false;
};

} // namespace splash::engine
