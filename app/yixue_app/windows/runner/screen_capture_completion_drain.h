#ifndef RUNNER_SCREEN_CAPTURE_COMPLETION_DRAIN_H_
#define RUNNER_SCREEN_CAPTURE_COMPLETION_DRAIN_H_

#include <windows.h>

#include <cstddef>
#include <functional>
#include <memory>

namespace yixue::runner {

struct PendingScreenCaptureCompletion {
  std::function<void()> dispatch;
  std::function<void()> discard;
};

// Remove every completion accepted before poster shutdown and invoke its
// discard callback on the window thread. The caller must close the poster
// first, which prevents new queue entries while this drain is running.
template <typename PopMessage>
std::size_t DiscardPendingScreenCaptureCompletions(
    PopMessage&& pop_message) noexcept {
  std::size_t discarded = 0;
  LPARAM payload = 0;
  while (pop_message(&payload)) {
    std::unique_ptr<PendingScreenCaptureCompletion> pending(
        reinterpret_cast<PendingScreenCaptureCompletion*>(payload));
    if (!pending) continue;
    if (pending->discard) {
      try {
        pending->discard();
      } catch (...) {
        // Continue releasing all completions even if one discard callback
        // fails during native window teardown.
      }
    }
    ++discarded;
  }
  return discarded;
}

}  // namespace yixue::runner

#endif  // RUNNER_SCREEN_CAPTURE_COMPLETION_DRAIN_H_
