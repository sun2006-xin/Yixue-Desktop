import 'native_core_bridge.dart';
import 'openai_compatible_translation_client.dart';
import 'translation_format_protector.dart';
import 'translation_quality_guard.dart';

class ModelEvaluationCase {
  const ModelEvaluationCase({
    required this.id,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.source,
    this.references = const [],
    this.preserve = const [],
  });

  final String id;
  final String sourceLanguage;
  final String targetLanguage;
  final String source;
  final List<String> references;
  final List<String> preserve;
}

const fixedModelEvaluationCases = <ModelEvaluationCase>[
  ModelEvaluationCase(
    id: 'daily-en-zh',
    sourceLanguage: 'english',
    targetLanguage: 'chinese',
    source: 'Could you open the window? It is getting warm in here.',
    references: ['你能把窗户打开吗？这里开始变热了。'],
  ),
  ModelEvaluationCase(
    id: 'technical-en-zh',
    sourceLanguage: 'english',
    targetLanguage: 'chinese',
    source:
        'The cache is invalidated whenever the model configuration changes.',
    references: ['每当模型配置发生变化时，缓存都会失效。'],
  ),
  ModelEvaluationCase(
    id: 'format-en-zh',
    sourceLanguage: 'english',
    targetLanguage: 'chinese',
    source: 'Version 2.1 costs \$0 and uses 512 MB of memory.',
    preserve: ['2.1', r'$0', '512 MB'],
  ),
  ModelEvaluationCase(
    id: 'academic-zh-en',
    sourceLanguage: 'chinese',
    targetLanguage: 'english',
    source: '本研究评估了不同分段策略对长文翻译准确性和连贯性的影响。',
    references: [
      'This study evaluated how different segmentation strategies affect the accuracy and coherence of long-document translation.',
    ],
  ),
];

class ModelEvaluationItem {
  const ModelEvaluationItem({
    required this.id,
    required this.source,
    required this.translated,
    required this.elapsed,
    required this.outputValid,
    required this.formattingValid,
    required this.referenceMatch,
    this.references = const [],
    this.errorCode,
  });

  final String id;
  final String source;
  final String translated;
  final Duration elapsed;
  final bool outputValid;
  final bool formattingValid;
  final bool referenceMatch;
  final List<String> references;
  final String? errorCode;

  bool get passed => errorCode == null && outputValid && formattingValid;
}

class ModelEvaluationReport {
  const ModelEvaluationReport({required this.items, required this.elapsed});

  final List<ModelEvaluationItem> items;
  final Duration elapsed;

  int get total => items.length;
  int get passed => items.where((item) => item.passed).length;
}

class ModelEvaluationService {
  const ModelEvaluationService._();

  static List<ModelEvaluationCase> casesForDirection(
    String sourceLanguage,
    String targetLanguage, {
    List<ModelEvaluationCase> cases = fixedModelEvaluationCases,
  }) => cases
      .where(
        (item) =>
            item.sourceLanguage == sourceLanguage &&
            item.targetLanguage == targetLanguage,
      )
      .toList(growable: false);

  static Future<ModelEvaluationReport> evaluate({
    required LocalTranslationCore core,
    required String modelPath,
    required String workerPath,
    List<ModelEvaluationCase> cases = fixedModelEvaluationCases,
  }) async {
    await core.configureLocalTranslation(
      modelPath: modelPath,
      workerPath: workerPath,
    );
    final totalClock = Stopwatch()..start();
    final items = <ModelEvaluationItem>[];

    for (final evaluationCase in cases) {
      final protectedInput = TranslationFormatProtector.protect(
        evaluationCase.source,
      );
      final clock = Stopwatch()..start();
      final result = await core.translateLocal(
        id: 'model-eval-${evaluationCase.id}',
        sourceText: protectedInput.maskedText,
        sourceLanguage: evaluationCase.sourceLanguage,
        targetLanguage: evaluationCase.targetLanguage,
      );
      clock.stop();
      var translated = result.text.trim();
      var formattingValid = true;
      try {
        translated = protectedInput.restore(translated).trim();
      } on TranslationFormatException {
        formattingValid = false;
      }
      formattingValid =
          formattingValid && evaluationCase.preserve.every(translated.contains);
      items.add(
        ModelEvaluationItem(
          id: evaluationCase.id,
          source: evaluationCase.source,
          translated: translated,
          elapsed: clock.elapsed,
          outputValid: !TranslationQualityGuard.isSuspicious(
            evaluationCase.source,
            translated,
            targetLanguage: evaluationCase.targetLanguage,
          ),
          formattingValid: formattingValid,
          references: List.unmodifiable(evaluationCase.references),
          referenceMatch: evaluationCase.references.any(
            (reference) => _normalize(reference) == _normalize(translated),
          ),
        ),
      );
    }
    totalClock.stop();
    return ModelEvaluationReport(items: items, elapsed: totalClock.elapsed);
  }

  static Future<ModelEvaluationReport> evaluateRemote({
    required OpenAiCompatibleTranslationClient client,
    required ProviderProfileData profile,
    List<ModelEvaluationCase> cases = fixedModelEvaluationCases,
  }) async {
    final totalClock = Stopwatch()..start();
    final items = <ModelEvaluationItem>[];

    for (final evaluationCase in cases) {
      final protectedInput = TranslationFormatProtector.protect(
        evaluationCase.source,
      );
      final clock = Stopwatch()..start();
      var translated = '';
      var formattingValid = true;
      String? errorCode;
      try {
        final raw = await client.translate(
          profile: profile,
          sourceText: protectedInput.maskedText,
          sourceLanguage: evaluationCase.sourceLanguage,
          targetLanguage: evaluationCase.targetLanguage,
          preserveLineBreaks: true,
        );
        translated = raw.trim();
        try {
          translated = protectedInput.restore(translated).trim();
        } on TranslationFormatException {
          formattingValid = false;
          errorCode = 'format_integrity_failed';
        }
        formattingValid =
            formattingValid &&
            evaluationCase.preserve.every(translated.contains);
        if (!formattingValid && errorCode == null) {
          errorCode = 'format_integrity_failed';
        }
      } on TranslationClientException catch (error) {
        errorCode = error.code;
        translated = '未返回译文';
      } finally {
        clock.stop();
      }
      items.add(
        ModelEvaluationItem(
          id: evaluationCase.id,
          source: evaluationCase.source,
          translated: translated,
          elapsed: clock.elapsed,
          outputValid:
              errorCode == null &&
              !TranslationQualityGuard.isSuspicious(
                evaluationCase.source,
                translated,
                targetLanguage: evaluationCase.targetLanguage,
              ),
          formattingValid: formattingValid,
          references: List.unmodifiable(evaluationCase.references),
          referenceMatch: evaluationCase.references.any(
            (reference) => _normalize(reference) == _normalize(translated),
          ),
          errorCode: errorCode,
        ),
      );
    }
    totalClock.stop();
    return ModelEvaluationReport(items: items, elapsed: totalClock.elapsed);
  }

  static String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');
}
