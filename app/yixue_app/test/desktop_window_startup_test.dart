import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/desktop_window_startup.dart';

void main() {
  test(
    'bounds desktop window preparation so app startup can continue',
    () async {
      final neverInitializes = Completer<void>();
      var configureCalled = false;

      await expectLater(
        prepareMainDesktopWindow(
          initialize: () => neverInitializes.future,
          configure: () async => configureCalled = true,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(configureCalled, isFalse);
    },
  );

  test('bounds window presentation and reports a terminal failure', () async {
    final neverShows = Completer<void>();
    var recoveryCalled = false;

    final stopwatch = Stopwatch()..start();
    final presented = await showMainWindowAfterFirstRasterizedFrame(
      firstFrameRasterized: Future<void>.value(),
      prepareWindow: () async {},
      showWindow: () => neverShows.future,
      focusWindow: () async {},
      isWindowVisible: () async => false,
      windowOperationTimeout: const Duration(milliseconds: 20),
      onPresentationFailure: (error, stackTrace) async {
        recoveryCalled = true;
        return false;
      },
    );

    expect(presented, isFalse);
    expect(recoveryCalled, isTrue);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 300)));
  });

  test('shows the desktop window only after the first Flutter frame', () async {
    final firstFrameRasterized = Completer<void>();
    final events = <String>[];

    final showWindow = showMainWindowAfterFirstRasterizedFrame(
      firstFrameRasterized: firstFrameRasterized.future,
      prepareWindow: () async => events.add('prepare'),
      showWindow: () async => events.add('show'),
      focusWindow: () async => events.add('focus'),
      isWindowVisible: () async => true,
      onPresentationFailure: (error, stackTrace) async {
        events.add('recover');
        return true;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);

    firstFrameRasterized.complete();
    await showWindow;

    expect(events, <String>['prepare', 'show', 'focus']);
  });

  test('does not reveal the native window when Flutter frame fails', () async {
    final events = <String>[];

    await expectLater(
      showMainWindowAfterFirstRasterizedFrame(
        firstFrameRasterized: Future<void>.error(StateError('raster failed')),
        prepareWindow: () async => events.add('prepare'),
        showWindow: () async => events.add('show'),
        focusWindow: () async => events.add('focus'),
        isWindowVisible: () async => true,
        onPresentationFailure: (error, stackTrace) async {
          events.add('recover');
          return true;
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(events, isEmpty);
  });

  test(
    'recovers visibility only after the first Flutter frame exists',
    () async {
      final events = <String>[];

      final presented = await showMainWindowAfterFirstRasterizedFrame(
        firstFrameRasterized: Future<void>.value(),
        prepareWindow: () async =>
            throw StateError('window preparation failed'),
        showWindow: () async => events.add('show'),
        focusWindow: () async => events.add('focus'),
        isWindowVisible: () async => true,
        onPresentationFailure: (error, stackTrace) async {
          events.add('recover');
          events.add('fallback-show');
          events.add('fallback-focus');
          return true;
        },
      );

      expect(presented, isTrue);
      expect(events, <String>['recover', 'fallback-show', 'fallback-focus']);
    },
  );

  test(
    'does not signal the supervisor before the window is presented',
    () async {
      final windowPresented = Completer<void>();
      final events = <String>[];

      final signal = signalSupervisorReadyAfterPresentation(
        windowPresented: windowPresented.future,
        signalReady: () async => events.add('ready'),
      );

      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      windowPresented.complete();
      await signal;

      expect(events, <String>['ready']);
    },
  );

  test(
    'does not signal the supervisor if presentation never succeeds',
    () async {
      final events = <String>[];

      await expectLater(
        signalSupervisorReadyAfterPresentation(
          windowPresented: Future<void>.error(
            StateError('window stayed hidden'),
          ),
          signalReady: () async => events.add('ready'),
        ),
        throwsA(isA<StateError>()),
      );

      expect(events, isEmpty);
    },
  );

  test(
    'a late first frame can still reveal the window and signal startup ready',
    () async {
      final windowPresentation = Completer<bool>();
      final supervisorWindowPresented = Completer<void>();
      final events = <String>[];
      final readiness = signalSupervisorReadyAfterPresentation(
        windowPresented: supervisorWindowPresented.future,
        signalReady: () async => events.add('ready'),
      );

      final presentationResult = await observeSupervisorWindowPresentation(
        windowPresentation: windowPresentation.future,
        supervisorWindowPresented: supervisorWindowPresented,
        timeout: const Duration(milliseconds: 10),
        firstFrameRasterized: Future<void>.value(),
        onTimeout: () => events.add('timeout'),
        onFailure: (error, stackTrace) => events.add('failure'),
      );

      expect(presentationResult, isNull);
      expect(events, <String>['timeout']);

      windowPresentation.complete(true);
      await readiness;

      expect(events, <String>['timeout', 'ready']);
    },
  );

  test('a native window that becomes visible after presentation failure still signals ready', () async {
    var visible = false;
    final firstFrameRasterized = Completer<void>();
    final supervisorWindowPresented = Completer<void>();
    final events = <String>[];

    final presentationResult = await observeSupervisorWindowPresentation(
      windowPresentation: Future<bool>.value(false),
      supervisorWindowPresented: supervisorWindowPresented,
      timeout: const Duration(milliseconds: 20),
      firstFrameRasterized: firstFrameRasterized.future,
      visibilityPollInterval: const Duration(milliseconds: 2),
      isWindowVisible: () async => visible,
      onTimeout: () => events.add('timeout'),
      onFailure: (error, stackTrace) => events.add('failure'),
    );

    expect(presentationResult, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(supervisorWindowPresented.isCompleted, isFalse);
    firstFrameRasterized.complete();
    await Future<void>.delayed(const Duration(milliseconds: 12));
    visible = true;
    await supervisorWindowPresented.future.timeout(const Duration(seconds: 1));

    expect(events, isEmpty);
    expect(supervisorWindowPresented.isCompleted, isTrue);
  });

  test(
    'a visible native window cannot signal ready if the first frame failed',
    () async {
      var visible = false;
      final firstFrameRasterized = Completer<void>();
      final supervisorWindowPresented = Completer<void>();
      final presentationResult = await observeSupervisorWindowPresentation(
        windowPresentation: Future<bool>.value(false),
        supervisorWindowPresented: supervisorWindowPresented,
        timeout: const Duration(milliseconds: 20),
        firstFrameRasterized: firstFrameRasterized.future,
        isWindowVisible: () async => visible,
        visibilityPollInterval: const Duration(milliseconds: 2),
        onTimeout: () {},
        onFailure: (error, stackTrace) {},
      );

      expect(presentationResult, isFalse);
      firstFrameRasterized.completeError(StateError('synthetic frame error'));
      await Future<void>.delayed(const Duration(milliseconds: 12));
      visible = true;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(supervisorWindowPresented.isCompleted, isFalse);
    },
  );

  test('terminal presentation errors are distinguished from timeout', () async {
    final windowPresentation = Future<bool>.error(
      StateError('window manager failed'),
    );
    final supervisorWindowPresented = Completer<void>();
    final events = <String>[];

    final presentationResult = await observeSupervisorWindowPresentation(
      windowPresentation: windowPresentation,
      supervisorWindowPresented: supervisorWindowPresented,
      timeout: const Duration(seconds: 1),
      firstFrameRasterized: Future<void>.value(),
      onTimeout: () => events.add('timeout'),
      onFailure: (error, stackTrace) => events.add('failure'),
    );

    expect(presentationResult, isFalse);
    expect(events, <String>['failure']);
    expect(supervisorWindowPresented.isCompleted, isFalse);
  });

  test(
    'does not report ready when the native window never becomes visible',
    () async {
      final presented = await showMainWindowAfterFirstRasterizedFrame(
        firstFrameRasterized: Future<void>.value(),
        prepareWindow: () async {},
        showWindow: () async {},
        focusWindow: () async {},
        isWindowVisible: () async => false,
        visibilityTimeout: const Duration(milliseconds: 20),
        onPresentationFailure: (error, stackTrace) async => false,
      );

      expect(presented, isFalse);
    },
  );

  test('bounds one native visibility query that never returns', () async {
    final neverReturns = Completer<bool>();
    final stopwatch = Stopwatch()..start();

    await expectLater(
      waitForWindowVisibility(
        isWindowVisible: () => neverReturns.future,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 300)));
  });

  test('a visible window is ready even when focus fails', () async {
    var focusFailureReported = false;
    final presented = await showMainWindowAfterFirstRasterizedFrame(
      firstFrameRasterized: Future<void>.value(),
      prepareWindow: () async {},
      showWindow: () async {},
      focusWindow: () async => throw StateError('focus was denied'),
      isWindowVisible: () async => true,
      onFocusFailure: (error, stackTrace) => focusFailureReported = true,
      onPresentationFailure: (error, stackTrace) async => false,
    );

    expect(presented, isTrue);
    expect(focusFailureReported, isTrue);
  });

  test(
    'bounds a screenshot child that never rasterizes its first frame',
    () async {
      final neverRasterizes = Completer<void>();

      await expectLater(
        waitForFirstRasterizedFrame(
          firstFrameRasterized: neverRasterizes.future,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
}
