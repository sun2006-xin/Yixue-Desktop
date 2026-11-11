#ifndef HOTKEY_MANAGER_WINDOWS_HOTKEY_KEY_MAPPING_H_
#define HOTKEY_MANAGER_WINDOWS_HOTKEY_KEY_MAPPING_H_

#include <cstdint>
#include <optional>
#include <utility>

namespace hotkey_manager_windows {

struct Set1ScanCode {
  uint8_t code;
  bool extended;
};

inline std::optional<Set1ScanCode> HidKeyboardUsageToSet1ScanCode(
    uint32_t usage_code) {
  if ((usage_code & 0xffff0000u) != 0x00070000u) {
    return std::nullopt;
  }

  const uint32_t usage = usage_code & 0xffffu;
  if (usage >= 0x04u && usage <= 0x1du) {
    static constexpr uint8_t kLetterScanCodes[] = {
        0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24,
        0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1f, 0x14,
        0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c};
    return Set1ScanCode{kLetterScanCodes[usage - 0x04u], false};
  }

  if (usage >= 0x1eu && usage <= 0x27u) {
    static constexpr uint8_t kDigitScanCodes[] = {
        0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b};
    return Set1ScanCode{kDigitScanCodes[usage - 0x1eu], false};
  }

  if (usage >= 0x3au && usage <= 0x43u) {
    return Set1ScanCode{static_cast<uint8_t>(0x3bu + usage - 0x3au), false};
  }

  switch (usage) {
    case 0x28:  // Enter
      return Set1ScanCode{0x1c, false};
    case 0x29:  // Escape
      return Set1ScanCode{0x01, false};
    case 0x2a:  // Backspace
      return Set1ScanCode{0x0e, false};
    case 0x2b:  // Tab
      return Set1ScanCode{0x0f, false};
    case 0x2c:  // Space
      return Set1ScanCode{0x39, false};
    case 0x2d:  // - and _
      return Set1ScanCode{0x0c, false};
    case 0x2e:  // = and +
      return Set1ScanCode{0x0d, false};
    case 0x2f:  // [ and {
      return Set1ScanCode{0x1a, false};
    case 0x30:  // ] and }
      return Set1ScanCode{0x1b, false};
    case 0x31:  // \ and |
      return Set1ScanCode{0x2b, false};
    case 0x33:  // ; and :
      return Set1ScanCode{0x27, false};
    case 0x34:  // ' and "
      return Set1ScanCode{0x28, false};
    case 0x35:  // ` and ~
      return Set1ScanCode{0x29, false};
    case 0x36:  // , and <
      return Set1ScanCode{0x33, false};
    case 0x37:  // . and >
      return Set1ScanCode{0x34, false};
    case 0x38:  // / and ?
      return Set1ScanCode{0x35, false};
    case 0x39:  // Caps Lock
      return Set1ScanCode{0x3a, false};
    case 0x44:  // F11
      return Set1ScanCode{0x57, false};
    case 0x45:  // F12
      return Set1ScanCode{0x58, false};
    case 0x46:  // Print Screen
      return Set1ScanCode{0x37, true};
    case 0x47:  // Scroll Lock
      return Set1ScanCode{0x46, false};
    case 0x49:  // Insert
      return Set1ScanCode{0x52, true};
    case 0x4a:  // Home
      return Set1ScanCode{0x47, true};
    case 0x4b:  // Page Up
      return Set1ScanCode{0x49, true};
    case 0x4c:  // Delete
      return Set1ScanCode{0x53, true};
    case 0x4d:  // End
      return Set1ScanCode{0x4f, true};
    case 0x4e:  // Page Down
      return Set1ScanCode{0x51, true};
    case 0x4f:  // Arrow Right
      return Set1ScanCode{0x4d, true};
    case 0x50:  // Arrow Left
      return Set1ScanCode{0x4b, true};
    case 0x51:  // Arrow Down
      return Set1ScanCode{0x50, true};
    case 0x52:  // Arrow Up
      return Set1ScanCode{0x48, true};
    case 0x53:  // Num Lock
      return Set1ScanCode{0x45, false};
    case 0x54:  // Keypad /
      return Set1ScanCode{0x35, true};
    case 0x55:  // Keypad *
      return Set1ScanCode{0x37, false};
    case 0x56:  // Keypad -
      return Set1ScanCode{0x4a, false};
    case 0x57:  // Keypad +
      return Set1ScanCode{0x4e, false};
    case 0x58:  // Keypad Enter
      return Set1ScanCode{0x1c, true};
    case 0x59:  // Keypad 1
      return Set1ScanCode{0x4f, false};
    case 0x5a:  // Keypad 2
      return Set1ScanCode{0x50, false};
    case 0x5b:  // Keypad 3
      return Set1ScanCode{0x51, false};
    case 0x5c:  // Keypad 4
      return Set1ScanCode{0x4b, false};
    case 0x5d:  // Keypad 5
      return Set1ScanCode{0x4c, false};
    case 0x5e:  // Keypad 6
      return Set1ScanCode{0x4d, false};
    case 0x5f:  // Keypad 7
      return Set1ScanCode{0x47, false};
    case 0x60:  // Keypad 8
      return Set1ScanCode{0x48, false};
    case 0x61:  // Keypad 9
      return Set1ScanCode{0x49, false};
    case 0x62:  // Keypad 0
      return Set1ScanCode{0x52, false};
    case 0x63:  // Keypad .
      return Set1ScanCode{0x53, false};
    case 0x65:  // Application
      return Set1ScanCode{0x5d, true};
    case 0x67:  // Keypad =
      return Set1ScanCode{0x59, false};
    default:
      return std::nullopt;
  }
}

template <typename Layout, typename MapScanCode>
inline std::optional<uint32_t> ResolveHidKeyboardUsageToVirtualKey(
    uint32_t usage_code,
    Layout layout,
    MapScanCode&& map_scan_code) {
  const auto scan_code = HidKeyboardUsageToSet1ScanCode(usage_code);
  if (!scan_code.has_value()) {
    return std::nullopt;
  }

  const uint32_t windows_scan_code =
      scan_code->code | (scan_code->extended ? 0xe000u : 0u);
  const uint32_t virtual_key =
      std::forward<MapScanCode>(map_scan_code)(windows_scan_code, layout);
  if (virtual_key == 0 || virtual_key > 0xffu) {
    return std::nullopt;
  }
  return virtual_key;
}

}  // namespace hotkey_manager_windows

#endif  // HOTKEY_MANAGER_WINDOWS_HOTKEY_KEY_MAPPING_H_
