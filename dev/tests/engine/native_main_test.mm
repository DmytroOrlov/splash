#define SPLASH_NATIVE_MAIN_TEST
#include "../../../runtime/main.mm"

#include <cstdlib>
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
  static_cast<void>(&splash::parseArguments);
  static_cast<void>(&splash::runNative);
  static_cast<void>(&splash::printBootstrapError);
  static_cast<void>(&splash::checkDevice);
}

std::vector<char *> argvFor(std::vector<std::string> &storage) {
  std::vector<char *> argv;
  argv.reserve(storage.size());
  for (std::string &argument : storage)
    argv.push_back(argument.data());
  return argv;
}

void testPauseOnBatteryArgumentDoesNotShiftPairs() {
  {
    splash::NativeArguments arguments;
    std::vector<std::string> storage{
        "splash", "serve-native", "target", "draft", "auto", "auto",
        "--decode-share", "0.25", "--pause-on-battery", "--kv-format",
        "bf16"};
    auto argv = argvFor(storage);
    splash::parseNativeOptions(arguments, static_cast<int>(argv.size()),
                               argv.data(), 6);
    require(arguments.pauseOnBattery, "standalone flag was not parsed");
    require(arguments.decodeShare == 0.25, "decode-share pair was shifted");
    require(arguments.kvFormat == splash::kv::Format::BFloat16,
            "kv-format pair was shifted");
  }
  {
    splash::NativeArguments arguments;
    std::vector<std::string> storage{
        "splash", "serve-native", "target", "draft", "auto", "auto",
        "--pause-on-battery", "--decode-share", "0.5", "--kv-format",
        "int8"};
    auto argv = argvFor(storage);
    splash::parseNativeOptions(arguments, static_cast<int>(argv.size()),
                               argv.data(), 6);
    require(arguments.pauseOnBattery, "flag before pairs was not parsed");
    require(arguments.decodeShare == 0.5, "adjacent decode-share was shifted");
    require(arguments.kvFormat == splash::kv::Format::Int8,
            "adjacent kv-format was shifted");
  }
  {
    splash::NativeArguments arguments;
    std::vector<std::string> storage{
        "splash", "serve-native", "target", "draft", "auto", "auto",
        "--decode-share", "0.75"};
    auto argv = argvFor(storage);
    splash::parseNativeOptions(arguments, static_cast<int>(argv.size()),
                               argv.data(), 6);
    require(!arguments.pauseOnBattery, "omitted flag did not default false");
    require(arguments.decodeShare == 0.75, "existing pair changed");
  }
}

class CountingPowerSource final : public PowerSource {
public:
  CountingPowerSource(int &starts, int &samples, int &registrations,
                      std::vector<std::string> &order)
      : starts_(starts), samples_(samples), registrations_(registrations),
        order_(order) {}

  LifecyclePower current() const noexcept override {
    ++samples_;
    order_.push_back("sample");
    return LifecyclePower::Battery;
  }
  void start(Callback callback) override {
    ++starts_;
    ++registrations_;
    order_.push_back("register");
    callback_ = std::move(callback);
  }
  void stop() noexcept override {}

private:
  int &starts_;
  int &samples_;
  int &registrations_;
  std::vector<std::string> &order_;
  Callback callback_;
};

void testBatteryPolicySetupGateAndStartupDecision() {
  int factories = 0;
  int starts = 0;
  int samples = 0;
  int registrations = 0;
  std::vector<std::string> order;
  const splash::PowerSourceFactory factory = [&] {
    ++factories;
    order.push_back("factory");
    return std::make_unique<CountingPowerSource>(
        starts, samples, registrations, order);
  };

  const auto disabled =
      splash::setupBatteryPolicy(false, factory, [] {});
  require(!disabled.powerSource && !disabled.pendingPower &&
              !disabled.initialPower,
          "disabled policy constructed battery state");
  require(factories == 0 && starts == 0 && samples == 0 && registrations == 0,
          "disabled policy touched the power source");
  require(!splash::shouldStartModelLess(false, disabled.initialPower),
          "disabled startup did not select full bootstrap");

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
}

} // namespace

int main() {
  try {
    retainNativeEntryPoints();
    testPauseOnBatteryArgumentDoesNotShiftPairs();
    testBatteryPolicySetupGateAndStartupDecision();
    std::cout << "native main tests passed\n";
    return EXIT_SUCCESS;
  } catch (const std::exception &error) {
    std::cerr << "native main tests failed: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
