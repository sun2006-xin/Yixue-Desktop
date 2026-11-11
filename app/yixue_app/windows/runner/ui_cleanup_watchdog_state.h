#ifndef RUNNER_UI_CLEANUP_WATCHDOG_STATE_H_
#define RUNNER_UI_CLEANUP_WATCHDOG_STATE_H_

#include <atomic>

namespace yixue::runner {

enum class UiCleanupWatchdogStatus : int {
  kDormant = 0,
  kPending = 1,
  kCompleted = 2,
  kExpired = 3,
};

// Resolves the race between normal native teardown and the last-resort
// watchdog. Exactly one terminal state can win.
class UiCleanupWatchdogState final {
 public:
  UiCleanupWatchdogState() = default;

  UiCleanupWatchdogState(const UiCleanupWatchdogState&) = delete;
  UiCleanupWatchdogState& operator=(const UiCleanupWatchdogState&) = delete;

  bool TryStart() noexcept {
    auto expected = UiCleanupWatchdogStatus::kDormant;
    return status_.compare_exchange_strong(
        expected, UiCleanupWatchdogStatus::kPending,
        std::memory_order_acq_rel);
  }

  bool TryMarkCompleted() noexcept {
    auto expected = UiCleanupWatchdogStatus::kPending;
    return status_.compare_exchange_strong(
        expected, UiCleanupWatchdogStatus::kCompleted,
        std::memory_order_acq_rel);
  }

  bool TryMarkExpired() noexcept {
    auto expected = UiCleanupWatchdogStatus::kPending;
    return status_.compare_exchange_strong(
        expected, UiCleanupWatchdogStatus::kExpired,
        std::memory_order_acq_rel);
  }

  UiCleanupWatchdogStatus status() const noexcept {
    return status_.load(std::memory_order_acquire);
  }

 private:
  std::atomic<UiCleanupWatchdogStatus> status_{
      UiCleanupWatchdogStatus::kDormant};
};

}  // namespace yixue::runner

#endif  // RUNNER_UI_CLEANUP_WATCHDOG_STATE_H_
