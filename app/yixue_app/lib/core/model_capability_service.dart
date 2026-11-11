import 'model_evaluation_service.dart';
import 'model_package_discovery_service.dart';
import 'native_core_bridge.dart';
import 'openai_compatible_translation_client.dart';
import 'translation_quality_guard.dart';

enum ModelCompatibilityStatus {
  readyForValidation,
  requiresCompatibleEndpoint,
  requiresLocalRuntime,
  incomplete,
  pathUnavailable,
}

class ModelCompatibilityExplanation {
  const ModelCompatibilityExplanation({
    required this.status,
    required this.title,
    required this.detail,
    required this.nextStep,
  });

  final ModelCompatibilityStatus status;
  final String title;
  final String detail;
  final String nextStep;
}

enum CapabilityTrialStatus { passed, outputRejected, failed }

class ModelCapabilityTrialResult {
  const ModelCapabilityTrialResult({
    required this.status,
    required this.detail,
    required this.translated,
    required this.elapsed,
    this.errorCode,
  });

  final CapabilityTrialStatus status;
  final String detail;
  final String translated;
  final Duration elapsed;
  final String? errorCode;

  bool get passed => status == CapabilityTrialStatus.passed;
}

class ModelCapabilityService {
  const ModelCapabilityService._();

  static ModelCompatibilityExplanation explainCandidate(ModelCandidate model) {
    if (!model.pathAvailable) {
      return const ModelCompatibilityExplanation(
        status: ModelCompatibilityStatus.pathUnavailable,
        title: '路径已失效',
        detail: '记录仍在本地，但模型文件夹已经不存在；译学不会尝试执行失效路径。',
        nextStep: '请重新扫描实际模型位置，或移除这条发现记录。',
      );
    }
    if (model.readiness == ModelReadiness.incomplete) {
      return const ModelCompatibilityExplanation(
        status: ModelCompatibilityStatus.incomplete,
        title: '文件不完整',
        detail: '已找到模型痕迹，但缺少当前适配器需要的权重或配置文件。',
        nextStep: '补齐同一模型目录后重新扫描；不要手动把不完整目录设为当前模型。',
      );
    }
    switch (model.family) {
      case ModelFamily.yixueTranslation:
        return const ModelCompatibilityExplanation(
          status: ModelCompatibilityStatus.readyForValidation,
          title: '可校验的译学模型包',
          detail: '该目录符合译学模型包入口，校验通过后才会进入快速翻译路由。',
          nextStep: '点击“校验并启用”，完成来源、哈希、语言方向和运行时检查。',
        );
      case ModelFamily.qwen:
      case ModelFamily.ollama:
        return const ModelCompatibilityExplanation(
          status: ModelCompatibilityStatus.requiresCompatibleEndpoint,
          title: '需要已有兼容接口',
          detail: '当前版本不会直接执行千问权重或 Ollama 权重；安装包也不会自动安装或启动 Ollama。请通过已有 Ollama 或其他 OpenAI 兼容本地接口接入，再进行能力试跑。',
          nextStep: '确认本机接口已运行后，点击“配置兼容接口”，保存模型 ID，再试跑。',
        );
      case ModelFamily.gguf:
      case ModelFamily.transformers:
      case ModelFamily.onnx:
        return const ModelCompatibilityExplanation(
          status: ModelCompatibilityStatus.requiresLocalRuntime,
          title: '等待安全运行内核',
          detail: '已识别模型文件，但译学当前没有可安全接管该格式的内置运行内核；扫描不会执行未知模型代码。',
          nextStep: '等待对应适配器，或使用模型原有兼容接口接入后再试跑。',
        );
    }
  }

  static ModelCapabilityTrialResult fromEvaluation(ModelEvaluationItem item) {
    if (item.errorCode != null) {
      return ModelCapabilityTrialResult(
        status: CapabilityTrialStatus.failed,
        detail: _errorDetail(item.errorCode!),
        translated: item.translated,
        elapsed: item.elapsed,
        errorCode: item.errorCode,
      );
    }
    if (!item.outputValid || !item.formattingValid) {
      return ModelCapabilityTrialResult(
        status: CapabilityTrialStatus.outputRejected,
        detail: '译文未通过输出门禁，当前模型不能据此接管后续任务。',
        translated: item.translated,
        elapsed: item.elapsed,
      );
    }
    return ModelCapabilityTrialResult(
      status: CapabilityTrialStatus.passed,
      detail: '最小翻译试跑通过，可以用于后续任务；完整质量仍需固定集和人工评测。',
      translated: item.translated,
      elapsed: item.elapsed,
    );
  }

  static ModelCapabilityTrialResult fromOutput({
    required String source,
    required String targetLanguage,
    required String translated,
    required Duration elapsed,
  }) {
    final output = translated.trim();
    if (output.isEmpty ||
        TranslationQualityGuard.isSuspicious(
          source,
          output,
          targetLanguage: targetLanguage,
        )) {
      return ModelCapabilityTrialResult(
        status: CapabilityTrialStatus.outputRejected,
        detail: '译文未通过输出门禁，当前模型不能据此接管后续任务。',
        translated: output,
        elapsed: elapsed,
      );
    }
    return ModelCapabilityTrialResult(
      status: CapabilityTrialStatus.passed,
      detail: '最小翻译试跑通过，可以用于后续任务；完整质量仍需固定集和人工评测。',
      translated: output,
      elapsed: elapsed,
    );
  }

  static ModelCapabilityTrialResult fromError(Object error) {
    final code = switch (error) {
      TranslationClientException(:final code) => code,
      CoreBridgeException(:final code) => code,
      _ => 'trial_failed',
    };
    return ModelCapabilityTrialResult(
      status: CapabilityTrialStatus.failed,
      detail: _errorDetail(code),
      translated: '未返回译文',
      elapsed: Duration.zero,
      errorCode: code,
    );
  }

  static String _errorDetail(String code) => switch (code) {
    'missing_credential' => '缺少 API 密钥；密钥不会显示在试跑结果中。',
    'provider_invalid' => '模型配置不完整，请检查模型 ID 和接口地址。',
    'provider_unavailable' => '当前模型未启用，不能进行能力试跑。',
    'request_timeout' => '接口响应超时，请检查本地服务是否启动或降低任务规模。',
    'network_error' => '无法连接到模型接口，请检查服务状态和网络边界。',
    'invalid_response' => '模型返回格式无法识别；该接口暂不兼容译学翻译协议。',
    'cancelled' => '试跑已取消，没有保存或重发请求。',
    'remote_service_error' => '模型服务返回临时或服务端错误，请检查服务日志和模型 ID。',
    'model_package_invalid' => '本地模型包校验失败，不能执行未校验模型。',
    _ => '能力试跑失败，请检查模型配置、运行内核和模型文件完整性。',
  };
}
