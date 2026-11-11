import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/streaming_asr_text.dart';

void main() {
  group('resolveStreamingAsrText', () {
    test('keeps the last partial when final decoding is empty', () {
      expect(
        resolveStreamingAsrText(
          decodedText: '  ',
          previousText: 'recognized phrase',
          isFinal: true,
        ),
        'recognized phrase',
      );
    });

    test('ignores an empty partial and an empty final with no prior text', () {
      expect(
        resolveStreamingAsrText(
          decodedText: '',
          previousText: '',
          isFinal: false,
        ),
        isNull,
      );
      expect(
        resolveStreamingAsrText(
          decodedText: '',
          previousText: '',
          isFinal: true,
        ),
        isNull,
      );
    });

    test('prefers non-empty final text and trims it', () {
      expect(
        resolveStreamingAsrText(
          decodedText: ' final phrase ',
          previousText: 'partial phrase',
          isFinal: true,
        ),
        'final phrase',
      );
    });
  });
}
