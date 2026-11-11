import 'dart:async';
import 'dart:collection';

import 'subtitle_session_contract.dart';
import 'subtitle_translation_queue.dart';

/// Read-only snapshot of the transcript and translation orchestration state.
final class SubtitleSessionCoordinatorState {
  const SubtitleSessionCoordinatorState({
    required this.sessionId,
    required this.captureAttemptId,
    required this.generation,
    required this.status,
    required this.segments,
    required this.translationQueue,
  });

  final String sessionId;
  final String captureAttemptId;
  final int generation;
  final SubtitleSessionStatus status;
  final List<SubtitleSegment> segments;
  final SubtitleTranslationQueueState translationQueue;

  bool get acceptsTranscriptUpdates =>
      status == SubtitleSessionStatus.capturing ||
      status == SubtitleSessionStatus.paused;
}

/// Owns one session's transcript timeline and connects final revisions to the
/// bounded translation queue.
///
/// The coordinator starts in `preparing`. The capture runtime calls
/// [markCapturing] only after its first valid audio frame has entered the
/// bounded queue. Pause keeps accepting updates from that attempt so an ASR
/// runtime can flush buffered audio. Resume requires a new attempt ID and
/// returns to `preparing`; callbacks from older attempts are ignored. Capture
/// device control and ASR are injected by the later desktop workbench/runtime
/// layers.
final class SubtitleSessionCoordinator {
  SubtitleSessionCoordinator({
    required String sessionId,
    required String initialCaptureAttemptId,
    required this.translationQueue,
    this.translationEnabled = true,
  }) : sessionId = _requireNonEmpty(sessionId, 'sessionId'),
       _captureAttemptId = _requireNonEmpty(
         initialCaptureAttemptId,
         'initialCaptureAttemptId',
       ) {
    if (translationQueue.isClosed) {
      throw StateError('The translation queue is already closed.');
    }
    _usedCaptureAttemptIds.add(_captureAttemptId);
    _translationSubscription = translationQueue.updates.listen(
      _onTranslationUpdate,
    );
    _queueStateSubscription = translationQueue.stateChanges.listen(
      _onQueueStateChange,
    );
  }

  final String sessionId;
  final SubtitleTranslationQueue translationQueue;
  final bool translationEnabled;
  final LinkedHashMap<SubtitleSegmentKey, SubtitleSegment> _segments =
      LinkedHashMap<SubtitleSegmentKey, SubtitleSegment>();
  final Set<String> _usedCaptureAttemptIds = <String>{};
  final StreamController<SubtitleSessionCoordinatorState> _states =
      StreamController<SubtitleSessionCoordinatorState>.broadcast();

  late final StreamSubscription<SubtitleSegment> _translationSubscription;
  late final StreamSubscription<SubtitleTranslationQueueState>
  _queueStateSubscription;
  String _captureAttemptId;
  SubtitleSessionStatus _status = SubtitleSessionStatus.preparing;
  int _generation = 0;
  bool _retryScheduled = false;
  Future<void>? _stopFuture;
  Future<void>? _failFuture;

  Stream<SubtitleSessionCoordinatorState> get stateChanges => _states.stream;
  SubtitleSessionCoordinatorState get currentState =>
      SubtitleSessionCoordinatorState(
        sessionId: sessionId,
        captureAttemptId: _captureAttemptId,
        generation: _generation,
        status: _status,
        segments: _sortedSegments(),
        translationQueue: translationQueue.currentState,
      );

  /// Accepts an ASR revision only for the current session and capture attempt.
  /// Duplicate/older revisions do not enqueue another translation request.
  bool applyTranscriptRevision(TranscriptRevision revision) {
    if (!currentState.acceptsTranscriptUpdates ||
        revision.sessionId != sessionId ||
        revision.captureAttemptId != _captureAttemptId) {
      return false;
    }

    final key = SubtitleSegmentKey(
      sessionId: revision.sessionId,
      captureAttemptId: revision.captureAttemptId,
      segmentId: revision.segmentId,
      sourceId: revision.sourceId,
      sourceKind: revision.sourceKind,
    );
    final previous = _segments[key];
    final next = previous == null
        ? SubtitleSegment.fromTranscript(
            revision,
            translationEnabled: translationEnabled,
          )
        : previous.applyTranscriptRevision(
            revision,
            translationEnabled: translationEnabled,
          );
    if (identical(previous, next)) return false;

    _segments[key] = next;
    if (previous != null && revision.revision > previous.transcript.revision) {
      translationQueue.invalidateOlderRevisions(
        key,
        transcriptRevision: revision.revision,
      );
    }
    _emitState();

    if (next.translationStatus == SubtitleTranslationStatus.awaitingQueue) {
      _enqueue(next);
    }
    return true;
  }

  void pause() {
    if (_status != SubtitleSessionStatus.preparing &&
        _status != SubtitleSessionStatus.capturing) {
      return;
    }
    _status = SubtitleSessionStatus.paused;
    _emitState();
  }

  /// Marks capture active after the first valid frame is accepted into the
  /// bounded native-to-Dart audio queue. Returns false after pause/stop or if
  /// the session has already left the preparing state.
  bool markCapturing() {
    if (_status != SubtitleSessionStatus.preparing) return false;
    _status = SubtitleSessionStatus.capturing;
    _emitState();
    return true;
  }

  /// Explicitly retries a failed or cancelled translation for the current
  /// transcript revision. A queue-full result leaves the segment retryable.
  SubtitleTranslationEnqueueResult retryTranslation(SubtitleSegmentKey key) {
    final segment = _segments[key];
    if (segment == null) {
      throw ArgumentError.value(key, 'key', 'Unknown subtitle segment.');
    }
    if (segment.translationStatus != SubtitleTranslationStatus.failed &&
        segment.translationStatus != SubtitleTranslationStatus.cancelled) {
      return SubtitleTranslationEnqueueResult(
        status: SubtitleTranslationEnqueueStatus.notReady,
        segment: segment,
      );
    }
    return _enqueue(segment);
  }

  /// Cancels the current queued or active translation for [key].
  Future<bool> cancelTranslation(SubtitleSegmentKey key) {
    final requestId = _segments[key]?.translationRequestId;
    if (requestId == null) return Future<bool>.value(false);
    return translationQueue.cancelRequest(requestId);
  }

  /// Resumes the same session under a fresh native/ASR capture attempt ID.
  void resume({required String captureAttemptId}) {
    if (_status != SubtitleSessionStatus.paused) {
      throw StateError('Only a paused subtitle session can resume.');
    }
    final nextAttemptId = _requireNonEmpty(
      captureAttemptId,
      'captureAttemptId',
    );
    if (!_usedCaptureAttemptIds.add(nextAttemptId)) {
      throw ArgumentError.value(
        captureAttemptId,
        'captureAttemptId',
        'Each resumed capture attempt needs a new ID.',
      );
    }
    _captureAttemptId = nextAttemptId;
    _generation += 1;
    _status = SubtitleSessionStatus.preparing;
    _emitState();
  }

  /// Stops transcript intake, cancels session translations, and closes state
  /// streams after the translation executor acknowledges cancellation.
  Future<void> stop() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    if (_status == SubtitleSessionStatus.stopped ||
        _status == SubtitleSessionStatus.failed) {
      return;
    }
    _status = SubtitleSessionStatus.stopping;
    _generation += 1;
    _emitState();

    await translationQueue.close();
    await _translationSubscription.cancel();
    await _queueStateSubscription.cancel();

    _status = SubtitleSessionStatus.stopped;
    _emitState();
    await _states.close();
  }

  /// Marks the session terminal after a capture/ASR failure, then cancels and
  /// drains translation work while preserving the `failed` status for history.
  /// The owner should await this and then close its persistence observer.
  Future<void> fail() => _failFuture ??= _fail();

  Future<void> _fail() async {
    if (_status == SubtitleSessionStatus.failed ||
        _status == SubtitleSessionStatus.stopped) {
      return;
    }
    if (_status == SubtitleSessionStatus.stopping) {
      final stopFuture = _stopFuture;
      if (stopFuture != null) await stopFuture;
      return;
    }
    _status = SubtitleSessionStatus.failed;
    _generation += 1;
    _emitState();

    await translationQueue.close();
    await _translationSubscription.cancel();
    await _queueStateSubscription.cancel();
    await _states.close();
  }

  SubtitleTranslationEnqueueResult _enqueue(SubtitleSegment segment) {
    final result = translationQueue.enqueue(segment);
    if (result.accepted ||
        result.status == SubtitleTranslationEnqueueStatus.duplicate ||
        result.status == SubtitleTranslationEnqueueStatus.sameLanguageSkipped) {
      _segments[segment.key] = result.segment;
      _emitState();
    }
    return result;
  }

  void _onTranslationUpdate(SubtitleSegment update) {
    if (_status == SubtitleSessionStatus.stopped ||
        _status == SubtitleSessionStatus.failed) {
      return;
    }
    final current = _segments[update.key];
    if (current == null ||
        current.transcript.revision != update.transcript.revision ||
        current.translationRequestId != update.translationRequestId) {
      return;
    }
    _segments[update.key] = update;
    _emitState();
    _scheduleRetry();
  }

  void _onQueueStateChange(SubtitleTranslationQueueState _) {
    if (_status == SubtitleSessionStatus.stopped ||
        _status == SubtitleSessionStatus.failed) {
      return;
    }
    _emitState();
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_retryScheduled ||
        _status == SubtitleSessionStatus.stopping ||
        _status == SubtitleSessionStatus.stopped ||
        _status == SubtitleSessionStatus.failed ||
        !translationQueue.currentState.hasCapacity ||
        !_segments.values.any(
          (segment) =>
              segment.translationStatus ==
              SubtitleTranslationStatus.awaitingQueue,
        )) {
      return;
    }
    _retryScheduled = true;
    scheduleMicrotask(() {
      _retryScheduled = false;
      _retryAwaitingSegments();
    });
  }

  void _retryAwaitingSegments() {
    if (_status == SubtitleSessionStatus.stopping ||
        _status == SubtitleSessionStatus.stopped ||
        _status == SubtitleSessionStatus.failed) {
      return;
    }
    final awaiting = _sortedSegments()
        .where(
          (segment) =>
              segment.translationStatus ==
              SubtitleTranslationStatus.awaitingQueue,
        )
        .toList(growable: false);
    for (final segment in awaiting) {
      if (!translationQueue.currentState.hasCapacity) break;
      final current = _segments[segment.key];
      if (current == null ||
          current.transcript.revision != segment.transcript.revision ||
          current.translationStatus !=
              SubtitleTranslationStatus.awaitingQueue) {
        continue;
      }
      _enqueue(current);
    }
  }

  List<SubtitleSegment> _sortedSegments() {
    final result = _segments.values.toList(growable: false);
    result.sort((left, right) {
      final timeOrder = left.transcript.startMs.compareTo(
        right.transcript.startMs,
      );
      if (timeOrder != 0) return timeOrder;
      final endOrder = left.transcript.endMs.compareTo(right.transcript.endMs);
      if (endOrder != 0) return endOrder;
      return left.transcript.segmentId.compareTo(right.transcript.segmentId);
    });
    return List<SubtitleSegment>.unmodifiable(result);
  }

  void _emitState() {
    if (!_states.isClosed) _states.add(currentState);
  }
}

String _requireNonEmpty(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
  return value;
}
