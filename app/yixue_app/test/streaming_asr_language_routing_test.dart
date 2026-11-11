import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/streaming_asr_runtime.dart';
import 'package:yixue_app/features/simultaneous_interpretation/streaming_asr.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('asr-language-routing-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test(
    'Japanese uses the multilingual model pack and reports unavailable',
    () async {
      final runtime = SherpaStreamingAsrRuntime(
        modelDirectory: Directory('${sandbox.path}/bilingual'),
        multilingualModelDirectory: Directory('${sandbox.path}/multilingual'),
      );

      await expectLater(
        runtime.openSession(
          sessionId: 'session-1',
          sourceId: 'mic-1',
          sourceKind: SubtitleAudioSourceKind.microphone,
          sourceLanguageCode: 'ja-JP',
        ),
        throwsA(
          isA<StreamingAsrException>().having(
            (error) => error.code,
            'code',
            StreamingAsrErrorCode.modelUnavailable,
          ),
        ),
      );
    },
  );

  test(
    'Auto uses the multilingual model pack and reports unavailable',
    () async {
      final runtime = SherpaStreamingAsrRuntime(
        modelDirectory: Directory('${sandbox.path}/bilingual'),
        multilingualModelDirectory: Directory('${sandbox.path}/multilingual'),
      );

      await expectLater(
        runtime.openSession(
          sessionId: 'session-1',
          sourceId: 'mic-1',
          sourceKind: SubtitleAudioSourceKind.microphone,
          sourceLanguageCode: 'auto',
        ),
        throwsA(
          isA<StreamingAsrException>().having(
            (error) => error.code,
            'code',
            StreamingAsrErrorCode.modelUnavailable,
          ),
        ),
      );
    },
  );

  test(
    'additional Whisper languages use the multilingual model route',
    () async {
      final runtime = SherpaStreamingAsrRuntime(
        modelDirectory: Directory('${sandbox.path}/bilingual'),
        multilingualModelDirectory: Directory('${sandbox.path}/multilingual'),
      );

      for (final language in <String>['es', 'fr', 'de', 'pt', 'ru']) {
        await expectLater(
          runtime.openSession(
            sessionId: 'session-$language',
            sourceId: 'mic-1',
            sourceKind: SubtitleAudioSourceKind.microphone,
            sourceLanguageCode: language,
          ),
          throwsA(
            isA<StreamingAsrException>().having(
              (error) => error.code,
              'code',
              StreamingAsrErrorCode.modelUnavailable,
            ),
          ),
          reason: '$language should reach the Whisper model readiness check',
        );
      }
    },
  );
}
