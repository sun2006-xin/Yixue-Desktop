#include "screenshot_orb_drag.h"

int main() {
  yixue::runner::ScreenshotOrbDragGesture gesture;
  gesture.Begin({100, 200}, {600, 300, 656, 356});

  if (gesture.Move({103, 202}, 5).has_value()) return 1;
  if (gesture.is_dragging()) return 2;

  const auto moved_left = gesture.Move({94, 201}, 5);
  if (!moved_left.has_value() || moved_left->x != 594 ||
      moved_left->y != 301 || !gesture.is_dragging()) {
    return 3;
  }

  if (!gesture.End() || gesture.is_pressed() || gesture.is_dragging()) return 4;
  if (gesture.Move({20, 20}, 5).has_value()) return 5;

  gesture.Begin({100, 200}, {600, 300, 656, 356});
  gesture.Cancel();
  if (gesture.is_pressed() || gesture.is_dragging()) return 6;
  return 0;
}
