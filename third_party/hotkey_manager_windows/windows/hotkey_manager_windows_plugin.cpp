#include "hotkey_manager_windows_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <cstdint>
#include <limits>
#include <optional>
#include <sstream>

#include "hotkey_key_mapping.h"

namespace hotkey_manager_windows {

namespace {

std::optional<int64_t> ReadInteger(const flutter::EncodableValue& value) {
  if (const auto* value32 = std::get_if<int32_t>(&value)) {
    return *value32;
  }
  if (const auto* value64 = std::get_if<int64_t>(&value)) {
    return *value64;
  }
  return std::nullopt;
}

void ReportInvalidHotkey(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  result->Error("invalid_hotkey", "The hotkey payload is invalid");
}

}  // namespace

// static
void HotkeyManagerWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "dev.leanflutter.plugins/hotkey_manager",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<HotkeyManagerWindowsPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(),
          "dev.leanflutter.plugins/hotkey_manager_event",
          &flutter::StandardMethodCodec::GetInstance());
  auto streamHandler = std::make_unique<flutter::StreamHandlerFunctions<>>(
      [plugin_pointer = plugin.get()](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        return plugin_pointer->OnListen(arguments, std::move(events));
      },
      [plugin_pointer = plugin.get()](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        return plugin_pointer->OnCancel(arguments);
      });
  event_channel->SetStreamHandler(std::move(streamHandler));

  registrar->AddPlugin(std::move(plugin));
}

HotkeyManagerWindowsPlugin::HotkeyManagerWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar) {
  registrar_ = registrar;
  window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

HotkeyManagerWindowsPlugin::~HotkeyManagerWindowsPlugin() {}

std::optional<LRESULT> HotkeyManagerWindowsPlugin::HandleWindowProc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) {
  switch (message) {
    case WM_HOTKEY: {
      int32_t hotkey_id = static_cast<int32_t>(wparam);
      for (const auto& [identifier, id] : hotkey_id_map_) {
        if (id == hotkey_id) {
          flutter::EncodableMap args = flutter::EncodableMap();
          args[flutter::EncodableValue("type")] = "onKeyDown";
          args[flutter::EncodableValue("data")] =
              flutter::EncodableMap({{"identifier", identifier}});
          if (event_sink_) {
            event_sink_->Success(flutter::EncodableValue(args));
          }
          break;
        }
      }
    }
  }
  return std::nullopt;
}

void HotkeyManagerWindowsPlugin::Register(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());
  const auto key_code_it = args.find(flutter::EncodableValue("keyCode"));
  const auto key_it = args.find(flutter::EncodableValue("key"));
  uint32_t virtual_key = 0;

  if (key_it != args.end()) {
    const auto* key_map = std::get_if<flutter::EncodableMap>(&key_it->second);
    if (key_map == nullptr) {
      ReportInvalidHotkey(std::move(result));
      return;
    }

    const auto usage_it = key_map->find(flutter::EncodableValue("usageCode"));
    const auto key_id_it = key_map->find(flutter::EncodableValue("keyId"));
    if (usage_it != key_map->end()) {
      if (key_id_it != key_map->end()) {
        ReportInvalidHotkey(std::move(result));
        return;
      }
      const auto usage_code = ReadInteger(usage_it->second);
      if (!usage_code.has_value() || *usage_code < 0 ||
          static_cast<uint64_t>(*usage_code) >
              (std::numeric_limits<uint32_t>::max)()) {
        ReportInvalidHotkey(std::move(result));
        return;
      }

      const HKL layout = ::GetKeyboardLayout(0);
      if (layout == nullptr) {
        result->Error("keyboard_layout_unavailable",
                      "Windows could not determine the current keyboard layout");
        return;
      }
      const auto resolved_key = ResolveHidKeyboardUsageToVirtualKey(
          static_cast<uint32_t>(*usage_code), layout,
          [](uint32_t scan_code, HKL keyboard_layout) -> uint32_t {
            return ::MapVirtualKeyExW(scan_code, MAPVK_VSC_TO_VK_EX,
                                      keyboard_layout);
          });
      if (!resolved_key.has_value()) {
        result->Error(
            "unsupported_keyboard_key",
            "Windows cannot map this physical key for the current layout",
            flutter::EncodableValue(static_cast<int64_t>(*usage_code)));
        return;
      }
      virtual_key = *resolved_key;
    } else {
      if (key_id_it == key_map->end() || key_code_it == args.end()) {
        ReportInvalidHotkey(std::move(result));
        return;
      }
      const auto logical_key_id = ReadInteger(key_id_it->second);
      const auto logical_key_code = ReadInteger(key_code_it->second);
      if (!logical_key_id.has_value() || !logical_key_code.has_value() ||
          *logical_key_code <= 0 || *logical_key_code > 0xff) {
        ReportInvalidHotkey(std::move(result));
        return;
      }
      virtual_key = static_cast<uint32_t>(*logical_key_code);
    }
  } else {
    // Keep the legacy channel shape usable for callers that send an already
    // resolved Win32 virtual-key code without the serialized key descriptor.
    if (key_code_it == args.end()) {
      ReportInvalidHotkey(std::move(result));
      return;
    }
    const auto legacy_key_code = ReadInteger(key_code_it->second);
    if (!legacy_key_code.has_value() || *legacy_key_code <= 0 ||
        *legacy_key_code > 0xff) {
      ReportInvalidHotkey(std::move(result));
      return;
    }
    virtual_key = static_cast<uint32_t>(*legacy_key_code);
  }

  std::vector<std::string> modifiers;
  std::string identifier =
      std::get<std::string>(args.at(flutter::EncodableValue("identifier")));
  flutter::EncodableList key_modifier_list = std::get<flutter::EncodableList>(
      args.at(flutter::EncodableValue("modifiers")));
  for (flutter::EncodableValue key_modifier_value : key_modifier_list) {
    std::string key_modifier = std::get<std::string>(key_modifier_value);
    modifiers.push_back(key_modifier);
  }
  int32_t hotkey_id = ++last_registered_hotkey_id_;
  UINT fs_modifiers = GetFsModifiersFromString(modifiers);
  const BOOL registered = ::RegisterHotKey(
      ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT),
      hotkey_id, fs_modifiers, virtual_key);
  if (!registered) {
    const DWORD error = ::GetLastError();
    result->Error(error == ERROR_HOTKEY_ALREADY_REGISTERED
                      ? "hotkey_conflict"
                      : "hotkey_registration_failed",
                  "Windows could not register the global hotkey",
                  flutter::EncodableValue(static_cast<int32_t>(error)));
    return;
  }
  hotkey_id_map_.insert(std::make_pair(identifier, hotkey_id));
  result->Success(flutter::EncodableValue(true));
}

void HotkeyManagerWindowsPlugin::Unregister(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());
  std::string identifier =
      std::get<std::string>(args.at(flutter::EncodableValue("identifier")));
  int32_t hotkey_id = hotkey_id_map_.at(identifier);
  ::UnregisterHotKey(
      ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT),
      hotkey_id);
  hotkey_id_map_.erase(identifier);
  result->Success(flutter::EncodableValue(true));
}

void HotkeyManagerWindowsPlugin::UnregisterAll(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  for (auto it = hotkey_id_map_.begin(); it != hotkey_id_map_.end(); ++it) {
    std::string identifier = it->first;
    int32_t hotkey_id = it->second;
    ::UnregisterHotKey(
        ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT),
        hotkey_id);
  }
  hotkey_id_map_.clear();
  result->Success(flutter::EncodableValue(true));
}

UINT HotkeyManagerWindowsPlugin::GetFsModifiersFromString(
    const std::vector<std::string>& modifiers) {
  UINT fs_modifiers = 0x0000;
  for (int32_t i = 0; i < modifiers.size(); i++) {
    UINT fs_modifier = 0x0000;
    if (modifiers[i] == "alt") {
      fs_modifier = MOD_ALT;
    } else if (modifiers[i] == "control") {
      fs_modifier = MOD_CONTROL;
    } else if (modifiers[i] == "meta") {
      fs_modifier = MOD_WIN;
    } else if (modifiers[i] == "shift") {
      fs_modifier = MOD_SHIFT;
    }
    fs_modifiers = fs_modifiers | fs_modifier;
  }
  return fs_modifiers;
}

void HotkeyManagerWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("register") == 0) {
    Register(method_call, std::move(result));
  } else if (method_call.method_name().compare("unregister") == 0) {
    Unregister(method_call, std::move(result));
  } else if (method_call.method_name().compare("unregisterAll") == 0) {
    UnregisterAll(method_call, std::move(result));
  } else {
    result->NotImplemented();
  }
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
HotkeyManagerWindowsPlugin::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  event_sink_ = std::move(events);
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
HotkeyManagerWindowsPlugin::OnCancelInternal(
    const flutter::EncodableValue* arguments) {
  event_sink_ = nullptr;
  return nullptr;
}

}  // namespace hotkey_manager_windows
