#pragma once

#include "engine/ReleasableMemory.hpp"
#include "ops/ExecutionPlans.hpp"

#include <memory>

namespace splash::ops {
class AneFfn;
} // namespace splash::ops

namespace splash::model {
struct LoadedModel;
}

namespace splash::engine {

class RuntimeResources;
struct RuntimeResourcesTestAccess;

// The model-bound part of RuntimeResources: the loaded model (its weight
// images, streamed expert/PLE stores and model-only descendants), the
// execution plans, the prefill FFN's Neural Engine split and the idle-weight
// callbacks of ReleasableMemory. Moving this owner never moves them:
// RuntimeContext and idle-weight borrows keep their addresses. Only
// RuntimeResources can construct/hold a production residency; no public
// detach operation can let it outlive retained storage. A moved-from residency
// is the T009 absence state: model()/operators() are unusable there, while
// aneFfn()/releasableMemory() report null.
//
// Storage declares model, then operators, then the split, then ReleasableMemory
// last, so destruction is the reverse: the idle-weight callbacks go before
// the ANE referents, the plans and the model images, stores and writers they
// borrow; the shared SSD readers pool is not owned here (stream shares
// refer to the retained pool).
class ModelResidency final {
public:
  ModelResidency(const ModelResidency &) = delete;
  ModelResidency &operator=(const ModelResidency &) = delete;
  ModelResidency(ModelResidency &&) noexcept;
  ModelResidency &operator=(ModelResidency &&) noexcept;
  ~ModelResidency();

private:
  friend class RuntimeResources;
  friend struct RuntimeResourcesTestAccess;

  ModelResidency(model::LoadedModel &&model, ops::ExecutionPlans &&operators,
                 std::unique_ptr<ops::AneFfn> &&aneFfn);
  [[nodiscard]] model::LoadedModel &model() noexcept;
  [[nodiscard]] const model::LoadedModel &model() const noexcept;
  [[nodiscard]] const ops::ExecutionPlans &operators() const noexcept;
  // The split's program, or null without one.
  [[nodiscard]] ops::AneFfn *aneFfn() noexcept;
  [[nodiscard]] const ops::AneFfn *aneFfn() const noexcept;
  // The idle-weight releasable memory, or null on a moved-from residency.
  [[nodiscard]] ReleasableMemory *releasableMemory() noexcept;
  [[nodiscard]] const ReleasableMemory *releasableMemory() const noexcept;

  struct Storage;
  std::unique_ptr<Storage> storage_;
};

} // namespace splash::engine
