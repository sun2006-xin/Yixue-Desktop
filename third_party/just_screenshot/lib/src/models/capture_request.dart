import 'captured_data.dart';
import 'screenshot_mode.dart';

/// Internal model for capture request parameters.
///
/// Used internally to pass parameters from public API to platform implementation.
/// This class is immutable and follows type safety principles.
class CaptureRequest {
  /// Creates a [CaptureRequest] instance.
  const CaptureRequest({
    required this.mode,
    this.includeCursor = false,
    this.displayId,
    this.bounds,
  });

  /// Screenshot capture mode (screen or region).
  final ScreenshotMode mode;

  /// Whether to include the cursor in the screenshot.
  final bool includeCursor;

  /// Optional display ID for multi-monitor setups (null = primary display).
  final int? displayId;

  /// When present with region mode, captures this physical rectangle without
  /// displaying the interactive selector.
  final ScreenshotBounds? bounds;

  /// Convert [CaptureRequest] to map for method channel.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'mode': mode.toValue(),
      'includeCursor': includeCursor,
      if (displayId != null) 'displayId': displayId,
      if (bounds case final bounds?)
        'bounds': {
          'left': bounds.left,
          'top': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        },
    };
  }

  /// Create [CaptureRequest] from map.
  factory CaptureRequest.fromMap(Map<Object?, Object?> map) {
    return CaptureRequest(
      mode: ScreenshotModeExtension.fromValue(map['mode'] as String),
      includeCursor: map['includeCursor'] as bool? ?? false,
      displayId: map['displayId'] as int?,
      bounds: map['bounds'] is Map
          ? ScreenshotBounds(
              left: (map['bounds'] as Map)['left'] as int,
              top: (map['bounds'] as Map)['top'] as int,
              width: (map['bounds'] as Map)['width'] as int,
              height: (map['bounds'] as Map)['height'] as int,
            )
          : null,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is CaptureRequest &&
        other.mode == mode &&
        other.includeCursor == includeCursor &&
        other.displayId == displayId &&
        other.bounds == bounds;
  }

  @override
  int get hashCode => Object.hash(mode, includeCursor, displayId, bounds);

  @override
  String toString() {
    return 'CaptureRequest(mode: $mode, includeCursor: $includeCursor, displayId: $displayId, bounds: $bounds)';
  }
}
