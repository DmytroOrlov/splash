#pragma once

#include "metal/Allocation.hpp"

#include <exception>
#include <functional>
#include <stdexcept>
#include <vector>

namespace splash::model {
// A borrowed port for one engine-owned writer generation. The engine keeps
// the port alive until its receipt has joined and been reclaimed.
class WriterRetirementPort {
public:
  virtual ~WriterRetirementPort() = default;
  virtual void launch(std::function<void()> body) = 0;
  [[nodiscard]] virtual bool joined() const = 0;
  virtual void reclaim() = 0;
  [[nodiscard]] virtual std::exception_ptr failure() const = 0;
};
// Executes a single image write on its writer thread, within the caller's
// resource scope. The completion notifier is outside this invocation.
using WeightWriteScope = std::function<void(const std::function<void()> &)>;

// Memory the engine gives back while idle and takes again before it runs the
// next request: a model's weights, which can be written again from their
// sources (WeightImages), with whatever else the engine gives back with them,
// or a test's stand-in.
class WeightMemory {
public:
  virtual ~WeightMemory() = default;
  // From release() until restore() has written the last image back.
  [[nodiscard]] virtual bool released() const noexcept = 0;
  // Gives the memory back while no command is in flight. During a restore it
  // gives back the parts restore() took back, which the next restore() starts
  // over from.
  virtual void release() = 0;
  // Takes back the next part released, such as an image whose memory `admit`
  // admits and which it writes again, in one admission; true once none is
  // left. A part whose memory admission or the driver refuses stays released
  // and throws metal::MetalAllocationError with the cause. Memory a part can
  // do without, such as an expert store's chunks above its floor
  // (model::ExpertStore), does not come back: the store grows it again as
  // memory allows. On any other failure the weights are unusable: the engine
  // stops.
  // A part may go on being written on a thread of its own once the call
  // returns (WeightImages), which calls the completion notifier as it ends:
  // writing() is true until then, and the next call, which may come only
  // after it, throws that write's failure as the call that wrote the part
  // would have.
  [[nodiscard]] virtual bool restore(const metal::AllocationAdmission &admit) = 0;
  // A part restore() took back is still being written on its thread, which
  // may allocate and run commands on the backend meanwhile.
  [[nodiscard]] virtual bool writing() const noexcept { return false; }
  // A lent writer remains active until the Owner has reclaimed its joined
  // generation. Unlike writing(), this must include the notifier and join.
  [[nodiscard]] virtual bool writerIntervalActive() const noexcept { return false; }
  // Owner-thread, nonblocking retirement polling. False means the interval
  // still owns authority; an implementation may reclaim a joined writer.
  [[nodiscard]] virtual bool pollWriterRetirement() { return true; }
  // Optional prepared writer boundary. The lease and retirement remain owned
  // by the caller; only an implementation with a prepared job accepts them.
  virtual void enableExternalWriter() {}
  virtual void setWeightWriteScope(WeightWriteScope) {}
  [[nodiscard]] virtual bool hasPreparedWriter() const noexcept { return false; }
  virtual void launchPreparedWriter(WriterRetirementPort &) { throw std::logic_error("no prepared writer"); }
  virtual bool finishPreparedWriter() { return true; }
  virtual void cancelPreparedWriter() { throw std::logic_error("no prepared writer"); }
  // Wakes the engine's loop as the write of a part on its thread ends, for
  // the writes restore() starts from then on; a part written before restore()
  // returns never calls it.
  virtual void setCompletionNotifier(std::function<void()>) {}
  // Enumerate actual persistent receiver slots during preparation. Wrappers
  // recursively append their receivers; mechanisms retaining no notifier add
  // none. The receivers must outlive prepared bindings and their rollback.
  virtual void completionRecipients(std::vector<WeightMemory *> &) {}
  // Installation must perform no allocation or callback invocation.
  virtual void swapCompletionNotifier(std::function<void()> &) noexcept {}
  virtual uint32_t notifierBindings() const noexcept { return 0; }
};

} // namespace splash::model
