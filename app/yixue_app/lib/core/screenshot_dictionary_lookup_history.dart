import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';

const screenshotDictionaryLookupHistoryLimit = 24;

enum ScreenshotDictionaryLookupKind { dictionary, modelTranslation }

/// A successful dictionary result plus the screenshot context shown when it
/// was looked up. This history is deliberately independent of the wordbook.
final class ScreenshotDictionaryLookupHistoryRecord {
  const ScreenshotDictionaryLookupHistoryRecord({
    required this.entry,
    this.recordId,
    this.lookupQuery = '',
    this.lookupKind = ScreenshotDictionaryLookupKind.dictionary,
    this.modelTranslation,
    required this.sessionId,
    required this.sourceContext,
    this.recognizedTextSnapshot = '',
    required this.translationSnapshot,
    required this.recordedAt,
  });

  factory ScreenshotDictionaryLookupHistoryRecord.modelTrial({
    required String lookupQuery,
    required String sessionId,
    required String sourceContext,
    String recognizedTextSnapshot = '',
    required String translationSnapshot,
    required String modelTranslation,
    required DateTime recordedAt,
  }) => ScreenshotDictionaryLookupHistoryRecord(
    entry: ScreenshotDictionaryLookupResult(
      word: lookupQuery.trim(),
      ipa: '',
      partOfSpeech: '',
      meanings: const [],
      example: '',
      exampleTranslation: '',
      qualityStatus: 'model_translation',
      examples: const [],
    ),
    lookupQuery: lookupQuery.trim(),
    lookupKind: ScreenshotDictionaryLookupKind.modelTranslation,
    modelTranslation: modelTranslation,
    sessionId: sessionId,
    sourceContext: sourceContext,
    recognizedTextSnapshot: recognizedTextSnapshot,
    translationSnapshot: translationSnapshot,
    recordedAt: recordedAt,
  );

  final ScreenshotDictionaryLookupResult entry;
  final String? recordId;

  /// The exact user-entered term; empty on older call sites means entry.word.
  final String lookupQuery;
  final ScreenshotDictionaryLookupKind lookupKind;
  final String? modelTranslation;

  bool get isModelTranslation =>
      lookupKind == ScreenshotDictionaryLookupKind.modelTranslation;

  final String sessionId;
  final String sourceContext;
  final String recognizedTextSnapshot;
  final String translationSnapshot;
  final DateTime recordedAt;

  String get id {
    final savedId = recordId?.trim();
    if (savedId != null && savedId.isNotEmpty) return savedId;
    return '${sessionId}\u0000${lookupQuery.trim().isEmpty ? entry.word : lookupQuery.trim()}\u0000${recordedAt.toUtc().microsecondsSinceEpoch}';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'entry': {
      'word': entry.word,
      'ipa': entry.ipa,
      'partOfSpeech': entry.partOfSpeech,
      'meanings': entry.meanings,
      'example': entry.example,
      'exampleTranslation': entry.exampleTranslation,
      'qualityStatus': entry.qualityStatus,
      'examples': [
        for (final example in entry.examples)
          {
            'englishText': example.englishText,
            'chineseText': example.chineseText,
            'reviewStatus': example.reviewStatus,
          },
      ],
      'variants': entry.variants,
      'collocations': entry.collocations,
      'relations': entry.relations,
    },
    'lookupQuery': lookupQuery.trim().isEmpty ? entry.word : lookupQuery.trim(),
    'lookupKind': lookupKind.name,
    if (modelTranslation != null) 'modelTranslation': modelTranslation,
    'sessionId': sessionId,
    'sourceContext': sourceContext,
    'recognizedTextSnapshot': recognizedTextSnapshot,
    'translationSnapshot': translationSnapshot,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
  };

  static ScreenshotDictionaryLookupHistoryRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final entryValue = raw['entry'];
    if (entryValue is! Map) return null;

    String? text(Object? value, {required int maxLength}) =>
        value is String && value.length <= maxLength ? value : null;
    final word = text(entryValue['word'], maxLength: 128);
    final ipa = text(entryValue['ipa'], maxLength: 512);
    final partOfSpeech = text(entryValue['partOfSpeech'], maxLength: 512);
    final example = text(entryValue['example'], maxLength: 10000);
    final exampleTranslation = text(
      entryValue['exampleTranslation'],
      maxLength: 10000,
    );
    final qualityStatus = text(entryValue['qualityStatus'], maxLength: 128);
    final recordId = raw['id'] == null
        ? null
        : text(raw['id'], maxLength: 256)?.trim();
    final lookupQuery = text(raw['lookupQuery'], maxLength: 128)?.trim();
    final lookupKind = switch (raw['lookupKind']) {
      null || 'dictionary' => ScreenshotDictionaryLookupKind.dictionary,
      'modelTranslation' => ScreenshotDictionaryLookupKind.modelTranslation,
      _ => null,
    };
    final modelTranslation = raw['modelTranslation'] == null
        ? null
        : text(raw['modelTranslation'], maxLength: 10000);
    final sessionId = text(raw['sessionId'], maxLength: 512);
    final sourceContext = text(raw['sourceContext'], maxLength: 2000);
    final recognizedTextSnapshot = raw['recognizedTextSnapshot'] == null
        ? sourceContext
        : text(raw['recognizedTextSnapshot'], maxLength: 100000);
    final translationSnapshot = text(
      raw['translationSnapshot'],
      maxLength: 200000,
    );
    final recordedAtValue = raw['recordedAt'];
    final recordedAt = recordedAtValue is String
        ? DateTime.tryParse(recordedAtValue)
        : null;
    final rawMeanings = entryValue['meanings'];
    final rawExamples = entryValue['examples'];
    final rawVariants = entryValue['variants'] ?? const <Object?>[];
    final rawCollocations = entryValue['collocations'] ?? const <Object?>[];
    final rawRelations = entryValue['relations'] ?? const <String, Object?>{};
    if (word == null ||
        word.trim().isEmpty ||
        ipa == null ||
        partOfSpeech == null ||
        example == null ||
        exampleTranslation == null ||
        qualityStatus == null ||
        (raw['id'] != null && (recordId == null || recordId.isEmpty)) ||
        lookupKind == null ||
        (raw['modelTranslation'] != null && modelTranslation == null) ||
        (lookupKind == ScreenshotDictionaryLookupKind.modelTranslation &&
            (modelTranslation == null || modelTranslation.trim().isEmpty)) ||
        (lookupKind == ScreenshotDictionaryLookupKind.dictionary &&
            modelTranslation != null) ||
        sessionId == null ||
        sourceContext == null ||
        recognizedTextSnapshot == null ||
        translationSnapshot == null ||
        recordedAt == null ||
        rawMeanings is! List ||
        rawMeanings.length > 100 ||
        rawExamples is! List ||
        rawExamples.length > 100 ||
        rawVariants is! List ||
        rawVariants.length > 100 ||
        rawCollocations is! List ||
        rawCollocations.length > 100 ||
        rawRelations is! Map ||
        rawRelations.length > 100) {
      return null;
    }

    final meanings = <String>[];
    for (final meaning in rawMeanings) {
      final value = text(meaning, maxLength: 4000);
      if (value == null) return null;
      meanings.add(value);
    }
    final examples = <ScreenshotDictionaryExample>[];
    for (final value in rawExamples) {
      if (value is! Map) return null;
      final englishText = text(value['englishText'], maxLength: 10000);
      final chineseText = text(value['chineseText'], maxLength: 10000);
      final reviewStatus = text(value['reviewStatus'], maxLength: 128);
      if (englishText == null || chineseText == null || reviewStatus == null) {
        return null;
      }
      examples.add(
        ScreenshotDictionaryExample(
          englishText: englishText,
          chineseText: chineseText,
          reviewStatus: reviewStatus,
        ),
      );
    }

    List<String>? parseTerms(Object? raw) {
      if (raw is! List || raw.length > 100) return null;
      final terms = <String>[];
      for (final term in raw) {
        final value = text(term, maxLength: 512);
        if (value == null) return null;
        terms.add(value);
      }
      return List.unmodifiable(terms);
    }

    final variants = parseTerms(rawVariants);
    final collocations = parseTerms(rawCollocations);
    if (variants == null || collocations == null) return null;
    final relations = <String, List<String>>{};
    for (final item in rawRelations.entries) {
      final label = text(item.key, maxLength: 128);
      final values = parseTerms(item.value);
      if (label == null || values == null) return null;
      relations[label] = values;
    }

    return ScreenshotDictionaryLookupHistoryRecord(
      entry: ScreenshotDictionaryLookupResult(
        word: word,
        ipa: ipa,
        partOfSpeech: partOfSpeech,
        meanings: List.unmodifiable(meanings),
        example: example,
        exampleTranslation: exampleTranslation,
        qualityStatus: qualityStatus,
        examples: List.unmodifiable(examples),
        variants: variants,
        collocations: collocations,
        relations: Map.unmodifiable(relations),
      ),
      recordId: recordId,
      lookupQuery: lookupQuery == null || lookupQuery.isEmpty
          ? word
          : lookupQuery,
      lookupKind: lookupKind,
      modelTranslation: modelTranslation,
      sessionId: sessionId,
      sourceContext: sourceContext,
      recognizedTextSnapshot: recognizedTextSnapshot,
      translationSnapshot: translationSnapshot,
      recordedAt: recordedAt.toUtc(),
    );
  }
}

abstract interface class ScreenshotDictionaryLookupHistoryStore {
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read();

  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  );

  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(String id);

  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear();
}

/// A small sidecar store: successful screenshot word lookups are not saved to
/// the learning wordbook unless the user separately chooses that action.
final class FileScreenshotDictionaryLookupHistoryStore
    implements ScreenshotDictionaryLookupHistoryStore {
  FileScreenshotDictionaryLookupHistoryStore(this.file);

  static const schemaVersion = 2;
  static const maxEntries = screenshotDictionaryLookupHistoryLimit;
  static const _maxFileBytes = 16 * 1024 * 1024;

  final File file;
  Future<void> _tail = Future<void>.value();

  File get _lockFile => File('${file.path}.lock');
  File get _previousFile => File('${file.path}.previous');

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read() async {
    await _tail;
    return _withFileLock(_readFile);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) {
    final operation = _tail.then((_) async {
      return _withFileLock(() async {
        final entries = await _readFile();
        final next = <ScreenshotDictionaryLookupHistoryRecord>[
          record,
          ...entries,
        ].take(maxEntries).toList(growable: false);
        await _writeEntries(next);
        return next;
      });
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(String id) {
    final operation = _tail.then((_) async {
      return _withFileLock(() async {
        final current = await _readFile();
        final next = current
            .where((record) => record.id != id)
            .toList(growable: false);
        if (next.length != current.length) await _writeEntries(next);
        return next;
      });
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear() {
    final operation = _tail.then((_) async {
      return _withFileLock(() async {
        await _writeEntries(const []);
        return const <ScreenshotDictionaryLookupHistoryRecord>[];
      });
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _writeEntries(
    List<ScreenshotDictionaryLookupHistoryRecord> entries,
  ) async {
    final encoded = jsonEncode({
      'schemaVersion': schemaVersion,
      'entries': [for (final entry in entries) entry.toJson()],
    });
    if (utf8.encode(encoded).length > _maxFileBytes) {
      throw const FileSystemException(
        'Screenshot lookup history exceeds the local storage limit',
      );
    }
    await _writeAtomically(encoded);
  }

  Future<T> _withFileLock<T>(Future<T> Function() action) async {
    await file.parent.create(recursive: true);
    final lockHandle = await _lockFile.open(mode: FileMode.append);
    var locked = false;
    try {
      await lockHandle.lock(FileLock.blockingExclusive);
      locked = true;
      return await action();
    } finally {
      if (locked) await lockHandle.unlock();
      await lockHandle.close();
    }
  }

  Future<void> _writeAtomically(String contents) async {
    final temporary = File(
      '${file.path}.${pid}.${DateTime.now().toUtc().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(contents, flush: true);
      if (await file.exists()) await file.copy(_previousFile.path);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<List<ScreenshotDictionaryLookupHistoryRecord>> _readFile() async {
    if (!await file.exists()) {
      if (!await _previousFile.exists()) return const [];
      final recovered = await _decodeFile(_previousFile);
      await _previousFile.copy(file.path);
      return recovered;
    }
    try {
      return await _decodeFile(file);
    } on FormatException catch (error) {
      final preserved = await _preserveCorruptFile();
      if (await _previousFile.exists()) {
        try {
          final recovered = await _decodeFile(_previousFile);
          await _previousFile.copy(file.path);
          return recovered;
        } on FormatException {
          // Both copies are retained; report the damaged current file below.
        }
      }
      throw FileSystemException(
        'Screenshot lookup history is damaged and was preserved at '
        '"${preserved.path}": $error',
        file.path,
      );
    }
  }

  Future<List<ScreenshotDictionaryLookupHistoryRecord>> _decodeFile(
    File source,
  ) async {
    if (await source.length() > _maxFileBytes) {
      throw const FormatException('History file exceeds the size limit');
    }
    final value = jsonDecode(await source.readAsString());
    if (value is! Map ||
        (value['schemaVersion'] != 1 &&
            value['schemaVersion'] != schemaVersion) ||
        value['entries'] is! List) {
      throw const FormatException('History schema is not supported');
    }
    final rawEntries = value['entries'] as List;
    if (rawEntries.length > maxEntries) {
      throw const FormatException('History has more entries than supported');
    }
    final entries = <ScreenshotDictionaryLookupHistoryRecord>[];
    for (final raw in rawEntries) {
      final record = ScreenshotDictionaryLookupHistoryRecord.tryParse(raw);
      if (record == null) {
        throw const FormatException('History contains an invalid entry');
      }
      entries.add(record);
    }
    return List.unmodifiable(entries);
  }

  Future<File> _preserveCorruptFile() async {
    var preserved = File('${file.path}.corrupt');
    if (await preserved.exists()) {
      preserved = File(
        '${file.path}.corrupt.${DateTime.now().toUtc().microsecondsSinceEpoch}',
      );
    }
    await file.copy(preserved.path);
    return preserved;
  }
}
