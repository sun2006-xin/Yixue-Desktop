import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/app_exit_cleanup_registry.dart';

void main() {
  test('records named exit cleanup timing without exception details', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-exit-diagnostics-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}exit.log');
    AppExitCleanupRegistry.configureDiagnosticFile(file);
    final unregister = AppExitCleanupRegistry.register(() async {
      throw StateError('private payload must not be written');
    }, name: 'test.cleanup');

    try {
      await expectLater(
        AppExitCleanupRegistry.prepareForExit(),
        throwsA(isA<StateError>()),
      );
      final log = await file.readAsString();
      expect(log, contains('cleanup_begin name=test.cleanup'));
      expect(log, contains('cleanup_end name=test.cleanup'));
      expect(log, contains('status=error type=StateError'));
      expect(log, isNot(contains('private payload')));
    } finally {
      unregister();
      AppExitCleanupRegistry.configureDiagnosticFile(null);
      await directory.delete(recursive: true);
    }
  });

  test(
    'writes structured subtitle phases to a private local JSONL log',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-subtitle-diagnostics-',
      );
      final exitLog = File(
        '${directory.path}${Platform.pathSeparator}exit.log',
      );
      final subtitleLog = File(
        '${directory.path}${Platform.pathSeparator}subtitle-session.jsonl',
      );
      AppExitCleanupRegistry.configureDiagnosticFile(exitLog);

      try {
        await AppExitCleanupRegistry.recordSubtitleSessionPhase(
          sessionId: 'session-test-17',
          phase: 'capture_asr_start',
          status: 'failure',
          elapsedMilliseconds: 83,
          errorCode: 'capture_start_failed',
          errorType: 'PlatformException',
        );

        final event = jsonDecode(await subtitleLog.readAsString()) as Map;
        expect(event['event'], 'subtitle_session_phase');
        expect(event['session_id'], 'session-test-17');
        expect(event['phase'], 'capture_asr_start');
        expect(event['status'], 'failure');
        expect(event['elapsed_ms'], 83);
        expect(event['error_code'], 'capture_start_failed');
        expect(event['error_type'], 'PlatformException');
        expect(event, isNot(contains('transcript')));
      } finally {
        AppExitCleanupRegistry.configureDiagnosticFile(null);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'exit cleanup steps continue in order after a native capture failure',
    () async {
      final events = <String>[];

      await expectLater(
        runExitCleanupSteps([
          () async {
            events.add('stop screen');
            throw StateError('screen stop failed');
          },
          () async => events.add('stop audio'),
          () async => events.add('save subtitles'),
          () async => events.add('finalize recording'),
        ]),
        throwsA(isA<StateError>()),
      );

      expect(events, [
        'stop screen',
        'stop audio',
        'save subtitles',
        'finalize recording',
      ]);
    },
  );

  test(
    'a failed recording finalization reaches the exit cleanup decision',
    () async {
      final events = <String>[];

      await expectLater(
        runExitCleanupSteps([
          () async {
            final recorderStatus = 'failed';
            throwIfExitCleanupFailed(
              failed: recorderStatus == 'failed',
              message: 'audio recording could not be finalized',
            );
          },
          () async => events.add('subtitle save still runs'),
        ]),
        throwsA(isA<StateError>()),
      );

      expect(events, ['subtitle save still runs']);
    },
  );

  test(
    'cancelling an exit step prevents later cleanup steps from starting',
    () async {
      final stepStarted = Completer<void>();
      final allowStepToFinish = Completer<void>();
      final events = <String>[];
      final cancellation = AppExitCleanupCancellation();

      final cleanup = runExitCleanupSteps([
        () async {
          events.add('step started');
          stepStarted.complete();
          await allowStepToFinish.future;
          events.add('step finished');
        },
        () async => events.add('later step'),
      ], cancellation: cancellation);

      await stepStarted.future;
      cancellation.cancel();
      await expectLater(cleanup, throwsA(isA<AppExitCleanupCancelled>()));
      allowStepToFinish.complete();
      await Future<void>.delayed(Duration.zero);

      expect(events, ['step started', 'step finished']);
    },
  );

  test(
    'registry exposes and clears the active exit cancellation token',
    () async {
      final cleanupStarted = Completer<void>();
      final cleanupCancelled = Completer<void>();
      final unregister = AppExitCleanupRegistry.register(() async {
        cleanupStarted.complete();
        await AppExitCleanupRegistry.activeCancellation!.whenCancelled;
        cleanupCancelled.complete();
      });

      try {
        final cleanup = AppExitCleanupRegistry.prepareForExit();
        await cleanupStarted.future;
        final cancellation = AppExitCleanupRegistry.activeCancellation;
        expect(cancellation, isNotNull);
        cancellation!.cancel();
        await cleanup;
        await cleanupCancelled.future;
        expect(AppExitCleanupRegistry.activeCancellation, isNull);
      } finally {
        unregister();
      }
    },
  );

  test('runs every registered cleanup in order until unregistered', () async {
    final events = <String>[];
    final unregisterFirst = AppExitCleanupRegistry.register(() async {
      events.add('first');
    });
    final unregisterSecond = AppExitCleanupRegistry.register(() async {
      events.add('second');
    });

    try {
      unregisterFirst();
      await AppExitCleanupRegistry.prepareForExit();

      expect(events, ['second']);
    } finally {
      unregisterFirst();
      unregisterSecond();
    }
  });

  test(
    'continues cleanup after a failure and rethrows the first failure',
    () async {
      final events = <String>[];
      final unregisterFailure = AppExitCleanupRegistry.register(() async {
        events.add('failure');
        throw StateError('first cleanup failed');
      });
      final unregisterLast = AppExitCleanupRegistry.register(() async {
        events.add('last');
      });

      try {
        await expectLater(
          AppExitCleanupRegistry.prepareForExit(),
          throwsA(isA<StateError>()),
        );

        expect(events, ['failure', 'last']);
      } finally {
        unregisterFailure();
        unregisterLast();
      }
    },
  );

  test(
    'starts independent cleanup while another resource is still stopping',
    () async {
      final firstStarted = Completer<void>();
      final firstGate = Completer<void>();
      final events = <String>[];
      final unregisterSlow = AppExitCleanupRegistry.register(() async {
        firstStarted.complete();
        await firstGate.future;
      });
      final unregisterOther = AppExitCleanupRegistry.register(() async {
        events.add('other');
      });

      try {
        final cleanup = AppExitCleanupRegistry.prepareForExit();
        await firstStarted.future;
        await Future<void>.delayed(Duration.zero);
        final otherStartedBeforeRelease = events.contains('other');
        firstGate.complete();
        await cleanup;

        expect(otherStartedBeforeRelease, isTrue);
      } finally {
        if (!firstGate.isCompleted) firstGate.complete();
        unregisterSlow();
        unregisterOther();
      }
    },
  );
}
