import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:yixue_app/core/model_evaluation_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/openai_compatible_translation_client.dart';
import 'package:yixue_app/core/provider_secret_store.dart';
import 'package:yixue_app/core/translation_format_protector.dart';

void main() {
  final libraryPath = Platform.environment['YIXUE_TEST_FFI_DLL'];
  final workerPath = Platform.environment['YIXUE_TEST_CT2_WORKER'];
  final modelPath = Platform.environment['YIXUE_TEST_MODEL'];
  final zhEnModelPath = Platform.environment['YIXUE_TEST_ZH_EN_MODEL'];

  test(
    'evaluates every fixed case and records latency without history writes',
    () async {
      final core = _FakeLocalCore((request) {
        return request.targetLanguage == 'english'
            ? 'A translated result.'
            : '结果 ${request.sourceText}';
      });

      final report = await ModelEvaluationService.evaluate(
        core: core,
        modelPath: r'D:\models\opus',
        workerPath: r'D:\runtime\worker.exe',
      );

      expect(report.items, hasLength(fixedModelEvaluationCases.length));
      expect(report.total, fixedModelEvaluationCases.length);
      expect(report.passed, report.total);
      expect(report.elapsed.inMicroseconds, greaterThanOrEqualTo(0));
      expect(core.configurationCount, 1);
      expect(core.requests, hasLength(fixedModelEvaluationCases.length));
    },
  );

  test('selects only cases supported by a directional translation model', () {
    final cases = ModelEvaluationService.casesForDirection(
      'english',
      'chinese',
    );

    expect(cases, isNotEmpty);
    expect(
      cases.every(
        (item) =>
            item.sourceLanguage == 'english' &&
            item.targetLanguage == 'chinese',
      ),
      isTrue,
    );
  });

  test('selects a Chinese sample for the reverse translation direction', () {
    final cases = ModelEvaluationService.casesForDirection(
      'chinese',
      'english',
    );

    expect(cases, isNotEmpty);
    expect(
      cases.every(
        (item) =>
            item.sourceLanguage == 'chinese' &&
            item.targetLanguage == 'english',
      ),
      isTrue,
    );
    expect(cases.first.source, contains('研究'));
  });

  test('keeps reference translations with evaluation results for comparison', () async {
    final core = _FakeLocalCore((request) => '模型输出');
    final evaluationCase = fixedModelEvaluationCases.first;

    final report = await ModelEvaluationService.evaluate(
      core: core,
      modelPath: 'model',
      workerPath: 'worker',
      cases: [evaluationCase],
    );

    expect(report.items.single.references, evaluationCase.references);
    expect(report.items.single.referenceMatch, isFalse);
  });

  test(
    'protects and restores formatting tokens during model evaluation',
    () async {
      final core = _FakeLocalCore((request) {
        expect(
          request.sourceText,
          contains(TranslationFormatProtector.sentinel),
        );
        return '版本 YXFMT 花费 YXFMT，使用 YXFMT。';
      });
      const evaluationCase = ModelEvaluationCase(
        id: 'format-only',
        sourceLanguage: 'english',
        targetLanguage: 'chinese',
        source: 'Version 2.1 costs \$0 and uses 512 MB.',
        preserve: ['2.1', r'$0', '512 MB'],
      );

      final report = await ModelEvaluationService.evaluate(
        core: core,
        modelPath: 'model',
        workerPath: 'worker',
        cases: const [evaluationCase],
      );

      expect(report.items.single.translated, contains('2.1'));
      expect(report.items.single.translated, contains(r'$0'));
      expect(report.items.single.translated, contains('512 MB'));
      expect(report.items.single.formattingValid, isTrue);
    },
  );

  test('marks suspicious output and lost preserve tokens as failed', () async {
    final core = _FakeLocalCore((request) {
      if (request.id.endsWith('format-en-zh')) return 'analysis: bad output';
      return 'valid output without required token';
    });

    final report = await ModelEvaluationService.evaluate(
      core: core,
      modelPath: 'model',
      workerPath: 'worker',
    );

    final format = report.items.singleWhere(
      (item) => item.id == 'format-en-zh',
    );
    expect(format.outputValid, isFalse);
    expect(format.passed, isFalse);
    expect(report.passed, lessThan(report.total));
  });

  test('rejects an unchanged English output in local Chinese evaluation', () async {
    const source = 'Technology changes life.';
    final core = _FakeLocalCore((request) => source);
    const evaluationCase = ModelEvaluationCase(
      id: 'unchanged-en-zh',
      sourceLanguage: 'english',
      targetLanguage: 'chinese',
      source: source,
    );

    final report = await ModelEvaluationService.evaluate(
      core: core,
      modelPath: 'model',
      workerPath: 'worker',
      cases: const [evaluationCase],
    );

    expect(report.items.single.outputValid, isFalse);
    expect(report.items.single.passed, isFalse);
  });

  test(
    'evaluates a local Ollama provider with the same protected cases',
    () async {
      final requests = <http.Request>[];
      const profile = ProviderProfileData(
        id: 'local.ollama',
        displayName: '本地 Ollama',
        kind: ProviderProfileKind.remoteApi,
        enabled: true,
        modelId: 'qwen3.5:4b',
        endpoint: 'http://127.0.0.1:11435/api',
      );
      final client = OpenAiCompatibleTranslationClient(
        httpClient: MockClient((request) async {
          requests.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final source =
              ((body['messages'] as List<dynamic>).last
                  as Map<String, dynamic>)['content'];
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object>{
                'message': <String, String>{
                  'content':
                      source.toString().contains(
                        TranslationFormatProtector.sentinel,
                      )
                      ? '版本 YXFMT 花费 YXFMT，使用 YXFMT。'
                      : '你能把窗户打开吗？这里开始变热了。',
                },
              }),
            ),
            200,
          );
        }),
        secrets: ProviderSecretStore(_EmptySecrets()),
      );

      final report = await ModelEvaluationService.evaluateRemote(
        client: client,
        profile: profile,
        cases: [fixedModelEvaluationCases[0], fixedModelEvaluationCases[2]],
      );

      expect(report.items, hasLength(2));
      expect(report.items.first.passed, isTrue);
      expect(report.items.last.formattingValid, isTrue);
      expect(report.items.last.translated, contains(r'$0'));
      expect(report.elapsed.inMicroseconds, greaterThanOrEqualTo(0));
      expect(requests, hasLength(2));
      expect(
        requests.every((request) => request.url.path == '/api/chat'),
        isTrue,
      );
    },
  );

  test(
    'runs the fixed evaluation set through the bundled local model',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-model-evaluation-',
      );
      final bridge = NativeCoreBridge.open(
        path: libraryPath,
        databasePath: '${directory.path}\\yixue.db',
      );
      try {
        final report = await ModelEvaluationService.evaluate(
          core: bridge,
          modelPath: modelPath!,
          workerPath: workerPath!,
          cases: ModelEvaluationService.casesForDirection('english', 'chinese'),
        );
        for (final item in report.items) {
          // Keep the real result visible in CI/local test output for human review.
          // This test intentionally does not turn model quality into a pass score.
          // ignore: avoid_print
          print(
            '[model-eval] ${item.id} ${item.elapsed.inMilliseconds}ms '
            'outputValid=${item.outputValid} formattingValid=${item.formattingValid} '
            '${item.translated}',
          );
        }
        expect(
          report.items,
          hasLength(
            ModelEvaluationService.casesForDirection(
              'english',
              'chinese',
            ).length,
          ),
        );
      } finally {
        bridge.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: libraryPath != null && workerPath != null && modelPath != null
        ? false
        : 'real local evaluation paths were not provided',
  );

  test(
    'runs the reverse fixed evaluation set through the bundled local model',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-model-evaluation-zh-en-',
      );
      final bridge = NativeCoreBridge.open(
        path: libraryPath,
        databasePath: '${directory.path}\\yixue.db',
      );
      try {
        final cases = ModelEvaluationService.casesForDirection(
          'chinese',
          'english',
        );
        final report = await ModelEvaluationService.evaluate(
          core: bridge,
          modelPath: zhEnModelPath!,
          workerPath: workerPath!,
          cases: cases,
        );
        for (final item in report.items) {
          // ignore: avoid_print
          print(
            '[model-eval] ${item.id} ${item.elapsed.inMilliseconds}ms '
            'outputValid=${item.outputValid} formattingValid=${item.formattingValid} '
            '${item.translated}',
          );
        }
        expect(report.items, hasLength(cases.length));
      } finally {
        bridge.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: libraryPath != null && workerPath != null && zhEnModelPath != null
        ? false
        : 'reverse local evaluation paths were not provided',
  );
}

class _EmptySecrets implements SecretBackend {
  @override
  Future<bool> containsKey(String key) async => false;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}
}

class _FakeLocalCore implements LocalTranslationCore {
  _FakeLocalCore(this.handler);

  final String Function(_EvaluationRequest request) handler;
  int configurationCount = 0;
  final List<_EvaluationRequest> requests = [];

  @override
  Future<bool> cancelLocalTranslation(String id) async => true;

  @override
  Future<void> configureLocalTranslation({
    required String modelPath,
    required String workerPath,
  }) async {
    configurationCount++;
  }

  @override
  Future<LocalTranslationResultData> translateLocal({
    required String id,
    required String sourceText,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    final request = _EvaluationRequest(
      id: id,
      sourceText: sourceText,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
    );
    requests.add(request);
    return LocalTranslationResultData(
      requestId: id,
      providerId: 'fake',
      text: handler(request),
    );
  }
}

class _EvaluationRequest {
  const _EvaluationRequest({
    required this.id,
    required this.sourceText,
    required this.sourceLanguage,
    required this.targetLanguage,
  });

  final String id;
  final String sourceText;
  final String sourceLanguage;
  final String targetLanguage;
}
