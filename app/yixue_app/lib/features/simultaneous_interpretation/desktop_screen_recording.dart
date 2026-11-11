import 'dart:io';

import 'package:flutter/services.dart';

import 'audio_capture_contract.dart';

/// Snapshot reported by the Windows Graphics Capture and Media Foundation
/// runner plugin.
final class DesktopScreenRecordingState {
  const DesktopScreenRecordingState({
    required this.status,
    this.path = '',
    this.message = '',
    this.targetName = '',
    this.audioSourceId = '',
    this.audioEnabled = false,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.framesWritten = 0,
    this.audioFramesWritten = 0,
    this.droppedVideoFrames = 0,
    this.durationUs = 0,
  });

  factory DesktopScreenRecordingState.fromMap(Map<Object?, Object?> value) =>
      DesktopScreenRecordingState(
        status: value['status'] as String? ?? 'failed',
        path: value['path'] as String? ?? '',
        message: value['message'] as String? ?? '',
        targetName: value['targetName'] as String? ?? '',
        audioSourceId: value['audioSourceId'] as String? ?? '',
        audioEnabled: value['audioEnabled'] as bool? ?? false,
        videoWidth: value['videoWidth'] as int? ?? 0,
        videoHeight: value['videoHeight'] as int? ?? 0,
        framesWritten: value['framesWritten'] as int? ?? 0,
        audioFramesWritten: value['audioFramesWritten'] as int? ?? 0,
        droppedVideoFrames: value['droppedVideoFrames'] as int? ?? 0,
        durationUs: value['durationUs'] as int? ?? 0,
      );

  final String status;
  final String path;
  final String message;
  final String targetName;
  final String audioSourceId;
  final bool audioEnabled;
  final int videoWidth;
  final int videoHeight;
  final int framesWritten;
  final int audioFramesWritten;
  final int droppedVideoFrames;
  final int durationUs;

  bool get hasTarget => status == 'targetSelected';
  bool get isRecording => status == 'recording' || status == 'starting';
  bool get isTerminal =>
      status == 'stopped' ||
      status == 'failed' ||
      status == 'cancelled' ||
      status == 'idle';
}

/// Reuses the active audio/subtitle session ID for a video recording when one
/// exists, so the history index can associate the media with its session.
/// Standalone video recordings keep their own generated ID.
String resolveScreenRecordingSessionId({
  required String fallbackSessionId,
  String? activeSubtitleSessionId,
  String? activeAudioOnlySessionId,
}) {
  if (activeSubtitleSessionId != null &&
      activeSubtitleSessionId.trim().isNotEmpty) {
    return activeSubtitleSessionId;
  }
  if (activeAudioOnlySessionId != null &&
      activeAudioOnlySessionId.trim().isNotEmpty) {
    return activeAudioOnlySessionId;
  }
  return fallbackSessionId;
}

/// Windows screen recording bridge. System Capture Picker remains the only
/// source of a GraphicsCaptureItem; this adapter does not bypass protected
/// content policies.
final class DesktopScreenRecordingAdapter {
  DesktopScreenRecordingAdapter({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel(
            'com.yixue.yixue_app/ai_tongchuan/screen_recording',
          );

  final MethodChannel _channel;

  Future<void> pickTarget() async {
    _requireWindows();
    await _channel.invokeMethod<void>('pickTarget');
  }

  Future<DesktopScreenRecordingState> getState() async {
    _requireWindows();
    final value = await _channel.invokeMapMethod<Object?, Object?>('getState');
    if (value == null) {
      throw const FormatException('Windows screen recorder returned no state.');
    }
    return DesktopScreenRecordingState.fromMap(value);
  }

  Future<DesktopScreenRecordingState> startRecording({
    required Directory recordingDirectory,
    required String sessionId,
    required bool retainAudio,
    required int? audioTimelineStartQpc100ns,
    required String? audioCaptureAttemptId,
    String? audioSourceId,
  }) async {
    _requireWindows();
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'startRecording',
      <String, Object?>{
        'recordingDirectory': recordingDirectory.absolute.path,
        'sessionId': sessionId,
        'retainAudio': retainAudio,
        if (retainAudio) 'audioSourceId': audioSourceId,
        if (retainAudio) 'audioCaptureAttemptId': audioCaptureAttemptId,
        if (retainAudio)
          'audioTimelineStartQpc100ns': audioTimelineStartQpc100ns,
      },
    );
    if (result == null) {
      throw const FormatException('Windows screen recorder returned no state.');
    }
    return DesktopScreenRecordingState.fromMap(result);
  }

  Future<void> writeAudioFrames(Iterable<AudioFrame> frames) async {
    _requireWindows();
    final values = frames.map(_frameValue).toList(growable: false);
    if (values.isEmpty) return;
    await _channel.invokeMethod<void>('writeAudioFrames', <String, Object?>{
      'frames': values,
    });
  }

  Future<DesktopScreenRecordingState> stopRecording({
    bool preservePartial = false,
    String? failureMessage,
  }) async {
    _requireWindows();
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'stopRecording',
      <String, Object?>{
        'preservePartial': preservePartial,
        if (failureMessage != null && failureMessage.trim().isNotEmpty)
          'failureMessage': failureMessage.trim(),
      },
    );
    if (result == null) {
      throw const FormatException('Windows screen recorder returned no state.');
    }
    return DesktopScreenRecordingState.fromMap(result);
  }

  Map<String, Object?> _frameValue(AudioFrame frame) => <String, Object?>{
    'sessionId': frame.sessionId,
    'captureAttemptId': frame.captureAttemptId,
    'sourceId': frame.sourceId,
    'qpcTime100ns': frame.qpcTime100ns,
    'sampleRateHz': frame.sampleRateHz,
    'channelCount': frame.channelCount,
    'sampleCount': frame.sampleCount,
    'sampleFormat': switch (frame.sampleFormat) {
      AudioPcmSampleFormat.signedInt16LittleEndian => 'signedInt16LittleEndian',
      AudioPcmSampleFormat.float32LittleEndian => 'float32LittleEndian',
    },
    'pcmBytes': Uint8List.fromList(frame.pcmBytes),
  };

  void _requireWindows() {
    if (!Platform.isWindows) {
      throw UnsupportedError('Desktop screen recording is Windows-only.');
    }
  }
}
