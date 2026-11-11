import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'subtitle_session_contract.dart';

enum SubtitleSessionHistoryStatus {
  preparing,
  capturing,
  paused,
  completed,
  interrupted,
  failed,
}

/// How source language selection was made when the session started.
///
/// `auto` is a recognition mode, not a transcript language code. Legacy
/// manifests without this field are represented as `null`.
enum SubtitleRecognitionMode { manual, auto }

/// Durable session metadata plus the latest confirmed revision of each cue.
/// Audio frames, interim ASR text, Provider credentials, and recording paths
/// are deliberately outside this record.
final class SubtitleSessionRecord {
  SubtitleSessionRecord({
    required String sessionId,
    required this.kind,
    required this.sourceKind,
    Iterable<SubtitleSessionAudioSource> sources =
        const <SubtitleSessionAudioSource>[],
    String? targetLanguageCode,
    required this.recognitionMode,
    required DateTime startedAtUtc,
    required this.status,
    DateTime? endedAtUtc,
    Iterable<SubtitleSegment> segments = const <SubtitleSegment>[],
    this.corruptSegmentCount = 0,
  }) : sessionId = _requireNonEmpty(sessionId, 'sessionId'),
       targetLanguageCode = targetLanguageCode == null
           ? null
           : _requireNonEmpty(targetLanguageCode, 'targetLanguageCode').trim(),
       startedAtUtc = startedAtUtc.toUtc(),
       endedAtUtc = endedAtUtc?.toUtc(),
       segments = List<SubtitleSegment>.unmodifiable(segments),
       sources = _normalizeSources(sources, segments) {
    if (corruptSegmentCount < 0) {
      throw ArgumentError.value(
        corruptSegmentCount,
        'corruptSegmentCount',
        'Must not be negative.',
      );
    }
    if (this.sessionId.length > 256) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'Must be <= 256 chars.',
      );
    }
    if (this.endedAtUtc != null &&
        this.endedAtUtc!.isBefore(this.startedAtUtc)) {
      throw ArgumentError.value(
        endedAtUtc,
        'endedAtUtc',
        'Must not be earlier than startedAtUtc.',
      );
    }
    if (_isTerminalHistoryStatus(status) != (this.endedAtUtc != null)) {
      throw ArgumentError(
        'Terminal sessions require endedAtUtc; active sessions must not have it.',
      );
    }
    final seen = <SubtitleSegmentKey>{};
    for (final segment in this.segments) {
      final sourceMatches = this.sources.isEmpty
          ? segment.transcript.sourceKind == sourceKind
          : this.sources.any(
              (source) =>
                  source.sourceId == segment.transcript.sourceId &&
                  source.sourceKind == segment.transcript.sourceKind,
            );
      if (segment.transcript.sessionId != this.sessionId ||
          !sourceMatches ||
          !segment.transcript.isFinal ||
          segment.transcript.text.trim().isEmpty) {
        throw ArgumentError(
          'A history record can contain only matching, '
          'non-empty finalized subtitle segments.',
        );
      }
      if (!seen.add(segment.key)) {
        throw ArgumentError('A history record cannot contain duplicate keys.');
      }
    }
  }

  final String sessionId;
  final SubtitleSessionKind kind;

  /// Legacy primary source kind retained for existing callers and history
  /// cards. Per-cue source identity lives on each transcript revision.
  final SubtitleAudioSourceKind sourceKind;

  /// All capture inputs declared by a multi-source session. Legacy records
  /// can have an empty list when they contain no source-bearing cues.
  final List<SubtitleSessionAudioSource> sources;

  /// Null only for legacy records without persisted target-language metadata.
  final String? targetLanguageCode;

  /// Null only for legacy or otherwise unknown recognition-mode metadata.
  final SubtitleRecognitionMode? recognitionMode;
  final DateTime startedAtUtc;
  final DateTime? endedAtUtc;
  final SubtitleSessionHistoryStatus status;
  final List<SubtitleSegment> segments;

  /// Number of cue files skipped while restoring this session. The files are
  /// kept on disk so users can recover them separately if needed.
  final int corruptSegmentCount;

  SubtitleSessionRecord copyWith({
    SubtitleSessionHistoryStatus? status,
    DateTime? endedAtUtc,
    bool clearEndedAtUtc = false,
    Iterable<SubtitleSegment>? segments,
    int? corruptSegmentCount,
  }) => SubtitleSessionRecord(
    sessionId: sessionId,
    kind: kind,
    sourceKind: sourceKind,
    sources: sources,
    targetLanguageCode: targetLanguageCode,
    recognitionMode: recognitionMode,
    startedAtUtc: startedAtUtc,
    endedAtUtc: clearEndedAtUtc ? null : endedAtUtc ?? this.endedAtUtc,
    status: status ?? this.status,
    segments: segments ?? this.segments,
    corruptSegmentCount: corruptSegmentCount ?? this.corruptSegmentCount,
  );
}

abstract interface class SubtitleSessionStore {
  Future<void> createSession(SubtitleSessionRecord session);

  Future<void> updateSessionStatus(
    String sessionId,
    SubtitleSessionHistoryStatus status, {
    DateTime? endedAtUtc,
  });

  Future<void> saveConfirmedSegment(
    String sessionId,
    SubtitleSegment segment, {
    String? translatedTargetLanguageCode,
  });

  Future<SubtitleSessionRecord?> readSession(String sessionId);

  Future<List<SubtitleSessionRecord>> listSessions();

  /// Marks leftover preparing/capturing/paused sessions interrupted.
  ///
  /// Call once during application startup, before allowing any session to
  /// attach. Ordinary reads and history listings never mutate live sessions.
  Future<int> recoverInterruptedSessions();

  Future<bool> deleteSession(String sessionId);

  Future<int> deleteSessionsBefore(DateTime cutoffUtc);
}

/// Optional health information exposed by stores that can safely skip damaged
/// history records without deleting their source files.
abstract interface class SubtitleSessionStoreDiagnostics {
  int get corruptSessionCount;
}

/// File-backed history store shared by Windows and macOS.
///
/// The caller supplies an app-owned directory. Each session and cue uses a
/// digest-derived path, so user-provided identifiers never become path parts.
/// Metadata and cue updates use a recoverable temporary/backup rename sequence.
/// Each operation also holds a root file lock to serialize cooperating app
/// processes. On macOS the caller must keep this store on one Dart isolate,
/// because the operating-system lock is process-scoped there.
final class FileSubtitleSessionStore
    implements SubtitleSessionStore, SubtitleSessionStoreDiagnostics {
  FileSubtitleSessionStore(this.rootDirectory, {DateTime Function()? now})
    : _clock = now ?? DateTime.now;

  static const int _manifestSchemaVersion = 2;
  static const int _legacyManifestSchemaVersion = 1;
  static const int _cueSchemaVersion = 1;
  static const int _maxMetadataBytes = 64 * 1024;
  static const int _maxSegmentBytes = 2 * 1024 * 1024;
  static const int _maxSessions = 10000;
  static final Map<String, Future<void>> _operationTails =
      <String, Future<void>>{};

  final Directory rootDirectory;
  final DateTime Function() _clock;
  final Set<String> _corruptSessionDirectories = <String>{};

  @override
  int get corruptSessionCount => _corruptSessionDirectories.length;

  String get _rootPath => rootDirectory.absolute.path;
  String get _rootLockKey {
    final normalized = rootDirectory.absolute.uri.normalizePath().toFilePath();
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  @override
  Future<void> createSession(SubtitleSessionRecord session) => _serialize(
    () async {
      if (session.targetLanguageCode == null) {
        throw const SubtitleSessionStoreException('target_language_required');
      }
      if (session.recognitionMode == null) {
        throw const SubtitleSessionStoreException('recognition_mode_required');
      }
      for (final segment in session.segments) {
        if (segment.translationStatus != SubtitleTranslationStatus.translated) {
          continue;
        }
        final requestTarget = segment.translationRequest?.targetLanguageCode
            .trim();
        if (requestTarget == null ||
            requestTarget.isEmpty ||
            requestTarget != session.targetLanguageCode) {
          throw const SubtitleSessionStoreException('target_language_mismatch');
        }
      }
      final directory = _sessionDirectory(session.sessionId);
      final metadataFile = _metadataFile(directory);
      await _recoverFile(metadataFile);
      if (await metadataFile.exists()) {
        throw const SubtitleSessionStoreException('session_already_exists');
      }
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      if (await _countCommittedSessions() >= _maxSessions) {
        throw const SubtitleSessionStoreException('too_many_sessions');
      }
      await directory.create(recursive: true);
      final segmentDirectory = _segmentDirectory(directory);
      if (session.segments.isNotEmpty) {
        await segmentDirectory.create(recursive: true);
        for (final segment in session.segments) {
          await _writeJson(
            _segmentFile(directory, segment.key),
            _storedCueJson(segment.transcript, segment),
          );
        }
      }
      // The manifest is the commit marker. An interrupted creation without
      // it is ignored by history scans and can be replaced on retry.
      await _writeJson(metadataFile, _manifestJson(session));
    },
  );

  @override
  Future<void> updateSessionStatus(
    String sessionId,
    SubtitleSessionHistoryStatus status, {
    DateTime? endedAtUtc,
  }) => _serialize(() async {
    final manifest = await _readManifest(sessionId);
    if (manifest == null) {
      throw const SubtitleSessionStoreException('session_not_found');
    }
    if (_isTerminal(manifest.status)) {
      if (status != manifest.status) {
        throw const SubtitleSessionStoreException('session_is_terminal');
      }
      return;
    }
    final terminal = _isTerminal(status);
    final ended =
        endedAtUtc?.toUtc() ??
        (terminal ? manifest.endedAtUtc ?? _clock().toUtc() : null);
    if (ended != null && ended.isBefore(manifest.startedAtUtc)) {
      throw const SubtitleSessionStoreException('invalid_session_time');
    }
    await _writeJson(
      _metadataFile(_sessionDirectory(sessionId)),
      _manifestJson(
        manifest
            .toRecord(segments: const <SubtitleSegment>[])
            .copyWith(
              status: status,
              endedAtUtc: ended,
              clearEndedAtUtc: !terminal,
            ),
      ),
    );
  });

  @override
  Future<void> saveConfirmedSegment(
    String sessionId,
    SubtitleSegment segment, {
    String? translatedTargetLanguageCode,
  }) => _serialize(() async {
    final normalizedSessionId = _requireNonEmpty(sessionId, 'sessionId');
    final transcript = segment.transcript;
    if (transcript.sessionId != normalizedSessionId || !transcript.isFinal) {
      throw const SubtitleSessionStoreException('invalid_confirmed_segment');
    }
    final manifest = await _readManifest(normalizedSessionId);
    if (manifest == null) {
      throw const SubtitleSessionStoreException('session_not_found');
    }
    final sourceMatches = manifest.sources.isEmpty
        ? manifest.sourceKind == transcript.sourceKind
        : manifest.sources.any(
            (source) =>
                source.sourceId == transcript.sourceId &&
                source.sourceKind == transcript.sourceKind,
          );
    if (!sourceMatches) {
      throw const SubtitleSessionStoreException('source_identity_mismatch');
    }
    if (_isTerminal(manifest.status)) {
      throw const SubtitleSessionStoreException('session_is_terminal');
    }
    if (segment.translationStatus == SubtitleTranslationStatus.translated) {
      final requestTarget = segment.translationRequest?.targetLanguageCode
          .trim();
      final explicitTarget = translatedTargetLanguageCode == null
          ? null
          : _requireNonEmpty(
              translatedTargetLanguageCode,
              'translatedTargetLanguageCode',
            ).trim();
      final targetLanguage = manifest.targetLanguageCode;
      final translatedLanguage = requestTarget ?? explicitTarget;
      if (targetLanguage == null ||
          translatedLanguage == null ||
          translatedLanguage.isEmpty ||
          (requestTarget != null &&
              explicitTarget != null &&
              requestTarget != explicitTarget) ||
          translatedLanguage != targetLanguage) {
        throw const SubtitleSessionStoreException('target_language_mismatch');
      }
    }

    final sessionDirectory = _sessionDirectory(normalizedSessionId);
    final segmentFile = _segmentFile(sessionDirectory, segment.key);
    final existing = await _readStoredCue(
      segmentFile,
      targetLanguageCode: manifest.targetLanguageCode,
    );
    final cueToWrite = _newestCompatibleCue(existing, segment);
    if (cueToWrite == null || identical(cueToWrite, existing)) return;
    final segmentDirectory = _segmentDirectory(sessionDirectory);
    await segmentDirectory.create(recursive: true);
    await _writeJson(
      segmentFile,
      _storedCueJson(cueToWrite.transcript, cueToWrite.segment),
    );
  });

  @override
  Future<SubtitleSessionRecord?> readSession(String sessionId) =>
      _serialize(() => _readSession(sessionId, recoverInterrupted: false));

  @override
  Future<List<SubtitleSessionRecord>> listSessions() =>
      _serialize(_listSessions);

  @override
  Future<int> recoverInterruptedSessions() => _serialize(() async {
    if (!await rootDirectory.exists()) return 0;
    var recovered = 0;
    await for (final entity in rootDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! Directory || !_isSessionStorageDirectory(entity)) continue;
      final metadataFile = _metadataFile(entity);
      await _recoverFile(metadataFile);
      if (!await metadataFile.exists()) continue;
      late final _SubtitleSessionManifest manifest;
      try {
        manifest = await _decodeManifest(metadataFile);
      } on SubtitleSessionStoreException catch (error) {
        if (error.code != 'corrupt_session_metadata') rethrow;
        _corruptSessionDirectories.add(entity.absolute.path);
        continue;
      }
      if (_sessionDirectory(manifest.sessionId).absolute.path !=
          entity.absolute.path) {
        throw const SubtitleSessionStoreException('session_path_mismatch');
      }
      if (manifest.status == SubtitleSessionHistoryStatus.preparing ||
          manifest.status == SubtitleSessionHistoryStatus.capturing ||
          manifest.status == SubtitleSessionHistoryStatus.paused) {
        await _readSession(manifest.sessionId, recoverInterrupted: true);
        recovered += 1;
      }
    }
    return recovered;
  });

  @override
  Future<bool> deleteSession(String sessionId) => _serialize(() async {
    final normalizedSessionId = _requireNonEmpty(sessionId, 'sessionId');
    final directory = _sessionDirectory(normalizedSessionId);
    final metadataFile = _metadataFile(directory);
    await _recoverFile(metadataFile);
    if (!await metadataFile.exists()) {
      if (!await directory.exists()) return false;
      await directory.delete(recursive: true);
      return true;
    }
    final manifest = await _decodeManifest(metadataFile);
    if (manifest.sessionId != normalizedSessionId) {
      throw const SubtitleSessionStoreException('session_path_mismatch');
    }
    if (!_isTerminal(manifest.status)) {
      throw const SubtitleSessionStoreException('session_is_active');
    }
    await directory.delete(recursive: true);
    return true;
  });

  @override
  Future<int> deleteSessionsBefore(DateTime cutoffUtc) => _serialize(() async {
    if (!await rootDirectory.exists()) return 0;
    var deleted = 0;
    final cutoff = cutoffUtc.toUtc();
    await for (final entity in rootDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! Directory) continue;
      if (!_isSessionStorageDirectory(entity)) continue;
      final metadataFile = _metadataFile(entity);
      await _recoverFile(metadataFile);
      if (!await metadataFile.exists()) {
        // Uncommitted directories have no recoverable session identity or
        // retention timestamp. Remove them as incomplete local artifacts.
        await entity.delete(recursive: true);
        continue;
      }
      late final _SubtitleSessionManifest manifest;
      try {
        manifest = await _decodeManifest(metadataFile);
      } on SubtitleSessionStoreException catch (error) {
        if (error.code != 'corrupt_session_metadata') rethrow;
        _corruptSessionDirectories.add(entity.absolute.path);
        continue;
      }
      if (_sessionDirectory(manifest.sessionId).absolute.path !=
          entity.absolute.path) {
        throw const SubtitleSessionStoreException('session_path_mismatch');
      }
      if (_isTerminal(manifest.status) &&
          manifest.startedAtUtc.isBefore(cutoff) &&
          await _deleteSession(manifest.sessionId)) {
        deleted += 1;
      }
    }
    return deleted;
  });

  Future<List<SubtitleSessionRecord>> _listSessions() async {
    _corruptSessionDirectories.clear();
    if (!await rootDirectory.exists()) {
      return const <SubtitleSessionRecord>[];
    }
    final result = <SubtitleSessionRecord>[];
    await for (final entity in rootDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! Directory) continue;
      if (!_isSessionStorageDirectory(entity)) continue;
      final metadataFile = _metadataFile(entity);
      await _recoverFile(metadataFile);
      if (!await metadataFile.exists()) {
        await entity.delete(recursive: true);
        continue;
      }
      late final _SubtitleSessionManifest manifest;
      try {
        manifest = await _decodeManifest(metadataFile);
      } on SubtitleSessionStoreException catch (error) {
        if (error.code != 'corrupt_session_metadata') rethrow;
        _corruptSessionDirectories.add(entity.absolute.path);
        continue;
      }
      if (_sessionDirectory(manifest.sessionId).absolute.path !=
          entity.absolute.path) {
        throw const SubtitleSessionStoreException('session_path_mismatch');
      }
      final record = await _readSession(
        manifest.sessionId,
        recoverInterrupted: false,
      );
      if (record != null) result.add(record);
      if (result.length > _maxSessions) {
        throw const SubtitleSessionStoreException('too_many_sessions');
      }
    }
    result.sort(
      (left, right) => right.startedAtUtc.compareTo(left.startedAtUtc),
    );
    return List<SubtitleSessionRecord>.unmodifiable(result);
  }

  Future<SubtitleSessionRecord?> _readSession(
    String sessionId, {
    required bool recoverInterrupted,
  }) async {
    final normalizedSessionId = _requireNonEmpty(sessionId, 'sessionId');
    final directory = _sessionDirectory(normalizedSessionId);
    final manifest = await _readManifest(normalizedSessionId);
    if (manifest == null) return null;
    final segmentDirectory = _segmentDirectory(directory);
    final cuesByKey = <SubtitleSegmentKey, _StoredSubtitleCue>{};
    var corruptSegmentCount = 0;
    if (await segmentDirectory.exists()) {
      await for (final entity in segmentDirectory.list(
        recursive: false,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final _StoredSubtitleCue? cue;
        try {
          cue = await _readStoredCue(
            entity,
            targetLanguageCode: manifest.targetLanguageCode,
          );
        } on SubtitleSessionStoreException catch (error) {
          if (error.code != 'corrupt_subtitle_segment' &&
              error.code != 'corrupt_session_file' &&
              error.code != 'stored_record_too_large') {
            rethrow;
          }
          corruptSegmentCount += 1;
          continue;
        } on FileSystemException {
          // A locked or temporarily unreadable cue must not hide every other
          // session in history. Keep the file and report the partial restore.
          corruptSegmentCount += 1;
          continue;
        }
        if (cue == null) continue;
        final canonicalPath = _segmentFile(directory, cue.key).absolute.path;
        final legacyPath = _legacySegmentFile(directory, cue.key).absolute.path;
        final actualPath = entity.absolute.path;
        if (cue.transcript.sessionId != normalizedSessionId ||
            (actualPath != canonicalPath && actualPath != legacyPath)) {
          throw const SubtitleSessionStoreException('segment_path_mismatch');
        }
        final existing = cuesByKey[cue.key];
        if (existing == null ||
            cue.transcript.revision > existing.transcript.revision ||
            (cue.transcript.revision == existing.transcript.revision &&
                actualPath == canonicalPath)) {
          cuesByKey[cue.key] = cue;
        }
      }
    }
    // The old single-source store used [captureAttemptId, segmentId] as the
    // filename digest. Read both layouts and let the highest revision win;
    // on ties the source-qualified path written by the new store is preferred.
    final segments = <SubtitleSegment>[
      for (final cue in cuesByKey.values)
        if (!cue.isTombstone) cue.segment!,
    ];
    segments.sort((left, right) {
      final start = left.transcript.startMs.compareTo(right.transcript.startMs);
      if (start != 0) return start;
      final end = left.transcript.endMs.compareTo(right.transcript.endMs);
      if (end != 0) return end;
      final attempt = left.transcript.captureAttemptId.compareTo(
        right.transcript.captureAttemptId,
      );
      if (attempt != 0) return attempt;
      return left.transcript.segmentId.compareTo(right.transcript.segmentId);
    });
    SubtitleSessionRecord record;
    try {
      record = manifest
          .toRecord(segments: segments)
          .copyWith(corruptSegmentCount: corruptSegmentCount);
    } on ArgumentError {
      throw const SubtitleSessionStoreException('corrupt_session_contents');
    }
    if (recoverInterrupted &&
        (record.status == SubtitleSessionHistoryStatus.preparing ||
            record.status == SubtitleSessionHistoryStatus.capturing ||
            record.status == SubtitleSessionHistoryStatus.paused)) {
      final now = _clock().toUtc();
      final endedAt = now.isBefore(record.startedAtUtc)
          ? record.startedAtUtc
          : now;
      record = record.copyWith(
        status: SubtitleSessionHistoryStatus.interrupted,
        endedAtUtc: endedAt,
      );
      await _writeJson(_metadataFile(directory), _manifestJson(record));
    }
    return record;
  }

  Future<bool> _deleteSession(String sessionId) async {
    final directory = _sessionDirectory(sessionId);
    final metadataFile = _metadataFile(directory);
    await _recoverFile(metadataFile);
    if (!await metadataFile.exists()) return false;
    final manifest = await _decodeManifest(metadataFile);
    if (manifest.sessionId != sessionId) {
      throw const SubtitleSessionStoreException('session_path_mismatch');
    }
    await directory.delete(recursive: true);
    return true;
  }

  Future<_SubtitleSessionManifest?> _readManifest(String sessionId) async {
    final file = _metadataFile(_sessionDirectory(sessionId));
    await _recoverFile(file);
    if (!await file.exists()) return null;
    final manifest = await _decodeManifest(file);
    if (manifest.sessionId != sessionId) {
      throw const SubtitleSessionStoreException('session_path_mismatch');
    }
    return manifest;
  }

  Future<_SubtitleSessionManifest> _decodeManifest(File file) async {
    Map<String, dynamic>? value;
    try {
      value = await _readJson(file, maxBytes: _maxMetadataBytes);
    } on SubtitleSessionStoreException catch (error) {
      if (error.code == 'corrupt_session_file' ||
          error.code == 'stored_record_too_large' ||
          error.code == 'session_metadata_missing') {
        throw const SubtitleSessionStoreException('corrupt_session_metadata');
      }
      rethrow;
    }
    if (value == null) {
      throw const SubtitleSessionStoreException('session_metadata_missing');
    }
    try {
      return _SubtitleSessionManifest.fromJson(value);
    } on FormatException {
      throw const SubtitleSessionStoreException('corrupt_session_metadata');
    } on ArgumentError {
      throw const SubtitleSessionStoreException('corrupt_session_metadata');
    }
  }

  Future<_StoredSubtitleCue?> _readStoredCue(
    File file, {
    String? targetLanguageCode,
  }) async {
    final value = await _readJson(file, maxBytes: _maxSegmentBytes);
    if (value == null) return null;
    try {
      return _decodeStoredCue(value, targetLanguageCode: targetLanguageCode);
    } on FormatException {
      throw const SubtitleSessionStoreException('corrupt_subtitle_segment');
    } on ArgumentError {
      throw const SubtitleSessionStoreException('corrupt_subtitle_segment');
    }
  }

  Future<Map<String, dynamic>?> _readJson(
    File file, {
    required int maxBytes,
  }) async {
    await _recoverFile(file);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length > maxBytes) {
      throw const SubtitleSessionStoreException('stored_record_too_large');
    }
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > maxBytes) {
        throw const SubtitleSessionStoreException('stored_record_too_large');
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('expected an object');
      }
      return decoded;
    } on SubtitleSessionStoreException {
      rethrow;
    } on FormatException {
      throw const SubtitleSessionStoreException('corrupt_session_file');
    }
  }

  Future<void> _writeJson(File file, Map<String, Object?> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    final maxBytes =
        file.parent.path.endsWith('${Platform.pathSeparator}segments')
        ? _maxSegmentBytes
        : _maxMetadataBytes;
    if (bytes.length > maxBytes) {
      throw const SubtitleSessionStoreException('record_too_large');
    }
    await _atomicWrite(file, bytes);
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
    // The target rename is the commit point. A leftover backup is safe and
    // will be removed on the next read; cleanup failure must not report that
    // the newly committed record failed to save.
    if (await backup.exists()) {
      try {
        await backup.delete();
      } on FileSystemException {
        // Keep the committed target authoritative.
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
          // A leftover temporary file is ignored while the target exists.
        }
      }
      return;
    } else if (await backup.exists()) {
      await backup.rename(file.path);
    }
    if (await temp.exists()) {
      try {
        await temp.delete();
      } on FileSystemException {
        // Temporary files are never authoritative.
      }
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final rootKey = _rootLockKey;
    final previous = _operationTails[rootKey] ?? Future<void>.value();
    final next = previous.then((_) async {
      RandomAccessFile? lockHandle;
      var locked = false;
      try {
        await rootDirectory.create(recursive: true);
        // `blockingExclusive` waits for another app process instead of
        // surfacing a busy lock as a failed user save.
        final handle = await File(
          '$_rootPath${Platform.pathSeparator}.store.lock',
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

  Directory _sessionDirectory(String sessionId) => Directory(
    '$_rootPath${Platform.pathSeparator}${_sessionDigest(sessionId)}',
  );

  File _metadataFile(Directory directory) =>
      File('${directory.path}${Platform.pathSeparator}session.json');

  Directory _segmentDirectory(Directory directory) =>
      Directory('${directory.path}${Platform.pathSeparator}segments');

  File _segmentFile(Directory sessionDirectory, SubtitleSegmentKey key) => File(
    '${_segmentDirectory(sessionDirectory).path}${Platform.pathSeparator}'
    '${_segmentDigest(key)}.json',
  );

  File _legacySegmentFile(Directory sessionDirectory, SubtitleSegmentKey key) =>
      File(
        '${_segmentDirectory(sessionDirectory).path}${Platform.pathSeparator}'
        '${_legacySegmentDigest(key)}.json',
      );

  static Map<String, Object?> _manifestJson(SubtitleSessionRecord session) =>
      <String, Object?>{
        'schemaVersion': _manifestSchemaVersion,
        'sessionId': session.sessionId,
        'kind': session.kind.name,
        'sourceKind': session.sourceKind.name,
        'sources': [
          for (final source in session.sources)
            <String, Object?>{
              'sourceId': source.sourceId,
              'sourceKind': source.sourceKind.name,
              'displayName': source.displayName,
            },
        ],
        'targetLanguageCode': session.targetLanguageCode,
        'recognitionMode': session.recognitionMode?.name,
        'startedAtUtc': session.startedAtUtc.toIso8601String(),
        'endedAtUtc': session.endedAtUtc?.toIso8601String(),
        'status': session.status.name,
      };

  static Map<String, Object?> _storedCueJson(
    TranscriptRevision transcript,
    SubtitleSegment? segment,
  ) {
    final isTombstone = segment == null;
    return <String, Object?>{
      'schemaVersion': _cueSchemaVersion,
      'deleted': isTombstone,
      'sessionId': transcript.sessionId,
      'captureAttemptId': transcript.captureAttemptId,
      'segmentId': transcript.segmentId,
      'sourceId': transcript.sourceId,
      'sourceKind': transcript.sourceKind.name,
      'startMs': transcript.startMs,
      'endMs': transcript.endMs,
      'text': transcript.text,
      'languageCode': transcript.languageCode,
      'speakerId': transcript.speakerId,
      'revision': transcript.revision,
      'translationDisabled':
          segment?.translationStatus ==
          SubtitleTranslationStatus.skippedDisabled,
      'translatedText':
          segment?.translationStatus == SubtitleTranslationStatus.translated
          ? segment?.translatedText
          : null,
    };
  }

  static _StoredSubtitleCue _decodeStoredCue(
    Map<String, dynamic> value, {
    String? targetLanguageCode,
  }) {
    if (value['schemaVersion'] != _cueSchemaVersion ||
        value['sessionId'] is! String ||
        value['captureAttemptId'] is! String ||
        value['segmentId'] is! String ||
        value['sourceId'] is! String ||
        value['startMs'] is! int ||
        value['endMs'] is! int ||
        value['text'] is! String ||
        value['languageCode'] is! String ||
        value['revision'] is! int ||
        (value['deleted'] != null && value['deleted'] is! bool) ||
        (value['speakerId'] != null && value['speakerId'] is! String) ||
        (value['translationDisabled'] != null &&
            value['translationDisabled'] is! bool) ||
        (value['translatedText'] != null &&
            value['translatedText'] is! String)) {
      throw const FormatException('invalid subtitle segment');
    }
    final transcript = TranscriptRevision(
      sessionId: value['sessionId'] as String,
      captureAttemptId: value['captureAttemptId'] as String,
      segmentId: value['segmentId'] as String,
      sourceId: value['sourceId'] as String,
      sourceKind: _enumValue(
        SubtitleAudioSourceKind.values,
        value['sourceKind'],
      ),
      startMs: value['startMs'] as int,
      endMs: value['endMs'] as int,
      text: value['text'] as String,
      languageCode: value['languageCode'] as String,
      revision: value['revision'] as int,
      isFinal: true,
      speakerId: value['speakerId'] as String?,
    );
    if (value['deleted'] == true) {
      if (transcript.text.trim().isNotEmpty ||
          value['translatedText'] != null) {
        throw const FormatException('invalid subtitle tombstone');
      }
      return _StoredSubtitleCue.tombstone(transcript);
    }
    return _StoredSubtitleCue.segment(
      transcript,
      SubtitleSegment.fromStoredFinalTranscript(
        transcript,
        translatedText: value['translatedText'] as String?,
        translationDisabled: value['translationDisabled'] == true,
        targetLanguageCode: targetLanguageCode,
      ),
    );
  }

  _StoredSubtitleCue? _newestCompatibleCue(
    _StoredSubtitleCue? existing,
    SubtitleSegment incoming,
  ) {
    final next = incoming.transcript;
    final incomingCue = next.text.trim().isEmpty
        ? _StoredSubtitleCue.tombstone(next)
        : _StoredSubtitleCue.segment(next, incoming);
    if (existing == null) return incomingCue;
    if (existing.key != incoming.key) {
      throw const SubtitleSessionStoreException('segment_key_collision');
    }
    final old = existing.transcript;
    if (next.revision < old.revision) return null;
    if (next.revision == old.revision &&
        (next.sourceId != old.sourceId ||
            next.sourceKind != old.sourceKind ||
            next.startMs != old.startMs ||
            next.endMs != old.endMs ||
            next.text != old.text ||
            next.languageCode != old.languageCode ||
            next.speakerId != old.speakerId)) {
      throw const SubtitleSessionStoreException('revision_conflict');
    }
    if (next.revision == old.revision && existing.isTombstone) {
      return existing;
    }
    if (next.text.trim().isEmpty) return incomingCue;
    if (next.revision > old.revision ||
        incoming.translationStatus == SubtitleTranslationStatus.translated ||
        existing.segment!.translationStatus !=
            SubtitleTranslationStatus.translated) {
      return incomingCue;
    }
    return existing;
  }

  Future<int> _countCommittedSessions() async {
    if (!await rootDirectory.exists()) return 0;
    var count = 0;
    await for (final entity in rootDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! Directory) continue;
      if (!_isSessionStorageDirectory(entity)) continue;
      final metadataFile = _metadataFile(entity);
      await _recoverFile(metadataFile);
      if (!await metadataFile.exists()) continue;
      final manifest = await _decodeManifest(metadataFile);
      if (_sessionDirectory(manifest.sessionId).absolute.path !=
          entity.absolute.path) {
        throw const SubtitleSessionStoreException('session_path_mismatch');
      }
      count += 1;
    }
    return count;
  }

  static String _sessionDigest(String sessionId) =>
      'session-${sha256.convert(utf8.encode(sessionId))}';

  static bool _isSessionStorageDirectory(Directory directory) {
    final path = directory.absolute.path;
    final separator = path.lastIndexOf(Platform.pathSeparator);
    final name = path.substring(separator + 1);
    return RegExp(r'^session-[0-9a-f]{64}$').hasMatch(name);
  }

  static String _segmentDigest(SubtitleSegmentKey key) => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String>[
            key.captureAttemptId,
            key.sourceId,
            key.sourceKind.name,
            key.segmentId,
          ]),
        ),
      )
      .toString();

  static String _legacySegmentDigest(SubtitleSegmentKey key) => sha256
      .convert(
        utf8.encode(jsonEncode(<String>[key.captureAttemptId, key.segmentId])),
      )
      .toString();

  static bool _isTerminal(SubtitleSessionHistoryStatus status) =>
      _isTerminalHistoryStatus(status);
}

final class _StoredSubtitleCue {
  const _StoredSubtitleCue.segment(this.transcript, this.segment)
    : isTombstone = false;

  const _StoredSubtitleCue.tombstone(this.transcript)
    : segment = null,
      isTombstone = true;

  final TranscriptRevision transcript;
  final SubtitleSegment? segment;
  final bool isTombstone;

  SubtitleSegmentKey get key => SubtitleSegmentKey(
    sessionId: transcript.sessionId,
    captureAttemptId: transcript.captureAttemptId,
    segmentId: transcript.segmentId,
    sourceId: transcript.sourceId,
    sourceKind: transcript.sourceKind,
  );
}

final class _SubtitleSessionManifest {
  const _SubtitleSessionManifest({
    required this.sessionId,
    required this.kind,
    required this.sourceKind,
    required this.sources,
    required this.targetLanguageCode,
    required this.recognitionMode,
    required this.startedAtUtc,
    required this.status,
    required this.endedAtUtc,
  });

  final String sessionId;
  final SubtitleSessionKind kind;
  final SubtitleAudioSourceKind sourceKind;
  final List<SubtitleSessionAudioSource> sources;
  final String? targetLanguageCode;
  final SubtitleRecognitionMode? recognitionMode;
  final DateTime startedAtUtc;
  final SubtitleSessionHistoryStatus status;
  final DateTime? endedAtUtc;

  factory _SubtitleSessionManifest.fromJson(Map<String, dynamic> value) {
    final schemaVersion = value['schemaVersion'];
    if ((schemaVersion !=
                FileSubtitleSessionStore._legacyManifestSchemaVersion &&
            schemaVersion != FileSubtitleSessionStore._manifestSchemaVersion) ||
        value['sessionId'] is! String ||
        value['startedAtUtc'] is! String ||
        (value['targetLanguageCode'] != null &&
            value['targetLanguageCode'] is! String) ||
        (value['sources'] != null && value['sources'] is! List) ||
        (value['endedAtUtc'] != null && value['endedAtUtc'] is! String) ||
        (schemaVersion == FileSubtitleSessionStore._manifestSchemaVersion &&
            !value.containsKey('recognitionMode'))) {
      throw const FormatException('invalid session metadata');
    }
    final sessionId = _requireNonEmpty(
      value['sessionId'] as String,
      'sessionId',
    );
    if (sessionId.length > 256) {
      throw const FormatException('session id is too long');
    }
    final startedAt = _parseDate(value['startedAtUtc'] as String);
    final endedAt = value['endedAtUtc'] == null
        ? null
        : _parseDate(value['endedAtUtc'] as String);
    if (endedAt != null && endedAt.isBefore(startedAt)) {
      throw const FormatException('invalid session time range');
    }
    final status = _enumValue(
      SubtitleSessionHistoryStatus.values,
      value['status'],
    );
    if (_isTerminalHistoryStatus(status) != (endedAt != null)) {
      throw const FormatException('inconsistent session status time');
    }
    final targetLanguage = value['targetLanguageCode'] == null
        ? null
        : _requireNonEmpty(
            value['targetLanguageCode'] as String,
            'targetLanguageCode',
          ).trim();
    final sources = <SubtitleSessionAudioSource>[];
    final rawSources = value['sources'];
    if (rawSources is List) {
      for (final rawSource in rawSources) {
        if (rawSource is! Map<String, dynamic> ||
            rawSource['sourceId'] is! String ||
            (rawSource['displayName'] != null &&
                rawSource['displayName'] is! String)) {
          throw const FormatException('invalid source identity');
        }
        sources.add(
          SubtitleSessionAudioSource(
            sourceId: rawSource['sourceId'] as String,
            sourceKind: _enumValue(
              SubtitleAudioSourceKind.values,
              rawSource['sourceKind'],
            ),
            displayName: rawSource['displayName'] as String?,
          ),
        );
      }
    }
    return _SubtitleSessionManifest(
      sessionId: sessionId,
      kind: _enumValue(SubtitleSessionKind.values, value['kind']),
      sourceKind: _enumValue(
        SubtitleAudioSourceKind.values,
        value['sourceKind'],
      ),
      sources: List<SubtitleSessionAudioSource>.unmodifiable(sources),
      targetLanguageCode: targetLanguage,
      recognitionMode:
          schemaVersion == FileSubtitleSessionStore._legacyManifestSchemaVersion
          ? null
          : _recognitionModeValue(value['recognitionMode']),
      startedAtUtc: startedAt,
      status: status,
      endedAtUtc: endedAt,
    );
  }

  SubtitleSessionRecord toRecord({
    required Iterable<SubtitleSegment> segments,
  }) => SubtitleSessionRecord(
    sessionId: sessionId,
    kind: kind,
    sourceKind: sourceKind,
    sources: sources,
    targetLanguageCode: targetLanguageCode,
    recognitionMode: recognitionMode,
    startedAtUtc: startedAtUtc,
    endedAtUtc: endedAtUtc,
    status: status,
    segments: segments,
  );
}

SubtitleRecognitionMode? _recognitionModeValue(Object? raw) {
  if (raw == null) return null;
  if (raw is! String) throw const FormatException('invalid recognition mode');
  for (final mode in SubtitleRecognitionMode.values) {
    if (mode.name == raw) return mode;
  }
  throw const FormatException('unknown recognition mode');
}

List<SubtitleSessionAudioSource> _normalizeSources(
  Iterable<SubtitleSessionAudioSource> input,
  Iterable<SubtitleSegment> segments,
) {
  final result = <SubtitleSessionAudioSource>[];
  final seen = <String>{};
  for (final source in input) {
    final key = '${source.sourceKind.name}\u0000${source.sourceId}';
    if (!seen.add(key)) {
      throw ArgumentError('A session cannot declare a source twice.');
    }
    result.add(source);
  }
  if (result.isEmpty) {
    for (final segment in segments) {
      final transcript = segment.transcript;
      final key = '${transcript.sourceKind.name}\u0000${transcript.sourceId}';
      if (seen.add(key)) {
        result.add(
          SubtitleSessionAudioSource(
            sourceId: transcript.sourceId,
            sourceKind: transcript.sourceKind,
          ),
        );
      }
    }
  }
  return List<SubtitleSessionAudioSource>.unmodifiable(result);
}

final class SubtitleSessionStoreException implements Exception {
  const SubtitleSessionStoreException(this.code);

  final String code;

  @override
  String toString() => 'SubtitleSessionStoreException($code)';
}

T _enumValue<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) throw const FormatException('invalid enum value');
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw const FormatException('unknown enum value');
}

DateTime _parseDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException('invalid date');
  return parsed.toUtc();
}

String _requireNonEmpty(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
  return value;
}

bool _isTerminalHistoryStatus(SubtitleSessionHistoryStatus status) =>
    status == SubtitleSessionHistoryStatus.completed ||
    status == SubtitleSessionHistoryStatus.interrupted ||
    status == SubtitleSessionHistoryStatus.failed;
