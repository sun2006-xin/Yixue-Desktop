#include "screenshot_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>
#include <wingdi.h>
#include <wincodec.h>
#include <windowsx.h>  // For GET_X_LPARAM and GET_Y_LPARAM

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <new>
#include <sstream>
#include <thread>
#include <utility>
#include <vector>

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "msimg32.lib")

namespace screenshot {

constexpr int64_t kMaximumCapturePixels = 20000000;
constexpr uint64_t kMaximumEncodedPngBytes = 64ull * 1024ull * 1024ull;

// Helper function to encode HBITMAP to PNG bytes using WIC
std::vector<uint8_t> EncodeBitmapToPNG(HBITMAP hBitmap, int width, int height) {
  std::vector<uint8_t> pngBytes;
  SetLastError(ERROR_SUCCESS);
  
  // Initialize COM
  HRESULT hr = CoInitialize(nullptr);
  bool comInitialized = SUCCEEDED(hr);
  
  IWICImagingFactory* pFactory = nullptr;
  IWICBitmap* pWICBitmap = nullptr;
  IWICStream* pStream = nullptr;
  IWICBitmapEncoder* pEncoder = nullptr;
  IWICBitmapFrameEncode* pFrameEncode = nullptr;
  IStream* pMemStream = nullptr;
  IStream* pIStream = nullptr;

  struct WicCleanup {
    IWICImagingFactory*& factory;
    IWICBitmap*& bitmap;
    IWICStream*& stream;
    IWICBitmapEncoder*& encoder;
    IWICBitmapFrameEncode*& frame;
    IStream*& memoryStream;
    IStream*& resultStream;
    bool comInitialized;
    ~WicCleanup() {
      if (resultStream) resultStream->Release();
      if (memoryStream) memoryStream->Release();
      if (frame) frame->Release();
      if (encoder) encoder->Release();
      if (stream) stream->Release();
      if (bitmap) bitmap->Release();
      if (factory) factory->Release();
      if (comInitialized) CoUninitialize();
    }
  } cleanup{pFactory, pWICBitmap, pStream, pEncoder, pFrameEncode,
            pMemStream, pIStream, comInitialized};
  
  do {
    // Create WIC factory
    hr = CoCreateInstance(
      CLSID_WICImagingFactory,
      nullptr,
      CLSCTX_INPROC_SERVER,
      IID_IWICImagingFactory,
      reinterpret_cast<LPVOID*>(&pFactory)
    );
    if (FAILED(hr)) break;
    
    // Create WIC bitmap from HBITMAP
    hr = pFactory->CreateBitmapFromHBITMAP(hBitmap, nullptr, WICBitmapIgnoreAlpha, &pWICBitmap);
    if (FAILED(hr)) break;
    
    // Create WIC stream
    hr = pFactory->CreateStream(&pStream);
    if (FAILED(hr)) break;
    
    // Create memory stream using IStream
    hr = CreateStreamOnHGlobal(nullptr, TRUE, &pMemStream);
    if (FAILED(hr)) break;
    
    // Initialize WIC stream from IStream
    hr = pStream->InitializeFromIStream(pMemStream);
    pMemStream->Release();
    pMemStream = nullptr;
    if (FAILED(hr)) break;
    
    // Create PNG encoder
    hr = pFactory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &pEncoder);
    if (FAILED(hr)) break;
    
    hr = pEncoder->Initialize(pStream, WICBitmapEncoderNoCache);
    if (FAILED(hr)) break;
    
    // Create frame
    hr = pEncoder->CreateNewFrame(&pFrameEncode, nullptr);
    if (FAILED(hr)) break;
    
    hr = pFrameEncode->Initialize(nullptr);
    if (FAILED(hr)) break;
    
    hr = pFrameEncode->SetSize(width, height);
    if (FAILED(hr)) break;
    
    WICPixelFormatGUID formatGUID = GUID_WICPixelFormat32bppBGRA;
    hr = pFrameEncode->SetPixelFormat(&formatGUID);
    if (FAILED(hr)) break;
    
    hr = pFrameEncode->WriteSource(pWICBitmap, nullptr);
    if (FAILED(hr)) break;
    
    hr = pFrameEncode->Commit();
    if (FAILED(hr)) break;
    
    hr = pEncoder->Commit();
    if (FAILED(hr)) break;
    
    // Get data from stream
    ULARGE_INTEGER streamSize;
    hr = pStream->QueryInterface(IID_IStream, reinterpret_cast<void**>(&pIStream));
    if (SUCCEEDED(hr)) {
      STATSTG stat = {};
      if (SUCCEEDED(pIStream->Stat(&stat, STATFLAG_NONAME))) {
        streamSize = stat.cbSize;
        if (streamSize.QuadPart > kMaximumEncodedPngBytes ||
            streamSize.QuadPart > (std::numeric_limits<size_t>::max)() ||
            streamSize.QuadPart > (std::numeric_limits<ULONG>::max)()) {
          pngBytes.clear();
          SetLastError(ERROR_FILE_TOO_LARGE);
          break;
        }
        pngBytes.resize(static_cast<size_t>(streamSize.QuadPart));
        
        LARGE_INTEGER zero = {};
        pIStream->Seek(zero, STREAM_SEEK_SET, nullptr);
        
        ULONG bytesRead = 0;
        hr = pIStream->Read(pngBytes.data(),
                            static_cast<ULONG>(pngBytes.size()), &bytesRead);
        if (FAILED(hr) || bytesRead != pngBytes.size()) {
          pngBytes.clear();
          SetLastError(ERROR_INVALID_DATA);
        }
      }
      pIStream->Release();
      pIStream = nullptr;
    }
    
  } while (false);
  
  return pngBytes;
}

// Runner.manifest declares PerMonitorV2. Do not override process awareness.
struct BitmapSurface {
  HDC dc = nullptr;
  HBITMAP bitmap = nullptr;
  HGDIOBJ previous = nullptr;
  BitmapSurface() = default;
  BitmapSurface(const BitmapSurface&) = delete;
  BitmapSurface& operator=(const BitmapSurface&) = delete;
  ~BitmapSurface() {
    if (dc && previous && previous != HGDI_ERROR) SelectObject(dc, previous);
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
  }
  bool Create(HDC source, int width, int height) {
    dc = CreateCompatibleDC(source);
    if (!dc) return false;
    bitmap = CreateCompatibleBitmap(source, width, height);
    if (!bitmap) return false;
    previous = SelectObject(dc, bitmap);
    return previous && previous != HGDI_ERROR;
  }
  HBITMAP Detach() {
    SelectObject(dc, previous);
    previous = nullptr;
    HBITMAP result = bitmap;
    bitmap = nullptr;
    return result;
  }
};

struct ScreenDc {
  HDC dc = GetDC(nullptr);
  ~ScreenDc() { if (dc) ReleaseDC(nullptr, dc); }
};

struct BitmapHandle {
  HBITMAP value = nullptr;
  explicit BitmapHandle(HBITMAP bitmap) : value(bitmap) {}
  BitmapHandle(const BitmapHandle&) = delete;
  BitmapHandle& operator=(const BitmapHandle&) = delete;
  BitmapHandle(BitmapHandle&& other) noexcept
      : value(std::exchange(other.value, nullptr)) {}
  BitmapHandle& operator=(BitmapHandle&& other) noexcept {
    if (this == &other) return *this;
    if (value) DeleteObject(value);
    value = std::exchange(other.value, nullptr);
    return *this;
  }
  ~BitmapHandle() {
    if (value) DeleteObject(value);
  }
};

class CaptureBusyLease final {
 public:
  explicit CaptureBusyLease(std::shared_ptr<std::atomic_bool> state)
      : state_(std::move(state)) {}
  CaptureBusyLease(const CaptureBusyLease&) = delete;
  CaptureBusyLease& operator=(const CaptureBusyLease&) = delete;

  void Arm() noexcept { armed_ = true; }

  ~CaptureBusyLease() {
    if (armed_ && state_) {
      state_->store(false, std::memory_order_release);
    }
  }

 private:
  std::shared_ptr<std::atomic_bool> state_;
  bool armed_ = false;
};

using ScreenshotMethodResult =
    flutter::MethodResult<flutter::EncodableValue>;

void ReplyCaptureError(
    const std::shared_ptr<ScreenshotMethodResult>& result,
    const char* code,
    const char* message,
    DWORD system_error = ERROR_SUCCESS) noexcept {
  try {
    if (system_error != ERROR_SUCCESS) {
      result->Error(code, message,
                    flutter::EncodableValue(static_cast<int>(system_error)));
    } else {
      result->Error(code, message);
    }
  } catch (...) {
    // Never let a late response exception escape the worker thread.
  }
}

void EncodeCapturedBitmapAsync(
    const std::shared_ptr<BitmapHandle>& bitmap,
    int width,
    int height,
    int x,
    int y,
    std::unique_ptr<ScreenshotMethodResult> result,
    const std::shared_ptr<CaptureBusyLease>& busy_lease) {
  std::shared_ptr<ScreenshotMethodResult> shared_result;
  try {
    shared_result =
        std::shared_ptr<ScreenshotMethodResult>(std::move(result));
  } catch (...) {
    if (result) {
      try {
        result->Error("out_of_memory",
                      "Unable to prepare screenshot response");
      } catch (...) {
        // Keep allocation failures from escaping the platform callback.
      }
    }
    return;
  }

  try {
    std::thread worker([bitmap, width, height, x, y, shared_result,
                        busy_lease]() {
      try {
        // WIC is initialized and released inside this function on the worker.
        // The HBITMAP has single ownership through |bitmap| for this operation.
        std::vector<uint8_t> png_bytes =
            EncodeBitmapToPNG(bitmap->value, width, height);
        const DWORD encode_error = GetLastError();
        if (png_bytes.empty()) {
          if (encode_error == ERROR_FILE_TOO_LARGE) {
            ReplyCaptureError(shared_result, "image_too_large",
                              "Select a smaller screen area", encode_error);
          } else {
            ReplyCaptureError(shared_result, "internal_error",
                              "Failed to encode PNG", encode_error);
          }
          return;
        }

        flutter::EncodableMap result_map;
        result_map[flutter::EncodableValue("left")] =
            flutter::EncodableValue(x);
        result_map[flutter::EncodableValue("top")] =
            flutter::EncodableValue(y);
        result_map[flutter::EncodableValue("width")] =
            flutter::EncodableValue(width);
        result_map[flutter::EncodableValue("height")] =
            flutter::EncodableValue(height);
        result_map[flutter::EncodableValue("bytes")] =
            flutter::EncodableValue(std::move(png_bytes));

        // MethodResult is intentionally single-writer: this worker is the only
        // place that completes this pending capture call.
        try {
          shared_result->Success(
              flutter::EncodableValue(std::move(result_map)));
        } catch (...) {
          // If encoding the response failed before Flutter accepted it, an
          // error response is the last safe fallback. This stays on the same
          // worker and cannot race another MethodResult completion.
          ReplyCaptureError(shared_result, "native_capture_failed",
                            "Unable to return screenshot result");
        }
      } catch (const std::bad_alloc&) {
        ReplyCaptureError(shared_result, "out_of_memory",
                          "Screen capture exceeded available memory");
      } catch (const std::exception&) {
        ReplyCaptureError(shared_result, "native_capture_failed",
                          "PNG encoding failed");
      } catch (...) {
        ReplyCaptureError(shared_result, "native_capture_failed",
                          "PNG encoding failed");
      }
    });
    try {
      worker.detach();
    } catch (...) {
      // A valid joinable worker should detach successfully. If Windows refuses
      // the detach, join it so destruction of a joinable std::thread cannot
      // terminate the process.
      if (worker.joinable()) worker.join();
    }
  } catch (const std::exception&) {
    ReplyCaptureError(shared_result, "native_capture_failed",
                      "Unable to start screenshot encoding");
  } catch (...) {
    ReplyCaptureError(shared_result, "native_capture_failed",
                      "Unable to start screenshot encoding");
  }
}

struct ForegroundRestore {
  HWND window = GetForegroundWindow();
  ~ForegroundRestore() {
    if (window && IsWindow(window)) SetForegroundWindow(window);
  }
};

RECT VirtualDesktop() {
  const LONG left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const LONG top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  return {left, top, left + GetSystemMetrics(SM_CXVIRTUALSCREEN),
          top + GetSystemMetrics(SM_CYVIRTUALSCREEN)};
}

HBITMAP CaptureScreenToBitmap(int* width, int* height, int* x, int* y,
                              bool includeCursor) {
  const RECT desktop = VirtualDesktop();
  const int64_t desktopWidth = static_cast<int64_t>(desktop.right) - desktop.left;
  const int64_t desktopHeight = static_cast<int64_t>(desktop.bottom) - desktop.top;
  constexpr int64_t kMaximumDimension = 32768;
  if (desktopWidth <= 0 || desktopHeight <= 0) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return nullptr;
  }
  if (desktopWidth > kMaximumDimension || desktopHeight > kMaximumDimension ||
      desktopWidth * desktopHeight > kMaximumCapturePixels) {
    SetLastError(ERROR_FILE_TOO_LARGE);
    return nullptr;
  }
  *x = desktop.left;
  *y = desktop.top;
  *width = static_cast<int>(desktopWidth);
  *height = static_cast<int>(desktopHeight);
  ScreenDc screen;
  BitmapSurface image;
  if (!screen.dc || *width <= 0 || *height <= 0 ||
      !image.Create(screen.dc, *width, *height) ||
      !BitBlt(image.dc, 0, 0, *width, *height, screen.dc, *x, *y,
              SRCCOPY | CAPTUREBLT)) return nullptr;
  if (includeCursor) {
    CURSORINFO cursor = {};
    cursor.cbSize = sizeof(cursor);
    if (GetCursorInfo(&cursor) && (cursor.flags & CURSOR_SHOWING)) {
      ICONINFO icon = {};
      if (GetIconInfo(cursor.hCursor, &icon)) {
        DrawIconEx(image.dc, cursor.ptScreenPos.x - *x -
                    static_cast<int>(icon.xHotspot),
                   cursor.ptScreenPos.y - *y - static_cast<int>(icon.yHotspot),
                   cursor.hCursor, 0, 0, 0, nullptr, DI_NORMAL);
        if (icon.hbmMask) DeleteObject(icon.hbmMask);
        if (icon.hbmColor) DeleteObject(icon.hbmColor);
      }
    }
  }
  return image.Detach();
}

enum class SelectionDragMode {
  kNone,
  kCreate,
  kMove,
  kTopLeft,
  kTop,
  kTopRight,
  kRight,
  kBottomRight,
  kBottom,
  kBottomLeft,
  kLeft,
};

struct SelectionState {
  RECT desktop = {};
  std::vector<RECT> monitors;
  BitmapSurface original;
  BitmapSurface tint;
  HPEN selectionPen = nullptr;
  HBRUSH handleBrush = nullptr;
  HBRUSH cueBrush = nullptr;
  HFONT cueFont = nullptr;
  POINT start = {};
  POINT current = {};
  RECT selected = {};
  RECT selectionAtDragStart = {};
  RECT selectionAtLastValidDrag = {};
  RECT moveBounds = {};
  SelectionDragMode dragMode = SelectionDragMode::kNone;
  bool selecting = false;
  bool selectionTooSmall = false;
  bool moveBlockedByCoverageGap = false;
  bool cancelled = true;
  bool failed = false;
  bool closing = false;

  ~SelectionState() {
    if (selectionPen) DeleteObject(selectionPen);
    if (handleBrush) DeleteObject(handleBrush);
    if (cueBrush) DeleteObject(cueBrush);
    if (cueFont) DeleteObject(cueFont);
  }

  bool CreateDrawingResources() {
    selectionPen = CreatePen(PS_SOLID, 2, RGB(32, 199, 181));
    handleBrush = CreateSolidBrush(RGB(32, 199, 181));
    cueBrush = CreateSolidBrush(RGB(3, 42, 82));
    cueFont = CreateFontW(-16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                          DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                          CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                          DEFAULT_PITCH, L"Microsoft YaHei UI");
    return selectionPen && handleBrush && cueBrush && cueFont;
  }
};

BOOL CALLBACK CollectMonitor(HMONITOR, HDC, LPRECT rect, LPARAM data) {
  try {
    reinterpret_cast<std::vector<RECT>*>(data)->push_back(*rect);
    return TRUE;
  } catch (...) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return FALSE;
  }
}

// A PNG is rectangular. Choose the largest fully covered rectangle inside
// the drag, so gaps in staggered/disconnected monitor layouts cannot become
// uninitialized pixels. The exact clipped rectangle is also drawn on screen.
// Adjacent monitors without a gap remain selectable together.
RECT ClipToDisplays(const RECT& requested, const std::vector<RECT>& monitors) {
  std::vector<RECT> intersections;
  std::vector<LONG> xs;
  std::vector<LONG> ys;
  for (const RECT& monitor : monitors) {
    RECT intersection = {};
    if (IntersectRect(&intersection, &requested, &monitor)) {
      intersections.push_back(intersection);
      xs.push_back(intersection.left);
      xs.push_back(intersection.right);
      ys.push_back(intersection.top);
      ys.push_back(intersection.bottom);
    }
  }
  auto uniqueEdges = [](std::vector<LONG>& edges) {
    std::sort(edges.begin(), edges.end());
    edges.erase(std::unique(edges.begin(), edges.end()), edges.end());
  };
  uniqueEdges(xs);
  uniqueEdges(ys);
  RECT best = {};
  int64_t bestArea = 0;
  for (size_t left = 0; left < xs.size(); ++left) {
    for (size_t right = left + 1; right < xs.size(); ++right) {
      LONG runTop = 0;
      bool inRun = false;
      for (size_t row = 0; row + 1 < ys.size(); ++row) {
        std::vector<std::pair<LONG, LONG>> coverage;
        for (const RECT& rect : intersections) {
          if (rect.top <= ys[row] && rect.bottom >= ys[row + 1])
            coverage.emplace_back(rect.left, rect.right);
        }
        std::sort(coverage.begin(), coverage.end());
        LONG coveredUntil = xs[left];
        for (const auto& interval : coverage) {
          if (interval.first > coveredUntil) break;
          coveredUntil = (std::max)(coveredUntil, interval.second);
        }
        if (coveredUntil >= xs[right]) {
          if (!inRun) runTop = ys[row];
          inRun = true;
          const int64_t area = static_cast<int64_t>(xs[right] - xs[left]) *
                               (ys[row + 1] - runTop);
          if (area > bestArea) {
            bestArea = area;
            best = {xs[left], runTop, xs[right], ys[row + 1]};
          }
        } else {
          inRun = false;
        }
      }
    }
  }
  return best;
}

HBITMAP CaptureRegionAtBounds(const RECT& requested, int* width, int* height,
                              int* x, int* y) {
  SetLastError(ERROR_SUCCESS);
  const int64_t requested_width =
      static_cast<int64_t>(requested.right) - requested.left;
  const int64_t requested_height =
      static_cast<int64_t>(requested.bottom) - requested.top;
  constexpr int64_t kMaximumDimension = 32768;
  if (requested_width <= 0 || requested_height <= 0) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return nullptr;
  }
  if (requested_width > kMaximumDimension ||
      requested_height > kMaximumDimension ||
      requested_width * requested_height > kMaximumCapturePixels) {
    SetLastError(ERROR_FILE_TOO_LARGE);
    return nullptr;
  }

  std::vector<RECT> monitors;
  if (!EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                           reinterpret_cast<LPARAM>(&monitors)) ||
      monitors.empty()) {
    return nullptr;
  }
  const RECT covered = ClipToDisplays(requested, monitors);
  if (covered.left != requested.left || covered.top != requested.top ||
      covered.right != requested.right || covered.bottom != requested.bottom) {
    // The selected display may have been disconnected or moved since pinning.
    SetLastError(ERROR_INVALID_PARAMETER);
    return nullptr;
  }

  ScreenDc screen;
  BitmapSurface selected;
  *width = static_cast<int>(requested_width);
  *height = static_cast<int>(requested_height);
  *x = requested.left;
  *y = requested.top;
  if (!screen.dc || !selected.Create(screen.dc, *width, *height) ||
      !BitBlt(selected.dc, 0, 0, *width, *height, screen.dc, *x, *y,
              SRCCOPY | CAPTUREBLT)) {
    return nullptr;
  }
  return selected.Detach();
}

bool ResizeKeepsFixedEdges(SelectionDragMode mode, const RECT& requested,
                           const RECT& clipped) {
  switch (mode) {
    case SelectionDragMode::kTopLeft:
      return clipped.right == requested.right &&
             clipped.bottom == requested.bottom;
    case SelectionDragMode::kTop:
      return clipped.left == requested.left &&
             clipped.right == requested.right &&
             clipped.bottom == requested.bottom;
    case SelectionDragMode::kTopRight:
      return clipped.left == requested.left &&
             clipped.bottom == requested.bottom;
    case SelectionDragMode::kRight:
      return clipped.left == requested.left &&
             clipped.top == requested.top &&
             clipped.bottom == requested.bottom;
    case SelectionDragMode::kBottomRight:
      return clipped.left == requested.left && clipped.top == requested.top;
    case SelectionDragMode::kBottom:
      return clipped.left == requested.left &&
             clipped.right == requested.right &&
             clipped.top == requested.top;
    case SelectionDragMode::kBottomLeft:
      return clipped.right == requested.right &&
             clipped.top == requested.top;
    case SelectionDragMode::kLeft:
      return clipped.top == requested.top &&
             clipped.right == requested.right &&
             clipped.bottom == requested.bottom;
    case SelectionDragMode::kNone:
    case SelectionDragMode::kCreate:
    case SelectionDragMode::kMove:
      return false;
  }
  return false;
}

SelectionDragMode HitTestSelection(const SelectionState& state, POINT point) {
  if (IsRectEmpty(&state.selected)) return SelectionDragMode::kCreate;

  const RECT& selection = state.selected;
  const LONG midX = (selection.left + selection.right) / 2;
  const LONG midY = (selection.top + selection.bottom) / 2;
  constexpr LONG kHandleHitRadius = 9;
  const std::array<std::pair<POINT, SelectionDragMode>, 8> handles = {{
      {{selection.left, selection.top}, SelectionDragMode::kTopLeft},
      {{midX, selection.top}, SelectionDragMode::kTop},
      {{selection.right, selection.top}, SelectionDragMode::kTopRight},
      {{selection.right, midY}, SelectionDragMode::kRight},
      {{selection.right, selection.bottom}, SelectionDragMode::kBottomRight},
      {{midX, selection.bottom}, SelectionDragMode::kBottom},
      {{selection.left, selection.bottom}, SelectionDragMode::kBottomLeft},
      {{selection.left, midY}, SelectionDragMode::kLeft},
  }};
  SelectionDragMode nearestHandle = SelectionDragMode::kNone;
  int64_t nearestDistance = kHandleHitRadius * kHandleHitRadius + 1;
  for (const auto& handle : handles) {
    const int64_t dx = static_cast<int64_t>(point.x) - handle.first.x;
    const int64_t dy = static_cast<int64_t>(point.y) - handle.first.y;
    const int64_t distance = dx * dx + dy * dy;
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestHandle = handle.second;
    }
  }
  if (nearestHandle != SelectionDragMode::kNone) return nearestHandle;
  return PtInRect(&selection, point) ? SelectionDragMode::kMove
                                    : SelectionDragMode::kCreate;
}

void UpdateSelection(SelectionState& state) {
  // GetCursorPos uses the process's PerMonitorV2 physical coordinates and
  // avoids the signed 16-bit WM_MOUSEMOVE coordinate limit.
  GetCursorPos(&state.current);
  const RECT& initial = state.selectionAtDragStart;
  RECT requested = initial;
  constexpr LONG kPreferredMinimumSelectionExtent = 12;
  const LONG minimumWidth = (std::min)(
      kPreferredMinimumSelectionExtent, initial.right - initial.left);
  const LONG minimumHeight = (std::min)(
      kPreferredMinimumSelectionExtent, initial.bottom - initial.top);
  switch (state.dragMode) {
    case SelectionDragMode::kCreate:
      requested = {(std::min)(state.start.x, state.current.x),
                   (std::min)(state.start.y, state.current.y),
                   (std::max)(state.start.x, state.current.x),
                   (std::max)(state.start.y, state.current.y)};
      break;
    case SelectionDragMode::kMove: {
      const LONG width = initial.right - initial.left;
      const LONG height = initial.bottom - initial.top;
      LONG dx = state.current.x - state.start.x;
      LONG dy = state.current.y - state.start.y;
      const RECT& bounds = IsRectEmpty(&state.moveBounds)
          ? state.desktop
          : state.moveBounds;
      dx = (std::max)(bounds.left - initial.left,
                      (std::min)(dx, bounds.right - initial.right));
      dy = (std::max)(bounds.top - initial.top,
                      (std::min)(dy, bounds.bottom - initial.bottom));
      requested = {initial.left + dx, initial.top + dy,
                   initial.left + dx + width, initial.top + dy + height};
      break;
    }
    case SelectionDragMode::kTopLeft:
      requested.left = (std::min)(state.current.x,
                                   initial.right - minimumWidth);
      requested.top = (std::min)(state.current.y,
                                  initial.bottom - minimumHeight);
      break;
    case SelectionDragMode::kTop:
      requested.top = (std::min)(state.current.y,
                                  initial.bottom - minimumHeight);
      break;
    case SelectionDragMode::kTopRight:
      requested.right = (std::max)(state.current.x,
                                   initial.left + minimumWidth);
      requested.top = (std::min)(state.current.y,
                                  initial.bottom - minimumHeight);
      break;
    case SelectionDragMode::kRight:
      requested.right = (std::max)(state.current.x,
                                   initial.left + minimumWidth);
      break;
    case SelectionDragMode::kBottomRight:
      requested.right = (std::max)(state.current.x,
                                   initial.left + minimumWidth);
      requested.bottom = (std::max)(state.current.y,
                                    initial.top + minimumHeight);
      break;
    case SelectionDragMode::kBottom:
      requested.bottom = (std::max)(state.current.y,
                                    initial.top + minimumHeight);
      break;
    case SelectionDragMode::kBottomLeft:
      requested.left = (std::min)(state.current.x,
                                   initial.right - minimumWidth);
      requested.bottom = (std::max)(state.current.y,
                                    initial.top + minimumHeight);
      break;
    case SelectionDragMode::kLeft:
      requested.left = (std::min)(state.current.x,
                                   initial.right - minimumWidth);
      break;
    case SelectionDragMode::kNone:
      return;
  }

  state.selectionTooSmall = false;
  if (state.dragMode == SelectionDragMode::kCreate &&
      (requested.right - requested.left < kPreferredMinimumSelectionExtent ||
       requested.bottom - requested.top < kPreferredMinimumSelectionExtent)) {
    state.selected = {};
    state.selectionTooSmall = true;
    return;
  }

  if (state.dragMode == SelectionDragMode::kMove) {
    if (state.moveBlockedByCoverageGap) return;
    RECT clipped = ClipToDisplays(requested, state.monitors);
    // A move must never crop the rectangle. Stop at the first uncovered area
    // so a drag cannot jump across a monitor gap onto another display.
    if (EqualRect(&requested, &clipped)) {
      state.selected = requested;
      state.selectionAtLastValidDrag = requested;
    } else {
      state.moveBlockedByCoverageGap = true;
    }
    return;
  }
  RECT clipped = {};
  if (IntersectRect(&clipped, &requested, &state.desktop))
    state.selected = ClipToDisplays(clipped, state.monitors);
  else
    state.selected = {};
  if (state.dragMode == SelectionDragMode::kCreate &&
      (state.selected.right - state.selected.left <
           kPreferredMinimumSelectionExtent ||
       state.selected.bottom - state.selected.top <
           kPreferredMinimumSelectionExtent)) {
    state.selected = {};
    state.selectionTooSmall = true;
  } else if (state.dragMode != SelectionDragMode::kCreate &&
             (!ResizeKeepsFixedEdges(state.dragMode, requested, state.selected) ||
              state.selected.right - state.selected.left < minimumWidth ||
              state.selected.bottom - state.selected.top < minimumHeight)) {
    // Multi-monitor clipping may not move the edge opposite the active handle.
    // Keep the last visible rectangle rather than shifting or shrinking it.
    state.selected = state.selectionAtLastValidDrag;
    return;
  }
  state.selectionAtLastValidDrag = state.selected;
}

void CloseOverlay(HWND window, SelectionState& state, bool cancelled) {
  state.cancelled = cancelled;
  state.closing = true;
  state.selecting = false;
  state.dragMode = SelectionDragMode::kNone;
  if (GetCapture() == window) ReleaseCapture();
  DestroyWindow(window);
}

bool CueRectForCursor(const SelectionState& state, POINT cursor,
                      bool hasSelection, RECT* cue) {
  MONITORINFO monitorInfo = {};
  monitorInfo.cbSize = sizeof(monitorInfo);
  if (!GetMonitorInfo(MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST),
                      &monitorInfo)) {
    return false;
  }

  RECT monitor = monitorInfo.rcMonitor;
  OffsetRect(&monitor, -state.desktop.left, -state.desktop.top);
  const LONG cueWidth = (std::min)(300L, monitor.right - monitor.left);
  const LONG cueHeight = hasSelection ? 42 : 30;
  LONG cueX = cursor.x - state.desktop.left + 14;
  LONG cueY = cursor.y - state.desktop.top + 18;
  cueX = (std::max)(monitor.left, (std::min)(cueX, monitor.right - cueWidth));
  cueY = (std::max)(monitor.top, (std::min)(cueY, monitor.bottom - cueHeight));
  *cue = {cueX, cueY, cueX + cueWidth, cueY + cueHeight};
  return true;
}

RECT ToOverlayCoordinates(RECT rect, const SelectionState& state) {
  OffsetRect(&rect, -state.desktop.left, -state.desktop.top);
  return rect;
}

void InvalidateSelectionMarkers(HWND window, RECT selection,
                                const SelectionState& state) {
  if (IsRectEmpty(&selection)) return;
  selection = ToOverlayCoordinates(selection, state);
  const LONG inset = 5;
  const std::array<RECT, 4> markers = {{
    {selection.left - inset, selection.top - inset,
     selection.right + inset, selection.top + inset},
    {selection.left - inset, selection.bottom - inset,
     selection.right + inset, selection.bottom + inset},
    {selection.left - inset, selection.top + inset,
     selection.left + inset, selection.bottom - inset},
    {selection.right - inset, selection.top + inset,
     selection.right + inset, selection.bottom - inset},
  }};
  for (const RECT& marker : markers) {
    if (!IsRectEmpty(&marker)) InvalidateRect(window, &marker, FALSE);
  }
}

void InvalidateRectDifference(HWND window, const RECT& first,
                              const RECT& second) {
  RECT intersection = {};
  if (!IntersectRect(&intersection, &first, &second)) {
    if (!IsRectEmpty(&first)) InvalidateRect(window, &first, FALSE);
    if (!IsRectEmpty(&second)) InvalidateRect(window, &second, FALSE);
    return;
  }

  auto invalidateOutsideIntersection = [window, &intersection](const RECT& rect) {
    const std::array<RECT, 4> strips = {{
      {rect.left, rect.top, rect.right, intersection.top},
      {rect.left, intersection.bottom, rect.right, rect.bottom},
      {rect.left, intersection.top, intersection.left, intersection.bottom},
      {intersection.right, intersection.top, rect.right, intersection.bottom},
    }};
    for (const RECT& strip : strips) {
      if (!IsRectEmpty(&strip)) InvalidateRect(window, &strip, FALSE);
    }
  };
  invalidateOutsideIntersection(first);
  invalidateOutsideIntersection(second);
}

void InvalidateOverlayChanges(HWND window, SelectionState& state,
                              RECT previousSelection, POINT previousCursor,
                              bool previousTooSmall,
                              bool previousMoveBlockedByCoverageGap) {
  RECT oldSelection = previousSelection;
  RECT newSelection = state.selected;
  if (!IsRectEmpty(&oldSelection)) InflateRect(&oldSelection, 5, 5);
  if (!IsRectEmpty(&newSelection)) InflateRect(&newSelection, 5, 5);
  InvalidateRectDifference(
      window, ToOverlayCoordinates(oldSelection, state),
      ToOverlayCoordinates(newSelection, state));
  // Resizing can move midpoint handles along an otherwise unchanged edge.
  // Redraw the old/new thin marker bands as well as the changed selection area.
  InvalidateSelectionMarkers(window, previousSelection, state);
  InvalidateSelectionMarkers(window, state.selected, state);

  RECT oldCue = {};
  RECT newCue = {};
  const bool previouslyHadSelection = !IsRectEmpty(&previousSelection);
  const bool currentlyHasSelection = !IsRectEmpty(&state.selected);
  const bool cueStateChanged =
      previouslyHadSelection != currentlyHasSelection ||
      previousTooSmall != state.selectionTooSmall ||
      previousMoveBlockedByCoverageGap != state.moveBlockedByCoverageGap;
  if (CueRectForCursor(state, previousCursor, previouslyHadSelection, &oldCue) &&
      CueRectForCursor(state, state.current, currentlyHasSelection, &newCue) &&
      (cueStateChanged || !EqualRect(&oldCue, &newCue))) {
    InvalidateRect(window, &oldCue, FALSE);
    InvalidateRect(window, &newCue, FALSE);
  }
}

bool DrawOverlay(HDC destination, SelectionState& state) {
  const int width = state.desktop.right - state.desktop.left;
  const int height = state.desktop.bottom - state.desktop.top;
  // BeginPaint clips these full-desktop operations to the invalid region. The
  // cached source is only one full-size bitmap; darkening and selection restore
  // happen directly in the paint DC, avoiding dimmed/frame full-screen copies.
  BitBlt(destination, 0, 0, width, height, state.original.dc, 0, 0, SRCCOPY);
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 107, 0};  // 42% navy opacity.
  if (!AlphaBlend(destination, 0, 0, width, height, state.tint.dc, 0, 0, 1,
                  1, blend)) {
    return false;
  }
  RECT selected = state.selected;
  OffsetRect(&selected, -state.desktop.left, -state.desktop.top);
  if (!IsRectEmpty(&selected)) {
    BitBlt(destination, selected.left, selected.top,
           selected.right - selected.left, selected.bottom - selected.top,
           state.original.dc, selected.left, selected.top, SRCCOPY);
    HGDIOBJ oldPen = SelectObject(destination, state.selectionPen);
    HGDIOBJ oldBrush = SelectObject(destination, GetStockObject(NULL_BRUSH));
    Rectangle(destination, selected.left, selected.top, selected.right,
              selected.bottom);
    SelectObject(destination, oldPen);
    SelectObject(destination, oldBrush);

    const LONG midX = (selected.left + selected.right) / 2;
    const LONG midY = (selected.top + selected.bottom) / 2;
    const std::array<POINT, 8> handles = {{
      {selected.left, selected.top}, {midX, selected.top},
      {selected.right, selected.top}, {selected.right, midY},
      {selected.right, selected.bottom}, {midX, selected.bottom},
      {selected.left, selected.bottom}, {selected.left, midY}
    }};
    for (const POINT& handle : handles) {
      RECT outer = {handle.x - 4, handle.y - 4, handle.x + 4, handle.y + 4};
      FillRect(destination, &outer, state.handleBrush);
      InflateRect(&outer, -1, -1);
      FillRect(destination, &outer,
               static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH)));
    }
  }

  RECT cue = {};
  if (!CueRectForCursor(state, state.current,
                        !IsRectEmpty(&state.selected), &cue)) return true;
  FillRect(destination, &cue, state.cueBrush);
  HGDIOBJ oldFont = SelectObject(destination, state.cueFont);
  SetBkMode(destination, TRANSPARENT);
  SetTextColor(destination, RGB(255, 255, 255));
  // Unicode escapes make the Win32 cue independent of the compiler code page.
  const bool hasSelection = !IsRectEmpty(&state.selected);
  const wchar_t* instruction = hasSelection && state.moveBlockedByCoverageGap
      ? L"\u5C4F\u5E55\u7A7A\u9699\u963B\u6321\u79FB\u52A8\n\u677E\u5F00\u540E\u53EF\u91CD\u65B0\u6846\u9009"
      : hasSelection
      ? L"\u62D6\u70B9\u7F29\u653E \u00B7 \u6846\u5185\u79FB\u52A8\nEnter \u786E\u8BA4 \u00B7 Esc \u53D6\u6D88"
      : state.selectionTooSmall
      ? L"\u533A\u57DF\u592A\u5C0F \u00B7 \u8BF7\u91CD\u65B0\u6846\u9009"
      : L"\u62D6\u52A8\u6846\u9009 \u00B7 Esc \u53D6\u6D88";
  const UINT instructionFormat = DT_CENTER | DT_VCENTER |
      (hasSelection ? DT_WORDBREAK : DT_SINGLELINE);
  DrawTextW(destination, instruction, -1, &cue, instructionFormat);
  SelectObject(destination, oldFont);
  return true;
}

LRESULT CALLBACK OverlayWndProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lParam);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* state = reinterpret_cast<SelectionState*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (!state) return DefWindowProc(window, message, wParam, lParam);
  try {
    switch (message) {
    case WM_LBUTTONDOWN: {
      const RECT previousSelection = state->selected;
      const POINT previousCursor = state->current;
      const bool previousTooSmall = state->selectionTooSmall;
      const bool previousMoveBlockedByCoverageGap =
          state->moveBlockedByCoverageGap;
      GetCursorPos(&state->start);
      state->current = state->start;
      state->selectionAtDragStart = state->selected;
      state->selectionAtLastValidDrag = state->selected;
      state->dragMode = HitTestSelection(*state, state->start);
      state->moveBounds = state->desktop;
      state->selectionTooSmall = false;
      state->moveBlockedByCoverageGap = false;
      if (state->dragMode == SelectionDragMode::kCreate) {
        state->selected = {};
        state->selectionAtLastValidDrag = {};
      } else if (state->dragMode == SelectionDragMode::kMove) {
        for (const RECT& monitor : state->monitors) {
          if (state->selected.left >= monitor.left &&
              state->selected.top >= monitor.top &&
              state->selected.right <= monitor.right &&
              state->selected.bottom <= monitor.bottom) {
            // Keep a single-monitor selection on that monitor while moving;
            // it cannot jump across a physical gap to a second display.
            state->moveBounds = monitor;
            break;
          }
        }
      }
      state->selecting = true;
      SetCapture(window);
      UpdateSelection(*state);
      InvalidateOverlayChanges(window, *state, previousSelection,
                               previousCursor, previousTooSmall,
                               previousMoveBlockedByCoverageGap);
      return 0;
    }
    case WM_MOUSEMOVE: {
      const RECT previousSelection = state->selected;
      const POINT previousCursor = state->current;
      const bool previousTooSmall = state->selectionTooSmall;
      const bool previousMoveBlockedByCoverageGap =
          state->moveBlockedByCoverageGap;
      if (state->selecting) UpdateSelection(*state);
      else GetCursorPos(&state->current);
      InvalidateOverlayChanges(window, *state, previousSelection,
                               previousCursor, previousTooSmall,
                               previousMoveBlockedByCoverageGap);
      return 0;
    }
    case WM_LBUTTONUP:
      if (state->selecting) {
        const RECT previousSelection = state->selected;
        const POINT previousCursor = state->current;
        const bool previousTooSmall = state->selectionTooSmall;
        const bool previousMoveBlockedByCoverageGap =
            state->moveBlockedByCoverageGap;
        UpdateSelection(*state);
        state->selecting = false;
        state->dragMode = SelectionDragMode::kNone;
        state->moveBlockedByCoverageGap = false;
        if (GetCapture() == window) ReleaseCapture();
        InvalidateOverlayChanges(window, *state, previousSelection,
                                 previousCursor, previousTooSmall,
                                 previousMoveBlockedByCoverageGap);
      }
      return 0;
    case WM_KEYDOWN:
      if (wParam == VK_ESCAPE) {
        CloseOverlay(window, *state, true);
      } else if (wParam == VK_RETURN && !state->selecting &&
                 !IsRectEmpty(&state->selected)) {
        CloseOverlay(window, *state, false);
      } else {
        return DefWindowProcW(window, message, wParam, lParam);
      }
      return 0;
    case WM_SYSKEYDOWN:
      return DefWindowProcW(window, message, wParam, lParam);
    case WM_SETCURSOR:
      if (LOWORD(lParam) == HTCLIENT) {
        POINT cursor{};
        GetCursorPos(&cursor);
        const SelectionDragMode mode = HitTestSelection(*state, cursor);
        LPCWSTR cursorName = IDC_CROSS;
        switch (mode) {
          case SelectionDragMode::kMove:
            cursorName = IDC_SIZEALL;
            break;
          case SelectionDragMode::kTopLeft:
          case SelectionDragMode::kBottomRight:
            cursorName = IDC_SIZENWSE;
            break;
          case SelectionDragMode::kTop:
          case SelectionDragMode::kBottom:
            cursorName = IDC_SIZENS;
            break;
          case SelectionDragMode::kTopRight:
          case SelectionDragMode::kBottomLeft:
            cursorName = IDC_SIZENESW;
            break;
          case SelectionDragMode::kRight:
          case SelectionDragMode::kLeft:
            cursorName = IDC_SIZEWE;
            break;
          case SelectionDragMode::kNone:
          case SelectionDragMode::kCreate:
            break;
        }
        SetCursor(LoadCursorW(nullptr, cursorName));
        return TRUE;
      }
      return DefWindowProcW(window, message, wParam, lParam);
    case WM_RBUTTONDOWN:
    case WM_CLOSE:
      CloseOverlay(window, *state, true);
      return 0;
    case WM_CAPTURECHANGED:
      if (state->selecting && !state->closing) CloseOverlay(window, *state, true);
      return 0;
    case WM_DISPLAYCHANGE:
      state->failed = true;  // Snapshot geometry is no longer current.
      CloseOverlay(window, *state, false);
      return 0;
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint;
      HDC dc = BeginPaint(window, &paint);
      const bool drawSucceeded = DrawOverlay(dc, *state);
      EndPaint(window, &paint);
      if (!drawSucceeded) {
        state->failed = true;
        CloseOverlay(window, *state, false);
      }
      return 0;
    }
    }
    return DefWindowProc(window, message, wParam, lParam);
  } catch (...) {
    // C++ exceptions must never cross the Win32 WNDPROC boundary. Treat an
    // allocation or drawing failure as a cancelled capture and destroy the
    // selection surface.
    state->failed = true;
    state->cancelled = true;
    state->selecting = false;
    state->closing = true;
    if (GetCapture() == window) ReleaseCapture();
    DestroyWindow(window);
    return 0;
  }
}

HBITMAP CaptureRegionToBitmap(int* width, int* height, int* x, int* y, bool* cancelled) {
  *cancelled = false;
  ForegroundRestore foreground;
  SelectionState state;
  state.desktop = VirtualDesktop();
  const int64_t desktopWidth64 =
      static_cast<int64_t>(state.desktop.right) - state.desktop.left;
  const int64_t desktopHeight64 =
      static_cast<int64_t>(state.desktop.bottom) - state.desktop.top;
  constexpr int64_t kMaximumDimension = 32768;
  if (desktopWidth64 <= 0 || desktopHeight64 <= 0) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return nullptr;
  }
  if (desktopWidth64 > kMaximumDimension ||
      desktopHeight64 > kMaximumDimension ||
      desktopWidth64 * desktopHeight64 > kMaximumCapturePixels) {
    SetLastError(ERROR_FILE_TOO_LARGE);
    return nullptr;
  }
  const int desktopWidth = static_cast<int>(desktopWidth64);
  const int desktopHeight = static_cast<int>(desktopHeight64);
  ScreenDc screen;
  if (desktopWidth <= 0 || desktopHeight <= 0 || !screen.dc ||
      !EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                           reinterpret_cast<LPARAM>(&state.monitors)) ||
      state.monitors.empty() ||
      !state.original.Create(screen.dc, desktopWidth, desktopHeight) ||
      !state.tint.Create(screen.dc, 1, 1) ||
      !state.CreateDrawingResources()) return nullptr;

  // All pixels stay in this call's memory. Take exactly one immutable desktop
  // snapshot before showing the overlay; selected PNG uses the same pixels.
  if (!BitBlt(state.original.dc, 0, 0, desktopWidth, desktopHeight, screen.dc,
              state.desktop.left, state.desktop.top, SRCCOPY | CAPTUREBLT))
    return nullptr;
  if (SetPixel(state.tint.dc, 0, 0, RGB(3, 42, 82)) == CLR_INVALID)
    return nullptr;
  GetCursorPos(&state.current);

  const wchar_t* className = L"YixueScreenshotOverlay";
  const HINSTANCE instance = GetModuleHandle(nullptr);
  WNDCLASSEXW windowClass = {};
  windowClass.cbSize = sizeof(windowClass);
  windowClass.lpfnWndProc = OverlayWndProc;
  windowClass.hInstance = instance;
  windowClass.hCursor = LoadCursor(nullptr, IDC_CROSS);
  windowClass.lpszClassName = className;
  const bool registered = RegisterClassExW(&windowClass) != 0;
  if (!registered && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
  HWND overlay = CreateWindowExW(
    WS_EX_TOPMOST | WS_EX_TOOLWINDOW, className, L"\u8BD1\u5B66\u622A\u5C4F\u9009\u533A",
    WS_POPUP, state.desktop.left, state.desktop.top, desktopWidth, desktopHeight,
    nullptr, nullptr, instance, &state);
  if (!overlay) {
    if (registered) UnregisterClassW(className, instance);
    return nullptr;
  }
  // Clip the window itself to the physical monitor union (no invisible gap
  // captures), while keeping the virtual desktop coordinate system intact.
  HRGN monitorRegion = CreateRectRgn(0, 0, 0, 0);
  if (!monitorRegion) {
    DestroyWindow(overlay);
    if (registered) UnregisterClassW(className, instance);
    return nullptr;
  }
  for (const RECT& monitor : state.monitors) {
    HRGN part = CreateRectRgn(monitor.left - state.desktop.left,
                             monitor.top - state.desktop.top,
                             monitor.right - state.desktop.left,
                             monitor.bottom - state.desktop.top);
    if (!part || CombineRgn(monitorRegion, monitorRegion, part, RGN_OR) == ERROR) {
      if (part) DeleteObject(part);
      DeleteObject(monitorRegion);
      DestroyWindow(overlay);
      if (registered) UnregisterClassW(className, instance);
      return nullptr;
    }
    DeleteObject(part);
  }
  if (!SetWindowRgn(overlay, monitorRegion, FALSE)) {
    DeleteObject(monitorRegion);
    DestroyWindow(overlay);
    if (registered) UnregisterClassW(className, instance);
    return nullptr;
  }  // Windows owns monitorRegion after SetWindowRgn succeeds.
  ShowWindow(overlay, SW_SHOW);
  SetForegroundWindow(overlay);
  SetFocus(overlay);
  UpdateWindow(overlay);

  // No PostQuitMessage on WM_DESTROY: this nested loop must not terminate the
  // Flutter runner's outer message loop. Preserve a real application WM_QUIT.
  MSG message = {};
  while (IsWindow(overlay)) {
    const BOOL status = GetMessage(&message, nullptr, 0, 0);
    if (status <= 0) {
      if (status == 0) PostQuitMessage(static_cast<int>(message.wParam));
      else state.failed = true;
      CloseOverlay(overlay, state, status == 0);
      break;
    }
    TranslateMessage(&message);
    DispatchMessage(&message);
  }
  if (registered) UnregisterClassW(className, instance);
  if (state.failed) return nullptr;
  if (state.cancelled || IsRectEmpty(&state.selected)) {
    *cancelled = true;
    return nullptr;
  }

  // Overlay is destroyed before original, undimmed snapshot pixels are copied.
  *x = state.selected.left;
  *y = state.selected.top;
  *width = state.selected.right - *x;
  *height = state.selected.bottom - *y;
  BitmapSurface selected;
  if (!selected.Create(screen.dc, *width, *height) ||
      !BitBlt(selected.dc, 0, 0, *width, *height, state.original.dc,
              *x - state.desktop.left, *y - state.desktop.top, SRCCOPY)) return nullptr;
  return selected.Detach();
}
// static
void ScreenshotPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "dev.flutter.screenshot",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<ScreenshotPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

ScreenshotPlugin::ScreenshotPlugin()
    : capture_in_progress_(std::make_shared<std::atomic_bool>(false)) {}

ScreenshotPlugin::~ScreenshotPlugin() {}

void ScreenshotPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  try {
  if (method_call.method_name().compare("capture") == 0) {
    // Extract parameters
    const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (!arguments) {
      result->Error("invalid_argument", "Arguments must be a map");
      return;
    }
    
    // Get mode parameter
    auto mode_it = arguments->find(flutter::EncodableValue("mode"));
    if (mode_it == arguments->end()) {
      result->Error("invalid_argument", "Missing 'mode' parameter");
      return;
    }
    
    const auto* mode_str = std::get_if<std::string>(&mode_it->second);
    if (!mode_str) {
      result->Error("invalid_argument", "'mode' must be a string");
      return;
    }
    
    // Validate mode
    if (*mode_str != "screen" && *mode_str != "region") {
      result->Error("invalid_argument", "Invalid mode: " + *mode_str);
      return;
    }
    
    // Get includeCursor parameter (optional, default false)
    bool includeCursor = false;
    auto cursor_it = arguments->find(flutter::EncodableValue("includeCursor"));
    if (cursor_it != arguments->end()) {
      const auto* cursor_bool = std::get_if<bool>(&cursor_it->second);
      if (cursor_bool) {
        includeCursor = *cursor_bool;
      }
    }
    
    // Reject reentrant calls while the native selection pumps Flutter messages,
    // and keep the operation busy through asynchronous PNG encoding.
    auto busy_lease = std::make_shared<CaptureBusyLease>(capture_in_progress_);
    if (capture_in_progress_->exchange(true, std::memory_order_acq_rel)) {
      result->Error("capture_in_progress", "A capture is already in progress");
      return;
    }
    busy_lease->Arm();

    if (*mode_str == "screen") {
      int width = 0;
      int height = 0;
      int x = 0;
      int y = 0;
      
      // Capture screen to bitmap
      HBITMAP hBitmap = CaptureScreenToBitmap(&width, &height, &x, &y, includeCursor);
      if (!hBitmap) {
        if (GetLastError() == ERROR_FILE_TOO_LARGE) {
          result->Error("image_too_large", "Select a smaller screen area");
          return;
        }
        result->Error("internal_error", "Failed to capture screen", 
                     flutter::EncodableValue(static_cast<int>(GetLastError())));
        return;
      }
      BitmapHandle bitmap(hBitmap);
      auto bitmap_owner = std::make_shared<BitmapHandle>(std::move(bitmap));
      EncodeCapturedBitmapAsync(bitmap_owner, width, height, x, y,
                                std::move(result), busy_lease);
      return;
    } else if (*mode_str == "region") {
      // Region mode (US2)
      int width = 0;
      int height = 0;
      int x = 0;
      int y = 0;
      bool cancelled = false;
      HBITMAP hBitmap = nullptr;
      const auto bounds_it = arguments->find(flutter::EncodableValue("bounds"));
      if (bounds_it == arguments->end()) {
        // Interactive region mode captures a fresh selection.
        hBitmap = CaptureRegionToBitmap(&width, &height, &x, &y, &cancelled);
        if (cancelled) {
          result->Success();  // Success with null value.
          return;
        }
      } else {
        const auto* bounds = std::get_if<flutter::EncodableMap>(&bounds_it->second);
        if (!bounds || bounds->size() != 4) {
          result->Error("invalid_region_bounds", "Invalid region bounds");
          return;
        }
        auto read_coordinate = [bounds](const char* name, int64_t* value) {
          const auto it = bounds->find(flutter::EncodableValue(name));
          if (it == bounds->end()) return false;
          if (const auto* int32_value = std::get_if<int32_t>(&it->second)) {
            *value = *int32_value;
            return true;
          }
          if (const auto* int64_value = std::get_if<int64_t>(&it->second)) {
            *value = *int64_value;
            return true;
          }
          return false;
        };
        int64_t left = 0, top = 0, requested_width = 0, requested_height = 0;
        if (!read_coordinate("left", &left) ||
            !read_coordinate("top", &top) ||
            !read_coordinate("width", &requested_width) ||
            !read_coordinate("height", &requested_height) ||
            left < (std::numeric_limits<LONG>::min)() ||
            left > (std::numeric_limits<LONG>::max)() ||
            top < (std::numeric_limits<LONG>::min)() ||
            top > (std::numeric_limits<LONG>::max)() ||
            requested_width <= 0 || requested_height <= 0 ||
            requested_width > (std::numeric_limits<LONG>::max)() - left ||
            requested_height > (std::numeric_limits<LONG>::max)() - top) {
          result->Error("invalid_region_bounds", "Invalid region bounds");
          return;
        }
        const RECT requested = {
            static_cast<LONG>(left), static_cast<LONG>(top),
            static_cast<LONG>(left + requested_width),
            static_cast<LONG>(top + requested_height)};
        hBitmap = CaptureRegionAtBounds(requested, &width, &height, &x, &y);
      }
      if (!hBitmap) {
        if (GetLastError() == ERROR_FILE_TOO_LARGE) {
          result->Error("image_too_large", "Select a smaller screen area");
          return;
        }
        if (bounds_it != arguments->end() &&
            GetLastError() == ERROR_INVALID_PARAMETER) {
          result->Error("invalid_region_bounds",
                        "The pinned region is no longer visible; select it again");
          return;
        }
        result->Error("internal_error", "Failed to capture selected region",
                      flutter::EncodableValue(static_cast<int>(GetLastError())));
        return;
      }
      BitmapHandle bitmap(hBitmap);
      auto bitmap_owner = std::make_shared<BitmapHandle>(std::move(bitmap));
      EncodeCapturedBitmapAsync(bitmap_owner, width, height, x, y,
                                std::move(result), busy_lease);
      return;
    } else {
      // Unknown mode
      result->Error("invalid_argument", "Invalid mode: " + *mode_str);
    }
  } else {
    result->NotImplemented();
  }
  } catch (const std::bad_alloc&) {
    try {
      result->Error("out_of_memory", "Screen capture exceeded available memory");
    } catch (...) {
      // Never let an exception cross the Flutter method-channel callback.
    }
  } catch (const std::exception&) {
    try {
      result->Error("native_capture_failed", "Native screen capture failed");
    } catch (...) {
      // Never let an exception cross the Flutter method-channel callback.
    }
  } catch (...) {
    try {
      result->Error("native_capture_failed", "Native screen capture failed");
    } catch (...) {
      // Never let an exception cross the Flutter method-channel callback.
    }
  }
}

}  // namespace screenshot
