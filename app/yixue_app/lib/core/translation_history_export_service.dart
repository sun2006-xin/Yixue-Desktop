import 'dart:convert';
import 'dart:io';

import 'native_core_bridge.dart';

/// Serializes local translation history for a user-selected local file.
///
/// The export format is intentionally allow-listed. Provider endpoints,
/// secret references, API keys and model files are never copied into the
/// history archive, even if a provider implementation stores them elsewhere.
class TranslationHistoryExportService {
  const TranslationHistoryExportService();

  static String encode({
    required List<TranslationHistoryEntryData> history,
    required List<TranslationAnnotationData> annotations,
    DateTime Function()? now,
  }) {
    final payload = <String, Object?>{
      'schemaVersion': 1,
      'product': '译学',
      'exportedAt': (now ?? DateTime.now)().toIso8601String(),
      'history': history.map(_historyToJson).toList(growable: false),
      'annotations': annotations
          .map((annotation) => annotation.toJson())
          .toList(growable: false),
      'excluded': const [
        'API keys',
        'credential references',
        'provider endpoints',
        'model weights',
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Writes an allow-listed archive to a path selected by the user.
  static Future<File> write({
    required String path,
    required List<TranslationHistoryEntryData> history,
    required List<TranslationAnnotationData> annotations,
    DateTime Function()? now,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      encode(history: history, annotations: annotations, now: now),
      flush: true,
    );
    return file;
  }

  static Map<String, Object> _historyToJson(TranslationHistoryEntryData entry) {
    return <String, Object>{
      'id': entry.id,
      'source_language': entry.sourceLanguage,
      'target_language': entry.targetLanguage,
      'source_text': entry.sourceText,
      'translated_text': entry.translatedText,
      'provider_id': entry.providerId,
      'created_at': entry.createdAt,
      'origin': entry.origin,
    };
  }
}
