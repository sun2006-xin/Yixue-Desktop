import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'subtitle_session_contract.dart';
import 'subtitle_session_coordinator.dart';
import 'subtitle_session_store.dart';

enum SubtitleSessionSaveStatus { idle, saving, saved, failed }

final class SubtitleSessionSaveState {
  const SubtitleSessionSaveState({required this.status, this.errorCode});

  final SubtitleSessionSaveStatus status;
  final String? errorCode;
}

/// Persists final subtitle revisions and lifecycle changes for one coordinator.
///
/// Call [attach] before starting audio capture, then inspect [initialWrite] and
/// [isPersisted] so the owner can handle an initial save failure explicitly.
/// Later writes are serialized in state order; failures are exposed to the
/// workbench and do not stop capture or translation. Call [retrySave] after a
/// visible save error.
final class SubtitleSessionPersistence {
  SubtitleSessionPersistence._({
    required this.store,
    required this.coordinator,
    required this.kind,
    required this.sourceKind,
    required this.sources,
    required this.targetLanguageCode,
    required this.recognitionMode,
    required this.startedAtUtc,
  }) {
    _subscription = coordinator.stateChanges.listen(_onCoordinatorState);
  }

  final SubtitleSessionStore store;
  final SubtitleSessionCoordinator coordinator;
  final SubtitleSessionKind kind;
  final SubtitleAudioSourceKind sourceKind;
  final List<SubtitleSessionAudioSource> sources;
  final String targetLanguageCode;
  final SubtitleRecognitionMode recognitionMode;
  final DateTime startedAtUtc;

  final Map<SubtitleSegmentKey, String> _savedCueFingerprints =
      <SubtitleSegmentKey, String>{};
  final StreamController<SubtitleSessionSaveState> _states =
      StreamController<SubtitleSessionSaveState>.broadcast();
  late final StreamSubscription<SubtitleSessionCoordinatorState> _subscription;
  SubtitleSessionSaveState _currentState = const SubtitleSessionSaveState(
    status: SubtitleSessionSaveStatus.idle,
  );
  late final Future<SubtitleSessionSaveState> initialWrite;
  Future<void> _writeTail = Future<void>.value();
  SubtitleSessionHistoryStatus? _savedStatus;
  var _created = false;
  var _closed = false;

  static Future<SubtitleSessionPersistence> attach({
    required SubtitleSessionStore store,
    required SubtitleSessionCoordinator coordinator,
    required SubtitleSessionKind kind,
    required SubtitleAudioSourceKind sourceKind,
    Iterable<SubtitleSessionAudioSource> sources =
        const <SubtitleSessionAudioSource>[],
    required String targetLanguageCode,
    required SubtitleRecognitionMode recognitionMode,
    required DateTime startedAtUtc,
  }) async {
    if (targetLanguageCode.trim().isEmpty) {
      throw ArgumentError.value(
        targetLanguageCode,
        'targetLanguageCode',
        'Must not be empty.',
      );
    }
    final persistence = SubtitleSessionPersistence._(
      store: store,
      coordinator: coordinator,
      kind: kind,
      sourceKind: sourceKind,
      sources: List<SubtitleSessionAudioSource>.unmodifiable(sources),
      targetLanguageCode: targetLanguageCode.trim(),
      recognitionMode: recognitionMode,
      startedAtUtc: startedAtUtc.toUtc(),
    );
    // Subscribe first, then replay current state so no transition is lost.
    persistence.initialWrite = persistence._enqueue(coordinator.currentState);
    await persistence.initialWrite;
    return persistence;
  }

  Stream<SubtitleSessionSaveState> get stateChanges => _states.stream;
  SubtitleSessionSaveState get currentState => _currentState;
  bool get isPersisted => _created;

  /// Replays the coordinator's current snapshot after a prior write failure.
  Future<SubtitleSessionSaveState> retrySave() =>
      _enqueue(coordinator.currentState, allowAfterClose: true);

  /// Stops observing state and drains all writes already queued.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _writeTail;
    await _states.close();
  }

  void _onCoordinatorState(SubtitleSessionCoordinatorState state) {
    unawaited(_enqueue(state).then<void>((_) {}));
  }

  Future<SubtitleSessionSaveState> _enqueue(
    SubtitleSessionCoordinatorState state, {
    bool allowAfterClose = false,
  }) {
    if (_closed && !allowAfterClose) {
      return Future<SubtitleSessionSaveState>.value(_currentState);
    }
    final result = Completer<SubtitleSessionSaveState>();
    final next = _writeTail.then((_) async {
      try {
        if (!_hasChanges(state)) {
          result.complete(_currentState);
          return;
        }
        _emit(
          const SubtitleSessionSaveState(
            status: SubtitleSessionSaveStatus.saving,
          ),
        );
        await _persist(state);
        final saved = const SubtitleSessionSaveState(
          status: SubtitleSessionSaveStatus.saved,
        );
        _emit(saved);
        result.complete(saved);
      } catch (error) {
        final failed = SubtitleSessionSaveState(
          status: SubtitleSessionSaveStatus.failed,
          errorCode: _errorCode(error),
        );
        _emit(failed);
        result.complete(failed);
      }
    });
    _writeTail = next;
    return result.future;
  }

  bool _hasChanges(SubtitleSessionCoordinatorState state) {
    if (!_created || _savedStatus != _historyStatus(state.status)) return true;
    for (final segment in state.segments) {
      if (!segment.transcript.isFinal) continue;
      if (_savedCueFingerprints[segment.key] != _cueFingerprint(segment)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _persist(SubtitleSessionCoordinatorState state) async {
    if (!_created) {
      await store.createSession(
        SubtitleSessionRecord(
          sessionId: coordinator.sessionId,
          kind: kind,
          sourceKind: sourceKind,
          sources: sources,
          targetLanguageCode: targetLanguageCode,
          recognitionMode: recognitionMode,
          startedAtUtc: startedAtUtc,
          status: SubtitleSessionHistoryStatus.preparing,
        ),
      );
      _created = true;
      _savedStatus = SubtitleSessionHistoryStatus.preparing;
    }

    for (final segment in state.segments) {
      if (!segment.transcript.isFinal) continue;
      final fingerprint = _cueFingerprint(segment);
      if (_savedCueFingerprints[segment.key] == fingerprint) continue;
      await store.saveConfirmedSegment(
        coordinator.sessionId,
        segment,
        translatedTargetLanguageCode:
            segment.translationStatus == SubtitleTranslationStatus.translated
            ? segment.translationRequest?.targetLanguageCode
            : null,
      );
      _savedCueFingerprints[segment.key] = fingerprint;
    }

    final nextStatus = _historyStatus(state.status);
    if (nextStatus != null && nextStatus != _savedStatus) {
      await store.updateSessionStatus(coordinator.sessionId, nextStatus);
      _savedStatus = nextStatus;
    }
  }

  SubtitleSessionHistoryStatus? _historyStatus(SubtitleSessionStatus status) =>
      switch (status) {
        SubtitleSessionStatus.idle || SubtitleSessionStatus.preparing =>
          SubtitleSessionHistoryStatus.preparing,
        SubtitleSessionStatus.capturing =>
          SubtitleSessionHistoryStatus.capturing,
        SubtitleSessionStatus.paused => SubtitleSessionHistoryStatus.paused,
        SubtitleSessionStatus.stopped => SubtitleSessionHistoryStatus.completed,
        SubtitleSessionStatus.failed => SubtitleSessionHistoryStatus.failed,
        SubtitleSessionStatus.stopping => null,
      };

  static String _cueFingerprint(SubtitleSegment segment) =>
      jsonEncode(<Object?>[
        segment.transcript.revision,
        segment.transcript.sourceId,
        segment.transcript.sourceKind.name,
        segment.transcript.startMs,
        segment.transcript.endMs,
        segment.transcript.text,
        segment.transcript.languageCode,
        segment.transcript.speakerId,
        segment.translationStatus == SubtitleTranslationStatus.skippedDisabled,
        segment.translationStatus ==
            SubtitleTranslationStatus.skippedSameLanguage,
        segment.translationStatus == SubtitleTranslationStatus.translated
            ? segment.translatedText
            : null,
        segment.translationStatus == SubtitleTranslationStatus.translated
            ? segment.translationRequest?.targetLanguageCode
            : null,
      ]);

  static String _errorCode(Object error) => switch (error) {
    SubtitleSessionStoreException(:final code) => code,
    FileSystemException() => 'storage_io_failed',
    _ => 'storage_write_failed',
  };

  void _emit(SubtitleSessionSaveState state) {
    _currentState = state;
    if (!_states.isClosed) _states.add(state);
  }
}
