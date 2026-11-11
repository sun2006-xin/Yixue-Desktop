#include "windows_screen_capture.h"
#include "recording_capture_safety.h"
#include "recording_time_anchor.h"
#include "recording_publication_policy.h"
#include "texture_unregistration_safety.h"

#include <windows.h>
#include <d3d11.h>
#include <d3d11_4.h>
#include <dxgi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shobjidl.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <wrl/client.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <cmath>
#include <filesystem>
#include <functional>
#include <iterator>
#include <limits>
#include <mutex>
#include <new>
#include <thread>
#include <utility>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::Capture::GraphicsCapturePicker;
using winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;

constexpr size_t kMaximumQueuedSamples = 96;
constexpr uint64_t kMaximumAudioFrameBytes = 256ULL * 1024;
constexpr int64_t kVideoFrameDuration100ns = 666'667;  // 15 fps.
constexpr int64_t kAudioSampleRate = 48'000;
constexpr int64_t kAudioChannelCount = 2;
constexpr auto kTextureUnregistrationWait = std::chrono::seconds(2);

void AddString(EncodableMap* map, const char* key, const std::string& value) {
  map->emplace(EncodableValue(key), EncodableValue(value));
}

void AddInt(EncodableMap* map, const char* key, int64_t value) {
  map->emplace(EncodableValue(key), EncodableValue(value));
}

void AddBool(EncodableMap* map, const char* key, bool value) {
  map->emplace(EncodableValue(key), EncodableValue(value));
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int count = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                        static_cast<int>(value.size()), nullptr,
                                        0);
  if (count <= 0) return {};
  std::wstring result(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), count);
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                        static_cast<int>(value.size()), nullptr,
                                        0, nullptr, nullptr);
  if (count <= 0) return {};
  std::string result(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), count, nullptr, nullptr);
  return result;
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

int64_t CurrentQpc100ns() {
  LARGE_INTEGER frequency = {};
  LARGE_INTEGER counter = {};
  if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0 ||
      !QueryPerformanceCounter(&counter) || counter.QuadPart < 0) {
    return 0;
  }
  return static_cast<int64_t>(
      static_cast<long double>(counter.QuadPart) * 10'000'000.0L /
      static_cast<long double>(frequency.QuadPart));
}

std::pair<uint32_t, uint32_t> FitSize(uint32_t width,
                                      uint32_t height,
                                      uint32_t max_width,
                                      uint32_t max_height,
                                      bool even_dimensions) {
  if (width == 0 || height == 0) return {0, 0};
  const double scale = std::min(
      {1.0, static_cast<double>(max_width) / width,
       static_cast<double>(max_height) / height});
  uint32_t fitted_width = std::max<uint32_t>(
      2, static_cast<uint32_t>(std::floor(width * scale)));
  uint32_t fitted_height = std::max<uint32_t>(
      2, static_cast<uint32_t>(std::floor(height * scale)));
  if (even_dimensions) {
    fitted_width &= ~1U;
    fitted_height &= ~1U;
  }
  return {fitted_width, fitted_height};
}

const EncodableValue* FindValue(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

bool ReadInteger(const EncodableMap& map, const char* key, int64_t* value) {
  const auto* encoded = FindValue(map, key);
  if (encoded == nullptr) return false;
  const auto parsed = encoded->TryGetLongValue();
  if (!parsed.has_value()) return false;
  *value = *parsed;
  return true;
}

class MfApartment {
 public:
  MfApartment() {
    const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    com_initialized_ = SUCCEEDED(result);
    if (com_initialized_) {
      mf_started_ = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_FULL));
    }
  }
  ~MfApartment() {
    if (mf_started_) MFShutdown();
    if (com_initialized_) CoUninitialize();
  }
  bool ready() const { return com_initialized_ && mf_started_; }

 private:
  bool com_initialized_ = false;
  bool mf_started_ = false;
};

struct MediaSample {
  enum class Kind { kVideo, kAudio } kind;
  int64_t timestamp_100ns = 0;
  int64_t duration_100ns = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> bytes;
};

class LocalMp4Recorder {
 public:
  using FailureCallback =
      std::function<void(const std::string&, const std::string&)>;

  explicit LocalMp4Recorder(FailureCallback failure_callback)
      : failure_callback_(std::move(failure_callback)) {}

  ~LocalMp4Recorder() { Stop(nullptr, nullptr, nullptr); }

  bool Start(const std::wstring& output_path,
             uint32_t width,
             uint32_t height,
             std::string* error_code,
             std::string* error_message) {
    std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
    if (worker_.joinable()) {
      if (error_code) *error_code = "recordingAlreadyActive";
      if (error_message) *error_message = "A screen recording is already active.";
      return false;
    }
    if (width == 0 || height == 0 || output_path.empty()) {
      if (error_code) *error_code = "invalidRecordingTarget";
      if (error_message) *error_message = "The recording path or capture size is invalid.";
      return false;
    }

    output_path_ = output_path;
    width_ = width;
    height_ = height;
    start_qpc_100ns_ = CurrentQpc100ns();
    if (start_qpc_100ns_ <= 0) {
      if (error_code) *error_code = "clockUnavailable";
      if (error_message) *error_message = "Windows performance clock is unavailable.";
      return false;
    }
    {
      std::lock_guard<std::mutex> queue_lock(queue_mutex_);
      queue_.clear();
      stopping_ = false;
      worker_ready_ = false;
      worker_start_succeeded_ = false;
      worker_finished_ = false;
      worker_error_.clear();
      worker_error_message_.clear();
      video_frames_written_ = 0;
      last_video_time_100ns_ = -1;
      last_audio_time_100ns_ = -1;
    }
    try {
      worker_ = std::thread(&LocalMp4Recorder::Worker, this);
    } catch (...) {
      if (error_code) *error_code = "recordingWorkerUnavailable";
      if (error_message) {
        *error_message = "Windows could not start the MP4 recording worker.";
      }
      return false;
    }
    std::unique_lock<std::mutex> queue_lock(queue_mutex_);
    if (!queue_changed_.wait_for(queue_lock, std::chrono::seconds(8),
                                 [this] { return worker_ready_; }) ||
        !worker_start_succeeded_) {
      if (error_code) *error_code = worker_error_.empty()
                                        ? "recordingInitializationTimeout"
                                        : worker_error_;
      if (error_message) *error_message = worker_error_message_.empty()
                                              ? "The MP4 recorder did not initialize."
                                              : worker_error_message_;
      stopping_ = true;
      queue_lock.unlock();
      queue_changed_.notify_all();
      if (worker_.joinable()) worker_.join();
      return false;
    }
    return true;
  }

  bool EnqueueVideo(const uint8_t* source,
                    size_t source_row_pitch,
                    uint32_t source_width,
                    uint32_t source_height,
                    int64_t qpc_time_100ns) {
    // WGC timestamps use QPC time in 100 ns units. A callback can arrive after
    // recording starts even when its frame was rendered before the start.
    if (!IsQpcAtOrAfterRecordingOrigin(qpc_time_100ns, start_qpc_100ns_) ||
        source_width == 0 || source_height == 0 || source == nullptr ||
        width_ == 0 || height_ == 0) {
      return false;
    }
    MediaSample sample;
    sample.kind = MediaSample::Kind::kVideo;
    sample.timestamp_100ns = RelativeTimestamp(qpc_time_100ns);
    sample.duration_100ns = kVideoFrameDuration100ns;
    sample.width = width_;
    sample.height = height_;
    sample.bytes.resize(static_cast<size_t>(width_) * height_ * 4);
    const size_t output_row_bytes = static_cast<size_t>(width_) * 4;
    for (uint32_t y = 0; y < height_; ++y) {
      const uint32_t source_y = static_cast<uint32_t>(
          static_cast<uint64_t>(y) * source_height / height_);
      const auto* source_row = source + static_cast<size_t>(source_y) *
                                           source_row_pitch;
      auto* output_row = sample.bytes.data() +
                         static_cast<size_t>(y) * output_row_bytes;
      for (uint32_t x = 0; x < width_; ++x) {
        const uint32_t source_x = static_cast<uint32_t>(
            static_cast<uint64_t>(x) * source_width / width_);
        std::memcpy(output_row + static_cast<size_t>(x) * 4,
                    source_row + static_cast<size_t>(source_x) * 4, 4);
      }
    }
    return Enqueue(std::move(sample), true);
  }

  bool EnqueueAudio(const EncodableValue& event) {
    const auto* map = std::get_if<EncodableMap>(&event);
    if (map == nullptr) return false;
    int64_t qpc_start = 0;
    int64_t sample_rate = 0;
    int64_t channels = 0;
    int64_t sample_count = 0;
    const bool has_capture_qpc =
        ReadInteger(*map, "qpcStart100ns", &qpc_start) ||
        ReadInteger(*map, "qpcTime100ns", &qpc_start);
    // WASAPI may also deliver a queued packet after recording starts. Reject
    // it when the captured audio itself predates this recording's QPC origin.
    if (!has_capture_qpc ||
        !ReadInteger(*map, "sampleRateHz", &sample_rate) ||
        !ReadInteger(*map, "channelCount", &channels) ||
        !ReadInteger(*map, "sampleCount", &sample_count) || qpc_start <= 0 ||
        sample_rate < 8'000 || sample_rate > 192'000 || channels <= 0 ||
        channels > 8 || sample_count <= 0 || sample_count > 48'000 ||
        !IsQpcAtOrAfterRecordingOrigin(qpc_start, start_qpc_100ns_)) {
      return false;
    }
    const auto* encoded_bytes = FindValue(*map, "pcmBytes");
    const auto* input_bytes = encoded_bytes == nullptr
                                  ? nullptr
                                  : std::get_if<std::vector<uint8_t>>(encoded_bytes);
    const uint64_t expected_bytes = static_cast<uint64_t>(sample_count) *
                                    static_cast<uint64_t>(channels) *
                                    sizeof(float);
    if (input_bytes == nullptr || expected_bytes > kMaximumAudioFrameBytes ||
        input_bytes->size() != expected_bytes) {
      return false;
    }

    const size_t output_count = static_cast<size_t>(
        (sample_count * kAudioSampleRate + sample_rate - 1) / sample_rate);
    MediaSample sample;
    sample.kind = MediaSample::Kind::kAudio;
    sample.timestamp_100ns = RelativeTimestamp(qpc_start);
    sample.duration_100ns = static_cast<int64_t>(output_count) *
                             10'000'000 / kAudioSampleRate;
    sample.bytes.resize(output_count * kAudioChannelCount * sizeof(int16_t));
    const auto store_output = [&sample](size_t index, int16_t value) {
      const size_t offset = index * sizeof(value);
      std::memcpy(sample.bytes.data() + offset, &value, sizeof(value));
    };
    for (size_t out_index = 0; out_index < output_count; ++out_index) {
      const double input_position =
          static_cast<double>(out_index) * static_cast<double>(sample_rate) /
          static_cast<double>(kAudioSampleRate);
      const size_t left_index = std::min<size_t>(
          static_cast<size_t>(input_position), static_cast<size_t>(sample_count - 1));
      const size_t right_index = std::min<size_t>(left_index + 1,
                                                  static_cast<size_t>(sample_count - 1));
      const float fraction = static_cast<float>(input_position - left_index);
      const auto value_for_channel = [&](int64_t channel) {
        const int64_t chosen = channels == 1 ? 0 : std::min<int64_t>(channel, channels - 1);
        float a = 0.0F;
        float b = 0.0F;
        const size_t left_offset =
            (left_index * static_cast<size_t>(channels) +
             static_cast<size_t>(chosen)) * sizeof(float);
        const size_t right_offset =
            (right_index * static_cast<size_t>(channels) +
             static_cast<size_t>(chosen)) * sizeof(float);
        std::memcpy(&a, input_bytes->data() + left_offset, sizeof(a));
        std::memcpy(&b, input_bytes->data() + right_offset, sizeof(b));
        if (!std::isfinite(a)) a = 0.0F;
        if (!std::isfinite(b)) b = 0.0F;
        const float mixed = a + (b - a) * fraction;
        const float clipped = std::clamp(mixed, -1.0F, 1.0F);
        return static_cast<int16_t>(std::lrint(clipped * 32767.0F));
      };
      store_output(out_index * 2, value_for_channel(0));
      store_output(out_index * 2 + 1, value_for_channel(1));
    }
    return Enqueue(std::move(sample), false);
  }

  bool Stop(std::string* output_path,
            std::string* error_code,
            std::string* error_message) {
    std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
    if (!worker_.joinable()) {
      if (output_path) *output_path = {};
      return true;
    }
    {
      std::lock_guard<std::mutex> queue_lock(queue_mutex_);
      stopping_ = true;
    }
    queue_changed_.notify_all();
    worker_.join();
    if (!worker_error_.empty()) {
      if (error_code) *error_code = worker_error_;
      if (error_message) *error_message = worker_error_message_;
      return false;
    }
    uint64_t video_frames_written = 0;
    {
      std::lock_guard<std::mutex> queue_lock(queue_mutex_);
      video_frames_written = video_frames_written_;
    }
    if (!yixue::runner::CanPublishScreenRecording(video_frames_written)) {
      if (error_code) *error_code = "recordingNoVideoFrames";
      if (error_message) {
        *error_message =
            "No video frames were written; the incomplete recording was kept.";
      }
      return false;
    }
    const auto completed_path = MakeCompletedRecordingPath(output_path_);
    if (completed_path.empty()) {
      if (error_code) *error_code = "invalidRecordingPath";
      if (error_message) {
        *error_message = "The recording file is missing its incomplete marker.";
      }
      return false;
    }
    std::error_code publish_error;
    std::filesystem::rename(output_path_, completed_path, publish_error);
    if (publish_error) {
      if (error_code) *error_code = "recordingPublishFailed";
      if (error_message) {
        *error_message =
            "The MP4 was finalized, but could not be published; the partial "
            "recording was kept.";
      }
      return false;
    }
    output_path_ = completed_path.wstring();
    if (output_path) *output_path = WideToUtf8(output_path_);
    return true;
  }

  bool active() const {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    return worker_.joinable() && worker_start_succeeded_ && !stopping_;
  }

  bool Failure(std::string* error_code,
               std::string* error_message) const {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (worker_error_.empty()) return false;
    if (error_code) *error_code = worker_error_;
    if (error_message) *error_message = worker_error_message_;
    return true;
  }

 private:
  int64_t RelativeTimestamp(int64_t qpc_time_100ns) const {
    return std::max<int64_t>(0, qpc_time_100ns - start_qpc_100ns_);
  }

  bool Enqueue(MediaSample sample, bool may_drop) {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (!worker_start_succeeded_ || stopping_ || !worker_error_.empty()) {
      return false;
    }
    int64_t& last_time = sample.kind == MediaSample::Kind::kVideo
                             ? last_video_time_100ns_
                             : last_audio_time_100ns_;
    if (last_time >= 0 && sample.timestamp_100ns <= last_time) {
      sample.timestamp_100ns = last_time + 1;
    }
    if (sample.kind == MediaSample::Kind::kVideo && last_time >= 0 &&
        sample.timestamp_100ns - last_time < kVideoFrameDuration100ns) {
      return true;
    }
    if (queue_.size() >= kMaximumQueuedSamples) {
      if (may_drop) return true;
      worker_error_ = "recordingQueueFull";
      worker_error_message_ = "Audio recording fell behind; the MP4 was stopped to avoid unbounded memory use.";
      stopping_ = true;
      queue_changed_.notify_all();
      return false;
    }
    last_time = sample.timestamp_100ns;
    queue_.emplace_back(std::move(sample));
    queue_changed_.notify_one();
    return true;
  }

  static HRESULT CreateVideoTypes(IMFSinkWriter* writer,
                                  uint32_t width,
                                  uint32_t height,
                                  DWORD* stream_index) {
    ComPtr<IMFMediaType> output;
    HRESULT result = MFCreateMediaType(&output);
    if (FAILED(result)) return result;
    output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    output->SetUINT32(MF_MT_AVG_BITRATE, 4'000'000);
    MFSetAttributeSize(output.Get(), MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(output.Get(), MF_MT_FRAME_RATE, 15, 1);
    MFSetAttributeRatio(output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    result = writer->AddStream(output.Get(), stream_index);
    if (FAILED(result)) return result;

    ComPtr<IMFMediaType> input;
    result = MFCreateMediaType(&input);
    if (FAILED(result)) return result;
    input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, 15, 1);
    MFSetAttributeRatio(input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    input->SetUINT32(MF_MT_DEFAULT_STRIDE, width * 4);
    return writer->SetInputMediaType(*stream_index, input.Get(), nullptr);
  }

  static HRESULT CreateAudioTypes(IMFSinkWriter* writer,
                                  DWORD* stream_index) {
    ComPtr<IMFMediaType> output;
    HRESULT result = MFCreateMediaType(&output);
    if (FAILED(result)) return result;
    output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS,
                      static_cast<UINT32>(kAudioChannelCount));
    output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                      static_cast<UINT32>(kAudioSampleRate));
    output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16'000);
    output->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 1);
    output->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
    output->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
    result = writer->AddStream(output.Get(), stream_index);
    if (FAILED(result)) return result;

    ComPtr<IMFMediaType> input;
    result = MFCreateMediaType(&input);
    if (FAILED(result)) return result;
    input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS,
                      static_cast<UINT32>(kAudioChannelCount));
    input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                      static_cast<UINT32>(kAudioSampleRate));
    input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT,
                     static_cast<UINT32>(kAudioChannelCount * 2));
    input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                     static_cast<UINT32>(kAudioSampleRate * kAudioChannelCount * 2));
    return writer->SetInputMediaType(*stream_index, input.Get(), nullptr);
  }

  static HRESULT WriteSample(IMFSinkWriter* writer,
                             DWORD stream_index,
                             const MediaSample& sample) {
    if (sample.bytes.empty() || sample.bytes.size() > MAXDWORD) {
      return E_INVALIDARG;
    }
    ComPtr<IMFSample> media_sample;
    HRESULT result = MFCreateSample(&media_sample);
    if (FAILED(result)) return result;
    ComPtr<IMFMediaBuffer> buffer;
    result = MFCreateMemoryBuffer(static_cast<DWORD>(sample.bytes.size()),
                                  &buffer);
    if (FAILED(result)) return result;
    BYTE* destination = nullptr;
    DWORD maximum_length = 0;
    result = buffer->Lock(&destination, &maximum_length, nullptr);
    if (FAILED(result)) return result;
    if (maximum_length < sample.bytes.size()) {
      buffer->Unlock();
      return E_OUTOFMEMORY;
    }
    std::memcpy(destination, sample.bytes.data(), sample.bytes.size());
    buffer->Unlock();
    result = buffer->SetCurrentLength(static_cast<DWORD>(sample.bytes.size()));
    if (FAILED(result)) return result;
    result = media_sample->AddBuffer(buffer.Get());
    if (FAILED(result)) return result;
    result = media_sample->SetSampleTime(sample.timestamp_100ns);
    if (FAILED(result)) return result;
    result = media_sample->SetSampleDuration(sample.duration_100ns);
    if (FAILED(result)) return result;
    return writer->WriteSample(stream_index, media_sample.Get());
  }

  void Worker() {
    try {
      RunWorker();
    } catch (...) {
      // An exception must not escape a std::thread entry point: that would
      // terminate the entire desktop process instead of failing this recording.
      {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        worker_start_succeeded_ = false;
        worker_ready_ = true;
        worker_finished_ = true;
        stopping_ = true;
        queue_.clear();
        worker_error_ = "recordingWorkerFailed";
        worker_error_message_ = "The MP4 recorder stopped unexpectedly.";
      }
      queue_changed_.notify_all();
    }
    try {
      std::string error_code;
      std::string error_message;
      if (failure_callback_ && Failure(&error_code, &error_message)) {
        failure_callback_(error_code, error_message);
      }
    } catch (...) {
      // Error reporting must never escape a native worker thread.
    }
  }

  void RunWorker() {
    MfApartment apartment;
    HRESULT result = apartment.ready() ? S_OK : MF_E_PLATFORM_NOT_INITIALIZED;
    ComPtr<IMFSinkWriter> writer;
    DWORD video_stream = 0;
    DWORD audio_stream = 0;
    if (SUCCEEDED(result)) {
      result = MFCreateSinkWriterFromURL(output_path_.c_str(), nullptr, nullptr,
                                         &writer);
    }
    if (SUCCEEDED(result)) result = CreateVideoTypes(writer.Get(), width_, height_, &video_stream);
    if (SUCCEEDED(result)) result = CreateAudioTypes(writer.Get(), &audio_stream);
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      worker_start_succeeded_ = SUCCEEDED(result);
      worker_ready_ = true;
      if (FAILED(result)) {
        worker_error_ = "mediaFoundationUnavailable";
        worker_error_message_ = "Windows Media Foundation could not prepare an H.264/AAC MP4 recorder.";
      }
    }
    queue_changed_.notify_all();
    if (FAILED(result)) return;

    for (;;) {
      MediaSample sample;
      {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        queue_changed_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
        if (queue_.empty() && stopping_) break;
        sample = std::move(queue_.front());
        queue_.pop_front();
      }
      result = WriteSample(writer.Get(),
                           sample.kind == MediaSample::Kind::kVideo
                               ? video_stream
                               : audio_stream,
                           sample);
      if (FAILED(result)) {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        worker_error_ = "mediaWriteFailed";
        worker_error_message_ = "Windows Media Foundation failed while writing the MP4.";
        stopping_ = true;
        queue_.clear();
        break;
      }
      if (sample.kind == MediaSample::Kind::kVideo) {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        ++video_frames_written_;
      }
    }
    const HRESULT finalize_result = writer->Finalize();
    if (FAILED(finalize_result)) {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      if (worker_error_.empty()) {
        worker_error_ = "recordingFinalizeFailed";
        worker_error_message_ = "The MP4 could not be finalized; it may be incomplete.";
      }
    }
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      worker_finished_ = true;
    }
    queue_changed_.notify_all();
  }

  mutable std::mutex lifecycle_mutex_;
  mutable std::mutex queue_mutex_;
  std::condition_variable queue_changed_;
  std::deque<MediaSample> queue_;
  std::thread worker_;
  std::wstring output_path_;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  int64_t start_qpc_100ns_ = 0;
  int64_t last_video_time_100ns_ = -1;
  int64_t last_audio_time_100ns_ = -1;
  uint64_t video_frames_written_ = 0;
  bool stopping_ = false;
  bool worker_ready_ = false;
  bool worker_start_succeeded_ = false;
  bool worker_finished_ = false;
  std::string worker_error_;
  std::string worker_error_message_;
  FailureCallback failure_callback_;
};

}  // namespace

struct WindowsScreenCapture::Impl {
  struct PixelBuffer {
    std::vector<uint8_t> pixels;
    uint32_t width = 0;
    uint32_t height = 0;
  };

  struct PixelFrame {
    FlutterDesktopPixelBuffer descriptor = {};
    std::shared_ptr<const PixelBuffer> pixels;
  };

  Impl(HWND owner,
       FlutterDesktopTextureRegistrarRef registrar,
       EventCallback callback)
      : owner_window(owner), texture_registrar(registrar),
        event_callback(std::move(callback)) {
    // Allocate callback storage before registering the texture so shutdown
    // never has to fall back to an unbounded wait under memory pressure.
    texture_unregistration_context =
        std::make_unique<TextureUnregisterCallbackContext>();
    FlutterDesktopTextureInfo info = {};
    info.type = kFlutterDesktopPixelBufferTexture;
    info.pixel_buffer_config.callback = &CopyPixelBuffer;
    info.pixel_buffer_config.user_data = this;
    texture_id = FlutterDesktopTextureRegistrarRegisterExternalTexture(
        texture_registrar, &info);
  }

  void Shutdown(
      bool wait_for_texture_unregistration = true,
      std::shared_ptr<void> keep_alive = {},
      std::chrono::milliseconds wait_timeout = kTextureUnregistrationWait) {
    if (shutdown_requested.exchange(true)) {
      if (wait_for_texture_unregistration) {
        texture_unregistration->WaitFor(wait_timeout);
      }
      return;
    }

    try {
      StopCapture();
    } catch (...) {
      // Continue unregistering the texture even if capture shutdown failed.
    }
    try {
      StopRecording(nullptr, nullptr, nullptr);
    } catch (...) {
      // Continue unregistering the texture even if recording shutdown failed.
    }

    FlutterDesktopTextureRegistrarRef registrar = nullptr;
    int64_t registered_texture_id = -1;
    {
      std::lock_guard<std::mutex> lock(texture_mutex);
      registrar = texture_registrar;
      registered_texture_id = texture_id;
      texture_registrar = nullptr;
      texture_id = -1;
    }
    if (registrar == nullptr || registered_texture_id < 0) {
      texture_unregistration->Complete();
      return;
    }
    auto* context = texture_unregistration_context.release();
    if (context == nullptr) {
      // This should be unreachable: the context is allocated before texture
      // registration and shutdown is entered once. Keep a no-allocation
      // fallback so a broken invariant still cannot free Flutter's callback
      // user_data before asynchronous unregistration completes.
      texture_unregistration_fallback_owner = std::move(keep_alive);
      FlutterDesktopTextureRegistrarUnregisterExternalTexture(
          registrar, registered_texture_id,
          &OnTextureUnregisteredFallback, this);
      if (wait_for_texture_unregistration) {
        texture_unregistration->WaitFor(wait_timeout);
      }
      return;
    }
    context->keep_alive = std::move(keep_alive);
    context->completion = texture_unregistration;
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(
        registrar, registered_texture_id,
        &TextureUnregisterCallbackContext::CompleteAndRelease, context);
    if (wait_for_texture_unregistration) {
      texture_unregistration->WaitFor(wait_timeout);
    }
  }

  int64_t GetTextureId() {
    std::lock_guard<std::mutex> lock(texture_mutex);
    return texture_id;
  }

  std::pair<uint32_t, uint32_t> GetPixelSize() {
    std::lock_guard<std::mutex> lock(pixels_mutex);
    return {pixel_width, pixel_height};
  }

  std::shared_ptr<PixelBuffer> AcquirePixelBuffer() {
    std::lock_guard<std::mutex> lock(pixels_mutex);
    for (const auto& buffer : pixel_buffer_pool) {
      if (buffer && buffer.use_count() == 1) return buffer;
    }
    for (auto& buffer : pixel_buffer_pool) {
      if (!buffer) {
        buffer = std::make_shared<PixelBuffer>();
        return buffer;
      }
    }
    // Flutter still owns every pooled frame. Keep displaying the last complete
    // snapshot and skip this preview update instead of allocating without a
    // bound while the renderer is under pressure.
    return nullptr;
  }

  void MarkTextureFrameAvailable() {
    std::lock_guard<std::mutex> lock(texture_mutex);
    if (shutdown_requested.load() || texture_id < 0 ||
        texture_registrar == nullptr) {
      return;
    }
    FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
        texture_registrar, texture_id);
  }

  bool IsShuttingDown() const { return shutdown_requested.load(); }

  bool IsShutdownComplete() const {
    return texture_unregistration->IsComplete();
  }

  static void ReleasePixelBuffer(void* context) {
    delete static_cast<PixelFrame*>(context);
  }

  static void OnTextureUnregisteredFallback(void* user_data) noexcept {
    auto* self = static_cast<Impl*>(user_data);
    if (self == nullptr) return;
    // Move the owner and completion into locals before releasing the final
    // owner. Their destructors run after this callback has stopped using self.
    auto keep_alive = std::move(self->texture_unregistration_fallback_owner);
    auto completion = self->texture_unregistration;
    completion->Complete();
  }

  static const FlutterDesktopPixelBuffer* CopyPixelBuffer(
      size_t,
      size_t,
      void* user_data) noexcept {
    try {
      auto* self = static_cast<Impl*>(user_data);
      if (self == nullptr) return nullptr;

      std::shared_ptr<const PixelBuffer> pixels;
      {
        std::lock_guard<std::mutex> lock(self->pixels_mutex);
        pixels = self->pixel_buffer;
      }
      if (!pixels || pixels->pixels.empty() || pixels->width == 0 ||
          pixels->height == 0) {
        return nullptr;
      }

      // The Flutter raster thread can retain this descriptor until its release
      // callback. Share an immutable frame snapshot instead of copying several
      // megabytes of pixels on every texture tick.
      auto pixel_frame =
          std::unique_ptr<PixelFrame>(new (std::nothrow) PixelFrame());
      if (!pixel_frame) return nullptr;
      pixel_frame->pixels = std::move(pixels);
      pixel_frame->descriptor.buffer = pixel_frame->pixels->pixels.data();
      pixel_frame->descriptor.width = pixel_frame->pixels->width;
      pixel_frame->descriptor.height = pixel_frame->pixels->height;
      pixel_frame->descriptor.release_callback = &ReleasePixelBuffer;
      pixel_frame->descriptor.release_context = pixel_frame.get();
      const auto* descriptor = &pixel_frame->descriptor;
      pixel_frame.release();
      return descriptor;
    } catch (...) {
      // This callback crosses Flutter's C ABI. Never allow allocation, locking,
      // or standard-library exceptions to unwind through the engine.
      return nullptr;
    }
  }

  bool IsSupported() const {
    try {
      return GraphicsCaptureSession::IsSupported();
    } catch (...) {
      return false;
    }
  }

  void EmitState(const std::string& status,
                 const std::string& error_code = "",
                 const std::string& detail = "") {
    EncodableMap event;
    AddString(&event, "type", "state");
    AddString(&event, "status", status);
    if (!error_code.empty()) AddString(&event, "errorCode", error_code);
    if (!detail.empty()) AddString(&event, "detail", detail);
    if (event_callback) event_callback(EncodableValue(std::move(event)));
  }

  bool EmitRecordingState(const std::string& status,
                          const std::string& error_code,
                          const std::string& detail,
                          const std::string& session_id,
                          const std::string& capture_attempt_id) {
    EncodableMap event;
    AddString(&event, "type", "state");
    AddString(&event, "status", status);
    if (!error_code.empty()) AddString(&event, "errorCode", error_code);
    if (!detail.empty()) AddString(&event, "detail", detail);
    AddString(&event, "sessionId", session_id);
    AddString(&event, "captureAttemptId", capture_attempt_id);
    return event_callback && event_callback(EncodableValue(std::move(event)));
  }

  void ReportRecorderFailure(const std::string& error_code,
                             const std::string& error_message,
                             const std::string& session_id,
                             const std::string& capture_attempt_id) {
    if (!recording_failure_signal.TrySignal()) return;
    try {
      if (EmitRecordingState("recordingFailed", error_code, error_message,
                             session_id, capture_attempt_id)) {
        return;
      }
    } catch (...) {
      // Event construction, queueing, or locking can also fail under memory
      // pressure. Let a later callback retry the cleanup handoff.
    }
    // Event posting can fail transiently. Permit the next audio/video callback
    // or an explicit stop to retry instead of permanently suppressing failure.
    recording_failure_signal.Reset();
  }

  // Called with recorder_mutex held. The media writer can fail on its own
  // thread, so publish its terminal error as soon as the next audio/video
  // callback observes it instead of leaving WASAPI running against a dead
  // recorder until the user navigates away.
  void ReportRecorderFailureLocked() {
    if (!recorder) return;
    std::string error_code;
    std::string error_message;
    if (!recorder->Failure(&error_code, &error_message)) return;
    ReportRecorderFailure(error_code, error_message, recording_session_id,
                          recording_capture_attempt_id);
  }

  void SelectSourceAsync(
      SelectionCallback callback,
      const std::shared_ptr<WindowsScreenCapture>& owner) {
    if (IsShuttingDown()) return;
    if (!IsSupported()) {
      callback(std::nullopt, "captureUnsupported",
               "Windows Graphics Capture is not available on this device.");
      return;
    }
    try {
      GraphicsCapturePicker picker;
      auto initialize = picker.as<IInitializeWithWindow>();
      winrt::check_hresult(initialize->Initialize(owner_window));
      picker.PickSingleItemAsync().Completed(
          [owner, callback = std::move(callback)](auto const& operation,
                                                   winrt::Windows::Foundation::AsyncStatus status) mutable {
            try {
              if (!owner || owner->impl_->IsShuttingDown()) return;
              if (status == winrt::Windows::Foundation::AsyncStatus::Canceled) {
                callback(std::nullopt, "captureCancelled", "Screen capture selection was cancelled.");
                return;
              }
              if (status != winrt::Windows::Foundation::AsyncStatus::Completed) {
                callback(std::nullopt, "capturePickerFailed", "Windows could not open the screen capture picker.");
                return;
              }
              const auto item = operation.GetResults();
              if (!item) {
                callback(std::nullopt, "captureCancelled", "Screen capture selection was cancelled.");
                return;
              }
              owner->impl_->StartCaptureItem(item, owner);
              EncodableMap value;
              AddInt(&value, "textureId", owner->impl_->GetTextureId());
              const auto [width, height] = owner->impl_->GetPixelSize();
              AddInt(&value, "width", width);
              AddInt(&value, "height", height);
              AddString(&value, "targetName", WideToUtf8(item.DisplayName().c_str()));
              callback(EncodableValue(std::move(value)), "", "");
            } catch (const winrt::hresult_error& error) {
              if (owner && !owner->impl_->IsShuttingDown()) {
                owner->impl_->StopCapture();
              }
              callback(std::nullopt, "captureStartFailed",
                       WideToUtf8(error.message().c_str()));
            } catch (...) {
              if (owner && !owner->impl_->IsShuttingDown()) {
                owner->impl_->StopCapture();
              }
              callback(std::nullopt, "captureStartFailed",
                       "Windows could not start capture for the selected target.");
            }
          });
    } catch (const winrt::hresult_error& error) {
      callback(std::nullopt, "capturePickerFailed",
               WideToUtf8(error.message().c_str()));
    } catch (...) {
      callback(std::nullopt, "capturePickerFailed",
               "Windows could not initialize the screen capture picker.");
    }
  }

  void StartCaptureItem(
      const GraphicsCaptureItem& item,
      const std::shared_ptr<WindowsScreenCapture>& owner) {
    if (IsShuttingDown()) return;
    StopCapture();
    std::unique_lock<std::mutex> capture_lock(capture_mutex);
    if (IsShuttingDown()) return;
    const uint64_t generation = ++capture_generation;
    D3D_FEATURE_LEVEL feature_level = {};
    const D3D_FEATURE_LEVEL feature_levels[] = {D3D_FEATURE_LEVEL_11_1,
                                                D3D_FEATURE_LEVEL_11_0,
                                                D3D_FEATURE_LEVEL_10_1};
    HRESULT result = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        feature_levels, static_cast<UINT>(std::size(feature_levels)),
        D3D11_SDK_VERSION, &d3d_device, &feature_level, &d3d_context);
    if (FAILED(result)) {
      result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, feature_levels,
                                 static_cast<UINT>(std::size(feature_levels)),
                                 D3D11_SDK_VERSION, &d3d_device, &feature_level,
                                 &d3d_context);
    }
    winrt::check_hresult(result);
    ComPtr<ID3D11Multithread> multithread;
    if (SUCCEEDED(d3d_context.As(&multithread))) {
      multithread->SetMultithreadProtected(TRUE);
    }
    ComPtr<IDXGIDevice> dxgi_device;
    winrt::check_hresult(d3d_device.As(&dxgi_device));
    winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
        dxgi_device.Get(), reinterpret_cast<IInspectable**>(
                               winrt::put_abi(direct_device))));

    capture_item = item;
    auto size = capture_item.Size();
    if (size.Width <= 0 || size.Height <= 0) {
      throw winrt::hresult_invalid_argument();
    }
    {
      std::lock_guard<std::mutex> pixel_lock(pixels_mutex);
      capture_width = static_cast<uint32_t>(size.Width);
      capture_height = static_cast<uint32_t>(size.Height);
      // Do not advertise the new source dimensions alongside pixels left over
      // from the previous source. The texture descriptor must always match the
      // byte buffer it describes.
      pixel_buffer.reset();
      pixel_width = 0;
      pixel_height = 0;
    }
    frame_pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        direct_device, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    frame_arrived_token = frame_pool.FrameArrived(
        [owner, generation](const Direct3D11CaptureFramePool& sender,
               const winrt::Windows::Foundation::IInspectable&) {
          if (owner && owner->impl_) {
            owner->impl_->OnFrameArrived(sender, generation);
          }
        });
    session = frame_pool.CreateCaptureSession(capture_item);
    session.IsCursorCaptureEnabled(true);
    item_closed_token = capture_item.Closed(
        [owner, generation](const GraphicsCaptureItem&,
                const winrt::Windows::Foundation::IInspectable&) {
          if (owner && owner->impl_) {
            const bool stopped =
                owner->impl_->StopCaptureForGeneration(generation);
            if (stopped && !owner->impl_->IsShuttingDown()) {
              owner->impl_->EmitState(
                  "captureStopped", "captureTargetClosed",
                  "The selected window or display was closed.");
            }
          }
        });
    capture_active = true;
    session.StartCapture();
    capture_lock.unlock();
    EmitState("captureStarted");
  }

  void OnFrameArrived(const Direct3D11CaptureFramePool& sender,
                      uint64_t generation) {
    // Snapshot the recording boundary before potentially slow readback. A
    // frame already in flight when recording starts/stops must not leak across
    // into the next file.
    const uint64_t frame_recording_epoch =
        recording_epoch.load(std::memory_order_acquire);
    // Free-threaded frame pools can notify from a worker thread. Keep D3D
    // readback and frame publication ordered without blocking StopCapture on
    // this mutex; stale work is rejected by the generation check below.
    std::lock_guard<std::mutex> frame_lock(frame_processing_mutex);
    ComPtr<ID3D11Device> frame_device;
    ComPtr<ID3D11DeviceContext> frame_context;
    {
      std::lock_guard<std::mutex> capture_lock(capture_mutex);
      if (IsShuttingDown() || !capture_active.load() ||
          generation != capture_generation) {
        return;
      }
      // Hold references to the D3D objects, then release capture_mutex before
      // the potentially slow GPU readback and CPU scaling work below. StopCapture
      // can now invalidate the generation promptly instead of waiting for Map.
      frame_device = d3d_device;
      frame_context = d3d_context;
    }
    if (frame_device.Get() == nullptr || frame_context.Get() == nullptr) return;
    try {
      auto frame = sender.TryGetNextFrame();
      if (!frame) return;
      const int64_t time_100ns = frame.SystemRelativeTime().count();
      const int64_t last_frame_time = last_processed_frame_time_100ns.load();
      if (last_frame_time > 0 &&
          time_100ns - last_frame_time < kVideoFrameDuration100ns) {
        return;
      }
      last_processed_frame_time_100ns.store(time_100ns);
      const auto content_size = frame.ContentSize();
      if (content_size.Width <= 0 || content_size.Height <= 0) return;
      const uint32_t width = static_cast<uint32_t>(content_size.Width);
      const uint32_t height = static_cast<uint32_t>(content_size.Height);
      const auto surface = frame.Surface().as<
          ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
      ComPtr<ID3D11Texture2D> source_texture;
      winrt::check_hresult(surface->GetInterface(
          __uuidof(ID3D11Texture2D),
          reinterpret_cast<void**>(source_texture.GetAddressOf())));
      D3D11_TEXTURE2D_DESC description = {};
      source_texture->GetDesc(&description);
      description.Width = width;
      description.Height = height;
      description.MipLevels = 1;
      description.ArraySize = 1;
      description.BindFlags = 0;
      description.MiscFlags = 0;
      description.Usage = D3D11_USAGE_STAGING;
      description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      ComPtr<ID3D11Texture2D> staging;
      winrt::check_hresult(frame_device->CreateTexture2D(
          &description, nullptr, staging.GetAddressOf()));
      frame_context->CopyResource(staging.Get(), source_texture.Get());
      D3D11_MAPPED_SUBRESOURCE mapped = {};
      winrt::check_hresult(frame_context->Map(staging.Get(), 0,
                                              D3D11_MAP_READ, 0, &mapped));
      struct UnmapScope {
        ID3D11DeviceContext* context;
        ID3D11Resource* resource;
        ~UnmapScope() { context->Unmap(resource, 0); }
      } unmap{frame_context.Get(), staging.Get()};
      if (description.Format != DXGI_FORMAT_B8G8R8A8_UNORM &&
          description.Format != DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) {
        return;
      }
      const size_t row_bytes = static_cast<size_t>(width) * 4;
      if (row_bytes == 0 || height > (std::numeric_limits<size_t>::max() / row_bytes)) {
        return;
      }
      const auto [preview_width, preview_height] =
          FitSize(width, height, 1280, 720, false);
      auto next_pixel_buffer = AcquirePixelBuffer();
      if (next_pixel_buffer) {
        const size_t preview_byte_count =
            static_cast<size_t>(preview_width) * preview_height * 4;
        next_pixel_buffer->pixels.resize(preview_byte_count);
        next_pixel_buffer->width = preview_width;
        next_pixel_buffer->height = preview_height;
      }
      const auto* source_pixels = static_cast<const uint8_t*>(mapped.pData);
      if (next_pixel_buffer) {
        for (uint32_t y = 0; y < preview_height; ++y) {
          const uint32_t source_y = static_cast<uint32_t>(
              static_cast<uint64_t>(y) * height / preview_height);
          const auto* source_row =
              source_pixels + static_cast<size_t>(source_y) * mapped.RowPitch;
          auto* output_row = next_pixel_buffer->pixels.data() +
                             static_cast<size_t>(y) * preview_width * 4;
          for (uint32_t x = 0; x < preview_width; ++x) {
            const uint32_t source_x = static_cast<uint32_t>(
                static_cast<uint64_t>(x) * width / preview_width);
            const auto* source_pixel = source_row +
                                       static_cast<size_t>(source_x) * 4;
            auto* output_pixel = output_row + static_cast<size_t>(x) * 4;
            output_pixel[0] = source_pixel[2];
            output_pixel[1] = source_pixel[1];
            output_pixel[2] = source_pixel[0];
            output_pixel[3] = source_pixel[3];
          }
        }
      }
      {
        // Serialize final frame publication with source invalidation. This
        // keeps a late old-source frame out of a newly started recording while
        // still leaving D3D readback and CPU scaling outside capture_mutex.
        std::lock_guard<std::mutex> commit_lock(frame_commit_mutex);
        bool report_size = false;
        bool preview_published = false;
        {
          std::lock_guard<std::mutex> capture_lock(capture_mutex);
          if (IsShuttingDown() || !capture_active.load() ||
              generation != capture_generation) {
            return;
          }
          std::lock_guard<std::mutex> lock(pixels_mutex);
          if (next_pixel_buffer) {
            pixel_buffer = std::move(next_pixel_buffer);
            pixel_width = preview_width;
            pixel_height = preview_height;
            preview_published = true;
          }
          capture_width = width;
          capture_height = height;
          if (static_cast<int32_t>(width) != last_reported_width ||
              static_cast<int32_t>(height) != last_reported_height) {
            last_reported_width = static_cast<int32_t>(width);
            last_reported_height = static_cast<int32_t>(height);
            report_size = true;
          }
        }
        if (preview_published) MarkTextureFrameAvailable();
        {
          std::lock_guard<std::mutex> lock(recorder_mutex);
          if (frame_recording_epoch ==
                  recording_epoch.load(std::memory_order_acquire) &&
              recorder) {
            if (recorder->active()) {
              recorder->EnqueueVideo(source_pixels, mapped.RowPitch, width,
                                     height, time_100ns);
            }
            ReportRecorderFailureLocked();
          }
        }
        if (report_size) {
          EncodableMap event;
          AddString(&event, "type", "size");
          AddInt(&event, "width", width);
          AddInt(&event, "height", height);
          if (event_callback) event_callback(EncodableValue(std::move(event)));
        }
      }
    } catch (...) {
      try {
        // Only the generation that is still current may report a capture
        // failure. A late exception from a stopped frame must not emit into a
        // replacement session or a window that has begun shutting down.
        const bool stopped = StopCaptureForGeneration(generation);
        if (stopped && !IsShuttingDown()) {
          EmitState("captureFailed", "captureFrameFailed",
                    "Windows failed while reading a capture frame.");
        }
      } catch (...) {
        // Native capture callbacks must not let errors escape onto WinRT's
        // free-threaded event dispatcher.
      }
    }
  }

  void StopCapture() {
    StopCaptureInternal(std::nullopt);
  }

  bool StopCaptureForGeneration(uint64_t expected_generation) {
    return StopCaptureInternal(
        std::optional<uint64_t>{expected_generation});
  }

  bool StopCaptureInternal(std::optional<uint64_t> expected_generation) {
    GraphicsCaptureItem stopped_item{nullptr};
    Direct3D11CaptureFramePool stopped_frame_pool{nullptr};
    GraphicsCaptureSession stopped_session{nullptr};
    winrt::event_token stopped_item_closed_token{};
    winrt::event_token stopped_frame_arrived_token{};
    {
      std::lock_guard<std::mutex> commit_lock(frame_commit_mutex);
      std::lock_guard<std::mutex> lock(capture_mutex);
      if (expected_generation.has_value() &&
          expected_generation.value() != capture_generation) {
        return false;
      }
      ++capture_generation;
      capture_active.store(false);
      stopped_item = capture_item;
      stopped_frame_pool = frame_pool;
      stopped_session = session;
      stopped_item_closed_token = item_closed_token;
      stopped_frame_arrived_token = frame_arrived_token;
      capture_item = nullptr;
      frame_pool = nullptr;
      session = nullptr;
      item_closed_token = {};
      frame_arrived_token = {};
      direct_device = nullptr;
      d3d_context.Reset();
      d3d_device.Reset();
      {
        std::lock_guard<std::mutex> pixel_lock(pixels_mutex);
        pixel_buffer.reset();
        pixel_width = 0;
        pixel_height = 0;
        capture_width = 0;
        capture_height = 0;
      }
    }
    try {
      if (stopped_item && stopped_item_closed_token.value != 0) {
        stopped_item.Closed(stopped_item_closed_token);
      }
      if (stopped_frame_pool && stopped_frame_arrived_token.value != 0) {
        stopped_frame_pool.FrameArrived(stopped_frame_arrived_token);
      }
      if (stopped_session) stopped_session.Close();
      if (stopped_frame_pool) stopped_frame_pool.Close();
    } catch (...) {
      // Continue releasing the remaining WinRT and D3D objects.
    }
    MarkTextureFrameAvailable();
    return true;
  }

  bool StartRecording(const std::wstring& path,
                      const std::string& session_id,
                      const std::string& capture_attempt_id,
                      std::string* error_code,
                      std::string* error_message) {
    if (!capture_active.load()) {
      if (error_code) *error_code = "captureNotActive";
      if (error_message) *error_message = "Select a screen or window before recording.";
      return false;
    }
    if (session_id.empty() || capture_attempt_id.empty()) {
      if (error_code) *error_code = "invalidRecordingIdentity";
      if (error_message) *error_message = "The recording session identity is missing.";
      return false;
    }
    uint32_t width = 0;
    uint32_t height = 0;
    {
      std::lock_guard<std::mutex> pixel_lock(pixels_mutex);
      const auto fitted = FitSize(capture_width, capture_height, 1920, 1080,
                                  true);
      width = fitted.first;
      height = fitted.second;
    }
    std::lock_guard<std::mutex> lock(recorder_mutex);
    if (recorder) {
      const bool recorder_active = recorder->active();
      if (error_code) {
        *error_code = recorder_active ? "recordingAlreadyActive"
                                      : "recordingCleanupPending";
      }
      if (error_message) {
        *error_message = recorder_active
                             ? "A screen recording is already active."
                             : "The previous recording is still being cleaned up.";
      }
      return false;
    }
    recording_failure_signal.Reset();
    recording_epoch.fetch_add(1, std::memory_order_acq_rel);
    recording_session_id = session_id;
    recording_capture_attempt_id = capture_attempt_id;
    // Capture immutable identity copies in the worker callback. StopRecording
    // can clear the active identity only after joining this worker.
    const std::string recording_session_id_copy = recording_session_id;
    const std::string recording_attempt_id_copy =
        recording_capture_attempt_id;
    recorder = std::make_unique<LocalMp4Recorder>(
        [this, recording_session_id_copy, recording_attempt_id_copy](
            const std::string& failure_code,
            const std::string& failure_message) {
          ReportRecorderFailure(failure_code, failure_message,
                                recording_session_id_copy,
                                recording_attempt_id_copy);
        });
    if (!recorder->Start(path, width, height, error_code, error_message)) {
      recorder.reset();
      recording_session_id.clear();
      recording_capture_attempt_id.clear();
      return false;
    }
    recording_path = path;
    EmitRecordingState("recordingStarted", "", WideToUtf8(path),
                       recording_session_id,
                       recording_capture_attempt_id);
    return true;
  }

  bool StopRecording(std::string* output_path,
                     std::string* error_code,
                     std::string* error_message) {
    std::lock_guard<std::mutex> lock(recorder_mutex);
    recording_epoch.fetch_add(1, std::memory_order_acq_rel);
    if (!recorder) {
      if (output_path) *output_path = {};
      return true;
    }
    const bool success = recorder->Stop(output_path, error_code, error_message);
    const bool failure_already_reported =
        recording_failure_signal.IsSignalled();
    recorder.reset();
    if (success) {
      EmitRecordingState("recordingFinalized", "",
                         output_path == nullptr ? "" : *output_path,
                         recording_session_id,
                         recording_capture_attempt_id);
    } else if (!failure_already_reported) {
      ReportRecorderFailure(
          error_code == nullptr ? "recordingFailed" : *error_code,
          error_message == nullptr ? "" : *error_message,
          recording_session_id, recording_capture_attempt_id);
    }
    return success;
  }

  bool PushAudioFrame(const EncodableValue& event) {
    std::lock_guard<std::mutex> lock(recorder_mutex);
    if (!recorder) return false;
    const bool was_active = recorder->active();
    const bool accepted = was_active && recorder->EnqueueAudio(event);
    ReportRecorderFailureLocked();
    return accepted;
  }

  HWND owner_window = nullptr;
  FlutterDesktopTextureRegistrarRef texture_registrar = nullptr;
  EventCallback event_callback;
  int64_t texture_id = -1;
  std::mutex texture_mutex;
  std::atomic<bool> shutdown_requested{false};
  std::shared_ptr<TextureUnregistrationCompletion> texture_unregistration =
      std::make_shared<TextureUnregistrationCompletion>();
  std::unique_ptr<TextureUnregisterCallbackContext>
      texture_unregistration_context;
  std::shared_ptr<void> texture_unregistration_fallback_owner;
  std::atomic<bool> capture_active{false};
  std::atomic<uint64_t> recording_epoch{0};
  std::mutex capture_mutex;
  std::mutex frame_processing_mutex;
  std::mutex frame_commit_mutex;
  uint64_t capture_generation = 0;
  GraphicsCaptureItem capture_item{nullptr};
  Direct3D11CaptureFramePool frame_pool{nullptr};
  GraphicsCaptureSession session{nullptr};
  winrt::event_token frame_arrived_token{};
  winrt::event_token item_closed_token{};
  IDirect3DDevice direct_device{nullptr};
  ComPtr<ID3D11Device> d3d_device;
  ComPtr<ID3D11DeviceContext> d3d_context;
  std::mutex pixels_mutex;
  std::shared_ptr<const PixelBuffer> pixel_buffer;
  std::array<std::shared_ptr<PixelBuffer>, 3> pixel_buffer_pool{};
  uint32_t pixel_width = 0;
  uint32_t pixel_height = 0;
  uint32_t capture_width = 0;
  uint32_t capture_height = 0;
  std::atomic<int64_t> last_processed_frame_time_100ns{0};
  int32_t last_reported_width = 0;
  int32_t last_reported_height = 0;
  std::mutex recorder_mutex;
  std::unique_ptr<LocalMp4Recorder> recorder;
  RecordingFailureSignal recording_failure_signal;
  std::string recording_session_id;
  std::string recording_capture_attempt_id;
  std::wstring recording_path;
};

WindowsScreenCapture::WindowsScreenCapture(
    HWND owner_window,
    FlutterDesktopTextureRegistrarRef texture_registrar,
    EventCallback event_callback)
    : impl_(std::make_shared<Impl>(owner_window, texture_registrar,
                                   std::move(event_callback))) {}

WindowsScreenCapture::~WindowsScreenCapture() {
  if (!impl_) return;
  try {
    // The Impl is still shared-owned here. Transfer that ownership to Flutter's
    // unregister callback before dropping the wrapper's last reference.
    impl_->Shutdown(false, impl_);
  } catch (...) {
    // Preserve noexcept destruction. Shutdown's native stop paths already
    // contain their own failures; the callback owner remains in Impl whenever
    // asynchronous texture unregistration has started.
  }
}

bool WindowsScreenCapture::IsSupported() const {
  return impl_ != nullptr && impl_->IsSupported();
}

void WindowsScreenCapture::SelectSourceAsync(SelectionCallback callback) {
  impl_->SelectSourceAsync(std::move(callback), shared_from_this());
}

void WindowsScreenCapture::StopCapture() {
  if (impl_) impl_->StopCapture();
}

void WindowsScreenCapture::Shutdown(std::chrono::milliseconds wait_timeout) {
  if (impl_) impl_->Shutdown(true, impl_, wait_timeout);
}

void WindowsScreenCapture::ShutdownForNavigation() {
  if (impl_) impl_->Shutdown(false, impl_, std::chrono::milliseconds(0));
}

bool WindowsScreenCapture::IsShutdownComplete() const {
  return impl_ == nullptr || impl_->IsShutdownComplete();
}

bool WindowsScreenCapture::StartRecording(const std::wstring& output_path,
                                          const std::string& session_id,
                                          const std::string& capture_attempt_id,
                                          std::string* error_code,
                                          std::string* error_message) {
  return impl_ && impl_->StartRecording(output_path, session_id,
                                        capture_attempt_id, error_code,
                                        error_message);
}

bool WindowsScreenCapture::StopRecording(std::string* output_path,
                                         std::string* error_code,
                                         std::string* error_message) {
  return impl_ && impl_->StopRecording(output_path, error_code, error_message);
}

bool WindowsScreenCapture::PushAudioFrame(const EncodableValue& event) {
  return impl_ && impl_->PushAudioFrame(event);
}

bool WindowsScreenCapture::IsRecording() const {
  if (!impl_) return false;
  std::lock_guard<std::mutex> lock(impl_->recorder_mutex);
  return impl_->recorder && impl_->recorder->active();
}
