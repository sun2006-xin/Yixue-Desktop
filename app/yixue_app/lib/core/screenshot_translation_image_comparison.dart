import 'dart:async';
import 'dart:typed_data';

/// Bounds uninterrupted byte comparison work on the UI isolate.
const screenshotTranslationImageCompareChunkBytes = 32 * 1024;

/// Returns whether two encoded screenshot images differ.
///
/// Large pinned-region captures can contain tens of megabytes. Yielding after
/// each small slice keeps input and frame work responsive while preserving an
/// exact comparison without copying the images into another isolate.
Future<bool> screenshotTranslationImageBytesDiffer(
  Uint8List previous,
  Uint8List current,
) async {
  if (previous.length != current.length) return true;
  for (
    var start = 0;
    start < previous.length;
    start += screenshotTranslationImageCompareChunkBytes
  ) {
    final end =
        start + screenshotTranslationImageCompareChunkBytes < previous.length
        ? start + screenshotTranslationImageCompareChunkBytes
        : previous.length;
    for (var index = start; index < end; index++) {
      if (previous[index] != current[index]) return true;
    }
    if (end < previous.length) await Future<void>.delayed(Duration.zero);
  }
  return false;
}
