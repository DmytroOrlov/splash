#define SPLASH_NATIVE_MAIN_TEST
#include "../../../runtime/main.mm"

#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <iostream>

namespace {

using splash::engine::LifecyclePower;
using splash::engine::PowerSource;

void require(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}

void retainNativeEntryPoints() {
  static_cast<void>(&splash::printUsage);
  static_cast<void>(&splash::runNative);
  static_cast<void>(&splash::reportStartFailure);
  static_cast<void>(&splash::checkDevice);
  static_cast<void>(&splash::checkModel);
  static_cast<void>(&splash::engine::parseNativeArguments);
}

// Exercise the production observer thread and notification handler.
void testSystemPowerStopWaitsForInflightCallback() {
  auto source = splash::engine::makeSystemPowerSource();
  std::mutex mutex;
  std::condition_variable condition;
  bool entered = false;
  bool release = false;
  std::atomic<int> deliveries{0};
  std::atomic<bool> returned{false};
  source->start([&](LifecyclePower) {
    ++deliveries;
    std::unique_lock lock(mutex);
    entered = true;
    condition.notify_all();
    condition.wait(lock, [&] { return release; });
  });
  // Always unblock the observer and join the stopper before unwinding.
  std::thread stopper;
  struct Cleanup {
    std::mutex &mutex;
    std::condition_variable &condition;
    bool &release;
    std::thread &stopper;
    PowerSource &source;
    ~Cleanup() {
      { std::lock_guard lock(mutex); release = true; }
      condition.notify_all();
      if (stopper.joinable()) stopper.join();
      else source.stop();
    }
  } cleanup{mutex, condition, release, stopper, *source};
  splash::engine::testing::enqueueSystemPowerNotification(*source);
  {
    std::unique_lock lock(mutex);
    require(condition.wait_for(lock, std::chrono::seconds(5), [&] { return entered; }),
            "observer callback did not enter within five seconds");
  }
  stopper = std::thread([&] { source->stop(); returned = true; });
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!splash::engine::testing::systemPowerObserverStopped(*source) &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::yield();
  require(splash::engine::testing::systemPowerObserverStopped(*source),
          "observer did not stop within five seconds");
  require(!returned.load(), "stop returned while the observer callback was blocked");
  {
    std::lock_guard lock(mutex);
    release = true;
  }
  condition.notify_all();
  stopper.join();
  require(returned.load() && deliveries.load() == 1,
          "stop failed to join the completed callback");
  splash::engine::testing::invokeSystemPowerNotification(*source);
  require(deliveries.load() == 1, "a notification reached the client after stop");
}

// The opt-in defaults off and selects ordinary startup.
void testPauseOnBatteryOptInContract() {
  require(!splash::engine::NativeArguments{}.pauseOnBattery,
          "pause-on-battery defaulted on");
  require(!splash::shouldStartModelLess(false, std::nullopt),
          "default command line did not select full startup");
}

class CountingPowerSource final : public PowerSource {
public:
  CountingPowerSource(int &starts, int &samples, int &registrations,
                      std::vector<std::string> &order,
                      LifecyclePower initial = LifecyclePower::Battery,
                      std::optional<LifecyclePower> duringStart = std::nullopt,
                      int *callbacks = nullptr)
      : starts_(starts), samples_(samples), registrations_(registrations),
        order_(order), initial_(initial), duringStart_(duringStart),
        callbacks_(callbacks) {}

  LifecyclePower current() const noexcept override {
    ++samples_;
    order_.push_back("sample");
    return initial_;
  }
  void start(Callback callback) override {
    ++starts_;
    ++registrations_;
    order_.push_back("register");
    callback_ = std::move(callback);
    if (duringStart_) {
      // The OS notification lands while start() is still registering: the
      // synchronous sample that follows is the OLDER reading.
      order_.push_back("callback");
      if (callbacks_)
        ++*callbacks_;
      callback_(*duringStart_);
    }
  }
  void stop() noexcept override {}

 private:
  int &starts_;
  int &samples_;
  int &registrations_;
  std::vector<std::string> &order_;
  LifecyclePower initial_;
  std::optional<LifecyclePower> duringStart_;
  int *callbacks_;
  Callback callback_;
};

// A source that keeps its client callback and delivers by request, recording
// every delivery, and whose stop() does what the real adapter's does: it
// clears the callback and refuses every later delivery.
class DeliveringPowerSource final : public PowerSource {
public:
  DeliveringPowerSource(int &stops, std::vector<std::string> &order,
                        int &deliveries, int &suppressed)
      : stops_(stops), order_(order), deliveries_(deliveries),
        suppressed_(suppressed) {}

  LifecyclePower current() const noexcept override {
    return LifecyclePower::Battery;
  }
  void start(Callback callback) override {
    callback_ = std::move(callback);
    stopped_ = false;
  }
  void stop() noexcept override {
    ++stops_;
    order_.push_back("stop");
    stopped_ = true;
    callback_ = {};
  }
  // An OS notification racing the teardown: after stop() it must not reach
  // the client callback at all.
  void deliver(LifecyclePower power) {
    if (stopped_ || !callback_) {
      ++suppressed_;
      order_.push_back("suppressed");
      return;
    }
    ++deliveries_;
    order_.push_back("deliver");
    callback_(power);
  }
  [[nodiscard]] bool holdsCallback() const noexcept { return !!callback_; }

 private:
  int &stops_;
  std::vector<std::string> &order_;
  int &deliveries_;
  int &suppressed_;
  Callback callback_;
  bool stopped_ = false;
};

// [T026] The observer callback must win over the synchronous initial sample:
// registration precedes the sample, so a notification that lands in between
// is the NEWER observation and recordInitial() must not overwrite it. The
// startup choice then follows the newer value, and exactly one wake happened.
void testObserverCallbackBeatsTheLateInitialSample() {
  int starts = 0;
  int samples = 0;
  int registrations = 0;
  int callbacks = 0;
  int wakes = 0;
  std::vector<std::string> order;

  // The observer says AC; the later synchronous sample answers Battery.
  const splash::PowerSourceFactory newerAhead = [&] {
    order.push_back("factory");
    return std::make_unique<CountingPowerSource>(
        starts, samples, registrations, order, LifecyclePower::Battery,
        LifecyclePower::AC, &callbacks);
  };
  const auto ahead = splash::setupBatteryPolicy(true, newerAhead, [&] { ++wakes; });
  require(order == std::vector<std::string>{"factory", "register", "callback", "sample"},
          "the observer callback did not land between registration and the sample");
  require(ahead.initialPower == LifecyclePower::AC,
          "the late initial sample overwrote the newer observer callback");
  require(starts == 1 && registrations == 1 && samples == 1 && callbacks == 1,
          "registration, sample or callback counts were incorrect");
  require(wakes == 1, "the observer wake was lost, or the suppressed initial sample woke again");
  require(!splash::shouldStartModelLess(true, ahead.initialPower),
          "the newer AC observation did not select the full bootstrap");
  require(splash::initialServingAuthorization(true, ahead.initialPower) ==
              LifecyclePower::AC,
          "the newer observation was not preserved as the startup authorization");

  // The mirror: a Battery callback beats an AC sample, and model-less startup
  // follows the newer observation.
  order.clear();
  const splash::PowerSourceFactory batteryAhead = [&] {
    return std::make_unique<CountingPowerSource>(
        starts, samples, registrations, order, LifecyclePower::AC,
        LifecyclePower::Battery, &callbacks);
  };
  const auto behind = splash::setupBatteryPolicy(true, batteryAhead, [&] { ++wakes; });
  require(behind.initialPower == LifecyclePower::Battery,
          "an AC initial sample overwrote the newer Battery callback");
  require(splash::shouldStartModelLess(true, behind.initialPower),
          "the newer Battery observation did not select model-less startup");
  require(splash::initialServingAuthorization(true, behind.initialPower) ==
              LifecyclePower::Battery,
          "the newer Battery observation was not preserved");
}

// [T026] The handoff is a record+wake pair and nothing else: no lifecycle
// state machine, no resource domain, no Engine/Model/Cache/Governor/ANE is
// reachable from it. The real adapter's OS callback (PowerSource.mm's
// powerSourceChanged) samples IOPowerSources and calls this record — nothing
// else; RuntimeBootstrap alone revises the lifecycle intent.
void testPendingPowerObservationIsRecordAndWakeOnly() {
  int wakes = 0;
  splash::engine::PendingPowerObservation pending([&] { ++wakes; });

  pending.recordInitial(LifecyclePower::AC);
  const auto initial = pending.take();
  require(initial.has_value() && *initial == LifecyclePower::AC && wakes == 1,
          "the initial observation was not recorded once and woken");
  require(!pending.take().has_value(), "one observation was handed out twice");

  pending.recordInitial(LifecyclePower::Battery);
  require(!pending.take().has_value() && wakes == 1,
          "a second initial sample recorded, or woke the loop with nothing new");

  pending.record(LifecyclePower::Battery);
  pending.record(LifecyclePower::Battery);
  require(wakes == 3, "each observer callback must wake the control loop");
  const auto latest = pending.take();
  require(latest.has_value() && *latest == LifecyclePower::Battery,
          "duplicate callbacks did not keep the latest detached value");

  // A late initial sample cannot overwrite what the observer already saw.
  pending.recordInitial(LifecyclePower::AC);
  require(!pending.take().has_value() && wakes == 3,
          "a late initial sample overwrote the observer's latest value");

  // Unknown stays fail-closed and legible.
  pending.record(LifecyclePower::Unknown);
  const auto unknown = pending.take();
  require(unknown.has_value() && *unknown == LifecyclePower::Unknown,
          "an Unknown observation was dropped instead of reported");
  std::cout << "PASS pending power observation is record+wake only\n";
}

// A real model-less control shell, started through the production startModelLess
// path (no RuntimeResources, no Engine): the Bootstrap whose teardown the
// observer must precede.
std::unique_ptr<splash::engine::RuntimeBootstrap> modelLessBootstrap(
    splash::engine::RuntimeMetrics &metrics, std::vector<uint8_t> &output) {
  splash::engine::RuntimeBootstrapConfig config;
  config.resources.model.capabilities.vocabularySize = 1024;
  config.resources.model.capabilities.maximumContextTokens = 2048;
  config.nativeLoop.engine.maxContext = 2048;
  config.nativeLoop.metrics = &metrics;
  config.initialPower = LifecyclePower::Battery;
  config.lifecycleWake = [] {};
  return splash::engine::RuntimeBootstrap::startModelLess(
      std::move(config),
      [&output](std::span<const uint8_t> bytes) {
        output.insert(output.end(), bytes.begin(), bytes.end());
      },
      [] { return std::string("{}"); });
}

// [T026] Observer teardown precedes Bootstrap teardown, and a notification
// that races it can never reach a Bootstrap that has gone: the client callback
// captures the shared PendingPowerObservation, never a raw Bootstrap pointer,
// and stop() clears it. The same order holds on a startup that never published
// a Bootstrap.
void testObserverTeardownPrecedesBootstrapAndSuppressesLateCallbacks() {
  int stops = 0;
  int deliveries = 0;
  int suppressed = 0;
  int wakes = 0;
  std::vector<std::string> order;

  // runNative's declaration order: the Bootstrap slot before the observer
  // teardown, so ~PowerObservationTeardown (stop, then shutdownLifecycle)
  // runs while the Bootstrap is still alive.
  splash::engine::RuntimeMetrics metrics;
  std::vector<uint8_t> output;
  auto bootstrap = modelLessBootstrap(metrics, output);
  std::unique_ptr<splash::engine::PowerSource> powerSource =
      std::make_unique<DeliveringPowerSource>(stops, order, deliveries, suppressed);
  auto *observer =
      static_cast<DeliveringPowerSource *>(powerSource.get());
  auto pendingPower =
      std::make_shared<splash::engine::PendingPowerObservation>([&] { ++wakes; });
  observer->start([pendingPower](LifecyclePower power) {
    pendingPower->record(power);
  });
  require(bootstrap->lifecycleStatus().state !=
              splash::engine::LifecycleState::Shutdown,
          "the published model-less shell was already shut down before teardown");
  {
    splash::PowerObservationTeardown teardown(powerSource, bootstrap);
    // A delivery while serving: recorded for the pump's next safe point.
    observer->deliver(LifecyclePower::Battery);
    require(deliveries == 1 && wakes == 1 &&
                pendingPower->take() == LifecyclePower::Battery,
            "a serving-time delivery did not reach the handoff only");
  }

  // The teardown ran: the observer stopped first, then the terminal lifecycle
  // intent was taken on the Bootstrap, which is still alive and serving control
  // here (its own shutdown reports the already-taken terminal intent).
  require(stops == 1 && order == std::vector<std::string>{"deliver", "stop"},
          "the observer stop did not happen exactly once, after the serving delivery");
  require(!observer->holdsCallback(),
          "the teardown left a client callback the OS could still deliver to");
  require(!bootstrap->shutdownLifecycle(),
          "the observer teardown did not take the terminal shutdown intent "
          "on the still-alive Bootstrap");
  require(bootstrap->lifecycleStatus().state ==
              splash::engine::LifecycleState::Shutdown,
          "the shutdown intent did not reach the lifecycle state");

  // A notification racing the teardown cannot reach anything: suppressed.
  observer->deliver(LifecyclePower::AC);
  require(suppressed == 1 && deliveries == 1,
          "a post-teardown delivery still reached the client callback");

  // The same ordering with a startup that never published a Bootstrap: the
  // observer still stops, and no lifecycle shutdown is attempted.
  std::unique_ptr<splash::engine::RuntimeBootstrap> unpublished;
  {
    std::unique_ptr<splash::engine::PowerSource> failedSource =
        std::make_unique<DeliveringPowerSource>(stops, order, deliveries, suppressed);
    auto *failedObserver =
        static_cast<DeliveringPowerSource *>(failedSource.get());
    auto failedPending =
        std::make_shared<splash::engine::PendingPowerObservation>([] {});
    // The policy registered its observer before the Bootstrap was built; the
    // startup then failed, so the teardown must still stop the observer cleanly
    // and never touch a Bootstrap that does not exist.
    failedSource->start([failedPending](LifecyclePower power) {
      failedPending->record(power);
    });
    splash::PowerObservationTeardown failedTeardown(failedSource, unpublished);
    failedObserver->deliver(LifecyclePower::Battery);
    require(deliveries == 2, "a delivery before the failed-start teardown was lost");
  }
  require(stops == 2 && !unpublished && suppressed == 1 && deliveries == 2,
          "an early-return teardown did not stop the observer cleanly");
  std::cout << "PASS observer teardown order: stop before Bootstrap teardown, "
               "late callbacks suppressed, callback owns only the handoff\n";
}

void testBatteryPolicySetupGateAndStartupDecision() {
  int factories = 0;
  int starts = 0;
  int samples = 0;
  int registrations = 0;
  std::vector<std::string> order;
  LifecyclePower configuredPower = LifecyclePower::Battery;
  const splash::PowerSourceFactory factory = [&] {
    ++factories;
    order.push_back("factory");
    return std::make_unique<CountingPowerSource>(
        starts, samples, registrations, order, configuredPower);
  };

  for (const auto power : {LifecyclePower::Battery, LifecyclePower::Unknown}) {
    configuredPower = power;
    const auto disabled = splash::setupBatteryPolicy(false, factory, [] {});
    require(!disabled.powerSource && !disabled.pendingPower &&
                !disabled.initialPower,
            "disabled policy constructed battery state");
    require(factories == 0 && starts == 0 && samples == 0 &&
                registrations == 0,
            "disabled policy touched the power source");
    require(!splash::shouldStartModelLess(false, disabled.initialPower),
            "disabled startup did not select full bootstrap");
    const auto authorization = splash::initialServingAuthorization(
        false, disabled.initialPower);
    require(authorization == LifecyclePower::AC,
            "disabled startup did not select AC-equivalent authorization");
  }

  configuredPower = LifecyclePower::Battery;
  const auto enabled = splash::setupBatteryPolicy(true, factory, [] {});
  require(enabled.powerSource && enabled.pendingPower &&
              enabled.initialPower == LifecyclePower::Battery,
          "enabled policy did not return its initial battery state");
  require(factories == 1 && starts == 1 && samples == 1 && registrations == 1,
          "enabled policy setup counts were incorrect");
  require(order == std::vector<std::string>{"factory", "register", "sample"},
          "power callback was not registered before sampling");
  require(splash::shouldStartModelLess(true, LifecyclePower::Battery),
          "battery startup did not select model-less bootstrap");
  require(splash::shouldStartModelLess(true, LifecyclePower::Unknown),
          "unknown startup did not select model-less bootstrap");
  require(!splash::shouldStartModelLess(true, LifecyclePower::AC),
          "AC startup did not select full bootstrap");
  require(splash::initialServingAuthorization(true, enabled.initialPower) ==
              LifecyclePower::Battery,
          "enabled startup did not preserve its physical initial observation");
  require(splash::initialServingAuthorization(true, LifecyclePower::Unknown) ==
              LifecyclePower::Unknown,
          "enabled Unknown initial observation was not preserved");
  require(splash::shouldStartModelLess(true, LifecyclePower::Unknown),
          "enabled Unknown stopped selecting model-less startup");
  require(splash::initialServingAuthorization(true, LifecyclePower::AC) ==
              LifecyclePower::AC,
          "enabled AC did not preserve full-start authorization");
}

} // namespace

int main() {
  try {
    retainNativeEntryPoints();
    testSystemPowerStopWaitsForInflightCallback();
    testPauseOnBatteryOptInContract();
    testBatteryPolicySetupGateAndStartupDecision();
    testObserverCallbackBeatsTheLateInitialSample();
    testPendingPowerObservationIsRecordAndWakeOnly();
    testObserverTeardownPrecedesBootstrapAndSuppressesLateCallbacks();
    std::cout << "native main tests passed\n";
    return EXIT_SUCCESS;
  } catch (const std::exception &error) {
    std::cerr << "native main tests failed: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
