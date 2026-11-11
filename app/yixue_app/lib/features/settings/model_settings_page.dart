import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/model_capability_service.dart';
import 'package:yixue_app/core/model_evaluation_service.dart';
import 'package:yixue_app/core/learning_summary_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/openai_compatible_translation_client.dart';
import 'package:yixue_app/core/provider_configuration_service.dart';
import 'package:yixue_app/core/provider_secret_store.dart';
import 'package:yixue_app/core/remote_provider_presets.dart';
import 'package:yixue_app/core/supported_language_code.dart';
import 'package:yixue_app/core/quick_translation_service.dart'
    show TranslationDirection;

class ModelSettingsPage extends StatefulWidget {
  const ModelSettingsPage({
    super.key,
    this.coreFactory,
    this.secretStore,
    this.modelValidator,
    this.directoryPicker,
    this.modelDiscovery,
    this.driveRootsProvider,
    this.modelCatalogDiscovery,
    this.modelFolderInspector,
    this.connectivityTester,
    this.capabilityTrialer,
    this.localWorkerPath,
    this.bundledModelRootPath,
    this.onConfigurationChanged,
    this.onOpenSimultaneousInterpretation,
    this.focusUnderstandingUsageRequestId = 0,
  });

  final AppCore Function()? coreFactory;
  final ProviderSecretStore? secretStore;
  final FutureOr<ModelPackageValidationData> Function(String modelPath)?
  modelValidator;
  final Future<String?> Function()? directoryPicker;
  final Future<List<String>> Function(String rootPath)? modelDiscovery;
  final Future<List<String>> Function()? driveRootsProvider;
  final Future<List<ModelCandidate>> Function(List<String> roots)?
  modelCatalogDiscovery;
  final Future<ModelCandidate?> Function(String modelPath)?
  modelFolderInspector;
  final Future<void> Function(ProviderProfileData profile)? connectivityTester;
  final Future<ModelCapabilityTrialResult> Function(
    ProviderProfileData profile,
  )?
  capabilityTrialer;
  final String? localWorkerPath;
  final String? bundledModelRootPath;
  final VoidCallback? onConfigurationChanged;
  final VoidCallback? onOpenSimultaneousInterpretation;
  final int focusUnderstandingUsageRequestId;

  @override
  State<ModelSettingsPage> createState() => _ModelSettingsPageState();
}

class _ModelSettingsPageState extends State<ModelSettingsPage> {
  final _settingsScrollController = ScrollController();
  final _understandingUsageFocusAnchorKey = GlobalKey();
  final _understandingApiFallbackAnchorKey = GlobalKey();
  late final AppCore _core;
  late final ProviderConfigurationService _configuration;
  late final Future<CoreHealth> _health;
  var _profiles = const <ProviderProfileData>[];
  String? _loadError;
  var _isLocalBusy = false;
  String? _localProgress;
  var _discoveredModels = const <ModelCandidate>[];
  String? _testingProviderId;
  String? _trialingProviderId;
  String? _evaluatingProviderId;

  String get _workerPath =>
      widget.localWorkerPath ??
      '${File(Platform.resolvedExecutable).parent.path}\\runtime\\yixue_ct2_worker.exe';

  String get _bundledModelRootPath =>
      widget.bundledModelRootPath ??
      '${File(Platform.resolvedExecutable).parent.path}\\models';

  List<ModelCandidate> _bundledModelCandidates() {
    if (widget.bundledModelRootPath == null ||
        widget.bundledModelRootPath!.trim().isEmpty) {
      return const [];
    }
    final models = [
      (
        id: 'bundled.yixue.opus-en-zh.int8',
        directory: 'yixue.opus-en-zh.int8',
        displayName: '译学英中轻量模型',
        sourceLanguage: 'english',
        targetLanguage: 'chinese',
      ),
      (
        id: 'bundled.yixue.opus-zh-en.int8',
        directory: 'yixue.opus-zh-en.int8',
        displayName: '译学中英轻量模型',
        sourceLanguage: 'chinese',
        targetLanguage: 'english',
      ),
    ];
    return models
        .map((model) {
          final path = '$_bundledModelRootPath\\${model.directory}';
          return ModelCandidate(
            catalogId: model.id,
            path: path,
            displayName: model.displayName,
            family: ModelFamily.yixueTranslation,
            readiness: ModelReadiness.readyToValidate,
            capabilities: const {ModelCapability.translation},
            assignedRoles: const {ModelRole.translation},
            pathAvailable:
                Directory(path).existsSync() &&
                File('$path\\${ModelPackageDiscoveryService.manifestName}')
                    .existsSync(),
            sourceLanguage: model.sourceLanguage,
            targetLanguage: model.targetLanguage,
          );
        })
        .toList(growable: false);
  }

  Future<ModelPackageValidationData> _validatedPackage(String modelPath) =>
      widget.modelValidator != null
      ? Future<ModelPackageValidationData>.sync(
          () => widget.modelValidator!(modelPath),
        )
      : Isolate.run(() => _validateModelPackage(modelPath));

  Future<({ModelEvaluationCase sample, ModelCapabilityTrialResult result})?>
  _runLocalCapabilityTrial(ProviderProfileData profile) async {
    if (profile.kind != ProviderProfileKind.localModel ||
        profile.modelPath == null) {
      return null;
    }
    final core = _core;
    if (core is! LocalTranslationCore) {
      _showMessage('当前运行核心不支持本地试译');
      return null;
    }
    final workerPath = _workerPath;
    if (!File(workerPath).existsSync()) {
      _showMessage('未找到随包本地翻译运行时，请重新安装完整预览版');
      return null;
    }
    _showMessage('正在用“${profile.displayName}”试译固定短句…');
    final package = await _validatedPackage(profile.modelPath!);
    final cases = ModelEvaluationService.casesForDirection(
      package.sourceLanguage,
      package.targetLanguage,
    );
    if (cases.isEmpty) {
      _showMessage('当前模型没有匹配的固定试译样例');
      return null;
    }
    final sample = cases.first;
    final localCore = core as LocalTranslationCore;
    await localCore.configureLocalTranslation(
      modelPath: profile.modelPath!,
      workerPath: workerPath,
    );
    final clock = Stopwatch()..start();
    final result = await localCore.translateLocal(
      id: 'model-trial-${DateTime.now().microsecondsSinceEpoch}',
      sourceText: sample.source,
      sourceLanguage: sample.sourceLanguage,
      targetLanguage: sample.targetLanguage,
    );
    clock.stop();
    return (
      sample: sample,
      result: ModelCapabilityService.fromOutput(
        source: sample.source,
        targetLanguage: sample.targetLanguage,
        translated: result.text,
        elapsed: clock.elapsed,
      ),
    );
  }

  Future<({ModelEvaluationCase sample, ModelCapabilityTrialResult result})>
  _runRemoteCapabilityTrial(ProviderProfileData profile) async {
    final sample = fixedModelEvaluationCases.first;
    final client = OpenAiCompatibleTranslationClient(
      httpClient: http.Client(),
      secrets: widget.secretStore ?? ProviderSecretStore.platform(),
      timeout: const Duration(seconds: 45),
    );
    try {
      _showMessage('正在用“${profile.displayName}”试跑最小翻译样例…');
      final report = await ModelEvaluationService.evaluateRemote(
        client: client,
        profile: profile,
        cases: [sample],
      );
      return (
        sample: sample,
        result: ModelCapabilityService.fromEvaluation(report.items.single),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _trialProvider(ProviderProfileData profile) async {
    if (_trialingProviderId != null) return;
    setState(() => _trialingProviderId = profile.id);
    final sample = fixedModelEvaluationCases.first;
    ({ModelEvaluationCase sample, ModelCapabilityTrialResult result})? trial;
    try {
      if (widget.capabilityTrialer != null) {
        trial = (
          sample: sample,
          result: await widget.capabilityTrialer!(profile),
        );
      } else if (profile.kind == ProviderProfileKind.localModel) {
        trial = await _runLocalCapabilityTrial(profile);
      } else {
        trial = await _runRemoteCapabilityTrial(profile);
      }
    } catch (error) {
      trial = (sample: sample, result: ModelCapabilityService.fromError(error));
    } finally {
      if (mounted) setState(() => _trialingProviderId = null);
    }
    if (trial != null) {
      await _showCapabilityTrialResult(profile, trial.sample, trial.result);
    }
  }

  Future<void> _showCapabilityTrialResult(
    ProviderProfileData profile,
    ModelEvaluationCase sample,
    ModelCapabilityTrialResult result,
  ) async {
    if (!mounted) return;
    final status = switch (result.status) {
      CapabilityTrialStatus.passed => '能力试跑通过',
      CapabilityTrialStatus.outputRejected => '输出未通过门禁',
      CapabilityTrialStatus.failed => '能力试跑失败',
    };
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${profile.displayName} · $status'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.detail),
                const SizedBox(height: 14),
                const Text(
                  '试跑原文',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                SelectableText(sample.source),
                const SizedBox(height: 12),
                const Text(
                  '模型译文',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                SelectableText(result.translated),
                const SizedBox(height: 12),
                Text('耗时：${result.elapsed.inMilliseconds} ms'),
                if (result.errorCode != null) ...[
                  const SizedBox(height: 4),
                  Text('错误类型：${result.errorCode}'),
                ],
                const SizedBox(height: 12),
                const Text(
                  '这只是最小能力检查，不代表完整翻译质量；不会写入历史，也不会改变当前模型选择。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: Navigator.of(context).pop,
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _evaluateLocalProvider(ProviderProfileData profile) async {
    if (profile.kind != ProviderProfileKind.localModel ||
        profile.modelPath == null ||
        _evaluatingProviderId != null) {
      return;
    }
    final core = _core;
    if (core is! LocalTranslationCore) {
      _showMessage('当前运行核心不支持本地评测');
      return;
    }
    final workerPath = _workerPath;
    if (!File(workerPath).existsSync()) {
      _showMessage('未找到随包本地翻译运行时，请重新安装完整预览版');
      return;
    }
    setState(() => _evaluatingProviderId = profile.id);
    try {
      _showMessage('正在评测“${profile.displayName}”固定样例…');
      final package = _core is ModelPackageCore
          ? await _validatedPackage(profile.modelPath!)
          : null;
      final cases = package == null
          ? fixedModelEvaluationCases
          : ModelEvaluationService.casesForDirection(
              package.sourceLanguage,
              package.targetLanguage,
            );
      if (cases.isEmpty) {
        _showMessage('当前模型没有匹配的固定评测样例');
        return;
      }
      final report = await ModelEvaluationService.evaluate(
        core: core as LocalTranslationCore,
        modelPath: profile.modelPath!,
        workerPath: workerPath,
        cases: cases,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${profile.displayName} · 固定集评测'),
          content: SizedBox(
            width: 620,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  '输出门禁通过 ${report.passed}/${report.total}  ·  总耗时 ${report.elapsed.inMilliseconds} ms',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text('这是本地模型筛选基线，不是专业领域准确率承诺。参考文本仅供人工对照。'),
                const SizedBox(height: 12),
                ...report.items.map(
                  (item) => _ModelEvaluationItemCard(item: item),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: Navigator.of(context).pop,
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      _showMessage('评测失败：${_friendlyError(error)}');
    } finally {
      if (mounted) setState(() => _evaluatingProviderId = null);
    }
  }

  Future<void> _evaluateProvider(ProviderProfileData profile) async {
    if (_evaluatingProviderId != null) return;
    if (profile.kind == ProviderProfileKind.localModel) {
      await _evaluateLocalProvider(profile);
      return;
    }
    if (profile.kind != ProviderProfileKind.remoteApi) return;
    setState(() => _evaluatingProviderId = profile.id);
    _showMessage('正在评测“${profile.displayName}”固定样例…');
    final client = OpenAiCompatibleTranslationClient(
      httpClient: http.Client(),
      secrets: widget.secretStore ?? ProviderSecretStore.platform(),
      timeout: const Duration(seconds: 45),
    );
    try {
      final report = await ModelEvaluationService.evaluateRemote(
        client: client,
        profile: profile,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${profile.displayName} · 固定集评测'),
          content: SizedBox(
            width: 620,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  '输出门禁通过 ${report.passed}/${report.total}  ·  总耗时 ${report.elapsed.inMilliseconds} ms',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  '远程/兼容模型评测只发送你主动选择的固定样例；不会写入翻译历史。结果用于本地对比，不是专业领域准确率承诺。',
                ),
                const SizedBox(height: 12),
                ...report.items.map(
                  (item) => _ModelEvaluationItemCard(item: item),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: Navigator.of(context).pop,
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      _showMessage('评测失败：${_friendlyError(error)}');
    } finally {
      client.close();
      if (mounted) setState(() => _evaluatingProviderId = null);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void initState() {
    super.initState();
    _core = widget.coreFactory?.call() ?? NativeCoreBridge.open();
    _configuration = ProviderConfigurationService(
      _core,
      widget.secretStore ?? ProviderSecretStore.platform(),
    );
    _health = Future<CoreHealth>.sync(_core.health);
    _refreshProfiles();
    _refreshModelCatalog();
    if (widget.focusUnderstandingUsageRequestId > 0 &&
        !_profiles.any(
          (profile) => profile.kind == ProviderProfileKind.remoteApi,
        )) {
      _scheduleUnderstandingUsageFocus();
    }
  }

  @override
  void didUpdateWidget(covariant ModelSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusUnderstandingUsageRequestId > 0 &&
        widget.focusUnderstandingUsageRequestId !=
            oldWidget.focusUnderstandingUsageRequestId) {
      _scheduleUnderstandingUsageFocus();
    }
  }

  void _scheduleUnderstandingUsageFocus() {
    final requestId = widget.focusUnderstandingUsageRequestId;
    // Let the target ExpansionTile mount and finish its opening animation
    // before asking the outer settings scroll view to reveal the role control.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 260), () async {
        if (!mounted || widget.focusUnderstandingUsageRequestId != requestId) {
          return;
        }
        final hasApiProvider = _profiles.any(
          (profile) => profile.kind == ProviderProfileKind.remoteApi,
        );
        final targetContext = hasApiProvider
            ? _understandingUsageFocusAnchorKey.currentContext
            : _understandingApiFallbackAnchorKey.currentContext;
        if (targetContext == null || !targetContext.mounted) return;
        await Scrollable.ensureVisible(
          targetContext,
          alignment: 0.2,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }),
    );
  }

  @override
  void dispose() {
    _settingsScrollController.dispose();
    _core.dispose();
    super.dispose();
  }

  void _refreshProfiles() {
    try {
      final profiles = _configuration.listProviders();
      final hadApiProvider = _profiles.any(
        (profile) => profile.kind == ProviderProfileKind.remoteApi,
      );
      final hasApiProvider = profiles.any(
        (profile) => profile.kind == ProviderProfileKind.remoteApi,
      );
      if (mounted) {
        setState(() {
          _profiles = profiles;
          _loadError = null;
        });
        if (widget.focusUnderstandingUsageRequestId > 0 &&
            hadApiProvider != hasApiProvider) {
          _scheduleUnderstandingUsageFocus();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _loadError = '暂时无法读取模型配置');
    }
  }

  void _refreshModelCatalog() {
    if (_core case final ModelCatalogCore catalogCore) {
      try {
        final merged = <String, ModelCandidate>{
          for (final model in catalogCore.listModelCatalogEntries().map(
            _candidateFromCatalog,
          ))
            '${model.family.name}|${model.path.toLowerCase()}': model,
        };
        for (final bundled in _bundledModelCandidates()) {
          final key = '${bundled.family.name}|${bundled.path.toLowerCase()}';
          final previous = merged[key];
          final candidate = bundled.copyWith(
            catalogId: previous?.catalogId ?? bundled.catalogId,
            // Once a catalog entry exists, its saved assignments are the
            // user's explicit choice. Do not re-add the bundled default role
            // after the user selects another translation provider.
            assignedRoles: previous?.assignedRoles ?? bundled.assignedRoles,
          );
          merged[key] = candidate;
          catalogCore.saveModelCatalogEntry(_catalogFromCandidate(candidate));
        }
        final sorted = merged.values.toList()
          ..sort(
            (left, right) => left.displayName.compareTo(right.displayName),
          );
        _discoveredModels = List.unmodifiable(sorted);
      } catch (_) {
        _loadError = '暂时无法读取已发现的模型';
      }
    }
  }

  Future<void> _addRemoteProvider() async {
    final draft = await showDialog<_RemoteProviderDraft>(
      context: context,
      builder: (_) => const _AddRemoteProviderDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      await _configuration.saveRemoteProvider(
        id: draft.id,
        displayName: draft.displayName,
        endpoint: draft.endpoint,
        modelId: draft.modelId,
        apiKey: draft.apiKey,
        enabled: false,
        assignedRoles: const {},
      );
      _refreshProfiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('模型配置已安全保存；可先手动试跑，只有选择“设为翻译”后才会参与翻译')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：${_friendlyError(error)}')),
        );
      }
    }
  }

  Future<void> _configureDiscoveredModel(ModelCandidate model) async {
    final draft = await showDialog<_RemoteProviderDraft>(
      context: context,
      builder: (_) => _AddRemoteProviderDialog(
        suggestedName: model.displayName,
        suggestedModel: model.displayName,
        suggestedEndpoint: 'http://127.0.0.1:11434/api',
      ),
    );
    if (draft == null || !mounted) return;
    try {
      await _configuration.saveRemoteProvider(
        id: draft.id,
        displayName: draft.displayName,
        endpoint: draft.endpoint,
        modelId: draft.modelId,
        apiKey: draft.apiKey,
        enabled: false,
        assignedRoles: const {},
      );
      _refreshProfiles();
      _showMessage('已保存兼容接口并保持停用。你可以先测试连接，再手动试跑；确认后选择“设为翻译”');
    } catch (error) {
      _showMessage('接入失败：${_friendlyError(error)}');
    }
  }

  Future<void> _addLocalProvider() async {
    final draft = await showDialog<_LocalProviderDraft>(
      context: context,
      builder: (_) => _AddLocalProviderDialog(directoryPicker: _pickDirectory),
    );
    if (draft == null || !mounted) return;
    await _inspectAndAddLocalProvider(draft.modelPath);
  }

  Future<void> _inspectAndAddLocalProvider(String modelPath) async {
    _setLocalProgress('正在识别模型类型…');
    try {
      final candidate = widget.modelFolderInspector != null
          ? await widget.modelFolderInspector!(modelPath)
          : widget.modelValidator == null
          ? await const ModelPackageDiscoveryService().inspectDirectory(
              modelPath,
            )
          : null;
      if (!mounted) return;
      if (candidate == null) {
        if (widget.modelValidator != null) {
          await _validateAndSaveLocalProvider(modelPath, keepBusy: true);
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有识别到支持的模型文件，请确认选择的是完整模型文件夹')),
        );
        return;
      }
      _mergeDiscovered([candidate]);
      if (candidate.readiness == ModelReadiness.readyToValidate) {
        // The picker may have selected a model library. Validate the actual
        // discovered package, not the library root that contains it.
        await _validateAndSaveLocalProvider(candidate.path, keepBusy: true);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(candidate.userMessage)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('识别失败：${_friendlyError(error)}')),
        );
      }
    } finally {
      _clearLocalProgress();
    }
  }

  Future<String?> _pickDirectory() =>
      widget.directoryPicker?.call() ?? getDirectoryPath();

  Future<void> _discoverLocalProviders() async {
    final rootPath = await _pickDirectory();
    if (rootPath == null || !mounted) return;
    _setLocalProgress('正在搜索译学模型包…');
    try {
      final discovered =
          await (widget.modelDiscovery?.call(rootPath) ??
              const ModelPackageDiscoveryService().discover(rootPath));
      if (!mounted) return;
      if (discovered.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('所选位置没有找到译学模型包')));
        return;
      }
      final selected = discovered.length == 1
          ? discovered.single
          : await _chooseDiscoveredModel(discovered);
      if (selected != null && mounted) {
        await _validateAndSaveLocalProvider(selected, keepBusy: true);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('搜索失败：${_friendlyError(error)}')),
        );
      }
    } finally {
      _clearLocalProgress();
    }
  }

  Future<void> _discoverAllModels() async {
    _setLocalProgress('正在查找本机磁盘…');
    try {
      final service = const ModelPackageDiscoveryService();
      final roots =
          await (widget.driveRootsProvider?.call() ??
              service.recommendedSearchRoots());
      if (!mounted) return;
      if (roots.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('没有找到可访问的本机磁盘')));
        return;
      }
      _setLocalProgress('正在优先搜索常见模型位置，并检查本机磁盘；不会打开或运行模型…');
      final found =
          await (widget.modelCatalogDiscovery?.call(roots) ??
              service.discoverModels(roots));
      if (!mounted) return;
      _mergeDiscovered(found);
      var notice = found.isEmpty
          ? '扫描完成，没有发现已知模型'
          : '扫描完成，发现 ${found.length} 个模型';
      for (final model in found) {
        if (model.family == ModelFamily.qwen ||
            model.family == ModelFamily.ollama) {
          notice = model.userMessage;
          break;
        }
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(notice)));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('搜索失败：${_friendlyError(error)}')),
        );
      }
    } finally {
      _clearLocalProgress();
    }
  }

  void _mergeDiscovered(Iterable<ModelCandidate> models) {
    final incoming = models.toList(growable: false);
    final merged = <String, ModelCandidate>{
      for (final model in _discoveredModels)
        '${model.family.name}|${model.path.toLowerCase()}': model,
    };
    for (final model in incoming) {
      final key = '${model.family.name}|${model.path.toLowerCase()}';
      final previous = merged[key];
      merged[key] = model.copyWith(
        assignedRoles: {...model.assignedRoles, ...?previous?.assignedRoles},
        catalogId: previous?.catalogId ?? model.catalogId,
        sourceLanguage: model.sourceLanguage ?? previous?.sourceLanguage,
        targetLanguage: model.targetLanguage ?? previous?.targetLanguage,
      );
    }
    final sorted = merged.values.toList()
      ..sort((left, right) => left.displayName.compareTo(right.displayName));
    if (_core case final ModelCatalogCore catalogCore) {
      for (final model in incoming) {
        final persisted =
            merged['${model.family.name}|${model.path.toLowerCase()}']!;
        catalogCore.saveModelCatalogEntry(_catalogFromCandidate(persisted));
      }
    }
    setState(() => _discoveredModels = List.unmodifiable(sorted));
  }

  void _toggleModelRole(ModelCandidate selected, ModelRole role) {
    // Discovered models are native local files. Understanding requests use
    // the OpenAI-compatible provider path; assigning this role to a native
    // model would appear enabled in settings but could never run.
    if (role == ModelRole.understanding) return;
    if (_core is! ModelCatalogCore) return;
    final shouldAssign = !selected.assignedRoles.contains(role);
    final selectedDirection = _translationDirectionForCandidate(selected);
    final updated = _discoveredModels
        .map((model) {
          final isSelected =
              model.path.toLowerCase() == selected.path.toLowerCase();
          final roles = {...model.assignedRoles};
          if (role != ModelRole.translation || !shouldAssign || isSelected) {
            if (isSelected || shouldAssign || role != ModelRole.translation) {
              roles.remove(role);
            }
          } else {
            final modelDirection = _translationDirectionForCandidate(model);
            if (selectedDirection == null ||
                modelDirection == null ||
                modelDirection == selectedDirection) {
              roles.remove(role);
            }
          }
          if (isSelected && shouldAssign) roles.add(role);
          return model.copyWith(assignedRoles: Set.unmodifiable(roles));
        })
        .toList(growable: false);
    final updatedProfiles = _profiles
        .map((profile) {
          final matches =
              profile.modelPath?.toLowerCase() == selected.path.toLowerCase();
          final roles = {...profile.assignedRoles};
          if (role != ModelRole.translation || !shouldAssign || matches) {
            if (matches || shouldAssign || role != ModelRole.translation) {
              roles.remove(role);
            }
          } else {
            final profileDirection = _translationDirectionForProfile(profile);
            if (profile.kind != ProviderProfileKind.localModel ||
                selectedDirection == null ||
                profileDirection == null ||
                profileDirection == selectedDirection) {
              roles.remove(role);
            }
          }
          if (matches && shouldAssign) roles.add(role);
          return profile.copyWith(assignedRoles: Set.unmodifiable(roles));
        })
        .toList(growable: false);
    final catalogCore = _core as ModelCatalogCore;
    for (final model in updated) {
      catalogCore.saveModelCatalogEntry(_catalogFromCandidate(model));
    }
    for (final profile in updatedProfiles) {
      final previous = _profiles
          .where((old) => old.id == profile.id)
          .firstOrNull;
      if (previous == null ||
          previous.enabled != profile.enabled ||
          !setEquals(previous.assignedRoles, profile.assignedRoles)) {
        _core.saveProviderProfile(profile);
      }
    }
    setState(() {
      _discoveredModels = List.unmodifiable(updated);
      _profiles = List.unmodifiable(updatedProfiles);
    });
    widget.onConfigurationChanged?.call();
  }

  Future<void> _removeDiscoveredModel(ModelCandidate model) async {
    if (_core is! ModelCatalogCore) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移除${model.displayName}记录？'),
        content: const Text('只移除译学中的发现记录，不会删除磁盘上的模型文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除记录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final id = model.catalogId ?? _catalogId(model);
      (_core as ModelCatalogCore).deleteModelCatalogEntry(id);
      setState(() {
        _discoveredModels = List.unmodifiable(
          _discoveredModels.where(
            (candidate) => (candidate.catalogId ?? _catalogId(candidate)) != id,
          ),
        );
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('发现记录已移除，模型文件未删除')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移除失败：${_friendlyError(error)}')),
        );
      }
    }
  }

  void _selectProvider(ProviderProfileData selected) {
    final selectedDirection = _translationDirectionForProfile(selected);
    final updated = _profiles
        .map((profile) {
          final isSelected = profile.id == selected.id;
          final profileDirection = _translationDirectionForProfile(profile);
          final keepsDifferentDirection =
              !isSelected &&
              selected.kind == ProviderProfileKind.localModel &&
              profile.kind == ProviderProfileKind.localModel &&
              selectedDirection != null &&
              profileDirection != null &&
              selectedDirection != profileDirection &&
              profile.assignedRoles.contains(ModelRole.translation);
          final roles = {...profile.assignedRoles};
          if (!keepsDifferentDirection) {
            roles.remove(ModelRole.translation);
          }
          if (isSelected) roles.add(ModelRole.translation);
          final keepsAnotherRole = roles.any(
            (role) => role != ModelRole.translation,
          );
          return profile.copyWith(
            enabled:
                isSelected ||
                (profile.enabled &&
                    (keepsAnotherRole || keepsDifferentDirection)),
            assignedRoles: Set.unmodifiable(roles),
          );
        })
        .toList(growable: false);
    for (final profile in updated) {
      _core.saveProviderProfile(profile);
    }
    _syncCatalogTranslationRoles(
      selectedLocalModelPaths: updated
          .where(
            (profile) =>
                profile.kind == ProviderProfileKind.localModel &&
                profile.assignedRoles.contains(ModelRole.translation),
          )
          .map((profile) => profile.modelPath)
          .whereType<String>(),
      managedLocalModelPaths: [
        ..._profiles
            .where((profile) => profile.kind == ProviderProfileKind.localModel)
            .map((profile) => profile.modelPath)
            .whereType<String>(),
        ...updated
            .where((profile) => profile.kind == ProviderProfileKind.localModel)
            .map((profile) => profile.modelPath)
            .whereType<String>(),
      ],
    );
    setState(() => _profiles = List.unmodifiable(updated));
    widget.onConfigurationChanged?.call();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          selected.kind == ProviderProfileKind.localModel
              ? '已设置 ${selected.displayName}；不同语向的本地模型会保留'
              : '${selected.displayName}已设为翻译模型',
        ),
      ),
    );
  }

  void _toggleProviderRole(ProviderProfileData selected, ModelRole role) {
    if (selected.kind == ProviderProfileKind.localModel &&
        role == ModelRole.understanding) {
      return;
    }
    final shouldAssign = !selected.assignedRoles.contains(role);
    final updated = _profiles
        .map((profile) {
          final isSelectedProfile = profile.id == selected.id;
          final roles = {...profile.assignedRoles};
          if (role == ModelRole.translation) {
            if (isSelectedProfile && !shouldAssign) {
              roles.remove(role);
            } else if (isSelectedProfile && shouldAssign) {
              roles.add(role);
            } else if (shouldAssign &&
                !_canKeepTranslationAlongside(profile, selected)) {
              roles.remove(role);
            }
          } else {
            roles.remove(role);
            if (isSelectedProfile && shouldAssign) roles.add(role);
          }
          final enabled = isSelectedProfile
              ? shouldAssign || (profile.enabled && roles.isNotEmpty)
              : profile.enabled;
          return profile.copyWith(
            enabled: enabled,
            assignedRoles: Set.unmodifiable(roles),
          );
        })
        .toList(growable: false);
    for (final profile in updated) {
      _core.saveProviderProfile(profile);
    }
    if (role == ModelRole.translation) {
      _syncCatalogTranslationRoles(
        selectedLocalModelPaths: updated
            .where(
              (profile) =>
                  profile.kind == ProviderProfileKind.localModel &&
                  profile.assignedRoles.contains(ModelRole.translation),
            )
            .map((profile) => profile.modelPath)
            .whereType<String>(),
        managedLocalModelPaths: [
          ..._profiles
              .where(
                (profile) => profile.kind == ProviderProfileKind.localModel,
              )
              .map((profile) => profile.modelPath)
              .whereType<String>(),
          ...updated
              .where(
                (profile) => profile.kind == ProviderProfileKind.localModel,
              )
              .map((profile) => profile.modelPath)
              .whereType<String>(),
        ],
      );
    }
    setState(() => _profiles = List.unmodifiable(updated));
    widget.onConfigurationChanged?.call();
    _showMessage(shouldAssign ? '已分配模型用途并启用' : '已取消模型用途');
  }

  void _syncCatalogTranslationRoles({
    required Iterable<String> selectedLocalModelPaths,
    required Iterable<String> managedLocalModelPaths,
  }) {
    if (_core case final ModelCatalogCore catalogCore) {
      final selectedPaths = selectedLocalModelPaths
          .map((path) => path.toLowerCase())
          .toSet();
      final managedPaths = {
        ...selectedPaths,
        ...managedLocalModelPaths.map((path) => path.toLowerCase()),
      };
      for (final entry in catalogCore.listModelCatalogEntries()) {
        if (!managedPaths.contains(entry.path.toLowerCase())) continue;
        final roles = entry.assignedRoles
            .where((role) => role != ModelRole.translation.wireName)
            .toList(growable: true);
        if (selectedPaths.contains(entry.path.toLowerCase())) {
          roles.add(ModelRole.translation.wireName);
        }
        final previousRoles = entry.assignedRoles.toSet();
        final updatedRoles = roles.toSet();
        if (previousRoles.length == updatedRoles.length &&
            previousRoles.containsAll(updatedRoles)) {
          continue;
        }
        catalogCore.saveModelCatalogEntry(
          ModelCatalogEntryData(
            id: entry.id,
            path: entry.path,
            displayName: entry.displayName,
            family: entry.family,
            readiness: entry.readiness,
            capabilities: entry.capabilities,
            assignedRoles: List.unmodifiable(roles),
            sourceLanguage: entry.sourceLanguage,
            targetLanguage: entry.targetLanguage,
          ),
        );
      }

      _discoveredModels = List.unmodifiable(
        _discoveredModels.map((model) {
          if (!managedPaths.contains(model.path.toLowerCase())) return model;
          final roles = {...model.assignedRoles}..remove(ModelRole.translation);
          if (selectedPaths.contains(model.path.toLowerCase())) {
            roles.add(ModelRole.translation);
          }
          return model.copyWith(assignedRoles: Set.unmodifiable(roles));
        }),
      );
    }
  }

  void _useBundledDefault() {
    final updated = _profiles
        .map((profile) {
          final hadTranslationRole = profile.assignedRoles.contains(
            ModelRole.translation,
          );
          final roles = {...profile.assignedRoles}
            ..remove(ModelRole.translation);
          return profile.copyWith(
            enabled:
                profile.enabled && (!hadTranslationRole || roles.isNotEmpty),
            assignedRoles: Set.unmodifiable(roles),
          );
        })
        .toList(growable: false);
    for (final profile in updated) {
      _core.saveProviderProfile(profile);
    }
    _syncCatalogTranslationRoles(
      selectedLocalModelPaths: const <String>[],
      managedLocalModelPaths: _profiles
          .where((profile) => profile.kind == ProviderProfileKind.localModel)
          .map((profile) => profile.modelPath)
          .whereType<String>(),
    );
    setState(() => _profiles = List.unmodifiable(updated));
    widget.onConfigurationChanged?.call();
    _showMessage('已恢复译学随包英汉模型');
  }

  Future<void> _deleteProvider(ProviderProfileData profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除${profile.displayName}？'),
        content: Text(
          profile.kind == ProviderProfileKind.localModel
              ? '只删除译学中的模型配置，不会删除本地模型文件。'
              : '只删除译学中的配置，并同步删除本机安全存储中的 API 密钥。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _configuration.deleteProvider(profile.id);
      _refreshProfiles();
      widget.onConfigurationChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${profile.displayName}已删除')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：${_friendlyError(error)}')),
        );
      }
    }
  }

  Future<void> _editProvider(ProviderProfileData profile) async {
    if (profile.kind != ProviderProfileKind.remoteApi) return;
    final draft = await showDialog<_RemoteProviderDraft>(
      context: context,
      builder: (_) => _AddRemoteProviderDialog(existing: profile),
    );
    if (draft == null || !mounted) return;
    try {
      await _configuration.updateRemoteProvider(
        existing: profile,
        displayName: draft.displayName,
        endpoint: draft.endpoint,
        modelId: draft.modelId,
        apiKey: draft.apiKey,
      );
      _refreshProfiles();
      widget.onConfigurationChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('模型配置已更新')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败：${_friendlyError(error)}')),
        );
      }
    }
  }

  Future<void> _testProvider(ProviderProfileData profile) async {
    if (profile.kind != ProviderProfileKind.remoteApi ||
        _testingProviderId != null) {
      return;
    }
    setState(() => _testingProviderId = profile.id);
    try {
      if (widget.connectivityTester != null) {
        await widget.connectivityTester!(profile);
      } else {
        final client = OpenAiCompatibleTranslationClient(
          httpClient: http.Client(),
          secrets: widget.secretStore ?? ProviderSecretStore.platform(),
          timeout: const Duration(seconds: 12),
        );
        try {
          await client.checkConnection(profile: profile);
        } finally {
          client.close();
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${profile.displayName}连接正常')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接测试失败：${_friendlyError(error)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _testingProviderId = null);
    }
  }

  Future<String?> _chooseDiscoveredModel(List<String> paths) {
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('找到 ${paths.length} 个模型包'),
        children: paths
            .map(
              (path) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, path),
                child: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  Future<void> _validateAndSaveLocalProvider(
    String modelPath, {
    bool keepBusy = false,
  }) async {
    _setLocalProgress('正在校验模型完整性…');
    try {
      final package = widget.modelValidator != null
          ? await widget.modelValidator!(modelPath)
          : await Isolate.run(() => _validateModelPackage(modelPath));
      _configuration.saveValidatedLocalProvider(
        package: package,
        modelPath: modelPath,
      );
      _registerValidatedTranslationModel(package, modelPath);
      _refreshProfiles();
      widget.onConfigurationChanged?.call();
      final saved = _profiles.where(
        (profile) =>
            profile.modelPath?.toLowerCase() == modelPath.toLowerCase(),
      );
      if (saved.isNotEmpty) _selectProvider(saved.first);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${package.displayName}已通过校验并启用')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：${_friendlyError(error)}')),
        );
      }
    } finally {
      if (!keepBusy) _clearLocalProgress();
    }
  }

  void _registerValidatedTranslationModel(
    ModelPackageValidationData package,
    String modelPath,
  ) {
    if (_core is! ModelCatalogCore) return;
    final existing = _discoveredModels.where(
      (model) => model.path.toLowerCase() == modelPath.toLowerCase(),
    );
    final candidate = existing.isNotEmpty
        ? existing.first.copyWith(
            assignedRoles: {
              ...existing.first.assignedRoles,
              ModelRole.translation,
            },
            sourceLanguage: package.sourceLanguage,
            targetLanguage: package.targetLanguage,
          )
        : ModelCandidate(
            path: modelPath,
            displayName: package.displayName,
            family: ModelFamily.yixueTranslation,
            readiness: ModelReadiness.readyToValidate,
            capabilities: const {ModelCapability.translation},
            assignedRoles: const {ModelRole.translation},
            sourceLanguage: package.sourceLanguage,
            targetLanguage: package.targetLanguage,
          );
    _mergeDiscovered([candidate]);
  }

  void _setLocalProgress(String message) {
    if (!mounted) return;
    setState(() {
      _isLocalBusy = true;
      _localProgress = message;
    });
  }

  void _clearLocalProgress() {
    if (!mounted) return;
    setState(() {
      _isLocalBusy = false;
      _localProgress = null;
    });
  }

  String _friendlyError(Object error) {
    if (error is FormatException) return '请检查必填内容';
    if (error is CoreBridgeException && error.code == 'model_package_invalid') {
      return '模型包校验失败，请确认文件完整且来源可信';
    }
    if (error is CoreBridgeException) return error.message;
    return '请检查地址和输入内容';
  }

  List<ProviderProfileData> get _enabledTranslationProviders => _profiles
      .where(
        (profile) =>
            profile.enabled &&
            profile.assignedRoles.contains(ModelRole.translation),
      )
      .toList(growable: false);

  List<ProviderProfileData> get _catalogTranslationProviders {
    final assignedPaths = _discoveredModels
        .where((model) => model.assignedRoles.contains(ModelRole.translation))
        .map((model) => model.path.toLowerCase())
        .toSet();
    assignedPaths.addAll(
      _enabledTranslationProviders
          .where((profile) => profile.kind == ProviderProfileKind.localModel)
          .map((profile) => profile.modelPath?.toLowerCase())
          .whereType<String>(),
    );
    return _profiles
        .where(
          (profile) =>
              profile.enabled &&
              profile.kind == ProviderProfileKind.localModel &&
              profile.modelPath != null &&
              assignedPaths.contains(profile.modelPath!.toLowerCase()),
        )
        .toList(growable: false);
  }

  List<String> get _translationRouteSummaries {
    final directions = _translationDirections;
    final explicit = _activeTranslationProvider;
    if (explicit != null) {
      if (explicit.kind == ProviderProfileKind.remoteApi) {
        return [
          for (final direction in directions)
            '${direction.label} · ${explicit.displayName} · ${explicit.modelId}',
        ];
      }
    }

    final providers = _enabledTranslationProviders.isNotEmpty
        ? _enabledTranslationProviders
              .where(
                (profile) => profile.kind == ProviderProfileKind.localModel,
              )
              .toList(growable: false)
        : _catalogTranslationProviders;
    final bundled = _bundledModelCandidates();
    return [
      for (final direction in directions)
        _routeSummaryForDirection(
          direction,
          providers: providers,
          bundled: bundled,
        ),
    ];
  }

  List<({String source, String target, String label})>
  get _translationDirections => [
    for (final direction in TranslationDirection.values)
      (
        source: direction.sourceLanguage,
        target: direction.targetLanguage,
        label: direction.actionLabel,
      ),
  ];

  String _routeSummaryForDirection(
    ({String source, String target, String label}) direction, {
    required List<ProviderProfileData> providers,
    required List<ModelCandidate> bundled,
  }) {
    final directionMatches = providers
        .where(
          (profile) =>
              _localProfileDirectionForSettings(profile, (
                source: direction.source,
                target: direction.target,
              )) ==
              true,
        )
        .toList(growable: false);
    final genericMatches = providers
        .where(
          (profile) =>
              _localProfileDirectionForSettings(profile, (
                source: direction.source,
                target: direction.target,
              )) ==
              null,
        )
        .toList(growable: false);
    final matchingProviders = directionMatches.isNotEmpty
        ? directionMatches
        : genericMatches;
    if (matchingProviders.length > 1) {
      return '${direction.label} · 多个本地模型匹配';
    }
    if (matchingProviders.length == 1) {
      final profile = matchingProviders.single;
      return '${direction.label} · ${profile.displayName} · ${profile.modelId}';
    }

    final bundledModel = bundled.where(
      (model) =>
          model.sourceLanguage == direction.source &&
          model.targetLanguage == direction.target,
    );
    if (bundledModel.isNotEmpty) {
      final model = bundledModel.first;
      return '${direction.label} · ${model.displayName} · '
          '${model.pathAvailable ? '随包可用' : '未检测到随包文件'}';
    }
    if (_enabledTranslationProviders.isNotEmpty) {
      return '${direction.label} · 已分配模型不支持此方向';
    }
    return '${direction.label} · 未配置对应模型';
  }

  bool get _hasTranslationProviderConflict {
    final providers = _enabledTranslationProviders.isNotEmpty
        ? _enabledTranslationProviders
        : _catalogTranslationProviders;
    if (providers.length <= 1) return false;
    if (providers.any(
      (profile) => profile.kind != ProviderProfileKind.localModel,
    )) {
      return true;
    }

    for (final direction in _translationDirections) {
      final matches = providers
          .where(
            (profile) =>
                _localProfileDirectionForSettings(profile, (
                  source: direction.source,
                  target: direction.target,
                )) ==
                true,
          )
          .length;
      final generic = providers
          .where(
            (profile) =>
                _localProfileDirectionForSettings(profile, (
                  source: direction.source,
                  target: direction.target,
                )) ==
                null,
          )
          .length;
      if (matches > 1 || (matches == 0 && generic > 1)) return true;
    }
    return false;
  }

  bool? _localProfileDirectionForSettings(
    ProviderProfileData profile,
    ({String source, String target}) direction,
  ) {
    final path = profile.modelPath?.toLowerCase();
    if (path == null) return null;
    final model = _discoveredModels.where(
      (candidate) => candidate.path.toLowerCase() == path,
    );
    final candidate = model.isEmpty ? null : model.first;
    return _translationModelDirection(
      model: candidate,
      path: path,
      source: direction.source,
      target: direction.target,
    );
  }

  TranslationDirection? _translationDirectionForProfile(
    ProviderProfileData profile,
  ) {
    if (profile.kind != ProviderProfileKind.localModel) return null;
    final matches = TranslationDirection.values
        .where(
          (direction) =>
              _localProfileDirectionForSettings(profile, (
                source: direction.sourceLanguage,
                target: direction.targetLanguage,
              )) ==
              true,
        )
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  TranslationDirection? _translationDirectionForCandidate(
    ModelCandidate candidate,
  ) {
    final matches = TranslationDirection.values
        .where(
          (direction) =>
              _translationModelDirection(
                model: candidate,
                path: candidate.path,
                source: direction.sourceLanguage,
                target: direction.targetLanguage,
              ) ==
              true,
        )
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  bool _canKeepTranslationAlongside(
    ProviderProfileData existing,
    ProviderProfileData selected,
  ) {
    if (existing.kind != ProviderProfileKind.localModel ||
        selected.kind != ProviderProfileKind.localModel) {
      return false;
    }
    final existingDirection = _translationDirectionForProfile(existing);
    final selectedDirection = _translationDirectionForProfile(selected);
    return existingDirection != null &&
        selectedDirection != null &&
        existingDirection != selectedDirection;
  }

  ProviderProfileData? get _activeTranslationProvider {
    // Runtime fails closed whenever more than one enabled provider claims
    // translation, regardless of whether the providers are local or API based.
    if (_hasTranslationProviderConflict) return null;
    final explicitlyAssigned = _enabledTranslationProviders;
    return explicitlyAssigned.length == 1 ? explicitlyAssigned.single : null;
  }

  Future<void> _chooseTranslationProvider() async {
    final choices = List<ProviderProfileData>.of(_profiles);
    if (choices.isEmpty) {
      _showMessage('还没有可选择的模型配置');
      return;
    }
    final maxListHeight = (MediaQuery.sizeOf(context).height * .55)
        .clamp(0.0, 420.0)
        .toDouble();
    final listHeight = (choices.length * 72.0)
        .clamp(0.0, maxListHeight)
        .toDouble();
    final hasRemoteChoice = choices.any(
      (profile) => profile.kind == ProviderProfileKind.remoteApi,
    );
    final selected = await showDialog<ProviderProfileData>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择翻译模型'),
        content: SizedBox(
          width: 420,
          height: listHeight + (hasRemoteChoice ? 52 : 0),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    for (final profile in choices)
                      ListTile(
                        leading: Icon(_providerRouteIcon(profile)),
                        title: Text(profile.displayName),
                        subtitle: Text(
                          '${_providerRouteLabel(profile)} · ${profile.modelId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: profile.id == _activeTranslationProvider?.id
                            ? const Chip(label: Text('当前使用'))
                            : TextButton(
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(profile),
                                child: const Text('设为翻译'),
                              ),
                        onTap: () => Navigator.of(dialogContext).pop(profile),
                      ),
                  ],
                ),
              ),
              if (hasRemoteChoice)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '使用远程 API 时，翻译原文会发送给所选服务；失败时不会自动切换。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected != null && mounted) _selectProvider(selected);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _settingsScrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '模型与服务',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: const Color(0xFF183D38),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text('管理本地模型与 API，并为翻译、理解和语音能力选择使用路线。新配置默认停用，不会自动替换现有路线。'),
              const SizedBox(height: 16),
              _DailyTranslationSetup(
                activeProvider: _activeTranslationProvider,
                conflictingProviderCount:
                    _enabledTranslationProviders.isNotEmpty
                    ? _enabledTranslationProviders.length
                    : _catalogTranslationProviders.length,
                hasTranslationProviderConflict: _hasTranslationProviderConflict,
                catalogTranslationProviderCount:
                    _catalogTranslationProviders.length,
                translationRouteSummaries: _translationRouteSummaries,
                onResolveConflict: _chooseTranslationProvider,
                onSwitchTranslationMethod: () => _chooseTranslationProvider(),
                onUseBundledDefault: _useBundledDefault,
                showBundledDefaultAction:
                    _activeTranslationProvider != null ||
                    _hasTranslationProviderConflict ||
                    _catalogTranslationProviders.isNotEmpty,
                onAddLocal: _isLocalBusy ? null : _addLocalProvider,
                onAddApi: _addRemoteProvider,
                onTestCurrent:
                    _activeTranslationProvider?.kind ==
                        ProviderProfileKind.remoteApi
                    ? () => _testProvider(_activeTranslationProvider!)
                    : null,
                testingCurrent:
                    _testingProviderId == _activeTranslationProvider?.id,
                onTrialCurrent: _activeTranslationProvider == null
                    ? null
                    : () => _trialProvider(_activeTranslationProvider!),
                trialingCurrent:
                    _trialingProviderId == _activeTranslationProvider?.id,
                understandingApiFallbackFocusKey:
                    widget.focusUnderstandingUsageRequestId > 0 &&
                        !_profiles.any(
                          (profile) =>
                              profile.kind == ProviderProfileKind.remoteApi,
                        )
                    ? _understandingApiFallbackAnchorKey
                    : null,
              ),
              const SizedBox(height: 14),
              _CoreStatusCard(health: _health),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  leading: const Icon(Icons.travel_explore_rounded),
                  title: const Text('查找已经下载的模型'),
                  subtitle: const Text('只搜索模型文件，不会自动运行模型'),
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _isLocalBusy ? null : _discoverAllModels,
                          icon: const Icon(Icons.radar_rounded),
                          label: const Text('搜索本机磁盘'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _isLocalBusy
                              ? null
                              : _discoverLocalProviders,
                          icon: const Icon(Icons.folder_open_rounded),
                          label: const Text('搜索指定位置'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_localProgress != null) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(_localProgress!),
              ],
              const SizedBox(height: 16),
              if (_loadError != null) Text(_loadError!),
              _ModelOverview(
                discovered: _discoveredModels,
                configured: _profiles,
                busy: _isLocalBusy,
                onEnable: (candidate) =>
                    _validateAndSaveLocalProvider(candidate.path),
                onConfigure: _configureDiscoveredModel,
                onToggleRole: _toggleModelRole,
                onToggleProviderRole: _toggleProviderRole,
                onSelectProvider: _selectProvider,
                onDeleteProvider: _deleteProvider,
                onEditProvider: _editProvider,
                onTestProvider: _testProvider,
                onTrialProvider: _trialProvider,
                onEvaluateProvider: _evaluateProvider,
                testingProviderId: _testingProviderId,
                trialingProviderId: _trialingProviderId,
                evaluatingProviderId: _evaluatingProviderId,
                onRemoveDiscovered: _removeDiscoveredModel,
                onOpenSimultaneousInterpretation:
                    widget.onOpenSimultaneousInterpretation,
                focusUnderstandingUsageRequestId:
                    widget.focusUnderstandingUsageRequestId,
                understandingUsageFocusAnchorKey:
                    _understandingUsageFocusAnchorKey,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DailyTranslationSetup extends StatelessWidget {
  const _DailyTranslationSetup({
    required this.activeProvider,
    required this.conflictingProviderCount,
    required this.hasTranslationProviderConflict,
    required this.catalogTranslationProviderCount,
    required this.translationRouteSummaries,
    required this.onResolveConflict,
    required this.onSwitchTranslationMethod,
    required this.onUseBundledDefault,
    required this.showBundledDefaultAction,
    required this.onAddLocal,
    required this.onAddApi,
    required this.onTestCurrent,
    required this.testingCurrent,
    required this.onTrialCurrent,
    required this.trialingCurrent,
    this.understandingApiFallbackFocusKey,
  });

  final ProviderProfileData? activeProvider;
  final int conflictingProviderCount;
  final bool hasTranslationProviderConflict;
  final int catalogTranslationProviderCount;
  final List<String> translationRouteSummaries;
  final VoidCallback onResolveConflict;
  final VoidCallback onSwitchTranslationMethod;
  final VoidCallback onUseBundledDefault;
  final bool showBundledDefaultAction;
  final VoidCallback? onAddLocal;
  final VoidCallback onAddApi;
  final VoidCallback? onTestCurrent;
  final bool testingCurrent;
  final VoidCallback? onTrialCurrent;
  final bool trialingCurrent;
  final Key? understandingApiFallbackFocusKey;

  @override
  Widget build(BuildContext context) {
    final hasConflict = hasTranslationProviderConflict;
    final usesCatalogTranslationFallback =
        !hasConflict &&
        activeProvider == null &&
        catalogTranslationProviderCount > 0;
    final routeLabel = hasConflict
        ? '需要选择唯一翻译服务'
        : activeProvider == null
        ? '本机 · 译学随包英汉模型'
        : '${_providerRouteLabel(activeProvider!)} · ${activeProvider!.displayName}';
    final modelLabel = activeProvider?.modelId;
    final availabilityDetail = activeProvider == null
        ? ''
        : activeProvider!.kind == ProviderProfileKind.localModel
        ? '短句试跑验证可用性'
        : '连接测试检查地址与密钥';
    final availabilityLabel = hasConflict
        ? '配置冲突'
        : usesCatalogTranslationFallback
        ? '按语种匹配'
        : activeProvider == null
        ? '随包英汉'
        : activeProvider!.kind == ProviderProfileKind.localModel
        ? '本地模型 · 可试跑'
        : 'API 模型 · 可测试';
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('daily-translation-setup'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: const Color(0xFFEAF4F1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFC9DFD8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.translate_rounded, color: Color(0xFF23745F)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '当前翻译方式',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Chip(
                  avatar: Icon(
                    hasConflict
                        ? Icons.warning_amber_rounded
                        : Icons.route_outlined,
                    size: 16,
                    color: hasConflict ? colors.error : null,
                  ),
                  label: Text(hasConflict ? '配置冲突' : availabilityLabel),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              hasConflict
                  ? '当前翻译：待选择唯一 Provider'
                  : usesCatalogTranslationFallback
                  ? '当前翻译：本地模型按语种匹配'
                  : '当前翻译：${activeProvider?.displayName ?? '译学随包英汉模型'}',
              key: const ValueKey('current-translation-provider'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              hasConflict
                  ? '$conflictingProviderCount 个启用的 Provider 存在翻译冲突。'
                  : usesCatalogTranslationFallback
                  ? '$catalogTranslationProviderCount 个本地模型按已配置语种匹配；同向多模型会提示冲突。'
                  : activeProvider == null
                  ? '本机默认 · 英译中与中译英'
                  : '$routeLabel${modelLabel == null || modelLabel.isEmpty ? '' : ' · $modelLabel'} · $availabilityDetail',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF55716C)),
            ),
            if (translationRouteSummaries.isNotEmpty) ...[
              const SizedBox(height: 8),
              Material(
                key: const ValueKey('translation-direction-routes'),
                color: colors.surface.withValues(alpha: .72),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                  side: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .7),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  key: const ValueKey('translation-direction-routes-toggle'),
                  initiallyExpanded: false,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  leading: const Icon(Icons.route_outlined, size: 20),
                  title: const Text('翻译方向路由'),
                  subtitle: Text(
                    '${translationRouteSummaries.length} 个翻译方向，展开查看当前路由',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        '列表展示译学当前的配置路由；外接 API 是否支持每个方向，仍需结合服务商能力与实际请求确认。',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                    for (final route in translationRouteSummaries)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            route,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (hasConflict) ...[
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('translation-provider-conflict'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colors.error.withValues(alpha: .35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded, color: colors.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '多个已启用的翻译配置同时指定了翻译用途。译学不会猜选本地模型或 API；请手动选择唯一配置。',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colors.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        key: const ValueKey(
                          'resolve-translation-provider-conflict',
                        ),
                        onPressed: onResolveConflict,
                        icon: const Icon(Icons.checklist_rounded),
                        label: const Text('选择唯一配置'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('choose-translation-provider'),
                  onPressed: onSwitchTranslationMethod,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('选择模型并设为翻译'),
                ),
                if (onTestCurrent != null)
                  OutlinedButton.icon(
                    key: const ValueKey('test-current-translation-provider'),
                    onPressed: testingCurrent ? null : onTestCurrent,
                    icon: testingCurrent
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering_outlined),
                    label: Text(testingCurrent ? '连接测试中…' : '测试当前 API'),
                  ),
                if (onTrialCurrent != null)
                  OutlinedButton.icon(
                    key: const ValueKey('trial-current-translation-provider'),
                    onPressed: trialingCurrent ? null : onTrialCurrent,
                    icon: trialingCurrent
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_circle_outline_rounded),
                    label: Text(trialingCurrent ? '试跑中…' : '短句试跑'),
                  ),
              ],
            ),
            if (showBundledDefaultAction) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('restore-bundled-translation-provider'),
                  onPressed: onUseBundledDefault,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('恢复译学随包英汉模型'),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 0,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Text(
                    '添加新方式',
                    style: TextStyle(color: Color(0xFF55716C), fontSize: 12),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('add-local-translation-provider'),
                  onPressed: onAddLocal,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('添加本地模型'),
                ),
                KeyedSubtree(
                  key: understandingApiFallbackFocusKey,
                  child: TextButton.icon(
                    key: const ValueKey('add-api-translation-provider'),
                    onPressed: onAddApi,
                    icon: const Icon(Icons.add_link_rounded, size: 18),
                    label: const Text('添加 API 模型'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              key: const ValueKey('model-role-setup-guide'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: .68),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: .7),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '可在上方选择并设为翻译；先用短句试跑。未明确选择的配置不会用于翻译。',
                      key: ValueKey('model-role-setup-guide-copy'),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              activeProvider?.kind == ProviderProfileKind.remoteApi
                  ? '实际翻译原文会发送给 ${activeProvider!.displayName}；短句试跑发送固定样例，失败时不会自动切换。'
                  : '短句试跑只使用本机所选模型；其他 API 不会自动接管翻译。',
              style: TextStyle(fontSize: 12, color: Color(0xFF55716C)),
            ),
          ],
        ),
      ),
    );
  }
}

String _providerRouteLabel(ProviderProfileData profile) {
  if (profile.kind == ProviderProfileKind.localModel) return '本地模型';
  if (isLocalCompatibleEndpoint(profile.endpoint)) return '本机 API';
  return '远程 API';
}

IconData _providerRouteIcon(ProviderProfileData profile) {
  if (profile.kind == ProviderProfileKind.localModel) {
    return Icons.computer_rounded;
  }
  return isLocalCompatibleEndpoint(profile.endpoint)
      ? Icons.laptop_rounded
      : Icons.cloud_outlined;
}

class _ModelOverview extends StatelessWidget {
  const _ModelOverview({
    required this.discovered,
    required this.configured,
    required this.busy,
    required this.onEnable,
    required this.onConfigure,
    required this.onToggleRole,
    required this.onToggleProviderRole,
    required this.onSelectProvider,
    required this.onDeleteProvider,
    required this.onEditProvider,
    required this.onTestProvider,
    required this.onTrialProvider,
    required this.onEvaluateProvider,
    required this.testingProviderId,
    required this.trialingProviderId,
    required this.evaluatingProviderId,
    required this.onRemoveDiscovered,
    this.onOpenSimultaneousInterpretation,
    required this.focusUnderstandingUsageRequestId,
    required this.understandingUsageFocusAnchorKey,
  });

  final List<ModelCandidate> discovered;
  final List<ProviderProfileData> configured;
  final bool busy;
  final ValueChanged<ModelCandidate> onEnable;
  final Future<void> Function(ModelCandidate) onConfigure;
  final void Function(ModelCandidate, ModelRole) onToggleRole;
  final void Function(ProviderProfileData, ModelRole) onToggleProviderRole;
  final ValueChanged<ProviderProfileData> onSelectProvider;
  final Future<void> Function(ProviderProfileData) onDeleteProvider;
  final Future<void> Function(ProviderProfileData) onEditProvider;
  final Future<void> Function(ProviderProfileData) onTestProvider;
  final Future<void> Function(ProviderProfileData) onTrialProvider;
  final Future<void> Function(ProviderProfileData) onEvaluateProvider;
  final String? testingProviderId;
  final String? trialingProviderId;
  final String? evaluatingProviderId;
  final Future<void> Function(ModelCandidate) onRemoveDiscovered;
  final VoidCallback? onOpenSimultaneousInterpretation;
  final int focusUnderstandingUsageRequestId;
  final GlobalKey understandingUsageFocusAnchorKey;

  @override
  Widget build(BuildContext context) {
    final hasExplicitTranslationProvider = configured.any(
      (profile) =>
          profile.enabled &&
          profile.assignedRoles.contains(ModelRole.translation),
    );
    final catalogTranslationFallbackIds = hasExplicitTranslationProvider
        ? const <String>{}
        : configured
              .where(
                (profile) =>
                    profile.enabled &&
                    profile.kind == ProviderProfileKind.localModel &&
                    profile.modelPath != null &&
                    discovered.any(
                      (model) =>
                          model.path.toLowerCase() ==
                              profile.modelPath!.toLowerCase() &&
                          model.assignedRoles.contains(ModelRole.translation),
                    ),
              )
              .map((profile) => profile.id)
              .toSet();
    final configuredPaths = configured
        .map((profile) => profile.modelPath?.toLowerCase())
        .whereType<String>()
        .toSet();
    final localProviders = configured
        .where((profile) => profile.kind == ProviderProfileKind.localModel)
        .toList(growable: false);
    final apiProviders = configured
        .where((profile) => profile.kind == ProviderProfileKind.remoteApi)
        .toList(growable: false);
    final bundled = discovered
        .where(_isBundledCandidate)
        .toList(growable: false);
    final unconfigured = discovered
        .where(
          (model) =>
              !_isBundledCandidate(model) &&
              !configuredPaths.contains(model.path.toLowerCase()),
        )
        .toList(growable: false);
    final ready = discovered
        .where(
          (model) =>
              !_isBundledCandidate(model) &&
              model.readiness == ModelReadiness.readyToValidate,
        )
        .length;
    final runtimeRequired = discovered
        .where(
          (model) =>
              !_isBundledCandidate(model) &&
              model.readiness == ModelReadiness.runtimeRequired,
        )
        .length;
    final incomplete = discovered
        .where(
          (model) =>
              !_isBundledCandidate(model) &&
              model.readiness == ModelReadiness.incomplete,
        )
        .length;
    List<Widget> providerTiles(
      List<ProviderProfileData> providers, {
      bool focusFirstUsageButton = false,
    }) => providers
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key;
          final profile = entry.value;
          return _ProviderTile(
            profile,
            currentTranslation: _currentTranslationProviderId == profile.id,
            catalogTranslationFallback: catalogTranslationFallbackIds.contains(
              profile.id,
            ),
            onSelect: onSelectProvider,
            supportedRoles: _supportedRolesFor(profile),
            onToggleRole: onToggleProviderRole,
            onDelete: onDeleteProvider,
            onEdit: onEditProvider,
            onTest: onTestProvider,
            onTrial: onTrialProvider,
            onEvaluate: onEvaluateProvider,
            testing: testingProviderId == profile.id,
            trialing: trialingProviderId == profile.id,
            evaluating: evaluatingProviderId == profile.id,
            understandingUsageFocusAnchorKey:
                focusFirstUsageButton && index == 0
                ? understandingUsageFocusAnchorKey
                : null,
          );
        })
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                '模型总览',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              '已配置 ${configured.length}  ·  已发现 ${discovered.length}',
              style: const TextStyle(color: Color(0xFF55716C)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: const Color(0xFFF7F9F8),
          child: ExpansionTile(
            key: const ValueKey('model-validation-summary'),
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('模型检查详情'),
            subtitle: Text(
              '$ready 可校验 · $runtimeRequired 等待运行内核 · $incomplete 个不完整',
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _OverviewStat(label: '可校验启用', value: ready),
                  _OverviewStat(label: '等待运行内核', value: runtimeRequired),
                  _OverviewStat(label: '文件不完整', value: incomplete),
                  _OverviewStat(label: '已配置使用', value: configured.length),
                  _OverviewStat(label: '随包英汉', value: bundled.length),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (configured.isEmpty && discovered.isEmpty)
          const _EmptyModels()
        else ...[
          if (bundled.isNotEmpty || localProviders.isNotEmpty)
            Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              color: const Color(0xFFF7F9F8),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFFD7DFDC)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ExpansionTile(
                key: const ValueKey('local-models-category'),
                initiallyExpanded: false,
                leading: const Icon(Icons.memory_rounded),
                title: Text('本地模型（${localProviders.length + bundled.length}）'),
                subtitle: const Text('译学随包模型与已添加模型；展开后再管理测试和用途'),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  if (bundled.isNotEmpty) ...[
                    _BundledModelsSection(
                      models: bundled,
                      configuredPaths: configuredPaths,
                    ),
                    const SizedBox(height: 10),
                  ],
                  ...providerTiles(localProviders),
                ],
              ),
            ),
          if (apiProviders.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(top: 8),
              elevation: 0,
              color: const Color(0xFFF7F9F8),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFFD7DFDC)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ExpansionTile(
                key: ValueKey(
                  focusUnderstandingUsageRequestId > 0
                      ? 'api-models-category-focus-$focusUnderstandingUsageRequestId'
                      : 'api-models-category',
                ),
                initiallyExpanded: focusUnderstandingUsageRequestId > 0,
                leading: const Icon(Icons.cloud_outlined),
                title: Text('API 服务（${apiProviders.length}）'),
                subtitle: const Text('DeepSeek 等兼容服务；查看连接状态与密钥配置'),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: providerTiles(
                  apiProviders,
                  focusFirstUsageButton: focusUnderstandingUsageRequestId > 0,
                ),
              ),
            ),
          if (unconfigured.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(top: 8),
              elevation: 0,
              color: const Color(0xFFF7F9F8),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFFD7DFDC)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ExpansionTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text('其他已发现模型（${unconfigured.length}）'),
                subtitle: const Text('展开后校验、配置用途或移除发现记录'),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                children: [
                  for (final model in unconfigured)
                    _CandidateTile(
                      model: model,
                      busy: busy,
                      onEnable: onEnable,
                      onConfigure: onConfigure,
                      onToggleRole: onToggleRole,
                      onRemove: onRemoveDiscovered,
                    ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 18),
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: const Color(0xFFF7F9F8),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFFD7DFDC)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ExpansionTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: const Text('模型用途与优先级'),
            subtitle: const Text('翻译、理解与总结（兼容 API）、语音合成；同传识别由 AI 同传页面管理'),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            children: [
              _ModelRoleMap(
                discovered: discovered,
                configured: configured,
                onOpenSimultaneousInterpretation:
                    onOpenSimultaneousInterpretation,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String? get _currentTranslationProviderId {
    final explicitlyAssigned = configured
        .where(
          (profile) =>
              profile.enabled &&
              profile.assignedRoles.contains(ModelRole.translation),
        )
        .toList(growable: false);
    if (explicitlyAssigned.length == 1) return explicitlyAssigned.single.id;
    return null;
  }

  Set<ModelRole> _supportedRolesFor(ProviderProfileData profile) {
    if (profile.kind == ProviderProfileKind.remoteApi) {
      return const {ModelRole.translation, ModelRole.understanding};
    }
    final modelPath = profile.modelPath?.toLowerCase();
    if (modelPath != null) {
      for (final model in discovered) {
        if (model.path.toLowerCase() == modelPath &&
            model.supportedRoles.isNotEmpty) {
          return _nativeLocalProviderRoles(model.supportedRoles);
        }
      }
    }
    return _nativeLocalProviderRoles(profile.assignedRoles);
  }
}

Set<ModelRole> _nativeLocalProviderRoles(Iterable<ModelRole> roles) => roles
    .toSet()
    .difference(const {ModelRole.speechRecognition, ModelRole.understanding});

bool _isBundledCandidate(ModelCandidate model) =>
    model.catalogId?.startsWith('bundled.yixue.') == true;

class _OverviewStat extends StatelessWidget {
  const _OverviewStat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF5F2),
        border: Border.all(color: const Color(0xFFCCE1DB)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            '$value',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _EmptyModels extends StatelessWidget {
  const _EmptyModels();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.64),
        border: Border.all(color: const Color(0xFFCFC8B9)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        children: [
          Icon(Icons.hub_outlined, size: 30, color: Color(0xFF55716C)),
          SizedBox(height: 10),
          Text('尚未发现模型', style: TextStyle(fontWeight: FontWeight.w700)),
          SizedBox(height: 4),
          Text('点击“一键搜索本机模型”，不需要知道模型保存在哪里。'),
        ],
      ),
    );
  }
}

class _BundledModelsSection extends StatelessWidget {
  const _BundledModelsSection({
    required this.models,
    required this.configuredPaths,
  });

  final List<ModelCandidate> models;
  final Set<String> configuredPaths;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF5F2),
        border: Border.all(color: const Color(0xFFBFDCD3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.inventory_2_outlined, color: Color(0xFF23745F)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '随包英汉模型',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                '官方默认',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('安装包自带两种英汉轻量模型；无需额外下载 Ollama。已明确配置的 Provider 会优先于随包默认。'),
          const SizedBox(height: 10),
          ...models.map((model) {
            final direction = model.sourceLanguage == 'chinese' ? '中译英' : '英译中';
            final configured = configuredPaths.contains(
              model.path.toLowerCase(),
            );
            final status = configured
                ? '当前配置优先'
                : model.pathAvailable
                ? '随包默认'
                : '随包文件缺失';
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    size: 19,
                    color: Color(0xFF23745F),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${model.displayName}  ·  $direction'),
                        const SizedBox(height: 2),
                        Text(
                          '$status  ·  ${model.path}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF55716C),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.model,
    required this.busy,
    required this.onEnable,
    required this.onConfigure,
    required this.onToggleRole,
    required this.onRemove,
  });

  final ModelCandidate model;
  final bool busy;
  final ValueChanged<ModelCandidate> onEnable;
  final Future<void> Function(ModelCandidate) onConfigure;
  final void Function(ModelCandidate, ModelRole) onToggleRole;
  final Future<void> Function(ModelCandidate) onRemove;

  @override
  Widget build(BuildContext context) {
    final ready = model.readiness == ModelReadiness.readyToValidate;
    final selectableRoles = _nativeLocalProviderRoles(model.supportedRoles);
    final assignedRoles = _nativeLocalProviderRoles(model.assignedRoles);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white.withValues(alpha: 0.72),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFFD7DFDC)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(
              ready ? Icons.verified_outlined : Icons.memory_rounded,
              color: ready ? const Color(0xFF238369) : const Color(0xFF55716C),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text('${model.familyLabel}  ·  ${model.availabilityLabel}'),
                  const SizedBox(height: 3),
                  Text(
                    model.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF6D746F),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: model.capabilities
                        .map(
                          (capability) => Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(_capabilityLabel(capability)),
                          ),
                        )
                        .toList(growable: false),
                  ),
                  if (assignedRoles.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '已指定候选：${assignedRoles.map((role) => role.label).join('、')}',
                      style: const TextStyle(
                        color: Color(0xFF23745F),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              children: [
                if (model.family == ModelFamily.qwen ||
                    model.family == ModelFamily.ollama)
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => onConfigure(model),
                    icon: const Icon(Icons.link_rounded, size: 18),
                    label: const Text('配置兼容接口'),
                  ),
                if (ready)
                  OutlinedButton(
                    onPressed: busy ? null : () => onEnable(model),
                    child: const Text('校验并启用'),
                  ),
                if (selectableRoles.isNotEmpty)
                  PopupMenuButton<ModelRole>(
                    tooltip: '设置模型用途',
                    onSelected: (role) => onToggleRole(model, role),
                    itemBuilder: (_) => selectableRoles
                        .map(
                          (role) => PopupMenuItem(
                            value: role,
                            child: Row(
                              children: [
                                Icon(
                                  model.assignedRoles.contains(role)
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Text(role.label),
                              ],
                            ),
                          ),
                        )
                        .toList(growable: false),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('设置用途'),
                    ),
                  ),
                IconButton(
                  tooltip: '查看模型详情',
                  onPressed: () => _showModelDetails(context, model),
                  icon: const Icon(Icons.info_outline_rounded),
                ),
                IconButton(
                  tooltip: '移除发现记录',
                  onPressed: busy ? null : () => onRemove(model),
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showModelDetails(
    BuildContext context,
    ModelCandidate model,
  ) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final compatibility = ModelCapabilityService.explainCandidate(model);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(model.displayName),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ModelDetailRow(label: '格式', value: model.familyLabel),
                _ModelDetailRow(label: '状态', value: model.availabilityLabel),
                _ModelDetailRow(label: '兼容性', value: compatibility.title),
                _ModelDetailRow(
                  label: '能力',
                  value: model.capabilities.map(_capabilityLabel).join('、'),
                ),
                _ModelDetailRow(
                  label: '可分配用途',
                  value: model.supportedRoles.isEmpty
                      ? '未识别'
                      : model.supportedRoles
                            .map((role) => role.label)
                            .join('、'),
                ),
                _ModelDetailRow(label: '本地路径', value: model.path),
                const SizedBox(height: 12),
                Text(
                  '${compatibility.detail}\n\n下一步：${compatibility.nextStep}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  '许可证、来源和 SHA-256 只有在模型包提供可验证声明时才会显示；发现模型不会自动执行权重或模型代码。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: Navigator.of(context).pop,
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _ModelDetailRow extends StatelessWidget {
  const _ModelDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SelectableText('$label：$value'),
    );
  }
}

class _ModelRoleMap extends StatelessWidget {
  const _ModelRoleMap({
    required this.discovered,
    required this.configured,
    this.onOpenSimultaneousInterpretation,
  });

  final List<ModelCandidate> discovered;
  final List<ProviderProfileData> configured;
  final VoidCallback? onOpenSimultaneousInterpretation;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF183D38),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 14,
        children: [
          _RoleItem(
            icon: Icons.translate_rounded,
            title: '翻译',
            detail: _roleDetail(ModelRole.translation, '随包默认（英语↔中文）'),
          ),
          _RoleItem(
            icon: Icons.auto_awesome,
            title: '理解与总结',
            detail: _roleDetail(
              ModelRole.understanding,
              '未配置理解与总结模型；本用途仅支持兼容 API。',
            ),
          ),
          _RoleItem(
            icon: Icons.hearing_rounded,
            title: 'AI 同传识别',
            detail: '识别模型由 AI 同传页面管理，不受这里的 Provider 角色控制。',
            actionLabel: '打开 AI 同传',
            onAction: onOpenSimultaneousInterpretation,
          ),
          _RoleItem(
            icon: Icons.record_voice_over,
            title: '语音合成',
            detail: _roleDetail(ModelRole.speechSynthesis, '未配置语音合成模型'),
          ),
        ],
      ),
    );
  }

  String _roleDetail(ModelRole role, String fallback) {
    if (role == ModelRole.translation) {
      final enabledAssignments = configured
          .where(
            (profile) =>
                profile.enabled &&
                profile.assignedRoles.contains(ModelRole.translation),
          )
          .toList(growable: false);
      if (enabledAssignments.length > 1) {
        if (enabledAssignments.any(
          (profile) => profile.kind != ProviderProfileKind.localModel,
        )) {
          return '${enabledAssignments.length} 个启用的 Provider 存在翻译冲突';
        }
        final routes = <String>[];
        for (final direction in TranslationDirection.values) {
          final matching = enabledAssignments.where((profile) {
            final path = profile.modelPath?.toLowerCase();
            final candidates = discovered.where(
              (candidate) =>
                  path != null && candidate.path.toLowerCase() == path,
            );
            return _translationModelDirection(
                  model: candidates.isEmpty ? null : candidates.first,
                  path: path,
                  source: direction.sourceLanguage,
                  target: direction.targetLanguage,
                ) ==
                true;
          });
          if (matching.length == 1) {
            routes.add(
              '${direction.actionLabel}：${matching.single.displayName}',
            );
          } else if (matching.length > 1) {
            return '${direction.actionLabel} 有多个匹配模型';
          }
        }
        if (routes.isNotEmpty) return routes.join('；');
        return '本地模型按语种分配';
      }
      if (enabledAssignments.length == 1) {
        return '${enabledAssignments.single.displayName}（当前使用）';
      }
      final catalogAssigned = configured
          .where(
            (profile) =>
                profile.enabled &&
                profile.kind == ProviderProfileKind.localModel &&
                profile.modelPath != null &&
                discovered.any(
                  (candidate) =>
                      candidate.path.toLowerCase() ==
                          profile.modelPath!.toLowerCase() &&
                      candidate.assignedRoles.contains(ModelRole.translation),
                ),
          )
          .toList(growable: false);
      if (catalogAssigned.length > 1) {
        return '${catalogAssigned.length} 个本地模型按语种分配；同向多模型会提示冲突';
      }
      if (catalogAssigned.length == 1) {
        return '${catalogAssigned.single.displayName}（按语种匹配）';
      }
    }

    if (role == ModelRole.understanding) {
      final apiProviders = configured
          .where((profile) => profile.kind == ProviderProfileKind.remoteApi)
          .toList(growable: false);
      final selected = LearningSummaryService.selectProvider(apiProviders);
      if (selected != null) return '${selected.displayName}（当前使用）';
      for (final profile in apiProviders.where((profile) => !profile.enabled)) {
        if (profile.assignedRoles.contains(ModelRole.understanding)) {
          return '${profile.displayName}（已分配，已停用）';
        }
      }
      return fallback;
    }

    for (final profile in configured.where((profile) => profile.enabled)) {
      if (profile.assignedRoles.contains(role)) {
        return '${profile.displayName}（当前使用）';
      }
      final modelPath = profile.modelPath?.toLowerCase();
      if (modelPath == null) continue;
      final model = discovered.where(
        (candidate) => candidate.path.toLowerCase() == modelPath,
      );
      if (model.isNotEmpty && model.first.assignedRoles.contains(role)) {
        return '${profile.displayName}（当前使用）';
      }
    }
    for (final profile in configured.where((profile) => !profile.enabled)) {
      if (profile.assignedRoles.contains(role)) {
        return '${profile.displayName}（已分配，已停用）';
      }
      final modelPath = profile.modelPath?.toLowerCase();
      if (modelPath == null) continue;
      final model = discovered.where(
        (candidate) => candidate.path.toLowerCase() == modelPath,
      );
      if (model.isNotEmpty && model.first.assignedRoles.contains(role)) {
        return '${profile.displayName}（已分配，已停用）';
      }
    }
    for (final model in discovered) {
      if (model.assignedRoles.contains(role)) {
        return _isBundledCandidate(model)
            ? '${model.displayName}（随包默认）'
            : '${model.displayName}（候选，尚未接入）';
      }
    }
    return fallback;
  }
}

ModelCatalogEntryData _catalogFromCandidate(ModelCandidate model) =>
    ModelCatalogEntryData(
      id: model.catalogId ?? _catalogId(model),
      path: model.path,
      displayName: model.displayName,
      family: switch (model.family) {
        ModelFamily.yixueTranslation => 'yixue_translation',
        _ => model.family.name,
      },
      readiness: switch (model.readiness) {
        ModelReadiness.readyToValidate => 'ready_to_validate',
        ModelReadiness.runtimeRequired => 'runtime_required',
        ModelReadiness.incomplete => 'incomplete',
      },
      capabilities: model.capabilities
          .map(
            (capability) => switch (capability) {
              ModelCapability.generalText => 'general_text',
              ModelCapability.speechRecognition => 'speech_recognition',
              ModelCapability.speechSynthesis => 'speech_synthesis',
              _ => capability.name,
            },
          )
          .toList(growable: false),
      assignedRoles: model.assignedRoles
          .map((role) => role.wireName)
          .toList(growable: false),
      sourceLanguage: model.sourceLanguage,
      targetLanguage: model.targetLanguage,
    );

bool? _translationModelDirection({
  required ModelCandidate? model,
  required String? path,
  required String source,
  required String target,
}) {
  final expectedDirections = TranslationDirection.values.where(
    (direction) =>
        direction.sourceLanguage == source &&
        direction.targetLanguage == target,
  );
  if (expectedDirections.length != 1) return false;
  final expected = expectedDirections.single;
  final modelSource = canonicalSupportedLanguageCode(model?.sourceLanguage);
  final modelTarget = canonicalSupportedLanguageCode(model?.targetLanguage);
  if (modelSource != null || modelTarget != null) {
    return modelSource == expected.sourceLanguageCode &&
        modelTarget == expected.targetLanguageCode &&
        !(expected.targetLanguageCode == 'zh' &&
            isTraditionalChineseLanguageTag(model?.targetLanguage));
  }

  final directions = [
    for (final direction in TranslationDirection.values)
      (
        sourceCode: direction.sourceLanguageCode,
        targetCode: direction.targetLanguageCode,
        source: direction.sourceLanguage,
        target: direction.targetLanguage,
      ),
  ];
  final normalizedPath = path?.toLowerCase();
  if (normalizedPath == null) return null;
  final hintedDirections = directions.where(
    (direction) => normalizedPath.contains(
      '${direction.sourceCode}-${direction.targetCode}',
    ),
  );
  if (hintedDirections.isEmpty) return null;
  return hintedDirections.any(
    (direction) => direction.source == source && direction.target == target,
  );
}

ModelCandidate _candidateFromCatalog(ModelCatalogEntryData entry) =>
    ModelCandidate(
      catalogId: entry.id,
      path: entry.path,
      displayName: entry.displayName,
      family: switch (entry.family) {
        'yixue_translation' => ModelFamily.yixueTranslation,
        'qwen' => ModelFamily.qwen,
        'transformers' => ModelFamily.transformers,
        'gguf' => ModelFamily.gguf,
        'onnx' => ModelFamily.onnx,
        'ollama' => ModelFamily.ollama,
        _ => ModelFamily.transformers,
      },
      readiness: switch (entry.readiness) {
        'ready_to_validate' => ModelReadiness.readyToValidate,
        'incomplete' => ModelReadiness.incomplete,
        _ => ModelReadiness.runtimeRequired,
      },
      capabilities: entry.capabilities
          .map(
            (value) => switch (value) {
              'general_text' => ModelCapability.generalText,
              'speech_recognition' => ModelCapability.speechRecognition,
              'speech_synthesis' => ModelCapability.speechSynthesis,
              'translation' => ModelCapability.translation,
              'summarization' => ModelCapability.summarization,
              'embedding' => ModelCapability.embedding,
              _ => ModelCapability.classification,
            },
          )
          .toSet(),
      assignedRoles: entry.assignedRoles
          .map(ModelRole.fromWireName)
          .whereType<ModelRole>()
          .toSet(),
      pathAvailable:
          Directory(entry.path).existsSync() || File(entry.path).existsSync(),
      sourceLanguage: entry.sourceLanguage,
      targetLanguage: entry.targetLanguage,
    );

String _catalogId(ModelCandidate model) {
  var hash = 0x811C9DC5;
  final value = '${model.family.name}|${model.path.toLowerCase()}';
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return 'catalog.${model.family.name}.${hash.toRadixString(16).padLeft(8, '0')}';
}

class _RoleItem extends StatelessWidget {
  const _RoleItem({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: actionLabel == null ? 190 : 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: const Color(0xFFB9E4D8)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      detail,
                      style: const TextStyle(
                        color: Color(0xFFC9D8D5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (actionLabel != null && onAction != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4),
              child: TextButton.icon(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFB9E4D8),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 15),
                label: Text(actionLabel!),
              ),
            ),
        ],
      ),
    );
  }
}

String _capabilityLabel(ModelCapability capability) => switch (capability) {
  ModelCapability.translation => '翻译',
  ModelCapability.generalText => '通用文本',
  ModelCapability.summarization => '总结',
  ModelCapability.speechRecognition => '语音识别',
  ModelCapability.speechSynthesis => '语音合成',
  ModelCapability.embedding => '向量检索',
  ModelCapability.classification => '文本分类',
};

class _ModelEvaluationItemCard extends StatelessWidget {
  const _ModelEvaluationItemCard({required this.item});

  final ModelEvaluationItem item;

  @override
  Widget build(BuildContext context) {
    final statusColor = item.passed ? Colors.green : Colors.red;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  item.passed
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  color: statusColor,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(item.id)),
                Text('${item.elapsed.inMilliseconds} ms'),
              ],
            ),
            const SizedBox(height: 5),
            Text('原文：${item.source}'),
            const SizedBox(height: 3),
            Text('模型译文：${item.translated}'),
            if (item.references.isNotEmpty) ...[
              const SizedBox(height: 6),
              const Text('参考译文（仅供人工对照）：'),
              for (final reference in item.references)
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 2),
                  child: Text(reference),
                ),
              const SizedBox(height: 3),
              Text(
                item.referenceMatch
                    ? '参考文本：与其中一条参考译文完全一致（仅为规范化字符串比较）'
                    : '参考文本：未完全一致（需要人工判断语义与表达质量）',
                style: TextStyle(
                  color: item.referenceMatch ? Colors.green : Colors.orange,
                  fontSize: 12,
                ),
              ),
            ],
            if (item.errorCode != null) Text('失败原因：${item.errorCode}'),
            if (!item.formattingValid) const Text('格式：关键片段未完整保留'),
            if (!item.outputValid && item.errorCode == null)
              const Text('输出：疑似元话术、原文未翻译或重复异常'),
          ],
        ),
      ),
    );
  }
}

enum _ConfiguredProviderAction { test, trial, evaluate, edit, delete }

class _ProviderTile extends StatelessWidget {
  const _ProviderTile(
    this.profile, {
    required this.currentTranslation,
    required this.catalogTranslationFallback,
    this.onSelect,
    required this.supportedRoles,
    required this.onToggleRole,
    required this.onDelete,
    required this.onEdit,
    required this.onTest,
    required this.onTrial,
    required this.onEvaluate,
    required this.testing,
    required this.trialing,
    required this.evaluating,
    this.understandingUsageFocusAnchorKey,
  });

  final ProviderProfileData profile;
  final bool currentTranslation;
  final bool catalogTranslationFallback;
  final ValueChanged<ProviderProfileData>? onSelect;
  final Set<ModelRole> supportedRoles;
  final void Function(ProviderProfileData, ModelRole) onToggleRole;
  final Future<void> Function(ProviderProfileData) onDelete;
  final Future<void> Function(ProviderProfileData) onEdit;
  final Future<void> Function(ProviderProfileData) onTest;
  final Future<void> Function(ProviderProfileData) onTrial;
  final Future<void> Function(ProviderProfileData) onEvaluate;
  final bool testing;
  final bool trialing;
  final bool evaluating;
  final GlobalKey? understandingUsageFocusAnchorKey;

  @override
  Widget build(BuildContext context) {
    final isLocal = profile.kind == ProviderProfileKind.localModel;
    return Card(
      key: ValueKey(profile.id),
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFD7DFDC)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 6),
              leading: Icon(
                isLocal ? Icons.computer_rounded : Icons.cloud_done_outlined,
                color: const Color(0xFF183D38),
              ),
              title: Text(
                profile.displayName,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${profile.modelId}  ·  ${isLocal
                    ? (profile.enabled ? '已校验' : '待校验')
                    : isLocalCompatibleEndpoint(profile.endpoint)
                    ? '本地接口'
                    : '密钥已保护'}',
              ),
              trailing: currentTranslation
                  ? const Chip(label: Text('当前翻译'))
                  : catalogTranslationFallback
                  ? const Chip(label: Text('按语种匹配'))
                  : null,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 2,
                children: [
                  if (!currentTranslation)
                    TextButton(
                      onPressed: onSelect == null
                          ? null
                          : () => onSelect!(profile),
                      child: const Text('设为翻译'),
                    ),
                  if (supportedRoles.isNotEmpty)
                    KeyedSubtree(
                      key: understandingUsageFocusAnchorKey,
                      child: PopupMenuButton<ModelRole>(
                        key: ValueKey('provider-roles-${profile.id}'),
                        tooltip: '设置已接入模型用途',
                        onSelected: (role) => onToggleRole(profile, role),
                        itemBuilder: (_) => supportedRoles
                            .map(
                              (role) => PopupMenuItem(
                                value: role,
                                child: Row(
                                  children: [
                                    Icon(
                                      profile.assignedRoles.contains(role)
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(role.label),
                                  ],
                                ),
                              ),
                            )
                            .toList(growable: false),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Text('设置用途'),
                        ),
                      ),
                    ),
                  PopupMenuButton<_ConfiguredProviderAction>(
                    key: ValueKey('provider-actions-${profile.id}'),
                    tooltip: '模型更多操作',
                    onSelected: (action) {
                      switch (action) {
                        case _ConfiguredProviderAction.test:
                          onTest(profile);
                          break;
                        case _ConfiguredProviderAction.trial:
                          onTrial(profile);
                          break;
                        case _ConfiguredProviderAction.evaluate:
                          onEvaluate(profile);
                          break;
                        case _ConfiguredProviderAction.edit:
                          onEdit(profile);
                          break;
                        case _ConfiguredProviderAction.delete:
                          onDelete(profile);
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      if (!isLocal)
                        const PopupMenuItem(
                          value: _ConfiguredProviderAction.test,
                          child: _ProviderMenuLabel(
                            icon: Icons.wifi_tethering_outlined,
                            label: '测试连接',
                          ),
                        ),
                      if (!isLocal || profile.enabled)
                        PopupMenuItem(
                          value: _ConfiguredProviderAction.trial,
                          enabled: !trialing,
                          child: _ProviderMenuLabel(
                            icon: Icons.play_circle_outline_rounded,
                            label: trialing ? '能力试跑中…' : '能力试跑',
                          ),
                        ),
                      if (profile.enabled)
                        PopupMenuItem(
                          value: _ConfiguredProviderAction.evaluate,
                          enabled: !evaluating,
                          child: _ProviderMenuLabel(
                            icon: Icons.assessment_outlined,
                            label: evaluating ? '固定集评测中…' : '固定集评测',
                          ),
                        ),
                      if (!isLocal)
                        const PopupMenuItem(
                          value: _ConfiguredProviderAction.edit,
                          child: _ProviderMenuLabel(
                            icon: Icons.edit_outlined,
                            label: '编辑配置',
                          ),
                        ),
                      const PopupMenuItem(
                        value: _ConfiguredProviderAction.delete,
                        child: _ProviderMenuLabel(
                          icon: Icons.delete_outline_rounded,
                          label: '删除配置',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderMenuLabel extends StatelessWidget {
  const _ProviderMenuLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
  );
}

class _LocalProviderDraft {
  const _LocalProviderDraft({required this.modelPath});

  final String modelPath;
}

class _AddLocalProviderDialog extends StatefulWidget {
  const _AddLocalProviderDialog({required this.directoryPicker});

  final Future<String?> Function() directoryPicker;

  @override
  State<_AddLocalProviderDialog> createState() =>
      _AddLocalProviderDialogState();
}

class _AddLocalProviderDialogState extends State<_AddLocalProviderDialog> {
  final _formKey = GlobalKey<FormState>();
  final _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '请填写此项' : null;

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context)
        .pop(_LocalProviderDraft(modelPath: _path.text.trim()));
  }

  Future<void> _browse() async {
    final selected = await widget.directoryPicker();
    if (selected != null && mounted) _path.text = selected;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择本地模型'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _path,
                  validator: _required,
                  decoration: const InputDecoration(
                    labelText: '模型文件夹',
                    hintText: r'D:\models\opus-mt-en-zh',
                  ),
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: _browse,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('浏览'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('识别并添加')),
      ],
    );
  }
}

ModelPackageValidationData _validateModelPackage(String modelPath) {
  final core = NativeCoreBridge.open();
  try {
    return (core as ModelPackageCore).validateModelPackage(modelPath);
  } finally {
    core.dispose();
  }
}

class _RemoteProviderDraft {
  const _RemoteProviderDraft({
    required this.id,
    required this.displayName,
    required this.endpoint,
    required this.modelId,
    required this.apiKey,
  });

  final String id;
  final String displayName;
  final String endpoint;
  final String modelId;
  final String apiKey;
}

class _AddRemoteProviderDialog extends StatefulWidget {
  const _AddRemoteProviderDialog({
    this.existing,
    this.suggestedName,
    this.suggestedModel,
    this.suggestedEndpoint,
  });

  final ProviderProfileData? existing;
  final String? suggestedName;
  final String? suggestedModel;
  final String? suggestedEndpoint;

  @override
  State<_AddRemoteProviderDialog> createState() =>
      _AddRemoteProviderDialogState();
}

class _AddRemoteProviderDialogState extends State<_AddRemoteProviderDialog> {
  final _formKey = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _endpoint = TextEditingController(text: 'https://api.openai.com/v1');
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  late final String _generatedIdSuffix;
  var _idCustomized = false;

  @override
  void initState() {
    super.initState();
    _generatedIdSuffix = DateTime.now().microsecondsSinceEpoch.toRadixString(
      36,
    );
    final existing = widget.existing;
    if (existing != null) {
      _id.text = existing.id;
      _name.text = existing.displayName;
      _endpoint.text = existing.endpoint ?? '';
      _model.text = existing.modelId;
    } else {
      _name.text = widget.suggestedName ?? '';
      _model.text = widget.suggestedModel ?? '';
      _endpoint.text = widget.suggestedEndpoint ?? _endpoint.text;
      if (widget.suggestedModel != null) {
        _id.text = _suggestedProviderId(widget.suggestedModel!);
        _idCustomized = true;
      } else {
        _id.text = _generatedApiProviderId('', _generatedIdSuffix);
      }
    }
  }

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _endpoint.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  String? _required(String? value) {
    return value == null || value.trim().isEmpty ? '请填写此项' : null;
  }

  String? _credentialValidator(String? value) {
    if (value != null && value.trim().isNotEmpty) return null;
    if (isLocalCompatibleEndpoint(_endpoint.text)) return null;
    return '远程 API 必须填写密钥；本地回环接口可以留空';
  }

  void _submit() {
    if (_id.text.trim().isEmpty) {
      _id.text = _generatedApiProviderId(_name.text, _generatedIdSuffix);
    }
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      _RemoteProviderDraft(
        id: _id.text.trim(),
        displayName: _name.text.trim(),
        endpoint: _endpoint.text.trim(),
        modelId: _model.text.trim(),
        apiKey: _apiKey.text.trim(),
      ),
    );
  }

  void _updateGeneratedId(String name) {
    if (_idCustomized ||
        widget.existing != null ||
        widget.suggestedModel != null) {
      return;
    }
    _id.text = _generatedApiProviderId(name, _generatedIdSuffix);
  }

  Widget _endpointNotice(BuildContext context) {
    return AnimatedBuilder(
      animation: _endpoint,
      builder: (context, _) {
        final isLocal = isLocalCompatibleEndpoint(_endpoint.text);
        final colors = Theme.of(context).colorScheme;
        final activationCopy = widget.existing == null
            ? '新配置保存后仍停用'
            : '保存不会改变当前启用状态';
        return Container(
          key: ValueKey(
            isLocal ? 'local-compatible-guidance' : 'remote-service-disclosure',
          ),
          width: double.infinity,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isLocal
                ? const Color(0xFFEAF5F2)
                : colors.tertiaryContainer.withValues(alpha: .58),
            border: Border.all(
              color: isLocal
                  ? const Color(0xFFCCE1DB)
                  : colors.tertiary.withValues(alpha: .25),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isLocal ? Icons.computer_rounded : Icons.cloud_outlined,
                size: 18,
                color: isLocal ? colors.primary : colors.tertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isLocal
                      ? '本机回环服务可不填 API 密钥。译学会把请求交给该地址上的本机服务；默认限制为 2,048 上下文、64 批量以降低内存占用。$activationCopy，服务不可用时不会自动切换到云端。'
                      : '非本机回环地址按远程服务处理。若这是云端 API，你提交的翻译文本会发送给服务商。连接测试会访问该地址，短句试跑会发送固定样例。$activationCopy，服务失败时不会自动切换。',
                  key: ValueKey(
                    isLocal
                        ? 'local-compatible-guidance-copy'
                        : 'remote-service-disclosure-copy',
                  ),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加 API 模型' : '编辑 API 模型'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  validator: _required,
                  decoration: const InputDecoration(labelText: '显示名称'),
                  onChanged: _updateGeneratedId,
                ),
                ExpansionTile(
                  key: const ValueKey('provider-presets'),
                  initiallyExpanded: false,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('服务预设（可选）'),
                  subtitle: const Text('展开后预填常用服务地址和模型 ID'),
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          '也可以直接填写服务地址、模型 ID 和密钥。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _presetButton(
                          const RemoteProviderPreset(
                            id: 'local-ollama',
                            label: '使用本地 Ollama',
                            displayName: '本地 Ollama',
                            endpoint: 'http://127.0.0.1:11434/api',
                            modelId: '',
                            description: '本地 Ollama 原生接口',
                          ),
                          Icons.memory_rounded,
                        ),
                        for (final preset in remoteProviderPresets)
                          _presetButton(
                            preset,
                            preset.id == 'deepseek-api'
                                ? Icons.cloud_outlined
                                : Icons.tune_rounded,
                          ),
                      ],
                    ),
                  ],
                ),
                TextFormField(
                  controller: _endpoint,
                  validator: _required,
                  decoration: const InputDecoration(
                    labelText: 'API 地址',
                    helperText:
                        '填写服务方提供的 OpenAI 兼容地址；本机服务可填写 localhost 或 127.0.0.1。',
                  ),
                ),
                _endpointNotice(context),
                TextFormField(
                  controller: _model,
                  validator: _required,
                  decoration: const InputDecoration(labelText: '模型 ID'),
                ),
                TextFormField(
                  controller: _apiKey,
                  validator: widget.existing == null
                      ? _credentialValidator
                      : null,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'API 密钥',
                    hintText: widget.existing == null
                        ? '远程必填；本地回环接口可留空'
                        : '留空以保留当前密钥',
                  ),
                  onFieldSubmitted: (_) => _submit(),
                ),
                ExpansionTile(
                  key: const ValueKey('provider-advanced-options'),
                  initiallyExpanded: false,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('高级设置'),
                  subtitle: const Text('配置 ID 自动生成，通常无需修改'),
                  children: [
                    TextFormField(
                      controller: _id,
                      readOnly: widget.existing != null,
                      onChanged: (_) => _idCustomized = true,
                      decoration: const InputDecoration(
                        labelText: '配置 ID',
                        helperText: '用于区分本机保存的服务配置和密钥。',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.existing == null ? '保存并保持停用' : '保存修改'),
        ),
      ],
    );
  }

  Widget _presetButton(RemoteProviderPreset preset, IconData icon) {
    return OutlinedButton.icon(
      // Keep the local Ollama key stable for UI automation and future deep links.
      // The persisted provider id remains `local-ollama` for compatibility.
      key: ValueKey(
        preset.id == 'local-ollama' ? 'use-ollama-local' : 'use-${preset.id}',
      ),
      onPressed: () {
        setState(() {
          _idCustomized = true;
          _endpoint.text = preset.endpoint;
          _name.text = preset.displayName;
          _id.text = preset.id;
          _model.text = preset.modelId;
        });
      },
      icon: Icon(icon, size: 18),
      label: Text(preset.label),
    );
  }
}

String _suggestedProviderId(String modelName) {
  final normalized = modelName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final value = 'local-${normalized.isEmpty ? 'ollama' : normalized}';
  return value.length <= 64 ? value : value.substring(0, 64);
}

String _generatedApiProviderId(String displayName, String suffix) {
  final normalized = displayName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final stem = normalized.isEmpty ? 'provider' : normalized;
  final maxStemLength = 59 - suffix.length;
  final safeStem = stem.length <= maxStemLength
      ? stem
      : stem.substring(0, maxStemLength).replaceAll(RegExp(r'-+$'), '');
  return 'api-$safeStem-$suffix';
}

class _CoreStatusCard extends StatelessWidget {
  const _CoreStatusCard({required this.health});

  final Future<CoreHealth> health;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF183D38),
        border: Border.all(color: const Color(0xFF315B54)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: FutureBuilder<CoreHealth>(
          future: health,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _CoreStatus(
                icon: Icons.sync_rounded,
                title: '正在连接本地核心…',
                detail: '正在检查数据与模型服务',
                color: Colors.white,
              );
            }
            if (snapshot.hasError) {
              return const _CoreStatus(
                icon: Icons.warning_amber_rounded,
                title: '本地核心未连接',
                detail: '请使用项目构建脚本重新打包 Rust DLL。',
                color: Color(0xFFFFC8B5),
              );
            }
            final value = snapshot.requireData;
            return _CoreStatus(
              icon: Icons.verified_user_outlined,
              title: '本地核心已连接',
              detail: '核心 ${value.coreVersion}  ·  协议 v${value.schemaVersion}',
              color: const Color(0xFFB9E4D8),
            );
          },
        ),
      ),
    );
  }
}

class _CoreStatus extends StatelessWidget {
  const _CoreStatus({
    required this.icon,
    required this.title,
    required this.detail,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(detail, style: const TextStyle(color: Color(0xFFC9D8D5))),
            ],
          ),
        ),
      ],
    );
  }
}
