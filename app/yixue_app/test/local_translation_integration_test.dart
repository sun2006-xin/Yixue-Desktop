import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/provider_secret_store.dart';
import 'package:yixue_app/core/quick_translation_service.dart';

final class _UnusedSecrets implements SecretBackend {
  @override
  Future<bool> containsKey(String key) async => false;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}
}

void main() {
  final libraryPath = Platform.environment['YIXUE_TEST_FFI_DLL'];
  final workerPath = Platform.environment['YIXUE_TEST_CT2_WORKER'];
  final modelPath = Platform.environment['YIXUE_TEST_MODEL'];
  final zhEnModelPath = Platform.environment['YIXUE_TEST_ZH_EN_MODEL'];
  final enabled =
      libraryPath != null && workerPath != null && modelPath != null;
  final zhEnEnabled =
      libraryPath != null && workerPath != null && zhEnModelPath != null;

  test(
    'translates through Dart isolate, Rust bridge, and local worker',
    () async {
      final testDirectory = await Directory.systemTemp.createTemp(
        'yixue-local-translation-',
      );
      final bridge = NativeCoreBridge.open(
        path: libraryPath,
        databasePath: '${testDirectory.path}\\yixue.db',
      );
      try {
        await bridge.configureLocalTranslation(
          modelPath: modelPath!,
          workerPath: workerPath!,
        );
        final result = await bridge.translateLocal(
          id: 'flutter-local-integration',
          sourceText: 'Technology changes life.',
          sourceLanguage: 'english',
          targetLanguage: 'chinese',
        );

        expect(result.text, isNotEmpty);
        expect(result.text, isNot('Technology changes life.'));
        expect(result.providerId, 'yixue.opus-en-zh.int8');
      } finally {
        bridge.dispose();
        await testDirectory.delete(recursive: true);
      }
    },
    skip: enabled ? false : 'real local runtime paths were not provided',
  );

  test(
    'translates Chinese to English through the complete local stack',
    () async {
      final testDirectory = await Directory.systemTemp.createTemp(
        'yixue-local-zh-en-',
      );
      final bridge = NativeCoreBridge.open(
        path: libraryPath,
        databasePath: '${testDirectory.path}\\yixue.db',
      );
      try {
        await bridge.configureLocalTranslation(
          modelPath: zhEnModelPath!,
          workerPath: workerPath!,
        );
        final result = await bridge.translateLocal(
          id: 'flutter-local-zh-en',
          sourceText: '\u5b66\u4e60\u6253\u5f00\u901a\u5f80\u66f4\u5927\u4e16\u754c\u7684\u5927\u95e8\u3002',
          sourceLanguage: 'chinese',
          targetLanguage: 'english',
        );

        expect(result.text, contains('Learning'));
        expect(result.providerId, 'yixue.opus-zh-en.int8');

        final teacher = await bridge.translateLocal(
          id: 'flutter-local-zh-en-teacher',
          sourceText: '\u8001\u5e08',
          sourceLanguage: 'chinese',
          targetLanguage: 'english',
        );
        expect(teacher.text, contains(RegExp('[A-Za-z]')));
        expect(teacher.text, isNot(contains('~')));
      } finally {
        bridge.dispose();
        await testDirectory.delete(recursive: true);
      }
    },
    skip: zhEnEnabled
        ? false
        : 'Chinese to English model path was not provided',
  );

  test(
    'preserves all fixed formatting cases through the complete local stack',
    () async {
      final testDirectory = await Directory.systemTemp.createTemp(
        'yixue-local-formatting-',
      );
      final suiteFile = File(
        '${Directory.current.parent.parent.path}'
        '\\benchmarks\\translation\\en-zh-evaluation-v2.json',
      );
      final suite =
          jsonDecode(await suiteFile.readAsString()) as Map<String, dynamic>;
      final cases = (suite['cases'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((item) => item['category'] == 'formatting');
      var requestNumber = 0;
      final service = QuickTranslationService(
        coreFactory: () => NativeCoreBridge.open(
          path: libraryPath,
          databasePath: '${testDirectory.path}\\yixue.db',
        ),
        secrets: ProviderSecretStore(_UnusedSecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: workerPath,
        localModelPath: modelPath,
        localChineseToEnglishModelPath: zhEnModelPath,
        idFactory: () => 'flutter-local-formatting-${requestNumber += 1}',
      );
      try {
        var completed = 0;
        for (final item in cases) {
          final direction = item['source_language'] == 'english'
              ? TranslationDirection.englishToChinese
              : TranslationDirection.chineseToEnglish;
          final translated = await service.translate(
            item['source'] as String,
            direction: direction,
          );
          for (final token
              in (item['preserve'] as List<dynamic>).cast<String>()) {
            expect(
              translated,
              contains(token),
              reason: '${item['id']} lost $token',
            );
          }
          completed += 1;
        }
        expect(completed, 16);
      } finally {
        service.dispose();
        await testDirectory.delete(recursive: true);
      }
    },
    skip: enabled && zhEnEnabled
        ? false
        : 'both real local model paths were not provided',
  );

  test(
    'dispose waits for an in-flight local translation before freeing engine',
    () async {
      final testDirectory = await Directory.systemTemp.createTemp(
        'yixue-local-dispose-',
      );
      final bridge = NativeCoreBridge.open(
        path: libraryPath,
        databasePath: '${testDirectory.path}\\yixue.db',
      );
      try {
        await bridge.configureLocalTranslation(
          modelPath: modelPath!,
          workerPath: workerPath!,
        );

        final translation = bridge.translateLocal(
          id: 'flutter-local-dispose',
          sourceText: 'Learning opens the door to a wider world.',
          sourceLanguage: 'english',
          targetLanguage: 'chinese',
        );
        bridge.dispose();

        final result = await translation;
        expect(result.text, isNotEmpty);
        expect(
          bridge.listProviderProfiles,
          throwsA(
            isA<CoreBridgeException>().having(
              (error) => error.code,
              'code',
              'bridge_disposed',
            ),
          ),
        );
      } finally {
        bridge.dispose();
        await testDirectory.delete(recursive: true);
      }
    },
    skip: enabled ? false : 'real local runtime paths were not provided',
  );

  test(
    'cancels an in-flight local translation through the native bridge',
    () async {
      final testDirectory = await Directory.systemTemp.createTemp(
        'yixue-local-cancel-',
      );
      final bridge = NativeCoreBridge.open(
        path: libraryPath,
        databasePath: '${testDirectory.path}\\yixue.db',
      );
      try {
        await bridge.configureLocalTranslation(
          modelPath: modelPath!,
          workerPath: workerPath!,
        );
        final translation = bridge.translateLocal(
          id: 'flutter-local-cancel',
          sourceText: List.filled(
            80,
            'Learning opens the door to a wider world.',
          ).join(' '),
          sourceLanguage: 'english',
          targetLanguage: 'chinese',
        );
        final cancelledResult = expectLater(
          translation,
          throwsA(
            isA<CoreBridgeException>().having(
              (error) => error.code,
              'code',
              'cancelled',
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          await bridge.cancelLocalTranslation('flutter-local-cancel'),
          isTrue,
        );
        await cancelledResult;
      } finally {
        bridge.dispose();
        await testDirectory.delete(recursive: true);
      }
    },
    skip: enabled ? false : 'real local runtime paths were not provided',
  );
}
