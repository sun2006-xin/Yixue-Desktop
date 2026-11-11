import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ffi/ffi.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/storage_policy.dart';

typedef _SchemaVersionNative = Uint32 Function();
typedef _SchemaVersionDart = int Function();
typedef _ProcessJsonNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ProcessJsonDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _StringFreeNative = Void Function(Pointer<Utf8>);
typedef _StringFreeDart = void Function(Pointer<Utf8>);
typedef _EngineOpenNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _EngineOpenDart = Pointer<Void> Function(Pointer<Utf8>);
typedef _EngineProcessNative = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
);
typedef _EngineProcessDart = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
);
typedef _EngineFreeNative = Void Function(Pointer<Void>);
typedef _EngineFreeDart = void Function(Pointer<Void>);

String _processEngineJsonInIsolate(
  String libraryPath,
  int engineAddress,
  String request,
) {
  final library = DynamicLibrary.open(libraryPath);
  final process = library
      .lookupFunction<_EngineProcessNative, _EngineProcessDart>(
        'yixue_engine_process_json',
      );
  final free = library.lookupFunction<_StringFreeNative, _StringFreeDart>(
    'yixue_string_free',
  );
  final input = request.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = process(Pointer<Void>.fromAddress(engineAddress), input);
    if (output == nullptr) throw StateError('native core returned null');
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) free(output);
  }
}

Map<String, dynamic> _decodeCoreResponse(String raw) {
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (error) {
    throw CoreBridgeException('invalid_response', error.message);
  }
  if (decoded is! Map<String, dynamic>) {
    throw const CoreBridgeException(
      'invalid_response',
      'native core response is not a JSON object',
    );
  }
  if (decoded['ok'] != true) {
    final error = decoded['error'];
    if (error is Map<String, dynamic>) {
      final code = error['code'];
      final message = error['message'];
      throw CoreBridgeException(
        code is String ? code : 'core_error',
        message is String ? message : 'native core operation failed',
      );
    }
    throw const CoreBridgeException(
      'core_error',
      'native core operation failed',
    );
  }
  return decoded;
}

@visibleForTesting
Map<String, dynamic> decodeCoreResponseForTesting(String raw) =>
    _decodeCoreResponse(raw);

abstract interface class CoreBridge {
  CoreHealth health();
}

abstract interface class AppCore implements CoreBridge {
  void saveProviderProfile(ProviderProfileData profile);

  void deleteProviderProfile(String providerId);

  List<ProviderProfileData> listProviderProfiles();

  void recordActivity(ActivityEventData activity);

  HomeSnapshotData homeSnapshot(String localDate, {int recentLimit = 10});

  void dispose();
}

/// Optional extension for the versioned homepage workbench contract.
///
/// Keeping this separate from [AppCore] lets older in-memory doubles and
/// integrations continue to use the legacy [HomeSnapshotData] contract while
/// the persistent bridge exposes the richer, date-scoped snapshot.
abstract interface class HomeWorkbenchCore {
  HomeCoreSnapshotData homeWorkbenchSnapshot(
    String localDate, {
    int recentLimit = 10,
  });
}

abstract interface class TranslationHistoryCore {
  void recordCompletedTranslation(CompletedTranslationData translation);

  List<TranslationHistoryEntryData> listTranslationHistory({int limit = 500});
}

/// Optional extension for a bridge that can delete explicitly selected
/// history rows without turning the action into a full category clear.
abstract interface class DeletableTranslationHistoryCore
    implements TranslationHistoryCore {
  void deleteTranslationHistory(List<String> ids);
}

/// Optional extension implemented by persistent bridges that can page local
/// history. Keeping this separate preserves compatibility with simple test
/// doubles and older integrations that only expose the original list method.
abstract interface class PagedTranslationHistoryCore
    implements TranslationHistoryCore {
  List<TranslationHistoryEntryData> listTranslationHistoryPage({
    int limit = 50,
    int offset = 0,
    String? origin,
    String query = '',
  });
}

/// Optional exact lookup used to validate screenshot history before archive
/// deletion without paging through the full OCR-text search result set.
abstract interface class ScreenshotTranslationHistoryValidationCore
    implements TranslationHistoryCore {
  bool validateScreenshotTranslationHistory({
    required String id,
    required String sourceText,
  });
}

/// Optional persistence hook for AI summaries attached to screenshot history.
abstract interface class ScreenshotTranslationHistorySummaryCore
    implements TranslationHistoryCore {
  void saveScreenshotTranslationSummary({
    required String id,
    required String sourceText,
    required String summaryText,
  });
}

/// Optional exact reference lookup used before deleting an archived image.
/// A shared capture image is removable only when every screenshot history
/// version that points to it is included in the selected history IDs.
abstract interface class ScreenshotCaptureImageDeletionCore
    implements TranslationHistoryCore {
  List<String> screenshotCaptureIdsOrphanedByHistoryDeletion(List<String> ids);
}

/// Optional lookup used to reconcile marked image-deletion backups after a
/// process exit. Ordinary image files are never inferred from this query.
abstract interface class ScreenshotCaptureImageReferenceCore
    implements TranslationHistoryCore {
  List<String> referencedScreenshotCaptureIds(List<String> captureIds);
}

abstract interface class TranslationAnnotationCore {
  void saveTranslationAnnotation(TranslationAnnotationData annotation);

  List<TranslationAnnotationData> listTranslationAnnotations({int limit = 100});
}

abstract interface class WordAnnotationCore {
  void saveWordAnnotation(WordAnnotationData annotation);

  WordAnnotationData? getWordAnnotation(String word);
}

abstract interface class ModelPackageCore {
  ModelPackageValidationData validateModelPackage(String modelPath);
}

abstract interface class ModelCatalogCore {
  void saveModelCatalogEntry(ModelCatalogEntryData entry);

  void deleteModelCatalogEntry(String modelId);

  List<ModelCatalogEntryData> listModelCatalogEntries();
}

abstract interface class DictionaryCore {
  List<DictionaryEntryData> lookupDictionary(String word, {int limit = 10});
  void saveDictionaryEntry(DictionaryEntryData entry);
  List<String> listFavoriteWords();
  void setFavoriteWord(String word, bool favorite);
}

abstract interface class PagedDictionaryCore {
  DictionaryEntryPageData listDictionaryEntryPage({
    String word = '',
    int limit = 50,
    int offset = 0,
  });
}

/// Optional extension for a persistent bridge that can page the complete
/// favorite-word workspace without changing the legacy dictionary contract.
abstract interface class PagedFavoriteWordCore {
  FavoriteWordPageData listFavoriteWordPage({
    String query = '',
    int limit = 40,
    int offset = 0,
  });
}

abstract interface class LocalDataCore {
  void clearUserData(String category);
}

abstract interface class StorageUsageCore {
  StorageUsageData storageUsage();
}

class DictionaryEntryData {
  const DictionaryEntryData({
    required this.id,
    required this.word,
    required this.ipa,
    required this.partOfSpeech,
    required this.meanings,
    required this.example,
    required this.exampleTranslation,
    required this.source,
  });

  final String id;
  final String word;
  final String ipa;
  final String partOfSpeech;
  final List<String> meanings;
  final String example;
  final String exampleTranslation;
  final String source;

  Map<String, Object?> toJson() => {
    'id': id,
    'word': word,
    'ipa': ipa,
    'part_of_speech': partOfSpeech,
    'meanings': meanings,
    'example': example,
    'example_translation': exampleTranslation,
    'source': source,
  };

  factory DictionaryEntryData.fromJson(Map<String, dynamic> value) {
    final meanings = value['meanings'];
    if (value['id'] is! String ||
        value['word'] is! String ||
        value['ipa'] is! String ||
        value['part_of_speech'] is! String ||
        meanings is! List<dynamic> ||
        meanings.any((item) => item is! String) ||
        value['example'] is! String ||
        value['example_translation'] is! String ||
        value['source'] is! String) {
      throw const CoreBridgeException(
        'invalid_response',
        'dictionary entry has invalid fields',
      );
    }
    return DictionaryEntryData(
      id: value['id'] as String,
      word: value['word'] as String,
      ipa: value['ipa'] as String,
      partOfSpeech: value['part_of_speech'] as String,
      meanings: meanings.cast<String>(),
      example: value['example'] as String,
      exampleTranslation: value['example_translation'] as String,
      source: value['source'] as String,
    );
  }
}

abstract interface class ContentSourceCore {
  void saveContentSource(ContentSourceData source);

  List<ContentSourceData> listContentSources({int limit = 20});

  ContentSourceVersionData saveContentSourceVersion(ContentSourceData source);

  List<ContentSourceVersionData> listContentSourceVersions(
    String sourceId, {
    int limit = 20,
  });

  ContentSourceData restoreContentSourceVersion({
    required String sourceId,
    required String versionId,
  });

  void setContentSourceFavorite({
    required String sourceId,
    required bool favorite,
  });

  void trashContentSource(String sourceId);

  void restoreContentSource(String sourceId);

  void deleteContentSource(String sourceId);
}

class ContentSourceData {
  const ContentSourceData({
    required this.id,
    required this.kind,
    required this.title,
    required this.localPath,
    required this.contentText,
    required this.readingPosition,
    required this.translatedParagraphsJson,
    required this.createdAt,
    this.isFavorite = false,
    this.deletedAt,
  });

  final String id;
  final String kind;
  final String title;
  final String? localPath;
  final String contentText;
  final int readingPosition;
  final String translatedParagraphsJson;
  final String createdAt;
  final bool isFavorite;
  final String? deletedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'title': title,
    'local_path': localPath,
    'content_text': contentText,
    'reading_position': readingPosition,
    'translated_paragraphs_json': translatedParagraphsJson,
    'created_at': createdAt,
    'is_favorite': isFavorite,
    'deleted_at': deletedAt,
  };

  factory ContentSourceData.fromJson(Map<String, dynamic> value) {
    if (value['id'] is! String ||
        value['kind'] is! String ||
        value['title'] is! String ||
        value['content_text'] is! String ||
        value['reading_position'] is! int ||
        value['translated_paragraphs_json'] is! String ||
        value['created_at'] is! String ||
        (value['local_path'] != null && value['local_path'] is! String) ||
        (value['is_favorite'] != null && value['is_favorite'] is! bool) ||
        (value['deleted_at'] != null && value['deleted_at'] is! String)) {
      throw const CoreBridgeException(
        'invalid_response',
        'content source has invalid fields',
      );
    }
    return ContentSourceData(
      id: value['id'] as String,
      kind: value['kind'] as String,
      title: value['title'] as String,
      localPath: value['local_path'] as String?,
      contentText: value['content_text'] as String,
      readingPosition: value['reading_position'] as int,
      translatedParagraphsJson: value['translated_paragraphs_json'] as String,
      createdAt: value['created_at'] as String,
      isFavorite: value['is_favorite'] == true,
      deletedAt: value['deleted_at'] as String?,
    );
  }
}

class ContentSourceVersionData {
  const ContentSourceVersionData({
    required this.id,
    required this.sourceId,
    required this.version,
    required this.kind,
    required this.title,
    required this.localPath,
    required this.contentText,
    required this.readingPosition,
    required this.translatedParagraphsJson,
    required this.createdAt,
  });

  final String id;
  final String sourceId;
  final int version;
  final String kind;
  final String title;
  final String? localPath;
  final String contentText;
  final int readingPosition;
  final String translatedParagraphsJson;
  final String createdAt;

  factory ContentSourceVersionData.fromJson(Map<String, dynamic> value) {
    if (value['id'] is! String ||
        value['source_id'] is! String ||
        value['version'] is! int ||
        value['kind'] is! String ||
        value['title'] is! String ||
        value['content_text'] is! String ||
        value['reading_position'] is! int ||
        value['translated_paragraphs_json'] is! String ||
        value['created_at'] is! String ||
        (value['local_path'] != null && value['local_path'] is! String)) {
      throw const CoreBridgeException(
        'invalid_response',
        'content source version has invalid fields',
      );
    }
    return ContentSourceVersionData(
      id: value['id'] as String,
      sourceId: value['source_id'] as String,
      version: value['version'] as int,
      kind: value['kind'] as String,
      title: value['title'] as String,
      localPath: value['local_path'] as String?,
      contentText: value['content_text'] as String,
      readingPosition: value['reading_position'] as int,
      translatedParagraphsJson: value['translated_paragraphs_json'] as String,
      createdAt: value['created_at'] as String,
    );
  }

  ContentSourceData toContentSource() => ContentSourceData(
    id: sourceId,
    kind: kind,
    title: title,
    localPath: localPath,
    contentText: contentText,
    readingPosition: readingPosition,
    translatedParagraphsJson: translatedParagraphsJson,
    createdAt: createdAt,
  );
}

class ModelCatalogEntryData {
  const ModelCatalogEntryData({
    required this.id,
    required this.path,
    required this.displayName,
    required this.family,
    required this.readiness,
    required this.capabilities,
    required this.assignedRoles,
    this.sourceLanguage,
    this.targetLanguage,
  });

  final String id;
  final String path;
  final String displayName;
  final String family;
  final String readiness;
  final List<String> capabilities;
  final List<String> assignedRoles;
  final String? sourceLanguage;
  final String? targetLanguage;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'path': path,
    'display_name': displayName,
    'family': family,
    'readiness': readiness,
    'capabilities': capabilities,
    'assigned_roles': assignedRoles,
    'source_language': sourceLanguage,
    'target_language': targetLanguage,
  };

  factory ModelCatalogEntryData.fromJson(Map<String, dynamic> value) {
    final capabilities = value['capabilities'];
    final roles = value['assigned_roles'];
    final sourceLanguage = value['source_language'];
    final targetLanguage = value['target_language'];
    if (value['id'] is! String ||
        value['path'] is! String ||
        value['display_name'] is! String ||
        value['family'] is! String ||
        value['readiness'] is! String ||
        capabilities is! List<dynamic> ||
        roles is! List<dynamic> ||
        (sourceLanguage != null && sourceLanguage is! String) ||
        (targetLanguage != null && targetLanguage is! String) ||
        capabilities.any((item) => item is! String) ||
        roles.any((item) => item is! String)) {
      throw const CoreBridgeException(
        'invalid_response',
        'model catalog entry has invalid fields',
      );
    }
    return ModelCatalogEntryData(
      id: value['id'] as String,
      path: value['path'] as String,
      displayName: value['display_name'] as String,
      family: value['family'] as String,
      readiness: value['readiness'] as String,
      capabilities: capabilities.cast<String>(),
      assignedRoles: roles.cast<String>(),
      sourceLanguage: sourceLanguage as String?,
      targetLanguage: targetLanguage as String?,
    );
  }
}

abstract interface class LocalTranslationCore {
  Future<void> configureLocalTranslation({
    required String modelPath,
    required String workerPath,
  });

  Future<LocalTranslationResultData> translateLocal({
    required String id,
    required String sourceText,
    required String sourceLanguage,
    required String targetLanguage,
  });

  Future<bool> cancelLocalTranslation(String id);
}

class LocalTranslationResultData {
  const LocalTranslationResultData({
    required this.requestId,
    required this.providerId,
    required this.text,
  });

  final String requestId;
  final String providerId;
  final String text;

  factory LocalTranslationResultData.fromJson(Map<String, dynamic> value) {
    final requestId = value['request_id'];
    final providerId = value['provider_id'];
    final text = value['text'];
    if (requestId is! String || providerId is! String || text is! String) {
      throw const CoreBridgeException(
        'invalid_response',
        'local translation response has invalid fields',
      );
    }
    return LocalTranslationResultData(
      requestId: requestId,
      providerId: providerId,
      text: text,
    );
  }
}

class ModelPackageValidationData {
  const ModelPackageValidationData({
    required this.packageId,
    required this.displayName,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.baseModel,
    required this.license,
    required this.verifiedFileCount,
    required this.totalBytes,
  });

  final String packageId;
  final String displayName;
  final String sourceLanguage;
  final String targetLanguage;
  final String baseModel;
  final String license;
  final int verifiedFileCount;
  final int totalBytes;

  factory ModelPackageValidationData.fromJson(Map<String, dynamic> value) {
    final packageId = value['package_id'];
    final displayName = value['display_name'];
    final sourceLanguage = value['source_language'];
    final targetLanguage = value['target_language'];
    final baseModel = value['base_model'];
    final license = value['license'];
    final verifiedFileCount = value['verified_file_count'];
    final totalBytes = value['total_bytes'];
    if (packageId is! String ||
        displayName is! String ||
        sourceLanguage is! String ||
        targetLanguage is! String ||
        baseModel is! String ||
        license is! String ||
        verifiedFileCount is! int ||
        totalBytes is! int) {
      throw const CoreBridgeException(
        'invalid_response',
        'model package validation response has invalid fields',
      );
    }
    return ModelPackageValidationData(
      packageId: packageId,
      displayName: displayName,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      baseModel: baseModel,
      license: license,
      verifiedFileCount: verifiedFileCount,
      totalBytes: totalBytes,
    );
  }
}

class CompletedTranslationData {
  const CompletedTranslationData({
    required this.id,
    required this.sourceText,
    required this.translatedText,
    required this.providerId,
    required this.createdAt,
    this.sourceLanguage = 'english',
    this.targetLanguage = 'chinese',
    this.origin = 'quick_translation',
    this.screenshotCaptureId,
    this.screenshotOcrLayout,
    this.translatedSourceBlockIndices,
  });

  final String id;
  final String sourceText;
  final String translatedText;
  final String providerId;
  final String createdAt;
  final String sourceLanguage;
  final String targetLanguage;
  final String origin;
  final String? screenshotCaptureId;
  final Map<String, Object?>? screenshotOcrLayout;
  final List<int>? translatedSourceBlockIndices;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'source_language': sourceLanguage,
    'target_language': targetLanguage,
    'source_text': sourceText,
    'translated_text': translatedText,
    'provider_id': providerId,
    'created_at': createdAt,
    'origin': origin,
    'screenshot_capture_id': ?screenshotCaptureId,
    if (origin == 'screenshot_translation' &&
        screenshotOcrLayout != null &&
        translatedSourceBlockIndices != null) ...{
      'screenshot_ocr_layout': screenshotOcrLayout,
      'translated_source_block_indices': translatedSourceBlockIndices,
    },
  };
}

class TranslationHistoryEntryData {
  const TranslationHistoryEntryData({
    required this.id,
    required this.sourceText,
    required this.translatedText,
    required this.providerId,
    required this.createdAt,
    this.sourceLanguage = 'english',
    this.targetLanguage = 'chinese',
    this.origin = 'quick_translation',
    this.screenshotCaptureId,
    this.summaryText,
    this.screenshotOcrLayout,
    this.translatedSourceBlockIndices,
  });

  final String id;
  final String sourceText;
  final String translatedText;
  final String providerId;
  final String createdAt;
  final String sourceLanguage;
  final String targetLanguage;
  final String origin;
  final String? screenshotCaptureId;
  final String? summaryText;
  final Map<String, Object?>? screenshotOcrLayout;
  final List<int>? translatedSourceBlockIndices;

  /// Legacy screenshot rows use their own history ID as the image key.
  String get captureId =>
      origin == 'screenshot_translation' ? screenshotCaptureId ?? id : id;

  String get originLabel =>
      origin == 'screenshot_translation' ? '截屏翻译' : '快速翻译';

  factory TranslationHistoryEntryData.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final sourceText = value['source_text'];
    final translatedText = value['translated_text'];
    final providerId = value['provider_id'];
    final createdAt = value['created_at'];
    final sourceLanguage = value['source_language'];
    final targetLanguage = value['target_language'];
    final origin = value.containsKey('origin')
        ? value['origin']
        : 'quick_translation';
    final screenshotCaptureId = value['screenshot_capture_id'];
    final summaryText = value['summary_text'];
    final rawScreenshotOcrLayout = value['screenshot_ocr_layout'];
    final rawTranslatedSourceBlockIndices =
        value['translated_source_block_indices'];
    if (id is! String ||
        sourceText is! String ||
        translatedText is! String ||
        providerId is! String ||
        createdAt is! String ||
        sourceLanguage is! String ||
        targetLanguage is! String ||
        (screenshotCaptureId != null && screenshotCaptureId is! String) ||
        (summaryText != null && summaryText is! String) ||
        (origin != 'quick_translation' && origin != 'screenshot_translation')) {
      throw const CoreBridgeException(
        'invalid_response',
        'translation history entry has invalid fields',
      );
    }
    final parsedLayout = rawScreenshotOcrLayout is Map
        ? <String, Object?>{
            for (final entry in rawScreenshotOcrLayout.entries)
              if (entry.key is String) (entry.key as String): entry.value,
          }
        : null;
    final parsedBlockIndices =
        rawTranslatedSourceBlockIndices is List &&
            rawTranslatedSourceBlockIndices.every((item) => item is int)
        ? List<int>.unmodifiable(rawTranslatedSourceBlockIndices.cast<int>())
        : null;
    // Optional alignment metadata is deliberately ignored unless it is a
    // complete pair on a screenshot history row. Old or malformed rows still
    // open as a normal image plus text comparison.
    final hasValidAlignmentMetadata =
        origin == 'screenshot_translation' &&
        parsedLayout != null &&
        parsedBlockIndices != null;
    return TranslationHistoryEntryData(
      id: id,
      sourceText: sourceText,
      translatedText: translatedText,
      providerId: providerId,
      createdAt: createdAt,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      origin: origin as String,
      screenshotCaptureId: screenshotCaptureId as String?,
      summaryText: summaryText as String?,
      screenshotOcrLayout: hasValidAlignmentMetadata ? parsedLayout : null,
      translatedSourceBlockIndices: hasValidAlignmentMetadata
          ? parsedBlockIndices
          : null,
    );
  }
}

class TranslationAnnotationData {
  const TranslationAnnotationData({
    required this.translationId,
    required this.note,
    required this.favorite,
    required this.addedToLearning,
    required this.updatedAt,
  });

  final String translationId;
  final String note;
  final bool favorite;
  final bool addedToLearning;
  final String updatedAt;

  Map<String, Object> toJson() => <String, Object>{
    'translation_id': translationId,
    'note': note,
    'favorite': favorite,
    'added_to_learning': addedToLearning,
    'updated_at': updatedAt,
  };

  factory TranslationAnnotationData.fromJson(Map<String, dynamic> value) {
    final translationId = value['translation_id'];
    final note = value['note'];
    final favorite = value['favorite'];
    final addedToLearning = value['added_to_learning'];
    final updatedAt = value['updated_at'];
    if (translationId is! String ||
        note is! String ||
        favorite is! bool ||
        addedToLearning is! bool ||
        updatedAt is! String) {
      throw const CoreBridgeException(
        'invalid_response',
        'translation annotation has invalid fields',
      );
    }
    return TranslationAnnotationData(
      translationId: translationId,
      note: note,
      favorite: favorite,
      addedToLearning: addedToLearning,
      updatedAt: updatedAt,
    );
  }
}

class WordAnnotationData {
  const WordAnnotationData({
    required this.word,
    required this.note,
    required this.addedToLearning,
    required this.updatedAt,
  });

  final String word;
  final String note;
  final bool addedToLearning;
  final String updatedAt;

  Map<String, Object> toJson() => <String, Object>{
    'word': word,
    'note': note,
    'added_to_learning': addedToLearning,
    'updated_at': updatedAt,
  };

  factory WordAnnotationData.fromJson(Map<String, dynamic> value) {
    final word = value['word'];
    final note = value['note'];
    final addedToLearning = value['added_to_learning'];
    final updatedAt = value['updated_at'];
    if (word is! String ||
        note is! String ||
        addedToLearning is! bool ||
        updatedAt is! String) {
      throw const CoreBridgeException(
        'invalid_response',
        'word annotation has invalid fields',
      );
    }
    return WordAnnotationData(
      word: word,
      note: note,
      addedToLearning: addedToLearning,
      updatedAt: updatedAt,
    );
  }
}

class FavoriteWordRecordData {
  const FavoriteWordRecordData({
    required this.word,
    required this.favoritedAt,
    required this.languagePair,
    required this.dictionaryEntries,
    required this.annotation,
  });

  final String word;
  final String favoritedAt;
  final String languagePair;
  final List<DictionaryEntryData> dictionaryEntries;
  final WordAnnotationData? annotation;

  factory FavoriteWordRecordData.fromJson(Map<String, dynamic> value) {
    final word = value['word'];
    final favoritedAt = value['favorited_at'];
    final languagePair = value['language_pair'];
    final entries = value['dictionary_entries'];
    final annotation = value['annotation'];
    if (word is! String ||
        favoritedAt is! String ||
        languagePair is! String ||
        entries is! List<dynamic> ||
        entries.any((item) => item is! Map) ||
        (annotation != null && annotation is! Map)) {
      throw const CoreBridgeException(
        'invalid_response',
        'favorite word record has invalid fields',
      );
    }
    return FavoriteWordRecordData(
      word: word,
      favoritedAt: favoritedAt,
      languagePair: languagePair,
      dictionaryEntries: entries
          .map(
            (item) => DictionaryEntryData.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
      annotation: annotation == null
          ? null
          : WordAnnotationData.fromJson(
              (annotation as Map).cast<String, dynamic>(),
            ),
    );
  }
}

class FavoriteWordPageData {
  const FavoriteWordPageData({required this.records, required this.hasMore});

  final List<FavoriteWordRecordData> records;
  final bool hasMore;

  factory FavoriteWordPageData.fromJson(Map<String, dynamic> value) {
    final records = value['records'];
    final hasMore = value['has_more'];
    if (records is! List<dynamic> ||
        records.any((item) => item is! Map) ||
        hasMore is! bool) {
      throw const CoreBridgeException(
        'invalid_response',
        'favorite word page has invalid fields',
      );
    }
    return FavoriteWordPageData(
      records: records
          .map(
            (item) => FavoriteWordRecordData.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
      hasMore: hasMore,
    );
  }
}

class DictionaryEntryPageData {
  const DictionaryEntryPageData({required this.entries, required this.hasMore});

  final List<DictionaryEntryData> entries;
  final bool hasMore;

  factory DictionaryEntryPageData.fromJson(Map<String, dynamic> value) {
    final entries = value['entries'];
    final hasMore = value['has_more'];
    if (entries is! List<dynamic> ||
        entries.any((item) => item is! Map) ||
        hasMore is! bool) {
      throw const CoreBridgeException(
        'invalid_response',
        'dictionary entry page has invalid fields',
      );
    }
    return DictionaryEntryPageData(
      entries: entries
          .map(
            (item) => DictionaryEntryData.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
      hasMore: hasMore,
    );
  }
}

enum ActivityKind {
  translation('translation'),
  reading('reading'),
  vocabulary('vocabulary'),
  exercise('exercise'),
  speaking('speaking'),
  focus('focus');

  const ActivityKind(this.wireName);
  final String wireName;

  static ActivityKind fromWireName(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw const CoreBridgeException(
      'invalid_response',
      'activity kind is unknown',
    ),
  );
}

class ActivityEventData {
  const ActivityEventData({
    required this.id,
    required this.kind,
    required this.title,
    required this.durationSeconds,
    required this.itemCount,
    required this.occurredAt,
    this.detail,
    this.sourceId,
  });

  final String id;
  final ActivityKind kind;
  final String title;
  final String? detail;
  final String? sourceId;
  final int durationSeconds;
  final int itemCount;
  final String occurredAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.wireName,
    'title': title,
    'detail': detail,
    'source_id': sourceId,
    'duration_seconds': durationSeconds,
    'item_count': itemCount,
    'occurred_at': occurredAt,
  };

  factory ActivityEventData.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final kind = value['kind'];
    final title = value['title'];
    final detail = value['detail'];
    final sourceId = value['source_id'];
    final durationSeconds = value['duration_seconds'];
    final itemCount = value['item_count'];
    final occurredAt = value['occurred_at'];
    if (id is! String ||
        kind is! String ||
        title is! String ||
        (detail != null && detail is! String) ||
        (sourceId != null && sourceId is! String) ||
        durationSeconds is! int ||
        itemCount is! int ||
        occurredAt is! String) {
      throw const CoreBridgeException(
        'invalid_response',
        'activity has invalid fields',
      );
    }
    return ActivityEventData(
      id: id,
      kind: ActivityKind.fromWireName(kind),
      title: title,
      detail: detail as String?,
      sourceId: sourceId as String?,
      durationSeconds: durationSeconds,
      itemCount: itemCount,
      occurredAt: occurredAt,
    );
  }
}

class HomeSnapshotData {
  const HomeSnapshotData({
    required this.learningMinutes,
    required this.readingPages,
    required this.masteredWords,
    required this.completedExercises,
    required this.recent,
  });

  final int learningMinutes;
  final int readingPages;
  final int masteredWords;
  final int completedExercises;
  final List<ActivityEventData> recent;

  factory HomeSnapshotData.fromJson(Map<String, dynamic> value) {
    final learningMinutes = value['learning_minutes'];
    final readingPages = value['reading_pages'];
    final masteredWords = value['mastered_words'];
    final completedExercises = value['completed_exercises'];
    final recent = value['recent'];
    if (learningMinutes is! int ||
        readingPages is! int ||
        masteredWords is! int ||
        completedExercises is! int ||
        recent is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'home snapshot has invalid fields',
      );
    }
    return HomeSnapshotData(
      learningMinutes: learningMinutes,
      readingPages: readingPages,
      masteredWords: masteredWords,
      completedExercises: completedExercises,
      recent: recent
          .map((entry) {
            if (entry is! Map<String, dynamic>) {
              throw const CoreBridgeException(
                'invalid_response',
                'recent activity is invalid',
              );
            }
            return ActivityEventData.fromJson(entry);
          })
          .toList(growable: false),
    );
  }
}

class HomeCoreSnapshotData {
  const HomeCoreSnapshotData({
    required this.localDate,
    required this.summary,
    required this.recent,
    this.details = const [],
  });

  final String localDate;
  final HomeSummaryData summary;
  final List<ActivityEventData> recent;
  final List<ActivityEventData> details;

  factory HomeCoreSnapshotData.fromJson(Map<String, dynamic> value) {
    final localDate = value['local_date'];
    final rawSummary = value['summary'];
    final rawRecent = value['recent'];
    final rawDetails = value['details'];
    if (localDate is! String ||
        rawSummary is! Map ||
        rawRecent is! List<dynamic> ||
        (rawDetails != null && rawDetails is! List<dynamic>)) {
      throw const CoreBridgeException(
        'invalid_response',
        'home workbench snapshot has invalid fields',
      );
    }

    final summary = rawSummary.cast<String, dynamic>();
    List<ActivityEventData> parseActivities(
      List<dynamic> raw,
      String errorMessage,
    ) => raw
        .map((entry) {
          if (entry is! Map) {
            throw CoreBridgeException('invalid_response', errorMessage);
          }
          return ActivityEventData.fromJson(entry.cast<String, dynamic>());
        })
        .toList(growable: false);

    final recent = parseActivities(
      rawRecent,
      'home workbench recent activity is invalid',
    );
    final details = rawDetails == null
        ? recent
        : parseActivities(
            rawDetails,
            'home workbench detail activity is invalid',
          );
    return HomeCoreSnapshotData(
      localDate: localDate,
      summary: HomeSummaryData.fromJson(summary),
      recent: recent,
      details: details,
    );
  }
}

class CoreHealth {
  const CoreHealth({required this.schemaVersion, required this.coreVersion});

  final int schemaVersion;
  final String coreVersion;
}

enum ProviderProfileKind {
  localModel('local_model'),
  remoteApi('remote_api');

  const ProviderProfileKind(this.wireName);

  final String wireName;

  static ProviderProfileKind fromWireName(String value) => switch (value) {
    'local_model' => localModel,
    'remote_api' => remoteApi,
    _ => throw const CoreBridgeException(
      'invalid_response',
      'provider profile kind is unknown',
    ),
  };
}

class ProviderProfileData {
  const ProviderProfileData({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.enabled,
    required this.modelId,
    this.endpoint,
    this.modelPath,
    this.secretRef,
    this.assignedRoles = const {},
  });

  final String id;
  final String displayName;
  final ProviderProfileKind kind;
  final bool enabled;
  final String modelId;
  final String? endpoint;
  final String? modelPath;
  final String? secretRef;
  final Set<ModelRole> assignedRoles;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'display_name': displayName,
    'kind': kind.wireName,
    'enabled': enabled,
    'model_id': modelId,
    'endpoint': endpoint,
    'model_path': modelPath,
    'secret_ref': secretRef,
    'assigned_roles': assignedRoles
        .map((role) => role.wireName)
        .toList(growable: false),
  };

  factory ProviderProfileData.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final displayName = value['display_name'];
    final kind = value['kind'];
    final enabled = value['enabled'];
    final modelId = value['model_id'];
    final roles = value['assigned_roles'];
    if (id is! String ||
        displayName is! String ||
        kind is! String ||
        enabled is! bool ||
        modelId is! String ||
        (roles != null && roles is! List<dynamic>) ||
        (roles is List<dynamic> &&
            roles.any(
              (item) => item is! String || ModelRole.fromWireName(item) == null,
            ))) {
      throw const CoreBridgeException(
        'invalid_response',
        'provider profile has invalid fields',
      );
    }
    return ProviderProfileData(
      id: id,
      displayName: displayName,
      kind: ProviderProfileKind.fromWireName(kind),
      enabled: enabled,
      modelId: modelId,
      endpoint: value['endpoint'] as String?,
      modelPath: value['model_path'] as String?,
      secretRef: value['secret_ref'] as String?,
      assignedRoles:
          (roles as List<dynamic>?)
              ?.map((item) => ModelRole.fromWireName(item as String)!)
              .toSet() ??
          const {},
    );
  }

  ProviderProfileData copyWith({
    bool? enabled,
    Set<ModelRole>? assignedRoles,
  }) => ProviderProfileData(
    id: id,
    displayName: displayName,
    kind: kind,
    enabled: enabled ?? this.enabled,
    modelId: modelId,
    endpoint: endpoint,
    modelPath: modelPath,
    secretRef: secretRef,
    assignedRoles: assignedRoles ?? this.assignedRoles,
  );
}

class CoreBridgeException implements Exception {
  const CoreBridgeException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'CoreBridgeException($code): $message';
}

class NativeCoreBridge
    implements
        AppCore,
        HomeWorkbenchCore,
        TranslationHistoryCore,
        PagedTranslationHistoryCore,
        ScreenshotTranslationHistoryValidationCore,
        ScreenshotTranslationHistorySummaryCore,
        DeletableTranslationHistoryCore,
        ScreenshotCaptureImageDeletionCore,
        ScreenshotCaptureImageReferenceCore,
        TranslationAnnotationCore,
        WordAnnotationCore,
        ModelPackageCore,
        ModelCatalogCore,
        DictionaryCore,
        PagedDictionaryCore,
        PagedFavoriteWordCore,
        LocalDataCore,
        StorageUsageCore,
        ContentSourceCore,
        LocalTranslationCore {
  NativeCoreBridge._(DynamicLibrary library, this._engine, this._libraryPath)
    : _schemaVersion = library
          .lookupFunction<_SchemaVersionNative, _SchemaVersionDart>(
            'yixue_bridge_schema_version',
          ),
      _processJson = library
          .lookupFunction<_ProcessJsonNative, _ProcessJsonDart>(
            'yixue_process_json',
          ),
      _stringFree = library.lookupFunction<_StringFreeNative, _StringFreeDart>(
        'yixue_string_free',
      ),
      _engineProcess = library
          .lookupFunction<_EngineProcessNative, _EngineProcessDart>(
            'yixue_engine_process_json',
          ),
      _engineFree = library.lookupFunction<_EngineFreeNative, _EngineFreeDart>(
        'yixue_engine_free',
      );

  factory NativeCoreBridge.open({String? path, String? databasePath}) {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'NativeCoreBridge currently supports Windows only',
      );
    }

    final resolvedPath =
        path ??
        '${File(Platform.resolvedExecutable).parent.path}\\yixue_ffi.dll';
    final library = DynamicLibrary.open(resolvedPath);
    var engine = nullptr.cast<Void>();
    if (databasePath != null) {
      final openEngine = library
          .lookupFunction<_EngineOpenNative, _EngineOpenDart>(
            'yixue_engine_open',
          );
      final nativePath = databasePath.toNativeUtf8();
      try {
        engine = openEngine(nativePath);
      } finally {
        malloc.free(nativePath);
      }
      if (engine == nullptr) {
        throw const CoreBridgeException(
          'engine_open_failed',
          'local provider database could not be opened',
        );
      }
    }
    return NativeCoreBridge._(library, engine, resolvedPath);
  }

  final _SchemaVersionDart _schemaVersion;
  final _ProcessJsonDart _processJson;
  final _StringFreeDart _stringFree;
  final _EngineProcessDart _engineProcess;
  final _EngineFreeDart _engineFree;
  final String _libraryPath;
  Pointer<Void> _engine;
  var _disposed = false;
  var _activeAsyncCalls = 0;

  @override
  CoreHealth health() {
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'health',
    });
    final data = response['data'];
    if (data is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'core health response has no data object',
      );
    }

    final schemaVersion = response['schema_version'];
    final coreVersion = data['core_version'];
    if (schemaVersion is! int || coreVersion is! String) {
      throw const CoreBridgeException(
        'invalid_response',
        'core health response has invalid fields',
      );
    }

    return CoreHealth(schemaVersion: schemaVersion, coreVersion: coreVersion);
  }

  @override
  void saveProviderProfile(ProviderProfileData profile) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'save_provider_profile',
      'payload': profile.toJson(),
    });
  }

  @override
  void deleteProviderProfile(String providerId) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'delete_provider_profile',
      'payload': <String, Object>{'id': providerId},
    });
  }

  @override
  List<ProviderProfileData> listProviderProfiles() {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_provider_profiles',
    });
    final data = response['data'];
    if (data is! Map<String, dynamic> || data['profiles'] is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'provider profile list is invalid',
      );
    }
    return (data['profiles'] as List<dynamic>)
        .map((value) {
          if (value is! Map<String, dynamic>) {
            throw const CoreBridgeException(
              'invalid_response',
              'provider profile entry is invalid',
            );
          }
          return ProviderProfileData.fromJson(value);
        })
        .toList(growable: false);
  }

  @override
  void saveModelCatalogEntry(ModelCatalogEntryData entry) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'save_model_catalog_entry',
      'payload': entry.toJson(),
    });
  }

  @override
  void deleteModelCatalogEntry(String modelId) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'delete_model_catalog_entry',
      'payload': <String, Object>{'id': modelId},
    });
  }

  @override
  List<ModelCatalogEntryData> listModelCatalogEntries() {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_model_catalog_entries',
    });
    final data = response['data'];
    if (data is! Map<String, dynamic> || data['models'] is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'model catalog list is invalid',
      );
    }
    return (data['models'] as List<dynamic>)
        .map((value) {
          if (value is! Map<String, dynamic>) {
            throw const CoreBridgeException(
              'invalid_response',
              'model catalog entry is invalid',
            );
          }
          return ModelCatalogEntryData.fromJson(value);
        })
        .toList(growable: false);
  }

  @override
  void saveDictionaryEntry(DictionaryEntryData entry) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'save_dictionary_entry',
      'payload': entry.toJson(),
    });
  }

  @override
  List<DictionaryEntryData> lookupDictionary(String word, {int limit = 10}) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_dictionary_entries',
      'payload': {'word': word, 'limit': limit},
    });
    final data = response['data'];
    if (data is! Map<String, dynamic> || data['entries'] is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'dictionary entry list is invalid',
      );
    }
    return (data['entries'] as List<dynamic>)
        .map(
          (value) =>
              DictionaryEntryData.fromJson(value as Map<String, dynamic>),
        )
        .toList(growable: false);
  }

  @override
  DictionaryEntryPageData listDictionaryEntryPage({
    String word = '',
    int limit = 50,
    int offset = 0,
  }) {
    if (offset < 0 || offset > 0xFFFFFFFF) {
      throw RangeError.range(offset, 0, 0xFFFFFFFF, 'offset');
    }
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_dictionary_entry_page',
      'payload': <String, Object>{
        'word': word,
        'limit': limit.clamp(1, 100).toInt(),
        'offset': offset,
      },
    });
    final data = response['data'];
    if (data is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'dictionary entry page has no data object',
      );
    }
    return DictionaryEntryPageData.fromJson(data);
  }

  @override
  void setFavoriteWord(String word, bool favorite) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'set_favorite_word',
      'payload': {
        'word': word,
        'favorite': favorite,
        'created_at': DateTime.now().toIso8601String(),
      },
    });
  }

  @override
  void clearUserData(String category) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'clear_user_data',
      'payload': <String, Object>{'category': category},
    });
  }

  @override
  StorageUsageData storageUsage() {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'storage_usage',
    });
    final data = response['data'];
    if (data is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'storage usage has no data object',
      );
    }
    try {
      return StorageUsageData.fromJson(data);
    } on FormatException catch (error) {
      throw CoreBridgeException('invalid_response', error.message);
    }
  }

  @override
  List<String> listFavoriteWords() {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_favorite_words',
    });
    final data = response['data'];
    if (data is! Map<String, dynamic> || data['words'] is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'favorite word list is invalid',
      );
    }
    final words = data['words'] as List<dynamic>;
    if (words.any((word) => word is! String)) {
      throw const CoreBridgeException(
        'invalid_response',
        'favorite word list has invalid fields',
      );
    }
    return words.cast<String>();
  }

  @override
  FavoriteWordPageData listFavoriteWordPage({
    String query = '',
    int limit = 40,
    int offset = 0,
  }) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_favorite_word_page',
      'payload': <String, Object>{
        'query': query,
        'limit': limit.clamp(1, 100).toInt(),
        'offset': offset,
      },
    });
    final data = response['data'];
    if (data is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'favorite word page has no data object',
      );
    }
    return FavoriteWordPageData.fromJson(data);
  }

  @override
  ModelPackageValidationData validateModelPackage(String modelPath) {
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'validate_model_package',
      'payload': <String, Object>{'model_path': modelPath},
    });
    final data = response['data'];
    if (data is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'model package validation response has no data object',
      );
    }
    return ModelPackageValidationData.fromJson(data);
  }

  @override
  Future<void> configureLocalTranslation({
    required String modelPath,
    required String workerPath,
  }) async {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'configure_local_translation',
      'payload': <String, Object>{
        'model_path': modelPath,
        'worker_path': workerPath,
      },
    });
  }

  @override
  Future<LocalTranslationResultData> translateLocal({
    required String id,
    required String sourceText,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    _requirePersistentEngine();
    final response = await _sendAsync(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'translate',
      'payload': <String, Object>{
        'id': id,
        'source_language': sourceLanguage,
        'target_language': targetLanguage,
        'text': sourceText,
      },
    });
    final data = response['data'];
    final translation = data is Map<String, dynamic>
        ? data['translation']
        : null;
    if (translation is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'local translation response is invalid',
      );
    }
    return LocalTranslationResultData.fromJson(translation);
  }

  @override
  Future<bool> cancelLocalTranslation(String id) async {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'cancel_translation',
      'payload': <String, Object>{'id': id},
    });
    final data = response['data'];
    final cancelled = data is Map<String, dynamic> ? data['cancelled'] : null;
    if (cancelled is! bool) {
      throw const CoreBridgeException(
        'invalid_response',
        'translation cancellation response is invalid',
      );
    }
    return cancelled;
  }

  @override
  void recordActivity(ActivityEventData activity) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'record_activity',
      'payload': activity.toJson(),
    });
  }

  @override
  void recordCompletedTranslation(CompletedTranslationData translation) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'record_completed_translation',
      'payload': translation.toJson(),
    });
  }

  @override
  List<TranslationHistoryEntryData> listTranslationHistory({int limit = 500}) {
    return _listTranslationHistoryPage(limit: limit, offset: 0);
  }

  @override
  List<TranslationHistoryEntryData> listTranslationHistoryPage({
    int limit = 50,
    int offset = 0,
    String? origin,
    String query = '',
  }) {
    return _listTranslationHistoryPage(
      limit: limit,
      offset: offset,
      origin: origin,
      query: query,
    );
  }

  List<TranslationHistoryEntryData> _listTranslationHistoryPage({
    required int limit,
    required int offset,
    String? origin,
    String query = '',
  }) {
    _requirePersistentEngine();
    final payload = <String, Object>{
      'limit': limit.clamp(0, 500),
      'offset': offset.clamp(0, 5000),
      'query': query,
    };
    if (origin != null) payload['origin'] = origin;
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_translation_history',
      'payload': payload,
    });
    final data = response['data'];
    final entries = data is Map<String, dynamic> ? data['translations'] : null;
    if (entries is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'translation history response is invalid',
      );
    }
    return entries
        .map((entry) {
          if (entry is! Map<String, dynamic>) {
            throw const CoreBridgeException(
              'invalid_response',
              'translation history entry is invalid',
            );
          }
          return TranslationHistoryEntryData.fromJson(entry);
        })
        .toList(growable: false);
  }

  @override
  void saveScreenshotTranslationSummary({
    required String id,
    required String sourceText,
    required String summaryText,
  }) {
    _requirePersistentEngine();
    if (id.trim().isEmpty ||
        id.length > 80 ||
        sourceText.trim().isEmpty ||
        sourceText.length > 5000 ||
        summaryText.trim().isEmpty ||
        summaryText.length > 20000) {
      throw const CoreBridgeException(
        'invalid_input',
        'screenshot history summary input is invalid',
      );
    }
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'save_screenshot_translation_summary',
      'payload': <String, Object>{
        'id': id,
        'source_text': sourceText,
        'summary_text': summaryText,
      },
    });
  }

  @override
  bool validateScreenshotTranslationHistory({
    required String id,
    required String sourceText,
  }) {
    _requirePersistentEngine();
    if (id.trim().isEmpty ||
        id.length > 80 ||
        sourceText.trim().isEmpty ||
        sourceText.length > 5000) {
      throw const CoreBridgeException(
        'invalid_input',
        'screenshot history validation input is invalid',
      );
    }
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'validate_screenshot_translation_history',
      'payload': <String, Object>{'id': id, 'source_text': sourceText},
    });
    final data = response['data'];
    final matches = data is Map<String, dynamic> ? data['matches'] : null;
    if (matches is! bool) {
      throw const CoreBridgeException(
        'invalid_response',
        'screenshot history validation response is invalid',
      );
    }
    return matches;
  }

  @override
  List<String> screenshotCaptureIdsOrphanedByHistoryDeletion(List<String> ids) {
    _requirePersistentEngine();
    if (ids.length > 500 ||
        ids.any((id) => id.trim().isEmpty || id.length > 300)) {
      throw const CoreBridgeException(
        'invalid_input',
        'selected translation history is invalid',
      );
    }
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'screenshot_capture_image_deletion_candidates',
      'payload': <String, Object>{'ids': ids},
    });
    final data = response['data'];
    final captureIds = data is Map<String, dynamic> ? data['captureIds'] : null;
    if (captureIds is! List<dynamic> ||
        captureIds.any((captureId) => captureId is! String)) {
      throw const CoreBridgeException(
        'invalid_response',
        'screenshot image deletion candidates are invalid',
      );
    }
    return captureIds.cast<String>();
  }

  @override
  List<String> referencedScreenshotCaptureIds(List<String> captureIds) {
    _requirePersistentEngine();
    if (captureIds.length > 500 ||
        captureIds.any((id) => id.trim().isEmpty || id.length > 300)) {
      throw const CoreBridgeException(
        'invalid_input',
        'screenshot capture references are invalid',
      );
    }
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'screenshot_capture_image_references',
      'payload': <String, Object>{'ids': captureIds},
    });
    final data = response['data'];
    final referencedIds = data is Map<String, dynamic>
        ? data['captureIds']
        : null;
    if (referencedIds is! List<dynamic> ||
        referencedIds.any((captureId) => captureId is! String)) {
      throw const CoreBridgeException(
        'invalid_response',
        'screenshot capture references response is invalid',
      );
    }
    return referencedIds.cast<String>();
  }

  @override
  void deleteTranslationHistory(List<String> ids) {
    _requirePersistentEngine();
    if (ids.length > 500 ||
        ids.any((id) => id.trim().isEmpty || id.length > 300)) {
      throw const CoreBridgeException(
        'invalid_input',
        'selected translation history is invalid',
      );
    }
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'delete_translation_history',
      'payload': <String, Object>{'ids': ids},
    });
  }

  @override
  void saveTranslationAnnotation(TranslationAnnotationData annotation) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'save_translation_annotation',
      'payload': annotation.toJson(),
    });
  }

  @override
  List<TranslationAnnotationData> listTranslationAnnotations({
    int limit = 100,
  }) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_translation_annotations',
      'payload': <String, Object>{'limit': limit.clamp(0, 500)},
    });
    final data = response['data'];
    final annotations = data is Map<String, dynamic>
        ? data['annotations']
        : null;
    if (annotations is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'translation annotation list is invalid',
      );
    }
    return annotations
        .map((value) {
          if (value is! Map<String, dynamic>) {
            throw const CoreBridgeException(
              'invalid_response',
              'translation annotation entry is invalid',
            );
          }
          return TranslationAnnotationData.fromJson(value);
        })
        .toList(growable: false);
  }

  @override
  void saveWordAnnotation(WordAnnotationData annotation) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'save_word_annotation',
      'payload': annotation.toJson(),
    });
  }

  @override
  WordAnnotationData? getWordAnnotation(String word) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'get_word_annotation',
      'payload': <String, Object>{'word': word},
    });
    final data = response['data'];
    final value = data is Map<String, dynamic> ? data['annotation'] : null;
    if (value == null) return null;
    if (value is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'word annotation response is invalid',
      );
    }
    return WordAnnotationData.fromJson(value);
  }

  @override
  void saveContentSource(ContentSourceData source) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'save_content_source',
      'payload': source.toJson(),
    });
  }

  @override
  List<ContentSourceData> listContentSources({int limit = 20}) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_content_sources',
      'payload': <String, Object>{'limit': limit.clamp(0, 100)},
    });
    final data = response['data'];
    final entries = data is Map<String, dynamic> ? data['sources'] : null;
    if (entries is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'content source response is invalid',
      );
    }
    return entries
        .map((entry) {
          if (entry is! Map<String, dynamic>) {
            throw const CoreBridgeException(
              'invalid_response',
              'content source entry is invalid',
            );
          }
          return ContentSourceData.fromJson(entry);
        })
        .toList(growable: false);
  }

  @override
  ContentSourceVersionData saveContentSourceVersion(ContentSourceData source) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'save_content_source_version',
      'payload': source.toJson(),
    });
    final data = response['data'];
    final version = data is Map<String, dynamic> ? data['version'] : null;
    if (version is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'content source version response is invalid',
      );
    }
    return ContentSourceVersionData.fromJson(version);
  }

  @override
  List<ContentSourceVersionData> listContentSourceVersions(
    String sourceId, {
    int limit = 20,
  }) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'list_content_source_versions',
      'payload': <String, Object>{
        'source_id': sourceId,
        'limit': limit.clamp(0, 100),
      },
    });
    final data = response['data'];
    final entries = data is Map<String, dynamic> ? data['versions'] : null;
    if (entries is! List<dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'content source versions response is invalid',
      );
    }
    return entries
        .map((entry) {
          if (entry is! Map<String, dynamic>) {
            throw const CoreBridgeException(
              'invalid_response',
              'content source version entry is invalid',
            );
          }
          return ContentSourceVersionData.fromJson(entry);
        })
        .toList(growable: false);
  }

  @override
  ContentSourceData restoreContentSourceVersion({
    required String sourceId,
    required String versionId,
  }) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'restore_content_source_version',
      'payload': <String, Object>{
        'source_id': sourceId,
        'version_id': versionId,
      },
    });
    final data = response['data'];
    final source = data is Map<String, dynamic> ? data['source'] : null;
    if (source is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'restored content source response is invalid',
      );
    }
    return ContentSourceData.fromJson(source);
  }

  @override
  void setContentSourceFavorite({
    required String sourceId,
    required bool favorite,
  }) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'set_content_source_favorite',
      'payload': <String, Object>{'source_id': sourceId, 'favorite': favorite},
    });
  }

  @override
  void trashContentSource(String sourceId) {
    _changeContentSourceState('trash_content_source', sourceId);
  }

  @override
  void restoreContentSource(String sourceId) {
    _changeContentSourceState('restore_content_source', sourceId);
  }

  @override
  void deleteContentSource(String sourceId) {
    _changeContentSourceState('delete_content_source', sourceId);
  }

  void _changeContentSourceState(String command, String sourceId) {
    _requirePersistentEngine();
    _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': command,
      'payload': <String, Object>{'source_id': sourceId},
    });
  }

  @override
  HomeSnapshotData homeSnapshot(String localDate, {int recentLimit = 10}) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'home_snapshot',
      'payload': <String, Object>{
        'local_date': localDate,
        'recent_limit': recentLimit,
      },
    });
    final data = response['data'];
    final snapshot = data is Map<String, dynamic> ? data['snapshot'] : null;
    if (snapshot is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'home snapshot response is invalid',
      );
    }
    return HomeSnapshotData.fromJson(snapshot);
  }

  @override
  HomeCoreSnapshotData homeWorkbenchSnapshot(
    String localDate, {
    int recentLimit = 10,
  }) {
    _requirePersistentEngine();
    final response = _send(<String, Object>{
      'schema_version': _schemaVersion(),
      'command': 'home_workbench_snapshot',
      'payload': <String, Object>{
        'local_date': localDate,
        'recent_limit': recentLimit,
      },
    });
    final data = response['data'];
    final snapshot = data is Map<String, dynamic> ? data['snapshot'] : null;
    if (snapshot is! Map<String, dynamic>) {
      throw const CoreBridgeException(
        'invalid_response',
        'home workbench snapshot response is invalid',
      );
    }
    return HomeCoreSnapshotData.fromJson(snapshot);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_activeAsyncCalls == 0) _releaseEngine();
  }

  Future<Map<String, dynamic>> _sendAsync(Map<String, Object> request) async {
    _requirePersistentEngine();
    final libraryPath = _libraryPath;
    final engineAddress = _engine.address;
    final encodedRequest = jsonEncode(request);
    _activeAsyncCalls += 1;
    try {
      final raw = await Isolate.run(
        () => _processEngineJsonInIsolate(
          libraryPath,
          engineAddress,
          encodedRequest,
        ),
      );
      return _decodeCoreResponse(raw);
    } finally {
      _activeAsyncCalls -= 1;
      if (_disposed && _activeAsyncCalls == 0) _releaseEngine();
    }
  }

  void _releaseEngine() {
    if (_engine == nullptr) return;
    _engineFree(_engine);
    _engine = nullptr.cast<Void>();
  }

  Map<String, dynamic> _send(Map<String, Object> request) {
    if (_disposed) {
      throw const CoreBridgeException(
        'bridge_disposed',
        'native core bridge is already disposed',
      );
    }
    final input = jsonEncode(request).toNativeUtf8();
    Pointer<Utf8> output = nullptr;
    try {
      output = _engine == nullptr
          ? _processJson(input)
          : _engineProcess(_engine, input);
      if (output == nullptr) {
        throw const CoreBridgeException(
          'null_response',
          'native core returned a null response',
        );
      }

      return _decodeCoreResponse(output.toDartString());
    } finally {
      malloc.free(input);
      if (output != nullptr) {
        _stringFree(output);
      }
    }
  }

  void _requirePersistentEngine() {
    if (_disposed) {
      throw const CoreBridgeException(
        'bridge_disposed',
        'native core bridge is already disposed',
      );
    }
    if (_engine == nullptr) {
      throw const CoreBridgeException(
        'engine_required',
        'provider operation requires a persistent core engine',
      );
    }
  }
}
