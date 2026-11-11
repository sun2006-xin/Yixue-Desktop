import 'dart:typed_data';

import 'subtitle_session_contract.dart';

/// Observable state for one requested capture source.
///
/// `active` must not be reported until the first valid frame is accepted by
/// the bounded native-to-Dart event queue. Session lifecycle state or a PCM
/// callback alone is not evidence that the frame crossed the capture bridge.
enum AudioCaptureSourceStatus {
  notRequested,
  requestingAccess,
  ready,
  waitingForFirstFrame,
  active,
  noSignal,
  paused,
  permissionDenied,
  deviceUnavailable,
  deviceDisconnected,
  stopped,
  failed,
}

/// Stable capture failure categories for UI and diagnostics.
enum AudioCaptureErrorCode {
  accessDenied,
  unsupportedMode,
  deviceUnavailable,
  deviceDisconnected,
  noSignal,
  unsupportedFormat,
  nativeInitializationFailed,
  streamFailure,
  unknown,
}

/// Audio format carried by [AudioFrame]. Samples are little-endian and
/// interleaved by channel.
enum AudioPcmSampleFormat {
  signedInt16LittleEndian(2),
  float32LittleEndian(4);

  const AudioPcmSampleFormat(this.bytesPerSample);

  final int bytesPerSample;
}

/// State for one distinct system, application, or microphone source.
final class AudioCaptureSourceState {
  AudioCaptureSourceState({
    required this.sourceId,
    required this.sourceKind,
    required this.status,
    this.sessionId,
    this.captureAttemptId,
    this.errorCode,
    this.sampleRateHz,
    this.channelCount,
    this.sampleFormat,
    this.firstFrameSequence,
    this.lastFrameSequence,
    this.firstFrameTimeUs,
  }) {
    if (sourceId.trim().isEmpty) {
      throw ArgumentError.value(sourceId, 'sourceId', 'Must not be empty.');
    }
    if (sessionId != null && sessionId!.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Must not be empty.');
    }
    if (captureAttemptId != null && captureAttemptId!.trim().isEmpty) {
      throw ArgumentError.value(
        captureAttemptId,
        'captureAttemptId',
        'Must not be empty.',
      );
    }
    final needsCaptureIdentity =
        status != AudioCaptureSourceStatus.notRequested &&
        status != AudioCaptureSourceStatus.ready;
    if (needsCaptureIdentity &&
        (sessionId == null || captureAttemptId == null)) {
      throw ArgumentError(
        'A runtime capture state needs session and attempt identity.',
      );
    }
    if (status == AudioCaptureSourceStatus.failed && errorCode == null) {
      throw ArgumentError('A failed source needs a stable error code.');
    }
    if (sampleRateHz != null && sampleRateHz! <= 0) {
      throw ArgumentError.value(
        sampleRateHz,
        'sampleRateHz',
        'Must be positive when provided.',
      );
    }
    if (channelCount != null && channelCount! <= 0) {
      throw ArgumentError.value(
        channelCount,
        'channelCount',
        'Must be positive when provided.',
      );
    }
    if (lastFrameSequence != null && lastFrameSequence! < 0) {
      throw ArgumentError.value(
        lastFrameSequence,
        'lastFrameSequence',
        'Must be non-negative when provided.',
      );
    }
    if (firstFrameSequence != null && firstFrameSequence! < 0) {
      throw ArgumentError.value(
        firstFrameSequence,
        'firstFrameSequence',
        'Must be non-negative when provided.',
      );
    }
    if (firstFrameTimeUs != null && firstFrameTimeUs! < 0) {
      throw ArgumentError.value(
        firstFrameTimeUs,
        'firstFrameTimeUs',
        'Must be non-negative when provided.',
      );
    }
    if (firstFrameSequence != null &&
        lastFrameSequence != null &&
        lastFrameSequence! < firstFrameSequence!) {
      throw ArgumentError(
        'lastFrameSequence must not precede the first frame.',
      );
    }
    if (status == AudioCaptureSourceStatus.active &&
        (sessionId == null ||
            captureAttemptId == null ||
            sampleRateHz == null ||
            channelCount == null ||
            sampleFormat == null ||
            firstFrameSequence == null ||
            lastFrameSequence == null ||
            firstFrameTimeUs == null)) {
      throw ArgumentError(
        'An active source needs capture identity and validated first-frame metadata.',
      );
    }
  }

  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final AudioCaptureSourceStatus status;
  final String? sessionId;
  final String? captureAttemptId;
  final AudioCaptureErrorCode? errorCode;
  final int? sampleRateHz;
  final int? channelCount;
  final AudioPcmSampleFormat? sampleFormat;
  final int? firstFrameSequence;
  final int? lastFrameSequence;
  final int? firstFrameTimeUs;
}

/// One owned copy of interleaved PCM audio from a single capture attempt.
///
/// [sampleCount] is the number of samples per channel. [startTimeUs] is the
/// frame's start on the session's active-capture monotonic clock; the clock
/// advances only while capture is active, so paused time is excluded. Native
/// adapters should emit bounded chunks and increasing [sequence] values.
/// A sequence gap or [hasDiscontinuityBefore] signals dropped/discontinuous
/// audio. This payload is transient and must not be persisted by default.
/// Consumers must treat [pcmBytes] as read-only; copy it before in-place work.
final class AudioFrame {
  static const maxFrameDurationUs = 100000;
  static const maxPcmBytes = 256 * 1024;
  static const maxSampleRateHz = 384000;
  static const maxChannelCount = 32;

  AudioFrame({
    required this.sessionId,
    required this.captureAttemptId,
    required this.sourceId,
    required this.sourceKind,
    required this.sequence,
    required this.startTimeUs,
    this.qpcTime100ns,
    required this.sampleRateHz,
    required this.channelCount,
    this.channelMask,
    required this.sampleCount,
    required this.sampleFormat,
    required Uint8List pcmBytes,
    this.hasDiscontinuityBefore = false,
  }) {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Must not be empty.');
    }
    if (captureAttemptId.trim().isEmpty) {
      throw ArgumentError.value(
        captureAttemptId,
        'captureAttemptId',
        'Must not be empty.',
      );
    }
    if (sourceId.trim().isEmpty) {
      throw ArgumentError.value(sourceId, 'sourceId', 'Must not be empty.');
    }
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence', 'Must be non-negative.');
    }
    if (startTimeUs < 0) {
      throw ArgumentError.value(
        startTimeUs,
        'startTimeUs',
        'Must be non-negative.',
      );
    }
    if (qpcTime100ns != null && qpcTime100ns! < 0) {
      throw ArgumentError.value(
        qpcTime100ns,
        'qpcTime100ns',
        'Must be non-negative when provided.',
      );
    }
    if (sampleRateHz <= 0 ||
        sampleRateHz > maxSampleRateHz ||
        channelCount <= 0 ||
        channelCount > maxChannelCount ||
        (channelMask != null &&
            (channelMask! < 0 || channelMask! > 0xffffffff)) ||
        sampleCount <= 0) {
      throw ArgumentError(
        'Sample rate, channel count, or sample count is outside supported bounds.',
      );
    }

    final maxSamplesPerChannel =
        maxFrameDurationUs * sampleRateHz ~/ Duration.microsecondsPerSecond;
    if (sampleCount > maxSamplesPerChannel) {
      throw ArgumentError.value(
        sampleCount,
        'sampleCount',
        'Frame duration exceeds $maxFrameDurationUs microseconds.',
      );
    }

    final expectedLength =
        sampleCount * channelCount * sampleFormat.bytesPerSample;
    if (expectedLength > maxPcmBytes) {
      throw ArgumentError.value(
        expectedLength,
        'pcmBytes.length',
        'Frame payload exceeds the $maxPcmBytes byte limit.',
      );
    }
    if (pcmBytes.length != expectedLength) {
      throw ArgumentError.value(
        pcmBytes.length,
        'pcmBytes.length',
        'Must match sampleCount * channelCount * bytes per sample.',
      );
    }
    this.pcmBytes = Uint8List.fromList(pcmBytes);
  }

  final String sessionId;
  final String captureAttemptId;
  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final int sequence;
  final int startTimeUs;

  /// Absolute Windows QPC timestamp in 100 ns units when the native source can
  /// provide a reliable system clock. Other platforms and timestamp-error
  /// packets may leave this unset. This is used only to align Windows media.
  final int? qpcTime100ns;
  final int sampleRateHz;
  final int channelCount;

  /// Windows speaker-position bit mask for multichannel PCM, when available.
  /// Other capture providers may omit this when the channel layout is unknown.
  final int? channelMask;

  final int sampleCount;
  final AudioPcmSampleFormat sampleFormat;
  late final Uint8List pcmBytes;
  final bool hasDiscontinuityBefore;

  int get durationUs =>
      sampleCount * Duration.microsecondsPerSecond ~/ sampleRateHz;
}

/// Returns whether [frame] belongs to the currently active capture attempt.
/// A source may be paused and resumed inside one session, so session/source
/// identity alone cannot distinguish delayed frames from the old attempt.
bool audioFrameMatchesCaptureIdentity(
  AudioFrame frame, {
  required String sessionId,
  required String captureAttemptId,
  required String sourceId,
  required SubtitleAudioSourceKind sourceKind,
}) =>
    frame.sessionId == sessionId &&
    frame.captureAttemptId == captureAttemptId &&
    frame.sourceId == sourceId &&
    frame.sourceKind == sourceKind;
