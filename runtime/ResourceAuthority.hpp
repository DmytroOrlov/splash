#pragma once

#include <string_view>

namespace splash::engine { class ResourceDomainAuthority; }
namespace splash::metal {

class AuthorityBinding;
class ResourceAuthority {
public:
  virtual ~ResourceAuthority() = default;
  virtual void check(std::string_view operation) const = 0;
  virtual void detachBackend(AuthorityBinding *binding) const = 0;
};

// The backend owns this slot; only the domain may bind or clear it.
class AuthorityBinding {
public:
  AuthorityBinding() = default;
  AuthorityBinding(const AuthorityBinding &) = delete;
  AuthorityBinding &operator=(const AuthorityBinding &) = delete;
  ~AuthorityBinding() { if (authority_) authority_->detachBackend(this); }
protected:
  [[nodiscard]] const ResourceAuthority *authority() const noexcept { return authority_; }
private:
  friend class splash::engine::ResourceDomainAuthority;
  const ResourceAuthority *authority_ = nullptr;
};

} // namespace splash::metal
