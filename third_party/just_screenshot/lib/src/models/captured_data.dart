import 'dart:typed_data';

/// An immutable rectangle in Windows physical screen pixels.
/// Origins may be negative; right and bottom edges are exclusive.
final class ScreenshotBounds {
  const ScreenshotBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  }) : assert(width > 0),
       assert(height > 0);

  final int left;
  final int top;
  final int width;
  final int height;
  int get right => left + width;
  int get bottom => top + height;

  @override
  bool operator ==(Object other) =>
      other is ScreenshotBounds &&
      left == other.left &&
      top == other.top &&
      width == other.width &&
      height == other.height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// Represents captured screenshot data with dimensions and pixel bytes.
///
/// This class is immutable and follows type safety principles.
class CapturedData {
  /// Creates a [CapturedData] instance.
  ///
  /// Validates that width and height are positive and bytes is non-empty.
  const CapturedData({
    required this.width,
    required this.height,
    required this.bytes,
    this.left = 0,
    this.top = 0,
  }) : assert(width > 0, 'Width must be positive'),
       assert(height > 0, 'Height must be positive'),
       assert(bytes.length > 0, 'Bytes must not be empty');

  /// Width of the captured image in pixels.
  final int width;

  /// Height of the captured image in pixels.
  final int height;

  final int left;
  final int top;
  ScreenshotBounds get bounds =>
      ScreenshotBounds(left: left, top: top, width: width, height: height);

  /// PNG-encoded image data as bytes.
  final Uint8List bytes;

  /// Create [CapturedData] from method channel response map.
  factory CapturedData.fromMap(Map<Object?, Object?> map) {
    final int width = map['width'] as int;
    final int height = map['height'] as int;
    final Uint8List bytes = map['bytes'] as Uint8List;
    final int left = map['left'] as int;
    final int top = map['top'] as int;
    if (width <= 0 || height <= 0 || bytes.isEmpty) {
      throw ArgumentError('Captured pixels and dimensions must be non-empty');
    }

    return CapturedData(
      left: left,
      top: top,
      width: width,
      height: height,
      bytes: bytes,
    );
  }

  /// Convert [CapturedData] to map for method channel.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'left': left,
      'top': top,
      'width': width,
      'height': height,
      'bytes': bytes,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is CapturedData &&
        other.left == left &&
        other.top == top &&
        other.width == width &&
        other.height == height &&
        _listEquals(other.bytes, bytes);
  }

  @override
  int get hashCode {
    int result = 17;
    result = 37 * result + left.hashCode;
    result = 37 * result + top.hashCode;
    result = 37 * result + width.hashCode;
    result = 37 * result + height.hashCode;
    // Hash bytes content, not identity
    for (final int byte in bytes) {
      result = 37 * result + byte.hashCode;
    }
    return result;
  }

  bool _listEquals<T>(List<T>? a, List<T>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    for (int index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  @override
  String toString() {
    return 'CapturedData(left: $left, top: $top, width: $width, height: $height, bytes: ${bytes.length} bytes)';
  }
}
