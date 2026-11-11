import 'screenshot_platform_interface.dart';
import 'src/models/captured_data.dart';
import 'src/models/screenshot_mode.dart';

// Export public models
export 'src/models/captured_data.dart';
export 'src/models/screenshot_exception.dart';
export 'src/models/screenshot_mode.dart';

/// Screenshot plugin singleton.
///
/// Provides methods for capturing screenshots on Windows.
class Screenshot {
  Screenshot._();

  /// Singleton instance.
  static final Screenshot instance = Screenshot._();

  /// Capture a screenshot.
  ///
  /// - [mode]: Screenshot capture mode (screen or region)
  /// - [includeCursor]: Whether to include the cursor in the screenshot
  /// - [displayId]: Reserved display ID; Windows captures the virtual desktop
  ///
  /// Returns [CapturedData] with [ScreenshotBounds] in physical screen pixels
  /// (including negative display origins) and PNG-encoded bytes,
  /// or null if the operation was cancelled by the user.
  ///
  /// Throws [ScreenshotException] if the operation fails.
  ///
  /// Example:
  /// ```dart
  /// final screenshot = Screenshot.instance;
  /// final data = await screenshot.capture(mode: ScreenshotMode.screen);
  /// if (data != null) {
  ///   print('Captured ${data.width}x${data.height} screenshot');
  /// }
  /// ```
  Future<CapturedData?> capture({
    required ScreenshotMode mode,
    bool includeCursor = false,
    int? displayId,
  }) {
    return ScreenshotPlatform.instance.capture(
      mode: mode,
      includeCursor: includeCursor,
      displayId: displayId,
    );
  }

  /// Re-captures a previously selected rectangle without opening the selector.
  ///
  /// Bounds use absolute Windows physical screen pixels; negative origins are
  /// valid on displays placed left of or above the primary display. The native
  /// implementation rejects stale bounds that no longer fit a connected
  /// display.
  Future<CapturedData?> captureAtBounds(ScreenshotBounds bounds) {
    return ScreenshotPlatform.instance.captureAtBounds(bounds);
  }
}
