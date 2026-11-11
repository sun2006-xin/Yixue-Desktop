#include <windows.h>

#include <cstdlib>
#include <iostream>
#include <string>

#include "hotkey_key_mapping.h"

namespace {

void Require(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(EXIT_FAILURE);
  }
}

void TestHidUsageToScanCode() {
  using hotkey_manager_windows::HidKeyboardUsageToSet1ScanCode;

  const auto key_y = HidKeyboardUsageToSet1ScanCode(0x0007001c);
  Require(key_y.has_value(), "HID Keyboard Y usage must be supported");
  Require(key_y->code == 0x15 && !key_y->extended,
          "HID Keyboard Y must map to Set-1 scan code 0x15");

  const auto arrow_right = HidKeyboardUsageToSet1ScanCode(0x0007004f);
  Require(arrow_right.has_value(), "HID Arrow Right usage must be supported");
  Require(arrow_right->code == 0x4d && arrow_right->extended,
          "HID Arrow Right must preserve the E0 scan-code prefix");

  Require(!HidKeyboardUsageToSet1ScanCode(0x000c00b5).has_value(),
          "consumer-page usages must be rejected");
  Require(!HidKeyboardUsageToSet1ScanCode(0x000700e0).has_value(),
          "modifier usages must not be accepted as the primary key");
  Require(!HidKeyboardUsageToSet1ScanCode(0x00070048).has_value(),
          "multi-byte Pause usage must be rejected until it can be mapped safely");
}

void TestLayoutIsUsedForVirtualKeyMapping() {
  using hotkey_manager_windows::ResolveHidKeyboardUsageToVirtualKey;

  int calls = 0;
  const auto us_vk = ResolveHidKeyboardUsageToVirtualKey(
      0x0007001c, 1,
      [&calls](uint32_t scan_code, int layout) -> uint32_t {
        ++calls;
        Require(scan_code == 0x15, "mapper must receive the physical scan code");
        return layout == 1 ? 0x59 : 0x5a;
      });
  const auto qwertz_vk = ResolveHidKeyboardUsageToVirtualKey(
      0x0007001c, 2,
      [&calls](uint32_t scan_code, int layout) -> uint32_t {
        ++calls;
        Require(scan_code == 0x15, "mapper must receive the physical scan code");
        return layout == 1 ? 0x59 : 0x5a;
      });
  Require(us_vk.has_value() && *us_vk == 0x59u,
          "US layout should resolve the selected position to VK_Y");
  Require(qwertz_vk.has_value() && *qwertz_vk == 0x5au,
          "QWERTZ layout should resolve the same position to VK_Z");
  Require(calls == 2, "mapper must be called once per valid usage");

  const auto invalid_vk = ResolveHidKeyboardUsageToVirtualKey(
      0x0007001c, 1,
      [](uint32_t, int) -> uint32_t { return 0; });
  Require(!invalid_vk.has_value(), "unmapped Windows keys must be rejected");

  int invalid_usage_calls = 0;
  const auto invalid_usage = ResolveHidKeyboardUsageToVirtualKey(
      0x000c00b5, 1,
      [&invalid_usage_calls](uint32_t, int) -> uint32_t {
        ++invalid_usage_calls;
        return 0x59;
      });
  Require(!invalid_usage.has_value(), "unsupported HID usages must fail closed");
  Require(invalid_usage_calls == 0,
          "Windows mapper must not run for an unsupported HID usage");
}

void TestWindowsKeyboardLayouts() {
  using hotkey_manager_windows::ResolveHidKeyboardUsageToVirtualKey;

  const HKL us = LoadKeyboardLayoutW(L"00000409", KLF_NOTELLSHELL);
  const HKL qwertz = LoadKeyboardLayoutW(L"00000407", KLF_NOTELLSHELL);
  Require(us != nullptr, "could not load the Windows English (US) layout");
  Require(qwertz != nullptr, "could not load the Windows German (QWERTZ) layout");

  const auto map_scan_code = [](uint32_t scan_code, HKL layout) -> uint32_t {
    return MapVirtualKeyExW(scan_code, MAPVK_VSC_TO_VK_EX, layout);
  };
  const auto us_vk = ResolveHidKeyboardUsageToVirtualKey(
      0x0007001c, us, map_scan_code);
  const auto qwertz_vk = ResolveHidKeyboardUsageToVirtualKey(
      0x0007001c, qwertz, map_scan_code);
  Require(us_vk.has_value() && *us_vk == 0x59u,
          "US layout must map HID Y position to VK_Y");
  Require(qwertz_vk.has_value() && *qwertz_vk == 0x5au,
          "German QWERTZ layout must map HID Y position to VK_Z");
}

}  // namespace

int main() {
  TestHidUsageToScanCode();
  TestLayoutIsUsedForVirtualKeyMapping();
  TestWindowsKeyboardLayouts();
  std::cout << "All native hotkey key-mapping checks passed.\n";
  return EXIT_SUCCESS;
}
