# Local integration notes

This directory vendors the Windows and Dart runtime sources from `just_screenshot` 0.1.0, licensed under BSD-3-Clause. It keeps only the library sources and upstream license/documentation needed by the app.

The upstream Windows CMake file defines `screenshot_plugin`, while Flutter generates a reference to `just_screenshot_plugin` from the package name. Its C API header is also stored under `include/screenshot`, while Flutter includes it under `just_screenshot`. The local copy aligns the CMake target, bundled-library variable, and header path with Flutter's generated names so the Windows app can build.

The application uses this package only for Windows region capture. Multi-monitor selection and high-DPI behavior have not been verified.

The Windows region overlay is locally optimized for interactive selection: it keeps one full-desktop snapshot, paints through the `BeginPaint` update-region clip, invalidates only changed selection bands and the old/new cursor cue, and reuses its GDI drawing resources. This avoids per-mouse-move full-desktop buffer copies and removes the full-size dimmed and frame bitmaps.

The Windows capture path limits desktop and region bitmaps to 20 million pixels and PNG payloads to 64 MiB. WIC, bitmap, Flutter method-channel, monitor-enumeration, and overlay-window callbacks use cleanup or exception barriers so allocation failures return capture errors instead of escaping native callbacks.
