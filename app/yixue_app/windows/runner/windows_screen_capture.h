#ifndef RUNNER_WINDOWS_SCREEN_CAPTURE_H_
#define RUNNER_WINDOWS_SCREEN_CAPTURE_H_

#include <flutter/encodable_value.h>
#include <flutter_texture_registrar.h>

#include <chrono>
#include <functional>
#include <memory>
#include <optional>
#include <string>

#include <windows.h>

// Windows Graphics Capture preview and optional local MP4 recording.
// Screen pixels stay in the native runner; Flutter receives only state and a
// registered texture ID.
class WindowsScreenCapture
    : public std::enable_shared_from_this<WindowsScreenCapture> {
 public:
  using EventCallback =
      std::function<bool(flutter::EncodableValue event)>;
  using SelectionCallback = std::function<void(
      std::optional<flutter::EncodableValue> value,
      const std::string& error_code,
      const std::string& error_message)>;

  WindowsScreenCapture(
      HWND owner_window,
      FlutterDesktopTextureRegistrarRef texture_registrar,
      EventCallback event_callback);
  ~WindowsScreenCapture();

  WindowsScreenCapture(const WindowsScreenCapture&) = delete;
  WindowsScreenCapture& operator=(const WindowsScreenCapture&) = delete;

  bool IsSupported() const;
  void SelectSourceAsync(SelectionCallback callback);
  void StopCapture();
  void Shutdown(std::chrono::milliseconds wait_timeout =
                    std::chrono::seconds(2));
  void ShutdownForNavigation();
  bool IsShutdownComplete() const;

  bool StartRecording(const std::wstring& output_path,
                      const std::string& session_id,
                      const std::string& capture_attempt_id,
                      std::string* error_code,
                      std::string* error_message);
  bool StopRecording(std::string* output_path,
                     std::string* error_code,
                     std::string* error_message);
  bool PushAudioFrame(const flutter::EncodableValue& event);
  bool IsRecording() const;

 private:
  struct Impl;
  std::shared_ptr<Impl> impl_;
};

#endif  // RUNNER_WINDOWS_SCREEN_CAPTURE_H_
