import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';

void main() {
  group('subtitle language safety', () {
    test(
      'auto is a recognition mode and cannot be persisted as a cue language',
      () {
        expect(() => _revision(languageCode: 'auto'), throwsArgumentError);
      },
    );

    test(
      'unknown detected language keeps the source and skips translation',
      () {
        final segment = SubtitleSegment.fromTranscript(
          _revision(languageCode: 'und'),
        );

        expect(segment.transcript.text, 'unrecognized words');
        expect(segment.transcript.languageCode, 'und');
        expect(
          segment.translationStatus,
          SubtitleTranslationStatus.skippedUnsupportedLanguage,
        );
        expect(segment.canTranslate, isFalse);
      },
    );

    test('history restore keeps unknown language as original-only', () {
      final segment = SubtitleSegment.fromStoredFinalTranscript(
        _revision(languageCode: 'mul'),
      );

      expect(segment.transcript.text, 'unrecognized words');
      expect(
        segment.translationStatus,
        SubtitleTranslationStatus.skippedUnsupportedLanguage,
      );
    });
  });
}

TranscriptRevision _revision({required String languageCode}) =>
    TranscriptRevision(
      sessionId: 'session-1',
      captureAttemptId: 'attempt-1',
      segmentId: 'segment-1',
      sourceId: 'microphone-1',
      sourceKind: SubtitleAudioSourceKind.microphone,
      startMs: 100,
      endMs: 900,
      text: 'unrecognized words',
      languageCode: languageCode,
      revision: 1,
      isFinal: true,
    );
