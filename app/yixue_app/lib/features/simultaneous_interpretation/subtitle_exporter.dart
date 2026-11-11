import 'subtitle_session_contract.dart';

enum SubtitleExportFormat { srt, webVtt }

/// One standards-compatible subtitle export. The segment keys are returned
/// alongside the text so callers can preserve the mapping to local history.
final class SubtitleExportDocument {
  const SubtitleExportDocument({
    required this.format,
    required this.sessionId,
    required this.content,
    required this.segmentKeys,
  });

  final SubtitleExportFormat format;
  final String sessionId;
  final String content;
  final List<SubtitleSegmentKey> segmentKeys;
}

/// Encodes one session's confirmed subtitle timeline as SRT or WebVTT.
/// Original text remains available if translation is pending or failed.
final class SubtitleExporter {
  const SubtitleExporter();

  SubtitleExportDocument toSrt(
    String sessionId,
    Iterable<SubtitleSegment> segments, {
    bool includeOriginal = true,
    bool includeTranslation = true,
  }) => _encode(
    sessionId,
    segments,
    format: SubtitleExportFormat.srt,
    includeOriginal: includeOriginal,
    includeTranslation: includeTranslation,
  );

  SubtitleExportDocument toWebVtt(
    String sessionId,
    Iterable<SubtitleSegment> segments, {
    bool includeOriginal = true,
    bool includeTranslation = true,
  }) => _encode(
    sessionId,
    segments,
    format: SubtitleExportFormat.webVtt,
    includeOriginal: includeOriginal,
    includeTranslation: includeTranslation,
  );

  SubtitleExportDocument _encode(
    String sessionId,
    Iterable<SubtitleSegment> segments, {
    required SubtitleExportFormat format,
    required bool includeOriginal,
    required bool includeTranslation,
  }) {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Must not be empty.');
    }
    if (!includeOriginal && !includeTranslation) {
      throw ArgumentError('At least one subtitle language must be included.');
    }

    final cues =
        segments
            .where(
              (segment) =>
                  segment.transcript.sessionId == sessionId &&
                  segment.canTranslate,
            )
            .map(
              (segment) => _ExportCue(
                segment,
                _cueText(
                  segment,
                  includeOriginal: includeOriginal,
                  includeTranslation: includeTranslation,
                ),
              ),
            )
            .where((cue) => cue.text.isNotEmpty)
            .toList(growable: false)
          ..sort((left, right) {
            final transcriptOrder = left.segment.transcript.startMs.compareTo(
              right.segment.transcript.startMs,
            );
            if (transcriptOrder != 0) return transcriptOrder;
            final endOrder = left.segment.transcript.endMs.compareTo(
              right.segment.transcript.endMs,
            );
            if (endOrder != 0) return endOrder;
            final attemptOrder = left.segment.transcript.captureAttemptId
                .compareTo(right.segment.transcript.captureAttemptId);
            if (attemptOrder != 0) return attemptOrder;
            return left.segment.transcript.segmentId.compareTo(
              right.segment.transcript.segmentId,
            );
          });

    final buffer = StringBuffer();
    if (format == SubtitleExportFormat.webVtt) {
      buffer.writeln('WEBVTT');
      if (cues.isNotEmpty) buffer.writeln();
    }
    for (var index = 0; index < cues.length; index += 1) {
      final cue = cues[index];
      if (index > 0) buffer.writeln();
      if (format == SubtitleExportFormat.srt) {
        buffer.writeln(index + 1);
        buffer.writeln(
          '${_formatTimestamp(cue.segment.transcript.startMs, decimalSeparator: ',')} --> '
          '${_formatTimestamp(cue.segment.transcript.endMs, decimalSeparator: ',')}',
        );
      } else {
        buffer.writeln(_webVttCueId(cue.segment.key));
        buffer.writeln(
          '${_formatTimestamp(cue.segment.transcript.startMs, decimalSeparator: '.')} --> '
          '${_formatTimestamp(cue.segment.transcript.endMs, decimalSeparator: '.')}',
        );
      }
      buffer.write(cue.text);
      buffer.write('\n');
    }

    return SubtitleExportDocument(
      format: format,
      sessionId: sessionId,
      content: buffer.toString(),
      segmentKeys: List<SubtitleSegmentKey>.unmodifiable(
        cues.map((cue) => cue.segment.key),
      ),
    );
  }

  String _cueText(
    SubtitleSegment segment, {
    required bool includeOriginal,
    required bool includeTranslation,
  }) {
    final lines = <String>[];
    final original = includeOriginal
        ? _normalizeText(segment.transcript.text)
        : '';
    if (original.isNotEmpty) lines.add(original);
    final translation =
        includeTranslation &&
            segment.translationStatus == SubtitleTranslationStatus.translated
        ? _normalizeText(segment.translatedText ?? '')
        : '';
    if (translation.isNotEmpty) lines.add(translation);
    return lines.join('\n');
  }

  String _formatTimestamp(
    int milliseconds, {
    required String decimalSeparator,
  }) {
    final hours = milliseconds ~/ 3600000;
    final minutes = milliseconds ~/ 60000 % 60;
    final seconds = milliseconds ~/ 1000 % 60;
    final remainder = milliseconds % 1000;
    return '${_twoDigits(hours)}:${_twoDigits(minutes)}:${_twoDigits(seconds)}'
        '$decimalSeparator${remainder.toString().padLeft(3, '0')}';
  }

  String _webVttCueId(SubtitleSegmentKey key) {
    String safe(String value) =>
        value.replaceAll(RegExp(r'[\r\n]'), '_').replaceAll('-->', '_').trim();

    return '${safe(key.sessionId)}:${safe(key.captureAttemptId)}:${safe(key.segmentId)}';
  }

  String _normalizeText(String value) =>
      value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();

  String _twoDigits(int value) => value.toString().padLeft(2, '0');
}

final class _ExportCue {
  const _ExportCue(this.segment, this.text);

  final SubtitleSegment segment;
  final String text;
}
