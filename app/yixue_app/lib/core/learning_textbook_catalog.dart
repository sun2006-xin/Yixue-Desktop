import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const learningTextbookSchemaVersion = 1;

enum LearningTextbookOrigin {
  selfAuthored('self_authored', '译学自写'),
  openLicense('open_license', '开放许可'),
  userImported('user_imported', '用户本地导入'),
  externalReference('external_reference', '外部参考');

  const LearningTextbookOrigin(this.wireName, this.label);

  final String wireName;
  final String label;

  static LearningTextbookOrigin fromWire(Object? raw) => values.firstWhere(
    (item) => item.wireName == raw,
    orElse: () => throw const FormatException('教材来源类型无效'),
  );
}

class LearningTextbookLessonData {
  const LearningTextbookLessonData({
    required this.id,
    required this.title,
    required this.sourceText,
    required this.translation,
    required this.vocabulary,
  });

  final String id;
  final String title;
  final String sourceText;
  final String translation;
  final List<String> vocabulary;

  LearningTextbookLessonData copyWith({
    String? translation,
    List<String>? vocabulary,
  }) => LearningTextbookLessonData(
    id: id,
    title: title,
    sourceText: sourceText,
    translation: translation ?? this.translation,
    vocabulary: vocabulary ?? this.vocabulary,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'source_text': sourceText,
    'translation': translation,
    'vocabulary': vocabulary,
  };

  factory LearningTextbookLessonData.fromJson(Map<String, dynamic> json) {
    final vocabulary = json['vocabulary'];
    if (vocabulary != null &&
        (vocabulary is! List ||
            vocabulary.any((item) => item is! String || item.trim().isEmpty))) {
      throw const FormatException('教材课次词汇格式无效');
    }
    final words = (vocabulary as List<dynamic>? ?? const <dynamic>[])
        .cast<String>()
        .map((item) => item.trim())
        .toSet()
        .toList(growable: false);
    if (words.length > 1000 || words.any((item) => item.length > 120)) {
      throw const FormatException('教材课次词汇数量或长度超限');
    }
    return LearningTextbookLessonData(
      id: _text(json['id'], '教材课次 ID', maxLength: 160),
      title: _text(json['title'], '教材课次标题', maxLength: 300),
      sourceText: _preservedText(
        json['source_text'],
        '教材课次原文',
        maxLength: 20000,
      ),
      translation: _optionalText(
        json['translation'],
        '教材课次译文',
        maxLength: 100000,
      ),
      vocabulary: List.unmodifiable(words),
    );
  }
}

class LearningTextbookPackageData {
  const LearningTextbookPackageData({
    required this.id,
    required this.title,
    required this.ageBand,
    required this.level,
    required this.version,
    required this.language,
    required this.licenseName,
    required this.licenseUrl,
    required this.rightsHolder,
    required this.sourceUrl,
    required this.redistributionAllowed,
    required this.origin,
    required this.lessons,
    required this.importedAt,
    required this.importedFrom,
  });

  final String id;
  final String title;
  final String ageBand;
  final String level;
  final String version;
  final String language;
  final String licenseName;
  final String licenseUrl;
  final String rightsHolder;
  final String sourceUrl;
  final bool redistributionAllowed;
  final LearningTextbookOrigin origin;
  final List<LearningTextbookLessonData> lessons;
  final String importedAt;
  final String importedFrom;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningTextbookSchemaVersion,
    'id': id,
    'title': title,
    'age_band': ageBand,
    'level': level,
    'version': version,
    'language': language,
    'license_name': licenseName,
    'license_url': licenseUrl,
    'rights_holder': rightsHolder,
    'source_url': sourceUrl,
    'redistribution_allowed': redistributionAllowed,
    'origin': origin.wireName,
    'lessons': [for (final lesson in lessons) lesson.toJson()],
    'imported_at': importedAt,
    'imported_from': importedFrom,
  };

  factory LearningTextbookPackageData.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != learningTextbookSchemaVersion) {
      throw const FormatException('教材包版本不受支持');
    }
    final rawLessons = json['lessons'];
    if (rawLessons is! List || rawLessons.isEmpty || rawLessons.length > 200) {
      throw const FormatException('教材包至少需要一个课次，且课次数量不能超过 200');
    }
    final lessons = [
      for (final raw in rawLessons)
        if (raw is Map<String, dynamic>)
          LearningTextbookLessonData.fromJson(raw)
        else
          throw const FormatException('教材课次必须是对象'),
    ];
    if (lessons.map((item) => item.id).toSet().length != lessons.length) {
      throw const FormatException('教材包包含重复课次 ID');
    }
    final importedAt = _text(json['imported_at'], '教材导入时间', maxLength: 80);
    if (DateTime.tryParse(importedAt) == null) {
      throw const FormatException('教材导入时间无效');
    }
    final importedFrom = _optionalText(
      json['imported_from'],
      '教材导入文件名',
      maxLength: 240,
    );
    return LearningTextbookPackageData(
      id: _text(json['id'], '教材包 ID', maxLength: 160),
      title: _text(json['title'], '教材名称', maxLength: 300),
      ageBand: _text(json['age_band'], '教材适用年龄段', maxLength: 100),
      level: _text(json['level'], '教材学段', maxLength: 100),
      version: _text(json['version'], '教材版本', maxLength: 200),
      language: _text(json['language'], '教材语言', maxLength: 32),
      licenseName: _text(json['license_name'], '教材许可证', maxLength: 300),
      licenseUrl: _url(json['license_url'], '教材许可证链接'),
      rightsHolder: _text(json['rights_holder'], '教材权利人或来源', maxLength: 300),
      sourceUrl: _url(json['source_url'], '教材来源链接'),
      redistributionAllowed: _bool(json['redistribution_allowed'], '教材再分发许可'),
      origin: LearningTextbookOrigin.fromWire(json['origin']),
      lessons: List.unmodifiable(lessons),
      importedAt: importedAt,
      importedFrom: importedFrom,
    );
  }

  LearningTextbookPackageData copyWith({
    String? importedAt,
    String? importedFrom,
    List<LearningTextbookLessonData>? lessons,
  }) => LearningTextbookPackageData(
    id: id,
    title: title,
    ageBand: ageBand,
    level: level,
    version: version,
    language: language,
    licenseName: licenseName,
    licenseUrl: licenseUrl,
    rightsHolder: rightsHolder,
    sourceUrl: sourceUrl,
    redistributionAllowed: redistributionAllowed,
    origin: origin,
    lessons: lessons ?? this.lessons,
    importedAt: importedAt ?? this.importedAt,
    importedFrom: importedFrom ?? this.importedFrom,
  );
}

class LearningTextbookReferenceData {
  const LearningTextbookReferenceData({
    required this.id,
    required this.title,
    required this.ageBand,
    required this.level,
    required this.version,
    required this.description,
    required this.status,
  });

  final String id;
  final String title;
  final String ageBand;
  final String level;
  final String version;
  final String description;
  final String status;
}

/// These are empty, honest entry points for future lawful course packages.
/// They describe the learning scope without copying a publisher's textbook.
const learningTextbookReferences = <LearningTextbookReferenceData>[
  LearningTextbookReferenceData(
    id: 'primary-textbooks',
    title: '小学英语教材',
    ageBand: '小学',
    level: 'primary',
    version: '不同地区与版本',
    description: '导入你所在地区和学校允许使用的课本或自制课程包。',
    status: '等待用户合法导入',
  ),
  LearningTextbookReferenceData(
    id: 'middle-textbooks',
    title: '初中英语教材',
    ageBand: '初中',
    level: 'middle',
    version: '不同地区与版本',
    description: '按地区、出版社和册次分别导入，避免把版本混在一起。',
    status: '等待用户合法导入',
  ),
  LearningTextbookReferenceData(
    id: 'high-textbooks',
    title: '高中英语教材',
    ageBand: '高中',
    level: 'high',
    version: '不同地区与版本',
    description: '支持按单元组织原文、译文和词汇，服务高考与进阶阅读。',
    status: '等待用户合法导入',
  ),
  LearningTextbookReferenceData(
    id: 'cet-textbooks',
    title: '四六级词汇与阅读',
    ageBand: '大学英语',
    level: 'cet4/cet6',
    version: '用户自定义版本',
    description: '可导入公开许可或自行制作的词表、例句和阅读材料。',
    status: '等待用户合法导入',
  ),
  LearningTextbookReferenceData(
    id: 'graduate-textbooks',
    title: '考研考博与学术英语',
    ageBand: '高阶学习',
    level: 'graduate/doctoral',
    version: '用户自定义版本',
    description: '适合学术阅读、术语积累和文章总结训练。',
    status: '等待用户合法导入',
  ),
  LearningTextbookReferenceData(
    id: 'social-textbooks',
    title: '社会人士与职场英语',
    ageBand: '社会与工作',
    level: 'social',
    version: '用户自定义版本',
    description: '可按职业、场景和个人目标建立自己的课程。',
    status: '等待用户合法导入',
  ),
];

class LearningTextbookPackageException implements Exception {
  const LearningTextbookPackageException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LearningTextbookPackageService {
  const LearningTextbookPackageService();

  static const maxPackageBytes = 50 * 1024 * 1024;
  static const maxStoreBytes = 64 * 1024 * 1024;
  static const maxDocumentLessonCharacters = 4000;
  static const maxDocumentLessons = 200;
  static const maxDocumentCharacters =
      maxDocumentLessonCharacters * maxDocumentLessons;
  static const _placeholderLicense = '请填写真实许可证或授权说明';

  /// Splits text without dropping separators or dividing a UTF-16 surrogate
  /// pair. When possible, a chunk ends at the latest line or word boundary
  /// within its final 35% so imported lessons and translation requests use the
  /// same predictable limits.
  static List<String> splitTextPreservingBoundaries(
    String text, {
    required int maxCharacters,
  }) {
    if (maxCharacters < 2) {
      throw ArgumentError.value(
        maxCharacters,
        'maxCharacters',
        'Must be at least 2.',
      );
    }

    final chunks = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = (start + maxCharacters).clamp(0, text.length);
      if (end < text.length) {
        final minimumBoundary = start + (maxCharacters * 0.65).round();
        var preferredBoundary = -1;
        for (final separator in const ['\n', '\r', ' ', '\t']) {
          final boundary = text.lastIndexOf(separator, end - 1);
          if (boundary >= minimumBoundary && boundary + 1 > preferredBoundary) {
            preferredBoundary = boundary + 1;
          }
        }
        if (preferredBoundary > start) end = preferredBoundary;
        if (_splitsSurrogatePair(text, end)) end--;
      }
      chunks.add(text.substring(start, end));
      start = end;
    }
    return List.unmodifiable(chunks);
  }

  static bool _splitsSurrogatePair(String text, int boundary) =>
      boundary > 0 &&
      boundary < text.length &&
      _isHighSurrogate(text.codeUnitAt(boundary - 1)) &&
      _isLowSurrogate(text.codeUnitAt(boundary));

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  static const templateJson = '''{
  "schema_version": 1,
  "id": "my-textbook.en-zh",
  "title": "我的英语教材",
  "age_band": "初中",
  "level": "middle",
  "version": "地区或出版社版本",
  "language": "en-zh",
  "license_name": "请填写真实许可证或授权说明",
  "license_url": "",
  "rights_holder": "请填写权利人或来源",
  "source_url": "",
  "redistribution_allowed": false,
  "lessons": [
    {
      "id": "unit-1",
      "title": "第一单元",
      "source_text": "A short lesson text.",
      "translation": "一段课文译文。",
      "vocabulary": ["lesson", "text"]
    }
  ]
}''';

  static const importGuidance = '''教材导入支持：
1. 标准教材包：UTF-8 JSON，或 ZIP 内包含 learning-textbook.json；每个课次包含原文，可选译文和词汇。
2. 当前支持 UTF-8 TXT 和 Markdown；DOCX、PDF 尚未接入教材导入。导入时需要补充学段、版本、许可证和权利人。
3. 网上能看到不等于可以复制或再分发。商业出版社教材只在你拥有合法使用权时导入；软件只保存在你的本地资料库，不会自动上传或随安装包发布。
4. 单个文件不超过 50 MB，TXT/Markdown 最多拆成 200 节、每节约 4000 字；超长资料请按章节拆分后导入。软件不会执行文件中的代码，也不会自动联网下载教材。''';

  LearningTextbookPackageData parse(
    Uint8List bytes, {
    required String fileName,
  }) {
    if (bytes.length > maxPackageBytes) {
      throw const LearningTextbookPackageException('教材文件超过 50 MB，已拒绝导入');
    }
    final extension = _extensionOf(fileName);
    final manifestBytes = extension == 'zip' || extension == 'yxtbook'
        ? _manifestFromZip(bytes)
        : bytes;
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes, allowMalformed: false));
    } on FormatException {
      throw const LearningTextbookPackageException('教材包不是有效的 UTF-8 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const LearningTextbookPackageException('教材包顶层必须是对象');
    }
    try {
      final now = DateTime.now().toIso8601String();
      final package = LearningTextbookPackageData.fromJson({
        ...decoded,
        'origin': LearningTextbookOrigin.userImported.wireName,
        'imported_at': now,
        'imported_from': fileName,
      });
      if (package.licenseName == _placeholderLicense ||
          package.rightsHolder == '请填写权利人或来源') {
        throw const LearningTextbookPackageException(
          '请先填写真实许可证、授权说明和权利人，再导入教材包',
        );
      }
      return package;
    } on FormatException catch (error) {
      throw LearningTextbookPackageException('教材包内容无效：${error.message}');
    }
  }

  LearningTextbookPackageData parseDocument({
    required Uint8List bytes,
    required String fileName,
    required String title,
    required String ageBand,
    required String level,
    required String version,
    required String licenseName,
    required String rightsHolder,
    String licenseUrl = '',
    String sourceUrl = '',
  }) {
    try {
      final extension = _extensionOf(fileName);
      if (!const {'txt', 'md', 'markdown'}.contains(extension)) {
        throw const LearningTextbookPackageException(
          '目前只支持 UTF-8 TXT 和 Markdown；DOCX 与 PDF 资料待阅读器完成后接入。',
        );
      }
      if (bytes.length > 50 * 1024 * 1024) {
        throw const LearningTextbookPackageException('教材文件超过 50 MB，已拒绝导入');
      }
      final text = utf8.decode(bytes, allowMalformed: false);
      if (text.trim().isEmpty) {
        throw const LearningTextbookPackageException('文件中没有可读取的正文内容');
      }
      if (text.length > maxDocumentCharacters) {
        throw const LearningTextbookPackageException(
          '文档正文超过 80 万字符。请按章节拆分为多个 TXT/Markdown 文件后导入。',
        );
      }
      final normalizedFileName = fileName.replaceAll(
        String.fromCharCode(92),
        '/',
      );
      final baseName = normalizedFileName.substring(
        normalizedFileName.lastIndexOf('/') + 1,
      );
      final extensionIndex = baseName.lastIndexOf('.');
      final documentTitle =
          (extensionIndex > 0
                  ? baseName.substring(0, extensionIndex)
                  : baseName)
              .trim();
      final safeId = _safeId(title, fileName);
      final now = DateTime.now().toIso8601String();
      final package = LearningTextbookPackageData(
        id: safeId,
        title: title.trim(),
        ageBand: ageBand.trim(),
        level: level.trim(),
        version: version.trim(),
        language: 'en-zh',
        licenseName: licenseName.trim(),
        licenseUrl: licenseUrl.trim(),
        rightsHolder: rightsHolder.trim(),
        sourceUrl: sourceUrl.trim(),
        redistributionAllowed: false,
        origin: LearningTextbookOrigin.userImported,
        lessons: _splitDocumentLessons(
          text,
          documentTitle: documentTitle.isEmpty ? title.trim() : documentTitle,
        ),
        importedAt: now,
        importedFrom: fileName,
      );
      if (package.licenseName == _placeholderLicense ||
          package.rightsHolder == '请填写权利人或来源') {
        throw const LearningTextbookPackageException(
          '请先填写真实许可证、授权说明和权利人，再导入教材',
        );
      }
      // Re-parse the serialized form so document imports receive the same
      // bounds and required-field validation as structured package imports.
      return LearningTextbookPackageData.fromJson(package.toJson());
    } on LearningTextbookPackageException {
      rethrow;
    } on FormatException catch (error) {
      throw LearningTextbookPackageException('教材资料信息无效：${error.message}');
    }
  }

  List<LearningTextbookLessonData> _splitDocumentLessons(
    String text, {
    required String documentTitle,
  }) {
    final chunks = splitTextPreservingBoundaries(
      text,
      maxCharacters: maxDocumentLessonCharacters,
    );

    if (chunks.length > maxDocumentLessons) {
      throw const LearningTextbookPackageException(
        '文档拆分后超过 200 节。请按章节拆成多个文件后导入。',
      );
    }
    return List.unmodifiable([
      for (var index = 0; index < chunks.length; index++)
        LearningTextbookLessonData(
          id: 'document-${index + 1}',
          title: chunks.length == 1
              ? documentTitle
              : '$documentTitle · 第 ${index + 1} 节',
          sourceText: chunks[index],
          translation: '',
          vocabulary: const [],
        ),
    ]);
  }

  Uint8List _manifestFromZip(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.files.length > 1000) {
        throw const LearningTextbookPackageException('教材 ZIP 文件条目过多，已拒绝导入');
      }
      final manifest = archive.files.where((file) {
        final normalized = file.name.replaceAll('\\', '/');
        return normalized == 'learning-textbook.json' ||
            normalized == './learning-textbook.json';
      }).firstOrNull;
      if (manifest == null) {
        throw const LearningTextbookPackageException(
          'ZIP 内缺少 learning-textbook.json 清单文件',
        );
      }
      final content = manifest.content;
      if (content.length > 4 * 1024 * 1024) {
        throw const LearningTextbookPackageException('教材清单超过 4 MB，已拒绝导入');
      }
      return Uint8List.fromList(content);
    } on LearningTextbookPackageException {
      rethrow;
    } catch (_) {
      throw const LearningTextbookPackageException('教材 ZIP 无法读取');
    }
  }

  static String _extensionOf(String name) {
    final index = name.lastIndexOf('.');
    return index < 0 ? '' : name.substring(index + 1).toLowerCase();
  }

  static String _safeId(String title, String fileName) {
    final source = '${title.trim()}-${fileName.trim()}'.toLowerCase();
    final id = source.replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
    final trimmed = id.replaceAll(RegExp(r'^-+|-+$'), '');
    final value = trimmed.isEmpty ? 'imported-textbook' : trimmed;
    return value.substring(0, value.length > 120 ? 120 : value.length);
  }
}

abstract interface class LearningTextbookStore {
  Future<List<LearningTextbookPackageData>> read();

  Future<void> write(List<LearningTextbookPackageData> packages);

  Future<void> clear();
}

class MemoryLearningTextbookStore implements LearningTextbookStore {
  List<LearningTextbookPackageData> _packages = const [];

  @override
  Future<List<LearningTextbookPackageData>> read() async => [
    for (final package in _packages)
      LearningTextbookPackageData.fromJson(package.toJson()),
  ];

  @override
  Future<void> write(List<LearningTextbookPackageData> packages) async {
    _packages = [
      for (final package in packages)
        LearningTextbookPackageData.fromJson(package.toJson()),
    ];
  }

  @override
  Future<void> clear() async => _packages = const [];
}

class FileLearningTextbookStore implements LearningTextbookStore {
  const FileLearningTextbookStore(this.file);

  final File file;

  @override
  Future<List<LearningTextbookPackageData>> read() async {
    try {
      if (!await file.exists() ||
          await file.length() > LearningTextbookPackageService.maxStoreBytes) {
        return const [];
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic> ||
          raw['schema_version'] != learningTextbookSchemaVersion ||
          raw['packages'] is! List ||
          (raw['packages'] as List).length > 200) {
        return const [];
      }
      return [
        for (final item in raw['packages'] as List)
          if (item is Map<String, dynamic>)
            LearningTextbookPackageData.fromJson(item)
          else
            throw const FormatException('教材资料库条目无效'),
      ];
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    } on JsonUnsupportedObjectError {
      return const [];
    }
  }

  @override
  Future<void> write(List<LearningTextbookPackageData> packages) async {
    if (packages.length > 200) {
      throw const LearningTextbookPackageException('本地教材包数量不能超过 200');
    }
    final validated = [
      for (final package in packages)
        LearningTextbookPackageData.fromJson(package.toJson()),
    ];
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'schema_version': learningTextbookSchemaVersion,
        'packages': [for (final package in validated) package.toJson()],
      }),
      flush: true,
    );
  }

  @override
  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Idempotent for a missing file.
    }
  }
}

String _text(Object? value, String label, {required int maxLength}) {
  if (value is! String || value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('$label无效');
  }
  return value.trim();
}

String _preservedText(Object? value, String label, {required int maxLength}) {
  if (value is! String || value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('$label无效');
  }
  return value;
}

String _optionalText(Object? value, String label, {required int maxLength}) {
  if (value == null) return '';
  if (value is! String || value.length > maxLength) {
    throw FormatException('$label无效');
  }
  return value.trim();
}

String _url(Object? value, String label) {
  final text = _optionalText(value, label, maxLength: 1000);
  if (text.isEmpty) return '';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw FormatException('$label必须是 HTTP 或 HTTPS 链接');
  }
  return text;
}

bool _bool(Object? value, String label) {
  if (value is! bool) throw FormatException('$label无效');
  return value;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
