#include "engine/PowerSource.hpp"

#include <IOKit/ps/IOPowerSources.h>

#include <condition_variable>
#include <exception>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>

namespace splash::engine {
namespace {

LifecyclePower samplePowerSource() noexcept {
  CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
  if (!snapshot)
    return LifecyclePower::Unknown;

  const CFStringRef source = IOPSGetProvidingPowerSourceType(snapshot);
  LifecyclePower result = LifecyclePower::Unknown;
  if (source && CFEqual(source, CFSTR(kIOPMACPowerKey)))
    result = LifecyclePower::AC;
  else if (source && CFEqual(source, CFSTR(kIOPMBatteryPowerKey)))
    result = LifecyclePower::Battery;
  // UPS and every absent/unsupported answer deliberately remain Unknown.
  CFRelease(snapshot);
  return result;
}

struct PowerSourceState final {
  std::mutex mutex;
  std::condition_variable readyCondition;
  PowerSource::Callback callback;
  CFRunLoopRef runLoop = nullptr; // retained while the observer thread runs
  bool ready = false;
  bool stopped = false;
  std::exception_ptr startupFailure;
};

void powerSourceChanged(void *context) {
  auto *state = static_cast<PowerSourceState *>(context);
  PowerSource::Callback callback;
  {
    std::lock_guard lock(state->mutex);
    if (state->stopped)
      return;
    callback = state->callback;
  }
  if (!callback)
    return;
  try {
    callback(samplePowerSource());
  } catch (...) {
    // Never let a client exception cross the IOKit C callback boundary.
  }
}

class SystemPowerSource final : public PowerSource {
public:
  SystemPowerSource() : state_(std::make_shared<PowerSourceState>()) {}
  ~SystemPowerSource() override { stop(); }

  LifecyclePower current() const noexcept override {
    return samplePowerSource();
  }

  void start(Callback callback) override {
    if (!callback)
      throw std::invalid_argument("power-source observer requires a callback");
    {
      std::lock_guard lock(state_->mutex);
      if (started_)
        throw std::logic_error("power-source observer already started");
      started_ = true;
      state_->callback = std::move(callback);
      state_->ready = false;
      state_->stopped = false;
      state_->startupFailure = nullptr;
    }

    try {
      const auto state = state_;
      thread_ = std::thread([state] {
        CFRunLoopSourceRef source =
            IOPSNotificationCreateRunLoopSource(powerSourceChanged,
                                                state.get());
        if (!source) {
          {
            std::lock_guard lock(state->mutex);
            state->startupFailure = std::make_exception_ptr(
                std::runtime_error(
                    "unable to register IOPowerSources notification"));
            state->ready = true;
          }
          state->readyCondition.notify_all();
          return;
        }

        CFRunLoopRef runLoop = CFRunLoopGetCurrent();
        CFRetain(runLoop);
        CFRunLoopAddSource(runLoop, source, kCFRunLoopDefaultMode);
        bool shouldRun = false;
        {
          std::lock_guard lock(state->mutex);
          state->runLoop = runLoop;
          state->ready = true;
          shouldRun = !state->stopped;
        }
        state->readyCondition.notify_all();

        if (shouldRun)
          CFRunLoopRun();

        CFRunLoopRemoveSource(runLoop, source, kCFRunLoopDefaultMode);
        {
          std::lock_guard lock(state->mutex);
          state->runLoop = nullptr;
          state->stopped = true;
          state->callback = {};
        }
        CFRelease(runLoop);
        CFRelease(source);
      });
    } catch (...) {
      std::lock_guard lock(state_->mutex);
      state_->callback = {};
      state_->stopped = true;
      started_ = false;
      throw;
    }

    std::exception_ptr startupFailure;
    {
      std::unique_lock lock(state_->mutex);
      state_->readyCondition.wait(lock, [this] { return state_->ready; });
      startupFailure = state_->startupFailure;
    }
    if (startupFailure) {
      stop();
      std::rethrow_exception(startupFailure);
    }
  }

  void stop() noexcept override {
    {
      std::lock_guard lock(state_->mutex);
      state_->stopped = true;
      state_->callback = {};
      if (state_->runLoop) {
        const CFRunLoopRef runLoop = state_->runLoop;
        // Queue the stop operation as well as signaling the current run. This
        // covers stop racing the observer thread just before CFRunLoopRun().
        CFRunLoopPerformBlock(runLoop, kCFRunLoopDefaultMode, ^{
          CFRunLoopStop(runLoop);
        });
        CFRunLoopWakeUp(state_->runLoop);
      }
    }
    if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id())
      thread_.join();
  }

private:
  std::shared_ptr<PowerSourceState> state_;
  std::thread thread_;
  bool started_ = false;
};

} // namespace

std::unique_ptr<PowerSource> makeSystemPowerSource() {
  return std::make_unique<SystemPowerSource>();
}

void PendingPowerObservation::recordInitial(LifecyclePower power) noexcept {
  try {
    std::function<void()> wake;
    {
      std::lock_guard lock(mutex_);
      if (initialSampleRecorded_ || observerCallbackSeen_)
        return;
      initialSampleRecorded_ = true;
      latest_ = power;
      pending_ = true;
      wake = wake_;
    }
    if (wake)
      wake();
  } catch (...) {
    // An observation callback cannot propagate through an OS callback.
  }
}

void PendingPowerObservation::record(LifecyclePower power) noexcept {
  try {
    std::function<void()> wake;
    {
      std::lock_guard lock(mutex_);
      observerCallbackSeen_ = true;
      latest_ = power;
      pending_ = true;
      wake = wake_;
    }
    if (wake)
      wake();
  } catch (...) {
    // An observation callback cannot propagate through an OS callback.
  }
}

std::optional<LifecyclePower> PendingPowerObservation::take() noexcept {
  try {
    std::lock_guard lock(mutex_);
    if (!pending_)
      return std::nullopt;
    pending_ = false;
    return latest_;
  } catch (...) {
    return std::nullopt;
  }
}

} // namespace splash::engine
