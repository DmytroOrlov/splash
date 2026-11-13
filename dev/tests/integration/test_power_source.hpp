// Compiled only into the dedicated full-server integration executable.
#include <fstream>

class TestFilePowerSource final : public splash::engine::PowerSource {
public:
  TestFilePowerSource() : path_(std::getenv("SPLASH_TEST_POWER_FILE")) {}
  splash::engine::LifecyclePower current() const noexcept override {
    try {
      std::ifstream in(path_);
      std::string value;
      in >> value;
      if (value == "ac") return splash::engine::LifecyclePower::AC;
      if (value == "battery") return splash::engine::LifecyclePower::Battery;
    } catch (...) {}
    return splash::engine::LifecyclePower::Unknown;
  }
  void start(Callback callback) override {
    thread_ = std::thread([this, callback = std::move(callback)] {
      auto previous = current();
      while (!stopped_.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        const auto next = current();
        if (next != previous) { previous = next; callback(next); }
      }
    });
  }
  void stop() noexcept override {
    stopped_.store(true);
    if (thread_.joinable()) thread_.join();
  }
  ~TestFilePowerSource() override { stop(); }
private:
  std::string path_;
  std::atomic<bool> stopped_{false};
  std::thread thread_;
};
