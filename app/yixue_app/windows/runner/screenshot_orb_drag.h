#ifndef RUNNER_SCREENSHOT_ORB_DRAG_H_
#define RUNNER_SCREENSHOT_ORB_DRAG_H_

#include <cstdint>
#include <cstdlib>
#include <optional>

namespace yixue::runner {

struct ScreenshotOrbDragPoint {
  std::int64_t x = 0;
  std::int64_t y = 0;
};

struct ScreenshotOrbDragRect {
  std::int64_t left = 0;
  std::int64_t top = 0;
  std::int64_t right = 0;
  std::int64_t bottom = 0;
};

// Tracks a left-button drag independently from Win32 message dispatch. A move
// is considered only after the pointer crosses the platform-scaled threshold.
class ScreenshotOrbDragGesture {
 public:
  void Begin(ScreenshotOrbDragPoint cursor,
             ScreenshotOrbDragRect bounds) noexcept {
    start_cursor_ = cursor;
    start_bounds_ = bounds;
    pressed_ = true;
    dragging_ = false;
  }

  std::optional<ScreenshotOrbDragPoint> Move(
      ScreenshotOrbDragPoint cursor,
      std::int64_t threshold) noexcept {
    if (!pressed_) return std::nullopt;

    const std::int64_t dx = cursor.x - start_cursor_.x;
    const std::int64_t dy = cursor.y - start_cursor_.y;
    if (!dragging_ && std::llabs(dx) < threshold &&
        std::llabs(dy) < threshold) {
      return std::nullopt;
    }

    dragging_ = true;
    return ScreenshotOrbDragPoint{start_bounds_.left + dx,
                                  start_bounds_.top + dy};
  }

  bool End() noexcept {
    const bool was_dragging = dragging_;
    pressed_ = false;
    dragging_ = false;
    return was_dragging;
  }

  void Cancel() noexcept {
    pressed_ = false;
    dragging_ = false;
  }

  bool is_pressed() const noexcept { return pressed_; }
  bool is_dragging() const noexcept { return dragging_; }

 private:
  ScreenshotOrbDragPoint start_cursor_{};
  ScreenshotOrbDragRect start_bounds_{};
  bool pressed_ = false;
  bool dragging_ = false;
};

}  // namespace yixue::runner

#endif  // RUNNER_SCREENSHOT_ORB_DRAG_H_
