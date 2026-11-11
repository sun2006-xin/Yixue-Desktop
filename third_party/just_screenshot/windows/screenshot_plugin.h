#ifndef FLUTTER_PLUGIN_SCREENSHOT_PLUGIN_H_
#define FLUTTER_PLUGIN_SCREENSHOT_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <memory>

namespace screenshot {

// Windows implementation of the screenshot plugin.
// 
// Error Codes (returned via MethodResult::Error):
// - "capture_in_progress": A second capture was requested during selection
// - "not_supported": Screenshot operation is not supported on this platform (non-Windows)
// - "internal_error": Internal Windows API error occurred (BitBlt, WIC encoding, memory allocation failure)
//                     Details contain Win32 error code (GetLastError) or error description
// - "invalid_argument": Invalid parameters provided (missing 'mode', invalid mode value, invalid parameter types)
//
// Return Values:
// - Success with Map: 'left', 'top', 'width', 'height' in physical screen pixels,
//                     including negative display origins, and 'bytes' (PNG)
// - Success with null: User cancelled (region mode ESC/right-click) - not an error
// - Error: Operation failed, see error codes above
class ScreenshotPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  ScreenshotPlugin();

  virtual ~ScreenshotPlugin();

  // Disallow copy and assign.
  ScreenshotPlugin(const ScreenshotPlugin&) = delete;
  ScreenshotPlugin& operator=(const ScreenshotPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  // 
  // Supported methods:
  // - "capture": Capture screenshot (screen or region mode)
  //   Parameters: { mode: "screen"|"region", includeCursor?: bool, displayId?: int }
  //   Returns: { left: int, top: int, width: int, height: int, bytes: Uint8List }
  //            or null for Esc, right-click, or an empty/clipped-away selection
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  // Keeps a capture busy until its asynchronous PNG encoding reply completes.
  // Workers retain this shared state and never access the plugin instance.
  std::shared_ptr<std::atomic_bool> capture_in_progress_;
};

}  // namespace screenshot

#endif  // FLUTTER_PLUGIN_SCREENSHOT_PLUGIN_H_
