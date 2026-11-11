import 'dart:async';

import 'audio_capture_contract.dart';
import 'desktop_audio_capture.dart';

enum ScreenRecordingCleanupStatus { clear, retryable, unconfirmed }

/// Owns one frame-listener cancellation across overlapping stop and disposal
/// paths. Stream cancellation remains observable to the awaited stop path, but
/// only one native cancellation is ever issued.
final class ScreenRecordingAudioFrameSubscriptionLease {
  ScreenRecordingAudioFrameSubscriptionLease(this.subscription);

  final StreamSubscription<AudioFrame> subscription;
  Future<void>? _cancelFuture;

  Future<void> cancel() => _cancelFuture ??= subscription.cancel();
}

ScreenRecordingCleanupStatus resolveScreenRecordingCleanupStatus({
  required bool ownsAudioSource,
  required DesktopAudioCaptureSource? source,
  required String? sessionId,
}) {
  if (!ownsAudioSource && source == null && sessionId == null) {
    return ScreenRecordingCleanupStatus.clear;
  }
  if (ownsAudioSource && source != null && sessionId?.isNotEmpty == true) {
    return ScreenRecordingCleanupStatus.retryable;
  }
  return ScreenRecordingCleanupStatus.unconfirmed;
}

bool canStartAudioCaptureAfterScreenRecordingCleanup(
  ScreenRecordingCleanupStatus cleanupStatus, {
  bool screenRecordingStopInProgress = false,
  bool audioSubscriptionCleanupUnconfirmed = false,
}) =>
    cleanupStatus == ScreenRecordingCleanupStatus.clear &&
    !screenRecordingStopInProgress &&
    !audioSubscriptionCleanupUnconfirmed;

/// A recording is publishable only when its audio writes and audio-source
/// cleanup both completed with confirmed outcomes.
bool screenRecordingMustPreservePartial({
  required bool audioWriteFailed,
  required bool sourceStopFailed,
  required bool audioCleanupFailed,
}) => audioWriteFailed || sourceStopFailed || audioCleanupFailed;

/// Releases app ownership of a Dart stream subscription after its one-shot
/// cancellation attempt, including when the stream's cleanup future fails.
Future<void> cancelScreenRecordingAudioFrameSubscription({
  required ScreenRecordingAudioFrameSubscriptionLease lease,
  required void Function() onCancellationAttemptComplete,
}) async {
  try {
    await lease.cancel();
  } finally {
    onCancellationAttemptComplete();
  }
}

/// Starts best-effort cancellation during widget disposal without leaking an
/// unhandled async error. The awaited recording shutdown still observes and
/// reports the same cancellation failure before finalizing its media file.
Future<void> cancelScreenRecordingAudioFrameSubscriptionForDisposal({
  required ScreenRecordingAudioFrameSubscriptionLease lease,
}) async {
  try {
    await lease.cancel();
  } on Object {
    // The owning shutdown path records the failure and preserves the partial.
  }
}

typedef ScreenRecordingAudioSourceStopper = Future<void> Function({
  required String sourceId,
  required String sessionId,
});

/// Retries cleanup using the original capture identity before a new screen
/// recording can replace it. A failed stop is deliberately propagated so the
/// caller keeps the source/session pair and blocks a second start.
Future<void> retryUnconfirmedScreenRecordingAudioStop({
  required bool ownsAudioSource,
  required DesktopAudioCaptureSource? source,
  required String? sessionId,
  required ScreenRecordingAudioSourceStopper stopSource,
}) async {
  if (!ownsAudioSource) return;
  final sourceId = source?.sourceId;
  final stableSessionId = sessionId;
  if (sourceId == null || sourceId.isEmpty || stableSessionId == null) {
    throw StateError('录屏音源没有关联的采集会话。');
  }
  await stopSource(sourceId: sourceId, sessionId: stableSessionId);
}

/// Releases screen-recording startup when either the first audio frame arrives
/// or the selected audio stream fails before producing a frame.
final class ScreenRecordingAudioStartupGate {
  final Completer<AudioFrame?> _firstFrame = Completer<AudioFrame?>();

  Future<AudioFrame?> get firstFrame => _firstFrame.future;

  bool get isCompleted => _firstFrame.isCompleted;

  void addFrame(AudioFrame frame) {
    if (!_firstFrame.isCompleted) _firstFrame.complete(frame);
  }

  void fail() {
    if (!_firstFrame.isCompleted) _firstFrame.complete(null);
  }
}

/// Returns a user-facing integrity failure when a captured audio frame cannot
/// be joined continuously to the MP4 audio track.
String? screenRecordingAudioFrameFailure(AudioFrame frame) {
  if (frame.hasDiscontinuityBefore) {
    return '录屏音轨检测到丢帧，未完成文件将保留供恢复排查。';
  }
  return null;
}

/// Appends one batch to the same serial writer tail used by shutdown. The
/// returned future completes after either the write or its failure handler,
/// so recorder finalization can safely await the tail before stopping native
/// media resources.
Future<void> enqueueScreenRecordingAudioWrite({
  required Future<void> previous,
  required Future<void> Function() write,
  required void Function(Object error, StackTrace stackTrace) onError,
}) {
  final current = previous.then<void>((_) => write());
  return current.then<void>((_) {}, onError: onError);
}

/// Bounded audio buffering while the native screen recorder is starting.
/// Overflow remains latched until [clear] so a delayed startup cannot miss it.
final class ScreenRecordingAudioPreRoll {
  ScreenRecordingAudioPreRoll({this.maxFrames = 64}) {
    if (maxFrames <= 0) {
      throw ArgumentError.value(maxFrames, 'maxFrames', 'Must be positive.');
    }
  }

  final int maxFrames;
  final List<AudioFrame> _frames = <AudioFrame>[];
  var _hasOverflowed = false;

  bool get hasOverflowed => _hasOverflowed;
  bool get isEmpty => _frames.isEmpty;

  bool add(AudioFrame frame) {
    if (_hasOverflowed || _frames.length >= maxFrames) {
      _hasOverflowed = true;
      return false;
    }
    _frames.add(frame);
    return true;
  }

  List<AudioFrame> takeBatch() {
    final batch = List<AudioFrame>.of(_frames, growable: false);
    _frames.clear();
    return batch;
  }

  void clear() {
    _frames.clear();
    _hasOverflowed = false;
  }
}
