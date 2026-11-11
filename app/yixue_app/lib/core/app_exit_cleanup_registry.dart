import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Registers page-owned work that must finish before the desktop process exits.
///
/// The active page owns microphone and system-audio resources. Keeping this
/// small registry in core lets the window lifecycle await that cleanup without
/// depending on a particular feature page.
typedef AppExitCleanup = Future<void> Function();

final class AppExitCleanupCancellation {
  final Completer<void> _cancelled = Completer<void>();
  var _isCancelled = false;

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
  }
}

final class AppExitCleanupCancelled implements Exception {
  const AppExitCleanupCancelled();
}

/// Turns a returned native failure state into a cleanup error the close flow
/// can show to the user.
void throwIfExitCleanupFailed({required bool failed, required String message}) {
  if (failed) throw StateError(message);
}

/// Runs dependent exit steps in order while still attempting every step.
///
/// Cleanup steps such as stopping screen capture, stopping audio, saving the
/// transcript, and finalizing recordings must not prevent one another from
/// running when an earlier native operation fails.
Future<void> runExitCleanupSteps(
  Iterable<AppExitCleanup> steps, {
  AppExitCleanupCancellation? cancellation,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final step in steps) {
    if (cancellation?.isCancelled ?? false) {
      throw const AppExitCleanupCancelled();
    }
    if (cancellation == null) {
      try {
        await step();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
      continue;
    }

    final completed = Object();
    final cancelled = Object();
    final outcome = await Future.any<Object>([
      Future<void>.sync(step).then<Object>(
        (_) => completed,
        onError: (Object error, StackTrace stackTrace) =>
            _CleanupFailure(error, stackTrace),
      ),
      cancellation.whenCancelled.then<Object>((_) => cancelled),
    ]);
    if (identical(outcome, cancelled)) {
      throw const AppExitCleanupCancelled();
    }
    if (outcome is _CleanupFailure) {
      firstError ??= outcome.error;
      firstStackTrace ??= outcome.stackTrace;
    }
  }
  if (cancellation?.isCancelled ?? false) {
    throw const AppExitCleanupCancelled();
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

final class AppExitCleanupRegistry {
  AppExitCleanupRegistry._();

  static final Map<Object, _AppExitCleanupEntry> _entries = {};
  static AppExitCleanupCancellation? _activeCancellation;
  static File? _diagnosticFile;
  static File? _subtitleDiagnosticFile;
  static Future<void> _diagnosticTail = Future<void>.value();
  static Future<void> _subtitleDiagnosticTail = Future<void>.value();
  static const _subtitleDiagnosticPhases = <String>{
    'translation_route',
    'translation_model_warmup',
    'audio_recording_start',
    'capture_asr_start',
    'session_pause',
    'session_resume',
    'session_stop',
    'audio_recording_finalize',
    'subtitle_window_open',
  };
  static const _subtitleDiagnosticStatuses = <String>{
    'begin',
    'success',
    'failure',
    'cancelled',
    'skipped',
  };
  static final _safeDiagnosticToken = RegExp(r'^[A-Za-z0-9_-]{1,96}$');

  /// Writes low-detail lifecycle events to a local diagnostic file.
  ///
  /// Only fixed event names, elapsed time, and error types are recorded; user
  /// content, paths, and exception messages are intentionally excluded.
  static void configureDiagnosticFile(File? file) {
    _diagnosticFile = file;
    _subtitleDiagnosticFile = file == null
        ? null
        : File(
            [
              file.parent.path,
              'subtitle-session.jsonl',
            ].join(Platform.pathSeparator),
          );
  }

  static Future<void> recordEvent(String event) async {
    try {
      await _writeDiagnostic(event).timeout(const Duration(milliseconds: 150));
    } on Object {
      // Shutdown diagnostics are best effort and must never hold shutdown.
    }
  }

  /// Writes only stage, outcome, timing, and safe error identifiers for
  /// simultaneous-session recovery. It never accepts media or transcript data.
  static Future<void> recordSubtitleSessionPhase({
    required String sessionId,
    required String phase,
    required String status,
    int? elapsedMilliseconds,
    String? errorCode,
    String? errorType,
  }) async {
    final file = _subtitleDiagnosticFile;
    if (file == null ||
        !_subtitleDiagnosticPhases.contains(phase) ||
        !_subtitleDiagnosticStatuses.contains(status)) {
      return;
    }

    final event = <String, Object?>{
      'timestamp_utc': DateTime.now().toUtc().toIso8601String(),
      'event': 'subtitle_session_phase',
      'session_id': _safeDiagnosticToken.hasMatch(sessionId)
          ? sessionId
          : 'unavailable',
      'phase': phase,
      'status': status,
      if (elapsedMilliseconds != null && elapsedMilliseconds >= 0)
        'elapsed_ms': elapsedMilliseconds,
      if (errorCode != null && _safeDiagnosticToken.hasMatch(errorCode))
        'error_code': errorCode,
      if (errorType != null && _safeDiagnosticToken.hasMatch(errorType))
        'error_type': errorType,
    };
    final line = '${jsonEncode(event)}\n';
    final previous = _subtitleDiagnosticTail;
    final next = previous.then((_) async {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(
          line,
          mode: FileMode.append,
          encoding: utf8,
          flush: true,
        );
      } on Object {
        // Diagnostics must never prevent capture, translation, or shutdown.
      }
    }, onError: (Object _, StackTrace _) {});
    _subtitleDiagnosticTail = next;
    try {
      await next.timeout(const Duration(milliseconds: 150));
    } on Object {
      // Session diagnostics are best effort and must never hold shutdown.
    }
  }

  static Future<void> _writeDiagnostic(String event) async {
    final file = _diagnosticFile;
    if (file == null) return;
    final line = '${DateTime.now().toIso8601String()} $event\n';
    final previous = _diagnosticTail;
    final next = previous.then((_) async {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(
          line,
          mode: FileMode.append,
          encoding: utf8,
          flush: true,
        );
      } on Object {
        // Diagnostics must never prevent the application from closing.
      }
    }, onError: (Object _, StackTrace _) {});
    _diagnosticTail = next;
    await next;
  }

  static AppExitCleanupCancellation? get activeCancellation =>
      _activeCancellation;

  static void cancelPendingPreparation() => _activeCancellation?.cancel();

  static void Function() register(
    AppExitCleanup cleanup, {
    String name = 'unnamed',
  }) {
    final token = Object();
    _entries[token] = _AppExitCleanupEntry(name: name, cleanup: cleanup);
    return () {
      _entries.remove(token);
    };
  }

  static Future<void> prepareForExit() async {
    final cancellation = AppExitCleanupCancellation();
    _activeCancellation = cancellation;
    final cleanups = List<_AppExitCleanupEntry>.of(_entries.values);
    final failures = <_CleanupFailure>[];
    await recordEvent('prepare_begin cleanup_count=${cleanups.length}');
    try {
      await Future.wait(
        cleanups.map((entry) async {
          final stopwatch = Stopwatch()..start();
          await recordEvent('cleanup_begin name=${entry.name}');
          try {
            await entry.cleanup();
            await recordEvent(
              'cleanup_end name=${entry.name} elapsed_ms=${stopwatch.elapsedMilliseconds} status=ok',
            );
          } catch (error, stackTrace) {
            failures.add(_CleanupFailure(error, stackTrace));
            await recordEvent(
              'cleanup_end name=${entry.name} '
              'elapsed_ms=${stopwatch.elapsedMilliseconds} '
              'status=error type=${error.runtimeType}',
            );
          }
        }),
      );
      if (failures.isNotEmpty) {
        final firstFailure = failures.first;
        await recordEvent(
          'prepare_end status=error failure_count=${failures.length}',
        );
        Error.throwWithStackTrace(firstFailure.error, firstFailure.stackTrace);
      }
      await recordEvent('prepare_end status=ok');
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }
    }
  }
}

final class _AppExitCleanupEntry {
  const _AppExitCleanupEntry({required this.name, required this.cleanup});

  final String name;
  final AppExitCleanup cleanup;
}

final class _CleanupFailure {
  const _CleanupFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
