#include "screenshot_translation_native_orb_plugin.h"
#include "screenshot_orb_drag.h"

#include <windows.h>
#include <windowsx.h>
#include <gdiplus.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr char kChannelName[] = "yixue/screenshot_translation/native_orb";
constexpr wchar_t kWindowClassName[] = L"YIXUE_SCREENSHOT_TRANSLATION_NATIVE_ORB";
constexpr wchar_t kWindowTitle[] = L"Yixue Screenshot Translation Orb";
constexpr UINT_PTR kAnimationTimer = 1;
constexpr int kOrbLogicalDiameter = 56;
constexpr int kOrbLogicalMargin = 12;
constexpr ULONGLONG kHoverAnimationMs = 180;
constexpr ULONGLONG kClickAnimationMs = 300;
constexpr int kMenuCapture = 1;
constexpr int kMenuOpenWorkbench = 2;
constexpr int kMenuShortcutSettings = 3;
constexpr int kMenuDisableOrb = 4;
constexpr int kMenuQuit = 5;

using namespace Gdiplus;

int ScaleForDpi(int logical, UINT dpi) {
  return MulDiv(logical, static_cast<int>(dpi), USER_DEFAULT_SCREEN_DPI);
}

UINT DpiForWindow(HWND window) {
  if (window != nullptr && IsWindow(window)) {
    const UINT dpi = GetDpiForWindow(window);
    if (dpi > 0) return dpi;
  }
  const UINT system_dpi = GetDpiForSystem();
  return system_dpi > 0 ? system_dpi : USER_DEFAULT_SCREEN_DPI;
}

std::unique_ptr<Bitmap> LoadBrandMarkFromFlutterBundle() {
  // Load the same master artwork used by Flutter's YixueBrandMark instead of
  // duplicating the leaf and nib as approximate native vector paths.
  std::vector<wchar_t> executable_path(32768, L'\0');
  const DWORD executable_length = GetModuleFileNameW(
      nullptr, executable_path.data(),
      static_cast<DWORD>(executable_path.size()));
  if (executable_length == 0 ||
      executable_length >= executable_path.size()) {
    return nullptr;
  }

  std::wstring asset_path(executable_path.data(), executable_length);
  const size_t separator = asset_path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return nullptr;
  asset_path.resize(separator + 1);
  asset_path.append(
      L"data\\flutter_assets\\assets\\brand\\yixue-logo-master-v3.png");

  auto brand_mark = std::make_unique<Bitmap>(asset_path.c_str());
  if (brand_mark->GetLastStatus() != Ok) return nullptr;
  return brand_mark;
}

class NativeScreenshotOrb {
 public:
  using CommandHandler =
      std::function<void(const std::string&, double, double)>;

  explicit NativeScreenshotOrb(CommandHandler command_handler)
      : command_handler_(std::move(command_handler)) {}

  ~NativeScreenshotOrb() { Destroy(); }

  bool PrepareBrandMark() {
    if (brand_mark_ != nullptr && brand_mark_->GetLastStatus() == Ok) {
      return true;
    }
    brand_mark_ = LoadBrandMarkFromFlutterBundle();
    return brand_mark_ != nullptr;
  }

  void ReleaseBrandMark() { brand_mark_.reset(); }

  bool Open(std::optional<POINT> requested_position) {
    const bool creating = window_ == nullptr;
    POINT position{};
    if (requested_position.has_value()) {
      position = *requested_position;
    } else if (window_ != nullptr) {
      RECT current{};
      if (!GetWindowRect(window_, &current)) return false;
      position = POINT{current.left, current.top};
    } else {
      const HWND foreground = GetForegroundWindow();
      const HMONITOR foreground_monitor =
          foreground != nullptr
              ? MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST)
              : MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
      MONITORINFO monitor_info{sizeof(MONITORINFO)};
      if (foreground_monitor != nullptr &&
          GetMonitorInfoW(foreground_monitor, &monitor_info)) {
        // Create the hidden HWND inside the selected work area first. Its
        // actual monitor DPI can then be queried with GetDpiForWindow.
        position = POINT{monitor_info.rcWork.left, monitor_info.rcWork.top};
      }
    }

    dpi_ = creating ? DpiForWindow(nullptr) : DpiForWindow(window_);
    const int diameter = ScaleForDpi(kOrbLogicalDiameter, dpi_);
    if (creating && !Create(diameter, position)) return false;

    // A newly created HWND is placed on the requested/foreground monitor with
    // a temporary system-DPI size. Resolve its per-monitor DPI from that HWND
    // before applying the final logical diameter.
    dpi_ = DpiForWindow(window_);
    const int monitor_diameter = ScaleForDpi(kOrbLogicalDiameter, dpi_);
    if (requested_position.has_value() || creating) {
      if (creating && !requested_position.has_value()) {
        const HMONITOR monitor =
            MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
        MONITORINFO monitor_info{sizeof(MONITORINFO)};
        if (monitor == nullptr || !GetMonitorInfoW(monitor, &monitor_info)) {
          return false;
        }
        const RECT area = monitor_info.rcWork;
        const int margin = ScaleForDpi(kOrbLogicalMargin, dpi_);
        position.x = area.right - monitor_diameter - margin;
        position.y = area.top +
                     (area.bottom - area.top - monitor_diameter) / 2;
      }
      if (!MoveAndResize(position, monitor_diameter, monitor_diameter, false)) {
        return false;
      }
    }

    if (!SnapToWorkArea() ||
        !SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                          SWP_SHOWWINDOW)) {
      return false;
    }
    ShowWindow(window_, SW_SHOWNOACTIVATE);
    return IsWindowVisible(window_) != FALSE;
  }

  void Destroy() {
    const HWND window = window_;
    if (window != nullptr && IsWindow(window)) {
      KillTimer(window, kAnimationTimer);
      if (GetCapture() == window) ReleaseCapture();
      DestroyWindow(window);
    }
    window_ = nullptr;
    capture_was_visible_ = false;
    ResetTransientState();
    dpi_ = DpiForWindow(nullptr);
  }

  bool IsVisible() const {
    return window_ != nullptr && IsWindowVisible(window_) != FALSE;
  }

  void HideForCapture() {
    if (window_ == nullptr || !IsWindow(window_) || !IsWindowVisible(window_)) {
      return;
    }
    capture_was_visible_ = true;
    KillTimer(window_, kAnimationTimer);
    if (GetCapture() == window_) ReleaseCapture();
    ResetTransientState();
    ShowWindow(window_, SW_HIDE);
  }

  void RestoreAfterCapture() {
    if (!capture_was_visible_) return;
    capture_was_visible_ = false;
    if (window_ == nullptr || !IsWindow(window_)) return;
    Render();
    SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    ShowWindow(window_, SW_SHOWNOACTIVATE);
    RefreshHoverAfterShow();
  }

 private:
  // A replacement HWND must register its own WM_MOUSELEAVE tracking and start
  // with no held-button or stale animation state after disable/retry cycles.
  void ResetTransientState() {
    mouse_inside_ = false;
    tracking_mouse_leave_ = false;
    pressed_ = false;
    dragging_ = false;
    drag_gesture_.Cancel();
    hover_started_at_ = 0;
    click_started_at_ = 0;
  }

  bool Create(int diameter, POINT position) {
    if (!EnsureWindowClass()) return false;
    window_ = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_LAYERED,
        kWindowClassName, kWindowTitle, WS_POPUP, position.x, position.y,
        diameter,
        diameter, nullptr, nullptr, GetModuleHandleW(nullptr), this);
    if (window_ == nullptr) return false;
    return true;
  }

  static bool EnsureWindowClass() {
    static bool registered = false;
    if (registered) return true;

    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.hCursor = LoadCursorW(nullptr, IDC_HAND);
    window_class.lpfnWndProc = WindowProc;
    window_class.lpszClassName = kWindowClassName;
    if (RegisterClassExW(&window_class) == 0 &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }
    registered = true;
    return true;
  }

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    NativeScreenshotOrb* orb = reinterpret_cast<NativeScreenshotOrb*>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
      orb = static_cast<NativeScreenshotOrb*>(create->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(orb));
      orb->window_ = window;
    }
    if (orb == nullptr) return DefWindowProcW(window, message, wparam, lparam);
    const LRESULT result = orb->HandleMessage(message, wparam, lparam);
    if (message == WM_NCDESTROY) {
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      orb->window_ = nullptr;
      orb->ResetTransientState();
    }
    return result;
  }

  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
      case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
      case WM_NCHITTEST: {
        const int x = GET_X_LPARAM(lparam);
        const int y = GET_Y_LPARAM(lparam);
        RECT bounds{};
        if (!GetWindowRect(window_, &bounds)) return HTTRANSPARENT;
        const double rx = (bounds.right - bounds.left) / 2.0;
        const double ry = (bounds.bottom - bounds.top) / 2.0;
        const double dx = x - (bounds.left + rx);
        const double dy = y - (bounds.top + ry);
        return (dx * dx / (rx * rx) + dy * dy / (ry * ry)) <= 1.0
                   ? HTCLIENT
                   : HTTRANSPARENT;
      }
      case WM_MOUSEMOVE:
        TrackMouseLeave();
        if (!mouse_inside_) {
          mouse_inside_ = true;
          hover_started_at_ = GetTickCount64();
          StartAnimation();
        }
        // Feed moves while the left button is held. Waiting for dragging_ here
        // deadlocks drag detection because UpdateDrag() is what sets that flag.
        if (pressed_) UpdateDrag();
        return 0;
      case WM_MOUSELEAVE:
        mouse_inside_ = false;
        tracking_mouse_leave_ = false;
        hover_started_at_ = GetTickCount64();
        StartAnimation();
        return 0;
      case WM_LBUTTONDOWN:
        {
          POINT cursor{};
          RECT bounds{};
          if (!GetCursorPos(&cursor) || !GetWindowRect(window_, &bounds)) {
            return 0;
          }
          SetCapture(window_);
          pressed_ = true;
          dragging_ = false;
          drag_gesture_.Begin(
              {cursor.x, cursor.y},
              {bounds.left, bounds.top, bounds.right, bounds.bottom});
        }
        StartAnimation();
        return 0;
      case WM_LBUTTONUP:
        HandleLeftButtonUp();
        return 0;
      case WM_CAPTURECHANGED:
        pressed_ = false;
        dragging_ = false;
        drag_gesture_.Cancel();
        return 0;
      case WM_CONTEXTMENU:
        // Deliberately handle only WM_CONTEXTMENU. WM_RBUTTONUP falls through
        // to DefWindowProc, which raises this message once after button-up.
        ShowContextMenu();
        return 0;
      case WM_TIMER:
        if (wparam == kAnimationTimer) TickAnimation();
        return 0;
      case WM_PAINT: {
        PAINTSTRUCT paint{};
        BeginPaint(window_, &paint);
        EndPaint(window_, &paint);
        Render();
        return 0;
      }
      case WM_ERASEBKGND:
        return 1;
      case WM_DPICHANGED: {
        const UINT window_dpi = GetDpiForWindow(window_);
        dpi_ = window_dpi > 0 ? window_dpi : HIWORD(wparam);
        const auto* suggested = reinterpret_cast<const RECT*>(lparam);
        if (suggested != nullptr) {
          SetWindowPos(window_, HWND_TOPMOST, suggested->left, suggested->top,
                       suggested->right - suggested->left,
                       suggested->bottom - suggested->top,
                       SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        }
        Render();
        return 0;
      }
      case WM_DISPLAYCHANGE:
        SnapToWorkArea();
        Render();
        return 0;
      case WM_DESTROY:
        KillTimer(window_, kAnimationTimer);
        return 0;
      default:
        return DefWindowProcW(window_, message, wparam, lparam);
    }
  }

  void TrackMouseLeave() {
    if (tracking_mouse_leave_) return;
    TRACKMOUSEEVENT tracking{sizeof(TRACKMOUSEEVENT)};
    tracking.dwFlags = TME_LEAVE;
    tracking.hwndTrack = window_;
    tracking_mouse_leave_ = TrackMouseEvent(&tracking) != FALSE;
  }

  void RefreshHoverAfterShow() {
    if (window_ == nullptr || !IsWindowVisible(window_)) return;
    POINT cursor{};
    RECT bounds{};
    if (!GetCursorPos(&cursor) || !GetWindowRect(window_, &bounds)) return;
    const double radius_x = (bounds.right - bounds.left) / 2.0;
    const double radius_y = (bounds.bottom - bounds.top) / 2.0;
    if (radius_x <= 0 || radius_y <= 0) return;
    const double dx = cursor.x - (bounds.left + radius_x);
    const double dy = cursor.y - (bounds.top + radius_y);
    if (dx * dx / (radius_x * radius_x) +
            dy * dy / (radius_y * radius_y) >
        1.0) {
      return;
    }
    mouse_inside_ = true;
    hover_started_at_ = GetTickCount64();
    TrackMouseLeave();
    StartAnimation();
  }

  void UpdateDrag() {
    POINT cursor{};
    if (!GetCursorPos(&cursor)) return;
    if (!pressed_) return;
    dpi_ = DpiForWindow(window_);
    const int drag_threshold = ScaleForDpi(5, dpi_);
    const auto position = drag_gesture_.Move(
        {cursor.x, cursor.y},
        static_cast<std::int64_t>(drag_threshold));
    dragging_ = drag_gesture_.is_dragging();
    if (!position) return;
    RECT bounds{};
    if (!GetWindowRect(window_, &bounds)) return;
    MoveAndResize(
        POINT{static_cast<LONG>(position->x),
              static_cast<LONG>(position->y)},
        bounds.right - bounds.left, bounds.bottom - bounds.top, false);
  }

  void HandleLeftButtonUp() {
    if (!pressed_) return;
    const bool was_dragging = drag_gesture_.End();
    pressed_ = false;
    if (GetCapture() == window_) ReleaseCapture();
    dragging_ = false;
    if (was_dragging) {
      SnapToWorkArea();
      EmitCommand("orbMoved", true);
    } else {
      click_started_at_ = GetTickCount64();
      StartAnimation();
      EmitCommand("captureRequested");
    }
    Render();
  }

  void ShowContextMenu() {
    HMENU menu = CreatePopupMenu();
    if (menu == nullptr) return;
    AppendMenuW(menu, MF_STRING, kMenuCapture, L"\u622A\u5C4F\u7FFB\u8BD1");
    AppendMenuW(menu, MF_STRING, kMenuOpenWorkbench,
                L"\u6253\u5F00\u8BD1\u5B66\u5DE5\u4F5C\u53F0");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuShortcutSettings,
                L"\u5FEB\u6377\u952E\u8BBE\u7F6E");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuDisableOrb,
                L"\u5173\u95ED\u60AC\u6D6E\u7403");
    AppendMenuW(menu, MF_STRING, kMenuQuit,
                L"\u9000\u51FA\u8BD1\u5B66");

    POINT cursor{};
    GetCursorPos(&cursor);
    const UINT command = TrackPopupMenuEx(
        menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_NOANIMATION,
        cursor.x, cursor.y, window_, nullptr);
    DestroyMenu(menu);
    switch (command) {
      case kMenuCapture:
        EmitCommand("captureRequested");
        break;
      case kMenuOpenWorkbench:
        EmitCommand("openMain");
        break;
      case kMenuShortcutSettings:
        EmitCommand("openScreenshotSettings");
        break;
      case kMenuDisableOrb:
        EmitCommand("disableOrb");
        break;
      case kMenuQuit:
        EmitCommand("quitRequested");
        break;
      default:
        break;
    }
  }

  bool SnapToWorkArea() {
    RECT rect{};
    if (!GetWindowRect(window_, &rect)) return false;
    const POINT center{rect.left + (rect.right - rect.left) / 2,
                       rect.top + (rect.bottom - rect.top) / 2};
    const HMONITOR monitor = MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof(MONITORINFO)};
    if (monitor == nullptr || !GetMonitorInfoW(monitor, &info)) return false;
    dpi_ = DpiForWindow(window_);
    const LONG width = ScaleForDpi(kOrbLogicalDiameter, dpi_);
    const LONG height = width;
    const LONG margin = ScaleForDpi(kOrbLogicalMargin, dpi_);
    const RECT area = info.rcWork;
    const LONG min_x = area.left + margin;
    const LONG min_y = area.top + margin;
    const LONG max_x = std::max(min_x, area.right - margin - width);
    const LONG max_y = std::max(min_y, area.bottom - margin - height);
    const LONG current_x = std::clamp(rect.left, min_x, max_x);
    const LONG current_y = std::clamp(rect.top, min_y, max_y);
    const std::array<POINT, 4> candidates = {
        POINT{min_x, current_y}, POINT{max_x, current_y},
        POINT{current_x, min_y}, POINT{current_x, max_y}};
    const auto distance = [&rect](POINT point) {
      const double dx = static_cast<double>(point.x - rect.left);
      const double dy = static_cast<double>(point.y - rect.top);
      return dx * dx + dy * dy;
    };
    const POINT snapped = *std::min_element(
        candidates.begin(), candidates.end(),
        [&distance](POINT a, POINT b) { return distance(a) < distance(b); });
    return MoveAndResize(snapped, width, height, true);
  }

  bool MoveAndResize(POINT position, int width, int height, bool topmost) {
    if (window_ == nullptr) return false;
    if (!SetWindowPos(window_, topmost ? HWND_TOPMOST : nullptr, position.x,
                      position.y, width, height,
                      SWP_NOACTIVATE | (topmost ? 0 : SWP_NOZORDER))) {
      return false;
    }
    return Render();
  }

  void EmitCommand(const std::string& type, bool include_position = false) {
    if (!command_handler_) return;
    double x = 0;
    double y = 0;
    if (include_position && window_ != nullptr) {
      RECT rect{};
      if (GetWindowRect(window_, &rect)) {
        x = static_cast<double>(rect.left);
        y = static_cast<double>(rect.top);
      }
    }
    command_handler_(type, x, y);
  }

  void StartAnimation() {
    if (window_ == nullptr) return;
    SetTimer(window_, kAnimationTimer, 16, nullptr);
    Render();
  }

  void TickAnimation() {
    const ULONGLONG now = GetTickCount64();
    const bool hover_running = now - hover_started_at_ < kHoverAnimationMs;
    const bool click_running = click_started_at_ != 0 &&
                               now - click_started_at_ < kClickAnimationMs;
    Render();
    if (!hover_running && !click_running) KillTimer(window_, kAnimationTimer);
  }

  float HoverAmount() const {
    if (hover_started_at_ == 0) return 0.0f;
    const double raw = std::clamp(
        static_cast<double>(GetTickCount64() - hover_started_at_) /
            static_cast<double>(kHoverAnimationMs),
        0.0, 1.0);
    const float eased = static_cast<float>(raw * raw * (3.0 - 2.0 * raw));
    return mouse_inside_ ? eased : 1.0f - eased;
  }

  bool Render() {
    if (window_ == nullptr || !IsWindow(window_) || brand_mark_ == nullptr ||
        brand_mark_->GetLastStatus() != Ok) {
      return false;
    }
    RECT client{};
    if (!GetClientRect(window_, &client)) return false;
    const int width = client.right - client.left;
    const int height = client.bottom - client.top;
    if (width <= 0 || height <= 0) return false;

    Bitmap canvas(width, height, PixelFormat32bppPARGB);
    Graphics graphics(&canvas);
    graphics.SetSmoothingMode(SmoothingModeAntiAlias);
    graphics.SetInterpolationMode(InterpolationModeHighQualityBicubic);
    graphics.SetCompositingQuality(CompositingQualityHighQuality);
    graphics.SetCompositingMode(CompositingModeSourceOver);
    graphics.Clear(Color(0, 0, 0, 0));

    const float hover = HoverAmount();
    const float scale = 1.0f + hover * 0.075f + (pressed_ ? 0.025f : 0.0f);
    const float center = width / 2.0f;
    graphics.TranslateTransform(center, center);
    graphics.ScaleTransform(scale, scale);
    graphics.TranslateTransform(-center, -center);

    const float unit = width / static_cast<float>(kOrbLogicalDiameter);
    const float outer = 3.0f * unit;
    const float diameter = 50.0f * unit;
    const RectF orb(outer, outer, diameter, diameter);
    if (hover > 0.02f) {
      const BYTE glow_alpha = static_cast<BYTE>(hover * 58.0f);
      SolidBrush glow(Color(glow_alpha, 42, 154, 227));
      graphics.FillEllipse(&glow, orb.X - 3.0f * unit,
                           orb.Y - 3.0f * unit,
                           orb.Width + 6.0f * unit,
                           orb.Height + 6.0f * unit);
    }

    LinearGradientBrush body(
        PointF(orb.X, orb.Y), PointF(orb.X + orb.Width, orb.Y + orb.Height),
        Color(255, 19, 111, 226), Color(255, 20, 190, 154));
    graphics.FillEllipse(&body, orb);
    Pen rim(Color(110 + static_cast<BYTE>(hover * 110), 255, 255, 255),
            std::max(1.0f, unit));
    graphics.DrawEllipse(&rim, orb);

    const RectF brand_rect(10.0f * unit, 10.0f * unit, 36.0f * unit,
                           36.0f * unit);
    graphics.DrawImage(brand_mark_.get(), brand_rect);

    if (click_started_at_ != 0) {
      const double raw = std::clamp(
          static_cast<double>(GetTickCount64() - click_started_at_) /
              static_cast<double>(kClickAnimationMs),
          0.0, 1.0);
      const float progress = static_cast<float>(raw);
      const float ripple = (32.0f + progress * 18.0f) * unit;
      const BYTE alpha = static_cast<BYTE>((1.0 - raw) * 150.0);
      Pen click_ring(Color(alpha, 255, 255, 255), 1.8f * unit);
      graphics.DrawEllipse(&click_ring, center - ripple / 2.0f,
                           center - ripple / 2.0f, ripple, ripple);
    }

    BitmapData data{};
    const Rect lock_rect(0, 0, width, height);
    if (canvas.LockBits(&lock_rect, ImageLockModeRead,
                        PixelFormat32bppPARGB, &data) != Ok) {
      return false;
    }

    HDC screen_dc = GetDC(nullptr);
    HDC memory_dc = screen_dc != nullptr ? CreateCompatibleDC(screen_dc) : nullptr;
    BITMAPINFO bitmap_info{};
    bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = width;
    bitmap_info.bmiHeader.biHeight = -height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HBITMAP dib = memory_dc != nullptr
                      ? CreateDIBSection(screen_dc, &bitmap_info, DIB_RGB_COLORS,
                                         &pixels, nullptr, 0)
                      : nullptr;
    HGDIOBJ old_bitmap = dib != nullptr ? SelectObject(memory_dc, dib) : nullptr;
    if (dib == nullptr || pixels == nullptr || old_bitmap == nullptr) {
      canvas.UnlockBits(&data);
      if (old_bitmap != nullptr) SelectObject(memory_dc, old_bitmap);
      if (dib != nullptr) DeleteObject(dib);
      if (memory_dc != nullptr) DeleteDC(memory_dc);
      if (screen_dc != nullptr) ReleaseDC(nullptr, screen_dc);
      return false;
    }

    const auto* source = static_cast<const std::uint8_t*>(data.Scan0);
    auto* destination = static_cast<std::uint8_t*>(pixels);
    for (int row = 0; row < height; ++row) {
      const auto* source_row = data.Stride >= 0
                                   ? source + row * data.Stride
                                   : source + (height - 1 - row) * -data.Stride;
      std::memcpy(destination + row * width * 4, source_row, width * 4);
    }
    canvas.UnlockBits(&data);

    RECT bounds{};
    GetWindowRect(window_, &bounds);
    POINT destination_point{bounds.left, bounds.top};
    POINT source_point{0, 0};
    SIZE size{width, height};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    const bool updated = UpdateLayeredWindow(
                             window_, screen_dc, &destination_point, &size,
                             memory_dc, &source_point, 0, &blend, ULW_ALPHA) !=
                         FALSE;
    SelectObject(memory_dc, old_bitmap);
    DeleteObject(dib);
    DeleteDC(memory_dc);
    ReleaseDC(nullptr, screen_dc);
    return updated;
  }

  HWND window_ = nullptr;
  CommandHandler command_handler_;
  std::unique_ptr<Bitmap> brand_mark_;
  bool capture_was_visible_ = false;
  UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
  bool mouse_inside_ = false;
  bool tracking_mouse_leave_ = false;
  bool pressed_ = false;
  bool dragging_ = false;
  yixue::runner::ScreenshotOrbDragGesture drag_gesture_;
  ULONGLONG hover_started_at_ = 0;
  ULONGLONG click_started_at_ = 0;
};

class ScreenshotTranslationNativeOrbPlugin : public flutter::Plugin {
 public:
  explicit ScreenshotTranslationNativeOrbPlugin(
      flutter::PluginRegistrarWindows* registrar)
      : channel_(std::make_unique<flutter::MethodChannel<
                     flutter::EncodableValue>>(
            registrar->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance())),
        orb_([this](const std::string& type, double x, double y) {
          SendCommand(type, x, y);
        }) {
    GdiplusStartupInput startup_input;
    gdiplus_status_ = GdiplusStartup(&gdiplus_token_, &startup_input, nullptr);
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      HandleMethodCall(call, std::move(result));
    });
  }

  ~ScreenshotTranslationNativeOrbPlugin() override {
    channel_->SetMethodCallHandler(nullptr);
    orb_.Destroy();
    orb_.ReleaseBrandMark();
    channel_.reset();
    if (gdiplus_token_ != 0) GdiplusShutdown(gdiplus_token_);
  }

 private:
  static std::optional<double> ReadNumber(
      const flutter::EncodableMap& map, const char* key) {
    const auto value = map.find(flutter::EncodableValue(key));
    if (value == map.end()) return std::nullopt;
    if (const auto* number = std::get_if<double>(&value->second)) {
      return std::isfinite(*number) ? std::optional<double>(*number)
                                    : std::nullopt;
    }
    if (const auto* number = std::get_if<int32_t>(&value->second)) {
      return static_cast<double>(*number);
    }
    if (const auto* number = std::get_if<int64_t>(&value->second)) {
      return static_cast<double>(*number);
    }
    return std::nullopt;
  }

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "open") {
      if (gdiplus_status_ != Ok) {
        result->Error("native_orb_render_unavailable",
                      "Unable to initialize the native orb renderer.");
        return;
      }
      if (!orb_.PrepareBrandMark()) {
        result->Error("native_orb_brand_unavailable",
                      "Unable to load the Yixue brand mark from app assets.");
        return;
      }
      std::optional<POINT> position;
      if (call.arguments() != nullptr) {
        if (const auto* map =
                std::get_if<flutter::EncodableMap>(call.arguments())) {
          const auto x = ReadNumber(*map, "x");
          const auto y = ReadNumber(*map, "y");
          if (x.has_value() && y.has_value()) {
            constexpr double kCoordinateLimit = 1000000.0;
            if (std::abs(*x) > kCoordinateLimit ||
                std::abs(*y) > kCoordinateLimit) {
              result->Error("invalid_orb_position",
                            "Orb position is outside the supported range.");
              return;
            }
            position = POINT{static_cast<LONG>(std::lround(*x)),
                             static_cast<LONG>(std::lround(*y))};
          }
        }
      }
      if (!orb_.Open(position)) {
        const DWORD error = GetLastError();
        result->Error("native_orb_open_failed",
                      "Unable to open the native screenshot orb; Windows error " +
                          std::to_string(error));
        return;
      }
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "close") {
      orb_.Destroy();
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "isVisible") {
      result->Success(flutter::EncodableValue(orb_.IsVisible()));
      return;
    }
    if (call.method_name() == "hideForCapture") {
      orb_.HideForCapture();
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "restoreAfterCapture") {
      orb_.RestoreAfterCapture();
      result->Success(flutter::EncodableValue(true));
      return;
    }
    result->NotImplemented();
  }

  void SendCommand(const std::string& type, double x, double y) {
    if (channel_ == nullptr) return;
    flutter::EncodableMap payload;
    if (type == "orbMoved") {
      payload.emplace(flutter::EncodableValue("x"),
                      flutter::EncodableValue(x));
      payload.emplace(flutter::EncodableValue("y"),
                      flutter::EncodableValue(y));
    }
    const auto request_id =
        std::string("native-") + std::to_string(++request_sequence_);
    flutter::EncodableMap message;
    message.emplace(flutter::EncodableValue("version"),
                    flutter::EncodableValue(int32_t{1}));
    message.emplace(flutter::EncodableValue("type"),
                    flutter::EncodableValue(type));
    message.emplace(flutter::EncodableValue("requestId"),
                    flutter::EncodableValue(request_id));
    message.emplace(flutter::EncodableValue("payload"),
                    flutter::EncodableValue(std::move(payload)));
    channel_->InvokeMethod(
        "onCommand",
        std::make_unique<flutter::EncodableValue>(std::move(message)));
  }

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  NativeScreenshotOrb orb_;
  ULONG_PTR gdiplus_token_ = 0;
  Status gdiplus_status_ = GenericError;
  uint64_t request_sequence_ = 0;
};

}  // namespace

void RegisterScreenshotTranslationNativeOrbPlugin(
    flutter::PluginRegistry* registry) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            registry->GetRegistrarForPlugin(
                                "ScreenshotTranslationNativeOrbPlugin"));
  registrar->AddPlugin(
      std::make_unique<ScreenshotTranslationNativeOrbPlugin>(registrar));
}
