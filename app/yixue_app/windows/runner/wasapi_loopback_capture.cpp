#include "wasapi_loopback_capture.h"

#include <windows.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <utility>
#include <vector>

#include "supervisor_diagnostics.h"

namespace {

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kSystemOutputSourceId[] = "windows-system-output";
constexpr char kMicrophoneSourcePrefix[] = "windows-microphone:";
constexpr size_t kMaximumFrameBytes = 256 * 1024;
constexpr uint64_t kMaximumFrameDurationUs = 100'000;
constexpr auto kNoSignalTimeout = std::chrono::seconds(4);
constexpr auto kPollInterval = std::chrono::milliseconds(5);
constexpr size_t kMaximumRetiredCaptureCount = 64;

struct RetiredCaptureRegistry {
  std::mutex mutex;
  std::array<std::unique_ptr<WasapiLoopbackCapture>,
             kMaximumRetiredCaptureCount> captures;
};

RetiredCaptureRegistry* GetRetiredCaptureRegistry() noexcept {
  static RetiredCaptureRegistry* registry =
      new (std::nothrow) RetiredCaptureRegistry();
  return registry;
}

void LogRetirementIssue(const char* event) noexcept {
  try {
    yixue::runner::diagnostics::Log(event);
  } catch (...) {
    // Retention must remain safe even when diagnostics cannot be written.
  }
}

int64_t SaturatingAddMicroseconds(int64_t base, uint64_t delta) {
  const int64_t maximum = std::numeric_limits<int64_t>::max();
  if (base >= maximum) {
    return maximum;
  }
  const uint64_t remaining = static_cast<uint64_t>(maximum - base);
  if (delta >= remaining) {
    return maximum;
  }
  return base + static_cast<int64_t>(delta);
}

class ComApartmentScope {
 public:
  ComApartmentScope() = default;
  ComApartmentScope(const ComApartmentScope&) = delete;
  ComApartmentScope& operator=(const ComApartmentScope&) = delete;
  ~ComApartmentScope() { CoUninitialize(); }
};

class AudioClientStartedScope {
 public:
  explicit AudioClientStartedScope(IAudioClient* audio_client)
      : audio_client_(audio_client) {}
  AudioClientStartedScope(const AudioClientStartedScope&) = delete;
  AudioClientStartedScope& operator=(const AudioClientStartedScope&) = delete;
  ~AudioClientStartedScope() {
    if (audio_client_ != nullptr) {
      audio_client_->Stop();
    }
  }

 private:
  IAudioClient* audio_client_;
};

class CaptureBufferScope {
 public:
  CaptureBufferScope(IAudioCaptureClient* capture_client,
                     UINT32 frame_count)
      : capture_client_(capture_client), frame_count_(frame_count) {}
  CaptureBufferScope(const CaptureBufferScope&) = delete;
  CaptureBufferScope& operator=(const CaptureBufferScope&) = delete;
  ~CaptureBufferScope() { Release(); }

  HRESULT Release() {
    if (capture_client_ == nullptr) {
      return S_OK;
    }
    IAudioCaptureClient* capture_client = capture_client_;
    capture_client_ = nullptr;
    return capture_client->ReleaseBuffer(frame_count_);
  }

 private:
  IAudioCaptureClient* capture_client_;
  UINT32 frame_count_;
};

EncodableValue MakeMap(EncodableMap value) {
  return EncodableValue(std::move(value));
}

void Add(EncodableMap* map, const char* key, EncodableValue value) {
  map->emplace(EncodableValue(key), std::move(value));
}

void AddString(EncodableMap* map, const char* key, const std::string& value) {
  Add(map, key, EncodableValue(value));
}

std::string ErrorCodeForHresult(HRESULT result) {
  if (result == E_ACCESSDENIED) {
    return "accessDenied";
  }
  if (result == AUDCLNT_E_UNSUPPORTED_FORMAT) {
    return "unsupportedFormat";
  }
  if (result == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED) {
    return "unsupportedMode";
  }
  if (result == AUDCLNT_E_DEVICE_INVALIDATED ||
      result == HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED)) {
    return "deviceDisconnected";
  }
  if (result == E_OUTOFMEMORY || result == CO_E_NOTINITIALIZED ||
      result == RPC_E_CHANGED_MODE) {
    return "nativeInitializationFailed";
  }
  return "streamFailure";
}

std::string StatusForErrorCode(const std::string& error_code) {
  if (error_code == "accessDenied") return "permissionDenied";
  if (error_code == "deviceUnavailable") return "deviceUnavailable";
  if (error_code == "deviceDisconnected") return "deviceDisconnected";
  return "failed";
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    return {};
  }
  return result;
}

bool IsFloatFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    return format->wBitsPerSample == 32;
  }
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    return extensible->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT &&
           format->wBitsPerSample == 32 &&
           extensible->Samples.wValidBitsPerSample == 32;
  }
  return false;
}

bool IsPcmFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_PCM) {
    return true;
  }
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    return extensible->SubFormat == KSDATAFORMAT_SUBTYPE_PCM;
  }
  return false;
}

uint16_t ValidBitsPerSample(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    return extensible->Samples.wValidBitsPerSample;
  }
  return format->wBitsPerSample;
}

bool IsSupportedFormat(const WAVEFORMATEX* format) {
  if (format == nullptr || format->nSamplesPerSec < 8'000 ||
      format->nSamplesPerSec > 384'000 || format->nChannels == 0 ||
      format->nChannels > 32 || format->nBlockAlign == 0) {
    return false;
  }
  if (IsFloatFormat(format)) {
    return static_cast<size_t>(format->nBlockAlign) >=
           static_cast<size_t>(format->nChannels) * sizeof(float);
  }
  if (!IsPcmFormat(format)) {
    return false;
  }
  const uint16_t container_bits = format->wBitsPerSample;
  const uint16_t valid_bits = ValidBitsPerSample(format);
  return (container_bits == 8 || container_bits == 16 || container_bits == 24 ||
          container_bits == 32) &&
         valid_bits > 0 && valid_bits <= container_bits &&
         static_cast<size_t>(format->nBlockAlign) >=
             static_cast<size_t>(format->nChannels) * (container_bits / 8);
}

std::optional<uint32_t> ChannelMaskFor(const WAVEFORMATEX* format) {
  if (format == nullptr || format->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
      format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    return std::nullopt;
  }

  const auto* extensible =
      reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
  const uint32_t channel_mask = extensible->dwChannelMask;
  if (channel_mask == 0) {
    return std::nullopt;
  }

  uint32_t remaining_bits = channel_mask;
  uint16_t speaker_count = 0;
  while (remaining_bits != 0) {
    speaker_count += static_cast<uint16_t>(remaining_bits & 1U);
    remaining_bits >>= 1U;
  }
  if (speaker_count != format->nChannels) {
    return std::nullopt;
  }
  return channel_mask;
}

float DecodePcmSample(const uint8_t* sample,
                      uint16_t container_bits,
                      uint16_t valid_bits) {
  if (container_bits == 8) {
    return (static_cast<float>(sample[0]) - 128.0f) / 128.0f;
  }

  int64_t value = 0;
  if (container_bits == 16) {
    int16_t signed_value = 0;
    std::memcpy(&signed_value, sample, sizeof(signed_value));
    value = signed_value;
  } else if (container_bits == 24) {
    int32_t signed_value = static_cast<int32_t>(sample[0]) |
                           (static_cast<int32_t>(sample[1]) << 8) |
                           (static_cast<int32_t>(sample[2]) << 16);
    if ((signed_value & 0x00800000) != 0) {
      signed_value |= static_cast<int32_t>(0xff000000);
    }
    value = signed_value;
  } else {
    int32_t signed_value = 0;
    std::memcpy(&signed_value, sample, sizeof(signed_value));
    value = signed_value;
  }
  if (valid_bits < container_bits) {
    value >>= container_bits - valid_bits;
  }
  return static_cast<float>(value) /
         static_cast<float>(uint64_t{1} << (valid_bits - 1));
}

bool ConvertPacketChunk(const BYTE* source,
                        uint32_t packet_frame_offset,
                        uint32_t frame_count,
                        const WAVEFORMATEX* format,
                        std::vector<uint8_t>* destination) {
  if (source == nullptr || destination == nullptr || frame_count == 0) {
    return false;
  }
  const size_t channel_count = format->nChannels;
  const size_t output_size =
      static_cast<size_t>(frame_count) * channel_count * sizeof(float);
  if (output_size > kMaximumFrameBytes) {
    return false;
  }
  destination->resize(output_size);

  const size_t container_bytes = format->wBitsPerSample / 8;
  const uint16_t valid_bits = ValidBitsPerSample(format);
  const bool input_is_float = IsFloatFormat(format);
  for (uint32_t frame = 0; frame < frame_count; ++frame) {
    const BYTE* input_frame =
        source + static_cast<size_t>(packet_frame_offset + frame) *
                     format->nBlockAlign;
    for (size_t channel = 0; channel < channel_count; ++channel) {
      float sample = 0.0f;
      const BYTE* input = input_frame + channel * container_bytes;
      if (input_is_float) {
        std::memcpy(&sample, input, sizeof(sample));
        if (!std::isfinite(sample)) {
          sample = 0.0f;
        }
      } else {
        sample = DecodePcmSample(input, format->wBitsPerSample, valid_bits);
      }
      const size_t output_index =
          (static_cast<size_t>(frame) * channel_count + channel) *
          sizeof(float);
      std::memcpy(destination->data() + output_index, &sample, sizeof(sample));
    }
  }
  return true;
}

}  // namespace

WasapiLoopbackCapture::WasapiLoopbackCapture(EventCallback event_callback)
    : event_callback_gate_(std::move(event_callback)) {}

WasapiLoopbackCapture::~WasapiLoopbackCapture() noexcept {
  try {
    if (Stop("") == WasapiCaptureStopResult::kPending) {
      std::unique_lock<std::mutex> lifecycle_lock(lifecycle_mutex_);
      stop_requested_.store(true);
      worker_completion_.Wait();
      if (worker_.joinable()) worker_.join();
      running_.store(false);
    }
  } catch (...) {
    // A native event/reporting failure during teardown must not escape an
    // implicitly noexcept destructor and terminate the desktop process.
  }
}

void RetireWasapiLoopbackCapture(
    std::unique_ptr<WasapiLoopbackCapture> capture) noexcept {
  if (!capture) return;

  try {
    capture->DisableEventCallback();
  } catch (...) {
    // A capture worker may still be using this object. Leak it intentionally
    // rather than running its destructor while the worker is pending.
    capture.release();
    LogRetirementIssue("wasapi_capture_callback_disable_failed");
    return;
  }

  auto* registry = GetRetiredCaptureRegistry();
  if (registry == nullptr) {
    capture.release();
    LogRetirementIssue("wasapi_capture_retirement_registry_unavailable");
    return;
  }

  try {
    std::lock_guard<std::mutex> lock(registry->mutex);
    for (auto& slot : registry->captures) {
      if (slot != nullptr) continue;
      slot = std::move(capture);
      return;
    }
  } catch (...) {
    capture.release();
    LogRetirementIssue("wasapi_capture_retirement_registry_failed");
    return;
  }

  // The bounded registry is full. Preserve the raw owner until process exit;
  // destroying it would leave a live worker with a dangling `this` pointer.
  capture.release();
  LogRetirementIssue("wasapi_capture_retirement_registry_full");
}

void ReapRetiredWasapiLoopbackCaptures() noexcept {
  auto* registry = GetRetiredCaptureRegistry();
  if (registry == nullptr) return;

  std::array<std::unique_ptr<WasapiLoopbackCapture>,
             kMaximumRetiredCaptureCount> finished;
  size_t finished_count = 0;
  try {
    std::lock_guard<std::mutex> lock(registry->mutex);
    for (auto& slot : registry->captures) {
      if (!slot) continue;
      try {
        if (slot->Stop("", std::chrono::milliseconds::zero()) !=
            WasapiCaptureStopResult::kStopped) {
          continue;
        }
        finished[finished_count++] = std::move(slot);
      } catch (...) {
        // Leave a capture in the registry if stop reporting unexpectedly
        // fails; its owner must continue to outlive the worker.
      }
    }
  } catch (...) {
    LogRetirementIssue("wasapi_capture_retirement_reap_failed");
    return;
  }
  // Destruction happens after the worker has joined and outside the registry
  // lock, so it cannot block another capture's retirement.
  for (size_t index = 0; index < finished_count; ++index) {
    finished[index].reset();
  }
}

WasapiCaptureStopResult StopAndRetireWasapiLoopbackCapture(
    std::unique_ptr<WasapiLoopbackCapture>& capture,
    const std::string& final_status,
    std::chrono::milliseconds timeout) noexcept {
  try {
    return yixue::runner::StopOrRetireWasapiCapture(
        capture, final_status, timeout,
        [](std::unique_ptr<WasapiLoopbackCapture> pending) {
          RetireWasapiLoopbackCapture(std::move(pending));
        });
  } catch (...) {
    RetireWasapiLoopbackCapture(std::move(capture));
    return WasapiCaptureStopResult::kPending;
  }
}

bool WasapiLoopbackCapture::Start(const std::string& source_id,
                                  const std::string& source_kind,
                                  const std::string& session_id,
                                  const std::string& capture_attempt_id,
                                  int64_t active_capture_offset_us,
                                  std::string* error_code,
                                  std::string* error_message) {
  std::unique_lock<std::mutex> lifecycle_lock(lifecycle_mutex_);
  const bool is_system_output = source_kind == "systemOutput" &&
                                source_id == kSystemOutputSourceId;
  const bool is_microphone = source_kind == "microphone" &&
                            source_id.rfind(kMicrophoneSourcePrefix, 0) == 0 &&
                            source_id.size() > sizeof(kMicrophoneSourcePrefix) - 1;
  if (!is_system_output && !is_microphone) {
    if (error_code) *error_code = "deviceUnavailable";
    if (error_message) *error_message = "The selected audio source is invalid.";
    return false;
  }
  if (session_id.empty() || capture_attempt_id.empty()) {
    if (error_code) *error_code = "unknown";
    if (error_message) *error_message = "Capture identity fields must not be empty.";
    return false;
  }
  if (active_capture_offset_us < 0) {
    if (error_code) *error_code = "unknown";
    if (error_message) *error_message = "The active capture offset is invalid.";
    return false;
  }
  if (active_capture_offset_us >
      std::numeric_limits<int64_t>::max() / 2) {
    if (error_code) *error_code = "unknown";
    if (error_message) *error_message = "The active capture offset is too large.";
    return false;
  }
  // The plugin registry is keyed by sourceId, so a paused capture entry can
  // outlive its worker. Do not let a different session take that entry over.
  if (!identity_.session_id.empty() && identity_.session_id != session_id) {
    if (error_code) *error_code = "captureSourceOwnedByAnotherSession";
    if (error_message) {
      *error_message = "The selected audio source belongs to another session.";
    }
    return false;
  }
  if (running_.load()) {
    if (error_code) *error_code = "streamFailure";
    if (error_message) *error_message = "A capture attempt is already running.";
    return false;
  }
  if (worker_.joinable()) {
    if (!worker_completion_.TryJoin(
            worker_, std::chrono::milliseconds::zero())) {
      if (error_code) *error_code = "audioCaptureStopPending";
      if (error_message) {
        *error_message = "The previous audio capture is still stopping.";
      }
      return false;
    }
  }

  identity_ = CaptureIdentity{
      source_id, source_kind, session_id, capture_attempt_id,
      active_capture_offset_us};
  stop_requested_.store(false);
  discontinuity_pending_.store(false);
  worker_completion_.Reset();
  running_.store(true);

  try {
    // Event construction and dispatch can allocate. Keep failures from this
    // platform-channel callback inside the capture API just like thread
    // startup failures, so low-memory startup does not unwind through Flutter.
    EmitState(identity_, "waitingForFirstFrame");
    worker_ = std::thread(&WasapiLoopbackCapture::CaptureWorker, this,
                          identity_);
  } catch (...) {
    running_.store(false);
    worker_completion_.MarkFinished();
    if (error_code) *error_code = "nativeInitializationFailed";
    if (error_message) *error_message = "The audio capture worker could not be launched.";
    try {
      EmitState(identity_, "failed", "nativeInitializationFailed");
    } catch (...) {
      // Never let failure reporting itself escape the platform callback.
    }
    return false;
  }
  return true;
}

WasapiCaptureStopResult WasapiLoopbackCapture::Stop(
    const std::string& final_status,
    std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> lifecycle_lock(lifecycle_mutex_);
  return StopLocked(final_status, timeout);
}

WasapiCaptureStopResult WasapiLoopbackCapture::StopIfOwnedBySession(
    const std::string& session_id,
    const std::string& final_status,
    std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> lifecycle_lock(lifecycle_mutex_);
  if (!identity_.session_id.empty() && identity_.session_id != session_id) {
    return WasapiCaptureStopResult::kNotOwned;
  }
  return StopLocked(final_status, timeout);
}

void WasapiLoopbackCapture::DisableEventCallback() {
  event_callback_gate_.Disable();
}

WasapiCaptureStopResult WasapiLoopbackCapture::StopLocked(
    const std::string& final_status,
    std::chrono::milliseconds timeout) {
  if (!worker_.joinable()) {
    return WasapiCaptureStopResult::kStopped;
  }
  stop_requested_.store(true);
  if (!worker_completion_.TryJoin(worker_, timeout)) {
    return WasapiCaptureStopResult::kPending;
  }
  running_.store(false);
  if (!final_status.empty()) {
    EmitState(identity_, final_status);
  }
  return WasapiCaptureStopResult::kStopped;
}

bool WasapiLoopbackCapture::DispatchEvent(EncodableValue event,
                                         bool is_audio_frame) {
  return event_callback_gate_.Dispatch(std::move(event), is_audio_frame);
}

void WasapiLoopbackCapture::EmitState(const CaptureIdentity& identity,
                                      const std::string& status,
                                      const std::string& error_code) {
  EncodableMap event;
  AddString(&event, "type", "state");
  AddString(&event, "sourceId", identity.source_id);
  AddString(&event, "sourceKind", identity.source_kind);
  AddString(&event, "status", status);
  AddString(&event, "sessionId", identity.session_id);
  AddString(&event, "captureAttemptId", identity.capture_attempt_id);
  if (!error_code.empty()) {
    AddString(&event, "errorCode", error_code);
  }
  DispatchEvent(MakeMap(std::move(event)), false);
}

void WasapiLoopbackCapture::EmitActiveState(
    const CaptureIdentity& identity,
    uint32_t sample_rate_hz,
    uint16_t channel_count,
    int64_t first_sequence,
    int64_t last_sequence,
    int64_t first_frame_time_us) {
  EncodableMap event;
  AddString(&event, "type", "state");
  AddString(&event, "sourceId", identity.source_id);
  AddString(&event, "sourceKind", identity.source_kind);
  AddString(&event, "status", "active");
  AddString(&event, "sessionId", identity.session_id);
  AddString(&event, "captureAttemptId", identity.capture_attempt_id);
  Add(&event, "sampleRateHz", EncodableValue(static_cast<int32_t>(sample_rate_hz)));
  Add(&event, "channelCount", EncodableValue(static_cast<int32_t>(channel_count)));
  AddString(&event, "sampleFormat", "float32LittleEndian");
  Add(&event, "firstFrameSequence", EncodableValue(first_sequence));
  Add(&event, "lastFrameSequence", EncodableValue(last_sequence));
  Add(&event, "firstFrameTimeUs", EncodableValue(first_frame_time_us));
  DispatchEvent(MakeMap(std::move(event)), false);
}

void WasapiLoopbackCapture::CaptureWorker(CaptureIdentity identity) {
  try {
    CaptureWorkerCore(identity);
  } catch (...) {
    running_.store(false);
    try {
      EmitState(identity, "failed", "nativeInitializationFailed");
    } catch (...) {
      // Keep native worker exceptions from terminating the desktop process.
    }
  }
  worker_completion_.MarkFinished();
}

void WasapiLoopbackCapture::CaptureWorkerCore(
    const CaptureIdentity& identity) {
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(com_result)) {
    if (stop_requested_.load()) {
      running_.store(false);
      return;
    }
    const std::string code = ErrorCodeForHresult(com_result);
    EmitState(identity, "failed", code);
    running_.store(false);
    return;
  }
  ComApartmentScope com_apartment;
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL,
                                    IID_PPV_ARGS(enumerator.GetAddressOf()));
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }
  if (FAILED(result)) {
    const std::string code = ErrorCodeForHresult(result);
    EmitState(identity, StatusForErrorCode(code), code);
    running_.store(false);
    return;
  }

  ComPtr<IMMDevice> device;
  if (identity.source_kind == "microphone") {
    const std::string endpoint_id = identity.source_id.substr(
        sizeof(kMicrophoneSourcePrefix) - 1);
    const std::wstring endpoint_id_wide = Utf8ToWide(endpoint_id);
    if (endpoint_id_wide.empty()) {
      EmitState(identity, "failed", "deviceUnavailable");
      running_.store(false);
      return;
    }
    result = enumerator->GetDevice(endpoint_id_wide.c_str(), &device);
  } else {
    result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  }
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }
  if (FAILED(result)) {
    const std::string code = "deviceUnavailable";
    EmitState(identity, StatusForErrorCode(code), code);
    running_.store(false);
    return;
  }

  ComPtr<IAudioClient> audio_client;
  result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                            reinterpret_cast<void**>(audio_client.GetAddressOf()));
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }
  if (FAILED(result)) {
    const std::string code = ErrorCodeForHresult(result);
    EmitState(identity, StatusForErrorCode(code), code);
    running_.store(false);
    return;
  }

  WAVEFORMATEX* mix_format = nullptr;
  result = audio_client->GetMixFormat(&mix_format);
  const auto free_mix_format = [](WAVEFORMATEX* value) {
    CoTaskMemFree(value);
  };
  std::unique_ptr<WAVEFORMATEX, decltype(free_mix_format)> mix_format_owner(
      mix_format, free_mix_format);
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }
  if (FAILED(result) || mix_format == nullptr) {
    const std::string code = result == AUDCLNT_E_DEVICE_INVALIDATED
                                 ? "deviceDisconnected"
                                 : "unsupportedFormat";
    EmitState(identity, "failed", code);
    running_.store(false);
    return;
  }
  if (!IsSupportedFormat(mix_format)) {
    EmitState(identity, "failed", "unsupportedFormat");
    running_.store(false);
    return;
  }

  const DWORD stream_flags = identity.source_kind == "systemOutput"
                                 ? AUDCLNT_STREAMFLAGS_LOOPBACK
                                 : 0;
  result = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, stream_flags,
                                    200'000, 0, mix_format, nullptr);
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }
  if (FAILED(result)) {
    const std::string code = ErrorCodeForHresult(result);
    EmitState(identity, "failed", code);
    running_.store(false);
    return;
  }

  ComPtr<IAudioCaptureClient> capture_client;
  result = audio_client->GetService(
      IID_PPV_ARGS(capture_client.GetAddressOf()));
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }
  if (FAILED(result)) {
    const std::string code = ErrorCodeForHresult(result);
    EmitState(identity, StatusForErrorCode(code), code);
    running_.store(false);
    return;
  }

  result = audio_client->Start();
  AudioClientStartedScope audio_client_started(
      SUCCEEDED(result) ? audio_client.Get() : nullptr);
  if (stop_requested_.load()) {
    running_.store(false);
    return;
  }
  if (FAILED(result)) {
    const std::string code = ErrorCodeForHresult(result);
    EmitState(identity, StatusForErrorCode(code), code);
    running_.store(false);
    return;
  }

  const auto capture_started = std::chrono::steady_clock::now();
  LARGE_INTEGER qpc_frequency = {};
  LARGE_INTEGER capture_start_qpc = {};
  const bool has_qpc_clock = QueryPerformanceFrequency(&qpc_frequency) != 0 &&
                             qpc_frequency.QuadPart > 0 &&
                             QueryPerformanceCounter(&capture_start_qpc) != 0;
  auto last_packet_time = capture_started;
  int64_t last_frame_end_us = identity.active_capture_offset_us;
  bool did_emit_first_frame = false;
  bool signal_missing = false;
  int64_t first_frame_time_us = 0;
  int64_t first_frame_sequence = 0;
  int64_t next_sequence = 0;
  const uint64_t sample_rate = mix_format->nSamplesPerSec;
  const uint16_t channel_count = mix_format->nChannels;
  const auto channel_mask = ChannelMaskFor(mix_format);
  const uint64_t max_frames_by_duration =
      std::max<uint64_t>(1, sample_rate * kMaximumFrameDurationUs / 1'000'000);
  const uint64_t max_frames_by_bytes =
      std::max<uint64_t>(1, kMaximumFrameBytes / (channel_count * sizeof(float)));
  const uint32_t max_chunk_frames = static_cast<uint32_t>(
      std::min(max_frames_by_duration, max_frames_by_bytes));

  std::vector<uint8_t> converted_bytes;
  while (!stop_requested_.load()) {
    UINT32 packet_frames = 0;
    result = capture_client->GetNextPacketSize(&packet_frames);
    if (FAILED(result)) {
      const std::string code = ErrorCodeForHresult(result);
      const std::string terminal_status = StatusForErrorCode(code);
      EmitState(identity, terminal_status, code);
      break;
    }

    if (packet_frames == 0) {
      const auto now = std::chrono::steady_clock::now();
      if (now - last_packet_time >= kNoSignalTimeout && !signal_missing) {
        EmitState(identity, "noSignal", "noSignal");
        signal_missing = true;
      }
      std::this_thread::sleep_for(kPollInterval);
      continue;
    }

    BYTE* packet_data = nullptr;
    UINT32 available_frames = 0;
    DWORD buffer_flags = 0;
    UINT64 device_position = 0;
    UINT64 qpc_position_100ns = 0;
    result = capture_client->GetBuffer(&packet_data, &available_frames,
                                       &buffer_flags, &device_position,
                                       &qpc_position_100ns);
    if (FAILED(result)) {
      const std::string code = ErrorCodeForHresult(result);
      const std::string terminal_status = StatusForErrorCode(code);
      EmitState(identity, terminal_status, code);
      break;
    }
    CaptureBufferScope capture_buffer(capture_client.Get(), available_frames);
    (void)device_position;

    bool packet_converted = true;
    if (available_frames > 0 && (buffer_flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0 &&
        packet_data == nullptr) {
      packet_converted = false;
    }

    int64_t packet_start_us = identity.active_capture_offset_us;
    const auto now = std::chrono::steady_clock::now();
    if ((buffer_flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) != 0 ||
        qpc_position_100ns == 0 || !has_qpc_clock) {
      const uint64_t elapsed_us = static_cast<uint64_t>(
          std::chrono::duration_cast<std::chrono::microseconds>(
              now - capture_started)
              .count());
      const uint64_t packet_duration_us =
          static_cast<uint64_t>(available_frames) * 1'000'000 / sample_rate;
      packet_start_us = SaturatingAddMicroseconds(
          packet_start_us,
          elapsed_us > packet_duration_us ? elapsed_us - packet_duration_us
                                          : 0);
    } else {
      const uint64_t capture_start_100ns = static_cast<uint64_t>(
          static_cast<long double>(capture_start_qpc.QuadPart) * 10'000'000.0L /
          static_cast<long double>(qpc_frequency.QuadPart));
      if (qpc_position_100ns >= capture_start_100ns) {
        const uint64_t delta_100ns = qpc_position_100ns - capture_start_100ns;
        const long double delta_us_value =
            static_cast<long double>(delta_100ns) / 10.0L;
        const uint64_t delta_us = static_cast<uint64_t>(std::min<long double>(
            delta_us_value,
            static_cast<long double>(std::numeric_limits<int64_t>::max())));
        packet_start_us = SaturatingAddMicroseconds(packet_start_us, delta_us);
      }
    }

    uint32_t packet_offset = 0;
    bool packet_discontinuity =
        (buffer_flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0 ||
        (buffer_flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) != 0;
    while (packet_converted && packet_offset < available_frames) {
      const uint32_t chunk_frames = std::min(
          max_chunk_frames, static_cast<uint32_t>(available_frames - packet_offset));
      if ((buffer_flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
        converted_bytes.assign(static_cast<size_t>(chunk_frames) * channel_count *
                                   sizeof(float),
                               0);
      } else if (!ConvertPacketChunk(packet_data, packet_offset, chunk_frames,
                                     mix_format, &converted_bytes)) {
        packet_converted = false;
        break;
      }

      const int64_t sample_count = static_cast<int64_t>(chunk_frames);
      const int64_t duration_us =
          sample_count * 1'000'000 / static_cast<int64_t>(sample_rate);
      const uint64_t packet_offset_us =
          static_cast<uint64_t>(packet_offset) * 1'000'000 / sample_rate;
      const int64_t proposed_start_signed =
          SaturatingAddMicroseconds(packet_start_us, packet_offset_us);
      const int64_t frame_start_us =
          std::max(proposed_start_signed, last_frame_end_us);
      last_frame_end_us = SaturatingAddMicroseconds(
          frame_start_us, static_cast<uint64_t>(duration_us));

      std::optional<int64_t> frame_qpc_time_100ns;
      if ((buffer_flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) == 0 &&
          qpc_position_100ns > 0 && has_qpc_clock) {
        const uint64_t packet_offset_100ns =
            static_cast<uint64_t>(packet_offset) * 10'000'000 / sample_rate;
        if (qpc_position_100ns <=
                std::numeric_limits<uint64_t>::max() - packet_offset_100ns &&
            qpc_position_100ns + packet_offset_100ns <=
                static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
          frame_qpc_time_100ns = static_cast<int64_t>(
              qpc_position_100ns + packet_offset_100ns);
        }
      }

      const bool was_dropped = discontinuity_pending_.load();
      const int64_t frame_sequence = next_sequence;
      const bool frame_discontinuity = packet_discontinuity || was_dropped;
      packet_discontinuity = false;
      EncodableMap event;
      AddString(&event, "type", "audioFrame");
      AddString(&event, "sessionId", identity.session_id);
      AddString(&event, "captureAttemptId", identity.capture_attempt_id);
      AddString(&event, "sourceId", identity.source_id);
      AddString(&event, "sourceKind", identity.source_kind);
      Add(&event, "sequence", EncodableValue(next_sequence));
      Add(&event, "startTimeUs", EncodableValue(frame_start_us));
      if (frame_qpc_time_100ns.has_value()) {
        Add(&event, "qpcTime100ns",
            EncodableValue(*frame_qpc_time_100ns));
      }
      Add(&event, "sampleRateHz", EncodableValue(static_cast<int32_t>(sample_rate)));
      Add(&event, "channelCount", EncodableValue(static_cast<int32_t>(channel_count)));
      if (channel_mask.has_value()) {
        Add(&event, "channelMask",
            EncodableValue(static_cast<int32_t>(*channel_mask)));
      }
      Add(&event, "sampleCount", EncodableValue(static_cast<int32_t>(chunk_frames)));
      AddString(&event, "sampleFormat", "float32LittleEndian");
      Add(&event, "pcmBytes", EncodableValue(std::move(converted_bytes)));
      Add(&event, "hasDiscontinuityBefore",
          EncodableValue(frame_discontinuity));

      const bool accepted =
          DispatchEvent(MakeMap(std::move(event)), true);
      discontinuity_pending_.store(!accepted);
      if (accepted && !did_emit_first_frame) {
        did_emit_first_frame = true;
        first_frame_sequence = frame_sequence;
        first_frame_time_us = frame_start_us;
        EmitActiveState(identity, static_cast<uint32_t>(sample_rate),
                        channel_count, first_frame_sequence, frame_sequence,
                        first_frame_time_us);
        signal_missing = false;
      } else if (accepted && signal_missing) {
        EmitActiveState(identity, static_cast<uint32_t>(sample_rate),
                        channel_count, first_frame_sequence, frame_sequence,
                        first_frame_time_us);
        signal_missing = false;
      }
      ++next_sequence;
      packet_offset += chunk_frames;
      last_packet_time = now;
    }

    const HRESULT release_result = capture_buffer.Release();
    if (FAILED(release_result)) {
      const std::string code = ErrorCodeForHresult(release_result);
      const std::string terminal_status = StatusForErrorCode(code);
      EmitState(identity, terminal_status, code);
      break;
    }
    if (!packet_converted) {
      EmitState(identity, "failed", "unsupportedFormat");
      break;
    }
  }

  running_.store(false);
}
