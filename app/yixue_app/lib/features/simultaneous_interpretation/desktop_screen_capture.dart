import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

final class DesktopScreenCaptureTarget {
  const DesktopScreenCaptureTarget({
    required this.textureId,
    required this.width,
    required this.height,
    required this.targetName,
    this.captureInstanceId,
  });

  final int textureId;
  final int width;
  final int height;
  final String targetName;
  final int? captureInstanceId;
}

final class DesktopScreenCaptureEvent {
  const DesktopScreenCaptureEvent({
    required this.type,
    required this.status,
    this.errorCode,
    this.detail,
    this.width,
    this.height,
    this.sessionId,
    this.captureAttemptId,
    this.captureInstanceId,
  });

  factory DesktopScreenCaptureEvent.fromMap(Map<Object?, Object?> map) {
    return DesktopScreenCaptureEvent(
      type: map['type']! as String,
      status: map['status'] as String? ?? '',
      errorCode: map['errorCode'] as String?,
      detail: map['detail'] as String?,
      width: map['width'] as int?,
      height: map['height'] as int?,
      sessionId: map['sessionId'] as String?,
      captureAttemptId: map['captureAttemptId'] as String?,
      captureInstanceId: map['captureInstanceId'] as int?,
    );
  }

  final String type;
  final String status;
  final String? errorCode;
  final String? detail;
  final int? width;
  final int? height;
  final String? sessionId;
  final String? captureAttemptId;
  final int? captureInstanceId;
}

/// Windows Graphics Capture bridge for the live preview and local MP4 files.
/// Pixel buffers remain native; this adapter exposes only the texture ID,
/// capture state, and finalized recording path.
final class DesktopScreenCaptureAdapter {
  DesktopScreenCaptureAdapter({
    required Directory this._applicationDataDirectory,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    Random? random,
    DateTime Function()? clock,
  }) : _methodChannel =
           methodChannel ??
           const MethodChannel(
             'com.yixue.yixue_app/ai_tongchuan/screen_capture',
           ),
       _eventChannel =
           eventChannel ??
           const EventChannel(
             'com.yixue.yixue_app/ai_tongchuan/screen_capture_events',
           ),
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  final Directory _applicationDataDirectory;
  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Random _random;
  final DateTime Function() _clock;
  int? _captureInstanceId;
  String? _recordingSessionId;
  String? _recordingCaptureAttemptId;
  bool _lastRecordingAudioFinalized = true;
  bool _previewReleasePending = false;
  Future<void>? _previewReleaseRequest;

  /// Whether Windows confirmed that the companion audio capture had stopped
  /// before the video container was finalized by the most recent stop call.
  bool get lastRecordingAudioFinalized => _lastRecordingAudioFinalized;

  bool isCurrentCaptureEvent(DesktopScreenCaptureEvent event) {
    return event.captureInstanceId == null ||
        _captureInstanceId == null ||
        event.captureInstanceId == _captureInstanceId;
  }

  bool isCurrentRecordingEvent(DesktopScreenCaptureEvent event) {
    if (event.sessionId == null && event.captureAttemptId == null) {
      return true;
    }
    return event.sessionId == _recordingSessionId &&
        event.captureAttemptId == _recordingCaptureAttemptId;
  }

  late final Stream<DesktopScreenCaptureEvent>
  events = _eventChannel.receiveBroadcastStream().map((event) {
    if (event is! Map) {
      throw FormatException('Unexpected desktop screen capture event: $event');
    }
    return DesktopScreenCaptureEvent.fromMap(Map<Object?, Object?>.from(event));
  }).asBroadcastStream();

  Future<bool> isSupported() async =>
      await _methodChannel.invokeMethod<bool>('isSupported') ?? false;

  Future<DesktopScreenCaptureTarget> selectSource() async {
    await _waitForPreviewReleaseComplete(
      timeout: const Duration(seconds: 3),
      pollInterval: const Duration(milliseconds: 16),
    );
    final result = await _methodChannel.invokeMapMethod<String, Object?>(
      'selectSource',
    );
    if (result == null) {
      throw const FormatException('Windows returned no capture target.');
    }
    _captureInstanceId = result['captureInstanceId'] as int?;
    return DesktopScreenCaptureTarget(
      textureId: result['textureId']! as int,
      width: result['width']! as int,
      height: result['height']! as int,
      targetName: result['targetName'] as String? ?? '所选窗口/屏幕',
      captureInstanceId: _captureInstanceId,
    );
  }

  Future<String> startRecording({
    String? sessionId,
    String? captureAttemptId,
  }) async {
    final recordingsDirectory = Directory(
      '${_applicationDataDirectory.path}${Platform.pathSeparator}'
      'simultaneous-interpretation${Platform.pathSeparator}'
      'video-recordings',
    );
    await recordingsDirectory.create(recursive: true);
    final now = _clock();
    final recordingSessionId = _isUuid(sessionId) ? sessionId! : _newId();
    final recordingAttemptId = captureAttemptId ?? _newId();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year.toString().padLeft(4, '0')}'
        '${twoDigits(now.month)}${twoDigits(now.day)}-'
        '${twoDigits(now.hour)}${twoDigits(now.minute)}${twoDigits(now.second)}';
    final outputPath =
        '${recordingsDirectory.path}${Platform.pathSeparator}'
        'screen-$stamp-$recordingSessionId-$pid-'
        '${now.microsecondsSinceEpoch}.partial.mp4';
    _recordingSessionId = recordingSessionId;
    _recordingCaptureAttemptId = recordingAttemptId;
    try {
      await _methodChannel.invokeMethod<void>('startRecording', {
        'outputPath': outputPath,
        'sessionId': recordingSessionId,
        'captureAttemptId': recordingAttemptId,
      });
    } catch (_) {
      if (_recordingSessionId == recordingSessionId &&
          _recordingCaptureAttemptId == recordingAttemptId) {
        _recordingSessionId = null;
        _recordingCaptureAttemptId = null;
      }
      rethrow;
    }
    return outputPath;
  }

  Future<String?> stopRecording() async {
    _lastRecordingAudioFinalized = true;
    final result = await _methodChannel.invokeMapMethod<String, Object?>(
      'stopRecording',
    );
    _lastRecordingAudioFinalized = result?['audioFinalized'] as bool? ?? true;
    return result?['outputPath'] as String?;
  }

  Future<void> stopCapture() async {
    await _methodChannel.invokeMethod<void>('stopCapture');
  }

  /// Stops the preview and requests texture release before another full-screen
  /// route is shown. Native code acknowledges only after Flutter's raster
  /// thread has finished unregistering the old external texture.
  Future<void> releasePreviewForNavigation({
    Duration timeout = const Duration(seconds: 3),
    Duration pollInterval = const Duration(milliseconds: 16),
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
    if (pollInterval <= Duration.zero) {
      throw ArgumentError.value(
        pollInterval,
        'pollInterval',
        'Must be positive.',
      );
    }

    if (!_previewReleasePending) {
      _previewReleasePending = true;
      late final Future<void> request;
      request = _methodChannel
          .invokeMethod<void>('releasePreviewForNavigation')
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              if (identical(_previewReleaseRequest, request)) {
                _previewReleaseRequest = null;
              }
              // Keep the selection barrier until native state is queried.
              // A channel error can arrive after the native handler began
              // retiring the texture, so it is not proof that nothing changed.
              Error.throwWithStackTrace(error, stackTrace);
            },
          );
      _previewReleaseRequest = request;
    }

    await _waitForPreviewReleaseComplete(
      timeout: timeout,
      pollInterval: pollInterval,
    );
  }

  Future<void> _waitForPreviewReleaseComplete({
    required Duration timeout,
    required Duration pollInterval,
  }) async {
    if (!_previewReleasePending) return;

    final elapsed = Stopwatch()..start();
    Duration remainingUntilDeadline() {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'Windows did not finish releasing the screen preview texture.',
          timeout,
        );
      }
      return remaining;
    }

    final releaseRequest = _previewReleaseRequest;
    if (releaseRequest != null) {
      await releaseRequest.timeout(remainingUntilDeadline());
    }
    while (_previewReleasePending) {
      final released = await _methodChannel
          .invokeMethod<bool>('isPreviewReleaseComplete')
          .timeout(remainingUntilDeadline());
      if (released == true) {
        _previewReleasePending = false;
        _previewReleaseRequest = null;
        return;
      }

      final remaining = remainingUntilDeadline();
      await Future<void>.delayed(
        remaining < pollInterval ? remaining : pollInterval,
      );
    }
  }

  String _newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final value = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0'));
    final hex = value.join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

bool _isUuid(String? value) =>
    value != null &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(value);
