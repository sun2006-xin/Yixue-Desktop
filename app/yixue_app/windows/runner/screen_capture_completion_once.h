#ifndef RUNNER_SCREEN_CAPTURE_COMPLETION_ONCE_H_
#define RUNNER_SCREEN_CAPTURE_COMPLETION_ONCE_H_

#include <atomic>
#include <utility>

namespace yixue::runner {

// A completion may have several mutually exclusive delivery paths (UI
// dispatch, post failure, or teardown discard). This claim lets each path
// safely attempt a MethodResult reply while ensuring only one path owns it.
class ScreenCaptureCompletionReply final {
 public:
  ScreenCaptureCompletionReply() = default;
  ScreenCaptureCompletionReply(const ScreenCaptureCompletionReply&) = delete;
  ScreenCaptureCompletionReply& operator=(
      const ScreenCaptureCompletionReply&) = delete;

  template <typename Callback>
  bool InvokeOnce(Callback&& callback) noexcept {
    bool expected = false;
    if (!replied_.compare_exchange_strong(
            expected, true, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      return false;
    }
    try {
      std::forward<Callback>(callback)();
    } catch (...) {
      // A MethodResult can throw if its engine is already closing. The claim
      // still prevents another completion path from sending a duplicate.
    }
    return true;
  }

 private:
  std::atomic<bool> replied_{false};
};

template <typename Callback>
bool RunScreenCapturePostFailureOnce(
    bool posted,
    ScreenCaptureCompletionReply& failure_claim,
    Callback&& callback) noexcept {
  if (posted) return false;
  return failure_claim.InvokeOnce(std::forward<Callback>(callback));
}

}  // namespace yixue::runner

#endif  // RUNNER_SCREEN_CAPTURE_COMPLETION_ONCE_H_
