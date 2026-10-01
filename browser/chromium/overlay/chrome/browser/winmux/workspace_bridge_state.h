#ifndef CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_STATE_H_
#define CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_STATE_H_

#include <algorithm>
#include <cstdint>
#include <optional>

namespace winmux {

// Confined to the bridge's serial background queue. A generation identifies a
// connection attempt, not a workspace revision or a persisted surface identity.
class WorkspaceBridgeState {
 public:
  uint64_t BeginAttempt() {
    ++generation_;
    phase_ = Phase::kConnecting;
    return generation_;
  }

  bool IsConnecting(uint64_t generation) const {
    return generation == generation_ && phase_ == Phase::kConnecting;
  }

  bool IsConnected(uint64_t generation) const {
    return generation == generation_ && phase_ == Phase::kConnected;
  }

  bool Authenticate(uint64_t generation) {
    if (!IsConnecting(generation))
      return false;
    phase_ = Phase::kConnected;
    next_delay_seconds_ = 1;
    ++authenticated_connections_;
    return true;
  }

  std::optional<unsigned> Disconnect(uint64_t generation) {
    if (generation != generation_ ||
        (phase_ != Phase::kConnecting && phase_ != Phase::kConnected)) {
      return std::nullopt;
    }
    phase_ = Phase::kWaiting;
    unsigned delay = next_delay_seconds_;
    next_delay_seconds_ = std::min(30u, next_delay_seconds_ * 2);
    return delay;
  }

  bool CanRetry(uint64_t generation) const {
    return generation == generation_ && phase_ == Phase::kWaiting;
  }

  uint64_t generation() const { return generation_; }
  uint64_t authenticated_connections() const {
    return authenticated_connections_;
  }

 private:
  enum class Phase { kIdle, kConnecting, kConnected, kWaiting };
  Phase phase_ = Phase::kIdle;
  uint64_t generation_ = 0;
  uint64_t authenticated_connections_ = 0;
  unsigned next_delay_seconds_ = 1;
};

}  // namespace winmux

#endif  // CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_STATE_H_
