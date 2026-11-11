import 'dart:async';
import 'dart:collection';

import 'package:yixue_app/core/quick_translation_service.dart';

import 'asr_language_registry.dart';
import 'subtitle_session_contract.dart';

/// Executes one confirmed subtitle translation request.
///
/// An executor should preserve the configured provider route. It must not
/// silently switch between local and remote providers.
abstract interface class SubtitleTranslationExecutor {
  Future<String> translate(SubtitleTranslationRequest request);

  /// Cancels only [requestId], leaving unrelated quick translations alone.
  Future<void> cancel(String requestId);
}

/// Optional startup hook for local executors that need to load a model before
/// the first real subtitle arrives. Remote executors must not send a synthetic
/// request during preparation.
abstract interface class SubtitleTranslationPreparer {
  Future<void> prepareForDirection({
    required String sourceLanguageCode,
    required String targetLanguageCode,
  });
}

/// Reuses the app's configured translation provider without adding one history
/// row per subtitle. Pass a service instance owned by the subtitle session.
final class QuickTranslationSubtitleExecutor
    implements SubtitleTranslationExecutor, SubtitleTranslationPreparer {
  QuickTranslationSubtitleExecutor(
    this.service, {
    Future<Map<TranslationDirection, SubtitleTranslationRouteSnapshot>>?
    routeSnapshots,
  }) : _routeSnapshots = routeSnapshots ?? service.snapshotSubtitleRoutes();

  final QuickTranslationService service;
  final Future<Map<TranslationDirection, SubtitleTranslationRouteSnapshot>>
  _routeSnapshots;
  String? _activeRequestId;
  bool _cancelRequested = false;

  @override
  Future<void> prepareForDirection({
    required String sourceLanguageCode,
    required String targetLanguageCode,
  }) async {
    final direction = _directionFor(sourceLanguageCode, targetLanguageCode);
    final routeSnapshots = await _routeSnapshots;
    final routeSnapshot = routeSnapshots[direction];
    if (routeSnapshot == null ||
        (routeSnapshot.kind != SubtitleTranslationRouteKind.bundledLocal &&
            routeSnapshot.kind != SubtitleTranslationRouteKind.localProfile)) {
      return;
    }
    if (_activeRequestId != null) {
      throw const SubtitleTranslationFailure('translation_in_progress');
    }

    final requestId =
        'subtitle-warmup-${DateTime.now().microsecondsSinceEpoch}';
    _activeRequestId = requestId;
    _cancelRequested = false;
    try {
      await service.translateSubtitle(
        _warmupTextFor(sourceLanguageCode),
        requestId: requestId,
        direction: direction,
        routeSnapshot: routeSnapshot,
      );
    } on QuickTranslationException catch (error) {
      throw SubtitleTranslationFailure(error.code);
    } finally {
      if (_activeRequestId == requestId) {
        _activeRequestId = null;
        _cancelRequested = false;
      }
    }
  }

  String _warmupTextFor(String sourceLanguageCode) =>
      switch (AsrLanguageRegistry.normalizeCode(sourceLanguageCode)) {
        'zh' => '你好。',
        'ja' => 'こんにちは。',
        'ko' => '안녕하세요.',
        'es' => 'Hola.',
        'fr' => 'Bonjour.',
        'de' => 'Hallo.',
        'pt' => 'Olá.',
        'ru' => 'Привет.',
        _ => 'Hello.',
      };

  @override
  Future<String> translate(SubtitleTranslationRequest request) async {
    final direction = _directionFor(
      request.sourceLanguageCode,
      request.targetLanguageCode,
    );
    if (_activeRequestId != null) {
      throw const SubtitleTranslationFailure('translation_in_progress');
    }
    _activeRequestId = request.requestId;
    _cancelRequested = false;
    try {
      final routeSnapshots = await _routeSnapshots;
      if (_cancelRequested) {
        throw const SubtitleTranslationFailure('cancelled');
      }
      final routeSnapshot = routeSnapshots[direction];
      if (routeSnapshot == null ||
          routeSnapshot.kind == SubtitleTranslationRouteKind.unavailable) {
        throw const SubtitleTranslationFailure('translation_route_unavailable');
      }
      return await service.translateSubtitle(
        request.text,
        requestId: request.requestId,
        direction: direction,
        routeSnapshot: routeSnapshot,
      );
    } on QuickTranslationException catch (error) {
      throw SubtitleTranslationFailure(error.code);
    } finally {
      if (_activeRequestId == request.requestId) {
        _activeRequestId = null;
        _cancelRequested = false;
      }
    }
  }

  @override
  Future<void> cancel(String requestId) async {
    if (_activeRequestId != requestId) return;
    _cancelRequested = true;
    await service.cancelTranslation(requestId);
  }

  static TranslationDirection _directionFor(String source, String target) {
    final direction = TranslationDirection.fromLanguageCodes(source, target);
    if (direction == null) {
      throw const SubtitleTranslationFailure('unsupported_language_pair');
    }
    return direction;
  }
}

final class SubtitleTranslationFailure implements Exception {
  const SubtitleTranslationFailure(this.code);

  final String code;

  @override
  String toString() => 'SubtitleTranslationFailure($code)';
}

enum SubtitleTranslationEnqueueStatus {
  accepted,
  duplicate,
  queueFull,
  closed,
  notReady,
  sameLanguageSkipped,
}

final class SubtitleTranslationEnqueueResult {
  const SubtitleTranslationEnqueueResult({
    required this.status,
    required this.segment,
  });

  final SubtitleTranslationEnqueueStatus status;
  final SubtitleSegment segment;

  bool get accepted => status == SubtitleTranslationEnqueueStatus.accepted;
}

/// Snapshot of the bounded translation queue for status UI and backpressure.
final class SubtitleTranslationQueueState {
  const SubtitleTranslationQueueState({
    required this.pendingCount,
    required this.maxPending,
    required this.activeRequestId,
    required this.activeRequestCancelled,
    required this.isClosed,
  });

  final int pendingCount;
  final int maxPending;
  final String? activeRequestId;
  final bool activeRequestCancelled;
  final bool isClosed;

  bool get hasCapacity => !isClosed && pendingCount < maxPending;
}

/// Serial, bounded queue for finalized subtitle revisions.
///
/// The owner keeps the timeline segments. If [enqueue] reports `queueFull`,
/// the owner retains that segment in `awaitingQueue` and retries after a
/// [stateChanges] update reports capacity. Pending translation work is capped;
/// one active request may run at a time because the configured translation
/// service is single-flight.
final class SubtitleTranslationQueue {
  SubtitleTranslationQueue({
    required this.executor,
    required this.targetLanguageCode,
    this.maxPending = 32,
    String Function()? requestIdFactory,
  }) : _requestIdFactory = requestIdFactory ?? _nextRequestId {
    if (maxPending <= 0) {
      throw ArgumentError.value(maxPending, 'maxPending', 'Must be positive.');
    }
    if (targetLanguageCode.trim().isEmpty) {
      throw ArgumentError.value(
        targetLanguageCode,
        'targetLanguageCode',
        'Must not be empty.',
      );
    }
  }

  final SubtitleTranslationExecutor executor;
  final String targetLanguageCode;
  final int maxPending;
  final String Function() _requestIdFactory;
  final Queue<_SubtitleTranslationJob> _pending =
      Queue<_SubtitleTranslationJob>();
  final StreamController<SubtitleSegment> _updates =
      StreamController<SubtitleSegment>.broadcast();
  final StreamController<SubtitleTranslationQueueState> _stateChanges =
      StreamController<SubtitleTranslationQueueState>.broadcast();

  _SubtitleTranslationJob? _active;
  bool _pumpScheduled = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  Stream<SubtitleSegment> get updates => _updates.stream;
  Stream<SubtitleTranslationQueueState> get stateChanges =>
      _stateChanges.stream;
  int get pendingCount => _pending.length;
  String? get activeRequestId => _active?.request.requestId;
  bool get isClosed => _closed;
  SubtitleTranslationQueueState get currentState =>
      SubtitleTranslationQueueState(
        pendingCount: _pending.length,
        maxPending: maxPending,
        activeRequestId: _active?.request.requestId,
        activeRequestCancelled: _active != null && !_active!.valid,
        isClosed: _closed,
      );

  SubtitleTranslationEnqueueResult enqueue(SubtitleSegment segment) {
    if (_closed) {
      return SubtitleTranslationEnqueueResult(
        status: SubtitleTranslationEnqueueStatus.closed,
        segment: segment,
      );
    }
    if (!segment.canTranslate ||
        (segment.translationStatus != SubtitleTranslationStatus.awaitingQueue &&
            segment.translationStatus != SubtitleTranslationStatus.failed &&
            segment.translationStatus != SubtitleTranslationStatus.cancelled)) {
      return SubtitleTranslationEnqueueResult(
        status: SubtitleTranslationEnqueueStatus.notReady,
        segment: segment,
      );
    }
    final sourceLanguageCode = AsrLanguageRegistry.normalizeCode(
      segment.transcript.languageCode,
    );
    final normalizedTargetLanguageCode = AsrLanguageRegistry.normalizeCode(
      targetLanguageCode,
    );
    if (sourceLanguageCode != null &&
        sourceLanguageCode == normalizedTargetLanguageCode) {
      return SubtitleTranslationEnqueueResult(
        status: SubtitleTranslationEnqueueStatus.sameLanguageSkipped,
        segment: segment.skipTranslationSameLanguage(),
      );
    }
    final existingJob = _findActiveOrPending(
      segment.key,
      segment.transcript.revision,
    );
    if (existingJob != null) {
      return SubtitleTranslationEnqueueResult(
        status: SubtitleTranslationEnqueueStatus.duplicate,
        segment: existingJob.segment,
      );
    }
    if (_pending.length >= maxPending) {
      return SubtitleTranslationEnqueueResult(
        status: SubtitleTranslationEnqueueStatus.queueFull,
        segment: segment,
      );
    }

    final requestId = _requestIdFactory();
    if (requestId.trim().isEmpty || _requestIdIsInFlight(requestId)) {
      throw StateError(
        'Translation request IDs must be non-empty and unique while in flight.',
      );
    }
    final transcript = segment.transcript;
    final request = SubtitleTranslationRequest(
      requestId: requestId,
      sessionId: transcript.sessionId,
      captureAttemptId: transcript.captureAttemptId,
      segmentId: transcript.segmentId,
      transcriptRevision: transcript.revision,
      text: transcript.text,
      sourceLanguageCode: transcript.languageCode,
      targetLanguageCode: targetLanguageCode,
    );
    final queuedSegment = segment.markQueued(request);
    _pending.add(_SubtitleTranslationJob(request, queuedSegment));
    _updates.add(queuedSegment);
    _emitState();
    _schedulePump();
    return SubtitleTranslationEnqueueResult(
      status: SubtitleTranslationEnqueueStatus.accepted,
      segment: queuedSegment,
    );
  }

  /// Invalidates older requests when ASR revises the same timeline segment.
  /// The caller should store the newer [TranscriptRevision] before applying
  /// queue updates so stale revisions are rejected by its segment map.
  void invalidateOlderRevisions(
    SubtitleSegmentKey key, {
    required int transcriptRevision,
  }) {
    if (transcriptRevision < 0) {
      throw ArgumentError.value(
        transcriptRevision,
        'transcriptRevision',
        'Must be non-negative.',
      );
    }
    for (final job in _pending.toList(growable: false)) {
      if (job.segment.key == key &&
          job.request.transcriptRevision < transcriptRevision) {
        _pending.remove(job);
        job.valid = false;
        _updates.add(
          job.segment.cancelTranslation(requestId: job.request.requestId),
        );
      }
    }
    final active = _active;
    if (active != null &&
        active.segment.key == key &&
        active.request.transcriptRevision < transcriptRevision) {
      unawaited(_cancelActiveJob(active));
    }
    _emitState();
    _schedulePump();
  }

  /// Explicitly cancels one queued or active request.
  Future<bool> cancelRequest(String requestId) async {
    for (final job in _pending.toList(growable: false)) {
      if (job.request.requestId == requestId) {
        _pending.remove(job);
        job.valid = false;
        _updates.add(job.segment.cancelTranslation(requestId: requestId));
        _emitState();
        _schedulePump();
        return true;
      }
    }
    final active = _active;
    if (active == null || active.request.requestId != requestId) return false;
    await _cancelActiveJob(active);
    await active.completion;
    return true;
  }

  /// Cancels pending work and invalidates results from the active request.
  /// The active executor acknowledges cancellation asynchronously. The queue
  /// waits for the translation future to unwind before closing its streams, so
  /// a session owner can use `close()` as a drain barrier before disposing the
  /// session-owned translation service.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    for (final job in _pending.toList(growable: false)) {
      job.valid = false;
      _updates.add(
        job.segment.cancelTranslation(requestId: job.request.requestId),
      );
    }
    _pending.clear();
    final active = _active;
    if (active != null) {
      await _cancelActiveJob(active);
      await active.completion;
    }
    _emitState();
    await _updates.close();
    await _stateChanges.close();
  }

  void _schedulePump() {
    if (_closed || _active != null || _pumpScheduled || _pending.isEmpty) {
      return;
    }
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  void _pump() {
    if (_closed || _active != null) return;
    while (_pending.isNotEmpty) {
      final job = _pending.removeFirst();
      if (!job.valid) continue;
      final translating = job.segment.markTranslating(job.request);
      job.segment = translating;
      _active = job;
      _updates.add(translating);
      _emitState();
      final completion = _run(job);
      job.completion = completion;
      unawaited(completion);
      return;
    }
    _emitState();
  }

  Future<void> _run(_SubtitleTranslationJob job) async {
    try {
      final translatedText = await executor.translate(job.request);
      if (!_isCurrent(job)) return;
      final result = SubtitleTranslationResult(
        requestId: job.request.requestId,
        sessionId: job.request.sessionId,
        captureAttemptId: job.request.captureAttemptId,
        segmentId: job.request.segmentId,
        transcriptRevision: job.request.transcriptRevision,
        sourceLanguageCode: job.request.sourceLanguageCode,
        targetLanguageCode: job.request.targetLanguageCode,
        translatedText: translatedText,
      );
      job.segment = job.segment.applyTranslationResult(result);
      if (job.segment.translationStatus ==
          SubtitleTranslationStatus.translated) {
        _updates.add(job.segment);
      }
    } on SubtitleTranslationFailure catch (error) {
      _emitFailure(job, error.code);
    } catch (_) {
      _emitFailure(job, 'translation_failed');
    } finally {
      job.finished = true;
      if (identical(_active, job)) {
        _active = null;
        _emitState();
        _schedulePump();
      }
    }
  }

  void _emitFailure(_SubtitleTranslationJob job, String errorCode) {
    if (!_isCurrent(job)) return;
    final result = SubtitleTranslationResult(
      requestId: job.request.requestId,
      sessionId: job.request.sessionId,
      captureAttemptId: job.request.captureAttemptId,
      segmentId: job.request.segmentId,
      transcriptRevision: job.request.transcriptRevision,
      sourceLanguageCode: job.request.sourceLanguageCode,
      targetLanguageCode: job.request.targetLanguageCode,
      errorCode: errorCode.trim().isEmpty ? 'translation_failed' : errorCode,
    );
    job.segment = job.segment.applyTranslationResult(result);
    if (job.segment.translationStatus == SubtitleTranslationStatus.failed) {
      _updates.add(job.segment);
    }
  }

  bool _isCurrent(_SubtitleTranslationJob job) =>
      !_closed && job.valid && identical(_active, job);

  Future<void> _cancelActiveJob(_SubtitleTranslationJob job) async {
    if (job.finished) return;
    final pendingCancellation = job.cancelFuture;
    if (pendingCancellation != null) {
      await pendingCancellation;
      return;
    }
    if (!job.valid) return;
    job.valid = false;
    if (!_updates.isClosed) {
      _updates.add(
        job.segment.cancelTranslation(requestId: job.request.requestId),
      );
    }
    _emitState();
    final cancellation = _cancelExecutor(job.request.requestId);
    job.cancelFuture = cancellation;
    await cancellation;
  }

  Future<void> _cancelExecutor(String requestId) async {
    try {
      await executor.cancel(requestId);
    } catch (_) {
      // The request is already invalidated; a failed native/network cancel
      // cannot make its late result valid again.
    }
  }

  _SubtitleTranslationJob? _findActiveOrPending(
    SubtitleSegmentKey key,
    int revision,
  ) {
    final active = _active;
    if (active != null &&
        active.valid &&
        active.segment.key == key &&
        active.request.transcriptRevision == revision) {
      return active;
    }
    for (final job in _pending) {
      if (job.valid &&
          job.segment.key == key &&
          job.request.transcriptRevision == revision) {
        return job;
      }
    }
    return null;
  }

  bool _requestIdIsInFlight(String requestId) {
    if (_active?.request.requestId == requestId) return true;
    return _pending.any((job) => job.request.requestId == requestId);
  }

  void _emitState() {
    if (_stateChanges.isClosed) return;
    _stateChanges.add(currentState);
  }

  static int _globalRequestSequence = 0;

  static String _nextRequestId() {
    _globalRequestSequence += 1;
    return 'subtitle-${DateTime.now().microsecondsSinceEpoch}-'
        '$_globalRequestSequence';
  }
}

final class _SubtitleTranslationJob {
  _SubtitleTranslationJob(this.request, this.segment);

  final SubtitleTranslationRequest request;
  SubtitleSegment segment;
  bool valid = true;
  bool finished = false;
  Future<void>? cancelFuture;
  Future<void>? completion;
}
