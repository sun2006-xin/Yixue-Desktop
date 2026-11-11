import 'dart:convert';
import 'dart:io';

enum StorageCategory {
  translationHistory(
    'translation_history',
    '翻译历史',
    '快速翻译与截屏翻译产生的原文、译文、来源和标注；不包含截图。',
  ),
  favoriteWords('favorite_words', '收藏单词', '收藏单词、用户笔记和加入学习的状态。'),
  dictionary('dictionary', '词典数据', '内置或合法导入的词条、释义和例句。'),
  learningRecords('learning_records', '学习记录', '学习项目、复习和作答记录。'),
  readingDocuments('reading_documents', '阅读文档', '导入的文档快照、阅读位置和段落译文。'),
  activity('activity', '活动统计', '首页学习、阅读和翻译统计。'),
  modelCatalog('model_catalog', '模型目录', '已发现模型的目录信息，不包含模型文件本身。');

  const StorageCategory(this.id, this.title, this.description);

  final String id;
  final String title;
  final String description;

  static StorageCategory? fromId(String value) {
    for (final category in values) {
      if (category.id == value) return category;
    }
    return null;
  }
}

class StoragePolicy {
  StoragePolicy({Map<StorageCategory, int?>? quotas})
    : quotas = Map.unmodifiable(quotas ?? const {});

  final Map<StorageCategory, int?> quotas;

  factory StoragePolicy.unlimited() => StoragePolicy(
    quotas: {for (final category in StorageCategory.values) category: null},
  );

  int? quotaFor(StorageCategory category) => quotas[category];

  StoragePolicy setQuota(StorageCategory category, int? bytes) {
    if (bytes != null && bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', '容量不能为负数');
    }
    return StoragePolicy(quotas: {...quotas, category: bytes});
  }

  bool isWithinQuota(
    StorageCategory category, {
    required int usedBytes,
    int additionalBytes = 0,
  }) {
    final quota = quotaFor(category);
    if (quota == null) return true;
    return usedBytes >= 0 &&
        additionalBytes >= 0 &&
        usedBytes + additionalBytes <= quota;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'quotas': {
      for (final category in StorageCategory.values)
        category.id: quotas.containsKey(category) ? quotas[category] : null,
    },
  };

  factory StoragePolicy.fromJson(Map<String, dynamic> value) {
    if (value['schemaVersion'] != 1 || value['quotas'] is! Map) {
      throw const FormatException('unsupported storage policy schema');
    }
    final rawQuotas = (value['quotas'] as Map).cast<String, dynamic>();
    final quotas = <StorageCategory, int?>{};
    for (final entry in rawQuotas.entries) {
      final category = StorageCategory.fromId(entry.key);
      if (category == null) continue;
      final rawBytes = entry.value;
      if (rawBytes == null) {
        quotas[category] = null;
      } else if (rawBytes is int && rawBytes >= 0) {
        quotas[category] = rawBytes;
      } else {
        throw const FormatException(
          'storage quota must be a non-negative integer or null',
        );
      }
    }
    return StoragePolicy(quotas: quotas);
  }
}

class StorageUsageData {
  StorageUsageData({Map<String, int>? usedBytes})
    : usedBytes = Map.unmodifiable(usedBytes ?? const {});

  final Map<String, int> usedBytes;

  int forCategory(StorageCategory category) => usedBytes[category.id] ?? 0;

  int get totalBytes =>
      usedBytes.values.fold(0, (total, value) => total + value);

  factory StorageUsageData.fromJson(Map<String, dynamic> value) {
    final records = value['records'];
    if (records is! List<dynamic> || records.any((item) => item is! Map)) {
      throw const FormatException('storage usage records are invalid');
    }
    final usedBytes = <String, int>{};
    for (final raw in records) {
      final record = (raw as Map).cast<String, dynamic>();
      final category = record['category'];
      final bytes = record['used_bytes'];
      if (category is! String || bytes is! int || bytes < 0) {
        throw const FormatException('storage usage record has invalid fields');
      }
      usedBytes[category] = bytes;
    }
    return StorageUsageData(usedBytes: usedBytes);
  }
}

abstract interface class StoragePolicyStore {
  Future<StoragePolicy?> read();

  Future<void> write(StoragePolicy policy);
}

class FileStoragePolicyStore implements StoragePolicyStore {
  const FileStoragePolicyStore(this.file);

  final File file;

  @override
  Future<StoragePolicy?> read() async {
    try {
      if (!await file.exists() || await file.length() > 64 * 1024) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) return null;
      return StoragePolicy.fromJson(value);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(StoragePolicy policy) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(policy.toJson()), flush: true);
  }
}

String formatStorageBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatStorageQuota(int? bytes) =>
    bytes == null ? '不限制' : formatStorageBytes(bytes);
