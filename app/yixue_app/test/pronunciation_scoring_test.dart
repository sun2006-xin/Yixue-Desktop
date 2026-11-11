import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/pronunciation_scoring.dart';

void main() {
  test('gives a perfect score for the same words with punctuation differences', () {
    final result = scorePronunciation(
      targetText: 'Hello, world!',
      recognizedText: 'hello world',
    );

    expect(result.score, 100);
    expect(result.grade, '优秀');
    expect(result.missingTokens, isEmpty);
    expect(result.extraTokens, isEmpty);
  });

  test('reports missing and extra words without using a model', () {
    final result = scorePronunciation(
      targetText: 'A small habit can help.',
      recognizedText: 'a habit helps',
    );

    expect(result.score, lessThan(100));
    expect(result.missingTokens, contains('small'));
    expect(result.extraTokens, contains('helps'));
    expect(result.grade, '继续练习');
  });

  test('penalizes a reordered phrase and keeps the recognized text', () {
    final result = scorePronunciation(
      targetText: 'read one sentence',
      recognizedText: 'sentence one read',
    );

    expect(result.score, 33);
    expect(result.recognizedText, 'sentence one read');
    expect(result.matchedTokens, hasLength(1));
  });

  test('returns zero for an empty recognition result', () {
    final result = scorePronunciation(
      targetText: 'clear speech',
      recognizedText: '',
    );

    expect(result.score, 0);
    expect(result.missingTokens, ['clear', 'speech']);
    expect(result.extraTokens, isEmpty);
  });
}
