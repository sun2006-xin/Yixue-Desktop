import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart' show PlatformException;

import 'audio_capture_contract.dart';
import 'desktop_audio_capture.dart';
import 'streaming_asr.dart';
import 'subtitle_session_contract.dart';
import 'subtitle_session_coordinator.dart';
import 'subtitle_session_persistence.dart';
import 'subtitle_session_store.dart';
import 'subtitle_translation_queue.dart';

/// Inputs selected by the workbench before a live session starts.
final class LiveSubtitleSessionStartRequest {
  LiveSubtitleSessionStartRequest({
    required this.sessionId,
    required this.initialCaptureAttemptId,
    required this.source,
    Iterable<DesktopAudioCaptureSource> additionalSources =
        const <DesktopAudioCaptureSource>[],
    required this.kind,
    required this.sourceLanguageCode,
    required this.targetLanguageCode,
    this.translationEnabled = true,
    this.startedAtUtc,
    this.activeCaptureOffsetUs = 0,
  }) : recognitionMode = sourceLanguageCode.trim().toLowerCase() == 'auto'
           ? SubtitleRecognitionMode.auto
           : SubtitleRecognitionMode.manual,
       additionalSources = List<DesktopAudioCaptureSource>.unmodifiable(
         _normalizeAdditionalSources(source, additionalSources),
       ) {
    if (sessionId.trim().isEmpty ||
        initialCaptureAttemptId.trim().isEmpty ||
        sourceLanguageCode.trim().isEmpty ||
        targetLanguageCode.trim().isEmpty) {
      throw ArgumentError('Session identity and languages are required.');
    }
    if (activeCaptureOffsetUs < 0) {
      throw ArgumentError.value(
        activeCaptureOffsetUs,
        'activeCaptureOffsetUs',
        'Must be non-negative.',
      );
    }
  }

  final String sessionId;
  final String initialCaptureAttemptId;
  final DesktopAudioCaptureSource source;
  final List<DesktopAudioCaptureSource> additionalSources;

  List<DesktopAudioCaptureSource> get sources =>
      List<DesktopAudioCaptureSource>.unmodifiable([
        source,
        ...additionalSources,
      ]);
  final SubtitleSessionKind kind;
  final String sourceLanguageCode;
  final String targetLanguageCode;
  final SubtitleRecognitionMode recognitionMode;
  final bool translationEnabled;
  final DateTime? startedAtUtc;
  final int activeCaptureOffsetUs;
}

/// Snapshot of the five independently visible live-session state layers.
final class LiveSubtitleSessionState {
  const LiveSubtitleSessionState({
    required this.coordinator,
    required this.source,
    required this.sourceStates,
    required this.asr,
    required this.asrStates,
    required this.translationQueue,
    required this.persistence,
    required this.errorCodes,
  });

  final SubtitleSessionCoordinatorState? coordinator;
  final AudioCaptureSourceState? source;
  final List<AudioCaptureSourceState> sourceStates;
  final StreamingAsrState? asr;
  final Map<String, StreamingAsrState> asrStates;
  final SubtitleTranslationQueueState? translationQueue;
  final SubtitleSessionSaveState? persistence;

  /// Stable application error codes accumulated during this owner's lifetime.
  final List<String> errorCodes;

  String? get errorCode => errorCodes.isEmpty ? null : errorCodes.last;
}

/// Stable failure exposed by an imperative session operation.
///
/// Platform, runtime, and filesystem exception messages are intentionally not
/// copied into the UI-facing API. The corresponding stable code is available
/// here and in [LiveSubtitleSessionState.errorCodes].
final class LiveSubtitleSessionException implements Exception {
  const LiveSubtitleSessionException(this.code);

  final String code;

  @override
  String toString() => 'LiveSubtitleSessionException($code)';
}

/// Owns capture, local streaming recognition, translation, and persistence for
/// one live subtitle session. This class has no Flutter widget dependencies.
final class LiveSubtitleSession {
  LiveSubtitleSession({
    required DesktopAudioCaptureAdapter capture,
    required StreamingAsrRuntime asrRuntime,
    required SubtitleSessionStore store,
    required SubtitleTranslationExecutor translationExecutor,
    this.onCaptureAttemptChanged,
    this.maxPendingTranslations = 32,
    this.asrOpenTimeout = const Duration(seconds: 75),
    this.asrReadyTimeout = const Duration(seconds: 15),
  }) : _capture = capture,
       _asrRuntime = asrRuntime,
       _store = store,
       _translationExecutor = translationExecutor {
    if (maxPendingTranslations <= 0) {
      throw ArgumentError.value(
        maxPendingTranslations,
        'maxPendingTranslations',
        'Must be positive.',
      );
    }
    if (asrOpenTimeout <= Duration.zero) {
      throw ArgumentError.value(
        asrOpenTimeout,
        'asrOpenTimeout',
        'Must be positive.',
      );
    }
    if (asrReadyTimeout <= Duration.zero) {
      throw ArgumentError.value(
        asrReadyTimeout,
        'asrReadyTimeout',
        'Must be positive.',
      );
    }
  }

  static final Random _secureRandom = Random.secure();

  final DesktopAudioCaptureAdapter _capture;
  final StreamingAsrRuntime _asrRuntime;
  final SubtitleSessionStore _store;
  final SubtitleTranslationExecutor _translationExecutor;
  final void Function(String? captureAttemptId)? onCaptureAttemptChanged;
  final int maxPendingTranslations;
  final Duration asrOpenTimeout;
  final Duration asrReadyTimeout;
  final StreamController<LiveSubtitleSessionState> _states =
      StreamController<LiveSubtitleSessionState>.broadcast();
  final List<String> _errorCodes = <String>[];

  SubtitleTranslationQueue? _translationQueue;
  SubtitleSessionCoordinator? _coordinator;
  SubtitleSessionPersistence? _persistence;
  final Map<String, StreamingAsrSession> _asrBySource =
      <String, StreamingAsrSession>{};
  // Native capture is keyed by sourceId. Keep every attempted source tied to
  // this session so cleanup can prove ownership at the platform edge.
  final Set<String> _captureSourcesToStop = <String>{};
  LiveSubtitleSessionStartRequest? _request;

  StreamSubscription<SubtitleSessionCoordinatorState>? _coordinatorSubscription;
  StreamSubscription<SubtitleSessionSaveState>? _persistenceSubscription;
  StreamSubscription<AudioCaptureSourceState>? _sourceSubscription;
  StreamSubscription<AudioFrame>? _frameSubscription;
  final Map<String, StreamSubscription<TranscriptRevision>>
  _asrRevisionSubscriptions =
      <String, StreamSubscription<TranscriptRevision>>{};
  final Map<String, StreamSubscription<StreamingAsrState>>
  _asrStateSubscriptions = <String, StreamSubscription<StreamingAsrState>>{};

  final Map<String, AudioCaptureSourceState> _sourceStates =
      <String, AudioCaptureSourceState>{};
  String? _captureAttemptId;
  int _activeCaptureOffsetUs = 0;
  final Map<String, int> _lastFrameSequenceBySource = <String, int>{};
  bool _acceptFrames = false;
  bool _captureStartRequested = false;
  bool _captureStopped = false;
  bool _capturePaused = false;
  bool _asrClosing = false;
  bool _stopInProgress = false;
  Future<void> _operationTail = Future<void>.value();
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  Future<void>? _failureFuture;
  Future<void>? _disposeFuture;

  Stream<LiveSubtitleSessionState> get stateChanges => _states.stream;

  /// Capture attempt currently allowed to produce frames for this session.
  /// Null means capture is paused or has stopped.
  String? get captureAttemptId => _captureAttemptId;

  LiveSubtitleSessionState get currentState => LiveSubtitleSessionState(
    coordinator: _coordinator?.currentState,
    source: _primarySourceState,
    sourceStates: List<AudioCaptureSourceState>.unmodifiable(
      _sourceStates.values,
    ),
    asr: _primaryAsrState,
    asrStates: Map<String, StreamingAsrState>.unmodifiable({
      for (final entry in _asrBySource.entries)
        entry.key: entry.value.currentState,
    }),
    translationQueue: _translationQueue?.currentState,
    persistence: _persistence?.currentState,
    errorCodes: List<String>.unmodifiable(_errorCodes),
  );

  /// True only after every capture source attempted by this session has
  /// acknowledged stop. A failed subtitle session can still own live audio.
  bool get captureStopConfirmed =>
      !_captureStartRequested ||
      (_captureStopped && _captureSourcesToStop.isEmpty);

  AudioCaptureSourceState? get _primarySourceState {
    final request = _request;
    if (request == null) return null;
    return _sourceStates[_captureSourceIdentity(
      request.source.sourceKind,
      request.source.sourceId,
    )];
  }

  StreamingAsrState? get _primaryAsrState {
    final request = _request;
    if (request == null) return null;
    return _asrBySource[_captureSourceIdentity(
          request.source.sourceKind,
          request.source.sourceId,
        )]
        ?.currentState;
  }

  Future<void> start(LiveSubtitleSessionStartRequest request) {
    final existing = _startFuture;
    if (existing != null) return existing;
    if (_stopFuture != null) {
      return Future<void>.error(
        const LiveSubtitleSessionException('session_already_stopped'),
      );
    }
    _request = request;
    _setCaptureAttemptId(request.initialCaptureAttemptId);
    _activeCaptureOffsetUs = request.activeCaptureOffsetUs;
    final operation = _enqueueLifecycle(() => _start(request));
    _startFuture = operation;
    return operation;
  }

  Future<void> _start(LiveSubtitleSessionStartRequest request) async {
    var failureFallback = 'session_start_failed';
    try {
      final queue = SubtitleTranslationQueue(
        executor: _translationExecutor,
        targetLanguageCode: request.targetLanguageCode,
        maxPending: maxPendingTranslations,
      );
      final coordinator = SubtitleSessionCoordinator(
        sessionId: request.sessionId,
        initialCaptureAttemptId: request.initialCaptureAttemptId,
        translationQueue: queue,
        translationEnabled: request.translationEnabled,
      );
      _translationQueue = queue;
      _coordinator = coordinator;
      _coordinatorSubscription = coordinator.stateChanges.listen(
        (_) => _publish(),
        onError: (Object _, StackTrace __) =>
            _handleAsyncFailure('coordinator_state_stream_failed'),
      );
      _publish();

      failureFallback = 'storage_initial_write_failed';
      final persistence = await SubtitleSessionPersistence.attach(
        store: _store,
        coordinator: coordinator,
        kind: request.kind,
        sourceKind: request.source.sourceKind,
        sources: [
          for (final source in request.sources)
            SubtitleSessionAudioSource(
              sourceId: source.sourceId,
              sourceKind: source.sourceKind,
              displayName: source.displayName,
            ),
        ],
        targetLanguageCode: request.targetLanguageCode,
        recognitionMode: request.recognitionMode,
        startedAtUtc: request.startedAtUtc ?? DateTime.now().toUtc(),
      );
      _persistence = persistence;
      _persistenceSubscription = persistence.stateChanges.listen(
        (_) => _publish(),
        onError: (Object _, StackTrace __) =>
            _handleAsyncFailure('storage_state_stream_failed'),
      );
      _publish();

      final initialSave = await persistence.initialWrite;
      if (!persistence.isPersisted ||
          initialSave.status != SubtitleSessionSaveStatus.saved) {
        final code = initialSave.errorCode ?? failureFallback;
        _recordError(code);
        throw LiveSubtitleSessionException(code);
      }

      failureFallback = 'asr_runtime_initialization_failed';
      for (final source in request.sources) {
        final asr = await _openAsrSession(
          sessionId: request.sessionId,
          sourceId: source.sourceId,
          sourceKind: source.sourceKind,
          sourceLanguageCode: request.sourceLanguageCode,
        );
        final sourceIdentity = _captureSourceIdentity(
          source.sourceKind,
          source.sourceId,
        );
        _asrBySource[sourceIdentity] = asr;
        _asrStateSubscriptions[sourceIdentity] = asr.stateChanges.listen(
          _onAsrState,
          onError: (Object _, StackTrace __) =>
              _handleAsyncFailure('asr_state_stream_failed'),
          onDone: _onAsrStateStreamDone,
        );
        _asrRevisionSubscriptions[sourceIdentity] = asr.revisions.listen(
          _onTranscriptRevision,
          onError: (Object _, StackTrace __) =>
              _handleAsyncFailure('asr_revision_stream_failed'),
          onDone: _onAsrRevisionStreamDone,
        );
        _publish();

        failureFallback = 'asr_runtime_initialization_failed';
        await _waitForAsrReady(asr);
      }

      // Arm every ASR worker before capture can emit a frame for that source.
      for (final asr in _asrBySource.values) {
        asr.beginCaptureAttempt(request.initialCaptureAttemptId);
      }
      _setCaptureAttemptId(request.initialCaptureAttemptId);
      _sourceStates.clear();
      _lastFrameSequenceBySource.clear();
      _subscribeToCapture();
      _acceptFrames = true;
      _captureStartRequested = true;

      failureFallback = 'audio_capture_start_failed';
      for (final source in request.sources) {
        // Remember before awaiting: if the platform partially starts before a
        // channel error, cleanup can ask it to stop this session's owner. The
        // native owner check prevents touching another session's same source.
        _captureSourcesToStop.add(source.sourceId);
        await _capture.startSource(
          source: source,
          sessionId: request.sessionId,
          captureAttemptId: request.initialCaptureAttemptId,
          activeCaptureOffsetUs: _activeCaptureOffsetUs,
        );
      }
      _captureStopped = false;
      _publish();
    } catch (error) {
      final code = _stableFailureCode(error, failureFallback);
      if (!_errorCodes.contains(code)) _recordError(code);
      await _failAndCleanup(code);
      throw LiveSubtitleSessionException(code);
    }
  }

  Future<void> pause() => _enqueueLifecycle(_pause);

  Future<void> _pause() async {
    final coordinator = _coordinator;
    final attemptId = _captureAttemptId;
    final request = _request;
    if (coordinator == null ||
        request == null ||
        _asrBySource.isEmpty ||
        attemptId == null) {
      throw const LiveSubtitleSessionException('session_not_started');
    }
    final status = coordinator.currentState.status;
    if (status == SubtitleSessionStatus.paused) return;
    if (status != SubtitleSessionStatus.preparing &&
        status != SubtitleSessionStatus.capturing) {
      throw const LiveSubtitleSessionException('session_not_active');
    }

    try {
      for (final sourceId in _captureSourcesToStop) {
        await _capture.pauseSource(
          sourceId: sourceId,
          sessionId: request.sessionId,
        );
      }
      _capturePaused = true;
      // Native sources have acknowledged pause. Stop accepting late queued
      // EventChannel frames before asking each ASR worker to finish the attempt;
      // otherwise a frame delivered during the finish acknowledgement can be
      // sent after the worker has already closed that attempt.
      _acceptFrames = false;
      _setCaptureAttemptId(null);
      await Future.wait<void>([
        for (final asr in _asrBySource.values)
          asr.finishCaptureAttempt(attemptId),
      ]);
      coordinator.pause();
      _publish();
    } catch (error) {
      const fallback = 'session_pause_failed';
      final code = _stableFailureCode(error, fallback);
      if (!_errorCodes.contains(code)) _recordError(code);
      await _failAndCleanup(code);
      throw LiveSubtitleSessionException(code);
    }
  }

  Future<void> resume() => _enqueueLifecycle(_resume);

  Future<void> _resume() async {
    final request = _request;
    final coordinator = _coordinator;
    if (request == null || coordinator == null || _asrBySource.isEmpty) {
      throw const LiveSubtitleSessionException('session_not_started');
    }
    if (coordinator.currentState.status != SubtitleSessionStatus.paused) {
      throw const LiveSubtitleSessionException('session_not_paused');
    }

    final nextAttemptId = _newCaptureAttemptId();
    try {
      coordinator.resume(captureAttemptId: nextAttemptId);
      _setCaptureAttemptId(nextAttemptId);
      _sourceStates.clear();
      _lastFrameSequenceBySource.clear();

      // The decoder must be ready for the new attempt before native capture
      // can emit a frame tagged with that attempt ID.
      for (final asr in _asrBySource.values) {
        asr.beginCaptureAttempt(nextAttemptId);
      }
      _acceptFrames = true;
      _capturePaused = false;
      _captureStopped = false;
      _captureStartRequested = true;
      for (final source in request.sources) {
        await _capture.resumeSource(
          source: source,
          sessionId: request.sessionId,
          captureAttemptId: nextAttemptId,
          activeCaptureOffsetUs: _activeCaptureOffsetUs,
        );
      }
      _publish();
    } catch (error) {
      const fallback = 'session_resume_failed';
      final code = _stableFailureCode(error, fallback);
      if (!_errorCodes.contains(code)) _recordError(code);
      await _failAndCleanup(code);
      throw LiveSubtitleSessionException(code);
    }
  }

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    final operation = _enqueueLifecycle(_stop);
    _stopFuture = operation;
    return operation;
  }

  /// Stops any remaining work and closes this session's public state stream.
  /// Safe to call after an ordinary stop, an asynchronous failure, or a
  /// partially completed start.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    final start = _startFuture;
    if (start != null) {
      try {
        await start;
      } on Object {
        // start() already publishes a stable failure code and performs its
        // own failure cleanup before completing with an error.
      }
    }

    final failure = _failureFuture;
    if (failure != null) {
      try {
        await failure;
      } on Object {
        // Continue releasing the resources that did not fail cleanup.
      }
    }

    try {
      await stop();
    } on Object {
      // stop() records a stable code; disposal still closes owned observers.
    }
    if (_captureSourcesToStop.isNotEmpty) {
      final stopped = await _stopOwnedCaptureSources();
      _captureStopped = _captureSourcesToStop.isEmpty;
      if (!stopped && !_errorCodes.contains('audio_capture_stop_failed')) {
        _recordError('audio_capture_stop_failed');
      }
    }
    await _operationTail;
    await _cancelCaptureSubscriptions();
    await _cancelAsrSubscriptions();
    await _cancelCoordinatorSubscription();
    await _cancelPersistenceSubscription();
    final persistence = _persistence;
    if (persistence != null) {
      await _attemptCleanup(persistence.close, 'storage_close_failed');
    }
    final translationQueue = _translationQueue;
    if (translationQueue != null) {
      await _attemptCleanup(
        translationQueue.close,
        'translation_queue_close_failed',
      );
    }
    if (!_states.isClosed) await _states.close();
  }

  Future<void> _stop() async {
    final coordinator = _coordinator;
    final persistence = _persistence;
    if (coordinator == null) return;
    _stopInProgress = true;
    var stopFailureCode = '';

    if (_captureStartRequested &&
        (!_captureStopped || _captureSourcesToStop.isNotEmpty)) {
      final stopped = await _stopOwnedCaptureSources();
      if (!stopped) {
        stopFailureCode = 'audio_capture_stop_failed';
        _recordError(stopFailureCode);
      }
    }
    _captureStopped = _captureSourcesToStop.isEmpty;
    _acceptFrames = false;
    _setCaptureAttemptId(null);
    await _cancelCaptureSubscriptions();

    if (_asrBySource.isNotEmpty && !_asrClosing) {
      _asrClosing = true;
      for (final asr in _asrBySource.values) {
        try {
          // Keep the revision listeners attached until every recognizer has
          // flushed final revisions into the still-open coordinator.
          await asr.close();
        } catch (_) {
          stopFailureCode = stopFailureCode.isEmpty
              ? 'asr_close_failed'
              : stopFailureCode;
          _recordError('asr_close_failed');
        }
      }
    }
    await _cancelAsrSubscriptions();

    try {
      // A failed audio stop or ASR flush must remain a failed session in
      // history. Only a clean flush is recorded as completed.
      if (stopFailureCode.isEmpty) {
        await coordinator.stop();
      } else {
        await coordinator.fail();
      }
    } catch (_) {
      stopFailureCode = stopFailureCode.isEmpty
          ? 'coordinator_stop_failed'
          : stopFailureCode;
      _recordError('coordinator_stop_failed');
    }
    await _cancelCoordinatorSubscription();

    if (persistence != null) {
      try {
        // The coordinator's stopped snapshot is persisted before observers are
        // closed, and close drains every queued write.
        await persistence.close();
      } catch (_) {
        stopFailureCode = stopFailureCode.isEmpty
            ? 'storage_close_failed'
            : stopFailureCode;
        _recordError('storage_close_failed');
      }
    }
    await _cancelPersistenceSubscription();
    _publish();

    if (stopFailureCode.isNotEmpty) {
      throw LiveSubtitleSessionException(stopFailureCode);
    }
  }

  Future<SubtitleSessionSaveState> retrySave() async {
    final persistence = _persistence;
    if (persistence == null) {
      throw const LiveSubtitleSessionException('session_not_started');
    }
    try {
      final saveState = await persistence.retrySave();
      _publish();
      return saveState;
    } catch (error) {
      const fallback = 'storage_retry_failed';
      final code = _stableFailureCode(error, fallback);
      if (!_errorCodes.contains(code)) _recordError(code);
      throw LiveSubtitleSessionException(code);
    }
  }

  SubtitleTranslationEnqueueResult retryTranslation(SubtitleSegmentKey key) {
    final coordinator = _coordinator;
    if (coordinator == null) {
      throw const LiveSubtitleSessionException('session_not_started');
    }
    try {
      return coordinator.retryTranslation(key);
    } catch (error) {
      const fallback = 'translation_retry_failed';
      final code = _stableFailureCode(error, fallback);
      if (!_errorCodes.contains(code)) _recordError(code);
      throw LiveSubtitleSessionException(code);
    }
  }

  Future<void> _waitForAsrReady(StreamingAsrSession asr) async {
    void validate(StreamingAsrState state) {
      if (state.status == StreamingAsrStatus.failed) {
        final error = state.errorCode?.name ?? 'runtime_initialization_failed';
        throw LiveSubtitleSessionException('asr_$error');
      }
      if (state.status == StreamingAsrStatus.closed) {
        throw const LiveSubtitleSessionException('asr_closed_before_start');
      }
    }

    validate(asr.currentState);
    if (asr.currentState.status == StreamingAsrStatus.ready) return;

    final ready = Completer<void>();
    late final StreamSubscription<StreamingAsrState> subscription;
    subscription = asr.stateChanges.listen(
      (state) {
        try {
          validate(state);
          if (state.status == StreamingAsrStatus.ready && !ready.isCompleted) {
            ready.complete();
          }
        } catch (error, stackTrace) {
          if (!ready.isCompleted) ready.completeError(error, stackTrace);
        }
      },
      onError: (Object _, StackTrace stackTrace) {
        if (!ready.isCompleted) {
          ready.completeError(
            const LiveSubtitleSessionException('asr_state_stream_failed'),
            stackTrace,
          );
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(
            const LiveSubtitleSessionException('asr_state_stream_closed'),
          );
        }
      },
    );
    try {
      // Re-read after listening so a ready event between the first read and
      // subscription cannot leave start waiting forever.
      validate(asr.currentState);
      if (asr.currentState.status == StreamingAsrStatus.ready &&
          !ready.isCompleted) {
        ready.complete();
      }
      try {
        await ready.future.timeout(asrReadyTimeout);
      } on TimeoutException {
        throw const LiveSubtitleSessionException('asr_ready_timeout');
      }
    } finally {
      await subscription.cancel();
    }
  }

  Future<StreamingAsrSession> _openAsrSession({
    required String sessionId,
    required String sourceId,
    required SubtitleAudioSourceKind sourceKind,
    required String sourceLanguageCode,
  }) async {
    final opening = _asrRuntime.openSession(
      sessionId: sessionId,
      sourceId: sourceId,
      sourceKind: sourceKind,
      sourceLanguageCode: sourceLanguageCode,
    );
    try {
      return await opening.timeout(asrOpenTimeout);
    } on TimeoutException {
      // Future.timeout cannot cancel the runtime operation. If it eventually
      // returns a recognizer, close that late resource instead of leaking its
      // worker after this session has already failed startup.
      unawaited(
        opening.then<void>(
          (lateSession) => _attemptCleanup(
            lateSession.close,
            'asr_late_session_close_failed',
          ),
          onError: (Object _, StackTrace __) {},
        ),
      );
      throw const LiveSubtitleSessionException('asr_open_timeout');
    }
  }

  void _subscribeToCapture() {
    _sourceSubscription = _capture.sourceStates.listen(
      _onSourceState,
      onError: (Object _, StackTrace __) =>
          _handleAsyncFailure('audio_source_stream_failed'),
      onDone: _onCaptureStreamDone,
    );
    _frameSubscription = _capture.frames.listen(
      _onAudioFrame,
      onError: (Object _, StackTrace __) =>
          _handleAsyncFailure('audio_frame_stream_failed'),
      onDone: _onCaptureStreamDone,
    );
  }

  void _onAudioFrame(AudioFrame frame) {
    final request = _request;
    final attemptId = _captureAttemptId;
    final sourceIdentity = _captureSourceIdentity(
      frame.sourceKind,
      frame.sourceId,
    );
    final asr = _asrBySource[sourceIdentity];
    if (!_acceptFrames || request == null || asr == null || attemptId == null) {
      return;
    }
    if (frame.sessionId != request.sessionId ||
        frame.captureAttemptId != attemptId ||
        !request.sources.any(
          (source) =>
              source.sourceId == frame.sourceId &&
              source.sourceKind == frame.sourceKind,
        )) {
      return;
    }
    final lastSequence = _lastFrameSequenceBySource[sourceIdentity];
    if (lastSequence != null && frame.sequence <= lastSequence) return;

    try {
      // addAudio is synchronous by contract: returning means the bounded ASR
      // worker accepted the frame; throwing means it did not.
      asr.addAudio(frame);
      _lastFrameSequenceBySource[sourceIdentity] = frame.sequence;
      final frameEndUs = frame.startTimeUs + frame.durationUs;
      if (frameEndUs > _activeCaptureOffsetUs) {
        _activeCaptureOffsetUs = frameEndUs;
      }

      final coordinator = _coordinator;
      if (coordinator?.currentState.status == SubtitleSessionStatus.preparing) {
        coordinator!.markCapturing();
      }
    } catch (error) {
      _handleAsyncFailure(_stableFailureCode(error, 'asr_audio_rejected'));
    }
  }

  void _onSourceState(AudioCaptureSourceState state) {
    final request = _request;
    final attemptId = _captureAttemptId;
    if (request == null || attemptId == null) return;
    if (!request.sources.any(
          (source) =>
              source.sourceId == state.sourceId &&
              source.sourceKind == state.sourceKind,
        ) ||
        state.sessionId != request.sessionId ||
        state.captureAttemptId != attemptId) {
      return;
    }
    _sourceStates[_captureSourceIdentity(state.sourceKind, state.sourceId)] =
        state;
    _publish();

    final code = switch (state.status) {
      AudioCaptureSourceStatus.permissionDenied => 'audio_access_denied',
      AudioCaptureSourceStatus.deviceUnavailable => 'audio_device_unavailable',
      AudioCaptureSourceStatus.deviceDisconnected =>
        'audio_device_disconnected',
      AudioCaptureSourceStatus.failed =>
        'audio_${state.errorCode?.name ?? 'capture_failed'}',
      AudioCaptureSourceStatus.stopped when !_stopInProgress =>
        'audio_source_stopped',
      _ => null,
    };
    if (code != null) _handleAsyncFailure(code);
  }

  void _onTranscriptRevision(TranscriptRevision revision) {
    final request = _request;
    final attemptId = _captureAttemptId;
    final coordinator = _coordinator;
    if (request == null || attemptId == null || coordinator == null) return;
    if (revision.sessionId != request.sessionId ||
        revision.captureAttemptId != attemptId ||
        !request.sources.any(
          (source) =>
              source.sourceId == revision.sourceId &&
              source.sourceKind == revision.sourceKind,
        )) {
      return;
    }
    try {
      coordinator.applyTranscriptRevision(revision);
      _publish();
    } catch (error) {
      _handleAsyncFailure(_stableFailureCode(error, 'asr_revision_rejected'));
    }
  }

  void _onAsrState(StreamingAsrState state) {
    _publish();
    if (state.status == StreamingAsrStatus.failed) {
      final error = state.errorCode?.name ?? 'runtime_failed';
      _handleAsyncFailure('asr_$error');
    } else if (state.status == StreamingAsrStatus.closed && !_asrClosing) {
      _handleAsyncFailure('asr_closed_unexpectedly');
    }
  }

  void _onAsrStateStreamDone() {
    if (!_asrClosing && !_stopInProgress) {
      _handleAsyncFailure('asr_state_stream_closed');
    }
  }

  void _onAsrRevisionStreamDone() {
    if (!_asrClosing && !_stopInProgress) {
      _handleAsyncFailure('asr_revision_stream_closed');
    }
  }

  void _onCaptureStreamDone() {
    if (!_stopInProgress && !_capturePaused && _captureStartRequested) {
      _handleAsyncFailure('audio_capture_stream_closed');
    }
  }

  void _handleAsyncFailure(String code) {
    if (_failureFuture != null || _stopInProgress) return;
    final failure = _enqueueLifecycle(() => _failAndCleanup(code));
    unawaited(
      failure.then<void>(
        (_) {},
        onError: (Object error, StackTrace _) {
          final cleanupCode = _stableFailureCode(
            error,
            'session_cleanup_failed',
          );
          if (!_errorCodes.contains(cleanupCode)) _recordError(cleanupCode);
        },
      ),
    );
  }

  Future<void> _failAndCleanup(String code) {
    final existing = _failureFuture;
    if (existing != null) return existing;
    final operation = _performFailureCleanup(code);
    _failureFuture = operation;
    return operation;
  }

  Future<void> _performFailureCleanup(String code) async {
    _recordError(code);
    _stopInProgress = true;
    _acceptFrames = false;
    _setCaptureAttemptId(null);

    if (_captureStartRequested &&
        (!_captureStopped || _captureSourcesToStop.isNotEmpty)) {
      await _stopOwnedCaptureSources(
        onFailure: () => _recordError('audio_capture_stop_failed'),
      );
      _captureStopped = _captureSourcesToStop.isEmpty;
    }
    await _cancelCaptureSubscriptions();

    if (_asrBySource.isNotEmpty && !_asrClosing) {
      _asrClosing = true;
      for (final asr in _asrBySource.values) {
        await _attemptCleanup(asr.close, 'asr_close_failed');
      }
    }
    await _cancelAsrSubscriptions();

    final coordinator = _coordinator;
    if (coordinator != null) {
      await _attemptCleanup(coordinator.fail, 'coordinator_fail_failed');
    }
    await _cancelCoordinatorSubscription();
    final persistence = _persistence;
    if (persistence != null) {
      await _attemptCleanup(persistence.close, 'storage_close_failed');
    }
    await _cancelPersistenceSubscription();
    _publish();
  }

  Future<void> _attemptCleanup(
    Future<void> Function() operation,
    String errorCode,
  ) async {
    try {
      await operation();
    } catch (_) {
      // The stable cleanup code is retained in state; raw platform/runtime
      // exception text never crosses this owner boundary.
      if (!_errorCodes.contains(errorCode)) _recordError(errorCode);
    }
  }

  Future<bool> _stopOwnedCaptureSources({void Function()? onFailure}) async {
    var stopped = true;
    final sourceIds = _captureSourcesToStop.toList(growable: false);
    final sessionId = _request?.sessionId;
    for (final sourceId in sourceIds) {
      if (sessionId == null) {
        stopped = false;
        onFailure?.call();
        continue;
      }
      try {
        await _capture.stopSource(sourceId: sourceId, sessionId: sessionId);
        _captureSourcesToStop.remove(sourceId);
      } catch (error) {
        if (_isCaptureOwnershipMismatch(error)) {
          // A failed start may have been rejected because another session
          // already owns this source ID. The native edge guarantees that the
          // mismatched stop did not touch that capture, so this session can
          // forget the attempted source without reporting a cleanup failure.
          _captureSourcesToStop.remove(sourceId);
          continue;
        }
        stopped = false;
        onFailure?.call();
      }
    }
    return stopped;
  }

  void _setCaptureAttemptId(String? captureAttemptId) {
    if (_captureAttemptId == captureAttemptId) return;
    _captureAttemptId = captureAttemptId;
    onCaptureAttemptChanged?.call(captureAttemptId);
  }

  Future<void> _cancelCaptureSubscriptions() async {
    final frame = _frameSubscription;
    _frameSubscription = null;
    if (frame != null) {
      await _attemptCleanup(
        frame.cancel,
        'audio_frame_subscription_close_failed',
      );
    }
    final source = _sourceSubscription;
    _sourceSubscription = null;
    if (source != null) {
      await _attemptCleanup(
        source.cancel,
        'audio_source_subscription_close_failed',
      );
    }
  }

  Future<void> _cancelAsrSubscriptions() async {
    final revisions = _asrRevisionSubscriptions.values.toList(growable: false);
    _asrRevisionSubscriptions.clear();
    for (final subscription in revisions) {
      await _attemptCleanup(
        subscription.cancel,
        'asr_revision_subscription_close_failed',
      );
    }
    final states = _asrStateSubscriptions.values.toList(growable: false);
    _asrStateSubscriptions.clear();
    for (final subscription in states) {
      await _attemptCleanup(
        subscription.cancel,
        'asr_state_subscription_close_failed',
      );
    }
  }

  Future<void> _cancelCoordinatorSubscription() async {
    final subscription = _coordinatorSubscription;
    _coordinatorSubscription = null;
    if (subscription != null) {
      await _attemptCleanup(
        subscription.cancel,
        'coordinator_subscription_close_failed',
      );
    }
  }

  Future<void> _cancelPersistenceSubscription() async {
    final subscription = _persistenceSubscription;
    _persistenceSubscription = null;
    if (subscription != null) {
      await _attemptCleanup(
        subscription.cancel,
        'storage_subscription_close_failed',
      );
    }
  }

  Future<void> _enqueueLifecycle(Future<void> Function() operation) {
    final next = _operationTail.then((_) => operation());
    // Keep the serialization chain usable after an operation fails while
    // returning the original failure to its caller.
    _operationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        if (error is LiveSubtitleSessionException) throw error;
        final code = _stableFailureCode(error, 'session_operation_failed');
        if (!_errorCodes.contains(code)) _recordError(code);
        throw LiveSubtitleSessionException(code);
      },
    );
  }

  void _recordError(String code) {
    if (code.trim().isEmpty || _errorCodes.contains(code)) return;
    _errorCodes.add(code);
    _publish();
  }

  void _publish() {
    if (!_states.isClosed) _states.add(currentState);
  }

  static String _stableFailureCode(Object error, String fallback) =>
      switch (error) {
        LiveSubtitleSessionException(:final code) => code,
        SubtitleSessionStoreException(:final code) => code,
        SubtitleTranslationFailure(:final code) => code,
        StreamingAsrException(:final code) => 'asr_${code.name}',
        _ => fallback,
      };

  static bool _isCaptureOwnershipMismatch(Object error) =>
      error is PlatformException &&
      error.code == 'capture_source_owned_by_another_session';

  static String _newCaptureAttemptId() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0'));
    final value = hex.join();
    return 'capture-${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }
}

List<DesktopAudioCaptureSource> _normalizeAdditionalSources(
  DesktopAudioCaptureSource primary,
  Iterable<DesktopAudioCaptureSource> additional,
) {
  if (primary.sourceId.trim().isEmpty) {
    throw ArgumentError.value(primary.sourceId, 'source.sourceId');
  }
  // The Windows capture registry is keyed by sourceId alone, so the same id
  // cannot be selected twice under two different source kinds.
  final seen = <String>{primary.sourceId};
  final result = <DesktopAudioCaptureSource>[];
  for (final source in additional) {
    if (source.sourceId.trim().isEmpty) {
      throw ArgumentError.value(source.sourceId, 'additionalSources.sourceId');
    }
    if (!seen.add(source.sourceId)) {
      throw ArgumentError(
        'A capture source cannot be selected more than once.',
      );
    }
    result.add(source);
  }
  return result;
}

String _captureSourceIdentity(SubtitleAudioSourceKind sourceKind, String id) =>
    '${sourceKind.name}\u0000$id';
