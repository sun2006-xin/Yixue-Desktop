import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'subtitle_session_contract.dart';

enum SubtitlePostSessionOutputKind { summary, terminology, actionItems }

enum SubtitlePostSessionProviderKind { local, remote }

/// Describes where the selected post-session generator processes transcript
/// text. A remote generator must provide a display-safe destination label that
/// can be shown before the caller sends any transcript content. Do not include
/// credentials or secret query parameters in either display field.
final class SubtitlePostSessionProviderInfo {
  const SubtitlePostSessionProviderInfo({
    required this.providerName,
    required this.kind,
    this.remoteDestinationLabel,
  });

  final String providerName;
  final SubtitlePostSessionProviderKind kind;
  final String? remoteDestinationLabel;

  bool get hasUsableDisclosure {
    if (providerName.trim().isEmpty) return false;
    return kind == SubtitlePostSessionProviderKind.local ||
        (remoteDestinationLabel?.trim().isNotEmpty ?? false);
  }

  String get processingDestination => switch (kind) {
    SubtitlePostSessionProviderKind.local => '仅在本机处理（${providerName.trim()}）',
    SubtitlePostSessionProviderKind.remote =>
      '${providerName.trim()} · ${remoteDestinationLabel?.trim() ?? '未提供服务地址'}',
  };
}

/// One confirmed subtitle segment made available to an injected generator.
/// Times are relative to the active audio capture clock, not a media player.
final class SubtitlePostSessionSourceSegment {
  SubtitlePostSessionSourceSegment({
    required this.captureAttemptId,
    required this.segmentId,
    required this.sourceId,
    required this.sourceKind,
    required this.startMs,
    required this.endMs,
    required this.sourceLanguageCode,
    required this.sourceText,
    this.targetLanguageCode,
    this.translatedText,
  }) {
    _requireText(captureAttemptId, 'captureAttemptId');
    _requireText(segmentId, 'segmentId');
    _requireText(sourceId, 'sourceId');
    _requireText(sourceLanguageCode, 'sourceLanguageCode');
    _requireText(sourceText, 'sourceText');
    if (startMs < 0 || endMs <= startMs) {
      throw ArgumentError('A source segment must have a valid time range.');
    }
  }

  final String captureAttemptId;
  final String segmentId;
  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final int startMs;
  final int endMs;
  final String sourceLanguageCode;
  final String? targetLanguageCode;
  final String sourceText;
  final String? translatedText;
}

/// Explicit request for an on-demand review of one saved subtitle session.
final class SubtitlePostSessionRequest {
  SubtitlePostSessionRequest({
    required this.sessionId,
    required this.sessionKind,
    required DateTime startedAtUtc,
    required Iterable<SubtitlePostSessionOutputKind> outputs,
    required Iterable<SubtitlePostSessionSourceSegment> segments,
  }) : startedAtUtc = startedAtUtc.toUtc(),
       outputs = Set<SubtitlePostSessionOutputKind>.unmodifiable(outputs),
       segments = List<SubtitlePostSessionSourceSegment>.unmodifiable(
         segments,
       ) {
    _requireText(sessionId, 'sessionId');
    if (this.outputs.isEmpty) {
      throw ArgumentError('Select at least one review output.');
    }
    if (this.segments.isEmpty) {
      throw ArgumentError('A review needs saved subtitle segments.');
    }
  }

  final String sessionId;
  final SubtitleSessionKind sessionKind;
  final DateTime startedAtUtc;
  final Set<SubtitlePostSessionOutputKind> outputs;
  final List<SubtitlePostSessionSourceSegment> segments;
}

/// Citation back to an exact confirmed segment and its session-relative range.
final class SubtitlePostSessionSourceRef {
  SubtitlePostSessionSourceRef({
    required this.captureAttemptId,
    required this.segmentId,
    required this.sourceId,
    required this.sourceKind,
    required this.startMs,
    required this.endMs,
  }) {
    _requireText(captureAttemptId, 'captureAttemptId');
    _requireText(segmentId, 'segmentId');
    _requireText(sourceId, 'sourceId');
    if (startMs < 0 || endMs <= startMs) {
      throw ArgumentError('A source citation must have a valid time range.');
    }
  }

  final String captureAttemptId;
  final String segmentId;
  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final int startMs;
  final int endMs;
}

final class SubtitlePostSessionInsight {
  SubtitlePostSessionInsight({
    required this.text,
    required Iterable<SubtitlePostSessionSourceRef> sources,
  }) : sources = List<SubtitlePostSessionSourceRef>.unmodifiable(sources) {
    _requireText(text, 'text');
    if (this.sources.isEmpty) {
      throw ArgumentError('Every review insight must cite source subtitles.');
    }
  }

  final String text;
  final List<SubtitlePostSessionSourceRef> sources;
}

final class SubtitlePostSessionTerm {
  SubtitlePostSessionTerm({
    required this.term,
    required this.explanation,
    required Iterable<SubtitlePostSessionSourceRef> sources,
  }) : sources = List<SubtitlePostSessionSourceRef>.unmodifiable(sources) {
    _requireText(term, 'term');
    _requireText(explanation, 'explanation');
    if (this.sources.isEmpty) {
      throw ArgumentError('Every terminology item must cite source subtitles.');
    }
  }

  final String term;
  final String explanation;
  final List<SubtitlePostSessionSourceRef> sources;
}

final class SubtitlePostSessionActionItem {
  SubtitlePostSessionActionItem({
    required this.action,
    this.owner,
    required Iterable<SubtitlePostSessionSourceRef> sources,
  }) : sources = List<SubtitlePostSessionSourceRef>.unmodifiable(sources) {
    _requireText(action, 'action');
    if (this.sources.isEmpty) {
      throw ArgumentError('Every action item must cite source subtitles.');
    }
  }

  final String action;
  final String? owner;
  final List<SubtitlePostSessionSourceRef> sources;
}

final class SubtitlePostSessionResult {
  SubtitlePostSessionResult({
    required DateTime generatedAtUtc,
    required Iterable<SubtitlePostSessionInsight> summaryPoints,
    required Iterable<SubtitlePostSessionTerm> terms,
    required Iterable<SubtitlePostSessionActionItem> actionItems,
  }) : generatedAtUtc = generatedAtUtc.toUtc(),
       summaryPoints = List<SubtitlePostSessionInsight>.unmodifiable(
         summaryPoints,
       ),
       terms = List<SubtitlePostSessionTerm>.unmodifiable(terms),
       actionItems = List<SubtitlePostSessionActionItem>.unmodifiable(
         actionItems,
       );

  final DateTime generatedAtUtc;
  final List<SubtitlePostSessionInsight> summaryPoints;
  final List<SubtitlePostSessionTerm> terms;
  final List<SubtitlePostSessionActionItem> actionItems;
}

/// Injected by the app shell so this feature does not own Provider secrets,
/// service routing, or QuickTranslationService lifecycle.
abstract interface class SubtitlePostSessionGenerator {
  SubtitlePostSessionProviderInfo get providerInfo;

  Future<SubtitlePostSessionResult> generate(
    SubtitlePostSessionRequest request,
  );
}

/// A provider may throw this exception when it has a safe message for the UI.
/// Other implementation details are intentionally not surfaced to users,
/// since transport errors can contain request metadata or credentials.
final class SubtitlePostSessionGenerationException implements Exception {
  const SubtitlePostSessionGenerationException(this.userMessage);

  final String userMessage;

  @override
  String toString() => userMessage;
}

/// A review result saved independently from the subtitle transcript store.
final class SubtitlePostSessionStoredReview {
  SubtitlePostSessionStoredReview({
    required String sessionId,
    required this.inputDigest,
    required DateTime generatedAtUtc,
    required Iterable<SubtitlePostSessionOutputKind> outputs,
    required this.providerInfo,
    required this.result,
  }) : sessionId = _requireStoredText(sessionId, 'sessionId'),
       generatedAtUtc = generatedAtUtc.toUtc(),
       outputs = Set<SubtitlePostSessionOutputKind>.unmodifiable(outputs) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(inputDigest)) {
      throw ArgumentError.value(inputDigest, 'inputDigest', 'Invalid SHA-256.');
    }
    if (this.outputs.isEmpty) {
      throw ArgumentError('A stored review must contain selected outputs.');
    }
    if (!providerInfo.hasUsableDisclosure) {
      throw ArgumentError('A stored review needs a complete Provider route.');
    }
    if (this.generatedAtUtc != result.generatedAtUtc) {
      throw ArgumentError('Stored review time must match its result.');
    }
  }

  final String sessionId;
  final String inputDigest;
  final DateTime generatedAtUtc;
  final Set<SubtitlePostSessionOutputKind> outputs;
  final SubtitlePostSessionProviderInfo providerInfo;
  final SubtitlePostSessionResult result;
}

abstract interface class SubtitlePostSessionReviewStore {
  Future<List<SubtitlePostSessionStoredReview>> listReviews();

  Future<void> saveReview(SubtitlePostSessionStoredReview review);

  Future<bool> deleteReview(String sessionId);

  /// Removes review files whose transcript session no longer exists.
  Future<int> retainSessionIds(Set<String> sessionIds);
}

/// File-backed local storage for generated meeting/video review results.
///
/// Every session uses its own digest-derived JSON filename. Writes use a
/// recoverable temp/backup rename sequence and operations are serialized with
/// an OS file lock, independently from the transcript store.
final class FileSubtitlePostSessionReviewStore
    implements SubtitlePostSessionReviewStore {
  FileSubtitlePostSessionReviewStore(this.rootDirectory);

  static const int _schemaVersion = 1;
  static const int _maxReviewBytes = 2 * 1024 * 1024;
  static const int _maxReviews = 10000;
  static final Map<String, Future<void>> _operationTails =
      <String, Future<void>>{};

  final Directory rootDirectory;

  String get _rootPath => rootDirectory.absolute.path;

  String get _rootLockKey {
    final normalized = rootDirectory.absolute.uri.normalizePath().toFilePath();
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  @override
  Future<List<SubtitlePostSessionStoredReview>> listReviews() =>
      _serialize(() async {
        if (!await rootDirectory.exists()) {
          return const <SubtitlePostSessionStoredReview>[];
        }
        await _recoverDirectory();
        final reviews = <SubtitlePostSessionStoredReview>[];
        await for (final entity in rootDirectory.list(
          recursive: false,
          followLinks: false,
        )) {
          if (entity is! File || !_isReviewFile(entity)) continue;
          final review = await _readReview(entity);
          if (review == null) continue;
          if (!_isExpectedReviewFile(entity, review.sessionId)) {
            throw const SubtitlePostSessionReviewStoreException(
              'review_path_mismatch',
            );
          }
          reviews.add(review);
        }
        reviews.sort(
          (left, right) => right.generatedAtUtc.compareTo(left.generatedAtUtc),
        );
        return List<SubtitlePostSessionStoredReview>.unmodifiable(reviews);
      });

  @override
  Future<void> saveReview(SubtitlePostSessionStoredReview review) =>
      _serialize(() async {
        await rootDirectory.create(recursive: true);
        await _recoverDirectory();
        final file = _reviewFile(review.sessionId);
        await _recoverFile(file);
        if (!await file.exists() && await _countReviews() >= _maxReviews) {
          throw const SubtitlePostSessionReviewStoreException(
            'review_limit_reached',
          );
        }
        final bytes = utf8.encode(jsonEncode(_reviewJson(review)));
        if (bytes.length > _maxReviewBytes) {
          throw const SubtitlePostSessionReviewStoreException(
            'review_record_too_large',
          );
        }
        await _atomicWrite(file, bytes);
      });

  @override
  Future<bool> deleteReview(String sessionId) => _serialize(() async {
    final file = _reviewFile(_requireStoredText(sessionId, 'sessionId'));
    await _recoverFile(file);
    final existed = await file.exists();
    await _deleteReviewFiles(file);
    return existed;
  });

  @override
  Future<int> retainSessionIds(Set<String> sessionIds) => _serialize(() async {
    if (!await rootDirectory.exists()) return 0;
    await _recoverDirectory();
    final retained = sessionIds;
    var deleted = 0;
    await for (final entity in rootDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! File || !_isReviewFile(entity)) continue;
      final review = await _readReview(entity);
      if (review == null) continue;
      if (!_isExpectedReviewFile(entity, review.sessionId)) {
        throw const SubtitlePostSessionReviewStoreException(
          'review_path_mismatch',
        );
      }
      if (!retained.contains(review.sessionId)) {
        await _deleteReviewFiles(entity);
        deleted += 1;
      }
    }
    return deleted;
  });

  Future<int> _countReviews() async {
    if (!await rootDirectory.exists()) return 0;
    await _recoverDirectory();
    var count = 0;
    await for (final entity in rootDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is File && _isReviewFile(entity)) count += 1;
    }
    return count;
  }

  Future<SubtitlePostSessionStoredReview?> _readReview(File file) async {
    await _recoverFile(file);
    if (!await file.exists()) return null;
    if (await file.length() > _maxReviewBytes) {
      throw const SubtitlePostSessionReviewStoreException(
        'stored_review_too_large',
      );
    }
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > _maxReviewBytes) {
        throw const SubtitlePostSessionReviewStoreException(
          'stored_review_too_large',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('expected an object');
      }
      return _storedReviewFromJson(decoded);
    } on SubtitlePostSessionReviewStoreException {
      rethrow;
    } on FormatException {
      throw const SubtitlePostSessionReviewStoreException('corrupt_review');
    } on ArgumentError {
      throw const SubtitlePostSessionReviewStoreException('corrupt_review');
    } on TypeError {
      throw const SubtitlePostSessionReviewStoreException('corrupt_review');
    }
  }

  Future<void> _atomicWrite(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    if (await temp.exists()) await temp.delete();
    if (await backup.exists()) await backup.delete();
    await temp.writeAsBytes(bytes, flush: true);
    try {
      if (await file.exists()) await file.rename(backup.path);
      await temp.rename(file.path);
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
    if (await backup.exists()) {
      try {
        await backup.delete();
      } on FileSystemException {
        // The target rename is the commit point; backup cleanup can be retried.
      }
    }
  }

  Future<void> _recoverFile(File file) async {
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    if (await file.exists()) {
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The committed target is authoritative.
        }
      }
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Ignore an abandoned temp file while the target exists.
        }
      }
      return;
    }
    if (await backup.exists()) await backup.rename(file.path);
    if (await temp.exists()) {
      try {
        await temp.delete();
      } on FileSystemException {
        // Temporary files are never authoritative.
      }
    }
  }

  Future<void> _recoverDirectory() async {
    if (!await rootDirectory.exists()) return;
    final targets = <String>{};
    await for (final entity in rootDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final path = entity.path;
      final name = entity.uri.pathSegments.last;
      for (final suffix in const <String>['.tmp', '.bak']) {
        if (!name.endsWith('.json$suffix')) continue;
        final targetPath = path.substring(0, path.length - suffix.length);
        if (_isReviewFile(File(targetPath))) targets.add(targetPath);
        break;
      }
    }
    for (final path in targets) {
      await _recoverFile(File(path));
    }
  }

  Future<void> _deleteReviewFiles(File file) async {
    // Remove recovery copies first. Deleting the authoritative target last
    // prevents startup recovery from restoring a review after a committed
    // deletion if the process stops midway through cleanup.
    for (final candidate in <File>[
      File('${file.path}.tmp'),
      File('${file.path}.bak'),
      file,
    ]) {
      if (await candidate.exists()) await candidate.delete();
    }
  }

  File _reviewFile(String sessionId) => File(
    '$_rootPath${Platform.pathSeparator}'
    'review-${_sessionDigest(sessionId)}.json',
  );

  bool _isReviewFile(File file) =>
      RegExp(r'^review-[0-9a-f]{64}\.json$')
          .hasMatch(file.uri.pathSegments.last);

  bool _isExpectedReviewFile(File file, String sessionId) {
    final expectedPath = _reviewFile(sessionId).absolute.path;
    final actualPath = file.absolute.path;
    return Platform.isWindows
        ? expectedPath.toLowerCase() == actualPath.toLowerCase()
        : expectedPath == actualPath;
  }

  static String _sessionDigest(String sessionId) =>
      sha256.convert(utf8.encode(sessionId)).toString();

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final rootKey = _rootLockKey;
    final previous = _operationTails[rootKey] ?? Future<void>.value();
    final next = previous.then((_) async {
      RandomAccessFile? lockHandle;
      var locked = false;
      try {
        await rootDirectory.create(recursive: true);
        final handle = await File(
          '$_rootPath${Platform.pathSeparator}.review-store.lock',
        ).open(mode: FileMode.append);
        lockHandle = handle;
        await handle.lock(FileLock.blockingExclusive);
        locked = true;
        completer.complete(await operation());
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      } finally {
        final handle = lockHandle;
        if (handle != null) {
          if (locked) {
            try {
              await handle.unlock();
            } on FileSystemException {
              // Closing the handle still releases the operating-system lock.
            }
          }
          try {
            await handle.close();
          } on FileSystemException {
            // The operation result has already been committed or reported.
          }
        }
      }
    });
    late final Future<void> queued;
    queued = next.then<void>(
      (_) {
        if (identical(_operationTails[rootKey], queued)) {
          _operationTails.remove(rootKey);
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_operationTails[rootKey], queued)) {
          _operationTails.remove(rootKey);
        }
      },
    );
    _operationTails[rootKey] = queued;
    return completer.future;
  }
}

final class SubtitlePostSessionReviewStoreException implements Exception {
  const SubtitlePostSessionReviewStoreException(this.code);

  final String code;

  @override
  String toString() => 'SubtitlePostSessionReviewStoreException($code)';
}

/// Stable digest of the transcript and translation inputs used for a review.
/// Selected output types are stored separately, so changing the outputs does
/// not make an otherwise matching review stale.
String subtitlePostSessionInputDigest(SubtitlePostSessionRequest request) {
  final segments = request.segments.toList()
    ..sort((left, right) {
      final start = left.startMs.compareTo(right.startMs);
      if (start != 0) return start;
      final source = left.sourceId.compareTo(right.sourceId);
      if (source != 0) return source;
      final sourceKind = left.sourceKind.name.compareTo(right.sourceKind.name);
      if (sourceKind != 0) return sourceKind;
      final attempt = left.captureAttemptId.compareTo(right.captureAttemptId);
      if (attempt != 0) return attempt;
      return left.segmentId.compareTo(right.segmentId);
    });
  final input = <String, Object?>{
    'sessionId': request.sessionId,
    'sessionKind': request.sessionKind.name,
    'startedAtUtc': request.startedAtUtc.toUtc().toIso8601String(),
    'segments': <Map<String, Object?>>[
      for (final segment in segments)
        <String, Object?>{
          'captureAttemptId': segment.captureAttemptId,
          'segmentId': segment.segmentId,
          'sourceId': segment.sourceId,
          'sourceKind': segment.sourceKind.name,
          'startMs': segment.startMs,
          'endMs': segment.endMs,
          'sourceLanguageCode': segment.sourceLanguageCode,
          'targetLanguageCode': segment.targetLanguageCode,
          'sourceText': segment.sourceText,
          'translatedText': segment.translatedText,
        },
    ],
  };
  return sha256.convert(utf8.encode(jsonEncode(input))).toString();
}

Map<String, Object?> _reviewJson(SubtitlePostSessionStoredReview review) =>
    <String, Object?>{
      'schemaVersion': FileSubtitlePostSessionReviewStore._schemaVersion,
      'sessionId': review.sessionId,
      'inputDigest': review.inputDigest,
      'generatedAtUtc': review.generatedAtUtc.toIso8601String(),
      'outputs': review.outputs.map((output) => output.name).toList(),
      'providerInfo': <String, Object?>{
        'providerName': review.providerInfo.providerName,
        'kind': review.providerInfo.kind.name,
        'remoteDestinationLabel': review.providerInfo.remoteDestinationLabel,
      },
      'result': _resultJson(review.result),
    };

Map<String, Object?> _resultJson(SubtitlePostSessionResult result) =>
    <String, Object?>{
      'generatedAtUtc': result.generatedAtUtc.toIso8601String(),
      'summaryPoints': <Map<String, Object?>>[
        for (final item in result.summaryPoints)
          <String, Object?>{
            'text': item.text,
            'sources': item.sources.map(_sourceRefJson).toList(),
          },
      ],
      'terms': <Map<String, Object?>>[
        for (final item in result.terms)
          <String, Object?>{
            'term': item.term,
            'explanation': item.explanation,
            'sources': item.sources.map(_sourceRefJson).toList(),
          },
      ],
      'actionItems': <Map<String, Object?>>[
        for (final item in result.actionItems)
          <String, Object?>{
            'action': item.action,
            'owner': item.owner,
            'sources': item.sources.map(_sourceRefJson).toList(),
          },
      ],
    };

Map<String, Object?> _sourceRefJson(SubtitlePostSessionSourceRef source) =>
    <String, Object?>{
      'captureAttemptId': source.captureAttemptId,
      'segmentId': source.segmentId,
      'sourceId': source.sourceId,
      'sourceKind': source.sourceKind.name,
      'startMs': source.startMs,
      'endMs': source.endMs,
    };

SubtitlePostSessionStoredReview _storedReviewFromJson(
  Map<String, dynamic> value,
) {
  if (value['schemaVersion'] !=
      FileSubtitlePostSessionReviewStore._schemaVersion) {
    throw const FormatException('unsupported review schema');
  }
  final provider = _mapValue(value['providerInfo'], 'providerInfo');
  final result = _mapValue(value['result'], 'result');
  return SubtitlePostSessionStoredReview(
    sessionId: _stringValue(value['sessionId'], 'sessionId'),
    inputDigest: _stringValue(value['inputDigest'], 'inputDigest'),
    generatedAtUtc: _dateValue(value['generatedAtUtc'], 'generatedAtUtc'),
    outputs: _listValue(
      value['outputs'],
      'outputs',
    ).map((item) => _enumByName(SubtitlePostSessionOutputKind.values, item)),
    providerInfo: SubtitlePostSessionProviderInfo(
      providerName: _stringValue(provider['providerName'], 'providerName'),
      kind: _enumByName(
        SubtitlePostSessionProviderKind.values,
        provider['kind'],
      ),
      remoteDestinationLabel: _optionalStringValue(
        provider['remoteDestinationLabel'],
        'remoteDestinationLabel',
      ),
    ),
    result: SubtitlePostSessionResult(
      generatedAtUtc: _dateValue(result['generatedAtUtc'], 'generatedAtUtc'),
      summaryPoints: _listValue(result['summaryPoints'], 'summaryPoints').map((
        item,
      ) {
        final insight = _mapValue(item, 'summaryPoint');
        return SubtitlePostSessionInsight(
          text: _stringValue(insight['text'], 'text'),
          sources: _listValue(
            insight['sources'],
            'sources',
          ).map(_sourceRefFromJson),
        );
      }),
      terms: _listValue(result['terms'], 'terms').map((item) {
        final term = _mapValue(item, 'term');
        return SubtitlePostSessionTerm(
          term: _stringValue(term['term'], 'term'),
          explanation: _stringValue(term['explanation'], 'explanation'),
          sources: _listValue(
            term['sources'],
            'sources',
          ).map(_sourceRefFromJson),
        );
      }),
      actionItems: _listValue(result['actionItems'], 'actionItems').map((item) {
        final action = _mapValue(item, 'actionItem');
        return SubtitlePostSessionActionItem(
          action: _stringValue(action['action'], 'action'),
          owner: _optionalStringValue(action['owner'], 'owner'),
          sources: _listValue(
            action['sources'],
            'sources',
          ).map(_sourceRefFromJson),
        );
      }),
    ),
  );
}

SubtitlePostSessionSourceRef _sourceRefFromJson(Object? value) {
  final source = _mapValue(value, 'source');
  return SubtitlePostSessionSourceRef(
    captureAttemptId: _stringValue(
      source['captureAttemptId'],
      'captureAttemptId',
    ),
    segmentId: _stringValue(source['segmentId'], 'segmentId'),
    sourceId: _stringValue(source['sourceId'], 'sourceId'),
    sourceKind: _enumByName(
      SubtitleAudioSourceKind.values,
      source['sourceKind'],
    ),
    startMs: _intValue(source['startMs'], 'startMs'),
    endMs: _intValue(source['endMs'], 'endMs'),
  );
}

Map<String, dynamic> _mapValue(Object? value, String name) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$name must be an object');
  }
  return value;
}

List<Object?> _listValue(Object? value, String name) {
  if (value is! List) throw FormatException('$name must be a list');
  return value.cast<Object?>();
}

String _stringValue(Object? value, String name) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$name must be a non-empty string');
  }
  return value;
}

String? _optionalStringValue(Object? value, String name) {
  if (value == null) return null;
  if (value is! String) throw FormatException('$name must be a string');
  return value;
}

int _intValue(Object? value, String name) {
  if (value is! int) throw FormatException('$name must be an integer');
  return value;
}

DateTime _dateValue(Object? value, String name) {
  final text = _stringValue(value, name);
  final date = DateTime.tryParse(text);
  if (date == null) throw FormatException('$name must be a date');
  return date.toUtc();
}

T _enumByName<T extends Enum>(List<T> values, Object? value) {
  final name = _stringValue(value, 'enum');
  for (final item in values) {
    if (item.name == name) return item;
  }
  throw const FormatException('unknown enum value');
}

String _requireStoredText(String value, String name) {
  if (value.trim().isEmpty) throw ArgumentError('$name must not be empty.');
  if (value.length > 256) throw ArgumentError('$name is too long.');
  return value;
}

/// Reject malformed or fabricated citations before displaying generator output.
void validateSubtitlePostSessionResult(
  SubtitlePostSessionRequest request,
  SubtitlePostSessionResult result,
) {
  final sourceRanges = <String, (int, int, String, SubtitleAudioSourceKind)>{
    for (final segment in request.segments)
      _sourceKey(
        segment.captureAttemptId,
        segment.segmentId,
        segment.sourceId,
        segment.sourceKind,
      ): (
        segment.startMs,
        segment.endMs,
        segment.sourceId,
        segment.sourceKind,
      ),
  };

  void validateSources(Iterable<SubtitlePostSessionSourceRef> sources) {
    for (final source in sources) {
      final expected =
          sourceRanges[_sourceKey(
            source.captureAttemptId,
            source.segmentId,
            source.sourceId,
            source.sourceKind,
          )];
      if (expected == null ||
          expected.$1 != source.startMs ||
          expected.$2 != source.endMs ||
          expected.$3 != source.sourceId ||
          expected.$4 != source.sourceKind) {
        throw const FormatException('复盘结果包含不属于当前字幕会话的来源引用。');
      }
    }
  }

  for (final item in result.summaryPoints) {
    validateSources(item.sources);
  }
  for (final item in result.terms) {
    validateSources(item.sources);
  }
  for (final item in result.actionItems) {
    validateSources(item.sources);
  }
}

String _sourceKey(
  String captureAttemptId,
  String segmentId,
  String sourceId,
  SubtitleAudioSourceKind sourceKind,
) => jsonEncode(<String>[
  captureAttemptId,
  segmentId,
  sourceId,
  sourceKind.name,
]);

void _requireText(String value, String name) {
  if (value.trim().isEmpty) throw ArgumentError('$name must not be empty.');
}
