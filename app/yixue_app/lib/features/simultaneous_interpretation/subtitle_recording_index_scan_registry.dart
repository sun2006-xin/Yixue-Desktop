import 'dart:async';
import 'dart:io';

import 'subtitle_audio_recording.dart';
import 'subtitle_video_recording_index.dart';

/// Shares active recording-index scans across history-page lifetimes.
///
/// A timed-out Future cannot cancel filesystem work. Keep at most two pending
/// video scans per app-data directory: the timed-out scan and one replacement.
final class SubtitleRecordingIndexScanRegistry {
  SubtitleRecordingIndexScanRegistry();

  static final instance = SubtitleRecordingIndexScanRegistry();

  final Map<String, Future<SubtitleAudioRecordingIndexResult>> _audioScans =
      <String, Future<SubtitleAudioRecordingIndexResult>>{};
  final Map<String, Future<SubtitleVideoRecordingIndexResult>> _videoScans =
      <String, Future<SubtitleVideoRecordingIndexResult>>{};
  final Map<String, Set<Future<SubtitleVideoRecordingIndexResult>>>
  _pendingVideoScans =
      <String, Set<Future<SubtitleVideoRecordingIndexResult>>>{};

  static const _maximumPendingVideoScansPerDirectory = 2;

  bool hasVideoScanCapacity(Directory appDataDirectory) =>
      (_pendingVideoScans[_directoryKey(appDataDirectory)]?.length ?? 0) <
      _maximumPendingVideoScansPerDirectory;

  Future<SubtitleAudioRecordingIndexResult> loadAudio(
    Directory appDataDirectory,
    Future<SubtitleAudioRecordingIndexResult> Function() loader,
  ) => _share(_audioScans, _directoryKey(appDataDirectory), loader);

  Future<SubtitleVideoRecordingIndexResult> loadVideo(
    Directory appDataDirectory,
    Future<SubtitleVideoRecordingIndexResult> Function() loader,
  ) {
    final key = _directoryKey(appDataDirectory);
    final existing = _videoScans[key];
    if (existing != null) return existing;

    final scan = Future<SubtitleVideoRecordingIndexResult>.sync(loader);
    _videoScans[key] = scan;
    final pending = _pendingVideoScans.putIfAbsent(
      key,
      () => <Future<SubtitleVideoRecordingIndexResult>>{},
    );
    pending.add(scan);
    void release() {
      pending.remove(scan);
      if (pending.isEmpty && identical(_pendingVideoScans[key], pending)) {
        _pendingVideoScans.remove(key);
      }
      if (identical(_videoScans[key], scan)) _videoScans.remove(key);
    }

    unawaited(
      scan.then<void>(
        (_) => release(),
        onError: (Object _, StackTrace _) => release(),
      ),
    );
    return scan;
  }

  /// Retires a timed-out video scan so a user-requested refresh can retry.
  ///
  /// Filesystem work cannot be cancelled once started. A replacement is
  /// allowed only while fewer than two scans for this directory are pending.
  /// Repeated timeouts therefore cannot grow the number of directory walks.
  bool releaseTimedOutVideoScan(
    Directory appDataDirectory,
    Future<SubtitleVideoRecordingIndexResult> scan,
  ) {
    final key = _directoryKey(appDataDirectory);
    final pending = _pendingVideoScans[key];
    if (!identical(_videoScans[key], scan) ||
        pending == null ||
        pending.length >= _maximumPendingVideoScansPerDirectory) {
      return false;
    }
    _videoScans.remove(key);
    return true;
  }

  String _directoryKey(Directory directory) {
    final path = directory.absolute.path;
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  Future<T> _share<T>(
    Map<String, Future<T>> scans,
    String key,
    Future<T> Function() loader,
  ) {
    final existing = scans[key];
    if (existing != null) return existing;

    final scan = Future<T>.sync(loader);
    scans[key] = scan;
    void release() {
      if (identical(scans[key], scan)) scans.remove(key);
    }

    unawaited(
      scan.then<void>(
        (_) => release(),
        onError: (Object _, StackTrace _) => release(),
      ),
    );
    return scan;
  }
}
