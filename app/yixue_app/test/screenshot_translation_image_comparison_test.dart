import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/screenshot_translation_image_comparison.dart';

void main() {
  test(
    'equal image bytes yield to the event loop between bounded slices',
    () async {
      final previous = Uint8List(128 * 1024);
      final current = Uint8List.fromList(previous);
      var timerServiced = false;
      Timer.run(() => timerServiced = true);

      expect(
        await screenshotTranslationImageBytesDiffer(previous, current),
        isFalse,
      );
      expect(timerServiced, isTrue);
    },
  );

  test('detects a changed byte after more than one comparison slice', () async {
    final previous = Uint8List(128 * 1024);
    final current = Uint8List.fromList(previous)..[previous.length - 1] = 1;

    expect(
      await screenshotTranslationImageBytesDiffer(previous, current),
      isTrue,
    );
  });

  test('different image lengths are immediately reported as changed', () async {
    expect(
      await screenshotTranslationImageBytesDiffer(Uint8List(32), Uint8List(33)),
      isTrue,
    );
  });
}
