/// Result of asking the native capture adapter to stop every source which may
/// have started in an audio-only session.
final class AudioCaptureStopResult<T> {
  const AudioCaptureStopResult({
    required this.stoppedSources,
    required this.failedSources,
  });

  final List<T> stoppedSources;
  final List<T> failedSources;

  bool get allStopped => failedSources.isEmpty;
}

/// Stops sources in reverse start order and keeps the ones whose shutdown
/// could not be confirmed so the caller can retain a retry path.
Future<AudioCaptureStopResult<T>> stopCaptureSources<T>(
  Iterable<T> attemptedSources,
  Future<void> Function(T source) stopSource,
) async {
  final stopped = <T>[];
  final failed = <T>[];
  for (final source in attemptedSources.toList().reversed) {
    try {
      await stopSource(source);
      stopped.add(source);
    } on Object {
      failed.add(source);
    }
  }
  return AudioCaptureStopResult<T>(
    stoppedSources: List<T>.unmodifiable(stopped),
    failedSources: List<T>.unmodifiable(failed),
  );
}
