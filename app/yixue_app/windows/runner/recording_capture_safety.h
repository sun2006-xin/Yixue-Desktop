#ifndef RUNNER_RECORDING_CAPTURE_SAFETY_H_
#define RUNNER_RECORDING_CAPTURE_SAFETY_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>

// Bind a background callback to the capture instance that created it. The
// callback keeps that instance alive even if navigation replaces the current
// preview capture on the UI thread.
template <typename Owner, typename Callback>
auto BindSharedOwner(std::shared_ptr<Owner> owner, Callback callback) {
  return [owner = std::move(owner), callback = std::move(callback)](
             auto&&... args) mutable -> decltype(auto) {
    return callback(owner, std::forward<decltype(args)>(args)...);
  };
}

class RecordingFailureSignal {
 public:
  bool TrySignal() noexcept {
    bool expected = false;
    return signalled_.compare_exchange_strong(
        expected, true, std::memory_order_acq_rel,
        std::memory_order_acquire);
  }

  bool IsSignalled() const noexcept {
    return signalled_.load(std::memory_order_acquire);
  }

  void Reset() noexcept {
    signalled_.store(false, std::memory_order_release);
  }

 private:
  std::atomic<bool> signalled_{false};
};

inline bool CanReleaseCaptureForNavigation(
    bool recorder_active,
    bool recording_audio_owner_exists) noexcept {
  return !recorder_active && !recording_audio_owner_exists;
}

inline bool HasMatchingRecordingIdentity(
    const std::string& event_session_id,
    const std::string& event_attempt_id,
    const std::string& active_session_id,
    const std::string& active_attempt_id) noexcept {
  return !event_session_id.empty() && !event_attempt_id.empty() &&
         event_session_id == active_session_id &&
         event_attempt_id == active_attempt_id;
}

inline bool IsStaleRecordingFailure(
    bool is_recording_failure,
    const std::string& event_session_id,
    const std::string& event_attempt_id,
    const std::string& active_session_id,
    const std::string& active_attempt_id) noexcept {
  return is_recording_failure &&
         !HasMatchingRecordingIdentity(event_session_id, event_attempt_id,
                                       active_session_id,
                                       active_attempt_id);
}

inline bool IsStaleCaptureInstanceEvent(int64_t event_instance_id,
                                        int64_t active_instance_id) noexcept {
  return event_instance_id <= 0 || active_instance_id <= 0 ||
         event_instance_id != active_instance_id;
}

inline bool ShouldCleanupCaptureFailure(
    bool is_recording_failure,
    bool is_capture_lifecycle_failure,
    const std::string& event_session_id,
    const std::string& event_attempt_id,
    const std::string& active_session_id,
    const std::string& active_attempt_id,
    int64_t event_capture_instance_id,
    int64_t active_capture_instance_id) noexcept {
  if ((!is_recording_failure && !is_capture_lifecycle_failure) ||
      IsStaleCaptureInstanceEvent(event_capture_instance_id,
                                  active_capture_instance_id)) {
    return false;
  }
  return !is_recording_failure ||
         HasMatchingRecordingIdentity(event_session_id, event_attempt_id,
                                      active_session_id,
                                      active_attempt_id);
}

#endif  // RUNNER_RECORDING_CAPTURE_SAFETY_H_
