#include "wasapi_audio_capture_plugin.h"

#include <windows.h>
#include <propkeydef.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <exception>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "wasapi_loopback_capture.h"
#include "wasapi_audio_callback_boundary.h"
#include "supervisor_diagnostics.h"

namespace {

using Microsoft::WRL::ComPtr;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kMethodChannelName[] =
    "com.yixue.yixue_app/ai_tongchuan/audio";
constexpr char kEventChannelName[] =
    "com.yixue.yixue_app/ai_tongchuan/audio_events";
constexpr char kSystemOutputSourceId[] = "windows-system-output";
constexpr char kMicrophoneSourcePrefix[] = "windows-microphone:";
constexpr wchar_t kDispatchWindowClass[] =
    L"YIXUE_AI_TONGCHUAN_AUDIO_DISPATCH";
constexpr UINT kDispatchEventsMessage = WM_APP + 0x371;
constexpr size_t kMaximumQueuedAudioFrames = 8;
constexpr auto kCaptureStopWait = std::chrono::milliseconds(500);

EncodableValue MakeMap(EncodableMap map) {
  return EncodableValue(std::move(map));
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          value.data(),
                                          static_cast<int>(value.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string result(static_cast<size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length, nullptr, nullptr) != length) {
    return {};
  }
  return result;
}

std::optional<std::string> ReadString(const EncodableMap& map,
                                      const char* key) {
  const auto found = map.find(EncodableValue(key));
  if (found == map.end()) return std::nullopt;
  if (const auto* value = std::get_if<std::string>(&found->second)) {
    if (!value->empty()) return *value;
  }
  return std::nullopt;
}

std::optional<int64_t> ReadInteger(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(key));
  if (found == map.end()) return std::nullopt;
  if (const auto* value = std::get_if<int32_t>(&found->second)) {
    return static_cast<int64_t>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&found->second)) {
    return *value;
  }
  return std::nullopt;
}

std::string ReadDeviceName(IMMDevice* device, const std::wstring& fallback) {
  ComPtr<IPropertyStore> properties;
  if (FAILED(device->OpenPropertyStore(STGM_READ, &properties))) {
    return WideToUtf8(fallback);
  }
  PROPVARIANT value;
  PropVariantInit(&value);
  const HRESULT result = properties->GetValue(PKEY_Device_FriendlyName, &value);
  std::wstring name;
  if (SUCCEEDED(result) && value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
    name = value.pwszVal;
  }
  PropVariantClear(&value);
  return WideToUtf8(name.empty() ? fallback : name);
}

EncodableMap MakeSource(const std::string& source_id,
                        const std::string& source_kind,
                        const std::string& display_name,
                        const std::string& description) {
  EncodableMap source;
  source.emplace(EncodableValue("sourceId"), EncodableValue(source_id));
  source.emplace(EncodableValue("sourceKind"), EncodableValue(source_kind));
  source.emplace(EncodableValue("displayName"), EncodableValue(display_name));
  source.emplace(EncodableValue("description"), EncodableValue(description));
  return source;
}

EncodableList EnumerateCaptureSources() {
  EncodableList result;
  result.emplace_back(MakeMap(MakeSource(
      kSystemOutputSourceId, "systemOutput", "系统播放声音",
      "Windows WASAPI 共享模式系统输出混音")));

  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool uninitialize_com = SUCCEEDED(com_result);
  if (FAILED(com_result) && com_result != RPC_E_CHANGED_MODE) return result;

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT status = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL,
                                    IID_PPV_ARGS(enumerator.GetAddressOf()));
  ComPtr<IMMDeviceCollection> devices;
  if (SUCCEEDED(status)) {
    status = enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE,
                                            &devices);
  }
  if (SUCCEEDED(status) && devices != nullptr) {
    UINT count = 0;
    if (SUCCEEDED(devices->GetCount(&count))) {
      for (UINT index = 0; index < count; ++index) {
        ComPtr<IMMDevice> device;
        if (FAILED(devices->Item(index, &device)) || device == nullptr) continue;
        LPWSTR raw_id = nullptr;
        if (FAILED(device->GetId(&raw_id)) || raw_id == nullptr) continue;
        const std::wstring endpoint_id(raw_id);
        CoTaskMemFree(raw_id);
        const std::string endpoint_id_utf8 = WideToUtf8(endpoint_id);
        if (endpoint_id_utf8.empty()) continue;
        const std::string source_id =
            std::string(kMicrophoneSourcePrefix) + endpoint_id_utf8;
        const std::string display_name = ReadDeviceName(device.Get(), endpoint_id);
        result.emplace_back(MakeMap(MakeSource(
            source_id, "microphone", display_name,
            "Windows WASAPI 共享模式麦克风输入")));
      }
    }
  }
  if (uninitialize_com) CoUninitialize();
  return result;
}

class AudioMethodReply final {
 public:
  using Result = flutter::MethodResult<EncodableValue>;

  explicit AudioMethodReply(std::unique_ptr<Result> result)
      : result_(std::move(result)) {}

  void Success(EncodableValue value) {
    if (result_ == nullptr || !reply_gate_.TryBeginReply()) return;
    result_->Success(value);
  }

  void Error(const std::string& code, const std::string& message) {
    if (result_ == nullptr || !reply_gate_.TryBeginReply()) return;
    result_->Error(code, message);
  }

  void NotImplemented() {
    if (result_ == nullptr || !reply_gate_.TryBeginReply()) return;
    result_->NotImplemented();
  }

 private:
  std::unique_ptr<Result> result_;
  yixue::runner::NativeMethodReplyGate reply_gate_;
};

class WasapiAudioCapturePlugin : public flutter::Plugin {
 public:
  explicit WasapiAudioCapturePlugin(flutter::PluginRegistrarWindows* registrar)
      : method_channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), kMethodChannelName,
            &flutter::StandardMethodCodec::GetInstance())),
        event_channel_(std::make_unique<flutter::EventChannel<EncodableValue>>(
            registrar->messenger(), kEventChannelName,
            &flutter::StandardMethodCodec::GetInstance())) {
    CreateDispatchWindow();
    method_channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          HandleMethodCall(call, std::move(result));
        });
    event_channel_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) {
              event_sink_ = std::move(sink);
              event_dispatch_state_->has_listener.store(event_sink_ != nullptr);
              return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
            },
            [this](const EncodableValue*) {
              event_dispatch_state_->has_listener.store(false);
              event_sink_.reset();
              ClearQueuedEvents();
              return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
            }));
  }

  ~WasapiAudioCapturePlugin() override {
    yixue::runner::diagnostics::Log("wasapi_plugin_destroy_begin");
    if (method_channel_ != nullptr) method_channel_->SetMethodCallHandler(nullptr);
    if (event_channel_ != nullptr) event_channel_->SetStreamHandler(nullptr);
    event_dispatch_state_->has_listener.store(false);
    yixue::runner::diagnostics::Log("wasapi_plugin_stop_all_begin");
    StopAll("stopped");
    yixue::runner::diagnostics::Log("wasapi_plugin_stop_all_end");
    event_sink_.reset();
    ClearQueuedEvents();
    if (dispatch_window_ != nullptr && IsWindow(dispatch_window_)) {
      yixue::runner::diagnostics::Log("wasapi_plugin_destroy_window_begin");
      {
        std::lock_guard<std::mutex> lock(event_dispatch_state_->mutex);
        event_dispatch_state_->dispatch_window = nullptr;
      }
      DestroyWindow(dispatch_window_);
      yixue::runner::diagnostics::Log("wasapi_plugin_destroy_window_end");
    }
    dispatch_window_ = nullptr;
    yixue::runner::diagnostics::Log("wasapi_plugin_destroy_end");
  }

 private:
  struct QueuedEvent {
    EncodableValue value;
    bool is_audio_frame = false;
  };

  static bool RegisterDispatchWindowClass() {
    static bool registered = false;
    if (registered) return true;
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpfnWndProc = WindowProc;
    window_class.lpszClassName = kDispatchWindowClass;
    if (RegisterClassExW(&window_class) == 0 &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }
    registered = true;
    return true;
  }

  bool CreateDispatchWindow() {
    if (!RegisterDispatchWindowClass()) return false;
    dispatch_window_ = CreateWindowExW(
        0, kDispatchWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
        GetModuleHandleW(nullptr), this);
    if (dispatch_window_ != nullptr) {
      std::lock_guard<std::mutex> lock(event_dispatch_state_->mutex);
      event_dispatch_state_->dispatch_window = dispatch_window_;
    }
    return dispatch_window_ != nullptr;
  }

  static LRESULT CALLBACK WindowProc(HWND window, UINT message,
                                     WPARAM wparam, LPARAM lparam) {
    WasapiAudioCapturePlugin* plugin =
        reinterpret_cast<WasapiAudioCapturePlugin*>(
            GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
      plugin = static_cast<WasapiAudioCapturePlugin*>(create->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(plugin));
      plugin->dispatch_window_ = window;
    }
    if (plugin == nullptr) return DefWindowProcW(window, message, wparam, lparam);
    if (message == kDispatchEventsMessage) {
      yixue::runner::RunWasapiAudioPluginCallbackSafely(
          [plugin] { plugin->DispatchQueuedEvents(); },
          [](std::exception_ptr) {
            yixue::runner::diagnostics::Log(
                "wasapi_event_dispatch_exception", ERROR_UNHANDLED_EXCEPTION);
          });
      return 0;
    }
    if (message == WM_NCDESTROY) {
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      plugin->dispatch_window_ = nullptr;
      std::lock_guard<std::mutex> lock(plugin->event_dispatch_state_->mutex);
      if (plugin->event_dispatch_state_->dispatch_window == window) {
        plugin->event_dispatch_state_->dispatch_window = nullptr;
      }
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }

  struct EventDispatchState {
    std::mutex mutex;
    std::deque<QueuedEvent> event_queue;
    size_t queued_audio_frames = 0;
    bool dispatch_posted = false;
    std::atomic<bool> has_listener{false};
    HWND dispatch_window = nullptr;
  };

  static bool EnqueueEvent(
      const std::shared_ptr<EventDispatchState>& state,
      EncodableValue event,
      bool is_audio_frame) {
    if (!state || !state->has_listener.load()) return false;
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->has_listener.load() || state->dispatch_window == nullptr) {
      return false;
    }
    if (is_audio_frame &&
        state->queued_audio_frames >= kMaximumQueuedAudioFrames) {
      return false;
    }
    if (is_audio_frame) ++state->queued_audio_frames;
    state->event_queue.push_back(QueuedEvent{std::move(event), is_audio_frame});
    if (state->dispatch_posted) return true;

    state->dispatch_posted = true;
    if (!PostMessageW(state->dispatch_window, kDispatchEventsMessage, 0, 0)) {
      state->event_queue.clear();
      state->queued_audio_frames = 0;
      state->dispatch_posted = false;
      return false;
    }
    return true;
  }

  void DispatchQueuedEvents() {
    std::deque<QueuedEvent> pending;
    {
      std::lock_guard<std::mutex> lock(event_dispatch_state_->mutex);
      pending.swap(event_dispatch_state_->event_queue);
      event_dispatch_state_->queued_audio_frames = 0;
      event_dispatch_state_->dispatch_posted = false;
    }
    if (!event_sink_) return;
    for (const auto& event : pending) event_sink_->Success(event.value);
  }

  void ClearQueuedEvents() {
    const auto state = event_dispatch_state_;
    std::lock_guard<std::mutex> lock(state->mutex);
    state->event_queue.clear();
    state->queued_audio_frames = 0;
    state->dispatch_posted = false;
  }

  static const EncodableMap* ReadArguments(
      const flutter::MethodCall<EncodableValue>& call) {
    if (call.arguments() == nullptr) return nullptr;
    return std::get_if<EncodableMap>(call.arguments());
  }

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!result) return;
    AudioMethodReply reply(std::move(result));
    yixue::runner::RunWasapiAudioPluginCallbackSafely(
        [&] { HandleMethodCallImpl(call, reply); },
        [this, &reply](std::exception_ptr) {
          yixue::runner::diagnostics::Log(
              "wasapi_method_callback_exception", ERROR_UNHANDLED_EXCEPTION);
          reply.Error("audio_capture_native_error",
                      "The native audio operation failed safely.");
        });
  }

  void HandleMethodCallImpl(const flutter::MethodCall<EncodableValue>& call,
                            AudioMethodReply& result) {
    if (call.method_name() == "enumerateSources") {
      result.Success(EncodableValue(EnumerateCaptureSources()));
      return;
    }
    if (call.method_name() == "startSource" ||
        call.method_name() == "resumeSource" ||
        call.method_name() == "start" || call.method_name() == "resume") {
      const EncodableMap* arguments = ReadArguments(call);
      if (arguments == nullptr) {
        result.Error("invalid_audio_capture_request",
                     "Audio source parameters are missing.");
        return;
      }
      const auto source_id = ReadString(*arguments, "sourceId");
      const auto session_id = ReadString(*arguments, "sessionId");
      const auto attempt_id = ReadString(*arguments, "captureAttemptId");
      const auto offset = ReadInteger(*arguments, "activeCaptureOffsetUs");
      const auto requested_kind = ReadString(*arguments, "sourceKind");
      const std::string source_kind = requested_kind.value_or(
          source_id.has_value() && *source_id == kSystemOutputSourceId
              ? "systemOutput"
              : "microphone");
      if (!source_id.has_value() || !session_id.has_value() ||
          !attempt_id.has_value() || !offset.has_value() || *offset < 0) {
        result.Error(
            "invalid_audio_capture_request",
            "Audio source identity or timeline offset is invalid.");
        return;
      }
      if (call.method_name() == "resumeSource" &&
          captures_.find(*source_id) == captures_.end()) {
        result.Error("audio_capture_source_not_found",
                     "The paused audio source no longer exists.");
        return;
      }
      std::string error_code;
      std::string error_message;
      try {
        if (!StartSource(*source_id, source_kind, *session_id, *attempt_id,
                         *offset, &error_code, &error_message)) {
          result.Error(error_code.empty() ? "audio_capture_start_failed"
                                          : error_code,
                       error_message);
          return;
        }
      } catch (const std::exception& error) {
        result.Error("audio_capture_start_failed",
                     std::string("Native audio startup failed: ") +
                         error.what());
        return;
      } catch (...) {
        result.Error("audio_capture_start_failed",
                     "Native audio startup failed.");
        return;
      }
      result.Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "pauseSource" ||
        call.method_name() == "stopSource") {
      const EncodableMap* arguments = ReadArguments(call);
      const auto source_id =
          arguments == nullptr ? std::nullopt : ReadString(*arguments, "sourceId");
      const auto session_id = arguments == nullptr
                                  ? std::nullopt
                                  : ReadString(*arguments, "sessionId");
      if (!source_id.has_value() || !session_id.has_value()) {
        result.Error("invalid_audio_capture_request",
                     "Audio source or session identity is missing.");
        return;
      }
      try {
        const auto stop_result = StopSourceForSession(
            *source_id, *session_id,
            call.method_name() == "pauseSource" ? "paused" : "stopped",
            call.method_name() == "stopSource");
        if (stop_result == WasapiCaptureStopResult::kNotOwned) {
          result.Error("capture_source_owned_by_another_session",
                       "The audio source belongs to another session.");
          return;
        }
        if (stop_result == WasapiCaptureStopResult::kPending) {
          result.Error(
              "audio_capture_stop_pending",
              "The audio source is still stopping. Retry after it finishes.");
          return;
        }
        result.Success(EncodableValue(true));
      } catch (...) {
        // Stop may join a native worker and publish its final state. Keep an
        // allocation or threading exception inside the plugin boundary rather
        // than unwinding through Flutter's MethodChannel callback.
        result.Error("audio_capture_stop_failed",
                     "The native audio source could not be stopped safely.");
      }
      return;
    }
    result.NotImplemented();
  }

  bool StartSource(const std::string& source_id,
                   const std::string& source_kind,
                   const std::string& session_id,
                   const std::string& attempt_id,
                   int64_t active_offset_us,
                   std::string* error_code,
                   std::string* error_message) {
    ReapRetiredWasapiLoopbackCaptures();
    if (dispatch_window_ == nullptr) {
      if (error_code) *error_code = "nativeInitializationFailed";
      if (error_message) *error_message = "The audio event dispatcher is unavailable.";
      return false;
    }
    auto found = captures_.find(source_id);
    if (found == captures_.end()) {
      const std::weak_ptr<EventDispatchState> weak_state =
          event_dispatch_state_;
      auto capture = std::make_unique<WasapiLoopbackCapture>(
          [weak_state](EncodableValue event, bool is_audio_frame) {
            const auto state = weak_state.lock();
            return state && EnqueueEvent(
                                state, std::move(event), is_audio_frame);
          });
      found = captures_.emplace(source_id, std::move(capture)).first;
    }
    return found->second->Start(source_id, source_kind, session_id, attempt_id,
                                active_offset_us, error_code, error_message);
  }

  WasapiCaptureStopResult StopSource(const std::string& source_id,
                                     const std::string& final_status,
                                     bool erase) {
    const auto found = captures_.find(source_id);
    if (found == captures_.end()) return WasapiCaptureStopResult::kStopped;
    const auto stop_result = found->second->Stop(final_status);
    if (erase && stop_result == WasapiCaptureStopResult::kStopped) {
      captures_.erase(found);
    }
    return stop_result;
  }

  WasapiCaptureStopResult StopSourceForSession(
      const std::string& source_id,
      const std::string& session_id,
      const std::string& final_status,
      bool erase) {
    const auto found = captures_.find(source_id);
    if (found == captures_.end()) return WasapiCaptureStopResult::kStopped;
    const auto stop_result = found->second->StopIfOwnedBySession(
        session_id, final_status, kCaptureStopWait);
    if (erase && stop_result == WasapiCaptureStopResult::kStopped) {
      captures_.erase(found);
    }
    return stop_result;
  }

  void StopAll(const std::string& final_status) {
    for (auto& capture : captures_) {
      StopAndRetireWasapiLoopbackCapture(
          capture.second, final_status, kCaptureStopWait);
    }
    captures_.clear();
  }

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink_;
  std::unordered_map<std::string, std::unique_ptr<WasapiLoopbackCapture>>
      captures_;
  std::shared_ptr<EventDispatchState> event_dispatch_state_ =
      std::make_shared<EventDispatchState>();
  HWND dispatch_window_ = nullptr;
};

}  // namespace

void RegisterWasapiAudioCapturePlugin(flutter::PluginRegistry* registry) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            registry->GetRegistrarForPlugin(
                                "WasapiAudioCapturePlugin"));
  registrar->AddPlugin(std::make_unique<WasapiAudioCapturePlugin>(registrar));
}
