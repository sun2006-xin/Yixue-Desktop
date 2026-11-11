import 'dart:io';

import 'package:flutter/services.dart';

import 'audio_capture_contract.dart';
import 'subtitle_session_contract.dart';

/// A system-output source exposed by the native Windows or macOS runner.
///
/// macOS sources identify a display filter. Windows currently exposes the
/// shared-mode default playback mix as one source.
final class DesktopAudioCaptureSource {
  const DesktopAudioCaptureSource({
    required this.sourceId,
    required this.sourceKind,
    required this.displayName,
    required this.description,
    this.displayIndex,
  });

  factory DesktopAudioCaptureSource.fromMap(Map<Object?, Object?> map) {
    return DesktopAudioCaptureSource(
      sourceId: map['sourceId']! as String,
      sourceKind: SubtitleAudioSourceKind.values.byName(
        map['sourceKind']! as String,
      ),
      displayName: map['displayName']! as String,
      description: map['description']! as String,
      displayIndex: map['displayIndex'] as int?,
    );
  }

  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final String displayName;
  final String description;
  final int? displayIndex;
}

/// Shared Dart adapter for Windows WASAPI and macOS ScreenCaptureKit audio.
///
/// Subscribe to [frames] and [sourceStates] before calling [start]. Resume
/// creates a new capture attempt and receives the active-capture offset, so
/// time spent paused is excluded from the session clock.
final class DesktopAudioCaptureAdapter {
  DesktopAudioCaptureAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ??
           const MethodChannel('com.yixue.yixue_app/ai_tongchuan/audio'),
       _eventChannel =
           eventChannel ??
           const EventChannel('com.yixue.yixue_app/ai_tongchuan/audio_events');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  late final Stream<Map<Object?, Object?>> _events = _eventChannel
      .receiveBroadcastStream()
      .map((event) {
        if (event is! Map) {
          throw FormatException('Unexpected desktop audio event: $event');
        }
        return Map<Object?, Object?>.from(event);
      })
      .asBroadcastStream();

  Stream<AudioFrame> get frames => _events
      .where((event) => event['type'] == 'audioFrame')
      .map(_audioFrameFromEvent);

  Stream<AudioCaptureSourceState> get sourceStates => _events
      .where((event) => event['type'] == 'state')
      .map(_sourceStateFromEvent);

  Future<List<DesktopAudioCaptureSource>> enumerateSources() async {
    _requireDesktop();
    final result = await _methodChannel.invokeMethod<List<dynamic>>(
      'enumerateSources',
    );
    return (result ?? const <dynamic>[])
        .map((value) {
          if (value is! Map) {
            throw FormatException('Unexpected desktop audio source: $value');
          }
          return DesktopAudioCaptureSource.fromMap(
            Map<Object?, Object?>.from(value),
          );
        })
        .toList(growable: false);
  }

  Future<void> start({
    required String sourceId,
    required String sessionId,
    required String captureAttemptId,
    int activeCaptureOffsetUs = 0,
  }) async {
    _requireDesktop();
    await _methodChannel.invokeMethod<void>('start', {
      'sourceId': sourceId,
      'sessionId': sessionId,
      'captureAttemptId': captureAttemptId,
      'activeCaptureOffsetUs': activeCaptureOffsetUs,
    });
  }

  Future<void> startSource({
    required DesktopAudioCaptureSource source,
    required String sessionId,
    required String captureAttemptId,
    int activeCaptureOffsetUs = 0,
  }) async {
    _requireDesktop();
    await _methodChannel.invokeMethod<void>('startSource', {
      'sourceId': source.sourceId,
      'sourceKind': source.sourceKind.name,
      'sessionId': sessionId,
      'captureAttemptId': captureAttemptId,
      'activeCaptureOffsetUs': activeCaptureOffsetUs,
    });
  }

  Future<void> pauseSource({
    required String sourceId,
    required String sessionId,
  }) async {
    _requireDesktop();
    await _methodChannel.invokeMethod<void>('pauseSource', {
      'sourceId': sourceId,
      'sessionId': sessionId,
    });
  }

  Future<void> resumeSource({
    required DesktopAudioCaptureSource source,
    required String sessionId,
    required String captureAttemptId,
    required int activeCaptureOffsetUs,
  }) async {
    _requireDesktop();
    await _methodChannel.invokeMethod<void>('resumeSource', {
      'sourceId': source.sourceId,
      'sourceKind': source.sourceKind.name,
      'sessionId': sessionId,
      'captureAttemptId': captureAttemptId,
      'activeCaptureOffsetUs': activeCaptureOffsetUs,
    });
  }

  Future<void> stopSource({
    required String sourceId,
    required String sessionId,
  }) async {
    _requireDesktop();
    await _methodChannel.invokeMethod<void>('stopSource', {
      'sourceId': sourceId,
      'sessionId': sessionId,
    });
  }

  Future<void> resume({
    required String sourceId,
    required String sessionId,
    required String captureAttemptId,
    required int activeCaptureOffsetUs,
  }) async {
    _requireDesktop();
    await _methodChannel.invokeMethod<void>('resume', {
      'sourceId': sourceId,
      'sessionId': sessionId,
      'captureAttemptId': captureAttemptId,
      'activeCaptureOffsetUs': activeCaptureOffsetUs,
    });
  }

  static AudioFrame _audioFrameFromEvent(Map<Object?, Object?> event) {
    final payload = event['pcmBytes'];
    if (payload is! Uint8List) {
      throw FormatException('Desktop audio frame is missing PCM bytes.');
    }
    return AudioFrame(
      sessionId: event['sessionId']! as String,
      captureAttemptId: event['captureAttemptId']! as String,
      sourceId: event['sourceId']! as String,
      sourceKind: SubtitleAudioSourceKind.values.byName(
        event['sourceKind']! as String,
      ),
      sequence: event['sequence']! as int,
      startTimeUs: event['startTimeUs']! as int,
      qpcTime100ns: event['qpcTime100ns'] as int?,
      sampleRateHz: event['sampleRateHz']! as int,
      channelCount: event['channelCount']! as int,
      channelMask: event['channelMask'] as int?,
      sampleCount: event['sampleCount']! as int,
      sampleFormat: AudioPcmSampleFormat.values.byName(
        event['sampleFormat']! as String,
      ),
      pcmBytes: payload,
      hasDiscontinuityBefore: event['hasDiscontinuityBefore']! as bool,
    );
  }

  static AudioCaptureSourceState _sourceStateFromEvent(
    Map<Object?, Object?> event,
  ) {
    final rawError = event['errorCode'] as String?;
    return AudioCaptureSourceState(
      sourceId: event['sourceId']! as String,
      sourceKind: SubtitleAudioSourceKind.values.byName(
        event['sourceKind']! as String,
      ),
      status: AudioCaptureSourceStatus.values.byName(
        event['status']! as String,
      ),
      sessionId: event['sessionId']! as String,
      captureAttemptId: event['captureAttemptId']! as String,
      errorCode: rawError == null
          ? null
          : AudioCaptureErrorCode.values.byName(rawError),
      sampleRateHz: event['sampleRateHz'] as int?,
      channelCount: event['channelCount'] as int?,
      sampleFormat: (event['sampleFormat'] as String?) == null
          ? null
          : AudioPcmSampleFormat.values.byName(
              event['sampleFormat']! as String,
            ),
      firstFrameSequence: event['firstFrameSequence'] as int?,
      lastFrameSequence: event['lastFrameSequence'] as int?,
      firstFrameTimeUs: event['firstFrameTimeUs'] as int?,
    );
  }

  static void _requireDesktop() {
    if (!Platform.isWindows && !Platform.isMacOS) {
      throw UnsupportedError(
        'DesktopAudioCaptureAdapter supports Windows and macOS only.',
      );
    }
  }
}
