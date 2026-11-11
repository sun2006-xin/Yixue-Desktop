import 'asr_language_registry.dart';

/// Audio paths that can supply speech to an interpretation session.
///
/// These values describe the capture source, not the identity of a speaker.
enum SubtitleAudioSourceKind { systemOutput, applicationOutput, microphone }

/// Persisted audio input identity. This describes an input path, never a
/// speaker. Display names are optional because endpoint names can change.
final class SubtitleSessionAudioSource {
  SubtitleSessionAudioSource({
    required this.sourceId,
    required this.sourceKind,
    this.displayName,
  }) {
    if (sourceId.trim().isEmpty) {
      throw ArgumentError.value(sourceId, 'sourceId', 'Must not be empty.');
    }
    if (displayName != null && displayName!.trim().isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'Must not be empty.',
      );
    }
  }

  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final String? displayName;
}

/// Interpretation context used to label a session in the UI and history.
enum SubtitleSessionKind { video, meeting, livestream }

/// Lifecycle states exposed by an interpretation session.
///
/// A session state alone does not prove that an audio source produced frames.
/// Source readiness and first-frame status belong to the capture contract.
enum SubtitleSessionStatus {
  idle,
  preparing,
  capturing,
  paused,
  stopping,
  stopped,
  failed,
}

/// Translation lifecycle for a recognized subtitle segment.
enum SubtitleTranslationStatus {
  awaitingFinal,
  awaitingQueue,
  queued,
  translating,
  translated,
  failed,
  cancelled,
  skippedEmpty,
  skippedDisabled,
  skippedUnsupportedLanguage,
  skippedSameLanguage,
}

/// One recognition update. Interim and final revisions share the same
/// `(sessionId, captureAttemptId, sourceId, sourceKind, segmentId)` key.
/// Source identity describes the input path, not a speaker.
///
/// Times are milliseconds from the start of active capture time, not
/// wall-clock timestamps. A later correction to a segment must use a larger
/// [revision]. Once final, a segment may receive a newer final correction but
/// cannot be reopened by a late interim update.
final class TranscriptRevision {
  TranscriptRevision({
    required this.sessionId,
    required this.captureAttemptId,
    required this.segmentId,
    required this.sourceId,
    required this.sourceKind,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.languageCode,
    required this.revision,
    required this.isFinal,
    this.speakerId,
  }) {
    _requireNonEmpty(sessionId, 'sessionId');
    _requireNonEmpty(captureAttemptId, 'captureAttemptId');
    _requireNonEmpty(segmentId, 'segmentId');
    _requireNonEmpty(sourceId, 'sourceId');
    _requireNonEmpty(languageCode, 'languageCode');
    if (languageCode.trim().toLowerCase().split(RegExp(r'[-_]')).first ==
        'auto') {
      throw ArgumentError.value(
        languageCode,
        'languageCode',
        'Transcript revisions require the recognized language, not auto mode.',
      );
    }
    if (startMs < 0) {
      throw ArgumentError.value(startMs, 'startMs', 'Must be non-negative.');
    }
    if (endMs <= startMs) {
      throw ArgumentError.value(
        endMs,
        'endMs',
        'Must be greater than startMs.',
      );
    }
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision', 'Must be non-negative.');
    }
  }

  final String sessionId;
  final String captureAttemptId;
  final String segmentId;
  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final int startMs;
  final int endMs;
  final String text;
  final String languageCode;
  final String? speakerId;
  final int revision;
  final bool isFinal;
}

/// A translation request is tied to one exact transcript revision and one
/// request attempt. [requestId] must be unique within the application.
final class SubtitleTranslationRequest {
  SubtitleTranslationRequest({
    required this.requestId,
    required this.sessionId,
    required this.captureAttemptId,
    required this.segmentId,
    required this.transcriptRevision,
    required this.text,
    required this.sourceLanguageCode,
    required this.targetLanguageCode,
  }) {
    _requireNonEmpty(requestId, 'requestId');
    _requireNonEmpty(sessionId, 'sessionId');
    _requireNonEmpty(captureAttemptId, 'captureAttemptId');
    _requireNonEmpty(segmentId, 'segmentId');
    _requireNonEmpty(text, 'text');
    _requireNonEmpty(sourceLanguageCode, 'sourceLanguageCode');
    _requireNonEmpty(targetLanguageCode, 'targetLanguageCode');
    if (transcriptRevision < 0) {
      throw ArgumentError.value(
        transcriptRevision,
        'transcriptRevision',
        'Must be non-negative.',
      );
    }
  }

  final String requestId;
  final String sessionId;
  final String captureAttemptId;
  final String segmentId;
  final int transcriptRevision;
  final String text;
  final String sourceLanguageCode;
  final String targetLanguageCode;
}

/// Result from one translation attempt. The identity fields let a segment
/// reject late results from an older transcript, another session, or a retry.
final class SubtitleTranslationResult {
  SubtitleTranslationResult({
    required this.requestId,
    required this.sessionId,
    required this.captureAttemptId,
    required this.segmentId,
    required this.transcriptRevision,
    required this.sourceLanguageCode,
    required this.targetLanguageCode,
    this.translatedText,
    this.errorCode,
  }) {
    _requireNonEmpty(requestId, 'requestId');
    _requireNonEmpty(sessionId, 'sessionId');
    _requireNonEmpty(captureAttemptId, 'captureAttemptId');
    _requireNonEmpty(segmentId, 'segmentId');
    _requireNonEmpty(sourceLanguageCode, 'sourceLanguageCode');
    _requireNonEmpty(targetLanguageCode, 'targetLanguageCode');
    if (transcriptRevision < 0) {
      throw ArgumentError.value(
        transcriptRevision,
        'transcriptRevision',
        'Must be non-negative.',
      );
    }

    final hasTranslation = translatedText?.trim().isNotEmpty ?? false;
    final hasError = errorCode?.trim().isNotEmpty ?? false;
    if (hasTranslation == hasError) {
      throw ArgumentError(
        'Provide exactly one non-empty translatedText or errorCode.',
      );
    }
  }

  final String requestId;
  final String sessionId;
  final String captureAttemptId;
  final String segmentId;
  final int transcriptRevision;
  final String sourceLanguageCode;
  final String targetLanguageCode;
  final String? translatedText;
  final String? errorCode;
}

/// Recognition and translation state for one stable subtitle timeline entry.
final class SubtitleSegment {
  SubtitleSegment._({
    required this.transcript,
    required this.translationStatus,
    this.translationRequest,
    this.translatedText,
    this.translationErrorCode,
  });

  factory SubtitleSegment.fromTranscript(
    TranscriptRevision transcript, {
    bool translationEnabled = true,
  }) {
    final status = !transcript.isFinal
        ? SubtitleTranslationStatus.awaitingFinal
        : transcript.text.trim().isEmpty
        ? SubtitleTranslationStatus.skippedEmpty
        : !AsrLanguageRegistry.isSupportedCode(transcript.languageCode)
        ? SubtitleTranslationStatus.skippedUnsupportedLanguage
        : !translationEnabled
        ? SubtitleTranslationStatus.skippedDisabled
        : SubtitleTranslationStatus.awaitingQueue;

    return SubtitleSegment._(transcript: transcript, translationStatus: status);
  }

  /// Recreates one finalized history entry. No live request ID is restored;
  /// untranslated entries can be queued again by a future session workflow.
  factory SubtitleSegment.fromStoredFinalTranscript(
    TranscriptRevision transcript, {
    String? translatedText,
    bool translationDisabled = false,
    String? targetLanguageCode,
  }) {
    if (!transcript.isFinal || transcript.text.trim().isEmpty) {
      throw ArgumentError(
        'Only non-empty finalized transcript revisions can be restored.',
      );
    }
    final normalizedTranslation = translatedText?.trim();
    if (normalizedTranslation != null && normalizedTranslation.isNotEmpty) {
      return SubtitleSegment._(
        transcript: transcript,
        translationStatus: SubtitleTranslationStatus.translated,
        translatedText: normalizedTranslation,
      );
    }
    if (translationDisabled) {
      return SubtitleSegment._(
        transcript: transcript,
        translationStatus: SubtitleTranslationStatus.skippedDisabled,
      );
    }
    if (!AsrLanguageRegistry.isSupportedCode(transcript.languageCode)) {
      return SubtitleSegment._(
        transcript: transcript,
        translationStatus: SubtitleTranslationStatus.skippedUnsupportedLanguage,
      );
    }
    if (targetLanguageCode != null &&
        AsrLanguageRegistry.normalizeCode(transcript.languageCode) ==
            AsrLanguageRegistry.normalizeCode(targetLanguageCode)) {
      return SubtitleSegment._(
        transcript: transcript,
        translationStatus: SubtitleTranslationStatus.skippedSameLanguage,
      );
    }
    return SubtitleSegment._(
      transcript: transcript,
      translationStatus: SubtitleTranslationStatus.awaitingQueue,
    );
  }

  /// Keeps a finalized cue when its recognized language is already the
  /// requested target language, without sending it through a translator.
  SubtitleSegment skipTranslationSameLanguage() => SubtitleSegment._(
    transcript: transcript,
    translationStatus: SubtitleTranslationStatus.skippedSameLanguage,
  );

  final TranscriptRevision transcript;
  final SubtitleTranslationStatus translationStatus;
  final SubtitleTranslationRequest? translationRequest;
  final String? translatedText;
  final String? translationErrorCode;

  SubtitleSegmentKey get key => SubtitleSegmentKey(
    sessionId: transcript.sessionId,
    captureAttemptId: transcript.captureAttemptId,
    segmentId: transcript.segmentId,
    sourceId: transcript.sourceId,
    sourceKind: transcript.sourceKind,
  );

  String? get translationRequestId => translationRequest?.requestId;

  /// Whether this revision contains a stable, non-empty phrase to translate.
  bool get canTranslate =>
      transcript.isFinal &&
      transcript.text.trim().isNotEmpty &&
      AsrLanguageRegistry.isSupportedCode(transcript.languageCode);

  /// Applies a newer recognition revision without changing its compound key.
  ///
  /// Duplicate/older revisions and late interim revisions after finalization
  /// are ignored. A newer final correction clears any in-flight or completed
  /// translation so the old text cannot appear beside the corrected transcript.
  SubtitleSegment applyTranscriptRevision(
    TranscriptRevision next, {
    bool translationEnabled = true,
  }) {
    if (next.sessionId != transcript.sessionId ||
        next.captureAttemptId != transcript.captureAttemptId ||
        next.segmentId != transcript.segmentId ||
        next.sourceId != transcript.sourceId ||
        next.sourceKind != transcript.sourceKind) {
      throw ArgumentError(
        'A revision must keep the current '
        '(sessionId, captureAttemptId, sourceId, sourceKind, segmentId) key.',
      );
    }
    if (next.sourceId != transcript.sourceId ||
        next.sourceKind != transcript.sourceKind) {
      throw ArgumentError('A revision must keep the current audio source.');
    }
    if (next.revision <= transcript.revision) return this;
    if (transcript.isFinal && !next.isFinal) return this;

    return SubtitleSegment.fromTranscript(
      next,
      translationEnabled: translationEnabled,
    );
  }

  /// Marks a request queued only after the bounded queue has accepted it.
  SubtitleSegment markQueued(SubtitleTranslationRequest request) {
    _requireMatchingTranscript(request);
    if (!canTranslate) {
      throw StateError('Only finalized non-empty transcript revisions queue.');
    }
    if (translationStatus != SubtitleTranslationStatus.awaitingQueue &&
        translationStatus != SubtitleTranslationStatus.failed &&
        translationStatus != SubtitleTranslationStatus.cancelled) {
      throw StateError('This subtitle segment is not ready to be queued.');
    }
    if (request.requestId == translationRequestId) {
      throw ArgumentError('Each translation attempt needs a new requestId.');
    }

    return SubtitleSegment._(
      transcript: transcript,
      translationStatus: SubtitleTranslationStatus.queued,
      translationRequest: request,
    );
  }

  /// Marks the currently queued request as active. Stale queue callbacks are
  /// ignored if a newer transcript revision or retry has replaced the request.
  SubtitleSegment markTranslating(SubtitleTranslationRequest request) {
    if (!_matchesTranscript(request) ||
        !_matchesRequest(request) ||
        translationStatus != SubtitleTranslationStatus.queued) {
      return this;
    }

    return SubtitleSegment._(
      transcript: transcript,
      translationStatus: SubtitleTranslationStatus.translating,
      translationRequest: translationRequest,
    );
  }

  /// Cancels a queued or active request and invalidates any result that arrives
  /// after cancellation. The segment can be explicitly queued again later.
  SubtitleSegment cancelTranslation({required String requestId}) {
    if (requestId != translationRequestId ||
        (translationStatus != SubtitleTranslationStatus.queued &&
            translationStatus != SubtitleTranslationStatus.translating)) {
      return this;
    }

    return SubtitleSegment._(
      transcript: transcript,
      translationStatus: SubtitleTranslationStatus.cancelled,
      translationRequest: translationRequest,
    );
  }

  /// Applies a result only to the exact transcript/request that produced it.
  /// Late results after a correction, retry, or session change leave this
  /// segment unchanged.
  SubtitleSegment applyTranslationResult(SubtitleTranslationResult result) {
    if (result.sessionId != transcript.sessionId ||
        result.captureAttemptId != transcript.captureAttemptId ||
        result.segmentId != transcript.segmentId ||
        result.transcriptRevision != transcript.revision ||
        result.requestId != translationRequestId ||
        result.sourceLanguageCode != transcript.languageCode ||
        result.targetLanguageCode != translationRequest?.targetLanguageCode ||
        translationStatus != SubtitleTranslationStatus.translating) {
      return this;
    }

    final translatedText = result.translatedText;
    if (translatedText != null) {
      return SubtitleSegment._(
        transcript: transcript,
        translationStatus: SubtitleTranslationStatus.translated,
        translationRequest: translationRequest,
        translatedText: translatedText,
      );
    }

    return SubtitleSegment._(
      transcript: transcript,
      translationStatus: SubtitleTranslationStatus.failed,
      translationRequest: translationRequest,
      translationErrorCode: result.errorCode,
    );
  }

  bool _matchesTranscript(SubtitleTranslationRequest request) =>
      request.sessionId == transcript.sessionId &&
      request.captureAttemptId == transcript.captureAttemptId &&
      request.segmentId == transcript.segmentId &&
      request.transcriptRevision == transcript.revision &&
      request.text == transcript.text &&
      request.sourceLanguageCode == transcript.languageCode;

  bool _matchesRequest(SubtitleTranslationRequest request) {
    final current = translationRequest;
    return current != null &&
        request.requestId == current.requestId &&
        request.sessionId == current.sessionId &&
        request.captureAttemptId == current.captureAttemptId &&
        request.segmentId == current.segmentId &&
        request.transcriptRevision == current.transcriptRevision &&
        request.text == current.text &&
        request.sourceLanguageCode == current.sourceLanguageCode &&
        request.targetLanguageCode == current.targetLanguageCode;
  }

  void _requireMatchingTranscript(SubtitleTranslationRequest request) {
    if (!_matchesTranscript(request)) {
      throw ArgumentError(
        'The translation request must match the current transcript revision.',
      );
    }
  }
}

/// Stable identity for one subtitle segment within one capture attempt and
/// audio source.
///
/// A resumed session receives a new capture attempt ID so callbacks from an
/// earlier attempt cannot overwrite the resumed timeline.
final class SubtitleSegmentKey {
  SubtitleSegmentKey({
    required this.sessionId,
    required this.captureAttemptId,
    required this.segmentId,
    this.sourceId = 'legacy-source',
    this.sourceKind = SubtitleAudioSourceKind.systemOutput,
  }) {
    _requireNonEmpty(sessionId, 'sessionId');
    _requireNonEmpty(captureAttemptId, 'captureAttemptId');
    _requireNonEmpty(segmentId, 'segmentId');
    _requireNonEmpty(sourceId, 'sourceId');
  }

  final String sessionId;
  final String captureAttemptId;
  final String segmentId;
  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;

  @override
  bool operator ==(Object other) =>
      other is SubtitleSegmentKey &&
      other.sessionId == sessionId &&
      other.captureAttemptId == captureAttemptId &&
      other.segmentId == segmentId &&
      other.sourceId == sourceId &&
      other.sourceKind == sourceKind;

  @override
  int get hashCode =>
      Object.hash(sessionId, captureAttemptId, sourceId, sourceKind, segmentId);
}

void _requireNonEmpty(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}
