import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/translation_history_export_service.dart';

void main() {
  test('encodes history and annotations without provider secrets', () {
    final payload = TranslationHistoryExportService.encode(
      history: const [
        TranslationHistoryEntryData(
          origin: 'screenshot_translation',
          id: 'translation-1',
          sourceText: 'Technology changes life.',
          translatedText: '技术改变生活。',
          providerId: 'remote.example',
          createdAt: '2026-09-14T10:00:00+08:00',
        ),
      ],
      annotations: const [
        TranslationAnnotationData(
          translationId: 'translation-1',
          note: '工作例句',
          favorite: true,
          addedToLearning: true,
          updatedAt: '2026-09-14T10:01:00+08:00',
        ),
      ],
    );

    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    expect(decoded['schemaVersion'], 1);
    expect(decoded['history'], isA<List<dynamic>>());
    expect(
      (decoded['history'] as List).single['origin'],
      'screenshot_translation',
    );
    expect(decoded['annotations'], isA<List<dynamic>>());
    expect(payload, isNot(contains('api_key')));
    expect(payload, isNot(contains('secret')));
  });
}
