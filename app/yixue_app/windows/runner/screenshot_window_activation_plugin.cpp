#include "screenshot_window_activation_plugin.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>

namespace {

constexpr char kChannelName[] = "yixue/screenshot_translation/native_window";
constexpr char kSetNoActivateMethod[] = "setNoActivate";

class ScreenshotWindowActivationPlugin : public flutter::Plugin {
public:
  explicit ScreenshotWindowActivationPlugin(
      flutter::PluginRegistrarWindows *registrar)
      : registrar_(registrar) {
    auto *view = registrar_->GetView();
    if (view != nullptr) {
      window_ = GetAncestor(view->GetNativeWindow(), GA_ROOT);
    }

    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND window, UINT message, WPARAM,
               LPARAM) -> std::optional<LRESULT> {
          if (message == WM_MOUSEACTIVATE && window == window_ &&
              (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_NOACTIVATE) !=
                  0) {
            // MA_NOACTIVATE passes the mouse message through to Flutter.
            // MA_NOACTIVATEANDEAT would swallow the click and break the orb.
            return MA_NOACTIVATE;
          }
          return std::nullopt;
        });

    channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar_->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto &call, auto result) {
      HandleMethodCall(call, std::move(result));
    });
  }

  ~ScreenshotWindowActivationPlugin() override {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
    channel_.reset();
  }

private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() != kSetNoActivateMethod) {
      result->NotImplemented();
      return;
    }
    if (!SetNoActivateStyle()) {
      const DWORD error = GetLastError();
      result->Error("set_no_activate_failed",
                    "Unable to mark screenshot orb as non-activating; " +
                        std::to_string(error));
      return;
    }
    result->Success(flutter::EncodableValue(true));
  }

  bool SetNoActivateStyle() const {
    if (window_ == nullptr || !IsWindow(window_)) {
      SetLastError(ERROR_INVALID_WINDOW_HANDLE);
      return false;
    }

    SetLastError(ERROR_SUCCESS);
    const LONG_PTR current_style = GetWindowLongPtrW(window_, GWL_EXSTYLE);
    if (current_style == 0 && GetLastError() != ERROR_SUCCESS) {
      return false;
    }

    if ((current_style & WS_EX_NOACTIVATE) == 0) {
      SetLastError(ERROR_SUCCESS);
      const LONG_PTR previous_style = SetWindowLongPtrW(
          window_, GWL_EXSTYLE, current_style | WS_EX_NOACTIVATE);
      if (previous_style == 0 && GetLastError() != ERROR_SUCCESS) {
        return false;
      }
    }

    return SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                            SWP_NOACTIVATE | SWP_FRAMECHANGED) != FALSE;
  }

  flutter::PluginRegistrarWindows *registrar_;
  HWND window_ = nullptr;
  int window_proc_id_ = -1;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

} // namespace

void RegisterScreenshotChildWindowActivationPlugin(
    flutter::PluginRegistry *registry) {
  auto *registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            registry->GetRegistrarForPlugin(
                                "ScreenshotChildWindowActivationPlugin"));
  registrar->AddPlugin(
      std::make_unique<ScreenshotWindowActivationPlugin>(registrar));
}
