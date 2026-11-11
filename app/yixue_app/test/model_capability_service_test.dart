import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/model_capability_service.dart';
import 'package:yixue_app/core/model_evaluation_service.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/openai_compatible_translation_client.dart';

void main() {
  test('explains each discovered model family without executing it', () {
    const candidates = <ModelCandidate>[
      ModelCandidate(
        path: r'D:\models\yixue',
        displayName: '译学英中包',
        family: ModelFamily.yixueTranslation,
        readiness: ModelReadiness.readyToValidate,
        capabilities: {ModelCapability.translation},
      ),
      ModelCandidate(
        path: r'D:\models\qwen',
        displayName: 'Qwen3',
        family: ModelFamily.qwen,
        readiness: ModelReadiness.runtimeRequired,
        capabilities: {ModelCapability.generalText},
      ),
      ModelCandidate(
        path: r'D:\models\model.gguf',
        displayName: '通用 GGUF',
        family: ModelFamily.gguf,
        readiness: ModelReadiness.runtimeRequired,
        capabilities: {ModelCapability.generalText},
      ),
      ModelCandidate(
        path: r'D:\models\broken',
        displayName: '不完整模型',
        family: ModelFamily.transformers,
        readiness: ModelReadiness.incomplete,
        capabilities: {ModelCapability.generalText},
        pathAvailable: false,
      ),
    ];

    final explanations = candidates
        .map(ModelCapabilityService.explainCandidate)
        .toList(growable: false);

    expect(explanations[0].status, ModelCompatibilityStatus.readyForValidation);
    expect(explanations[0].nextStep, contains('校验'));
    expect(
      explanations[1].status,
      ModelCompatibilityStatus.requiresCompatibleEndpoint,
    );
    expect(explanations[1].detail, contains('Ollama'));
    expect(
      explanations[2].status,
      ModelCompatibilityStatus.requiresLocalRuntime,
    );
    expect(explanations[2].detail, contains('运行内核'));
    expect(explanations[3].status, ModelCompatibilityStatus.pathUnavailable);
    expect(explanations[3].nextStep, contains('重新扫描'));
  });

  test('turns a passing evaluation into a successful capability trial', () {
    const item = ModelEvaluationItem(
      id: 'trial',
      source: 'Hello.',
      translated: '你好。',
      elapsed: Duration(milliseconds: 42),
      outputValid: true,
      formattingValid: true,
      referenceMatch: false,
    );

    final result = ModelCapabilityService.fromEvaluation(item);

    expect(result.status, CapabilityTrialStatus.passed);
    expect(result.translated, '你好。');
    expect(result.elapsed, const Duration(milliseconds: 42));
    expect(result.detail, contains('可以用于后续任务'));
  });

  test('does not pass a trial when output quality gates reject it', () {
    const item = ModelEvaluationItem(
      id: 'trial',
      source: 'Hello.',
      translated: 'Hello.',
      elapsed: Duration.zero,
      outputValid: false,
      formattingValid: true,
      referenceMatch: false,
    );

    final result = ModelCapabilityService.fromEvaluation(item);

    expect(result.status, CapabilityTrialStatus.outputRejected);
    expect(result.passed, isFalse);
    expect(result.detail, contains('未通过输出门禁'));
  });

  test('applies the same output gate to a local trial result', () {
    final result = ModelCapabilityService.fromOutput(
      source: 'Hello.',
      targetLanguage: 'chinese',
      translated: '哈哈哈哈哈哈哈哈哈哈',
      elapsed: const Duration(milliseconds: 7),
    );

    expect(result.status, CapabilityTrialStatus.outputRejected);
    expect(result.elapsed, const Duration(milliseconds: 7));
  });

  test('keeps stable remote error codes visible to the user', () {
    final result = ModelCapabilityService.fromError(
      const TranslationClientException('missing_credential'),
    );

    expect(result.status, CapabilityTrialStatus.failed);
    expect(result.errorCode, 'missing_credential');
    expect(result.detail, contains('密钥'));
    expect(result.detail, isNot(contains('Bearer')));
  });
}
