import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/app_data_directory.dart';
import 'audio_capture_contract.dart';
import 'subtitle_session_contract.dart';

/// Lifecycle of an explicitly enabled local audio recording.
///
/// Constructing a recorder or starting subtitle capture does not enable this
/// feature. Audio is written only after [SubtitleAudioSessionRecorder.start]
/// has been called and until [SubtitleAudioSessionRecorder.stop] completes.
enum SubtitleAudioRecordingStatus { idle, recording, stopping, stopped, failed }

/// Persisted status exposed by the bounded recording-history index.
enum SubtitleAudioIndexedRecordingStatus {
  completed,
  incomplete,
  unknown,
  failed,
  interrupted,
}

/// One validated local WAV file referenced by a recording manifest.
final class SubtitleAudioIndexedFile {
  const SubtitleAudioIndexedFile({
    required this.sourceKind,
    required this.file,
    required this.sampleRateHz,
    required this.channelCount,
    required this.dataBytes,
    this.channelMask,
    this.headerBytes = 44,
    this.droppedFrames = 0,
    this.discontinuities = 0,
  });

  final SubtitleAudioSourceKind sourceKind;
  final File file;
  final int sampleRateHz;
  final int channelCount;
  final int dataBytes;
  final int? channelMask;
  final int headerBytes;
  final int droppedFrames;
  final int discontinuities;
}

/// An interrupted WAV container whose PCM payload is still preserved on disk.
///
/// Older recorder versions did not checkpoint the source format, so either
/// format field can be null. Recovery must ask the user for missing values;
/// the index never guesses them.
final class SubtitleAudioRecoveryCandidate {
  const SubtitleAudioRecoveryCandidate({
    required this.sourceId,
    required this.sourceKind,
    required this.rawFile,
    required this.dataBytes,
    this.channelMask,
    this.headerBytes = 44,
    this.sampleRateHz,
    this.channelCount,
    this.legacyMultichannelUpgrade = false,
  });

  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final File rawFile;
  final int dataBytes;
  final int? channelMask;
  final int headerBytes;
  final int? sampleRateHz;
  final int? channelCount;
  final bool legacyMultichannelUpgrade;

  bool get formatKnown => sampleRateHz != null && channelCount != null;
}

/// A validated standalone audio recording and its available local media.
final class SubtitleAudioIndexedRecording {
  SubtitleAudioIndexedRecording({
    required this.sessionId,
    required this.recordingId,
    required this.status,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.directory,
    required Iterable<SubtitleAudioIndexedFile> files,
    Iterable<SubtitleAudioRecoveryCandidate> recoveryCandidates =
        const <SubtitleAudioRecoveryCandidate>[],
    this.emptyAudioSources = 0,
    required this.droppedFrames,
    required this.discontinuities,
    required this.lossCountersKnown,
  }) : files = List<SubtitleAudioIndexedFile>.unmodifiable(files),
       recoveryCandidates = List<SubtitleAudioRecoveryCandidate>.unmodifiable(
         recoveryCandidates,
       );

  final String sessionId;
  final String recordingId;
  final SubtitleAudioIndexedRecordingStatus status;
  final DateTime startedAtUtc;
  final DateTime? endedAtUtc;
  final Directory directory;
  final List<SubtitleAudioIndexedFile> files;
  final List<SubtitleAudioRecoveryCandidate> recoveryCandidates;

  /// Number of declared sources with no audio path or an empty WAV. These
  /// recordings remain visible for diagnosis but are never playable.
  final int emptyAudioSources;
  final int droppedFrames;
  final int discontinuities;
  final bool lossCountersKnown;
}

/// Result of the bounded local recording scan. [truncated] means at least one
/// scan limit was reached; callers should show the entries found and tell the
/// user that the local recordings folder may contain more files.
final class SubtitleAudioRecordingIndexResult {
  SubtitleAudioRecordingIndexResult({
    required Iterable<SubtitleAudioIndexedRecording> recordings,
    required this.truncated,
  }) : recordings = List<SubtitleAudioIndexedRecording>.unmodifiable(
         recordings,
       );

  final List<SubtitleAudioIndexedRecording> recordings;
  final bool truncated;
}

/// Immutable recording information for one declared capture input.
final class SubtitleAudioRecordingSourceState {
  const SubtitleAudioRecordingSourceState({
    required this.sourceId,
    required this.sourceKind,
    this.relativePath,
    this.sampleRateHz,
    this.channelCount,
    this.channelMask,
    this.dataBytes = 0,
    this.samplesPerChannel = 0,
    this.framesWritten = 0,
    this.droppedFrames = 0,
    this.discontinuities = 0,
    this.firstSequence,
    this.lastSequence,
    this.startedAtUtc,
    this.endedAtUtc,
    this.error,
  });

  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;

  /// Path relative to the configured app-data directory, using `/` separators.
  /// Null means this source produced no valid frame during the recording.
  final String? relativePath;
  final int? sampleRateHz;
  final int? channelCount;
  final int? channelMask;
  final int dataBytes;
  final int samplesPerChannel;
  final int framesWritten;
  final int droppedFrames;
  final int discontinuities;
  final int? firstSequence;
  final int? lastSequence;
  final DateTime? startedAtUtc;
  final DateTime? endedAtUtc;
  final String? error;
}

/// Read-only snapshot of the current recording operation.
final class SubtitleAudioRecordingState {
  SubtitleAudioRecordingState({
    required this.status,
    Iterable<SubtitleAudioRecordingSourceState> sources =
        const <SubtitleAudioRecordingSourceState>[],
    this.sessionId,
    this.recordingId,
    this.manifestRelativePath,
    this.startedAtUtc,
    this.endedAtUtc,
    this.error,
  }) : sources = List<SubtitleAudioRecordingSourceState>.unmodifiable(sources);

  factory SubtitleAudioRecordingState.idle() =>
      SubtitleAudioRecordingState(status: SubtitleAudioRecordingStatus.idle);

  final SubtitleAudioRecordingStatus status;
  final String? sessionId;
  final String? recordingId;
  final String? manifestRelativePath;
  final DateTime? startedAtUtc;
  final DateTime? endedAtUtc;
  final String? error;
  final List<SubtitleAudioRecordingSourceState> sources;
}

/// Writes each declared source from one session to its own local PCM16 WAV.
///
/// The recorder consumes a broadcast [AudioFrame] stream so the ASR pipeline
/// and the recorder can observe the same bounded capture events. It accepts
/// only the exact session ID and `(sourceId, sourceKind)` pairs supplied to
/// [start]. It never writes audio into subtitle history records.
///
/// The app-data directory should be the same local directory used by the
/// application stores. The generated paths are under
/// `simultaneous-interpretation/recordings/`; session IDs and source IDs are
/// represented by SHA-256 digests in path components.
final class SubtitleAudioSessionRecorder {
  SubtitleAudioSessionRecorder({
    required Directory appDataDirectory,
    DateTime Function()? now,
  }) : _appDataDirectory = Directory(appDataDirectory.absolute.path),
       _clock = now ?? DateTime.now;

  static const int _maxPendingFrames = 64;
  static const int _maxRiffDataBytes = 0xffffffff - 36;
  static const int _maxManifestBytes = 64 * 1024;
  static const int _maxSourcesPerManifest = 16;
  static const int _schemaVersion = 1;
  static const String _recordingFormat = 'wav-pcm-s16le';
  static const String _recordingRootRelativePath =
      'simultaneous-interpretation/recordings';
  static const Duration _progressBroadcastInterval = Duration(seconds: 1);
  static final Set<String> _activeRecordingSessions = <String>{};
  static final Set<String> _deletingRecordingSessions = <String>{};

  static int _maxRiffDataBytesForHeader(int headerBytes) =>
      0xffffffff - headerBytes + 8;

  final Directory _appDataDirectory;
  final DateTime Function() _clock;
  final StreamController<SubtitleAudioRecordingState> _stateController =
      StreamController<SubtitleAudioRecordingState>.broadcast();
  final Stopwatch _broadcastClock = Stopwatch()..start();
  final Map<_RecordingSourceKey, SubtitleSessionAudioSource> _definitions =
      <_RecordingSourceKey, SubtitleSessionAudioSource>{};
  final Map<_RecordingSourceKey, _WavSourceWriter> _writers =
      <_RecordingSourceKey, _WavSourceWriter>{};
  final Map<_RecordingSourceKey, int> _droppedFrames =
      <_RecordingSourceKey, int>{};

  SubtitleAudioRecordingState _state = SubtitleAudioRecordingState.idle();
  Timer? _stateThrottleTimer;
  StreamSubscription<AudioFrame>? _frameSubscription;
  Future<void> _writeTail = Future<void>.value();
  Future<SubtitleAudioRecordingState>? _stopFuture;
  RandomAccessFile? _sessionLockHandle;
  String? _activeSessionRegistryKey;
  String? _failureMessage;
  String? _sessionId;
  String? _recordingId;
  String? _recordingDirectoryRelativePath;
  String? _manifestRelativePath;
  DateTime? _startedAtUtc;
  int _pendingWrites = 0;
  Duration? _lastStateBroadcastElapsed;
  String? _captureAttemptId;
  bool _disposed = false;
  bool _writeFailed = false;

  SubtitleAudioRecordingState get state => _state;

  Stream<SubtitleAudioRecordingState> get states => _stateController.stream;

  /// Local root containing per-session recording directories.
  Directory get recordingsRootDirectory => Directory(
    joinAppDataPath(_appDataDirectory.path, _recordingRootRelativePath),
  );

  /// Absolute path suitable for displaying or opening from a desktop UI.
  String get recordingsRootPath => recordingsRootDirectory.path;

  /// Resolves a saved session's media directory without following links.
  static Future<Directory?> sessionRecordingsDirectory({
    required Directory appDataDirectory,
    required String sessionId,
  }) async {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty || normalizedSessionId.length > 256) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'Must contain 1 to 256 non-whitespace characters.',
      );
    }
    final recordingsRoot = await _findRecordingsRoot(
      Directory(appDataDirectory.absolute.path),
      createIfMissing: false,
    );
    if (recordingsRoot == null) return null;
    final sessionDirectory = Directory(
      joinAppDataPath(recordingsRoot.path, _digest(normalizedSessionId)),
    );
    final type = await FileSystemEntity.type(
      sessionDirectory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw StateError('The hashed session recording path is not a directory.');
    }
    await for (final entry in sessionDirectory.list(followLinks: false)) {
      if (_basename(entry.path) != '.session.lock') return sessionDirectory;
    }
    // The audio deletion flow leaves the empty hashed directory and lock file
    // in place to coordinate later cross-process recording starts.
    return null;
  }

  /// Lists a bounded set of completed or interrupted recordings with valid
  /// local PCM WAV files. A stale `recording` manifest is treated as
  /// interrupted only when a finalized WAV can be derived and verified.
  /// Corrupt manifests and unsafe filesystem entries are ignored so one
  /// damaged recording cannot hide the rest of history.
  static Future<List<SubtitleAudioIndexedRecording>> listSavedRecordings({
    required Directory appDataDirectory,
  }) async =>
      (await listSavedRecordingsWithStatus(appDataDirectory: appDataDirectory))
          .recordings;

  static Future<SubtitleAudioRecordingIndexResult>
  listSavedRecordingsWithStatus({required Directory appDataDirectory}) async {
    // Keep indexing bounded, but count only entries that produce visible
    // recordings so stale lock-only folders cannot consume the history quota.
    const maxSessionDirectories = 250;
    const maxRecordingDirectories = 1000;
    const maxVisitedSessionEntries = 5000;
    const maxVisitedRecordingEntries = 5000;
    final recordingsRoot = await _findRecordingsRoot(
      Directory(appDataDirectory.absolute.path),
      createIfMissing: false,
    );
    if (recordingsRoot == null) {
      return SubtitleAudioRecordingIndexResult(
        recordings: const <SubtitleAudioIndexedRecording>[],
        truncated: false,
      );
    }

    final recordings = <SubtitleAudioIndexedRecording>[];
    final appDataRoot = Directory(appDataDirectory.absolute.path);
    var visitedSessions = 0;
    var visitedRecordings = 0;
    var visitedRecordingEntries = 0;
    final sessionEntities = await recordingsRoot
        .list(followLinks: false)
        .take(maxVisitedSessionEntries + 1)
        .toList();
    var truncated = sessionEntities.length > maxVisitedSessionEntries;
    if (truncated) sessionEntities.removeLast();
    // Filesystem enumeration order is not stable across Windows machines.
    sessionEntities.sort(_compareFileSystemEntityPaths);
    for (final sessionEntity in sessionEntities) {
      if (visitedRecordings >= maxRecordingDirectories) {
        truncated = true;
        break;
      }
      final sessionDigest = _basename(sessionEntity.path);
      if (!_isSha256Digest(sessionDigest)) continue;
      if (await FileSystemEntity.type(sessionEntity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      if (_activeRecordingSessions.contains(
        _activeRegistryKey(appDataRoot, sessionDigest),
      )) {
        continue;
      }
      if (await _sessionHasActiveOsLock(Directory(sessionEntity.path))) {
        continue;
      }
      final recordingEntities = await Directory(sessionEntity.path)
          .list(followLinks: false)
          .take(maxVisitedRecordingEntries + 1)
          .toList();
      if (recordingEntities.length > maxVisitedRecordingEntries) {
        truncated = true;
        recordingEntities.removeLast();
      }
      recordingEntities.sort(_compareFileSystemEntityPaths);
      var hasIndexedRecording = false;
      var reachedSessionLimit = false;
      for (final recordingEntity in recordingEntities) {
        if (visitedRecordingEntries++ >= maxVisitedRecordingEntries) {
          truncated = true;
          reachedSessionLimit = true;
          break;
        }
        final recordingId = _basename(recordingEntity.path);
        if (!_isRecordingId(recordingId)) continue;
        if (await FileSystemEntity.type(
              recordingEntity.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
          continue;
        }
        try {
          final decoded = await _readManifestWithSafeFallback(
            recordingDirectory: Directory(recordingEntity.path),
            sessionDigest: sessionDigest,
            recordingId: recordingId,
          );
          if (decoded == null ||
              decoded['schemaVersion'] != _schemaVersion ||
              decoded['format'] != _recordingFormat) {
            continue;
          }
          final sessionId = decoded['sessionId'];
          final manifestRecordingId = decoded['recordingId'];
          final rawStatus = decoded['status'];
          final startedAt = _parseDateTime(decoded['startedAtUtc']);
          final endedAt = _parseDateTime(decoded['endedAtUtc']);
          if (sessionId is! String ||
              sessionId.trim().isEmpty ||
              sessionId.length > 256 ||
              _digest(sessionId) != sessionDigest ||
              manifestRecordingId != recordingId ||
              startedAt == null ||
              (rawStatus != 'completed' &&
                  rawStatus != 'failed' &&
                  rawStatus != 'interrupted' &&
                  rawStatus != 'recording')) {
            continue;
          }

          final rawSources = decoded['sources'];
          if (rawSources is! List ||
              rawSources.isEmpty ||
              rawSources.length > _maxSourcesPerManifest) {
            continue;
          }
          final indexedFiles = <SubtitleAudioIndexedFile>[];
          final recoveryCandidates = <SubtitleAudioRecoveryCandidate>[];
          var emptyAudioSources = 0;
          final seenSources = <String>{};
          var recordingDroppedFrames = 0;
          var recordingDiscontinuities = 0;
          var lossCountersKnown = true;
          for (final rawSource in rawSources) {
            if (rawSource is! Map<String, dynamic>) {
              lossCountersKnown = false;
              continue;
            }
            final sourceId = rawSource['sourceId'];
            final sourceKindName = rawSource['sourceKind'];
            final rawDroppedFrames = _nonNegativeCount(
              rawSource['droppedFrames'],
            );
            final rawDiscontinuities = _nonNegativeCount(
              rawSource['discontinuities'],
            );
            if (rawDroppedFrames == null || rawDiscontinuities == null) {
              lossCountersKnown = false;
            }
            final droppedFrames = rawDroppedFrames ?? 0;
            final discontinuities = rawDiscontinuities ?? 0;
            if (sourceId is! String ||
                sourceId.trim().isEmpty ||
                sourceId.length > 1024 ||
                sourceKindName is! String) {
              lossCountersKnown = false;
              continue;
            }
            SubtitleAudioSourceKind? sourceKind;
            for (final candidate in SubtitleAudioSourceKind.values) {
              if (candidate.name == sourceKindName) {
                sourceKind = candidate;
                break;
              }
            }
            if (sourceKind == null) {
              lossCountersKnown = false;
              continue;
            }
            final sourceKey = '${sourceKind.name}:$sourceId';
            if (!seenSources.add(sourceKey)) {
              lossCountersKnown = false;
              continue;
            }
            recordingDroppedFrames += droppedFrames;
            recordingDiscontinuities += discontinuities;

            final expectedRelativePath = _joinRelative(<String>[
              _recordingRootRelativePath,
              sessionDigest,
              recordingId,
              '${sourceKind.name}-${_digest(sourceId)}.wav',
            ]);
            final sourcePath = rawSource['relativePath'];
            final hasStoredPath = sourcePath == expectedRelativePath;
            final sampleRateHz = rawSource['sampleRateHz'];
            final channelCount = rawSource['channelCount'];
            final channelMask = rawSource['channelMask'];
            final dataBytes = rawSource['dataBytes'];
            final samplesPerChannel = rawSource['samplesPerChannel'];
            final framesWritten = rawSource['framesWritten'];
            final hasNoAudioData =
                sourcePath == null &&
                rawSource['container'] == null &&
                rawSource['codec'] == null &&
                rawSource['bitsPerSample'] == null &&
                rawSource['sampleRateHz'] == null &&
                rawSource['channelCount'] == null &&
                channelMask == null &&
                dataBytes == 0 &&
                (samplesPerChannel == null || samplesPerChannel == 0) &&
                (framesWritten == null || framesWritten == 0);
            final file = File(
              joinAppDataPath(
                appDataDirectory.absolute.path,
                expectedRelativePath,
              ),
            );
            if ((!hasStoredPath && !hasNoAudioData) ||
                (hasStoredPath &&
                    (rawSource['container'] != 'wav' ||
                        rawSource['codec'] != 'pcm_s16le' ||
                        rawSource['bitsPerSample'] != 16))) {
              continue;
            }
            if (hasNoAudioData) {
              if (rawStatus == 'recording' ||
                  rawStatus == 'interrupted' ||
                  rawStatus == 'failed') {
                final candidate = await _readInterruptedRawPcm(
                  file,
                  sourceId: sourceId,
                  sourceKind: sourceKind,
                  sampleRateHz: null,
                  channelCount: null,
                  channelMask: null,
                );
                if (candidate != null) {
                  recoveryCandidates.add(candidate);
                  continue;
                }
              }
              emptyAudioSources++;
              continue;
            }
            if (hasStoredPath &&
                (sampleRateHz is! int ||
                    _validSampleRate(sampleRateHz) == null ||
                    channelCount is! int ||
                    _validChannelCount(channelCount) == null ||
                    (channelMask != null &&
                        !_isValidChannelMask(channelMask, channelCount)) ||
                    dataBytes is! int ||
                    dataBytes < 0 ||
                    dataBytes > _maxRiffDataBytes ||
                    dataBytes % (channelCount * 2) != 0 ||
                    (samplesPerChannel != null &&
                        (samplesPerChannel is! int ||
                            samplesPerChannel < 0 ||
                            samplesPerChannel !=
                                dataBytes ~/ (channelCount * 2))) ||
                    (framesWritten != null &&
                        (framesWritten is! int ||
                            framesWritten < 0 ||
                            framesWritten > _maxRiffDataBytes ||
                            (samplesPerChannel is int &&
                                framesWritten > samplesPerChannel))))) {
              continue;
            }
            final wavInfo = await _readValidPcm16Wav(
              file,
              expectedSampleRateHz: hasStoredPath ? sampleRateHz as int : null,
              expectedChannelCount: hasStoredPath ? channelCount as int : null,
              expectedChannelMask: hasStoredPath && channelMask is int
                  ? channelMask
                  : null,
              expectedDataBytes: hasStoredPath ? dataBytes as int : null,
              allowLegacyMultichannel: rawStatus == 'completed',
            );
            if (wavInfo != null && wavInfo.dataBytes > 0) {
              if (rawStatus == 'completed' &&
                  wavInfo.headerBytes == 44 &&
                  wavInfo.channelCount > 2 &&
                  wavInfo.dataBytes <= _maxRiffDataBytesForHeader(68)) {
                recoveryCandidates.add(
                  SubtitleAudioRecoveryCandidate(
                    sourceId: sourceId,
                    sourceKind: sourceKind,
                    rawFile: file,
                    dataBytes: wavInfo.dataBytes,
                    headerBytes: wavInfo.headerBytes,
                    sampleRateHz: wavInfo.sampleRateHz,
                    channelCount: wavInfo.channelCount,
                    legacyMultichannelUpgrade: true,
                  ),
                );
              } else {
                indexedFiles.add(
                  SubtitleAudioIndexedFile(
                    sourceKind: sourceKind,
                    file: file,
                    sampleRateHz: wavInfo.sampleRateHz,
                    channelCount: wavInfo.channelCount,
                    dataBytes: wavInfo.dataBytes,
                    channelMask: wavInfo.channelMask,
                    headerBytes: wavInfo.headerBytes,
                    droppedFrames: droppedFrames,
                    discontinuities: discontinuities,
                  ),
                );
              }
            } else if (wavInfo != null) {
              emptyAudioSources++;
            } else if (rawStatus == 'recording' ||
                rawStatus == 'interrupted' ||
                rawStatus == 'failed') {
              final candidate = await _readInterruptedRawPcm(
                file,
                sourceId: sourceId,
                sourceKind: sourceKind,
                sampleRateHz: sampleRateHz,
                channelCount: channelCount,
                channelMask: channelMask,
                minimumDataBytes: hasStoredPath ? dataBytes as int : null,
              );
              if (candidate != null) recoveryCandidates.add(candidate);
            }
          }
          if (indexedFiles.isEmpty &&
              recoveryCandidates.isEmpty &&
              emptyAudioSources == 0 &&
              recordingDroppedFrames == 0 &&
              recordingDiscontinuities == 0 &&
              rawStatus != 'failed' &&
              rawStatus != 'recording' &&
              rawStatus != 'interrupted') {
            continue;
          }
          if (!hasIndexedRecording) {
            if (visitedSessions >= maxSessionDirectories) {
              truncated = true;
              reachedSessionLimit = true;
              break;
            }
            visitedSessions++;
            hasIndexedRecording = true;
          }
          if (visitedRecordings >= maxRecordingDirectories) {
            truncated = true;
            reachedSessionLimit = true;
            break;
          }
          visitedRecordings++;
          recordings.add(
            SubtitleAudioIndexedRecording(
              sessionId: sessionId,
              recordingId: recordingId,
              status: rawStatus == 'completed'
                  ? recordingDroppedFrames > 0 || recordingDiscontinuities > 0
                        ? SubtitleAudioIndexedRecordingStatus.incomplete
                        : lossCountersKnown
                        ? SubtitleAudioIndexedRecordingStatus.completed
                        : SubtitleAudioIndexedRecordingStatus.unknown
                  : rawStatus == 'failed'
                  ? SubtitleAudioIndexedRecordingStatus.failed
                  : SubtitleAudioIndexedRecordingStatus.interrupted,
              startedAtUtc: startedAt.toUtc(),
              endedAtUtc: endedAt?.toUtc(),
              directory: Directory(recordingEntity.path),
              files: indexedFiles,
              recoveryCandidates: recoveryCandidates,
              emptyAudioSources: emptyAudioSources,
              droppedFrames: recordingDroppedFrames,
              discontinuities: recordingDiscontinuities,
              lossCountersKnown: lossCountersKnown,
            ),
          );
        } on Object {
          // A malformed or concurrently removed entry is skipped in isolation.
        }
      }
      if (reachedSessionLimit) break;
    }
    recordings.sort(
      (left, right) => right.startedAtUtc.compareTo(left.startedAtUtc),
    );
    return SubtitleAudioRecordingIndexResult(
      recordings: recordings,
      truncated: truncated,
    );
  }

  /// Recovers interrupted PCM or upgrades a verified legacy multichannel WAV.
  ///
  /// The original WAV and manifest are never changed. Missing sample-rate or
  /// channel metadata must be supplied explicitly by the user.
  /// The session lock is acquired non-blockingly so recovery cannot race an
  /// active recorder in another process.
  static Future<String> recoverInterruptedRecording({
    required Directory appDataDirectory,
    required String sessionId,
    required String recordingId,
    required String sourceId,
    required SubtitleAudioSourceKind sourceKind,
    int? sampleRateHz,
    int? channelCount,
    int? channelMask,
    bool upgradeLegacyMultichannel = false,
  }) async {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty || normalizedSessionId.length > 256) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Invalid session ID.');
    }
    if (!_isRecordingId(recordingId)) {
      throw ArgumentError.value(
        recordingId,
        'recordingId',
        'Invalid recording ID.',
      );
    }
    final normalizedSourceId = sourceId.trim();
    if (normalizedSourceId.isEmpty || normalizedSourceId.length > 1024) {
      throw ArgumentError.value(sourceId, 'sourceId', 'Invalid source ID.');
    }

    final appDataRoot = Directory(appDataDirectory.absolute.path);
    final sessionDigest = _digest(normalizedSessionId);
    final registryKey = _activeRegistryKey(appDataRoot, sessionDigest);
    if (_activeRecordingSessions.contains(registryKey) ||
        _deletingRecordingSessions.contains(registryKey)) {
      throw StateError('This session is active or being modified.');
    }

    final recordingsRoot = await _findRecordingsRoot(
      appDataRoot,
      createIfMissing: false,
    );
    if (recordingsRoot == null) {
      throw StateError('The interrupted recording no longer exists.');
    }
    final sessionDirectory = Directory(
      joinAppDataPath(recordingsRoot.path, sessionDigest),
    );
    if (await FileSystemEntity.type(
          sessionDirectory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      throw StateError('The interrupted recording session is unavailable.');
    }

    final lockFile = File(
      joinAppDataPath(sessionDirectory.path, '.session.lock'),
    );
    if (await FileSystemEntity.type(lockFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('The recording session lock is unavailable.');
    }
    RandomAccessFile? lockHandle;
    Directory? recoveredDirectory;
    try {
      lockHandle = await lockFile.open(mode: FileMode.append);
      try {
        await lockHandle.lock(FileLock.exclusive, 0, 1);
      } on Object {
        throw StateError('The recording is still active in another process.');
      }

      final oldDirectory = Directory(
        joinAppDataPath(sessionDirectory.path, recordingId),
      );
      if (await FileSystemEntity.type(oldDirectory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError('The interrupted recording no longer exists.');
      }
      final decoded = await _readManifestWithSafeFallback(
        recordingDirectory: oldDirectory,
        sessionDigest: sessionDigest,
        recordingId: recordingId,
      );
      final sourceStatus = decoded?['status'];
      final isInterruptedSource =
          sourceStatus == 'recording' ||
          sourceStatus == 'interrupted' ||
          sourceStatus == 'failed';
      final isLegacyUpgradeSource =
          upgradeLegacyMultichannel && sourceStatus == 'completed';
      if (decoded == null ||
          decoded['schemaVersion'] != _schemaVersion ||
          decoded['format'] != _recordingFormat ||
          decoded['recordingId'] != recordingId ||
          decoded['sessionId'] != normalizedSessionId ||
          (!isInterruptedSource && !isLegacyUpgradeSource)) {
        throw FormatException('This recording is not eligible for recovery.');
      }
      final startedAtUtc = _parseDateTime(decoded['startedAtUtc']);
      final rawSources = decoded['sources'];
      if (startedAtUtc == null ||
          rawSources is! List ||
          rawSources.isEmpty ||
          rawSources.length > _maxSourcesPerManifest) {
        throw FormatException('The interrupted recording metadata is invalid.');
      }
      Map<String, dynamic>? matchingSource;
      for (final rawSource in rawSources) {
        if (rawSource is Map<String, dynamic> &&
            rawSource['sourceId'] == normalizedSourceId &&
            rawSource['sourceKind'] == sourceKind.name) {
          matchingSource = rawSource;
          break;
        }
      }
      final source = matchingSource;
      if (source == null) {
        throw FormatException(
          'The selected audio source is not in this recording.',
        );
      }

      final storedSampleRate = _validSampleRate(source['sampleRateHz']);
      final storedChannels = _validChannelCount(source['channelCount']);
      final storedChannelMask = _validChannelMask(
        source['channelMask'],
        storedChannels,
      );
      if ((source['sampleRateHz'] != null && storedSampleRate == null) ||
          (source['channelCount'] != null && storedChannels == null) ||
          (source['channelMask'] != null && storedChannelMask == null)) {
        throw FormatException(
          'The interrupted audio format metadata is invalid.',
        );
      }
      final storedDataBytes = source['dataBytes'];
      if (storedDataBytes is! int ||
          storedDataBytes < 0 ||
          storedDataBytes > _maxRiffDataBytes ||
          (storedChannels != null &&
              storedDataBytes % (storedChannels * 2) != 0)) {
        throw FormatException('The interrupted PCM metadata is invalid.');
      }
      final storedSamplesPerChannel = source['samplesPerChannel'];
      if (storedSamplesPerChannel != null &&
          (storedSamplesPerChannel is! int ||
              storedSamplesPerChannel < 0 ||
              storedSamplesPerChannel > _maxRiffDataBytes ||
              (storedChannels != null &&
                  storedSamplesPerChannel !=
                      storedDataBytes ~/ (storedChannels * 2)))) {
        throw FormatException(
          'The interrupted PCM sample metadata is invalid.',
        );
      }
      final storedFramesWritten = source['framesWritten'];
      if (storedFramesWritten != null &&
          (storedFramesWritten is! int ||
              storedFramesWritten < 0 ||
              storedFramesWritten > _maxRiffDataBytes ||
              (storedSamplesPerChannel is int &&
                  storedFramesWritten > storedSamplesPerChannel))) {
        throw FormatException('The interrupted PCM frame metadata is invalid.');
      }

      final sourceRelativePath = _joinRelative(<String>[
        _recordingRootRelativePath,
        sessionDigest,
        recordingId,
        '${sourceKind.name}-${_digest(normalizedSourceId)}.wav',
      ]);
      final hasStoredPath = source['relativePath'] != null;
      if ((hasStoredPath && source['relativePath'] != sourceRelativePath) ||
          (!hasStoredPath && decoded['status'] != 'recording')) {
        throw FormatException('The audio path does not match its recording.');
      }
      if (hasStoredPath &&
          (source['container'] != 'wav' ||
              source['codec'] != 'pcm_s16le' ||
              source['bitsPerSample'] != 16)) {
        throw FormatException(
          'The interrupted audio format metadata is invalid.',
        );
      }
      if (!hasStoredPath &&
          (source['container'] != null ||
              source['codec'] != null ||
              source['bitsPerSample'] != null ||
              storedSampleRate != null ||
              storedChannels != null ||
              storedDataBytes != 0 ||
              (storedSamplesPerChannel != null &&
                  storedSamplesPerChannel != 0) ||
              (storedFramesWritten != null && storedFramesWritten != 0))) {
        throw FormatException('The uncheckpointed audio metadata is invalid.');
      }
      final rawFile = File(
        joinAppDataPath(appDataRoot.path, sourceRelativePath),
      );
      final requestedSampleRate = storedSampleRate ?? sampleRateHz;
      final requestedChannels = storedChannels ?? channelCount;
      final requestedChannelMask = storedChannelMask ?? channelMask;
      final candidate = upgradeLegacyMultichannel
          ? await _readLegacyMultichannelPcmWav(
              rawFile,
              sourceId: normalizedSourceId,
              sourceKind: sourceKind,
              sampleRateHz: requestedSampleRate,
              channelCount: requestedChannels,
              channelMask: requestedChannelMask,
              dataBytes: storedDataBytes,
            )
          : await _readInterruptedRawPcm(
              rawFile,
              sourceId: normalizedSourceId,
              sourceKind: sourceKind,
              sampleRateHz: requestedSampleRate,
              channelCount: requestedChannels,
              channelMask: requestedChannelMask,
              minimumDataBytes: hasStoredPath ? storedDataBytes : null,
            );
      if (candidate == null || candidate.dataBytes <= 0) {
        throw FormatException(
          'The interrupted recording has no recoverable PCM data.',
        );
      }

      final candidateSampleRate = candidate.sampleRateHz;
      final candidateChannels = candidate.channelCount;
      final candidateChannelMask = candidate.channelMask;
      if (storedSampleRate != null &&
          sampleRateHz != null &&
          sampleRateHz != storedSampleRate) {
        throw FormatException(
          'The sample rate does not match the saved recording metadata.',
        );
      }
      if (storedChannels != null &&
          channelCount != null &&
          channelCount != storedChannels) {
        throw FormatException(
          'The channel count does not match the saved recording metadata.',
        );
      }
      final resolvedSampleRate = candidateSampleRate ?? sampleRateHz;
      final resolvedChannels = candidateChannels ?? channelCount;
      final resolvedChannelMask = candidateChannelMask ?? channelMask;
      if (resolvedSampleRate == null ||
          resolvedSampleRate <= 0 ||
          resolvedSampleRate > AudioFrame.maxSampleRateHz ||
          resolvedChannels == null ||
          resolvedChannels <= 0 ||
          resolvedChannels > AudioFrame.maxChannelCount) {
        throw FormatException(
          'This older recording does not contain a valid audio format. Choose the sample rate and channel count to recover it.',
        );
      }
      if (candidate.dataBytes % (resolvedChannels * 2) != 0) {
        throw FormatException(
          'The PCM payload length does not match the selected channel count.',
        );
      }

      final recoveredRecordingId = _newSecureRecordingId();
      final newRecordingDirectory = Directory(
        joinAppDataPath(sessionDirectory.path, recoveredRecordingId),
      );
      await newRecordingDirectory.create();
      recoveredDirectory = newRecordingDirectory;
      final relativePath = _joinRelative(<String>[
        _recordingRootRelativePath,
        sessionDigest,
        recoveredRecordingId,
        '${sourceKind.name}-${_digest(normalizedSourceId)}.wav',
      ]);
      final recoveredFile = File(
        joinAppDataPath(appDataRoot.path, relativePath),
      );
      await recoveredFile.create(exclusive: true);
      final outputChannelMask = resolvedChannels > 2
          ? resolvedChannelMask ?? 0
          : null;
      RandomAccessFile? output;
      var copiedBytes = 0;
      try {
        output = await recoveredFile.open(mode: FileMode.writeOnly);
        await output.writeFrom(
          _buildPcm16WavHeader(
            sampleRateHz: resolvedSampleRate,
            channelCount: resolvedChannels,
            channelMask: outputChannelMask,
            dataBytes: candidate.dataBytes,
          ),
        );
        final payload = rawFile.openRead(candidate.headerBytes);
        await for (final chunk in payload) {
          if (copiedBytes + chunk.length > candidate.dataBytes) {
            throw FileSystemException(
              'The interrupted PCM file changed during recovery.',
            );
          }
          await output.writeFrom(chunk);
          copiedBytes += chunk.length;
        }
        final after = await rawFile.stat();
        if (copiedBytes != candidate.dataBytes ||
            after.size != candidate.dataBytes + candidate.headerBytes) {
          throw FileSystemException(
            'The interrupted PCM file changed during recovery.',
          );
        }
        await output.flush();
        await output.close();
        output = null;
      } finally {
        await output?.close();
      }

      final now = DateTime.now().toUtc();
      final upgradingLegacyMultichannel = candidate.legacyMultichannelUpgrade;
      final completedAtUtc = upgradingLegacyMultichannel
          ? (_parseDateTime(decoded['endedAtUtc']) ?? now)
          : now;
      final manifest = <String, Object?>{
        'schemaVersion': _schemaVersion,
        'recordingId': recoveredRecordingId,
        'sessionId': normalizedSessionId,
        'status': upgradingLegacyMultichannel ? 'completed' : 'interrupted',
        'format': _recordingFormat,
        'startedAtUtc': startedAtUtc.toUtc().toIso8601String(),
        'endedAtUtc': completedAtUtc.toIso8601String(),
        'error': upgradingLegacyMultichannel
            ? null
            : 'recovered_from_interrupted_recording',
        'sources': <Object?>[
          <String, Object?>{
            'sourceId': normalizedSourceId,
            'sourceKind': sourceKind.name,
            'relativePath': relativePath,
            'container': 'wav',
            'codec': 'pcm_s16le',
            'sampleRateHz': resolvedSampleRate,
            'channelCount': resolvedChannels,
            'channelMask': outputChannelMask,
            'bitsPerSample': 16,
            'dataBytes': candidate.dataBytes,
            'samplesPerChannel': candidate.dataBytes ~/ (resolvedChannels * 2),
            'framesWritten': upgradingLegacyMultichannel
                ? source['framesWritten']
                : 0,
            'droppedFrames': upgradingLegacyMultichannel
                ? source['droppedFrames']
                : null,
            'discontinuities': upgradingLegacyMultichannel
                ? source['discontinuities']
                : null,
            'firstSequence': upgradingLegacyMultichannel
                ? source['firstSequence']
                : null,
            'lastSequence': upgradingLegacyMultichannel
                ? source['lastSequence']
                : null,
            'startedAtUtc': startedAtUtc.toUtc().toIso8601String(),
            'endedAtUtc': completedAtUtc.toIso8601String(),
            'error': upgradingLegacyMultichannel
                ? null
                : 'Completeness cannot be verified after interruption.',
          },
        ],
      };
      final manifestFile = File(
        joinAppDataPath(newRecordingDirectory.path, 'manifest.json'),
      );
      final temporaryManifest = File('${manifestFile.path}.tmp');
      await temporaryManifest.writeAsString(jsonEncode(manifest), flush: true);
      await temporaryManifest.rename(manifestFile.path);
      return recoveredRecordingId;
    } on Object {
      final directory = recoveredDirectory;
      if (directory != null) {
        try {
          await directory.delete(recursive: true);
        } on Object {
          // Preserve the original interrupted recording even if cleanup fails.
        }
      }
      rethrow;
    } finally {
      if (lockHandle != null) {
        try {
          await lockHandle.unlock(0, 1);
        } on Object {
          // Closing the handle also releases an OS-held lock.
        }
        try {
          await lockHandle.close();
        } on Object {
          // Do not hide the recovery result behind a late close error.
        }
      }
    }
  }

  /// Deletes one validated recording without touching sibling recordings or
  /// subtitle history. The per-session lock serializes deletion with writers.
  static Future<int> deleteRecording({
    required Directory appDataDirectory,
    required String sessionId,
    required String recordingId,
  }) async {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty || normalizedSessionId.length > 256) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Invalid session ID.');
    }
    if (!_isRecordingId(recordingId)) {
      throw ArgumentError.value(
        recordingId,
        'recordingId',
        'Invalid recording ID.',
      );
    }
    final appDataRoot = Directory(appDataDirectory.absolute.path);
    final sessionDigest = _digest(normalizedSessionId);
    final registryKey = _activeRegistryKey(appDataRoot, sessionDigest);
    if (_activeRecordingSessions.contains(registryKey)) {
      throw StateError('Cannot delete recordings while the session is active.');
    }
    if (!_deletingRecordingSessions.add(registryKey)) {
      throw StateError('The session recordings are already being deleted.');
    }
    RandomAccessFile? lockHandle;
    var lockAcquired = false;
    try {
      final matches = await listSavedRecordings(appDataDirectory: appDataRoot);
      final indexedMatches = matches
          .where(
            (recording) =>
                recording.sessionId == normalizedSessionId &&
                recording.recordingId == recordingId,
          )
          .toList(growable: false);
      if (indexedMatches.isEmpty) return 0;
      final indexed = indexedMatches.first;
      if (indexed.recoveryCandidates.isNotEmpty) {
        throw StateError(
          'Cannot delete a recording while recoverable PCM data exists.',
        );
      }

      final recordingsRoot = await _findRecordingsRoot(
        appDataRoot,
        createIfMissing: false,
      );
      if (recordingsRoot == null) return 0;
      final sessionDirectory = Directory(
        joinAppDataPath(recordingsRoot.path, sessionDigest),
      );
      if (await FileSystemEntity.type(
            sessionDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory) {
        return 0;
      }
      final lockFile = File(
        joinAppDataPath(sessionDirectory.path, '.session.lock'),
      );
      final lockType = await FileSystemEntity.type(
        lockFile.path,
        followLinks: false,
      );
      if (lockType == FileSystemEntityType.link ||
          lockType == FileSystemEntityType.directory) {
        throw StateError('The recording lock path is not a regular file.');
      }
      lockHandle = await lockFile.open(mode: FileMode.append);
      await lockHandle.lock(FileLock.exclusive, 0, 1);
      lockAcquired = true;
      if (_activeRecordingSessions.contains(registryKey)) {
        throw StateError(
          'Cannot delete recordings while the session is active.',
        );
      }
      final recordingDirectory = Directory(
        joinAppDataPath(sessionDirectory.path, recordingId),
      );
      if (await FileSystemEntity.type(
            recordingDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory) {
        return 0;
      }
      return await _deleteFileSystemEntityWithoutFollowingLinks(
        recordingDirectory,
      );
    } finally {
      try {
        if (lockHandle != null) {
          if (lockAcquired) {
            try {
              await lockHandle.unlock(0, 1);
            } on FileSystemException {
              // Closing the handle below releases an OS-held lock as well.
            }
          }
          await lockHandle.close();
        }
      } finally {
        _deletingRecordingSessions.remove(registryKey);
      }
    }
  }

  /// Deletes only recordings beneath this app-data directory for [sessionId].
  ///
  /// The target is derived from the session ID's SHA-256 digest; caller input
  /// is never used as a filesystem path. Active recordings are rejected both
  /// by an in-process registry and by a non-blocking OS file lock, so another
  /// app process cannot race deletion against an active writer. Subtitle
  /// history and files outside the dedicated recording root are untouched.
  static Future<int> deleteSessionRecordings({
    required Directory appDataDirectory,
    required String sessionId,
  }) async {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty || normalizedSessionId.length > 256) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'Must contain 1 to 256 non-whitespace characters.',
      );
    }

    final appDataRoot = Directory(appDataDirectory.absolute.path);
    final sessionDigest = _digest(normalizedSessionId);
    final registryKey = _activeRegistryKey(appDataRoot, sessionDigest);
    if (_activeRecordingSessions.contains(registryKey)) {
      throw StateError('Cannot delete recordings while the session is active.');
    }
    if (!_deletingRecordingSessions.add(registryKey)) {
      throw StateError('The session recordings are already being deleted.');
    }

    RandomAccessFile? lockHandle;
    var lockAcquired = false;
    try {
      final recordingsRoot = await _findRecordingsRoot(
        appDataRoot,
        createIfMissing: false,
      );
      if (recordingsRoot == null) return 0;
      final sessionDirectory = Directory(
        joinAppDataPath(recordingsRoot.path, sessionDigest),
      );
      final sessionDirectoryType = await FileSystemEntity.type(
        sessionDirectory.path,
        followLinks: false,
      );
      if (sessionDirectoryType == FileSystemEntityType.notFound) {
        await sessionDirectory.create();
      } else if (sessionDirectoryType != FileSystemEntityType.directory) {
        throw StateError(
          'The hashed session recording path is not a directory.',
        );
      }

      if (_activeRecordingSessions.contains(registryKey)) {
        throw StateError(
          'Cannot delete recordings while the session is active.',
        );
      }
      final lockFile = File(
        joinAppDataPath(sessionDirectory.path, '.session.lock'),
      );
      final lockFileType = await FileSystemEntity.type(
        lockFile.path,
        followLinks: false,
      );
      if (lockFileType == FileSystemEntityType.link ||
          lockFileType == FileSystemEntityType.directory) {
        throw StateError(
          'The session recording lock path is not a regular file.',
        );
      }
      lockHandle = await lockFile.open(mode: FileMode.append);
      try {
        await lockHandle.lock(FileLock.exclusive, 0, 1);
        lockAcquired = true;
      } on FileSystemException {
        throw StateError(
          'Cannot delete recordings while another process is recording.',
        );
      }

      var removedEntries = 0;
      await for (final entry in sessionDirectory.list(followLinks: false)) {
        if (_basename(entry.path) == '.session.lock') continue;
        removedEntries += await _deleteFileSystemEntityWithoutFollowingLinks(
          entry,
        );
      }
      return removedEntries;
    } finally {
      try {
        if (lockHandle != null) {
          if (lockAcquired) {
            try {
              await lockHandle.unlock(0, 1);
            } on FileSystemException {
              // Closing the handle below releases an OS-held lock as well.
            }
          }
          await lockHandle.close();
        }
      } finally {
        _deletingRecordingSessions.remove(registryKey);
      }
    }
  }

  /// Whether a new recording may start after any earlier file lock is released.
  bool get canStart =>
      !_disposed &&
      (_state.status == SubtitleAudioRecordingStatus.idle ||
          _state.status == SubtitleAudioRecordingStatus.stopped ||
          (_state.status == SubtitleAudioRecordingStatus.failed &&
              _sessionLockHandle == null));

  /// Starts local recording. This must be called explicitly by the user flow.
  ///
  /// [frames] must be broadcast. A fresh random recording directory is used
  /// for each call, including a later recording in the same subtitle session.
  Future<SubtitleAudioRecordingState> start({
    required String sessionId,
    required String? captureAttemptId,
    required Iterable<SubtitleSessionAudioSource> sources,
    required Stream<AudioFrame> frames,
  }) async {
    if (_disposed) throw StateError('This audio recorder has been disposed.');
    if (!canStart) {
      throw StateError(
        'The audio recorder is already active or still stopping.',
      );
    }
    if (!frames.isBroadcast) {
      throw ArgumentError.value(
        frames,
        'frames',
        'A broadcast AudioFrame stream is required.',
      );
    }

    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty || normalizedSessionId.length > 256) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'Must contain 1 to 256 non-whitespace characters.',
      );
    }
    final normalizedCaptureAttemptId = captureAttemptId?.trim();
    if (captureAttemptId != null && normalizedCaptureAttemptId!.isEmpty) {
      throw ArgumentError.value(
        captureAttemptId,
        'captureAttemptId',
        'Must be null or contain non-whitespace characters.',
      );
    }
    final normalizedSources = _normalizeSources(sources);
    if (normalizedSources.isEmpty) {
      throw ArgumentError.value(
        sources,
        'sources',
        'At least one audio source must be declared.',
      );
    }

    final sessionDigest = _digest(normalizedSessionId);
    final activeRegistryKey = _activeRegistryKey(
      _appDataDirectory,
      sessionDigest,
    );
    if (_activeRecordingSessions.contains(activeRegistryKey) ||
        _deletingRecordingSessions.contains(activeRegistryKey)) {
      throw StateError('This session already has an active audio recording.');
    }

    _sessionId = normalizedSessionId;
    _captureAttemptId = normalizedCaptureAttemptId;
    _recordingId = _newRecordingId();
    _recordingDirectoryRelativePath = _joinRelative(<String>[
      _recordingRootRelativePath,
      sessionDigest,
      _recordingId!,
    ]);
    _manifestRelativePath = _joinRelative(<String>[
      _recordingDirectoryRelativePath!,
      'manifest.json',
    ]);
    _startedAtUtc = _clock().toUtc();
    _failureMessage = null;
    _writeFailed = false;
    _pendingWrites = 0;
    _stopFuture = null;
    _writeTail = Future<void>.value();
    _definitions
      ..clear()
      ..addEntries(
        normalizedSources.map(
          (source) => MapEntry(
            _RecordingSourceKey(source.sourceId, source.sourceKind),
            source,
          ),
        ),
      );
    _writers.clear();
    _droppedFrames.clear();
    _activeSessionRegistryKey = activeRegistryKey;
    _activeRecordingSessions.add(activeRegistryKey);

    final recordingDirectory = Directory(
      joinAppDataPath(_appDataDirectory.path, _recordingDirectoryRelativePath!),
    );
    try {
      final recordingsRoot = await _findRecordingsRoot(
        _appDataDirectory,
        createIfMissing: true,
      );
      final sessionDirectory = Directory(
        joinAppDataPath(recordingsRoot!.path, sessionDigest),
      );
      final sessionDirectoryType = await FileSystemEntity.type(
        sessionDirectory.path,
        followLinks: false,
      );
      if (sessionDirectoryType == FileSystemEntityType.notFound) {
        await sessionDirectory.create();
      } else if (sessionDirectoryType != FileSystemEntityType.directory) {
        throw StateError(
          'The hashed session recording path is not a directory.',
        );
      }
      final lockFile = File(
        joinAppDataPath(sessionDirectory.path, '.session.lock'),
      );
      final lockType = await FileSystemEntity.type(
        lockFile.path,
        followLinks: false,
      );
      if (lockType == FileSystemEntityType.link ||
          lockType == FileSystemEntityType.directory) {
        throw StateError(
          'The session recording lock path is not a regular file.',
        );
      }
      final lockHandle = await lockFile.open(mode: FileMode.append);
      try {
        await lockHandle.lock(FileLock.exclusive, 0, 1);
        _sessionLockHandle = lockHandle;
      } on Object {
        await lockHandle.close();
        throw StateError('This session is being recorded by another process.');
      }
      final recordingDirectoryType = await FileSystemEntity.type(
        recordingDirectory.path,
        followLinks: false,
      );
      if (recordingDirectoryType == FileSystemEntityType.notFound) {
        await recordingDirectory.create();
      } else {
        throw StateError('The unique recording directory already exists.');
      }

      _state = _buildState(SubtitleAudioRecordingStatus.recording);
      await _writeManifest(status: 'recording');
      _publishState(immediate: true);

      _frameSubscription = frames.listen(
        _acceptFrame,
        onError: (Object error, StackTrace stackTrace) {
          _scheduleStopWithFailure('audio_frame_stream_error: $error');
        },
        onDone: () {
          if (_state.status == SubtitleAudioRecordingStatus.recording) {
            unawaited(stop());
          }
        },
        cancelOnError: false,
      );
      return _state;
    } on Object catch (error) {
      _failureMessage = 'recording_start_failed: $error';
      if (_sessionLockHandle != null) {
        try {
          await _writeManifest(status: 'failed', endedAtUtc: _clock().toUtc());
        } on Object {
          // Preserve the original start failure if even the failure manifest
          // cannot be committed.
        }
      }
      await _releaseSessionLock();
      _state = _buildState(SubtitleAudioRecordingStatus.failed);
      _publishState(immediate: true);
      rethrow;
    }
  }

  /// Stops accepting frames, finalizes every WAV header, and commits manifest.
  Future<SubtitleAudioRecordingState> stop({String? failureReason}) {
    final normalizedFailureReason = failureReason?.trim();
    final hasFailureReason =
        normalizedFailureReason != null && normalizedFailureReason.isNotEmpty;
    if (hasFailureReason && _sessionId != null && _recordingId != null) {
      _failureMessage ??= normalizedFailureReason;
    }

    final activeStop = _stopFuture;
    if (activeStop != null) {
      if (!hasFailureReason) return activeStop;
      return activeStop.then((stopped) {
        if (stopped.status != SubtitleAudioRecordingStatus.stopped) {
          return stopped;
        }
        return _markStoppedRecordingFailed(stopped, normalizedFailureReason);
      });
    }
    if (_state.status == SubtitleAudioRecordingStatus.idle) {
      return Future<SubtitleAudioRecordingState>.value(_state);
    }
    if (_state.status == SubtitleAudioRecordingStatus.stopped) {
      if (!hasFailureReason) {
        return Future<SubtitleAudioRecordingState>.value(_state);
      }
      return _markStoppedRecordingFailed(_state, normalizedFailureReason);
    }
    if (_state.status == SubtitleAudioRecordingStatus.failed &&
        _sessionLockHandle == null) {
      return Future<SubtitleAudioRecordingState>.value(_state);
    }

    final stopOperation = _finishStop();
    _stopFuture = stopOperation;
    return stopOperation;
  }

  Future<SubtitleAudioRecordingState> _markStoppedRecordingFailed(
    SubtitleAudioRecordingState stopped,
    String failureReason,
  ) async {
    _failureMessage ??= failureReason;
    final endedAtUtc = stopped.endedAtUtc ?? _clock().toUtc();
    _state = _buildState(
      SubtitleAudioRecordingStatus.failed,
      endedAtUtc: endedAtUtc,
    );
    try {
      await _writeManifest(status: 'failed', endedAtUtc: endedAtUtc);
    } finally {
      _publishState(immediate: true);
    }
    return _state;
  }

  /// Updates which capture attempt may be appended to the active WAV files.
  /// A null ID pauses acceptance while preserving the current recording.
  void setCaptureAttemptId(String? captureAttemptId) {
    if (_disposed) return;
    final normalizedCaptureAttemptId = captureAttemptId?.trim();
    if (captureAttemptId != null && normalizedCaptureAttemptId!.isEmpty) {
      throw ArgumentError.value(
        captureAttemptId,
        'captureAttemptId',
        'Must be null or contain non-whitespace characters.',
      );
    }
    _captureAttemptId = normalizedCaptureAttemptId;
  }

  /// Completes an active recording before closing the state stream.
  Future<void> dispose() async {
    if (_disposed) return;
    if (_state.status == SubtitleAudioRecordingStatus.recording ||
        _state.status == SubtitleAudioRecordingStatus.stopping ||
        (_state.status == SubtitleAudioRecordingStatus.failed &&
            _sessionLockHandle != null)) {
      await stop();
    }
    _disposed = true;
    _stateThrottleTimer?.cancel();
    _stateThrottleTimer = null;
    await _stateController.close();
  }

  Future<SubtitleAudioRecordingState> _finishStop() async {
    _state = _buildState(SubtitleAudioRecordingStatus.stopping);
    _publishState(immediate: true);

    try {
      await _frameSubscription?.cancel();
    } on Object catch (error) {
      _failureMessage ??= 'audio_frame_stream_cancel_failed: $error';
    }
    _frameSubscription = null;

    await _writeTail;
    final endedAtUtc = _clock().toUtc();
    for (final writer in _writers.values) {
      try {
        await writer.finalize(endedAtUtc: endedAtUtc);
      } on Object catch (error) {
        writer.error ??= 'wav_finalize_failed: $error';
        _failureMessage ??= 'wav_finalize_failed: $error';
        await writer.closeAfterFailure();
      }
    }

    try {
      await _writeManifest(
        status: _failureMessage == null ? 'completed' : 'failed',
        endedAtUtc: endedAtUtc,
      );
    } on Object catch (error) {
      _failureMessage ??= 'manifest_write_failed: $error';
    }
    await _releaseSessionLock();

    final status = _failureMessage == null
        ? SubtitleAudioRecordingStatus.stopped
        : SubtitleAudioRecordingStatus.failed;
    _state = _buildState(status, endedAtUtc: endedAtUtc);
    _publishState(immediate: true);
    return _state;
  }

  void _acceptFrame(AudioFrame frame) {
    if (_state.status != SubtitleAudioRecordingStatus.recording ||
        frame.sessionId != _sessionId ||
        _captureAttemptId == null ||
        frame.captureAttemptId != _captureAttemptId) {
      return;
    }
    final key = _RecordingSourceKey(frame.sourceId, frame.sourceKind);
    if (!_definitions.containsKey(key)) return;
    if (_pendingWrites >= _maxPendingFrames) {
      _droppedFrames.update(key, (count) => count + 1, ifAbsent: () => 1);
      _publishState();
      return;
    }

    _pendingWrites++;
    _writeTail = _writeTail
        .then<void>((_) => _appendFrame(key, frame))
        .catchError((Object error, StackTrace stackTrace) {
          _writeFailed = true;
          _failureMessage ??= 'audio_frame_write_failed: $error';
          final writer = _writers[key];
          if (writer != null) writer.error ??= _failureMessage;
          _state = _buildState(SubtitleAudioRecordingStatus.failed);
          _publishState(immediate: true);
          Timer.run(() {
            if (_sessionLockHandle != null &&
                (_state.status == SubtitleAudioRecordingStatus.recording ||
                    _state.status == SubtitleAudioRecordingStatus.failed)) {
              unawaited(stop());
            }
          });
        })
        .whenComplete(() {
          _pendingWrites--;
          _publishState();
        });
  }

  Future<void> _appendFrame(_RecordingSourceKey key, AudioFrame frame) async {
    if (_writeFailed) return;
    final definition = _definitions[key];
    if (definition == null) return;

    _validateFrame(frame);
    final writer = _writers[key] ?? await _createWriter(definition, frame);
    if (writer.sampleRateHz != frame.sampleRateHz ||
        writer.channelCount != frame.channelCount ||
        writer.channelMask !=
            (frame.channelCount > 2 ? frame.channelMask ?? 0 : null)) {
      throw FormatException(
        'A source changed WAV sample rate or channel count during recording.',
      );
    }
    if (writer.lastCaptureAttemptId != frame.captureAttemptId) {
      if (writer.lastCaptureAttemptId != null) {
        // A new capture attempt marks a real gap in the local recording even
        // though each native worker restarts its sequence number at zero.
        writer.discontinuities++;
      }
      writer.lastCaptureAttemptId = frame.captureAttemptId;
      writer.lastSequence = null;
    }
    if (writer.lastSequence != null && frame.sequence <= writer.lastSequence!) {
      _droppedFrames.update(key, (count) => count + 1, ifAbsent: () => 1);
      return;
    }

    final pcm16 = _convertToPcm16(frame);
    if (pcm16.length >
        _maxRiffDataBytesForHeader(writer.headerBytes) - writer.dataBytes) {
      throw StateError('WAV data reached the RIFF 4 GiB size limit.');
    }
    final shouldCheckpointFormat = writer.framesWritten == 0;
    await writer.handle.writeFrom(pcm16);
    writer.dataBytes += pcm16.length;
    writer.samplesPerChannel += frame.sampleCount;
    writer.framesWritten++;
    if (writer.firstSequence == null) {
      writer.firstSequence = frame.sequence;
      writer.startedAtUtc = _clock().toUtc();
    }
    if ((writer.lastSequence != null &&
            frame.sequence > writer.lastSequence! + 1) ||
        frame.hasDiscontinuityBefore) {
      writer.discontinuities++;
    }
    writer.lastSequence = frame.sequence;
    if (shouldCheckpointFormat) {
      // Persist enough format information to recover the raw PCM if Windows
      // terminates the process before the WAV header can be finalized.
      await writer.handle.flush();
      await _writeManifest(status: 'recording');
    }
    _publishState();
  }

  Future<_WavSourceWriter> _createWriter(
    SubtitleSessionAudioSource definition,
    AudioFrame firstFrame,
  ) async {
    final key = _RecordingSourceKey(definition.sourceId, definition.sourceKind);
    final relativePath = _joinRelative(<String>[
      _recordingDirectoryRelativePath!,
      '${definition.sourceKind.name}-${_digest(definition.sourceId)}.wav',
    ]);
    final file = File(joinAppDataPath(_appDataDirectory.path, relativePath));
    await file.parent.create(recursive: true);
    await file.create(exclusive: true);
    final handle = await file.open(mode: FileMode.writeOnly);
    final channelMask = firstFrame.channelCount > 2
        ? firstFrame.channelMask ?? 0
        : null;
    try {
      // Persist the format in the file before the first PCM frame reaches
      // disk. If Windows terminates the app before the manifest checkpoint,
      // recovery can still identify an extensible multichannel header and
      // will not mistake its last 24 bytes for audio samples.
      await handle.writeFrom(
        _buildPcm16WavHeader(
          sampleRateHz: firstFrame.sampleRateHz,
          channelCount: firstFrame.channelCount,
          channelMask: channelMask,
          dataBytes: 0,
        ),
      );
      await handle.flush();
    } on Object {
      await handle.close();
      rethrow;
    }
    final writer = _WavSourceWriter(
      key: key,
      file: file,
      handle: handle,
      relativePath: relativePath,
      sampleRateHz: firstFrame.sampleRateHz,
      channelCount: firstFrame.channelCount,
      channelMask: channelMask,
    );
    _writers[key] = writer;
    return writer;
  }

  void _validateFrame(AudioFrame frame) {
    if (frame.sampleRateHz <= 0 ||
        frame.sampleRateHz > AudioFrame.maxSampleRateHz ||
        frame.channelCount <= 0 ||
        frame.channelCount > AudioFrame.maxChannelCount ||
        frame.sampleCount <= 0 ||
        frame.sampleCount *
                frame.channelCount *
                frame.sampleFormat.bytesPerSample !=
            frame.pcmBytes.length ||
        frame.pcmBytes.length > AudioFrame.maxPcmBytes) {
      throw FormatException('Audio frame format or byte length is invalid.');
    }
    if (frame.channelCount > 2 &&
        !_isValidChannelMask(frame.channelMask ?? 0, frame.channelCount)) {
      throw FormatException(
        'A multichannel recording requires a speaker mask with one bit per channel.',
      );
    }
    final durationUs =
        frame.sampleCount *
        Duration.microsecondsPerSecond ~/
        frame.sampleRateHz;
    if (durationUs > AudioFrame.maxFrameDurationUs) {
      throw FormatException('Audio frame exceeds the supported duration.');
    }
    final blockAlign = frame.channelCount * 2;
    final byteRate = frame.sampleRateHz * blockAlign;
    if (blockAlign > 0xffff || byteRate > 0xffffffff) {
      throw FormatException('Audio format cannot be represented by RIFF/WAV.');
    }
  }

  Uint8List _convertToPcm16(AudioFrame frame) {
    if (frame.sampleFormat == AudioPcmSampleFormat.signedInt16LittleEndian) {
      return Uint8List.fromList(frame.pcmBytes);
    }

    final sampleTotal = frame.sampleCount * frame.channelCount;
    final input = ByteData.sublistView(frame.pcmBytes);
    final output = Uint8List(sampleTotal * 2);
    final outputData = ByteData.sublistView(output);
    for (var index = 0; index < sampleTotal; index++) {
      var value = input.getFloat32(index * 4, Endian.little);
      if (value.isNaN) {
        value = 0;
      } else if (value.isInfinite) {
        value = value.isNegative ? -1 : 1;
      }
      value = value.clamp(-1.0, 1.0).toDouble();
      final quantized = value <= -1
          ? -32768
          : value >= 1
          ? 32767
          : value < 0
          ? (value * 32768).round()
          : (value * 32767).round();
      outputData.setInt16(index * 2, quantized, Endian.little);
    }
    return output;
  }

  Future<void> _writeManifest({
    required String status,
    DateTime? endedAtUtc,
  }) async {
    final manifestRelativePath = _manifestRelativePath;
    if (manifestRelativePath == null || _sessionId == null) return;
    final value = <String, Object?>{
      'schemaVersion': _schemaVersion,
      'recordingId': _recordingId,
      'sessionId': _sessionId,
      'status': status,
      'format': _recordingFormat,
      'startedAtUtc': _startedAtUtc?.toIso8601String(),
      'endedAtUtc': endedAtUtc?.toUtc().toIso8601String(),
      'error': _failureMessage,
      'sources': _buildState(
        status == 'recording'
            ? SubtitleAudioRecordingStatus.recording
            : status == 'completed'
            ? SubtitleAudioRecordingStatus.stopped
            : SubtitleAudioRecordingStatus.failed,
        endedAtUtc: endedAtUtc,
      ).sources.map(_sourceManifestValue).toList(growable: false),
    };
    final target = File(
      joinAppDataPath(_appDataDirectory.path, manifestRelativePath),
    );
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    if (await temp.exists()) await temp.delete();
    if (await backup.exists()) await backup.delete();
    await temp.writeAsString(jsonEncode(value), flush: true);
    try {
      if (await target.exists()) await target.rename(backup.path);
      await temp.rename(target.path);
    } on Object {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    if (await backup.exists()) {
      try {
        await backup.delete();
      } on FileSystemException {
        // The newly renamed manifest remains authoritative.
      }
    }
  }

  Map<String, Object?> _sourceManifestValue(
    SubtitleAudioRecordingSourceState source,
  ) => <String, Object?>{
    'sourceId': source.sourceId,
    'sourceKind': source.sourceKind.name,
    'relativePath': source.relativePath,
    'container': source.relativePath == null ? null : 'wav',
    'codec': source.relativePath == null ? null : 'pcm_s16le',
    'sampleRateHz': source.sampleRateHz,
    'channelCount': source.channelCount,
    'channelMask': source.channelMask,
    'bitsPerSample': source.relativePath == null ? null : 16,
    'dataBytes': source.dataBytes,
    'samplesPerChannel': source.samplesPerChannel,
    'framesWritten': source.framesWritten,
    'droppedFrames': source.droppedFrames,
    'discontinuities': source.discontinuities,
    'firstSequence': source.firstSequence,
    'lastSequence': source.lastSequence,
    'startedAtUtc': source.startedAtUtc?.toIso8601String(),
    'endedAtUtc': source.endedAtUtc?.toIso8601String(),
    'error': source.error,
  };

  SubtitleAudioRecordingState _buildState(
    SubtitleAudioRecordingStatus status, {
    DateTime? endedAtUtc,
  }) {
    final sources = _definitions.entries.map((entry) {
      final writer = _writers[entry.key];
      return SubtitleAudioRecordingSourceState(
        sourceId: entry.value.sourceId,
        sourceKind: entry.value.sourceKind,
        relativePath: writer?.relativePath,
        sampleRateHz: writer?.sampleRateHz,
        channelCount: writer?.channelCount,
        channelMask: writer?.channelMask,
        dataBytes: writer?.dataBytes ?? 0,
        samplesPerChannel: writer?.samplesPerChannel ?? 0,
        framesWritten: writer?.framesWritten ?? 0,
        droppedFrames:
            (_droppedFrames[entry.key] ?? 0) + (writer?.droppedFrames ?? 0),
        discontinuities: writer?.discontinuities ?? 0,
        firstSequence: writer?.firstSequence,
        lastSequence: writer?.lastSequence,
        startedAtUtc: writer?.startedAtUtc,
        endedAtUtc: endedAtUtc,
        error: writer?.error,
      );
    });
    return SubtitleAudioRecordingState(
      status: status,
      sessionId: _sessionId,
      recordingId: _recordingId,
      manifestRelativePath: _manifestRelativePath,
      startedAtUtc: _startedAtUtc,
      endedAtUtc: endedAtUtc,
      error: _failureMessage,
      sources: sources,
    );
  }

  void _scheduleStopWithFailure(String message) {
    _failureMessage ??= message;
    _state = _buildState(SubtitleAudioRecordingStatus.failed);
    _publishState(immediate: true);
    Timer.run(() {
      if (_sessionLockHandle != null &&
          (_state.status == SubtitleAudioRecordingStatus.recording ||
              _state.status == SubtitleAudioRecordingStatus.failed)) {
        unawaited(stop());
      }
    });
  }

  void _publishState({bool immediate = false}) {
    if (_disposed || _stateController.isClosed) return;
    _state = _buildState(_state.status, endedAtUtc: _state.endedAtUtc);
    if (immediate) {
      _stateThrottleTimer?.cancel();
      _stateThrottleTimer = null;
      _emitStateNow();
      return;
    }

    final last = _lastStateBroadcastElapsed;
    final elapsed = _broadcastClock.elapsed;
    final remaining = last == null
        ? Duration.zero
        : _progressBroadcastInterval - (elapsed - last);
    if (remaining <= Duration.zero) {
      _emitStateNow();
    } else {
      _stateThrottleTimer ??= Timer(remaining, _emitStateNow);
    }
  }

  void _emitStateNow() {
    _stateThrottleTimer?.cancel();
    _stateThrottleTimer = null;
    if (_disposed || _stateController.isClosed) return;
    _lastStateBroadcastElapsed = _broadcastClock.elapsed;
    _stateController.add(_state);
  }

  Future<void> _releaseSessionLock() async {
    final lockHandle = _sessionLockHandle;
    final registryKey = _activeSessionRegistryKey;
    _sessionLockHandle = null;
    _activeSessionRegistryKey = null;
    if (registryKey != null) _activeRecordingSessions.remove(registryKey);
    if (lockHandle == null) return;
    try {
      await lockHandle.unlock(0, 1);
    } on FileSystemException {
      // Closing the handle below releases an OS-held lock as well.
    }
    await lockHandle.close();
  }

  String _newRecordingId() {
    return _newSecureRecordingId();
  }

  static String _newSecureRecordingId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  List<SubtitleSessionAudioSource> _normalizeSources(
    Iterable<SubtitleSessionAudioSource> sources,
  ) {
    final result = <SubtitleSessionAudioSource>[];
    final seen = <_RecordingSourceKey>{};
    for (final source in sources) {
      final normalizedId = source.sourceId.trim();
      if (normalizedId.isEmpty || normalizedId.length > 1024) {
        throw ArgumentError.value(
          source.sourceId,
          'sources.sourceId',
          'Must contain 1 to 1024 non-whitespace characters.',
        );
      }
      final normalized = SubtitleSessionAudioSource(
        sourceId: normalizedId,
        sourceKind: source.sourceKind,
        displayName: source.displayName,
      );
      final key = _RecordingSourceKey(
        normalized.sourceId,
        normalized.sourceKind,
      );
      if (!seen.add(key)) {
        throw ArgumentError('Each source identity may be declared only once.');
      }
      result.add(normalized);
    }
    return List<SubtitleSessionAudioSource>.unmodifiable(result);
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _joinRelative(Iterable<String> segments) => segments.join('/');

  static String _activeRegistryKey(
    Directory appDataRoot,
    String sessionDigest,
  ) {
    var normalizedRoot = Directory(appDataRoot.absolute.path).absolute.path;
    if (Platform.isWindows) normalizedRoot = normalizedRoot.toLowerCase();
    return '$normalizedRoot${Platform.pathSeparator}$sessionDigest';
  }

  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static bool _isSha256Digest(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  static bool _isRecordingId(String value) =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

  static Future<bool> _sessionHasActiveOsLock(
    Directory sessionDirectory,
  ) async {
    final lockFile = File(
      joinAppDataPath(sessionDirectory.path, '.session.lock'),
    );
    final type = await FileSystemEntity.type(lockFile.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) return true;
    RandomAccessFile? handle;
    try {
      handle = await lockFile.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive, 0, 1);
      await handle.unlock(0, 1);
      return false;
    } on Object {
      return true;
    } finally {
      try {
        await handle?.close();
      } on Object {
        // A stale lock handle is released when the OS closes it.
      }
    }
  }

  static Future<Map<String, dynamic>?> _readManifestWithSafeFallback({
    required Directory recordingDirectory,
    required String sessionDigest,
    required String recordingId,
  }) async {
    final manifest = File(
      joinAppDataPath(recordingDirectory.path, 'manifest.json'),
    );
    final manifestType = await FileSystemEntity.type(
      manifest.path,
      followLinks: false,
    );
    if (manifestType == FileSystemEntityType.file) {
      return _readBoundedManifest(manifest);
    }
    if (manifestType != FileSystemEntityType.notFound) return null;

    for (final suffix in const <String>['.tmp', '.bak']) {
      final sidecar = File('${manifest.path}$suffix');
      if (await FileSystemEntity.type(sidecar.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final decoded = await _readBoundedManifest(sidecar);
      if (decoded != null &&
          _isStrictFallbackManifest(
            decoded,
            sessionDigest: sessionDigest,
            recordingId: recordingId,
          )) {
        return decoded;
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _readBoundedManifest(File file) async {
    try {
      final before = await file.stat();
      if (before.size <= 0 || before.size > _maxManifestBytes) return null;
      final handle = await file.open(mode: FileMode.read);
      Uint8List bytes;
      try {
        bytes = await handle.read(_maxManifestBytes + 1);
      } finally {
        await handle.close();
      }
      final after = await file.stat();
      if (bytes.length != before.size ||
          bytes.length > _maxManifestBytes ||
          after.size != before.size ||
          after.modified != before.modified) {
        return null;
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  static bool _isStrictFallbackManifest(
    Map<String, dynamic> manifest, {
    required String sessionDigest,
    required String recordingId,
  }) {
    final sessionId = manifest['sessionId'];
    final status = manifest['status'];
    final startedAt = _parseDateTime(manifest['startedAtUtc']);
    final endedAt = manifest['endedAtUtc'];
    final error = manifest['error'];
    final rawSources = manifest['sources'];
    if (manifest['schemaVersion'] != _schemaVersion ||
        manifest['format'] != _recordingFormat ||
        manifest['recordingId'] != recordingId ||
        sessionId is! String ||
        sessionId.trim().isEmpty ||
        sessionId.length > 256 ||
        _digest(sessionId) != sessionDigest ||
        (status != 'completed' &&
            status != 'failed' &&
            status != 'interrupted' &&
            status != 'recording') ||
        startedAt == null ||
        (endedAt != null && _parseDateTime(endedAt) == null) ||
        (status == 'recording' && endedAt != null) ||
        (status != 'recording' && endedAt == null) ||
        (error != null && (error is! String || error.length > 4096)) ||
        rawSources is! List ||
        rawSources.isEmpty ||
        rawSources.length > _maxSourcesPerManifest) {
      return false;
    }

    final seenSources = <String>{};
    for (final rawSource in rawSources) {
      if (rawSource is! Map<String, dynamic>) return false;
      final sourceId = rawSource['sourceId'];
      final sourceKindName = rawSource['sourceKind'];
      if (sourceId is! String ||
          sourceId.trim().isEmpty ||
          sourceId.length > 1024 ||
          sourceKindName is! String) {
        return false;
      }
      SubtitleAudioSourceKind? sourceKind;
      for (final candidate in SubtitleAudioSourceKind.values) {
        if (candidate.name == sourceKindName) {
          sourceKind = candidate;
          break;
        }
      }
      if (sourceKind == null ||
          !seenSources.add('${sourceKind.name}:$sourceId')) {
        return false;
      }

      final expectedRelativePath = _joinRelative(<String>[
        _recordingRootRelativePath,
        sessionDigest,
        recordingId,
        '${sourceKind.name}-${_digest(sourceId)}.wav',
      ]);
      final relativePath = rawSource['relativePath'];
      final hasPath = relativePath != null;
      if ((hasPath && relativePath != expectedRelativePath) ||
          (status != 'recording' && !hasPath)) {
        return false;
      }

      final sampleRate = _validSampleRate(rawSource['sampleRateHz']);
      final channels = _validChannelCount(rawSource['channelCount']);
      final channelMask = _validChannelMask(rawSource['channelMask'], channels);
      final rawSampleRate = rawSource['sampleRateHz'];
      final rawChannels = rawSource['channelCount'];
      final dataBytes = rawSource['dataBytes'];
      final samplesPerChannel = rawSource['samplesPerChannel'];
      final framesWritten = rawSource['framesWritten'];
      if ((rawSampleRate != null && sampleRate == null) ||
          (rawChannels != null && channels == null) ||
          (rawSource['channelMask'] != null && channelMask == null) ||
          dataBytes is! int ||
          dataBytes < 0 ||
          dataBytes > _maxRiffDataBytes ||
          !_isBoundedManifestCount(samplesPerChannel) ||
          !_isBoundedManifestCount(framesWritten) ||
          !_isOptionalBoundedManifestCount(rawSource['droppedFrames']) ||
          !_isOptionalBoundedManifestCount(rawSource['discontinuities']) ||
          !_isOptionalBoundedManifestCount(rawSource['firstSequence']) ||
          !_isOptionalBoundedManifestCount(rawSource['lastSequence']) ||
          !_isOptionalManifestDate(rawSource['startedAtUtc']) ||
          !_isOptionalManifestDate(rawSource['endedAtUtc']) ||
          !_isOptionalManifestError(rawSource['error'])) {
        return false;
      }
      final validSamplesPerChannel = samplesPerChannel as int;
      final validFramesWritten = framesWritten as int;

      if (hasPath) {
        if (rawSource['container'] != 'wav' ||
            rawSource['codec'] != 'pcm_s16le' ||
            rawSource['bitsPerSample'] != 16 ||
            sampleRate == null ||
            channels == null ||
            dataBytes % (channels * 2) != 0 ||
            validSamplesPerChannel != dataBytes ~/ (channels * 2) ||
            validFramesWritten > validSamplesPerChannel) {
          return false;
        }
      } else if (rawSource['container'] != null ||
          rawSource['codec'] != null ||
          rawSource['bitsPerSample'] != null ||
          sampleRate != null ||
          channels != null ||
          channelMask != null ||
          dataBytes != 0 ||
          samplesPerChannel != 0 ||
          framesWritten != 0) {
        return false;
      }
    }
    return true;
  }

  static bool _isBoundedManifestCount(Object? value) =>
      value is int && value >= 0 && value <= _maxRiffDataBytes;

  static bool _isOptionalBoundedManifestCount(Object? value) =>
      value == null || _isBoundedManifestCount(value);

  static bool _isOptionalManifestDate(Object? value) =>
      value == null || _parseDateTime(value) != null;

  static bool _isOptionalManifestError(Object? value) =>
      value == null || (value is String && value.length <= 4096);

  static int? _validSampleRate(Object? value) {
    if (value is! int || value <= 0 || value > AudioFrame.maxSampleRateHz) {
      return null;
    }
    return value;
  }

  static int? _validChannelCount(Object? value) {
    if (value is! int || value <= 0 || value > AudioFrame.maxChannelCount) {
      return null;
    }
    return value;
  }

  static int? _validChannelMask(Object? value, int? channelCount) {
    if (value == null) return null;
    if (value is! int || value < 0 || value > 0xffffffff) return null;
    if (value == 0) return channelCount == null || channelCount > 2 ? 0 : null;
    var bits = value;
    var setBits = 0;
    while (bits != 0) {
      setBits += bits & 1;
      bits >>= 1;
    }
    if (channelCount != null && setBits != channelCount) return null;
    return value;
  }

  static bool _isValidChannelMask(Object? value, int channelCount) =>
      value is int &&
      value >= 0 &&
      _validChannelMask(value, channelCount) == value;

  static Future<SubtitleAudioRecoveryCandidate?> _readInterruptedRawPcm(
    File file, {
    required String sourceId,
    required SubtitleAudioSourceKind sourceKind,
    required Object? sampleRateHz,
    required Object? channelCount,
    required Object? channelMask,
    int? minimumDataBytes,
  }) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      final before = await file.stat();
      final storedSampleRate = _validSampleRate(sampleRateHz);
      final storedChannels = _validChannelCount(channelCount);
      final storedMask = _validChannelMask(channelMask, storedChannels);
      if ((sampleRateHz != null && storedSampleRate == null) ||
          (channelCount != null && storedChannels == null) ||
          (channelMask != null && storedMask == null) ||
          before.size < 44 ||
          before.size > _maxRiffDataBytes + 68) {
        return null;
      }
      final handle = await file.open(mode: FileMode.read);
      Uint8List header;
      try {
        header = await handle.read(before.size < 68 ? before.size : 68);
      } finally {
        await handle.close();
      }
      if (header.length < 44) return null;
      final after = await file.stat();
      if (after.size != before.size || after.modified != before.modified) {
        return null;
      }

      var resolvedHeaderBytes =
          storedChannels != null && storedChannels > 2 && storedMask != null
          ? 68
          : 44;
      var resolvedSampleRate = storedSampleRate;
      var resolvedChannels = storedChannels;
      var resolvedMask = storedMask;
      var headerMatches = false;

      // New recordings write a format-bearing placeholder before their first
      // PCM frame. Read that metadata directly because a crash can happen
      // before the matching manifest checkpoint is durable.
      final data = ByteData.sublistView(header);
      final extensibleHeader =
          header.length >= 68 &&
          _asciiAt(header, 0, 'RIFF') &&
          _asciiAt(header, 8, 'WAVE') &&
          _asciiAt(header, 12, 'fmt ') &&
          data.getUint32(16, Endian.little) == 40 &&
          data.getUint16(20, Endian.little) == 0xfffe &&
          _asciiAt(header, 60, 'data');
      final classicHeader =
          _asciiAt(header, 0, 'RIFF') &&
          _asciiAt(header, 8, 'WAVE') &&
          _asciiAt(header, 12, 'fmt ') &&
          data.getUint32(16, Endian.little) == 16 &&
          data.getUint16(20, Endian.little) == 1 &&
          _asciiAt(header, 36, 'data');

      if (extensibleHeader || classicHeader) {
        final parsedHeaderBytes = extensibleHeader ? 68 : 44;
        final parsedChannels = _validChannelCount(
          data.getUint16(22, Endian.little),
        );
        final parsedSampleRate = _validSampleRate(
          data.getUint32(24, Endian.little),
        );
        final parsedMask = extensibleHeader
            ? _validChannelMask(
                data.getUint32(40, Endian.little),
                parsedChannels,
              )
            : null;
        final declaredDataBytes = data.getUint32(
          parsedHeaderBytes == 44 ? 40 : 64,
          Endian.little,
        );
        final dataBytes = before.size - parsedHeaderBytes;
        final declaredRiffBytes = data.getUint32(4, Endian.little);
        final declaredSizesMatch =
            (declaredDataBytes == 0 || declaredDataBytes == dataBytes) &&
            (declaredRiffBytes == parsedHeaderBytes - 8 ||
                declaredRiffBytes == before.size - 8);
        final validPcmHeader =
            parsedChannels != null &&
            parsedSampleRate != null &&
            parsedChannels <= AudioFrame.maxChannelCount &&
            parsedSampleRate <= AudioFrame.maxSampleRateHz &&
            data.getUint32(28, Endian.little) ==
                parsedSampleRate * parsedChannels * 2 &&
            data.getUint16(32, Endian.little) == parsedChannels * 2 &&
            (extensibleHeader
                ? data.getUint16(36, Endian.little) == 22 &&
                      data.getUint16(38, Endian.little) == 16 &&
                      parsedMask != null &&
                      _matchesPcmSubtypeGuid(header, 44)
                : data.getUint16(34, Endian.little) == 16);
        final metadataMatches =
            (storedSampleRate == null ||
                storedSampleRate == parsedSampleRate) &&
            (storedChannels == null || storedChannels == parsedChannels) &&
            (storedMask == null || storedMask == parsedMask);
        if (validPcmHeader &&
            declaredSizesMatch &&
            metadataMatches &&
            dataBytes >= 0 &&
            dataBytes % (parsedChannels * 2) == 0) {
          final expectedHeader = _buildPcm16WavHeader(
            sampleRateHz: parsedSampleRate,
            channelCount: parsedChannels,
            channelMask: parsedMask,
            dataBytes: declaredDataBytes,
          );
          headerMatches = _isValidPartialWavHeader(
            header.sublist(0, parsedHeaderBytes),
            expectedHeader,
          );
          if (headerMatches) {
            resolvedHeaderBytes = parsedHeaderBytes;
            resolvedSampleRate = parsedSampleRate;
            resolvedChannels = parsedChannels;
            resolvedMask = parsedMask;
          }
        }
      }

      final dataBytes = before.size - resolvedHeaderBytes;
      // A header without PCM is not a recoverable recording. Treat it as an
      // empty source in history instead of creating a zero-byte recovery file.
      if (dataBytes <= 0 ||
          dataBytes > _maxRiffDataBytesForHeader(resolvedHeaderBytes)) {
        return null;
      }
      // The manifest is checkpointed after the first audio frame so the
      // format is recoverable. Audio frames written afterwards are not
      // checkpointed individually, so a terminated process can leave a PCM
      // file that is longer than the manifest. Treat the checkpoint as a
      // lower bound; a shorter file still indicates truncation or corruption.
      if (minimumDataBytes != null && dataBytes < minimumDataBytes) {
        return null;
      }
      if (resolvedChannels != null && dataBytes % (resolvedChannels * 2) != 0) {
        return null;
      }
      // Legacy recordings can still contain an all-zero placeholder. Keep
      // the metadata-based fallback for those files, but never guess a
      // multichannel offset when the embedded format is available.
      if (!headerMatches) {
        final fallbackHeader = header.sublist(0, resolvedHeaderBytes);
        headerMatches =
            fallbackHeader.every((byte) => byte == 0) ||
            (resolvedSampleRate != null && resolvedChannels != null
                ? _isValidPartialWavHeader(
                    fallbackHeader,
                    _buildPcm16WavHeader(
                      sampleRateHz: resolvedSampleRate,
                      channelCount: resolvedChannels,
                      channelMask: resolvedHeaderBytes == 68
                          ? resolvedMask
                          : null,
                      dataBytes: dataBytes,
                    ),
                  )
                : false);
      }
      if (!headerMatches) return null;
      return SubtitleAudioRecoveryCandidate(
        sourceId: sourceId,
        sourceKind: sourceKind,
        rawFile: file,
        dataBytes: dataBytes,
        channelMask: resolvedMask,
        headerBytes: resolvedHeaderBytes,
        sampleRateHz: resolvedSampleRate,
        channelCount: resolvedChannels,
      );
    } on Object {
      return null;
    }
  }

  static bool _isValidPartialWavHeader(Uint8List actual, Uint8List expected) {
    if (actual.length != expected.length) return false;
    var exactMatch = true;
    for (var index = 0; index < actual.length; index++) {
      if (actual[index] != expected[index]) {
        exactMatch = false;
        break;
      }
    }
    if (exactMatch) return true;
    for (var prefixLength = 0; prefixLength < actual.length; prefixLength++) {
      var matches = true;
      for (var index = 0; index < prefixLength; index++) {
        if (actual[index] != expected[index]) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      for (var index = prefixLength; index < actual.length; index++) {
        if (actual[index] != 0) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  static Uint8List _buildPcm16WavHeader({
    required int sampleRateHz,
    required int channelCount,
    int? channelMask,
    required int dataBytes,
  }) {
    final extensible = channelMask != null;
    final header = Uint8List(extensible ? 68 : 44);
    final data = ByteData.sublistView(header);
    _writeAscii(header, 0, 'RIFF');
    data.setUint32(4, dataBytes + header.length - 8, Endian.little);
    _writeAscii(header, 8, 'WAVE');
    _writeAscii(header, 12, 'fmt ');
    data.setUint32(16, extensible ? 40 : 16, Endian.little);
    data.setUint16(20, extensible ? 0xfffe : 1, Endian.little);
    data.setUint16(22, channelCount, Endian.little);
    data.setUint32(24, sampleRateHz, Endian.little);
    data.setUint32(28, sampleRateHz * channelCount * 2, Endian.little);
    data.setUint16(32, channelCount * 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    if (extensible) {
      data.setUint16(36, 22, Endian.little);
      data.setUint16(38, 16, Endian.little);
      data.setUint32(40, channelMask, Endian.little);
      header.setRange(44, 60, const <int>[
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x10,
        0x00,
        0x80,
        0x00,
        0x00,
        0xaa,
        0x00,
        0x38,
        0x9b,
        0x71,
      ]);
      _writeAscii(header, 60, 'data');
      data.setUint32(64, dataBytes, Endian.little);
    } else {
      _writeAscii(header, 36, 'data');
      data.setUint32(40, dataBytes, Endian.little);
    }
    return header;
  }

  static void _writeAscii(Uint8List bytes, int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes[offset + index] = value.codeUnitAt(index);
    }
  }

  static DateTime? _parseDateTime(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static int? _nonNegativeCount(Object? value) =>
      value is int && value >= 0 ? value : null;

  static Future<_Pcm16WavInfo?> _readValidPcm16Wav(
    File file, {
    int? expectedSampleRateHz,
    int? expectedChannelCount,
    int? expectedChannelMask,
    int? expectedDataBytes,
    bool allowLegacyMultichannel = false,
  }) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      final length = await file.length();
      if (length < 44 ||
          length > 0xffffffff + 8 ||
          (expectedDataBytes != null && length < expectedDataBytes + 44)) {
        return null;
      }
      final handle = await file.open(mode: FileMode.read);
      try {
        final header = await handle.read(68);
        if (header.length < 44) return null;
        final data = ByteData.sublistView(header);
        if (!_asciiAt(header, 0, 'RIFF') ||
            data.getUint32(4, Endian.little) != length - 8 ||
            !_asciiAt(header, 8, 'WAVE') ||
            !_asciiAt(header, 12, 'fmt ')) {
          return null;
        }
        final formatSize = data.getUint32(16, Endian.little);
        final formatTag = data.getUint16(20, Endian.little);
        final headerBytes = formatSize == 16 && formatTag == 1
            ? 44
            : formatSize == 40 && formatTag == 0xfffe && header.length == 68
            ? 68
            : 0;
        if (headerBytes == 0 ||
            !_asciiAt(header, headerBytes - 8, 'data') ||
            data.getUint32(headerBytes == 44 ? 40 : 64, Endian.little) >
                _maxRiffDataBytesForHeader(headerBytes) ||
            (headerBytes == 44 &&
                data.getUint16(22, Endian.little) > 2 &&
                !allowLegacyMultichannel)) {
          return null;
        }
        final channelCount = data.getUint16(22, Endian.little);
        final sampleRateHz = data.getUint32(24, Endian.little);
        final dataBytes = data.getUint32(
          headerBytes == 44 ? 40 : 64,
          Endian.little,
        );
        final channelMask = headerBytes == 68
            ? data.getUint32(40, Endian.little)
            : null;
        final validBits = headerBytes == 68
            ? data.getUint16(38, Endian.little)
            : data.getUint16(34, Endian.little);
        final pcmGuidMatches =
            headerBytes == 44 || _matchesPcmSubtypeGuid(header, 44);
        final validMask = channelMask == null
            ? null
            : _validChannelMask(channelMask, channelCount);
        if (channelCount <= 0 ||
            channelCount > AudioFrame.maxChannelCount ||
            sampleRateHz <= 0 ||
            sampleRateHz > AudioFrame.maxSampleRateHz ||
            dataBytes + headerBytes != length ||
            dataBytes % (channelCount * 2) != 0 ||
            data.getUint32(28, Endian.little) !=
                sampleRateHz * channelCount * 2 ||
            data.getUint16(32, Endian.little) != channelCount * 2 ||
            validBits != 16 ||
            !pcmGuidMatches ||
            (headerBytes == 68 &&
                (data.getUint16(36, Endian.little) != 22 ||
                    validMask == null)) ||
            (expectedSampleRateHz != null &&
                sampleRateHz != expectedSampleRateHz) ||
            (expectedChannelCount != null &&
                channelCount != expectedChannelCount) ||
            (expectedChannelMask != null &&
                channelMask != expectedChannelMask) ||
            (expectedDataBytes != null && dataBytes != expectedDataBytes)) {
          return null;
        }
        return _Pcm16WavInfo(
          sampleRateHz: sampleRateHz,
          channelCount: channelCount,
          dataBytes: dataBytes,
          headerBytes: headerBytes,
          channelMask: validMask,
        );
      } finally {
        await handle.close();
      }
    } on Object {
      return null;
    }
  }

  static Future<SubtitleAudioRecoveryCandidate?> _readLegacyMultichannelPcmWav(
    File file, {
    required String sourceId,
    required SubtitleAudioSourceKind sourceKind,
    required Object? sampleRateHz,
    required Object? channelCount,
    required Object? channelMask,
    required Object? dataBytes,
  }) async {
    final validSampleRate = _validSampleRate(sampleRateHz);
    final validChannels = _validChannelCount(channelCount);
    final validMask = _validChannelMask(channelMask, validChannels);
    if (validSampleRate == null ||
        validChannels == null ||
        validChannels <= 2 ||
        (channelMask != null && validMask == null) ||
        dataBytes is! int ||
        dataBytes <= 0 ||
        dataBytes > _maxRiffDataBytesForHeader(68)) {
      return null;
    }
    final wavInfo = await _readValidPcm16Wav(
      file,
      expectedSampleRateHz: validSampleRate,
      expectedChannelCount: validChannels,
      expectedChannelMask: channelMask is int ? channelMask : null,
      expectedDataBytes: dataBytes,
      allowLegacyMultichannel: true,
    );
    if (wavInfo == null ||
        wavInfo.headerBytes != 44 ||
        wavInfo.channelCount <= 2 ||
        wavInfo.dataBytes == 0) {
      return null;
    }
    return SubtitleAudioRecoveryCandidate(
      sourceId: sourceId,
      sourceKind: sourceKind,
      rawFile: file,
      dataBytes: wavInfo.dataBytes,
      headerBytes: wavInfo.headerBytes,
      sampleRateHz: wavInfo.sampleRateHz,
      channelCount: wavInfo.channelCount,
      legacyMultichannelUpgrade: true,
    );
  }

  static bool _asciiAt(Uint8List bytes, int offset, String value) {
    if (offset < 0 || offset + value.length > bytes.length) return false;
    for (var index = 0; index < value.length; index++) {
      if (bytes[offset + index] != value.codeUnitAt(index)) return false;
    }
    return true;
  }

  static bool _matchesPcmSubtypeGuid(Uint8List bytes, int offset) {
    const pcmSubtypeGuid = <int>[
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x10,
      0x00,
      0x80,
      0x00,
      0x00,
      0xaa,
      0x00,
      0x38,
      0x9b,
      0x71,
    ];
    if (offset < 0 || offset + pcmSubtypeGuid.length > bytes.length) {
      return false;
    }
    for (var index = 0; index < pcmSubtypeGuid.length; index++) {
      if (bytes[offset + index] != pcmSubtypeGuid[index]) return false;
    }
    return true;
  }

  static int _compareFileSystemEntityPaths(
    FileSystemEntity left,
    FileSystemEntity right,
  ) {
    final leftPath = Platform.isWindows ? left.path.toLowerCase() : left.path;
    final rightPath = Platform.isWindows
        ? right.path.toLowerCase()
        : right.path;
    return leftPath.compareTo(rightPath);
  }

  static Future<Directory?> _findRecordingsRoot(
    Directory appDataRoot, {
    required bool createIfMissing,
  }) async {
    var current = Directory(appDataRoot.absolute.path);
    if (createIfMissing) await current.create(recursive: true);
    final appDataType = await FileSystemEntity.type(
      current.path,
      followLinks: false,
    );
    if (appDataType == FileSystemEntityType.notFound) return null;
    if (appDataType != FileSystemEntityType.directory) {
      throw StateError(
        'The app-data recording root is not a regular directory.',
      );
    }
    for (final segment in const <String>[
      'simultaneous-interpretation',
      'recordings',
    ]) {
      final next = Directory(joinAppDataPath(current.path, segment));
      final type = await FileSystemEntity.type(next.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!createIfMissing) return null;
        await next.create();
      } else if (type != FileSystemEntityType.directory) {
        throw StateError(
          'The audio recording root contains a non-directory path component.',
        );
      }
      current = next;
    }
    return current;
  }

  static Future<int> _deleteFileSystemEntityWithoutFollowingLinks(
    FileSystemEntity entity,
  ) async {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return 0;
    if (type == FileSystemEntityType.link) {
      await Link(entity.path).delete();
      return 1;
    }
    if (type == FileSystemEntityType.file) {
      await File(entity.path).delete();
      return 1;
    }
    if (type != FileSystemEntityType.directory) return 0;

    var removedEntries = 0;
    await for (final child in Directory(entity.path).list(followLinks: false)) {
      removedEntries += await _deleteFileSystemEntityWithoutFollowingLinks(
        child,
      );
    }
    await Directory(entity.path).delete();
    return removedEntries + 1;
  }
}

final class _RecordingSourceKey {
  const _RecordingSourceKey(this.sourceId, this.sourceKind);

  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;

  @override
  bool operator ==(Object other) =>
      other is _RecordingSourceKey &&
      other.sourceId == sourceId &&
      other.sourceKind == sourceKind;

  @override
  int get hashCode => Object.hash(sourceId, sourceKind);
}

final class _Pcm16WavInfo {
  const _Pcm16WavInfo({
    required this.sampleRateHz,
    required this.channelCount,
    required this.dataBytes,
    required this.headerBytes,
    this.channelMask,
  });

  final int sampleRateHz;
  final int channelCount;
  final int dataBytes;
  final int headerBytes;
  final int? channelMask;
}

final class _WavSourceWriter {
  _WavSourceWriter({
    required this.key,
    required this.file,
    required this.handle,
    required this.relativePath,
    required this.sampleRateHz,
    required this.channelCount,
    required this.channelMask,
  });

  final _RecordingSourceKey key;
  final File file;
  final RandomAccessFile handle;
  final String relativePath;
  final int sampleRateHz;
  final int channelCount;
  final int? channelMask;
  int get headerBytes => channelCount > 2 ? 68 : 44;
  int dataBytes = 0;
  int samplesPerChannel = 0;
  int framesWritten = 0;
  int droppedFrames = 0;
  int discontinuities = 0;
  int? firstSequence;
  int? lastSequence;
  String? lastCaptureAttemptId;
  DateTime? startedAtUtc;
  String? error;
  bool _closed = false;

  Future<void> finalize({required DateTime endedAtUtc}) async {
    if (_closed) return;
    await handle.setPosition(0);
    await handle.writeFrom(_buildWavHeader());
    await handle.flush();
    await handle.close();
    _closed = true;
    this.endedAtUtc = endedAtUtc.toUtc();
  }

  DateTime? endedAtUtc;

  Future<void> closeAfterFailure() async {
    if (_closed) return;
    try {
      await handle.close();
    } on FileSystemException {
      // Preserve the original writer failure.
    }
    _closed = true;
  }

  Uint8List _buildWavHeader() {
    final header = Uint8List(headerBytes);
    final data = ByteData.sublistView(header);
    _writeAscii(header, 0, 'RIFF');
    data.setUint32(4, dataBytes + header.length - 8, Endian.little);
    _writeAscii(header, 8, 'WAVE');
    _writeAscii(header, 12, 'fmt ');
    data.setUint32(16, channelCount > 2 ? 40 : 16, Endian.little);
    data.setUint16(20, channelCount > 2 ? 0xfffe : 1, Endian.little);
    data.setUint16(22, channelCount, Endian.little);
    data.setUint32(24, sampleRateHz, Endian.little);
    data.setUint32(28, sampleRateHz * channelCount * 2, Endian.little);
    data.setUint16(32, channelCount * 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    if (channelCount > 2) {
      data.setUint16(36, 22, Endian.little);
      data.setUint16(38, 16, Endian.little);
      data.setUint32(40, channelMask!, Endian.little);
      header.setRange(44, 60, const <int>[
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x10,
        0x00,
        0x80,
        0x00,
        0x00,
        0xaa,
        0x00,
        0x38,
        0x9b,
        0x71,
      ]);
      _writeAscii(header, 60, 'data');
      data.setUint32(64, dataBytes, Endian.little);
    } else {
      _writeAscii(header, 36, 'data');
      data.setUint32(40, dataBytes, Endian.little);
    }
    return header;
  }

  static void _writeAscii(Uint8List bytes, int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes[offset + index] = value.codeUnitAt(index);
    }
  }
}
