#ifndef RUNNER_WASAPI_LOOPBACK_CAPTURE_H_
#define RUNNER_WASAPI_LOOPBACK_CAPTURE_H_

#include <flutter/encodable_value.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "wasapi_capture_lifecycle.h"
#include "wasapi_event_callback_gate.h"
#include "wasapi_worker_completion.h"

// Captures one shared-mode WASAPI source (system loopback or a selected
// microphone endpoint) and emits owned, bounded PCM frame events. The callback
// must marshal events to Flutter's platform thread; the capture worker never
// calls an EventSink directly.
class WasapiLoopbackCapture {
 public:
  using EventCallback =
      WasapiEventCallbackGate<flutter::EncodableValue>::EventCallback;

  explicit WasapiLoopbackCapture(EventCallback event_callback);
  ~WasapiLoopbackCapture();

  WasapiLoopbackCapture(const WasapiLoopbackCapture&) = delete;
  WasapiLoopbackCapture& operator=(const WasapiLoopbackCapture&) = delete;

  bool Start(const std::string& source_id,
             const std::string& source_kind,
             const std::string& session_id,
             const std::string& capture_attempt_id,
             int64_t active_capture_offset_us,
             std::string* error_code,
             std::string* error_message);
  WasapiCaptureStopResult Stop(
      const std::string& final_status,
      std::chrono::milliseconds timeout = std::chrono::milliseconds(500));
  WasapiCaptureStopResult StopIfOwnedBySession(
      const std::string& session_id,
      const std::string& final_status,
      std::chrono::milliseconds timeout = std::chrono::milliseconds(500));
  void DisableEventCallback();

 private:
  struct CaptureIdentity {
    std::string source_id;
    std::string source_kind;
    std::string session_id;
    std::string capture_attempt_id;
    int64_t active_capture_offset_us = 0;
  };

  void CaptureWorker(CaptureIdentity identity);
  void CaptureWorkerCore(const CaptureIdentity& identity);
  WasapiCaptureStopResult StopLocked(
      const std::string& final_status,
      std::chrono::milliseconds timeout);
  bool DispatchEvent(flutter::EncodableValue event, bool is_audio_frame);
  void EmitState(const CaptureIdentity& identity,
                 const std::string& status,
                 const std::string& error_code = "");
  void EmitActiveState(const CaptureIdentity& identity,
                       uint32_t sample_rate_hz,
                       uint16_t channel_count,
                       int64_t first_sequence,
                       int64_t last_sequence,
                       int64_t first_frame_time_us);

  WasapiEventCallbackGate<flutter::EncodableValue> event_callback_gate_;
  std::mutex lifecycle_mutex_;
  std::thread worker_;
  yixue::runner::WasapiWorkerCompletion worker_completion_;
  CaptureIdentity identity_;
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> running_{false};
  std::atomic<bool> discontinuity_pending_{false};
};

void RetireWasapiLoopbackCapture(
    std::unique_ptr<WasapiLoopbackCapture> capture) noexcept;
void ReapRetiredWasapiLoopbackCaptures() noexcept;
WasapiCaptureStopResult StopAndRetireWasapiLoopbackCapture(
    std::unique_ptr<WasapiLoopbackCapture>& capture,
    const std::string& final_status,
    std::chrono::milliseconds timeout = std::chrono::milliseconds(500)) noexcept;

#endif  // RUNNER_WASAPI_LOOPBACK_CAPTURE_H_
