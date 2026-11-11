#include "flutter_window.h"
#include "screen_recording_operation_queue.h"
#include "supervisor_diagnostics.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter_plugin_registrar.h>
#include <flutter/standard_method_codec.h>

#include <filesystem>
#include <algorithm>
#include <chrono>
#include <exception>
#include <functional>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <thread>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "screenshot_window_activation_plugin.h"
#include "screenshot_translation_native_orb_plugin.h"
#include "recording_capture_safety.h"
#include "screen_capture_completion_drain.h"
#include "screen_capture_completion_once.h"
#include "native_method_exception_boundary.h"
#include "supervised_process_lifecycle.h"
#include "wasapi_audio_capture_plugin.h"
#include "windows_screen_recording_plugin.h"

namespace {

constexpr UINT kScreenCaptureEventMessage = WM_APP + 42;
constexpr UINT kScreenCaptureCompletionMessage = WM_APP + 43;
constexpr char kScreenCaptureMethodChannelName[] =
    "com.yixue.yixue_app/ai_tongchuan/screen_capture";
constexpr char kScreenCaptureEventChannelName[] =
    "com.yixue.yixue_app/ai_tongchuan/screen_capture_events";
constexpr char kSubtitleWindowMethodChannelName[] =
    "com.yixue.yixue_app/subtitle_window/native";
constexpr char kSupervisorMethodChannelName[] =
    "com.yixue.yixue_app/supervisor";
constexpr char kMainWindowActivationMethodChannelName[] =
    "com.yixue.yixue_app/window_activation";
constexpr char kSystemOutputSourceId[] = "windows-system-output";

struct PendingScreenCaptureEvent {
  flutter::EncodableValue event;
};

struct RecordingStartOperation {
  bool succeeded = false;
  std::unique_ptr<WasapiLoopbackCapture> audio_capture;
  yixue::runner::ScreenCaptureCompletionReply start_reply;
  yixue::runner::ScreenCaptureCompletionReply pending_stop_reply;
  yixue::runner::ScreenCaptureCompletionReply post_failure;
  std::string error_code;
  std::string error_message;
};

struct RecordingStopOperation {
  bool succeeded = false;
  bool audio_finalized = true;
  std::unique_ptr<WasapiLoopbackCapture> audio_capture;
  std::string output_path;
  std::string error_code;
  std::string error_message;
  yixue::runner::ScreenCaptureCompletionReply stop_reply;
  yixue::runner::ScreenCaptureCompletionReply post_failure;
};

const flutter::EncodableValue* FindValue(
    const flutter::EncodableMap& map,
    const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

bool ReadString(const flutter::EncodableMap& map,
                const char* key,
                std::string* value) {
  const auto* encoded = FindValue(map, key);
  if (encoded == nullptr || !std::holds_alternative<std::string>(*encoded)) {
    return false;
  }
  *value = std::get<std::string>(*encoded);
  return !value->empty();
}

void AddString(flutter::EncodableMap* map,
               const char* key,
               const std::string& value) {
  map->emplace(flutter::EncodableValue(key), flutter::EncodableValue(value));
}

void AddInt(flutter::EncodableMap* map, const char* key, int64_t value) {
  map->emplace(flutter::EncodableValue(key), flutter::EncodableValue(value));
}

void AddCaptureInstanceId(flutter::EncodableValue* event, int64_t instance_id) {
  if (event == nullptr) return;
  auto* map = std::get_if<flutter::EncodableMap>(event);
  if (map != nullptr) AddInt(map, "captureInstanceId", instance_id);
}

void DiscardQueuedScreenCaptureMessages(HWND hwnd) noexcept {
  if (hwnd == nullptr) return;

  MSG pending_message = {};
  while (::PeekMessageW(&pending_message, hwnd, kScreenCaptureEventMessage,
                        kScreenCaptureEventMessage, PM_REMOVE)) {
    delete reinterpret_cast<PendingScreenCaptureEvent*>(
        pending_message.lParam);
  }
  static_cast<void>(yixue::runner::DiscardPendingScreenCaptureCompletions(
      [hwnd](LPARAM* payload) {
        MSG message = {};
        if (!::PeekMessageW(&message, hwnd, kScreenCaptureCompletionMessage,
                            kScreenCaptureCompletionMessage, PM_REMOVE)) {
          return false;
        }
        *payload = message.lParam;
        return true;
      }));
}

void PumpPendingThreadMessages() noexcept {
  MSG message = {};
  while (::PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    if (message.message == WM_QUIT) continue;
    ::TranslateMessage(&message);
    ::DispatchMessageW(&message);
  }
}

}  // namespace

// Capture callbacks can outlive FlutterWindow while an asynchronous texture
// unregister is pending. The poster owns only an HWND and a close gate; queued
// UI completions that capture FlutterWindow are drained before destruction.
class ScreenCaptureEventPoster final {
 public:
  explicit ScreenCaptureEventPoster(HWND hwnd) : hwnd_(hwnd) {}

  bool Post(flutter::EncodableValue event) noexcept {
    std::unique_ptr<PendingScreenCaptureEvent> pending;
    try {
      pending.reset(
          new (std::nothrow) PendingScreenCaptureEvent{std::move(event)});
    } catch (...) {
      return false;
    }
    if (!pending) return false;

    try {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!accepting_.load(std::memory_order_acquire) || hwnd_ == nullptr) {
        return false;
      }
      // Transfer ownership before publishing the message. The UI thread can
      // dequeue it as soon as PostMessage succeeds, before this worker resumes.
      auto* posted = pending.release();
      if (!PostMessage(hwnd_, kScreenCaptureEventMessage, 0,
                       reinterpret_cast<LPARAM>(posted))) {
        pending.reset(posted);
        return false;
      }
      return true;
    } catch (...) {
      return false;
    }
  }

  bool PostCompletion(std::function<void()> dispatch,
                      std::function<void()> discard) noexcept {
    std::unique_ptr<yixue::runner::PendingScreenCaptureCompletion> pending;
    try {
      pending = std::make_unique<
          yixue::runner::PendingScreenCaptureCompletion>(
          yixue::runner::PendingScreenCaptureCompletion{
              std::move(dispatch), std::move(discard)});
    } catch (...) {
      return false;
    }
    try {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!accepting_.load(std::memory_order_acquire) || hwnd_ == nullptr) {
        return false;
      }
      // A posted completion may be drained by the UI thread before
      // PostMessage returns to this worker.
      auto* queued = pending.release();
      if (!PostMessage(hwnd_, kScreenCaptureCompletionMessage, 0,
                       reinterpret_cast<LPARAM>(queued))) {
        pending.reset(queued);
        return false;
      }
      return true;
    } catch (...) {
      return false;
    }
  }

  void Close() noexcept {
    accepting_.store(false, std::memory_order_release);
    try {
      std::lock_guard<std::mutex> lock(mutex_);
      hwnd_ = nullptr;
    } catch (...) {
      // The event poster is also used from native teardown paths.
    }
  }

 private:
  std::mutex mutex_;
  HWND hwnd_ = nullptr;
  std::atomic<bool> accepting_{true};
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool subtitle_process,
                             bool supervised_ui)
    : project_(project),
      subtitle_process_(subtitle_process),
      supervised_ui_(supervised_ui) {}

FlutterWindow::~FlutterWindow() { CleanupAfterMessageLoop(); }

bool FlutterWindow::OnCreate() {
  const char* failure_phase = "base_window";
  try {
    if (!Win32Window::OnCreate()) {
      return false;
    }
    failure_phase = "screen_capture_event_poster";
    screen_capture_event_poster_ =
        std::make_shared<ScreenCaptureEventPoster>(GetHandle());
    screen_capture_shutdown_.store(false);

    RECT frame = GetClientArea();

    // The size here must match the window dimensions to avoid unnecessary
    // surface creation / destruction in the startup path.
    failure_phase = "flutter_controller";
    flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
        frame.right - frame.left, frame.bottom - frame.top, project_);
    // Ensure that basic setup of the controller was successful.
    if (!flutter_controller_->engine() || !flutter_controller_->view()) {
      return false;
    }

    failure_phase = "generated_plugin_registration";
    RegisterPlugins(flutter_controller_->engine());
    if (subtitle_process_) {
      failure_phase = "subtitle_channel_registration";
      RegisterSubtitleWindowChannel();
    } else {
      failure_phase = "supervisor_channel_registration";
      RegisterSupervisorReadinessChannel();
      failure_phase = "main_window_activation_channel_registration";
      RegisterMainWindowActivationChannel();
      failure_phase = "audio_capture_plugin_registration";
      RegisterWasapiAudioCapturePlugin(flutter_controller_->engine());
      failure_phase = "screen_recording_plugin_registration";
      screen_recording_reply_gate_ =
          std::make_shared<yixue::runner::ScreenRecordingReplyGate>();
      RegisterWindowsScreenRecordingPlugin(flutter_controller_->engine(),
                                           GetHandle(),
                                           screen_recording_reply_gate_);
      failure_phase = "screen_capture_channel_registration";
      RegisterScreenCaptureChannels();
      failure_phase = "screenshot_orb_plugin_registration";
      RegisterScreenshotTranslationNativeOrbPlugin(
          flutter_controller_->engine());
    }
    failure_phase = "multi_window_callback_registration";
    if (subtitle_process_) {
      DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
        auto* flutter_view_controller =
            reinterpret_cast<flutter::FlutterViewController*>(controller);
        RegisterPlugins(flutter_view_controller->engine());
      });
    } else {
      DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
        auto* flutter_view_controller =
            reinterpret_cast<flutter::FlutterViewController*>(controller);
        RegisterPlugins(flutter_view_controller->engine());
        RegisterScreenshotChildWindowActivationPlugin(
            flutter_view_controller->engine());
      });
    }
    failure_phase = "attach_flutter_view";
    SetChildContent(flutter_controller_->view()->GetNativeWindow());

    // Request a rasterized Flutter frame while keeping window visibility under
    // Dart's first-frame presentation gate. The native runner must not expose
    // the empty surface before the app has painted its loading or error state.
    failure_phase = "first_frame_request";
    flutter_controller_->ForceRedraw();

    return true;
  } catch (const std::bad_alloc&) {
    yixue::runner::diagnostics::LogText(
        "flutter_window_create_failure_phase", failure_phase);
    yixue::runner::diagnostics::Log(
        "flutter_window_create_allocation_failed", ERROR_NOT_ENOUGH_MEMORY);
  } catch (const std::exception&) {
    yixue::runner::diagnostics::LogText(
        "flutter_window_create_failure_phase", failure_phase);
    yixue::runner::diagnostics::Log("flutter_window_create_exception",
                                    ERROR_GEN_FAILURE);
  } catch (...) {
    yixue::runner::diagnostics::LogText(
        "flutter_window_create_failure_phase", failure_phase);
    yixue::runner::diagnostics::Log(
        "flutter_window_create_unknown_exception", ERROR_GEN_FAILURE);
  }

  // Tear down any partially registered channels/plugins while still inside a
  // controlled startup failure path; the destructor remains idempotent.
  try {
    CleanupAfterMessageLoop();
  } catch (...) {
    // Startup remains failed; the owning process performs its normal exit.
  }
  return false;
}

void FlutterWindow::OnDestroy() {
  // The window may be destroyed synchronously inside window_manager's close
  // method-channel callback. Only block new capture calls here; destroying the
  // Flutter controller from that callback re-enters the engine and can crash
  // flutter_windows.dll. Full teardown runs after GetMessage returns.
  screen_capture_shutdown_.store(true);
  if (screen_capture_event_poster_) screen_capture_event_poster_->Close();
  DiscardQueuedScreenCaptureMessages(GetHandle());
  ReleaseShutdownBlockReason();
  Win32Window::OnDestroy();
}

void FlutterWindow::CleanupAfterMessageLoop() {
  if (cleanup_started_) return;
  cleanup_started_ = true;
  if (!subtitle_process_) {
    yixue::runner::diagnostics::Log("main_cleanup_begin");
  }
  yixue::runner::SignalParentSupervisorCloseRequest();
  screen_capture_shutdown_.store(true);
  if (screen_capture_event_poster_) screen_capture_event_poster_->Close();
  // Close serializes with PostMessage. Drain completions accepted before the
  // close gate while this window is still alive; after the drain, no queued
  // callback that captures FlutterWindow can run during detached cleanup.
  DiscardQueuedScreenCaptureMessages(GetHandle());
  if (screen_recording_reply_gate_) {
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log(
          "main_cleanup_recording_replies_drain_begin");
    }
    screen_recording_reply_gate_->Close();
    // Flutter's Windows messenger and task runner use the UI thread. Keep
    // servicing queued platform messages while draining an already-started
    // native reply so shutdown cannot deadlock after GetMessage returned.
    auto reply_drain_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!screen_recording_reply_gate_->WaitForDrainFor(
        std::chrono::milliseconds(20))) {
      PumpPendingThreadMessages();
      if (std::chrono::steady_clock::now() >= reply_drain_deadline) {
        if (!subtitle_process_) {
          yixue::runner::diagnostics::Log(
              "main_cleanup_recording_replies_drain_timed_out",
              ERROR_TIMEOUT);
        }
        if (!supervised_ui_) {
          must_exit_process_after_cleanup_ = true;
          return;
        }
        // Keep the parent supervisor alive to enforce its 60-second user
        // decision. Continue pumping replies; an active native operation may
        // still be completing a recording response.
        reply_drain_deadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(10);
      }
    }
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log(
          "main_cleanup_recording_replies_drain_end");
    }
  }
  if (!subtitle_process_) {
    yixue::runner::diagnostics::Log("main_cleanup_channels_begin");
  }
  try {
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log("main_cleanup_screen_capture_begin");
    }
    auto worker_shutdown =
        JoinRecordingOperationWorker(true, !supervised_ui_);
    const auto worker_is_still_running = [](auto result) {
      return result ==
                 yixue::runner::RecordingWorkerWaitResult::kTimedOutRetained ||
             result ==
                 yixue::runner::RecordingWorkerWaitResult::kWaitFailedRetained;
    };
    auto next_worker_wait_log =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (supervised_ui_ && worker_is_still_running(worker_shutdown)) {
      if (!subtitle_process_ &&
          std::chrono::steady_clock::now() >= next_worker_wait_log) {
        yixue::runner::diagnostics::Log(
            "main_cleanup_recording_worker_still_running", ERROR_TIMEOUT);
        next_worker_wait_log =
            std::chrono::steady_clock::now() + std::chrono::seconds(10);
      }
      // Retain the std::thread handle in the supervised child. If the media
      // finalizer finishes, join it and continue normal cleanup; if not, the
      // parent prompts the user and can terminate this process tree.
      worker_shutdown = JoinRecordingOperationWorker(true, false);
    }
    const bool recording_worker_abandoned =
        worker_shutdown ==
            yixue::runner::RecordingWorkerWaitResult::kTimedOutDetached ||
        worker_shutdown ==
            yixue::runner::RecordingWorkerWaitResult::kWaitFailedDetached;
    if (recording_worker_abandoned) {
      if (!subtitle_process_) {
        yixue::runner::diagnostics::Log(
            "main_cleanup_recording_worker_abandoned");
      }
      // Do not unwind FlutterWindow here: its screen-capture and Flutter
      // members may still be referenced by the detached operation. The runner
      // will terminate this already-closing process without destructing them.
      must_exit_process_after_cleanup_ = true;
      return;
    } else {
      ShutdownScreenCapture();
    }
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log("main_cleanup_screen_capture_end");
    }
  } catch (...) {
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log("main_cleanup_screen_capture_exception");
    }
    // The native owner may still be active. Do not destroy the Flutter
    // controller, texture registrar, or capture state after a failed stop.
    must_exit_process_after_cleanup_ = true;
    return;
  }

  if (screen_capture_method_channel_) {
    try {
      screen_capture_method_channel_->SetMethodCallHandler(nullptr);
    } catch (...) {
      // The channel wrapper is still released before its borrowed messenger.
    }
    // Channels borrow the engine messenger, so release them before the
    // controller (and its messenger) is destroyed. Keeping these wrappers
    // alive past controller teardown leaves a stale messenger pointer during
    // repeated native window cleanup.
    screen_capture_method_channel_.reset();
  }
  if (supervisor_method_channel_) {
    try {
      supervisor_method_channel_->SetMethodCallHandler(nullptr);
    } catch (...) {
      // Release the wrapper before its engine messenger even if detaching the
      // handler reports a channel teardown error.
    }
    supervisor_method_channel_.reset();
  }
  if (main_window_activation_channel_) {
    try {
      main_window_activation_channel_->SetMethodCallHandler(nullptr);
    } catch (...) {
      // Release the wrapper before its engine messenger.
    }
    main_window_activation_channel_.reset();
  }
  if (subtitle_window_method_channel_) {
    try {
      subtitle_window_method_channel_->SetMethodCallHandler(nullptr);
    } catch (...) {
      // Continue releasing the channel before the engine.
    }
    subtitle_window_method_channel_.reset();
  }
  if (screen_capture_event_channel_) {
    try {
      screen_capture_event_channel_->SetStreamHandler(nullptr);
    } catch (...) {
      // Continue releasing the channel before the engine.
    }
    screen_capture_event_channel_.reset();
  }
  screen_capture_event_sink_.reset();
  if (!subtitle_process_) {
    yixue::runner::diagnostics::Log("main_cleanup_channels_end");
    yixue::runner::diagnostics::Log("main_cleanup_flutter_controller_begin");
  }

  if (flutter_controller_) {
    flutter_controller_.reset();
  }
  if (!subtitle_process_) {
    yixue::runner::diagnostics::Log("main_cleanup_flutter_controller_end");
    yixue::runner::diagnostics::Log("main_cleanup_base_window_begin");
  }

  try {
    Win32Window::OnDestroy();
  } catch (...) {
    // Destruction must remain best-effort and non-throwing.
  }
  if (!subtitle_process_) {
    yixue::runner::diagnostics::Log("main_cleanup_base_window_end");
  }
}

void FlutterWindow::RegisterScreenCaptureChannels() {
  auto* engine = flutter_controller_->engine();
  auto* registrar = engine->GetRegistrarForPlugin("YixueWindowsScreenCapture");
  auto* texture_registrar =
      FlutterDesktopRegistrarGetTextureRegistrar(registrar);
  screen_capture_instance_id_ = next_screen_capture_instance_id_++;
  const int64_t capture_instance_id = screen_capture_instance_id_;
  const auto event_poster = screen_capture_event_poster_;
  screen_capture_ = std::make_shared<WindowsScreenCapture>(
      GetHandle(), texture_registrar,
      [event_poster, capture_instance_id](flutter::EncodableValue event) {
        AddCaptureInstanceId(&event, capture_instance_id);
        return event_poster && event_poster->Post(std::move(event));
      });
  // A new poster and native capture owner belong to this HWND lifecycle.
  screen_capture_shutdown_.store(false);

  auto* messenger = engine->messenger();
  screen_capture_method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kScreenCaptureMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  screen_capture_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, kScreenCaptureEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  screen_capture_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>
            shared_result;
        try {
          // Creating the shared ownership control block can allocate. Keep it
          // inside the exception boundary so an allocation failure cannot
          // escape a Flutter method-channel callback.
          shared_result = std::shared_ptr<
              flutter::MethodResult<flutter::EncodableValue>>(
              std::move(result));
          HandleScreenCaptureMethod(call, shared_result);
        } catch (const std::exception& error) {
          try {
            if (shared_result) {
              shared_result->Error("nativeOperationFailed", error.what());
            } else if (result) {
              result->Error("nativeOperationFailed", error.what());
            }
          } catch (...) {
            // Error reporting is best-effort; never unwind into the engine.
          }
        } catch (...) {
          try {
            if (shared_result) {
              shared_result->Error("nativeOperationFailed",
                                   "Windows 桌面采集操作未能完成。");
            } else if (result) {
              result->Error("nativeOperationFailed",
                            "Windows 桌面采集操作未能完成。");
            }
          } catch (...) {
            // Error reporting is best-effort; never unwind into the engine.
          }
        }
      });

  auto on_listen =
      [this](const flutter::EncodableValue*,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                 events)
          -> std::unique_ptr<flutter::StreamHandlerError<
              flutter::EncodableValue>> {
    screen_capture_event_sink_ = std::move(events);
    return nullptr;
  };
  auto on_cancel = [this](const flutter::EncodableValue*)
      -> std::unique_ptr<flutter::StreamHandlerError<
          flutter::EncodableValue>> {
    screen_capture_event_sink_.reset();
    return nullptr;
  };
  screen_capture_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<
          flutter::EncodableValue>>(std::move(on_listen), std::move(on_cancel)));
}

void FlutterWindow::RegisterSubtitleWindowChannel() {
  subtitle_window_method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          kSubtitleWindowMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  subtitle_window_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        yixue::runner::RunNativeOperationSafely(
            [&] {
              const HWND window = GetHandle();
              if (window == nullptr || !IsWindow(window)) {
                result->Error("windowUnavailable", "字幕窗口已关闭。");
                return;
              }
              if (call.method_name() == "showNoActivate") {
                if (!subtitle_window_placed_) {
                  MONITORINFO monitor_info{};
                  monitor_info.cbSize = sizeof(monitor_info);
                  const HMONITOR monitor =
                      MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
                  if (monitor == nullptr ||
                      !GetMonitorInfoW(monitor, &monitor_info)) {
                    result->Error("monitorUnavailable",
                                  "无法确定字幕窗口显示位置。");
                    return;
                  }

                  const RECT area = monitor_info.rcWork;
                  const int area_width = area.right - area.left;
                  const int area_height = area.bottom - area.top;
                  const int width =
                      (std::min)(1000, (std::max)(720, area_width - 48));
                  const int height =
                      (std::min)(180, (std::max)(132, area_height - 48));
                  const int x = area.left + (area_width - width) / 2;
                  const int y = area.bottom - height - 24;
                  if (!SetWindowPos(window, HWND_TOPMOST, x, y, width, height,
                                    SWP_NOACTIVATE | SWP_SHOWWINDOW)) {
                    result->Error("windowShowFailed", "无法显示字幕窗口。");
                    return;
                  }
                  subtitle_window_placed_ = true;
                } else if (!SetWindowPos(
                               window, HWND_TOPMOST, 0, 0, 0, 0,
                               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                                   SWP_SHOWWINDOW)) {
                  result->Error("windowShowFailed", "无法显示字幕窗口。");
                  return;
                }
                ShowWindow(window, SW_SHOWNOACTIVATE);
                result->Success(flutter::EncodableValue(true));
                return;
              }
              if (call.method_name() == "hide") {
                ShowWindow(window, SW_HIDE);
                result->Success(flutter::EncodableValue(true));
                return;
              }
              result->NotImplemented();
            },
            [&](std::exception_ptr) {
              try {
                if (result) {
                  result->Error("nativeOperationFailed",
                                "字幕窗口操作未能完成。");
                }
              } catch (...) {
                // Error reporting is best-effort; never unwind into the engine.
              }
            });
      });
}

void FlutterWindow::RegisterSupervisorReadinessChannel() {
  supervisor_method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          kSupervisorMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  supervisor_method_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        yixue::runner::RunNativeOperationSafely(
            [&] {
              if (call.method_name() == "signalUiCleanupWatchdogStart") {
                // Dart sends this only after exit cleanup has succeeded and
                // the user can no longer cancel the close. Wake the supervisor
                // now so its user-confirmed timeout covers native teardown too.
                yixue::runner::SignalParentSupervisorCloseRequest();
                // Direct launches still need a local fallback watchdog. A
                // supervised UI leaves timeout decisions to its parent.
                yixue::runner::SignalUiCleanupWatchdogStart();
                result->Success();
                return;
              }
              if (call.method_name() != "signalAppReady") {
                result->NotImplemented();
                return;
              }
              if (!yixue::runner::SignalParentSupervisorAppReady()) {
                result->Error("supervisorReadinessSignalFailed",
                              "Windows 未接受译学启动就绪信号。");
                return;
              }
              result->Success();
            },
            [&](std::exception_ptr) {
              try {
                if (result) {
                  result->Error("nativeOperationFailed",
                                "Windows 启动监督信号处理失败。");
                }
              } catch (...) {
                // Error reporting is best-effort; never unwind into the engine.
              }
            });
      });
}

void FlutterWindow::RegisterMainWindowActivationChannel() {
  main_window_activation_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          kMainWindowActivationMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  main_window_activation_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        yixue::runner::RunNativeOperationSafely(
            [&] {
              if (call.method_name() != "ready") {
                result->NotImplemented();
                return;
              }
              restore_main_window_handler_ready_ = true;
              result->Success(flutter::EncodableValue(true));
              DispatchPendingMainWindowRestore();
              DispatchPendingSystemShutdown();
            },
            [&](std::exception_ptr) {
              try {
                if (result) {
                  result->Error("nativeOperationFailed",
                                "Windows 窗口恢复通知未能完成。");
                }
              } catch (...) {
                // Never unwind through Flutter's method-channel callback.
              }
            });
      });
}

void FlutterWindow::DispatchPendingMainWindowRestore() noexcept {
  if (!restore_main_window_pending_ ||
      !restore_main_window_handler_ready_ ||
      !main_window_activation_channel_) {
    return;
  }
  try {
    main_window_activation_channel_->InvokeMethod(
        "restoreMainWindow", std::make_unique<flutter::EncodableValue>());
    restore_main_window_pending_ = false;
  } catch (...) {
    yixue::runner::diagnostics::Log(
        "single_instance_restore_request_dispatch_failed",
        ERROR_GEN_FAILURE);
  }
}

void FlutterWindow::DispatchPendingSystemShutdown() noexcept {
  if (!system_shutdown_pending_ ||
      !restore_main_window_handler_ready_ ||
      !main_window_activation_channel_) {
    return;
  }
  try {
    main_window_activation_channel_->InvokeMethod(
        "systemShutdown",
        std::make_unique<flutter::EncodableValue>(
            system_shutdown_has_extended_grace_));
    system_shutdown_pending_ = false;
    yixue::runner::diagnostics::Log("main_system_shutdown_cleanup_requested");
  } catch (...) {
    yixue::runner::diagnostics::Log(
        "main_system_shutdown_cleanup_dispatch_failed", ERROR_GEN_FAILURE);
  }
}

void FlutterWindow::ReleaseShutdownBlockReason() noexcept {
  if (!shutdown_block_reason_registered_) return;
  shutdown_block_reason_registered_ = false;
  if (::ShutdownBlockReasonDestroy(GetHandle())) {
    yixue::runner::diagnostics::Log(
        "main_shutdown_block_reason_released");
  } else {
    yixue::runner::diagnostics::Log(
        "main_shutdown_block_reason_release_failed", ::GetLastError());
  }
}

void FlutterWindow::HandleScreenCaptureMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!screen_capture_ || screen_capture_shutdown_.load()) {
    if (!screen_capture_) {
      result->Error("captureNotInitialized",
                    "Windows 桌面画面采集对象尚未创建。");
    } else {
      result->Error("captureShuttingDown",
                    "Windows 桌面画面采集组件正在关闭。");
    }
    return;
  }
  const auto& method = call.method_name();
  if (method == "isSupported") {
    result->Success(flutter::EncodableValue(screen_capture_->IsSupported()));
    return;
  }
  if (method == "selectSource") {
    bool recording_operation_active = false;
    {
      std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
      recording_operation_active =
          recording_operation_state_ != RecordingOperationState::kIdle;
    }
    if (recording_operation_active || screen_capture_->IsRecording()) {
      result->Error("recordingActive", "请先停止当前录制，再更换画面来源。");
      return;
    }
    const int64_t capture_instance_id = screen_capture_instance_id_;
    const auto reply_gate = screen_recording_reply_gate_;
    screen_capture_->SelectSourceAsync(
        [reply_gate, result, capture_instance_id](
            std::optional<flutter::EncodableValue> value,
            const std::string& error_code,
            const std::string& error_message) {
          if (!reply_gate || !result) return;
          reply_gate->InvokeIfOpen([&] {
            if (value.has_value()) {
              if (auto* map = std::get_if<flutter::EncodableMap>(&*value)) {
                AddInt(map, "captureInstanceId", capture_instance_id);
              }
              result->Success(std::move(*value));
            } else {
              result->Error(error_code.empty() ? "captureFailed" : error_code,
                            error_message);
            }
          });
        });
    return;
  }
  if (method == "startRecording") {
    bool recording_operation_active = false;
    {
      std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
      recording_operation_active =
          recording_operation_state_ != RecordingOperationState::kIdle;
    }
    if (recording_operation_active || recording_audio_capture_ ||
        screen_capture_->IsRecording()) {
      result->Error("recordingCleanupPending",
                    "上一次录屏仍在清理，请稍后重试。");
      return;
    }
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    std::string output_path;
    std::string session_id;
    std::string capture_attempt_id;
    if (arguments == nullptr ||
        !ReadString(*arguments, "outputPath", &output_path) ||
        !ReadString(*arguments, "sessionId", &session_id) ||
        !ReadString(*arguments, "captureAttemptId", &capture_attempt_id)) {
      result->Error("invalidArguments",
                    "startRecording 需要 outputPath、sessionId 和 captureAttemptId。");
      return;
    }
    std::string error_code;
    std::string error_message;
    std::wstring native_path;
    try {
      native_path = std::filesystem::u8path(output_path).wstring();
    } catch (const std::filesystem::filesystem_error&) {
      result->Error("invalidOutputPath", "无法解析本机录屏保存路径。");
      return;
    }
    StartRecordingAsync(std::move(native_path), std::move(session_id),
                        std::move(capture_attempt_id), std::move(result));
    return;
  }
  if (method == "stopRecording") {
    StopRecordingAsync(std::move(result), false);
    return;
  }
  if (method == "stopCapture") {
    StopRecordingAsync(std::move(result), true);
    return;
  }
  if (method == "releasePreviewForNavigation") {
    bool recording_operation_active = false;
    {
      std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
      recording_operation_active =
          recording_operation_state_ != RecordingOperationState::kIdle;
    }
    if (!CanReleaseCaptureForNavigation(
            (screen_capture_ && screen_capture_->IsRecording()) ||
                recording_operation_active,
            recording_audio_capture_ != nullptr)) {
      result->Error("recordingActive", "请先停止录屏，再打开字幕历史。");
      return;
    }
    try {
      auto* engine = flutter_controller_->engine();
      auto* registrar = engine->GetRegistrarForPlugin("YixueWindowsScreenCapture");
      auto* texture_registrar =
          FlutterDesktopRegistrarGetTextureRegistrar(registrar);
      const int64_t replacement_capture_instance_id =
          next_screen_capture_instance_id_++;
      const auto event_poster = screen_capture_event_poster_;
      auto replacement = std::make_shared<WindowsScreenCapture>(
          GetHandle(), texture_registrar,
          [event_poster, replacement_capture_instance_id](
              flutter::EncodableValue event) {
            AddCaptureInstanceId(&event, replacement_capture_instance_id);
            return event_poster && event_poster->Post(std::move(event));
          });
      retired_screen_captures_.erase(
          std::remove_if(retired_screen_captures_.begin(),
                         retired_screen_captures_.end(),
                         [](const auto& capture) {
                           return !capture || capture->IsShutdownComplete();
                         }),
          retired_screen_captures_.end());
      // Retain the old owner before starting asynchronous shutdown. If vector
      // growth fails, the current capture remains usable and the route can retry.
      retired_screen_captures_.push_back(screen_capture_);
      // The texture registrar completes unregistration asynchronously. Keep
      // the old capture owner alive until its raster callback releases it,
      // rather than blocking Flutter's UI thread on that callback.
      retired_screen_captures_.back()->ShutdownForNavigation();
      screen_capture_ = std::move(replacement);
      screen_capture_instance_id_ = replacement_capture_instance_id;
      result->Success();
    } catch (const std::exception& error) {
      result->Error("previewReleaseFailed", error.what());
    } catch (...) {
      result->Error("previewReleaseFailed", "无法重置桌面画面预览。");
    }
    return;
  }
  if (method == "isPreviewReleaseComplete") {
    const bool complete = std::all_of(
        retired_screen_captures_.begin(), retired_screen_captures_.end(),
        [](const auto& capture) {
          return !capture || capture->IsShutdownComplete();
        });
    if (complete) {
      retired_screen_captures_.erase(
          std::remove_if(retired_screen_captures_.begin(),
                         retired_screen_captures_.end(),
                         [](const auto& capture) {
                           return !capture || capture->IsShutdownComplete();
                         }),
          retired_screen_captures_.end());
    }
    result->Success(flutter::EncodableValue(complete));
    return;
  }
  result->NotImplemented();
}

yixue::runner::RecordingWorkerWaitResult
FlutterWindow::JoinRecordingOperationWorker(bool wait_for_shutdown,
                                            bool detach_on_timeout) noexcept {
  if (!wait_for_shutdown) {
    return recording_operation_worker_.TryJoinIfComplete();
  }
  const auto result = recording_operation_worker_.WaitForShutdownFor(
      std::chrono::seconds(2), detach_on_timeout);
  if (result == yixue::runner::RecordingWorkerWaitResult::kWaitFailedDetached &&
      !subtitle_process_) {
    yixue::runner::diagnostics::Log(
        "main_cleanup_recording_worker_wait_failed", ::GetLastError());
  }
  return result;
}

void FlutterWindow::StartRecordingAsync(
    std::wstring output_path,
    std::string session_id,
    std::string capture_attempt_id,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  static_cast<void>(JoinRecordingOperationWorker());
  bool recording_operation_active = false;
  {
    std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
    recording_operation_active =
        recording_operation_state_ != RecordingOperationState::kIdle;
  }
  if (recording_operation_worker_.joinable() || recording_operation_active) {
    result->Error("recordingCleanupPending",
                  "上一次录屏仍在清理，请稍后重试。");
    return;
  }

  std::shared_ptr<RecordingStartOperation> operation;
  try {
    operation = std::make_shared<RecordingStartOperation>();
  } catch (...) {
    result->Error("recordingStartFailed", "录屏初始化内存不足，请重试。");
    return;
  }
  const auto capture = screen_capture_;
  const auto completion_poster = screen_capture_event_poster_;
  const auto capture_event_poster = screen_capture_event_poster_;
  const auto reply_gate = screen_recording_reply_gate_;
  const auto capture_instance_id = screen_capture_instance_id_;
  {
    std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
    recording_operation_state_ = RecordingOperationState::kStarting;
    recording_session_id_ = session_id;
    recording_capture_attempt_id_ = capture_attempt_id;
    pending_recording_stop_result_.reset();
    pending_recording_stop_capture_ = false;
    recording_failure_pending_ = false;
    recording_failure_stops_capture_ = false;
  }

  try {
    recording_operation_worker_.Start(
        [window = this, capture, completion_poster, capture_event_poster,
         reply_gate, capture_instance_id, output_path = std::move(output_path),
         session_id = std::move(session_id),
         capture_attempt_id = std::move(capture_attempt_id), result,
         operation]() mutable {
          bool partial_cleanup_attempted = false;
          const auto stop_partial_recording = [&]() noexcept {
            if (partial_cleanup_attempted) return;
            partial_cleanup_attempted = true;
            if (operation->audio_capture) {
              StopAndRetireWasapiLoopbackCapture(
                  operation->audio_capture, "stopped");
              if (operation->audio_capture) {
                RetireWasapiLoopbackCapture(
                    std::move(operation->audio_capture));
              }
            }
            try {
              if (capture) {
                capture->StopRecording(nullptr, nullptr, nullptr);
              }
            } catch (...) {
              // The media worker and its partial file remain recoverable.
            }
          };

          try {
            if (!capture ||
                !capture->StartRecording(
                    output_path, session_id, capture_attempt_id,
                    &operation->error_code, &operation->error_message)) {
              if (operation->error_code.empty()) {
                operation->error_code = "recordingStartFailed";
              }
            } else {
              operation->audio_capture =
                  std::make_unique<WasapiLoopbackCapture>(BindSharedOwner(
                      capture,
                      [capture_event_poster, session_id, capture_attempt_id,
                       capture_instance_id](
                          const std::shared_ptr<WindowsScreenCapture>& owner,
                          flutter::EncodableValue event,
                          bool is_audio_frame) {
                        if (is_audio_frame) {
                          return owner && owner->PushAudioFrame(event);
                        }
                        const auto* map =
                            std::get_if<flutter::EncodableMap>(&event);
                        const auto* status_value =
                            map == nullptr ? nullptr : FindValue(*map, "status");
                        const auto* status =
                            status_value == nullptr
                                ? nullptr
                                : std::get_if<std::string>(status_value);
                        if (status != nullptr &&
                            (*status == "failed" ||
                             *status == "permissionDenied" ||
                             *status == "deviceUnavailable" ||
                             *status == "deviceDisconnected")) {
                          flutter::EncodableMap failure;
                          AddString(&failure, "type", "state");
                          AddString(&failure, "status",
                                    "recordingAudioFailed");
                          AddString(&failure, "sessionId", session_id);
                          AddString(&failure, "captureAttemptId",
                                    capture_attempt_id);
                          AddInt(&failure, "captureInstanceId",
                                 capture_instance_id);
                          const auto* code = FindValue(*map, "errorCode");
                          if (code != nullptr) {
                            failure.emplace(
                                flutter::EncodableValue("errorCode"), *code);
                          }
                          if (capture_event_poster) {
                            capture_event_poster->Post(
                                flutter::EncodableValue(std::move(failure)));
                          }
                        }
                        return true;
                      }));
              if (!operation->audio_capture->Start(
                      kSystemOutputSourceId, "systemOutput", session_id,
                      capture_attempt_id, 0, &operation->error_code,
                      &operation->error_message)) {
                if (operation->error_code.empty()) {
                  operation->error_code = "recordingAudioUnavailable";
                }
                if (operation->error_message.empty()) {
                  operation->error_message = "无法采集系统播放声音。";
                }
              } else {
                operation->succeeded = true;
              }
            }
          } catch (const std::exception& error) {
            operation->error_code = "recordingStartFailed";
            operation->error_message =
                std::string("录屏或系统声音初始化失败：") + error.what();
          } catch (...) {
            operation->error_code = "recordingStartFailed";
            operation->error_message = "录屏或系统声音初始化失败。";
          }

          if (!operation->succeeded) stop_partial_recording();

          const auto handle_post_failure = [&]() noexcept {
            if (operation->succeeded) stop_partial_recording();

            std::shared_ptr<
                flutter::MethodResult<flutter::EncodableValue>>
                pending_stop_result;
            bool stop_capture = false;
            {
              std::lock_guard<std::mutex> lock(
                  window->recording_operation_state_mutex_);
              window->recording_operation_state_ =
                  RecordingOperationState::kIdle;
              window->recording_session_id_.clear();
              window->recording_capture_attempt_id_.clear();
              stop_capture = window->recording_failure_stops_capture_ ||
                             window->pending_recording_stop_capture_;
              pending_stop_result =
                  std::move(window->pending_recording_stop_result_);
              window->pending_recording_stop_capture_ = false;
              window->recording_failure_pending_ = false;
              window->recording_failure_stops_capture_ = false;
            }
            if (stop_capture && capture) {
              try {
                capture->StopCapture();
              } catch (...) {
                // Preserve the native owner; later cleanup can retry.
              }
            }

            if (!reply_gate) return;
            reply_gate->InvokeIfOpen([&] {
              const auto error_code = operation->succeeded
                    ? std::string("recordingCompletionUnavailable")
                    : (operation->error_code.empty()
                           ? std::string("recordingStartFailed")
                           : operation->error_code);
              const auto error_message = operation->succeeded
                    ? std::string("录屏准备结果无法返回，已尝试停止本次录制。")
                    : operation->error_message;
              operation->start_reply.InvokeOnce([&] {
                if (result) result->Error(error_code, error_message);
              });
              if (pending_stop_result) {
                operation->pending_stop_reply.InvokeOnce([&] {
                  pending_stop_result->Error(
                      operation->succeeded
                          ? "recordingCompletionUnavailable"
                          : "recordingStartFailed",
                      operation->succeeded
                          ? "录屏启动结果无法返回，停止请求已交由本机清理。"
                          : "录屏未能启动，停止请求未执行。");
                });
              }
            });
          };

          bool posted = false;
          try {
            posted = completion_poster && completion_poster->PostCompletion(
                  [window, result, operation]() mutable {
                    if (!operation->succeeded) {
                      std::shared_ptr<
                          flutter::MethodResult<flutter::EncodableValue>>
                          pending_stop_result;
                      bool stop_capture = false;
                      {
                        std::lock_guard<std::mutex> lock(
                            window->recording_operation_state_mutex_);
                        window->recording_operation_state_ =
                            RecordingOperationState::kIdle;
                        window->recording_session_id_.clear();
                        window->recording_capture_attempt_id_.clear();
                        stop_capture =
                            window->recording_failure_stops_capture_ ||
                            window->pending_recording_stop_capture_;
                        pending_stop_result = std::move(
                            window->pending_recording_stop_result_);
                        window->pending_recording_stop_capture_ = false;
                        window->recording_failure_pending_ = false;
                        window->recording_failure_stops_capture_ = false;
                      }
                      operation->start_reply.InvokeOnce([&] {
                        if (result) {
                          result->Error(
                              operation->error_code.empty()
                                  ? "recordingStartFailed"
                                  : operation->error_code,
                              operation->error_message);
                        }
                      });
                      if (pending_stop_result) {
                        window->StopRecordingAsync(
                            std::move(pending_stop_result), stop_capture);
                      } else if (stop_capture) {
                        window->StopRecordingAsync(nullptr, true);
                      }
                      return;
                    }
                    window->recording_audio_capture_ =
                        std::move(operation->audio_capture);
                    std::shared_ptr<
                        flutter::MethodResult<flutter::EncodableValue>>
                        pending_stop_result;
                    bool should_stop = false;
                    bool stop_capture = false;
                    {
                      std::lock_guard<std::mutex> lock(
                          window->recording_operation_state_mutex_);
                      window->recording_operation_state_ =
                          RecordingOperationState::kRecording;
                      should_stop =
                          window->pending_recording_stop_result_ != nullptr ||
                          window->recording_failure_pending_;
                      if (should_stop) {
                        stop_capture =
                            window->recording_failure_stops_capture_ ||
                            window->pending_recording_stop_capture_;
                        pending_stop_result = std::move(
                            window->pending_recording_stop_result_);
                        window->pending_recording_stop_capture_ = false;
                        window->recording_failure_pending_ = false;
                        window->recording_failure_stops_capture_ = false;
                      }
                    }
                    operation->start_reply.InvokeOnce([&] {
                      if (result) result->Success();
                    });
                    if (should_stop) {
                      window->StopRecordingAsync(std::move(pending_stop_result),
                                                 stop_capture);
                    }
                  },
                  [window, operation, reply_gate, result]() {
                    // A queued start completion can be discarded during
                    // WM_DESTROY. Transfer the capture to normal post-loop
                    // cleanup instead of joining its worker in the window proc.
                    if (operation->audio_capture &&
                        !window->recording_audio_capture_) {
                      window->recording_audio_capture_ =
                          std::move(operation->audio_capture);
                    }
                    std::shared_ptr<
                        flutter::MethodResult<flutter::EncodableValue>>
                        pending_stop_result;
                    {
                      std::lock_guard<std::mutex> lock(
                          window->recording_operation_state_mutex_);
                      window->recording_operation_state_ =
                          RecordingOperationState::kIdle;
                      window->recording_session_id_.clear();
                      window->recording_capture_attempt_id_.clear();
                      pending_stop_result = std::move(
                          window->pending_recording_stop_result_);
                      window->pending_recording_stop_capture_ = false;
                      window->recording_failure_pending_ = false;
                      window->recording_failure_stops_capture_ = false;
                    }
                    if (!reply_gate) return;
                    reply_gate->InvokeIfOpen([&] {
                      operation->start_reply.InvokeOnce([&] {
                        if (result) {
                          result->Error(
                              "captureShuttingDown",
                              "录屏启动完成前窗口已关闭，本次录制已交由关闭流程清理。");
                        }
                      });
                      if (pending_stop_result) {
                        operation->pending_stop_reply.InvokeOnce([&] {
                          pending_stop_result->Error(
                              "captureShuttingDown",
                              "录屏窗口正在关闭，停止请求已由关闭流程接管。");
                        });
                      }
                    });
                  });
          } catch (...) {
            posted = false;
          }
          static_cast<void>(yixue::runner::RunScreenCapturePostFailureOnce(
              posted, operation->post_failure, handle_post_failure));
        });
  } catch (const std::exception& error) {
    {
      std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
      recording_operation_state_ = RecordingOperationState::kIdle;
      recording_session_id_.clear();
      recording_capture_attempt_id_.clear();
    }
    result->Error("recordingStartFailed",
                  std::string("无法启动录屏准备任务：") + error.what());
  } catch (...) {
    {
      std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
      recording_operation_state_ = RecordingOperationState::kIdle;
      recording_session_id_.clear();
      recording_capture_attempt_id_.clear();
    }
    result->Error("recordingStartFailed", "无法启动录屏准备任务。");
  }
}

void FlutterWindow::StopRecordingAsync(
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    bool stop_capture) {
  bool deferred_while_starting = false;
  bool already_stopping = false;
  bool duplicate_stop = false;
  {
    std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
    if (recording_operation_state_ == RecordingOperationState::kStarting) {
      deferred_while_starting = true;
      if (!result) {
        recording_failure_pending_ = true;
        recording_failure_stops_capture_ =
            recording_failure_stops_capture_ || stop_capture;
      } else if (!pending_recording_stop_result_) {
        // Serialize a user stop request behind startup. This avoids returning
        // a spurious error when Stop is pressed immediately after Start.
        pending_recording_stop_result_ = std::move(result);
        pending_recording_stop_capture_ = stop_capture;
      } else {
        duplicate_stop = true;
      }
    } else if (recording_operation_state_ ==
               RecordingOperationState::kStopping) {
      already_stopping = true;
    }
  }
  if (deferred_while_starting) {
    if (duplicate_stop && result) {
      result->Error("recordingCleanupPending", "录屏已经收到停止请求，请稍后重试。");
    }
    return;
  }
  if (already_stopping) {
    if (result) {
      result->Error("recordingCleanupPending", "录屏仍在停止和保存，请稍后重试。");
    }
    return;
  }

  JoinRecordingOperationWorker();
  if (recording_operation_worker_.joinable()) {
    if (result) {
      result->Error("recordingCleanupPending", "录屏仍在清理，请稍后重试。");
    }
    return;
  }
  const auto capture = screen_capture_;
  if (!capture) {
    if (result) {
      result->Error("captureNotInitialized", "Windows 桌面画面采集对象尚未创建。");
    }
    return;
  }
  std::shared_ptr<RecordingStopOperation> operation;
  try {
    operation = std::make_shared<RecordingStopOperation>();
  } catch (...) {
    if (result) {
      result->Error("recordingStopFailed", "停止录屏时内存不足，录制仍在保留。");
    }
    return;
  }
  operation->audio_capture = std::move(recording_audio_capture_);
  const auto completion_poster = screen_capture_event_poster_;
  const auto reply_gate = screen_recording_reply_gate_;
  {
    std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
    recording_operation_state_ = RecordingOperationState::kStopping;
  }

  try {
    recording_operation_worker_.Start(
        [window = this, capture, completion_poster, reply_gate, operation,
         result, stop_capture]() {
          try {
            if (operation->audio_capture) {
              operation->audio_finalized =
                  StopAndRetireWasapiLoopbackCapture(
                      operation->audio_capture, "stopped") ==
                  WasapiCaptureStopResult::kStopped;
              if (!operation->audio_finalized) {
                yixue::runner::diagnostics::Log(
                    "screen_recording_audio_stop_pending");
              }
            }
          } catch (const std::exception& error) {
            operation->error_code = "recordingAudioStopFailed";
            operation->error_message = error.what();
          } catch (...) {
            operation->error_code = "recordingAudioStopFailed";
            operation->error_message = "系统声音采集未能正常停止。";
          }

          std::string video_error_code;
          std::string video_error_message;
          bool video_stopped = false;
          try {
            video_stopped = capture->StopRecording(
                &operation->output_path, &video_error_code,
                &video_error_message);
          } catch (const std::exception& error) {
            video_error_code = "recordingStopFailed";
            video_error_message = error.what();
          } catch (...) {
            video_error_code = "recordingStopFailed";
            video_error_message = "Windows 未能完成录屏保存。";
          }
          if (!video_stopped) {
            operation->error_code = video_error_code.empty()
                ? "recordingStopFailed"
                : video_error_code;
            operation->error_message = video_error_message;
          }
          operation->succeeded = video_stopped && operation->error_code.empty();
          if (video_stopped && stop_capture) {
            try {
              capture->StopCapture();
            } catch (...) {
              operation->succeeded = false;
              operation->error_code = "captureStopFailed";
              operation->error_message = "录屏已保存，但桌面画面预览未能停止。";
            }
          }

          const auto retire_remaining_audio = [&]() noexcept {
            if (!operation->audio_capture) return;
            StopAndRetireWasapiLoopbackCapture(operation->audio_capture,
                                               "stopped");
            if (operation->audio_capture) {
              RetireWasapiLoopbackCapture(std::move(operation->audio_capture));
            }
          };
          // StopAndRetire normally consumes the owner, but a mismatched or
          // partially failed stop can leave it here. Retire it on the worker
          // before any completion closure can release the operation.
          retire_remaining_audio();
          const auto handle_post_failure = [&]() noexcept {
            retire_remaining_audio();
            {
              std::lock_guard<std::mutex> lock(
                  window->recording_operation_state_mutex_);
              window->recording_operation_state_ =
                  RecordingOperationState::kIdle;
              window->recording_session_id_.clear();
              window->recording_capture_attempt_id_.clear();
              window->recording_failure_pending_ = false;
              window->recording_failure_stops_capture_ = false;
            }
            if (!reply_gate || !result) return;
            reply_gate->InvokeIfOpen([&] {
              operation->stop_reply.InvokeOnce([&] {
                if (!operation->succeeded) {
                  result->Error(
                      operation->error_code.empty()
                          ? "recordingStopFailed"
                          : operation->error_code,
                      operation->error_message);
                  return;
                }
                if (stop_capture) {
                  result->Success();
                  return;
                }
                flutter::EncodableMap response;
                AddString(&response, "outputPath", operation->output_path);
                response.emplace(
                    flutter::EncodableValue("audioFinalized"),
                    flutter::EncodableValue(operation->audio_finalized));
                result->Success(
                    flutter::EncodableValue(std::move(response)));
              });
            });
          };

          bool posted = false;
          try {
            posted = completion_poster && completion_poster->PostCompletion(
                [window, operation, result, stop_capture]() {
                  {
                    std::lock_guard<std::mutex> lock(
                        window->recording_operation_state_mutex_);
                    window->recording_operation_state_ =
                        RecordingOperationState::kIdle;
                    window->recording_session_id_.clear();
                    window->recording_capture_attempt_id_.clear();
                    window->recording_failure_pending_ = false;
                    window->recording_failure_stops_capture_ = false;
                  }
                  if (!result) return;
                  if (!operation->succeeded) {
                    operation->stop_reply.InvokeOnce([&] {
                      result->Error(
                          operation->error_code.empty()
                              ? "recordingStopFailed"
                              : operation->error_code,
                          operation->error_message);
                    });
                    return;
                  }
                  if (stop_capture) {
                    operation->stop_reply.InvokeOnce(
                        [&] { result->Success(); });
                    return;
                  }
                  flutter::EncodableMap response;
                  AddString(&response, "outputPath", operation->output_path);
                  response.emplace(
                      flutter::EncodableValue("audioFinalized"),
                      flutter::EncodableValue(operation->audio_finalized));
                  operation->stop_reply.InvokeOnce([&] {
                    result->Success(
                        flutter::EncodableValue(std::move(response)));
                  });
                },
                [window, operation, reply_gate, result, stop_capture]() {
                  if (operation->audio_capture &&
                      !window->recording_audio_capture_) {
                    window->recording_audio_capture_ =
                        std::move(operation->audio_capture);
                  }
                  {
                    std::lock_guard<std::mutex> lock(
                        window->recording_operation_state_mutex_);
                    window->recording_operation_state_ =
                        RecordingOperationState::kIdle;
                    window->recording_session_id_.clear();
                    window->recording_capture_attempt_id_.clear();
                    window->recording_failure_pending_ = false;
                    window->recording_failure_stops_capture_ = false;
                  }
                  if (!reply_gate || !result) return;
                  reply_gate->InvokeIfOpen([&] {
                    operation->stop_reply.InvokeOnce([&] {
                      if (!operation->succeeded) {
                        result->Error(
                            operation->error_code.empty()
                                ? "recordingStopFailed"
                                : operation->error_code,
                            operation->error_message);
                        return;
                      }
                      if (stop_capture) {
                        result->Success();
                        return;
                      }
                      flutter::EncodableMap response;
                      AddString(&response, "outputPath", operation->output_path);
                      response.emplace(
                          flutter::EncodableValue("audioFinalized"),
                          flutter::EncodableValue(
                              operation->audio_finalized));
                      result->Success(
                          flutter::EncodableValue(std::move(response)));
                    });
                  });
                });
          } catch (...) {
            posted = false;
          }
          static_cast<void>(yixue::runner::RunScreenCapturePostFailureOnce(
              posted, operation->post_failure, handle_post_failure));
        });
  } catch (const std::exception& error) {
    recording_audio_capture_ = std::move(operation->audio_capture);
    {
      std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
      recording_operation_state_ = RecordingOperationState::kRecording;
    }
    if (result) {
      result->Error("recordingStopFailed",
                    std::string("无法启动录屏保存任务：") + error.what());
    }
  } catch (...) {
    recording_audio_capture_ = std::move(operation->audio_capture);
    {
      std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
      recording_operation_state_ = RecordingOperationState::kRecording;
    }
    if (result) {
      result->Error("recordingStopFailed", "无法启动录屏保存任务。");
    }
  }
}

void FlutterWindow::ShutdownScreenCapture() {
  if (screen_capture_event_poster_) screen_capture_event_poster_->Close();
  const auto texture_wait_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  const auto remaining_texture_wait = [&texture_wait_deadline] {
    const auto now = std::chrono::steady_clock::now();
    if (now >= texture_wait_deadline) return std::chrono::milliseconds(0);
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        texture_wait_deadline - now);
  };
  if (recording_audio_capture_) {
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log("main_cleanup_recording_audio_begin");
    }
    const auto stop_result = StopAndRetireWasapiLoopbackCapture(
        recording_audio_capture_, "stopped");
    if (stop_result == WasapiCaptureStopResult::kPending && !subtitle_process_) {
      yixue::runner::diagnostics::Log(
          "main_cleanup_recording_audio_stop_pending");
    }
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log("main_cleanup_recording_audio_end");
    }
  }
  if (!subtitle_process_ && !retired_screen_captures_.empty()) {
    yixue::runner::diagnostics::Log(
        "main_cleanup_retired_capture_begin",
        static_cast<DWORD>(retired_screen_captures_.size()));
  }
  for (const auto& capture : retired_screen_captures_) {
    if (!capture) continue;
    try {
      capture->Shutdown(remaining_texture_wait());
    } catch (...) {
      // Continue releasing the remaining capture instances.
    }
  }
  retired_screen_captures_.clear();
  if (screen_capture_) {
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log(
          "main_cleanup_screen_capture_owner_begin");
    }
    try {
      screen_capture_->Shutdown(remaining_texture_wait());
    } catch (...) {
      // The capture object's destructor has an independent no-throw fallback.
    }
    screen_capture_.reset();
    if (!subtitle_process_) {
      yixue::runner::diagnostics::Log(
          "main_cleanup_screen_capture_owner_end");
    }
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (!subtitle_process_) {
    if (message == WM_CLOSE) {
      yixue::runner::diagnostics::Log("main_wm_close_received");
    } else if (message == WM_QUERYENDSESSION) {
      yixue::runner::diagnostics::Log("main_wm_queryendsession",
                                      static_cast<DWORD>(wparam));
      system_shutdown_has_extended_grace_ =
          ::IsWindowVisible(hwnd) != FALSE;
      if (yixue::runner::ShouldRegisterShutdownBlockReason(
              message, ::IsWindowVisible(hwnd) != FALSE,
              subtitle_process_) &&
          !shutdown_block_reason_registered_) {
        shutdown_block_reason_registered_ =
            ::ShutdownBlockReasonCreate(
                hwnd,
                L"译学正在停止采集并保存字幕；未完成的录音或录屏可能无法播放。") !=
            FALSE;
        yixue::runner::diagnostics::Log(
            shutdown_block_reason_registered_
                ? "main_shutdown_block_reason_registered"
                : "main_shutdown_block_reason_registration_failed",
            shutdown_block_reason_registered_ ? ERROR_SUCCESS
                                               : ::GetLastError());
      }
      system_shutdown_has_extended_grace_ =
          system_shutdown_has_extended_grace_ ||
          shutdown_block_reason_registered_;
    } else if (message == WM_ENDSESSION) {
      yixue::runner::diagnostics::Log("main_wm_endsession",
                                      static_cast<DWORD>(wparam));
      if (yixue::runner::ShouldNotifyFlutterOfSystemSessionEnd(
              message, wparam, subtitle_process_)) {
        system_shutdown_has_extended_grace_ =
            system_shutdown_has_extended_grace_ ||
            ::IsWindowVisible(hwnd) != FALSE ||
            shutdown_block_reason_registered_;
        system_shutdown_pending_ = true;
        DispatchPendingSystemShutdown();
      } else if (wparam == FALSE) {
        ReleaseShutdownBlockReason();
        system_shutdown_has_extended_grace_ = false;
      }
    } else if (message == WM_SYSCOMMAND &&
               (wparam & 0xFFF0) == SC_CLOSE) {
      yixue::runner::diagnostics::Log("main_wm_syscommand_close");
    } else if (message == WM_NCDESTROY) {
      yixue::runner::diagnostics::Log("main_wm_ncdestroy");
    }
  }
  try {
    if (message == yixue::runner::kRestoreMainWindowMessage) {
      restore_main_window_pending_ = true;
      DispatchPendingMainWindowRestore();
      return 0;
    }

    if (message == WM_DESTROY) {
      if (!subtitle_process_) {
        yixue::runner::diagnostics::Log("main_wm_destroy_received");
        // Signal only for a real native window destruction. Win32Window::
        // Create used to call its generic Destroy() hook even on first launch,
        // which looked like a close request to the supervisor.
        yixue::runner::SignalParentSupervisorCloseRequest();
      }
      // Arm the watchdog before the remainder of WM_DESTROY dispatch or the
      // message loop can stall during native teardown.
      yixue::runner::SignalUiCleanupWatchdogStart();
      // Stop new event posts and discard this window's queued capture payloads
      // while its HWND is still valid. Engine and texture destruction remains
      // deferred until the native close method has returned to the message loop.
      screen_capture_shutdown_.store(true);
      if (screen_capture_event_poster_) screen_capture_event_poster_->Close();
      DiscardQueuedScreenCaptureMessages(hwnd);
    }

    if (message == kScreenCaptureCompletionMessage) {
      std::unique_ptr<yixue::runner::PendingScreenCaptureCompletion> pending(
          reinterpret_cast<yixue::runner::PendingScreenCaptureCompletion*>(
              lparam));
      if (!pending) return 0;
      try {
        if (pending->dispatch) pending->dispatch();
      } catch (...) {
        // A completion callback must not unwind through the Win32 procedure.
      }
      return 0;
    }

    // This private message carries a heap payload owned by this window. Take
    // ownership and handle lifecycle cleanup before Flutter or plugins can
    // consume the message or throw while dispatching it.
    if (message == kScreenCaptureEventMessage) {
      std::unique_ptr<PendingScreenCaptureEvent> pending(
          reinterpret_cast<PendingScreenCaptureEvent*>(lparam));
      if (!pending) return 0;
      try {
        const auto* map =
            std::get_if<flutter::EncodableMap>(&pending->event);
        const auto* error_value = map == nullptr ? nullptr
                                                  : FindValue(*map, "errorCode");
        const auto* error = error_value == nullptr
                                ? nullptr
                                : std::get_if<std::string>(error_value);
        const auto* status_value =
            map == nullptr ? nullptr : FindValue(*map, "status");
        const auto* status = status_value == nullptr
                                 ? nullptr
                                 : std::get_if<std::string>(status_value);
        const bool capture_target_closed =
            error != nullptr && *error == "captureTargetClosed";
        const bool recording_audio_failed =
            status != nullptr && *status == "recordingAudioFailed";
        const bool recording_failed =
            status != nullptr && *status == "recordingFailed";
        const bool capture_failed =
            status != nullptr && *status == "captureFailed";
        const auto* session_value =
            map == nullptr ? nullptr : FindValue(*map, "sessionId");
        const auto* session_id = session_value == nullptr
                                     ? nullptr
                                     : std::get_if<std::string>(session_value);
        const auto* attempt_value =
            map == nullptr ? nullptr : FindValue(*map, "captureAttemptId");
        const auto* attempt_id = attempt_value == nullptr
                                     ? nullptr
                                     : std::get_if<std::string>(attempt_value);
        const auto* capture_id_value =
            map == nullptr ? nullptr : FindValue(*map, "captureInstanceId");
        const auto capture_id = capture_id_value == nullptr
                                    ? std::optional<int64_t>{}
                                    : capture_id_value->TryGetLongValue();
        const bool is_recording_failure =
            recording_audio_failed || recording_failed;
        const bool is_capture_lifecycle_failure =
            capture_target_closed || capture_failed;
        const bool should_cleanup =
            is_capture_lifecycle_failure || is_recording_failure;
        bool should_stop_recording = false;
        if (should_cleanup) {
          std::lock_guard<std::mutex> lock(recording_operation_state_mutex_);
          if (ShouldCleanupCaptureFailure(
                  is_recording_failure, is_capture_lifecycle_failure,
                  session_id == nullptr ? "" : *session_id,
                  attempt_id == nullptr ? "" : *attempt_id,
                  recording_session_id_, recording_capture_attempt_id_,
                  capture_id.value_or(0), screen_capture_instance_id_)) {
            if (recording_operation_state_ ==
                RecordingOperationState::kStarting) {
              recording_failure_pending_ = true;
              recording_failure_stops_capture_ =
                  recording_failure_stops_capture_ ||
                  is_capture_lifecycle_failure;
            } else if (recording_operation_state_ ==
                       RecordingOperationState::kRecording) {
              should_stop_recording = true;
            }
          }
        }
        if (should_stop_recording) {
          StopRecordingAsync(nullptr, is_capture_lifecycle_failure);
        }
        // Cleanup is native lifecycle work and must not depend on Dart having
        // an active EventChannel listener. The listener controls only UI updates.
        if (screen_capture_event_sink_) {
          try {
            screen_capture_event_sink_->Success(pending->event);
          } catch (...) {
            // Event delivery failure must not terminate the native window proc.
          }
        }
      } catch (...) {
        // Contain malformed events and allocation failures in this noexcept
        // window callback; pending still releases its payload on this path.
      }
      return 0;
    }

    // Give Flutter, including plugins, an opportunity to handle other window
    // messages after native capture-event ownership and cleanup are resolved.
    if (flutter_controller_) {
      std::optional<LRESULT> result =
          flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                        lparam);
      if (result) {
        return *result;
      }
    }

    if (message == WM_FONTCHANGE && flutter_controller_) {
      flutter_controller_->engine()->ReloadSystemFonts();
    }

    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  } catch (...) {
    // Preserve the base window's destruction and quit-message behavior even
    // when cleanup or Flutter dispatch fails while closing the main window.
    if (message == WM_DESTROY) {
      screen_capture_shutdown_.store(true);
      if (screen_capture_event_poster_) screen_capture_event_poster_->Close();
      return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
    }
    // This is a noexcept Win32 callback. Never let plugin or Flutter exceptions
    // escape into the operating system's window procedure.
    return 0;
  }
}
