#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "win32_window.h"
#include "wasapi_loopback_capture.h"
#include "windows_screen_capture.h"
#include "recording_operation_worker.h"

class ScreenCaptureEventPoster;

namespace yixue::runner {
class ScreenRecordingReplyGate;
}

enum class RecordingOperationState {
  kIdle,
  kStarting,
  kRecording,
  kStopping,
};

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool subtitle_process = false,
                         bool supervised_ui = false);
  virtual ~FlutterWindow();

  // Tears down Flutter-owned channels and textures after the native message
  // loop returns, so the engine is never destroyed from inside a platform
  // channel callback that initiated window close.
  void CleanupAfterMessageLoop();

  // Some Windows media APIs and in-flight platform replies can fail to return.
  // A supervised UI leaves final termination to its parent so the user can
  // choose whether to wait for a media finalizer or force-close the process.
  bool must_exit_process_after_cleanup() const noexcept {
    return must_exit_process_after_cleanup_;
  }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RegisterSupervisorReadinessChannel();
  void RegisterMainWindowActivationChannel();
  void DispatchPendingMainWindowRestore() noexcept;
  void DispatchPendingSystemShutdown() noexcept;
  void ReleaseShutdownBlockReason() noexcept;
  void RegisterScreenCaptureChannels();
  void RegisterSubtitleWindowChannel();
  void HandleScreenCaptureMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StartRecordingAsync(
      std::wstring output_path,
      std::string session_id,
      std::string capture_attempt_id,
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopRecordingAsync(
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      bool stop_capture);
  yixue::runner::RecordingWorkerWaitResult JoinRecordingOperationWorker(
      bool wait_for_shutdown = false,
      bool detach_on_timeout = true) noexcept;
  void ShutdownScreenCapture();

  // The project to run.
  flutter::DartProject project_;
  const bool subtitle_process_;
  const bool supervised_ui_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      screen_capture_method_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      supervisor_method_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      main_window_activation_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      screen_capture_event_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      subtitle_window_method_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      screen_capture_event_sink_;
  std::shared_ptr<ScreenCaptureEventPoster> screen_capture_event_poster_;
  std::shared_ptr<yixue::runner::ScreenRecordingReplyGate>
      screen_recording_reply_gate_;
  std::shared_ptr<WindowsScreenCapture> screen_capture_;
  // Keep captures replaced during navigation so shutdown can wait for their
  // asynchronous texture-unregistration callbacks before destroying the engine.
  std::vector<std::shared_ptr<WindowsScreenCapture>>
      retired_screen_captures_;
  std::unique_ptr<WasapiLoopbackCapture> recording_audio_capture_;
  std::string recording_session_id_;
  std::string recording_capture_attempt_id_;
  yixue::runner::RecordingOperationWorker recording_operation_worker_;
  // Native post-failure callbacks can run on the recording worker. Protect the
  // operation state and deferred stop request shared with the window thread.
  std::mutex recording_operation_state_mutex_;
  RecordingOperationState recording_operation_state_ =
      RecordingOperationState::kIdle;
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>
      pending_recording_stop_result_;
  bool pending_recording_stop_capture_ = false;
  bool recording_failure_pending_ = false;
  bool recording_failure_stops_capture_ = false;
  int64_t next_screen_capture_instance_id_ = 1;
  int64_t screen_capture_instance_id_ = 0;
  std::atomic<bool> screen_capture_shutdown_{false};
  bool subtitle_window_placed_ = false;
  bool restore_main_window_handler_ready_ = false;
  bool restore_main_window_pending_ = false;
  bool system_shutdown_pending_ = false;
  bool system_shutdown_has_extended_grace_ = false;
  bool shutdown_block_reason_registered_ = false;
  bool cleanup_started_ = false;
  bool must_exit_process_after_cleanup_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
