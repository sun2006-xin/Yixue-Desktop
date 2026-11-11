import 'dart:convert';
import 'dart:io';

enum ModelFamily { yixueTranslation, qwen, transformers, gguf, onnx, ollama }

enum ModelReadiness { readyToValidate, runtimeRequired, incomplete }

enum ModelCapability {
  translation,
  generalText,
  summarization,
  speechRecognition,
  speechSynthesis,
  embedding,
  classification,
}

enum ModelRole {
  translation('translation', '翻译'),
  understanding('understanding', '理解与总结'),
  speechRecognition('speech_recognition', '语音识别'),
  speechSynthesis('speech_synthesis', '语音合成');

  const ModelRole(this.wireName, this.label);
  final String wireName;
  final String label;

  static ModelRole? fromWireName(String value) {
    for (final role in values) {
      if (role.wireName == value) return role;
    }
    return null;
  }
}

class ModelCandidate {
  const ModelCandidate({
    required this.path,
    required this.displayName,
    required this.family,
    required this.readiness,
    required this.capabilities,
    this.assignedRoles = const {},
    this.pathAvailable = true,
    this.catalogId,
    this.sourceLanguage,
    this.targetLanguage,
  });

  final String path;
  final String displayName;
  final ModelFamily family;
  final ModelReadiness readiness;
  final Set<ModelCapability> capabilities;
  final Set<ModelRole> assignedRoles;
  final bool pathAvailable;
  final String? catalogId;
  final String? sourceLanguage;
  final String? targetLanguage;

  Set<ModelRole> get supportedRoles => <ModelRole>{
    if (capabilities.contains(ModelCapability.translation))
      ModelRole.translation,
    if (capabilities.contains(ModelCapability.generalText) ||
        capabilities.contains(ModelCapability.summarization))
      ModelRole.understanding,
    if (capabilities.contains(ModelCapability.speechRecognition))
      ModelRole.speechRecognition,
    if (capabilities.contains(ModelCapability.speechSynthesis))
      ModelRole.speechSynthesis,
  };

  ModelCandidate copyWith({
    Set<ModelRole>? assignedRoles,
    bool? pathAvailable,
    String? catalogId,
    String? sourceLanguage,
    String? targetLanguage,
  }) => ModelCandidate(
    path: path,
    displayName: displayName,
    family: family,
    readiness: readiness,
    capabilities: capabilities,
    assignedRoles: assignedRoles ?? this.assignedRoles,
    pathAvailable: pathAvailable ?? this.pathAvailable,
    catalogId: catalogId ?? this.catalogId,
    sourceLanguage: sourceLanguage ?? this.sourceLanguage,
    targetLanguage: targetLanguage ?? this.targetLanguage,
  );

  String get familyLabel => switch (family) {
    ModelFamily.yixueTranslation => '译学翻译包',
    ModelFamily.qwen => '千问 / Transformers',
    ModelFamily.transformers => 'Transformers',
    ModelFamily.gguf => 'GGUF',
    ModelFamily.onnx => 'ONNX',
    ModelFamily.ollama => 'Ollama 模型缓存',
  };

  String get readinessLabel => switch (readiness) {
    ModelReadiness.readyToValidate => '可校验并启用',
    ModelReadiness.runtimeRequired => '已发现 · 需接入运行内核',
    ModelReadiness.incomplete => '文件不完整',
  };

  String get availabilityLabel =>
      pathAvailable ? readinessLabel : '路径已失效 · 请重新扫描或移除记录';

  String get userMessage {
    if (!pathAvailable) {
      return '记录仍在本地，但模型路径已不存在；可以重新扫描，或移除这条记录。';
    }
    if (family == ModelFamily.qwen) {
      return '千问模型已经找到；当前安装包不会自动安装或启动 Ollama。只有本机已有兼容接口并通过能力试跑后，才能用于翻译、理解与总结；普通权重文件仍需对应运行内核。';
    }
    if (family == ModelFamily.ollama) {
      return '已找到 Ollama 模型缓存；当前安装包不会自动安装或启动 Ollama。只有本机已有兼容接口并通过能力试跑后，才能用于翻译或理解。';
    }
    if (readiness == ModelReadiness.readyToValidate) {
      return '模型已经找到，可以继续校验并启用。';
    }
    if (readiness == ModelReadiness.incomplete) {
      return '模型文件夹已经找到，但缺少权重或配置文件。';
    }
    return '模型已经找到；当前版本会先收录，接入对应运行内核后即可启用。';
  }
}

/// Discovers candidates without executing or loading model code.
///
/// Scans are bounded, do not follow links, and skip operating-system/build
/// folders. Discovery only catalogs a candidate. The Rust core still verifies
/// a Yixue package before it can be enabled.
class ModelPackageDiscoveryService {
  const ModelPackageDiscoveryService({
    this.maximumDepth = 8,
    this.maximumEntries = 60000,
    this.maximumResults = 128,
  });

  static const manifestName = 'yixue-model.json';
  static const _maximumConfigBytes = 2 * 1024 * 1024;
  static const _skippedDirectories = <String>{
    r'$recycle.bin',
    r'$winreagent',
    'system volume information',
    'windows',
    'program files',
    'program files (x86)',
    'programdata',
    'recovery',
    'node_modules',
    '.git',
    'target',
    'build',
    'dist',
  };

  final int maximumDepth;
  final int maximumEntries;
  final int maximumResults;

  Future<List<String>> discover(String rootPath) async {
    final models = await discoverModels([rootPath]);
    return List.unmodifiable(
      models
          .where((model) => model.family == ModelFamily.yixueTranslation)
          .map((model) => model.path),
    );
  }

  Future<List<ModelCandidate>> discoverModels(List<String> rootPaths) async {
    final results = <ModelCandidate>[];
    final seen = <String>{};
    final pending = <({Directory directory, int depth})>[];
    for (final rootPath in rootPaths) {
      final root = Directory(rootPath);
      if (await root.exists()) pending.add((directory: root, depth: 0));
    }

    var visitedEntries = 0;
    var cursor = 0;
    while (cursor < pending.length &&
        visitedEntries < maximumEntries &&
        results.length < maximumResults) {
      final current = pending[cursor++];
      try {
        final entries = <FileSystemEntity>[];
        await for (final entity in current.directory.list(followLinks: false)) {
          visitedEntries += 1;
          if (visitedEntries > maximumEntries) break;
          entries.add(entity);
          if (entity is Directory &&
              current.depth < maximumDepth &&
              !_shouldSkip(entity.path)) {
            pending.add((directory: entity, depth: current.depth + 1));
          }
        }
        final candidates = await _inspectEntries(current.directory, entries);
        for (final candidate in candidates) {
          final key =
              '${candidate.family.name}|${candidate.path.toLowerCase()}';
          if (seen.add(key)) results.add(candidate);
          if (results.length >= maximumResults) break;
        }
      } on FileSystemException {
        // Inaccessible folders are skipped without aborting a whole-drive scan.
      }
    }

    results.sort((left, right) => left.path.compareTo(right.path));
    return List.unmodifiable(results);
  }

  Future<ModelCandidate?> inspectDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return null;
    try {
      // A user will often select a model library (for example
      // `D:\\Models`) rather than the leaf folder that contains
      // `yixue-model.json` or `config.json`. Reuse the same bounded walker as
      // the all-disk scan so the picker and the scanner do not disagree.
      final candidates = await discoverModels([path]);
      if (candidates.isEmpty) return null;
      final orderedCandidates = List<ModelCandidate>.of(candidates)..sort(
        (left, right) => left.readiness.index.compareTo(right.readiness.index),
      );
      return orderedCandidates.first;
    } on FileSystemException {
      return null;
    }
  }

  Future<List<String>> availableDriveRoots() async {
    if (!Platform.isWindows) return <String>[Directory.current.path];
    final roots = <String>[];
    for (var code = 'C'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code += 1) {
      final path = '${String.fromCharCode(code)}:\\';
      try {
        if (await Directory(path).exists()) roots.add(path);
      } on FileSystemException {
        // Disconnected or inaccessible volumes are ignored.
      }
    }
    return List.unmodifiable(roots);
  }

  /// Returns likely model locations first, then drive roots for a bounded
  /// fallback scan. This prevents unrelated folders from using the whole entry
  /// budget before a custom model library is reached.
  Future<List<String>> recommendedSearchRoots() async {
    final drives = await availableDriveRoots();
    final candidates = <String>[
      ...[Platform.environment['OLLAMA_MODELS']].whereType<String>(),
      ...[Platform.environment['USERPROFILE']]
          .whereType<String>()
          .map((home) => '$home\\.ollama\\models'),
      for (final drive in drives) ...[
        '${drive}models',
        '${drive}Models',
        '${drive}OpenViking\\ollama-models',
        '${drive}AI',
        '${drive}LLM',
      ],
      ...drives,
    ];
    final roots = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      if (!seen.add(candidate.toLowerCase())) continue;
      try {
        if (await Directory(candidate).exists()) roots.add(candidate);
      } on FileSystemException {
        // Inaccessible suggested paths are ignored.
      }
    }
    return List.unmodifiable(roots);
  }

  Future<List<ModelCandidate>> _inspectEntries(
    Directory directory,
    List<FileSystemEntity> entries,
  ) async {
    final files = entries.whereType<File>().toList(growable: false);
    final names = <String, File>{
      for (final file in files) _nameOf(file.path).toLowerCase(): file,
    };
    final candidates = <ModelCandidate>[];

    if (names.containsKey(manifestName)) {
      candidates.add(
        ModelCandidate(
          path: directory.path,
          displayName: _displayName(directory.path),
          family: ModelFamily.yixueTranslation,
          readiness: ModelReadiness.readyToValidate,
          capabilities: const {ModelCapability.translation},
        ),
      );
      return candidates;
    }

    final ggufFiles = files
        .where((file) => file.path.toLowerCase().endsWith('.gguf'))
        .toList(growable: false);
    if (ggufFiles.isNotEmpty) {
      final displayName = ggufFiles.length == 1
          ? _withoutExtension(_nameOf(ggufFiles.single.path))
          : _displayName(directory.path);
      candidates.add(
        ModelCandidate(
          path: directory.path,
          displayName: displayName,
          family: ModelFamily.gguf,
          readiness: ModelReadiness.runtimeRequired,
          capabilities: _textCapabilities(displayName),
        ),
      );
    }

    final config = names['config.json'];
    if (config != null) {
      final metadata = await _readConfig(config);
      final modelType = (metadata?['model_type'] as String? ?? '')
          .toLowerCase();
      final architectures =
          (metadata?['architectures'] as List?)
              ?.whereType<String>()
              .join(' ')
              .toLowerCase() ??
          '';
      final isQwen =
          modelType.startsWith('qwen') || architectures.contains('qwen');
      final hasWeights = files.any((file) {
        final name = file.path.toLowerCase();
        return name.endsWith('.safetensors') ||
            name.endsWith('pytorch_model.bin') ||
            name.endsWith('model.bin');
      });
      if (isQwen || hasWeights) {
        candidates.add(
          ModelCandidate(
            path: directory.path,
            displayName: _displayName(directory.path),
            family: isQwen ? ModelFamily.qwen : ModelFamily.transformers,
            readiness: hasWeights
                ? ModelReadiness.runtimeRequired
                : ModelReadiness.incomplete,
            capabilities: _textCapabilities(directory.path),
          ),
        );
      }
    }

    final onnxFiles = files
        .where((file) => file.path.toLowerCase().endsWith('.onnx'))
        .toList(growable: false);
    if (onnxFiles.isNotEmpty) {
      final signature =
          '${directory.path} ${onnxFiles.map((file) => file.path).join(' ')}'
              .toLowerCase();
      final capabilities = <ModelCapability>{
        if (_containsAny(signature, const [
          'whisper',
          'asr',
          'speech-recognition',
        ]))
          ModelCapability.speechRecognition,
        if (_containsAny(signature, const ['tts', 'vits', 'speech-synthesis']))
          ModelCapability.speechSynthesis,
        if (_containsAny(signature, const [
          'opus-mt',
          'marian',
          'm2m100',
          'translation',
          'translate',
        ]))
          ModelCapability.translation,
      };
      if (capabilities.isNotEmpty) {
        candidates.add(
          ModelCandidate(
            path: directory.path,
            displayName: _displayName(directory.path),
            family: ModelFamily.onnx,
            readiness: ModelReadiness.runtimeRequired,
            capabilities: Set.unmodifiable(capabilities),
          ),
        );
      }
    }

    if (_isOllamaManifestPath(directory.path) && files.isNotEmpty) {
      for (final file in files) {
        final displayName = _ollamaDisplayName(file.path);
        candidates.add(
          ModelCandidate(
            path: file.path,
            displayName: displayName,
            family: ModelFamily.ollama,
            readiness: ModelReadiness.runtimeRequired,
            capabilities: _textCapabilities(displayName),
          ),
        );
      }
    }
    return candidates;
  }

  Future<Map<String, Object?>?> _readConfig(File file) async {
    try {
      if (await file.length() > _maximumConfigBytes) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  bool _shouldSkip(String path) =>
      _skippedDirectories.contains(_nameOf(path).toLowerCase());

  bool _containsAny(String value, List<String> needles) =>
      needles.any(value.contains);

  Set<ModelCapability> _textCapabilities(String name) {
    final normalized = name.toLowerCase();
    if (normalized.contains('embedding')) {
      return const {ModelCapability.embedding};
    }
    if (_containsAny(normalized, const ['intent', 'classifier', 'rerank'])) {
      return const {ModelCapability.classification};
    }
    final capabilities = <ModelCapability>{
      ModelCapability.generalText,
      ModelCapability.summarization,
    };
    if (_containsAny(normalized, const [
      'translate',
      'translation',
      'translator',
      'opus-mt',
      'marian',
      'm2m100',
      'nllb',
      'seamless-m4t',
    ])) {
      capabilities.add(ModelCapability.translation);
    }
    return Set.unmodifiable(capabilities);
  }

  bool _isOllamaManifestPath(String path) {
    final normalized = path.replaceAll('\\', '/').toLowerCase();
    return normalized.contains('/.ollama/models/manifests/') ||
        normalized.contains('/ollama-models/manifests/');
  }

  String _ollamaDisplayName(String path) {
    final parts = path.replaceAll('\\', '/').split('/');
    if (parts.length < 2) return _nameOf(path);
    return '${parts[parts.length - 2]}:${parts.last}';
  }

  String _displayName(String path) => _nameOf(path);

  String _withoutExtension(String name) {
    final index = name.lastIndexOf('.');
    return index <= 0 ? name : name.substring(0, index);
  }

  String _nameOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}
