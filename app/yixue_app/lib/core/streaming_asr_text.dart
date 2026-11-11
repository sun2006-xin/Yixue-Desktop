/// Resolves text emitted by an online recognizer for a single subtitle segment.
///
/// Some decoders return an empty final result after previously yielding a
/// non-empty partial. In that case, keep the last partial as the final text so
/// a higher-revision empty event cannot erase a usable subtitle.
String? resolveStreamingAsrText({
  required String decodedText,
  required String previousText,
  required bool isFinal,
}) {
  final normalized = decodedText.trim();
  if (normalized.isNotEmpty) return normalized;

  if (!isFinal) return null;
  final previous = previousText.trim();
  return previous.isEmpty ? null : previous;
}
