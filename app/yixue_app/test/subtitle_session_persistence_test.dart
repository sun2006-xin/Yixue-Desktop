import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_coordinator.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_persistence.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_translation_queue.dart';

void main() {
  for (final mode in SubtitleRecognitionMode.values) {
    test('persists a new ${mode.name} recognition session', () async {
      final rootDirectory = await Directory.systemTemp.createTemp(
        'yixue-subtitle-session-persistence-',
      );
      addTearDown(() async {
        if (await rootDirectory.exists()) {
          await rootDirectory.delete(recursive: true);
        }
      });

      final store = FileSubtitleSessionStore(rootDirectory);
      final queue = SubtitleTranslationQueue(
        executor: const _UnusedTranslationExecutor(),
        targetLanguageCode: 'zh',
      );
      final coordinator = SubtitleSessionCoordinator(
        sessionId: 'persistence-${mode.name}',
        initialCaptureAttemptId: 'attempt-${mode.name}',
        translationQueue: queue,
        translationEnabled: false,
      );
      final persistence = await SubtitleSessionPersistence.attach(
        store: store,
        coordinator: coordinator,
        kind: SubtitleSessionKind.meeting,
        sourceKind: SubtitleAudioSourceKind.systemOutput,
        recognitionMode: mode,
        targetLanguageCode: 'zh',
        startedAtUtc: DateTime.utc(2026, 10, 11, 12),
      );

      expect(persistence.isPersisted, isTrue);
      final session = await store.readSession('persistence-${mode.name}');
      expect(session?.recognitionMode, mode);

      await persistence.close();
      await coordinator.stop();
    });
  }
}

final class _UnusedTranslationExecutor implements SubtitleTranslationExecutor {
  const _UnusedTranslationExecutor();

  @override
  Future<String> translate(SubtitleTranslationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<void> cancel(String requestId) async {}
}
