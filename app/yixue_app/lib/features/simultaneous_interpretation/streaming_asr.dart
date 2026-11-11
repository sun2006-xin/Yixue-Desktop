import 'dart:async';

import 'audio_capture_contract.dart';
import 'subtitle_session_contract.dart';

/// Runtime boundary for local streaming speech recognition.
///
/// ASR is deliberately separate from the translation Provider. The recognizer
/// receives transient audio frames and returns revisions for the existing
/// subtitle timeline contract.
abstract interface class StreamingAsrRuntime {
  Future<StreamingAsrSession> openSession({
    required String sessionId,
    required String sourceId,
    required SubtitleAudioSourceKind sourceKind,
    required String sourceLanguageCode,
  });
}

/// One streaming recognizer across a subtitle session's capture attempts.
///
/// [addAudio] must be fast and bounded. Returning means the frame was
/// accepted into the bounded recognizer queue. A terminal state or rejected
/// frame is reported synchronously as [StreamingAsrException], as well as
/// through [stateChanges]. The runtime never silently stitches audio across
/// dropped frames.
abstract interface class StreamingAsrSession {
  Stream<TranscriptRevision> get revisions;

  Stream<StreamingAsrState> get stateChanges;

  StreamingAsrState get currentState;

  /// Arms the worker for a fresh native capture attempt before capture starts.
  /// Late frames from previous attempts are ignored.
  void beginCaptureAttempt(String captureAttemptId);

  void addAudio(AudioFrame frame);

  /// Flushes the current decoder attempt while keeping the recognizer loaded.
  /// Call after capture has paused and before starting a fresh attempt.
  Future<void> finishCaptureAttempt(String captureAttemptId);

  /// Flushes the active attempt and releases native recognizer resources.
  Future<void> close();
}

enum StreamingAsrStatus {
  loading,
  ready,
  recognizing,
  flushing,
  closed,
  failed,
}

enum StreamingAsrErrorCode {
  modelUnavailable,
  modelInvalid,
  runtimeUnavailable,
  runtimeInitializationFailed,
  audioFormatUnsupported,
  audioBackpressure,
  recognitionFailed,
  workerExited,
  workerTimedOut,
  workerProtocolError,
}

final class StreamingAsrException implements Exception {
  const StreamingAsrException(this.code);

  final StreamingAsrErrorCode code;

  @override
  String toString() => 'StreamingAsrException(${code.name})';
}

final class StreamingAsrState {
  const StreamingAsrState({
    required this.status,
    this.errorCode,
    this.hasRecognizedSpeech = false,
    this.captureAttemptId,
  });

  final StreamingAsrStatus status;
  final StreamingAsrErrorCode? errorCode;
  final bool hasRecognizedSpeech;
  final String? captureAttemptId;
}

/// Current repository accepts only PCM input, so an adapter implementation can
/// be replaced without coupling the session coordinator to one ASR package.
typedef StreamingAsrRevision = TranscriptRevision;

/// Values used while creating a recognizer session.
final class StreamingAsrSessionConfig {
  StreamingAsrSessionConfig({
    required this.sessionId,
    required this.sourceId,
    required this.sourceKind,
    required this.sourceLanguageCode,
  }) {
    if (sessionId.trim().isEmpty ||
        sourceId.trim().isEmpty ||
        sourceLanguageCode.trim().isEmpty) {
      throw ArgumentError('ASR session identity and language are required.');
    }
  }

  final String sessionId;
  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final String sourceLanguageCode;
}
