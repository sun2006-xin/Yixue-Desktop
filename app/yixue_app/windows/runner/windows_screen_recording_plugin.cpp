#include "windows_screen_recording_plugin.h"
#include "recording_time_anchor.h"
#include "recording_publication_policy.h"
#include "recording_filename_policy.h"
#include "native_method_exception_boundary.h"
#include "screen_recording_operation_queue.h"
#include "supervisor_diagnostics.h"

#include <windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mfreadwrite.h>
#include <mftransform.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <deque>
#include <filesystem>
#include <future>
#include <iomanip>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "windowsapp.lib")

namespace {

using Microsoft::WRL::ComPtr;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::Capture::GraphicsCapturePicker;
using winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;

constexpr char kMethodChannelName[] =
    "com.yixue.yixue_app/ai_tongchuan/screen_recording";
constexpr uint32_t kFramePoolBufferCount = 3;
constexpr uint32_t kVideoFramesPerSecond = 30;
constexpr uint32_t kVideoBitrate = 6'000'000;
constexpr uint32_t kAudioSampleRate = 48'000;
constexpr uint32_t kAudioChannels = 2;
constexpr uint32_t kAudioBitsPerSample = 16;
constexpr uint32_t kAudioBitrate = 192'000;
constexpr int64_t kMfTimeUnitsPerSecond = 10'000'000;
constexpr size_t kMaximumAudioFrameBytes = 1024 * 1024;
constexpr size_t kMaximumWriterQueuePackets = 512;
constexpr size_t kMaximumQueuedVideoBytes = 96 * 1024 * 1024;
constexpr size_t kMaximumQueuedAudioBytes = 16 * 1024 * 1024;

template <typename Reply>
void DeliverScreenRecordingReply(
    const std::shared_ptr<yixue::runner::ScreenRecordingReplyGate>& gate,
    const std::shared_ptr<flutter::MethodResult<EncodableValue>>& result,
    Reply&& reply) {
  if (!gate || !result) return;
  gate->InvokeIfOpen([&] { std::forward<Reply>(reply)(*result); });
}

void Add(EncodableMap* map, const char* key, EncodableValue value) {
  map->emplace(EncodableValue(key), std::move(value));
}

void AddString(EncodableMap* map, const char* key, const std::string& value) {
  Add(map, key, EncodableValue(value));
}

std::optional<std::string> ReadString(const EncodableMap& map,
                                      const char* key) {
  const auto found = map.find(EncodableValue(key));
  if (found == map.end()) return std::nullopt;
  const auto* value = std::get_if<std::string>(&found->second);
  if (value == nullptr || value->empty()) return std::nullopt;
  return *value;
}

std::optional<int64_t> ReadInteger(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(key));
  if (found == map.end()) return std::nullopt;
  if (const auto* value = std::get_if<int32_t>(&found->second)) {
    return static_cast<int64_t>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  return std::nullopt;
}

std::optional<bool> ReadBoolean(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(key));
  if (found == map.end()) return std::nullopt;
  if (const auto* value = std::get_if<bool>(&found->second)) return *value;
  return std::nullopt;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                        value.data(),
                                        static_cast<int>(value.size()), nullptr,
                                        0);
  if (count <= 0) return {};
  std::wstring result(static_cast<size_t>(count), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          count) != count) {
    return {};
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                        value.data(),
                                        static_cast<int>(value.size()), nullptr,
                                        0, nullptr, nullptr);
  if (count <= 0) return {};
  std::string result(static_cast<size_t>(count), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), count,
                          nullptr, nullptr) != count) {
    return {};
  }
  return result;
}

uint16_t FloatToPcm16(float sample) {
  if (!std::isfinite(sample)) sample = 0.0f;
  sample = std::clamp(sample, -1.0f, 1.0f);
  const float scaled = sample < 0.0f ? sample * 32768.0f : sample * 32767.0f;
  const int32_t signed_sample = static_cast<int32_t>(std::lrint(scaled));
  return static_cast<uint16_t>(static_cast<int16_t>(signed_sample));
}

std::filesystem::path MakeRecordingPath(const std::string& directory_utf8,
                                        const std::string& session_id) {
  const std::wstring directory_wide = Utf8ToWide(directory_utf8);
  if (directory_wide.empty()) {
    throw std::invalid_argument("录屏保存目录不是有效的 UTF-8 路径。");
  }
  std::filesystem::path directory(directory_wide);
  if (!directory.is_absolute()) {
    throw std::invalid_argument("录屏目录必须是绝对路径。");
  }
  std::filesystem::create_directories(directory);
  const auto now = std::chrono::system_clock::now();
  const auto time = std::chrono::system_clock::to_time_t(now);
  std::tm local_time{};
  localtime_s(&local_time, &time);
  std::wostringstream filename;
  filename << L"screen-" << std::put_time(&local_time, L"%Y%m%d-%H%M%S");
  const auto session_token = yixue::runner::SessionIdFilenameToken(session_id);
  if (!session_token.empty()) filename << L"-" << session_token;
  filename << L"-" << GetCurrentProcessId() << L"-" << GetTickCount64()
           << L".partial.mp4";
  return directory / filename.str();
}

std::filesystem::path MakeCompletedRecordingPath(
    const std::filesystem::path& partial_path) {
  std::wstring filename = partial_path.filename().wstring();
  constexpr wchar_t kPartialSuffix[] = L".partial.mp4";
  const size_t suffix_length = _countof(kPartialSuffix) - 1;
  if (filename.size() < suffix_length ||
      filename.compare(filename.size() - suffix_length, suffix_length,
                       kPartialSuffix) != 0) {
    return {};
  }
  filename.replace(filename.size() - suffix_length, suffix_length, L".mp4");
  return partial_path.parent_path() / filename;
}

class ScreenRecordingEngine final
    : public std::enable_shared_from_this<ScreenRecordingEngine> {
 private:
  struct VideoPacket {
    std::vector<uint8_t> pixels;
    int64_t timestamp_100ns = 0;
    int64_t duration_100ns = 0;
  };

  struct AudioPacket {
    std::vector<uint8_t> float_pcm;
    uint32_t input_sample_offset = 0;
    uint32_t input_samples = 0;
    uint32_t input_rate = 0;
    uint32_t input_channels = 0;
    int64_t timestamp_100ns = 0;
  };

  using WriterPacket = std::variant<VideoPacket, AudioPacket>;

  struct WriterStartupResult {
    bool succeeded = false;
    std::string error;
  };

  class FrameCallbackLease final {
   public:
    explicit FrameCallbackLease(ScreenRecordingEngine* owner) noexcept
        : owner_(owner != nullptr && owner->BeginFrameCallback() ? owner : nullptr) {}
    ~FrameCallbackLease() {
      if (owner_ != nullptr) owner_->EndFrameCallback();
    }
    FrameCallbackLease(const FrameCallbackLease&) = delete;
    FrameCallbackLease& operator=(const FrameCallbackLease&) = delete;
    explicit operator bool() const noexcept { return owner_ != nullptr; }

   private:
    ScreenRecordingEngine* owner_ = nullptr;
  };

 public:
  EncodableMap Snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    EncodableMap result;
    AddString(&result, "status", status_);
    AddString(&result, "path", path_utf8_);
    AddString(&result, "message", message_);
    AddString(&result, "targetName", target_name_);
    AddString(&result, "audioSourceId", audio_source_id_);
    AddString(&result, "audioCaptureAttemptId", audio_capture_attempt_id_);
    Add(&result, "audioEnabled", EncodableValue(audio_enabled_));
    Add(&result, "videoWidth", EncodableValue(static_cast<int32_t>(video_width_)));
    Add(&result, "videoHeight", EncodableValue(static_cast<int32_t>(video_height_)));
    Add(&result, "framesWritten", EncodableValue(static_cast<int64_t>(frames_written_)));
    Add(&result, "audioFramesWritten", EncodableValue(static_cast<int64_t>(audio_frames_written_)));
    Add(&result, "droppedVideoFrames", EncodableValue(static_cast<int64_t>(
        dropped_video_frames_.load(std::memory_order_relaxed))));
    Add(&result, "durationUs", EncodableValue(duration_us_));
    return result;
  }

  void PickTarget(HWND owner_window) {
    if (owner_window == nullptr || !IsWindow(owner_window)) {
      SetFailure("窗口句柄无效，无法打开 Windows 录屏授权窗口。");
      return;
    }
    if (!GraphicsCaptureSession::IsSupported()) {
      SetFailure("当前 Windows 版本或图形设备不支持系统录屏。");
      return;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (status_ == "pickerOpen" || status_ == "starting" ||
          status_ == "recording" || status_ == "stopping" ||
          (status_ == "failed" && capture_resources_active_)) {
        message_ = "当前录屏操作尚未结束。";
        return;
      }
    }
    try {
      GraphicsCapturePicker picker;
      auto initialize_with_window = picker.as<IInitializeWithWindow>();
      winrt::check_hresult(initialize_with_window->Initialize(owner_window));
      uint64_t picker_generation = 0;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (status_ == "recording" || status_ == "starting" ||
            status_ == "stopping" ||
            (status_ == "failed" && capture_resources_active_)) {
          message_ = "当前录屏尚未结束。";
          return;
        }
        picker_generation = ++picker_generation_;
        status_ = "pickerOpen";
        message_.clear();
        target_ = nullptr;
      }
      const std::weak_ptr<ScreenRecordingEngine> weak = shared_from_this();
      picker.PickSingleItemAsync().Completed(
          [weak, picker_generation](const auto& operation,
                                   winrt::Windows::Foundation::AsyncStatus
                                      async_status) noexcept {
            const auto self = weak.lock();
            if (!self) return;
            yixue::runner::RunNativeOperationSafely(
                [&] {
                  try {
                    if (async_status !=
                        winrt::Windows::Foundation::AsyncStatus::Completed) {
                      self->SetPickerFailure(
                          picker_generation,
                          "Windows 系统录屏选择器已取消或无法完成。");
                      return;
                    }
                    auto selected = operation.GetResults();
                    std::lock_guard<std::mutex> lock(self->mutex_);
                    if (self->picker_generation_ != picker_generation ||
                        self->status_ != "pickerOpen") {
                      return;
                    }
                    if (!selected) {
                      self->status_ = "cancelled";
                      self->message_ = "已取消录屏目标选择。";
                      return;
                    }
                    self->target_ = selected;
                    const auto display_name = selected.DisplayName();
                    self->target_name_ = WideToUtf8(std::wstring(
                        display_name.c_str(), display_name.size()));
                    self->status_ = "targetSelected";
                    self->message_.clear();
                  } catch (const winrt::hresult_error& error) {
                    self->SetPickerFailure(
                        picker_generation,
                        "读取 Windows 录屏目标失败，HRESULT=" +
                            std::to_string(
                                static_cast<uint32_t>(error.code())));
                  } catch (...) {
                    self->SetPickerFailure(
                        picker_generation,
                        "读取 Windows 录屏目标时发生未知错误。");
                  }
                },
                [self, picker_generation](std::exception_ptr) noexcept {
                  yixue::runner::diagnostics::Log(
                      "screen_recording_picker_callback_exception",
                      ERROR_UNHANDLED_EXCEPTION);
                  try {
                    self->SetPickerFailure(picker_generation,
                                           "录屏选择器回调失败。");
                  } catch (...) {
                    yixue::runner::diagnostics::Log(
                        "screen_recording_picker_failure_report_exception",
                        ERROR_UNHANDLED_EXCEPTION);
                  }
                });
          });
    } catch (const winrt::hresult_error& error) {
      SetFailure("打开 Windows 录屏选择器失败，HRESULT=" +
                 std::to_string(static_cast<uint32_t>(error.code())));
    } catch (...) {
      SetFailure("打开 Windows 录屏选择器失败。");
    }
  }

  bool MarshalTargetForStart(ComPtr<IStream>* stream, std::string* error) const {
    if (stream == nullptr) {
      if (error) *error = "无法准备 Windows 录屏目标。";
      return false;
    }
    GraphicsCaptureItem selected{nullptr};
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (status_ != "targetSelected" || !target_) {
        if (error) *error = "请先使用 Windows 系统选择器选择屏幕或窗口。";
        return false;
      }
      selected = target_;
    }

    using CaptureItemInterface =
        winrt::Windows::Graphics::Capture::IGraphicsCaptureItem;
    const auto capture_item = selected.as<CaptureItemInterface>();
    const HRESULT result = CoMarshalInterThreadInterfaceInStream(
        winrt::guid_of<CaptureItemInterface>(),
        reinterpret_cast<IUnknown*>(winrt::get_abi(capture_item)),
        stream->ReleaseAndGetAddressOf());
    if (FAILED(result)) {
      if (error) {
        *error = "无法将录屏目标安全传递到后台线程，HRESULT=" +
                 std::to_string(static_cast<uint32_t>(result));
      }
      return false;
    }
    return true;
  }

  static GraphicsCaptureItem UnmarshalTargetForStart(ComPtr<IStream> stream) {
    using CaptureItemInterface =
        winrt::Windows::Graphics::Capture::IGraphicsCaptureItem;
    winrt::com_ptr<CaptureItemInterface> capture_item;
    const HRESULT result = CoGetInterfaceAndReleaseStream(
        stream.Detach(), winrt::guid_of<CaptureItemInterface>(),
        capture_item.put_void());
    winrt::check_hresult(result);
    return capture_item.as<GraphicsCaptureItem>();
  }

  bool Start(const EncodableMap& arguments,
             GraphicsCaptureItem selected,
             std::string* error) {
    const auto directory = ReadString(arguments, "recordingDirectory");
    const auto session_id = ReadString(arguments, "sessionId");
    const auto audio_source = ReadString(arguments, "audioSourceId");
    const auto audio_capture_attempt =
        ReadString(arguments, "audioCaptureAttemptId");
    const auto audio_timeline_start =
        ReadInteger(arguments, "audioTimelineStartQpc100ns");
    const auto retain_audio = ReadBoolean(arguments, "retainAudio").value_or(false);
    if (!directory || !session_id || session_id->size() > 160 ||
        (retain_audio &&
         (!audio_source || audio_source->empty() || !audio_capture_attempt ||
          audio_capture_attempt->empty() || audio_capture_attempt->size() > 160 ||
          !audio_timeline_start || *audio_timeline_start <= 0))) {
      if (error) *error = "录屏参数不完整；录音开启时还需指定音源、采集尝试和首帧 QPC 时间锚点。";
      return false;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (status_ != "targetSelected" || !target_) {
        if (error) *error = "请先使用 Windows 系统选择器选择屏幕或窗口。";
        return false;
      }
      if (session_id_ == *session_id && status_ == "recording") {
        if (error) *error = "当前录屏已经开始。";
        return false;
      }
      status_ = "starting";
      capture_resources_active_ = true;
      message_.clear();
      path_.clear();
      path_utf8_.clear();
      audio_enabled_ = retain_audio;
      audio_source_id_ = retain_audio ? *audio_source : std::string();
      audio_capture_attempt_id_ =
          retain_audio ? *audio_capture_attempt : std::string();
      audio_timeline_start_qpc_100ns_ =
          retain_audio ? *audio_timeline_start : 0;
      last_audio_enqueued_qpc_100ns_ = -1;
      audio_frames_written_ = 0;
      frames_written_ = 0;
      dropped_video_frames_.store(0, std::memory_order_relaxed);
      duration_us_ = 0;
      video_time_origin_100ns_ = -1;
      last_video_timestamp_100ns_ = -1;
      session_id_ = *session_id;
    }

    try {
      const auto file_path = MakeRecordingPath(*directory, *session_id);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        path_ = file_path;
        path_utf8_ = WideToUtf8(file_path.wstring());
      }
      const auto size = selected.Size();
      if (size.Width < 2 || size.Height < 2) {
        throw std::runtime_error("选择的录屏目标没有有效尺寸。");
      }
      const uint32_t output_width = static_cast<uint32_t>(size.Width) & ~1U;
      const uint32_t output_height = static_cast<uint32_t>(size.Height) & ~1U;
      capture_content_width_ = static_cast<uint32_t>(size.Width);
      capture_content_height_ = static_cast<uint32_t>(size.Height);
      {
        std::lock_guard<std::mutex> callback_lock(frame_callback_mutex_);
        capture_stopping_ = false;
      }
      if (!StartWriterThread(file_path, output_width, output_height,
                             retain_audio, error)) {
        throw std::runtime_error(error && !error->empty()
                                     ? *error
                                     : "无法初始化 MP4 编码器。");
      }
      if (!InitializeGraphicsDevice(error)) {
        throw std::runtime_error(error && !error->empty()
                                     ? *error
                                     : "无法初始化图形捕获设备。");
      }

      frame_pool_ = Direct3D11CaptureFramePool::CreateFreeThreaded(
          capture_device_, DirectXPixelFormat::B8G8R8A8UIntNormalized,
          static_cast<int32_t>(kFramePoolBufferCount), size);
      const std::weak_ptr<ScreenRecordingEngine> weak = shared_from_this();
      frame_arrived_token_ = frame_pool_.FrameArrived(
          [weak](const Direct3D11CaptureFramePool& sender,
                 const winrt::Windows::Foundation::IInspectable&) noexcept {
            if (const auto self = weak.lock()) self->OnFrameArrived(sender);
          });
      capture_session_ = frame_pool_.CreateCaptureSession(selected);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (status_ == "starting") status_ = "recording";
        video_width_ = output_width;
        video_height_ = output_height;
        target_ = selected;
        message_.clear();
      }
      capture_session_.StartCapture();
      return true;
    } catch (const winrt::hresult_error& exception) {
      const std::string message =
          "启动 Windows 录屏失败，HRESULT=" +
          std::to_string(static_cast<uint32_t>(exception.code()));
      if (error) *error = message;
      FailAndRelease(message);
      return false;
    } catch (const std::exception& exception) {
      const std::string message = exception.what();
      if (error) *error = message;
      FailAndRelease(message);
      return false;
    } catch (...) {
      const std::string message = "启动 Windows 录屏失败。";
      if (error) *error = message;
      FailAndRelease(message);
      return false;
    }
  }

  bool WriteAudioFrames(const EncodableList& frames, std::string* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (status_ != "recording" || !audio_enabled_) {
      if (error) *error = "当前录屏没有启用可写入的视频音轨。";
      return false;
    }
    for (const auto& raw_frame : frames) {
      const auto* frame = std::get_if<EncodableMap>(&raw_frame);
      if (frame == nullptr) {
        if (error) *error = "音频帧格式无效。";
        return false;
      }
      const auto frame_session_id = ReadString(*frame, "sessionId");
      const auto source_id = ReadString(*frame, "sourceId");
      const auto capture_attempt_id = ReadString(*frame, "captureAttemptId");
      const auto qpc_time_100ns = ReadInteger(*frame, "qpcTime100ns");
      const auto sample_rate = ReadInteger(*frame, "sampleRateHz");
      const auto channels = ReadInteger(*frame, "channelCount");
      const auto sample_count = ReadInteger(*frame, "sampleCount");
      const auto format = ReadString(*frame, "sampleFormat");
      const auto bytes_value = frame->find(EncodableValue("pcmBytes"));
      if (!frame_session_id || !source_id || !capture_attempt_id ||
          !IsMatchingAudioCaptureIdentity(
              *frame_session_id, *source_id, *capture_attempt_id, session_id_,
              audio_source_id_, audio_capture_attempt_id_)) {
        continue;
      }
      if (!qpc_time_100ns || *qpc_time_100ns <= 0) {
        const std::string message = "音频帧缺少有效 QPC 时间戳，已停止 MP4 音轨写入。";
        SetFailureLocked(message);
        if (error) *error = message;
        return false;
      }
      if (!sample_rate || *sample_rate < 8'000 || *sample_rate > 192'000 ||
          !channels || *channels < 1 || *channels > 8 || !sample_count ||
          *sample_count < 1 || *sample_count > 48'000 || !format ||
          *format != "float32LittleEndian" || bytes_value == frame->end()) {
        const std::string message = "音频帧格式或采样参数无效。";
        SetFailureLocked(message);
        if (error) *error = message;
        return false;
      }
      const auto* pcm_bytes =
          std::get_if<std::vector<uint8_t>>(&bytes_value->second);
      const uint64_t expected_bytes = static_cast<uint64_t>(*sample_count) *
                                      static_cast<uint64_t>(*channels) * sizeof(float);
      if (pcm_bytes == nullptr || pcm_bytes->size() != expected_bytes ||
          pcm_bytes->size() > kMaximumAudioFrameBytes) {
        const std::string message = "音频帧 PCM 数据长度不匹配。";
        SetFailureLocked(message);
        if (error) *error = message;
        return false;
      }
      if (!IsQpcAtOrAfterRecordingOrigin(
              *qpc_time_100ns, audio_timeline_start_qpc_100ns_)) {
        const std::string message = "音频帧 QPC 早于 MP4 时间原点。";
        SetFailureLocked(message);
        if (error) *error = message;
        return false;
      }
      if (last_audio_enqueued_qpc_100ns_ >= 0 &&
          *qpc_time_100ns <= last_audio_enqueued_qpc_100ns_) {
        const std::string message = "音频帧 QPC 时间倒退或重复，已停止 MP4 音轨写入。";
        SetFailureLocked(message);
        if (error) *error = message;
        return false;
      }
      const uint64_t output_samples64 =
          (static_cast<uint64_t>(*sample_count) * kAudioSampleRate +
           static_cast<uint32_t>(*sample_rate) / 2) /
          static_cast<uint32_t>(*sample_rate);
      if (output_samples64 == 0 || output_samples64 > kAudioSampleRate * 6ULL) {
        const std::string message = "音频帧时长超过 MP4 编码器支持范围。";
        SetFailureLocked(message);
        if (error) *error = message;
        return false;
      }

      AudioPacket packet;
      packet.float_pcm = *pcm_bytes;
      packet.input_sample_offset = 0;
      packet.input_samples = static_cast<uint32_t>(*sample_count);
      packet.input_rate = static_cast<uint32_t>(*sample_rate);
      packet.input_channels = static_cast<uint32_t>(*channels);
      packet.timestamp_100ns =
          *qpc_time_100ns - audio_timeline_start_qpc_100ns_;
      if (!EnqueueAudioPacket(std::move(packet))) {
        const std::string message = "录屏音轨队列已满或编码器已停止。";
        SetFailureLocked(message);
        if (error) *error = message;
        return false;
      }
      last_audio_enqueued_qpc_100ns_ = *qpc_time_100ns;
    }
    return true;
  }

  bool Stop(std::string* error, bool preserve_partial = false,
            std::string failure_message = {}) {
    std::lock_guard<std::mutex> stop_lock(stop_mutex_);
    bool preserve_failure = false;
    std::string existing_message;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (status_ == "pickerOpen" || status_ == "targetSelected") {
        status_ = "cancelled";
        message_ = "已取消录屏。";
        capture_resources_active_ = false;
        ++picker_generation_;
        target_ = nullptr;
        return true;
      }
      if (status_ != "recording" && status_ != "starting" &&
          status_ != "failed" && status_ != "stopping") {
        return status_ == "stopped" || status_ == "idle" || status_ == "cancelled";
      }
      if (preserve_partial && status_ != "failed") {
        SetFailureLocked(
            failure_message.empty()
                ? "录屏音轨完整性检查失败；未完成文件已保留。"
                : failure_message);
      }
      preserve_failure = status_ == "failed";
      existing_message = message_;
      status_ = "stopping";
    }

    std::string capture_error;
    const bool capture_stopped = StopCaptureAndWait(&capture_error);
    std::string writer_error;
    const bool writer_stopped = StopWriterThread(&writer_error);
    ResetGraphicsResources();

    std::filesystem::path partial_path;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!capture_stopped || !writer_stopped) {
        const std::string failure = !writer_stopped && !writer_error.empty()
                                        ? writer_error
                                        : (!capture_error.empty()
                                               ? capture_error
                                               : "停止录屏时发生未知错误。");
        SetFailureLocked(failure);
        capture_resources_active_ = !capture_stopped;
        if (error) *error = failure;
        return false;
      }
      if (preserve_failure || status_ == "failed") {
        const std::string recording_failure =
            !message_.empty() ? message_
                              : (existing_message.empty() ? "录屏此前已失败。"
                                                          : existing_message);
        SetFailureLocked(recording_failure);
        capture_resources_active_ = false;
        if (error) *error = message_;
        return true;
      }
      if (!yixue::runner::CanPublishScreenRecording(frames_written_)) {
        const std::string failure =
            "录屏期间没有成功写入视频画面；未完成文件已保留。";
        SetFailureLocked(failure);
        capture_resources_active_ = false;
        if (error) *error = failure;
        return false;
      }
      partial_path = path_;
    }

    const auto completed_path = MakeCompletedRecordingPath(partial_path);
    if (partial_path.empty() || completed_path.empty()) {
      const std::string failure = "录屏文件缺少未完成标记，无法安全发布。";
      std::lock_guard<std::mutex> lock(mutex_);
      SetFailureLocked(failure);
      capture_resources_active_ = false;
      if (error) *error = failure;
      return false;
    }
    std::error_code publish_error;
    std::filesystem::rename(partial_path, completed_path, publish_error);
    if (publish_error) {
      const std::string failure =
          "录屏已收尾，但无法将文件标记为正式成品；未完成文件已保留。";
      std::lock_guard<std::mutex> lock(mutex_);
      SetFailureLocked(failure);
      capture_resources_active_ = false;
      if (error) *error = failure;
      return false;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    path_ = completed_path;
    path_utf8_ = WideToUtf8(completed_path.wstring());
    status_ = "stopped";
    capture_resources_active_ = false;
    message_.clear();
    return true;
  }

  void Shutdown() {
    std::string ignored;
    Stop(&ignored);
    StopWriterThread(&ignored);
    StopCaptureAndWait(&ignored);
  }

 private:
  static constexpr DWORD kInvalidStreamIndex = std::numeric_limits<DWORD>::max();

  void SetFailure(const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex_);
    SetFailureLocked(message);
  }

  void SetCaptureFailure(const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (status_ != "failed") SetFailureLocked(message);
  }

  void SetPickerFailure(uint64_t generation, const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (picker_generation_ == generation && status_ == "pickerOpen") {
      SetFailureLocked(message);
    }
  }

  void SetFailureLocked(const std::string& message) {
    status_ = "failed";
    message_ = message;
  }

  bool StartWriterThread(const std::filesystem::path& path,
                         uint32_t width,
                         uint32_t height,
                         bool audio_enabled,
                         std::string* error) {
    if (writer_thread_.joinable()) {
      if (error) *error = "上一个 MP4 编码线程尚未结束。";
      return false;
    }
    {
      std::lock_guard<std::mutex> lock(writer_queue_mutex_);
      writer_queue_.clear();
      queued_video_bytes_ = 0;
      queued_audio_bytes_ = 0;
      writer_accepting_packets_ = false;
      writer_stop_requested_ = false;
      writer_failed_ = false;
      writer_error_message_.clear();
    }

    std::promise<WriterStartupResult> startup_promise;
    auto startup_future = startup_promise.get_future();
    writer_thread_ = std::thread(
        [this, path, width, height, audio_enabled,
         startup_promise = std::move(startup_promise)]() mutable {
          bool startup_reported = false;
          bool apartment_initialized = false;
          const auto report_startup = [&](WriterStartupResult result) {
            if (startup_reported) return;
            startup_reported = true;
            startup_promise.set_value(std::move(result));
          };

          try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            apartment_initialized = true;
          } catch (const winrt::hresult_error& exception) {
            const std::string message = "初始化录屏 MTA 编码线程失败，HRESULT=" +
                std::to_string(static_cast<uint32_t>(exception.code()));
            RecordWriterFailure(message);
            report_startup({false, message});
          } catch (...) {
            const std::string message = "初始化录屏 MTA 编码线程失败。";
            RecordWriterFailure(message);
            report_startup({false, message});
          }

          if (apartment_initialized) {
            std::string initialization_error;
            bool initialized = false;
            try {
              initialized = InitializeMediaFoundation(
                  path, width, height, audio_enabled, &initialization_error);
            } catch (const winrt::hresult_error& exception) {
              initialization_error = "初始化 MP4 编码器失败，HRESULT=" +
                  std::to_string(static_cast<uint32_t>(exception.code()));
            } catch (...) {
              initialization_error = "初始化 MP4 编码器时发生未知错误。";
            }

            if (!initialized) {
              if (initialization_error.empty()) {
                initialization_error = "无法初始化 MP4 编码器。";
              }
              RecordWriterFailure(initialization_error);
              CleanupWriterOnCurrentThread(false);
              report_startup({false, initialization_error});
            } else {
              {
                std::lock_guard<std::mutex> lock(writer_queue_mutex_);
                writer_accepting_packets_ = true;
              }
              report_startup({true, {}});
              try {
                WriterWorkerLoop();
              } catch (const winrt::hresult_error& exception) {
                RecordWriterFailure(
                    "Media Foundation 编码线程失败，HRESULT=" +
                    std::to_string(static_cast<uint32_t>(exception.code())));
              } catch (...) {
                RecordWriterFailure("Media Foundation 编码线程发生未知错误。");
              }
              CleanupWriterOnCurrentThread(true);
            }
            winrt::uninit_apartment();
          }
        });

    const WriterStartupResult result = startup_future.get();
    if (!result.succeeded) {
      {
        std::lock_guard<std::mutex> lock(writer_queue_mutex_);
        writer_accepting_packets_ = false;
        writer_stop_requested_ = true;
      }
      writer_queue_condition_.notify_all();
      if (writer_thread_.joinable()) writer_thread_.join();
      if (error) *error = result.error;
      return false;
    }
    return true;
  }

  void WriterWorkerLoop() {
    for (;;) {
      WriterPacket packet;
      {
        std::unique_lock<std::mutex> lock(writer_queue_mutex_);
        writer_queue_condition_.wait(lock, [this] {
          return writer_stop_requested_ || !writer_queue_.empty();
        });
        if (writer_queue_.empty() && writer_stop_requested_) break;
        packet = std::move(writer_queue_.front());
        writer_queue_.pop_front();
        if (const auto* video = std::get_if<VideoPacket>(&packet)) {
          queued_video_bytes_ -= video->pixels.size();
        } else if (const auto* audio = std::get_if<AudioPacket>(&packet)) {
          queued_audio_bytes_ -= audio->float_pcm.size();
        }
      }

      {
        std::lock_guard<std::mutex> lock(writer_queue_mutex_);
        if (writer_failed_) continue;
      }

      std::string write_error;
      bool succeeded = false;
      try {
        if (const auto* video = std::get_if<VideoPacket>(&packet)) {
          succeeded = WriteVideoSample(*video);
          if (!succeeded) write_error = "Media Foundation 写入视频样本失败。";
          if (succeeded) {
            std::lock_guard<std::mutex> lock(mutex_);
            ++frames_written_;
            duration_us_ = std::max<int64_t>(
                duration_us_, (video->timestamp_100ns +
                               video->duration_100ns) * 1'000'000 /
                                  kMfTimeUnitsPerSecond);
          }
        } else if (const auto* audio = std::get_if<AudioPacket>(&packet)) {
          succeeded = WritePcmAudioSample(
              audio->float_pcm, audio->input_sample_offset,
              audio->input_samples, audio->input_rate, audio->input_channels,
              audio->timestamp_100ns, &write_error);
        }
      } catch (const winrt::hresult_error& exception) {
        write_error = "Media Foundation 写入样本失败，HRESULT=" +
            std::to_string(static_cast<uint32_t>(exception.code()));
      } catch (...) {
        write_error = "Media Foundation 写入样本时发生未知错误。";
      }
      if (!succeeded) {
        if (write_error.empty()) write_error = "Media Foundation 写入样本失败。";
        RecordWriterFailure(write_error);
        {
          std::lock_guard<std::mutex> lock(writer_queue_mutex_);
          writer_queue_.clear();
          queued_video_bytes_ = 0;
          queued_audio_bytes_ = 0;
          writer_accepting_packets_ = false;
          writer_stop_requested_ = true;
        }
        writer_queue_condition_.notify_all();
      }
    }
  }

  void CleanupWriterOnCurrentThread(bool finalize) noexcept {
    if (writer_ != nullptr) {
      if (finalize) {
        const HRESULT result = writer_->Finalize();
        if (FAILED(result)) {
          RecordWriterFailure("MP4 文件收尾失败，HRESULT=" +
                              std::to_string(static_cast<uint32_t>(result)));
        }
      }
      writer_.Reset();
    }
    if (mf_started_) {
      MFShutdown();
      mf_started_ = false;
    }
    video_stream_index_ = kInvalidStreamIndex;
    audio_stream_index_ = kInvalidStreamIndex;
  }

  void RecordWriterFailure(const std::string& message) {
    {
      std::lock_guard<std::mutex> lock(writer_queue_mutex_);
      writer_failed_ = true;
      if (writer_error_message_.empty()) writer_error_message_ = message;
      writer_accepting_packets_ = false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    SetFailureLocked(message);
  }

  bool EnqueueAudioPacket(AudioPacket packet) {
    const size_t packet_bytes = packet.float_pcm.size();
    {
      std::lock_guard<std::mutex> lock(writer_queue_mutex_);
      if (!writer_accepting_packets_ || writer_failed_ ||
          writer_queue_.size() >= kMaximumWriterQueuePackets ||
          packet_bytes > kMaximumQueuedAudioBytes -
                             std::min(queued_audio_bytes_,
                                      kMaximumQueuedAudioBytes)) {
        return false;
      }
      queued_audio_bytes_ += packet_bytes;
      writer_queue_.emplace_back(std::move(packet));
    }
    writer_queue_condition_.notify_one();
    return true;
  }

  bool EnqueueVideoPacket(VideoPacket packet) {
    const size_t packet_bytes = packet.pixels.size();
    {
      std::lock_guard<std::mutex> lock(writer_queue_mutex_);
      if (!writer_accepting_packets_ || writer_failed_) return false;
      if (writer_queue_.size() >= kMaximumWriterQueuePackets ||
          packet_bytes > kMaximumQueuedVideoBytes -
                             std::min(queued_video_bytes_,
                                      kMaximumQueuedVideoBytes)) {
        dropped_video_frames_.fetch_add(1, std::memory_order_relaxed);
        return true;
      }
      queued_video_bytes_ += packet_bytes;
      writer_queue_.emplace_back(std::move(packet));
    }
    writer_queue_condition_.notify_one();
    return true;
  }

  bool StopWriterThread(std::string* error) {
    {
      std::lock_guard<std::mutex> lock(writer_queue_mutex_);
      writer_accepting_packets_ = false;
      writer_stop_requested_ = true;
    }
    writer_queue_condition_.notify_all();
    if (writer_thread_.joinable()) writer_thread_.join();
    std::lock_guard<std::mutex> lock(writer_queue_mutex_);
    if (writer_failed_) {
      if (error) {
        *error = writer_error_message_.empty() ? "MP4 编码线程失败。"
                                               : writer_error_message_;
      }
      return false;
    }
    return true;
  }

  bool BeginFrameCallback() noexcept {
    std::lock_guard<std::mutex> lock(frame_callback_mutex_);
    if (capture_stopping_) return false;
    ++active_frame_callbacks_;
    return true;
  }

  void EndFrameCallback() noexcept {
    {
      std::lock_guard<std::mutex> lock(frame_callback_mutex_);
      if (active_frame_callbacks_ > 0) --active_frame_callbacks_;
    }
    frame_callback_condition_.notify_all();
  }

  bool StopCaptureAndWait(std::string* error) {
    bool handler_removed = true;
    {
      std::lock_guard<std::mutex> lock(frame_callback_mutex_);
      capture_stopping_ = true;
    }
    try {
      if (frame_pool_) frame_pool_.FrameArrived(frame_arrived_token_);
    } catch (const winrt::hresult_error& exception) {
      handler_removed = false;
      if (error) {
        *error = "解除录屏帧回调失败，HRESULT=" +
                 std::to_string(static_cast<uint32_t>(exception.code()));
      }
    } catch (...) {
      handler_removed = false;
      if (error) *error = "解除录屏帧回调失败。";
    }
    {
      std::unique_lock<std::mutex> lock(frame_callback_mutex_);
      frame_callback_condition_.wait(lock, [this] {
        return active_frame_callbacks_ == 0;
      });
    }
    bool session_closed = true;
    try {
      if (capture_session_) {
        capture_session_.Close();
        capture_session_ = nullptr;
      }
    } catch (const winrt::hresult_error& exception) {
      session_closed = false;
      if (error && error->empty()) {
        *error = "关闭 Windows 录屏会话失败，HRESULT=" +
                 std::to_string(static_cast<uint32_t>(exception.code()));
      }
    } catch (...) {
      session_closed = false;
      if (error && error->empty()) *error = "关闭 Windows 录屏会话失败。";
    }

    bool frame_pool_closed = true;
    try {
      if (frame_pool_) {
        frame_pool_.Close();
        frame_pool_ = nullptr;
      }
    } catch (const winrt::hresult_error& exception) {
      frame_pool_closed = false;
      if (error && error->empty()) {
        *error = "关闭录屏帧池失败，HRESULT=" +
                 std::to_string(static_cast<uint32_t>(exception.code()));
      }
    } catch (...) {
      frame_pool_closed = false;
      if (error && error->empty()) *error = "关闭录屏帧池失败。";
    }
    return handler_removed && session_closed && frame_pool_closed;
  }

  void ResetGraphicsResources() noexcept {
    staging_texture_.Reset();
    d3d_context_.Reset();
    d3d_device_.Reset();
    capture_device_ = nullptr;
    staging_width_ = 0;
    staging_height_ = 0;
  }

  bool InitializeMediaFoundation(const std::filesystem::path& path,
                                 uint32_t width,
                                 uint32_t height,
                                 bool audio_enabled,
                                 std::string* error) {
    HRESULT result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(result)) {
      if (error) *error = "初始化 Media Foundation 失败，HRESULT=" +
                          std::to_string(static_cast<uint32_t>(result));
      return false;
    }
    mf_started_ = true;
    ComPtr<IMFAttributes> writer_attributes;
    result = MFCreateAttributes(writer_attributes.GetAddressOf(), 1);
    if (SUCCEEDED(result)) {
      result = writer_attributes->SetUINT32(
          MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    }
    if (SUCCEEDED(result)) {
      result = MFCreateSinkWriterFromURL(path.c_str(), nullptr,
                                         writer_attributes.Get(),
                                         writer_.GetAddressOf());
    }
    if (FAILED(result)) {
      if (error) *error = "创建 MP4 编码器失败，HRESULT=" +
                          std::to_string(static_cast<uint32_t>(result));
      return false;
    }
    writer_video_width_ = width;
    writer_video_height_ = height;
    ComPtr<IMFMediaType> output_video;
    result = MFCreateMediaType(output_video.GetAddressOf());
    if (SUCCEEDED(result)) result = output_video->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(result)) result = output_video->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    if (SUCCEEDED(result)) result = output_video->SetUINT32(MF_MT_AVG_BITRATE, kVideoBitrate);
    if (SUCCEEDED(result)) result = output_video->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (SUCCEEDED(result)) result = MFSetAttributeSize(output_video.Get(), MF_MT_FRAME_SIZE, width, height);
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(output_video.Get(), MF_MT_FRAME_RATE, kVideoFramesPerSecond, 1);
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(output_video.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (SUCCEEDED(result)) result = writer_->AddStream(output_video.Get(), &video_stream_index_);

    ComPtr<IMFMediaType> input_video;
    if (SUCCEEDED(result)) result = MFCreateMediaType(input_video.GetAddressOf());
    if (SUCCEEDED(result)) result = input_video->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(result)) result = input_video->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (SUCCEEDED(result)) result = input_video->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (SUCCEEDED(result)) result = MFSetAttributeSize(input_video.Get(), MF_MT_FRAME_SIZE, width, height);
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(input_video.Get(), MF_MT_FRAME_RATE, kVideoFramesPerSecond, 1);
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(input_video.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (SUCCEEDED(result)) result = input_video->SetUINT32(MF_MT_DEFAULT_STRIDE, width * 4);
    if (SUCCEEDED(result)) result = writer_->SetInputMediaType(video_stream_index_, input_video.Get(), nullptr);

    audio_stream_index_ = kInvalidStreamIndex;
    if (SUCCEEDED(result) && audio_enabled) {
      ComPtr<IMFMediaType> output_audio;
      result = MFCreateMediaType(output_audio.GetAddressOf());
      if (SUCCEEDED(result)) result = output_audio->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      if (SUCCEEDED(result)) result = output_audio->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
      if (SUCCEEDED(result)) result = output_audio->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kAudioChannels);
      if (SUCCEEDED(result)) result = output_audio->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAudioSampleRate);
      if (SUCCEEDED(result)) result = output_audio->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAudioBitrate / 8);
      if (SUCCEEDED(result)) result = output_audio->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kAudioBitsPerSample);
      if (SUCCEEDED(result)) result = writer_->AddStream(output_audio.Get(), &audio_stream_index_);

      ComPtr<IMFMediaType> input_audio;
      if (SUCCEEDED(result)) result = MFCreateMediaType(input_audio.GetAddressOf());
      if (SUCCEEDED(result)) result = input_audio->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      if (SUCCEEDED(result)) result = input_audio->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      if (SUCCEEDED(result)) result = input_audio->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kAudioChannels);
      if (SUCCEEDED(result)) result = input_audio->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAudioSampleRate);
      if (SUCCEEDED(result)) result = input_audio->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kAudioBitsPerSample);
      if (SUCCEEDED(result)) result = input_audio->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, kAudioChannels * kAudioBitsPerSample / 8);
      if (SUCCEEDED(result)) result = input_audio->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAudioSampleRate * kAudioChannels * kAudioBitsPerSample / 8);
      if (SUCCEEDED(result)) result = writer_->SetInputMediaType(audio_stream_index_, input_audio.Get(), nullptr);
    }
    if (SUCCEEDED(result)) result = writer_->BeginWriting();
    if (FAILED(result)) {
      if (error) *error = "配置 MP4 H.264/AAC 编码器失败，HRESULT=" +
                          std::to_string(static_cast<uint32_t>(result));
      return false;
    }
    return true;
  }

  bool InitializeGraphicsDevice(std::string* error) {
    constexpr D3D_FEATURE_LEVEL feature_levels[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL selected_level{};
    HRESULT result = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        feature_levels, static_cast<UINT>(std::size(feature_levels)),
        D3D11_SDK_VERSION, d3d_device_.GetAddressOf(), &selected_level,
        d3d_context_.GetAddressOf());
    if (result == E_INVALIDARG) {
      result = D3D11CreateDevice(
          nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
          D3D11_CREATE_DEVICE_BGRA_SUPPORT,
          feature_levels + 1, static_cast<UINT>(std::size(feature_levels) - 1),
          D3D11_SDK_VERSION, d3d_device_.GetAddressOf(), &selected_level,
          d3d_context_.GetAddressOf());
    }
    if (FAILED(result)) {
      result = D3D11CreateDevice(
          nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
          D3D11_CREATE_DEVICE_BGRA_SUPPORT,
          feature_levels + 1, static_cast<UINT>(std::size(feature_levels) - 1),
          D3D11_SDK_VERSION, d3d_device_.GetAddressOf(), &selected_level,
          d3d_context_.GetAddressOf());
    }
    if (FAILED(result)) {
      if (error) *error = "创建设备录屏所需的 Direct3D 设备失败，HRESULT=" +
                          std::to_string(static_cast<uint32_t>(result));
      return false;
    }
    ComPtr<IDXGIDevice> dxgi_device;
    result = d3d_device_.As(&dxgi_device);
    ComPtr<IInspectable> inspectable_device;
    if (SUCCEEDED(result)) {
      result = CreateDirect3D11DeviceFromDXGIDevice(
          dxgi_device.Get(), inspectable_device.GetAddressOf());
    }
    if (FAILED(result)) {
      if (error) *error = "连接 Windows 图形捕获设备失败，HRESULT=" +
                          std::to_string(static_cast<uint32_t>(result));
      return false;
    }
    winrt::copy_from_abi(capture_device_, inspectable_device.Get());
    return true;
  }

  void OnFrameArrived(const Direct3D11CaptureFramePool& sender) noexcept {
    FrameCallbackLease callback_lease(this);
    if (!callback_lease) return;
    try {
      std::lock_guard<std::mutex> frame_lock(frame_processing_mutex_);
      bool audio_enabled = false;
      int64_t audio_timeline_origin_100ns = 0;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (status_ != "recording") return;
        audio_enabled = audio_enabled_;
        audio_timeline_origin_100ns = audio_timeline_start_qpc_100ns_;
      }
      auto frame = sender.TryGetNextFrame();
      if (!frame) return;
      const auto content_size = frame.ContentSize();
      if (content_size.Width < 2 || content_size.Height < 2) return;
      const auto content_width = static_cast<uint32_t>(content_size.Width);
      const auto content_height = static_cast<uint32_t>(content_size.Height);
      // SystemRelativeTime is QPC-derived and exposed as 100 ns TimeSpan ticks,
      // matching the converted WASAPI QPC timestamps carried by audio frames.
      const int64_t frame_time_100ns = frame.SystemRelativeTime().count();
      if (frame_time_100ns <= 0) {
        if (audio_enabled) {
          SetCaptureFailure("视频帧缺少有效 QPC 时间戳，无法与音轨同步。");
        }
        return;
      }
      const bool size_changed = capture_content_width_ != content_width ||
                                capture_content_height_ != content_height;
      int64_t timestamp = 0;
      if (audio_enabled) {
        if (!IsQpcAtOrAfterRecordingOrigin(frame_time_100ns,
                                           audio_timeline_origin_100ns)) {
          SetCaptureFailure("视频帧 QPC 早于 MP4 音频时间原点。");
          return;
        }
        timestamp = frame_time_100ns - audio_timeline_origin_100ns;
      } else {
        if (video_time_origin_100ns_ < 0) {
          video_time_origin_100ns_ = frame_time_100ns;
        }
        timestamp = std::max<int64_t>(
            0, frame_time_100ns - video_time_origin_100ns_);
      }
      const int64_t nominal_duration = kMfTimeUnitsPerSecond / kVideoFramesPerSecond;
      if (last_video_timestamp_100ns_ >= 0) {
        if (timestamp <= last_video_timestamp_100ns_) {
          SetCaptureFailure("视频帧 QPC 时间倒退或重复。");
          return;
        }
        if (timestamp - last_video_timestamp_100ns_ < nominal_duration) {
          return;
        }
      }
      auto pixels = CopyVideoPixels(frame);
      if (!pixels) {
        SetCaptureFailure("复制录屏帧到 CPU 缓冲区失败。");
        return;
      }
      VideoPacket packet;
      packet.pixels = std::move(*pixels);
      packet.timestamp_100ns = timestamp;
      packet.duration_100ns = nominal_duration;
      if (!EnqueueVideoPacket(std::move(packet))) {
        SetCaptureFailure("MP4 编码线程已停止，无法接收录屏帧。");
        return;
      }
      last_video_timestamp_100ns_ = timestamp;
      if (size_changed) {
        capture_content_width_ = content_width;
        capture_content_height_ = content_height;
        frame.Close();
        sender.Recreate(capture_device_, DirectXPixelFormat::B8G8R8A8UIntNormalized,
                        static_cast<int32_t>(kFramePoolBufferCount), content_size);
      }
    } catch (const winrt::hresult_error& exception) {
      SetCaptureFailure("录屏帧处理失败，HRESULT=" +
                        std::to_string(static_cast<uint32_t>(exception.code())));
    } catch (...) {
      SetCaptureFailure("录屏帧处理发生未知错误。");
    }
  }

  std::optional<std::vector<uint8_t>> CopyVideoPixels(
      const Direct3D11CaptureFrame& frame) {
    auto surface = frame.Surface();
    ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>
        surface_access;
    HRESULT result = reinterpret_cast<IUnknown*>(winrt::get_abi(surface))
                         ->QueryInterface(IID_PPV_ARGS(surface_access.GetAddressOf()));
    ComPtr<ID3D11Texture2D> source_texture;
    if (SUCCEEDED(result)) {
      result = surface_access->GetInterface(IID_PPV_ARGS(source_texture.GetAddressOf()));
    }
    if (FAILED(result)) return std::nullopt;
    D3D11_TEXTURE2D_DESC source_desc{};
    source_texture->GetDesc(&source_desc);
    if (source_desc.Width == 0 || source_desc.Height == 0 ||
        source_desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) {
      return std::nullopt;
    }
    if (staging_texture_ == nullptr ||
        staging_width_ != source_desc.Width || staging_height_ != source_desc.Height) {
      staging_texture_.Reset();
      D3D11_TEXTURE2D_DESC staging_desc = source_desc;
      staging_desc.Usage = D3D11_USAGE_STAGING;
      staging_desc.BindFlags = 0;
      staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      staging_desc.MiscFlags = 0;
      result = d3d_device_->CreateTexture2D(&staging_desc, nullptr,
                                             staging_texture_.GetAddressOf());
      if (FAILED(result)) return std::nullopt;
      staging_width_ = source_desc.Width;
      staging_height_ = source_desc.Height;
    }
    if (video_width_ > std::numeric_limits<size_t>::max() / 4) {
      return std::nullopt;
    }
    const size_t output_stride = static_cast<size_t>(video_width_) * 4;
    if (video_height_ != 0 &&
        output_stride > std::numeric_limits<size_t>::max() / video_height_) {
      return std::nullopt;
    }
    const size_t output_bytes = output_stride * video_height_;
    if (output_bytes == 0 || output_bytes > std::numeric_limits<DWORD>::max()) {
      return std::nullopt;
    }
    std::vector<uint8_t> pixels(output_bytes, 0);
    const UINT copy_rows = std::min<UINT>(video_height_, source_desc.Height);
    const size_t copy_bytes =
        static_cast<size_t>(std::min<UINT>(video_width_, source_desc.Width)) * 4;

    d3d_context_->CopyResource(staging_texture_.Get(), source_texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    result = d3d_context_->Map(staging_texture_.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result)) return std::nullopt;
    if (mapped.pData == nullptr || mapped.RowPitch < copy_bytes) {
      d3d_context_->Unmap(staging_texture_.Get(), 0);
      return std::nullopt;
    }
    const auto* source_bytes = static_cast<const uint8_t*>(mapped.pData);
    for (UINT row = 0; row < copy_rows; ++row) {
      std::memcpy(pixels.data() + static_cast<size_t>(row) * output_stride,
                  source_bytes + static_cast<size_t>(row) * mapped.RowPitch,
                  copy_bytes);
    }
    d3d_context_->Unmap(staging_texture_.Get(), 0);

    return pixels;
  }

  bool WriteVideoSample(const VideoPacket& packet) {
    const size_t expected_bytes = static_cast<size_t>(writer_video_width_) *
                                  writer_video_height_ * 4;
    if (packet.pixels.size() != expected_bytes ||
        expected_bytes > std::numeric_limits<DWORD>::max()) {
      return false;
    }
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT result = MFCreateSample(sample.GetAddressOf());
    if (SUCCEEDED(result)) {
      result = MFCreateMemoryBuffer(static_cast<DWORD>(expected_bytes),
                                    buffer.GetAddressOf());
    }
    BYTE* target_bytes = nullptr;
    if (SUCCEEDED(result)) result = buffer->Lock(&target_bytes, nullptr, nullptr);
    if (SUCCEEDED(result) && target_bytes == nullptr) result = E_POINTER;
    if (SUCCEEDED(result)) {
      std::memcpy(target_bytes, packet.pixels.data(), expected_bytes);
      result = buffer->Unlock();
    }
    if (SUCCEEDED(result)) {
      result = buffer->SetCurrentLength(static_cast<DWORD>(expected_bytes));
    }
    if (SUCCEEDED(result)) result = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(result)) result = sample->SetSampleTime(packet.timestamp_100ns);
    if (SUCCEEDED(result)) result = sample->SetSampleDuration(packet.duration_100ns);
    if (SUCCEEDED(result)) result = writer_->WriteSample(video_stream_index_, sample.Get());
    return SUCCEEDED(result);
  }

  bool WritePcmAudioSample(const std::vector<uint8_t>& input,
                           uint32_t input_sample_offset,
                           uint32_t input_samples,
                           uint32_t input_rate,
                           uint32_t input_channels,
                           int64_t timestamp_100ns,
                           std::string* error) {
    const uint64_t output_samples64 =
        (static_cast<uint64_t>(input_samples) * kAudioSampleRate + input_rate / 2) /
        input_rate;
    if (output_samples64 == 0 || output_samples64 > kAudioSampleRate * 6ULL) {
      if (error) *error = "音频样本时长超过编码范围。";
      return false;
    }
    const uint32_t output_samples = static_cast<uint32_t>(output_samples64);
    const uint64_t output_size64 = static_cast<uint64_t>(output_samples) *
                                   kAudioChannels * sizeof(int16_t);
    if (output_size64 > std::numeric_limits<DWORD>::max()) return false;
    std::vector<uint8_t> output(static_cast<size_t>(output_size64));
    const auto read_sample = [&](uint32_t sample, uint32_t channel) {
      const size_t index = (static_cast<size_t>(sample + input_sample_offset) *
                            input_channels + channel) * sizeof(float);
      float value = 0.0f;
      std::memcpy(&value, input.data() + index, sizeof(value));
      return std::isfinite(value) ? value : 0.0f;
    };
    for (uint32_t output_index = 0; output_index < output_samples; ++output_index) {
      const uint64_t source_position_numerator =
          static_cast<uint64_t>(output_index) * input_rate;
      const uint32_t source_index = std::min<uint32_t>(
          input_samples - 1,
          static_cast<uint32_t>(source_position_numerator / kAudioSampleRate));
      const uint32_t next_source_index = std::min(input_samples - 1, source_index + 1);
      const float fraction = static_cast<float>(source_position_numerator % kAudioSampleRate) /
                             static_cast<float>(kAudioSampleRate);
      for (uint32_t channel = 0; channel < kAudioChannels; ++channel) {
        float first = 0.0f;
        float second = 0.0f;
        if (input_channels == 1) {
          first = read_sample(source_index, 0);
          second = read_sample(next_source_index, 0);
        } else {
          const uint32_t source_channel = std::min(channel, input_channels - 1);
          first = read_sample(source_index, source_channel);
          second = read_sample(next_source_index, source_channel);
        }
        const float mixed = first + (second - first) * fraction;
        const uint16_t pcm = FloatToPcm16(mixed);
        const size_t target_index =
            (static_cast<size_t>(output_index) * kAudioChannels + channel) * 2;
        output[target_index] = static_cast<uint8_t>(pcm & 0xff);
        output[target_index + 1] = static_cast<uint8_t>((pcm >> 8) & 0xff);
      }
    }
    const int64_t duration =
        static_cast<int64_t>(output_samples) * kMfTimeUnitsPerSecond / kAudioSampleRate;
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT result = MFCreateSample(sample.GetAddressOf());
    if (SUCCEEDED(result)) {
      result = MFCreateMemoryBuffer(static_cast<DWORD>(output.size()),
                                    buffer.GetAddressOf());
    }
    BYTE* target_bytes = nullptr;
    if (SUCCEEDED(result)) result = buffer->Lock(&target_bytes, nullptr, nullptr);
    if (SUCCEEDED(result) && target_bytes == nullptr) result = E_POINTER;
    if (SUCCEEDED(result)) {
      std::memcpy(target_bytes, output.data(), output.size());
      result = buffer->Unlock();
    }
    if (SUCCEEDED(result)) {
      result = buffer->SetCurrentLength(static_cast<DWORD>(output.size()));
    }
    if (SUCCEEDED(result)) result = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(result)) result = sample->SetSampleTime(timestamp_100ns);
    if (SUCCEEDED(result)) result = sample->SetSampleDuration(duration);
    if (SUCCEEDED(result)) result = writer_->WriteSample(audio_stream_index_, sample.Get());
    if (FAILED(result)) {
      if (error) *error = "Media Foundation 写入音频样本失败，HRESULT=" +
                          std::to_string(static_cast<uint32_t>(result));
      return false;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      ++audio_frames_written_;
      duration_us_ = std::max<int64_t>(
          duration_us_, (timestamp_100ns + duration) * 1'000'000 /
                            kMfTimeUnitsPerSecond);
    }
    return true;
  }

  void FailAndRelease(const std::string& message) {
    std::string ignored;
    const bool capture_stopped = StopCaptureAndWait(&ignored);
    std::string writer_error;
    StopWriterThread(&writer_error);
    ResetGraphicsResources();
    if (!path_.empty()) {
      std::error_code remove_error;
      (void)yixue::runner::RemoveFailedScreenRecordingFile(path_,
                                                          &remove_error);
    }
    std::lock_guard<std::mutex> lock(mutex_);
    SetFailureLocked(message);
    capture_resources_active_ = !capture_stopped;
  }

  mutable std::mutex mutex_;
  std::mutex stop_mutex_;
  std::string status_ = "idle";
  std::string message_;
  uint64_t picker_generation_ = 0;
  std::string session_id_;
  std::string audio_source_id_;
  std::string audio_capture_attempt_id_;
  std::string path_utf8_;
  std::filesystem::path path_;
  std::string target_name_;
  GraphicsCaptureItem target_{nullptr};
  bool audio_enabled_ = false;
  bool capture_resources_active_ = false;
  int64_t audio_timeline_start_qpc_100ns_ = 0;
  int64_t last_audio_enqueued_qpc_100ns_ = -1;
  int64_t video_time_origin_100ns_ = -1;
  int64_t last_video_timestamp_100ns_ = -1;
  int64_t duration_us_ = 0;
  uint32_t capture_content_width_ = 0;
  uint32_t capture_content_height_ = 0;
  uint32_t video_width_ = 0;
  uint32_t video_height_ = 0;
  uint32_t writer_video_width_ = 0;
  uint32_t writer_video_height_ = 0;
  uint32_t staging_width_ = 0;
  uint32_t staging_height_ = 0;
  uint64_t frames_written_ = 0;
  uint64_t audio_frames_written_ = 0;
  std::atomic<uint64_t> dropped_video_frames_{0};
  std::mutex frame_processing_mutex_;
  std::mutex frame_callback_mutex_;
  std::condition_variable frame_callback_condition_;
  size_t active_frame_callbacks_ = 0;
  bool capture_stopping_ = true;

  std::mutex writer_queue_mutex_;
  std::condition_variable writer_queue_condition_;
  std::deque<WriterPacket> writer_queue_;
  size_t queued_video_bytes_ = 0;
  size_t queued_audio_bytes_ = 0;
  bool writer_accepting_packets_ = false;
  bool writer_stop_requested_ = false;
  bool writer_failed_ = false;
  std::string writer_error_message_;
  std::thread writer_thread_;

  // The following Media Foundation state is created, used, finalized, and
  // released only by writer_thread_ while it is initialized as COM MTA.
  bool mf_started_ = false;
  DWORD video_stream_index_ = kInvalidStreamIndex;
  DWORD audio_stream_index_ = kInvalidStreamIndex;
  ComPtr<IMFSinkWriter> writer_;
  ComPtr<ID3D11Device> d3d_device_;
  ComPtr<ID3D11DeviceContext> d3d_context_;
  ComPtr<ID3D11Texture2D> staging_texture_;
  IDirect3DDevice capture_device_{nullptr};
  Direct3D11CaptureFramePool frame_pool_{nullptr};
  GraphicsCaptureSession capture_session_{nullptr};
  winrt::event_token frame_arrived_token_{};
};

class WindowsScreenRecordingPlugin final : public flutter::Plugin {
 public:
  WindowsScreenRecordingPlugin(flutter::PluginRegistrarWindows* registrar,
                               HWND owner_window,
                               std::shared_ptr<yixue::runner::ScreenRecordingReplyGate>
                                   reply_gate)
      : owner_window_(owner_window),
        reply_gate_(std::move(reply_gate)),
        engine_(std::make_shared<ScreenRecordingEngine>()),
        channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), kMethodChannelName,
            &flutter::StandardMethodCodec::GetInstance())) {
    const auto engine = engine_;
    operations_ = yixue::runner::ScreenRecordingOperationQueue::Create(
        [] { winrt::init_apartment(winrt::apartment_type::single_threaded); },
        [engine] {
          yixue::runner::diagnostics::Log(
              "screen_recording_engine_shutdown_begin");
          try {
            engine->Shutdown();
            yixue::runner::diagnostics::Log(
                "screen_recording_engine_shutdown_end");
          } catch (...) {
            yixue::runner::diagnostics::Log(
                "screen_recording_shutdown_exception", ERROR_GEN_FAILURE);
          }
          winrt::uninit_apartment();
        });
    if (!operations_) {
      yixue::runner::diagnostics::Log(
          "screen_recording_worker_unavailable", ERROR_NOT_ENOUGH_MEMORY);
    }
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      HandleMethodCall(call, std::move(result));
    });
  }

  ~WindowsScreenRecordingPlugin() override {
    yixue::runner::diagnostics::Log(
        "screen_recording_plugin_destroy_begin");
    if (reply_gate_) reply_gate_->CloseAndWait();
    if (channel_) channel_->SetMethodCallHandler(nullptr);
    if (operations_) {
      const auto shutdown_result = operations_->CloseAndJoinFor(
          std::chrono::seconds(10));
      if (shutdown_result ==
          yixue::runner::ScreenRecordingOperationQueue::ShutdownResult::
              kTimedOut) {
        yixue::runner::diagnostics::Log(
            "screen_recording_shutdown_wait_timed_out", ERROR_TIMEOUT);
      } else {
        yixue::runner::diagnostics::Log(
            "screen_recording_shutdown_joined");
      }
      operations_.reset();
    } else if (engine_) {
      // Recording cannot start without the worker. This fallback therefore
      // only releases an idle engine or cancels an unstarted picker.
      engine_->Shutdown();
    }
    engine_.reset();
    yixue::runner::diagnostics::Log("screen_recording_plugin_destroy_end");
  }

 private:
  static const EncodableMap* ReadArguments(
      const flutter::MethodCall<EncodableValue>& call) {
    if (call.arguments() == nullptr) return nullptr;
    return std::get_if<EncodableMap>(call.arguments());
  }

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!result) return;
    const auto& method = call.method_name();
    const bool log_operation = method == "pickTarget" ||
                               method == "startRecording" ||
                               method == "stopRecording";
    if (log_operation) {
      const char* event = method == "pickTarget"
                              ? "screen_recording_pick_target_begin"
                              : method == "startRecording"
                                    ? "screen_recording_start_begin"
                                    : "screen_recording_stop_begin";
      yixue::runner::diagnostics::Log(event);
    }
    yixue::runner::RunNativeOperationSafely(
        [&] { HandleMethodCallImpl(call, result); },
        [this, &result](std::exception_ptr exception) {
          try {
            std::rethrow_exception(exception);
          } catch (const winrt::hresult_error& error) {
            yixue::runner::diagnostics::Log(
                "screen_recording_method_hresult_exception",
                static_cast<DWORD>(error.code()));
            result->Error(
                "screen_recording_native_error",
                "Windows 录屏操作失败，译学仍可继续使用。 HRESULT=" +
                    std::to_string(static_cast<uint32_t>(error.code())));
          } catch (const std::exception&) {
            yixue::runner::diagnostics::Log(
                "screen_recording_method_exception",
                ERROR_UNHANDLED_EXCEPTION);
            result->Error("screen_recording_native_error",
                          "Windows 录屏操作失败，译学仍可继续使用。");
          } catch (...) {
            yixue::runner::diagnostics::Log(
                "screen_recording_method_exception",
                ERROR_UNHANDLED_EXCEPTION);
            result->Error("screen_recording_native_error",
                          "Windows 录屏操作失败，译学仍可继续使用。");
          }
        });
  }

  void HandleMethodCallImpl(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>>& result) {
    const EncodableMap* arguments = ReadArguments(call);
    if (call.method_name() == "pickTarget") {
      if (!operations_) {
        result->Error("screen_recording_worker_unavailable",
                      "Windows 录屏后台线程不可用，请重启译学后重试。");
        return;
      }
      engine_->PickTarget(owner_window_);
      yixue::runner::diagnostics::Log("screen_recording_picker_requested");
      result->Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "getState") {
      result->Success(EncodableValue(engine_->Snapshot()));
      return;
    }
    if (call.method_name() == "startRecording") {
      if (arguments == nullptr) {
        result->Error("invalid_screen_recording_request", "录屏参数缺失。");
        return;
      }
      if (!operations_) {
        result->Error("screen_recording_worker_unavailable",
                      "Windows 录屏后台线程不可用，请重启译学后重试。");
        return;
      }
      EncodableMap arguments_copy = *arguments;
      ComPtr<IStream> marshaled_target;
      std::string error;
      if (!engine_->MarshalTargetForStart(&marshaled_target, &error)) {
        result->Error("screen_recording_start_failed", error);
        return;
      }
      auto operation_result =
          std::shared_ptr<flutter::MethodResult<EncodableValue>>(
              std::move(result));
      yixue::runner::ScreenRecordingOperationQueue::Operation operation =
          [engine = engine_, reply_gate = reply_gate_, operation_result,
           arguments = std::move(arguments_copy),
           marshaled_target = std::move(marshaled_target)]() mutable {
            try {
              auto selected =
                  ScreenRecordingEngine::UnmarshalTargetForStart(
                      std::move(marshaled_target));
              std::string error;
              if (!engine->Start(arguments, std::move(selected), &error)) {
                yixue::runner::diagnostics::Log(
                    "screen_recording_start_rejected", ERROR_GEN_FAILURE);
                DeliverScreenRecordingReply(
                    reply_gate, operation_result, [&](auto& reply) {
                      reply.Error("screen_recording_start_failed", error);
                    });
                return;
              }
              yixue::runner::diagnostics::Log(
                  "screen_recording_start_succeeded");
              DeliverScreenRecordingReply(
                  reply_gate, operation_result, [&](auto& reply) {
                    reply.Success(EncodableValue(engine->Snapshot()));
                  });
            } catch (const winrt::hresult_error& error) {
              DeliverScreenRecordingReply(
                  reply_gate, operation_result, [&](auto& reply) {
                    reply.Error(
                        "screen_recording_start_failed",
                        "启动 Windows 录屏失败，HRESULT=" +
                            std::to_string(
                                static_cast<uint32_t>(error.code())));
                  });
            } catch (...) {
              DeliverScreenRecordingReply(
                  reply_gate, operation_result, [](auto& reply) {
                    reply.Error("screen_recording_start_failed",
                                "启动 Windows 录屏时发生未知错误。");
                  });
            }
          };
      if (!operations_->Post(operation)) {
        DeliverScreenRecordingReply(
            reply_gate_, operation_result, [](auto& reply) {
              reply.Error("screen_recording_worker_unavailable",
                          "Windows 录屏后台线程正在关闭，请重试。");
            });
      }
      return;
    }
    if (call.method_name() == "writeAudioFrames") {
      if (arguments == nullptr) {
        result->Error("invalid_screen_recording_audio", "音频帧参数缺失。");
        return;
      }
      const auto found = arguments->find(EncodableValue("frames"));
      if (found == arguments->end()) {
        result->Error("invalid_screen_recording_audio", "音频帧列表缺失。");
        return;
      }
      const auto* frames = std::get_if<EncodableList>(&found->second);
      if (frames == nullptr || frames->size() > 128) {
        result->Error("invalid_screen_recording_audio", "音频帧列表无效或过大。");
        return;
      }
      std::string error;
      if (!engine_->WriteAudioFrames(*frames, &error)) {
        result->Error("screen_recording_audio_write_failed", error);
        return;
      }
      result->Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "stopRecording") {
      if (!operations_) {
        result->Error("screen_recording_worker_unavailable",
                      "Windows 录屏后台线程不可用，请重启译学后重试。");
        return;
      }
      const EncodableMap* stop_arguments = ReadArguments(call);
      const bool preserve_partial =
          stop_arguments != nullptr &&
          ReadBoolean(*stop_arguments, "preservePartial").value_or(false);
      const std::string failure_message =
          stop_arguments == nullptr
              ? std::string()
              : ReadString(*stop_arguments, "failureMessage").value_or("");
      auto operation_result =
          std::shared_ptr<flutter::MethodResult<EncodableValue>>(
              std::move(result));
      yixue::runner::ScreenRecordingOperationQueue::Operation operation =
          [engine = engine_, reply_gate = reply_gate_, operation_result,
           preserve_partial, failure_message] {
            try {
              std::string error;
              if (!engine->Stop(&error, preserve_partial, failure_message)) {
                yixue::runner::diagnostics::Log(
                    "screen_recording_stop_failed", ERROR_GEN_FAILURE);
                DeliverScreenRecordingReply(
                    reply_gate, operation_result, [&](auto& reply) {
                      reply.Error("screen_recording_stop_failed", error);
                    });
                return;
              }
              yixue::runner::diagnostics::Log(
                  "screen_recording_stop_succeeded");
              DeliverScreenRecordingReply(
                  reply_gate, operation_result, [&](auto& reply) {
                    reply.Success(EncodableValue(engine->Snapshot()));
                  });
            } catch (const winrt::hresult_error& error) {
              DeliverScreenRecordingReply(
                  reply_gate, operation_result, [&](auto& reply) {
                    reply.Error(
                        "screen_recording_stop_failed",
                        "停止 Windows 录屏失败，HRESULT=" +
                            std::to_string(
                                static_cast<uint32_t>(error.code())));
                  });
            } catch (...) {
              DeliverScreenRecordingReply(
                  reply_gate, operation_result, [](auto& reply) {
                    reply.Error("screen_recording_stop_failed",
                                "停止 Windows 录屏时发生未知错误。");
                  });
            }
          };
      if (!operations_->Post(operation)) {
        DeliverScreenRecordingReply(
            reply_gate_, operation_result, [](auto& reply) {
              reply.Error("screen_recording_worker_unavailable",
                          "Windows 录屏后台线程正在关闭，请重试。");
            });
      }
      return;
    }
    result->NotImplemented();
  }

  HWND owner_window_ = nullptr;
  std::shared_ptr<yixue::runner::ScreenRecordingReplyGate> reply_gate_;
  std::shared_ptr<ScreenRecordingEngine> engine_;
  std::shared_ptr<yixue::runner::ScreenRecordingOperationQueue> operations_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
};

}  // namespace

void RegisterWindowsScreenRecordingPlugin(flutter::PluginRegistry* registry,
                                          HWND owner_window,
                                          std::shared_ptr<yixue::runner::ScreenRecordingReplyGate>
                                              reply_gate) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            registry->GetRegistrarForPlugin(
                                "WindowsScreenRecordingPlugin"));
  registrar->AddPlugin(std::make_unique<WindowsScreenRecordingPlugin>(
      registrar, owner_window, std::move(reply_gate)));
}
