#ifndef RUNNER_WASAPI_CAPTURE_LIFECYCLE_H_
#define RUNNER_WASAPI_CAPTURE_LIFECYCLE_H_

#include <chrono>
#include <memory>
#include <string>
#include <utility>

enum class WasapiCaptureStopResult {
  kStopped,
  kPending,
  kNotOwned,
};

namespace yixue::runner {

// A timed-out capture must keep owning its worker. Callers transfer pending
// captures to a process-lifetime owner instead of destroying them and turning
// a bounded Stop into an unbounded destructor wait.
template <typename Capture, typename Retirer>
WasapiCaptureStopResult StopOrRetireWasapiCapture(
    std::unique_ptr<Capture>& capture,
    const std::string& final_status,
    std::chrono::milliseconds timeout,
    Retirer&& retire) {
  if (!capture) return WasapiCaptureStopResult::kStopped;

  const auto result = capture->Stop(final_status, timeout);
  if (result == WasapiCaptureStopResult::kPending) {
    std::forward<Retirer>(retire)(std::move(capture));
  } else if (result == WasapiCaptureStopResult::kStopped) {
    capture.reset();
  }
  return result;
}

}  // namespace yixue::runner

#endif  // RUNNER_WASAPI_CAPTURE_LIFECYCLE_H_
