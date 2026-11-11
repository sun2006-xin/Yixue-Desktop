import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/features/brand/app_startup_gate.dart';
import 'package:yixue_app/features/brand/launch_gate.dart';

void main() {
  testWidgets('keeps a loading frame visible until startup returns', (
    tester,
  ) async {
    final startup = Completer<Widget>();
    var readinessSignals = 0;

    await tester.pumpWidget(
      AppStartupGate(
        start: () => startup.future,
        onReady: () async => readinessSignals++,
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
      ),
    );

    expect(find.text('loading'), findsOneWidget);
    expect(readinessSignals, 0);
    startup.complete(const MaterialApp(home: Text('ready')));
    await tester.pumpAndSettle();

    expect(find.text('ready'), findsOneWidget);
    expect(readinessSignals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retries the supervisor readiness signal after an IPC error', (
    tester,
  ) async {
    var readinessAttempts = 0;
    await tester.pumpWidget(
      AppStartupGate(
        start: () async => const MaterialApp(home: Text('ready')),
        onReady: () async {
          readinessAttempts++;
          if (readinessAttempts == 1) {
            throw StateError('temporary readiness IPC failure');
          }
        },
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(readinessAttempts, 1);

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(readinessAttempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signals readiness after a recoverable startup error is shown', (
    tester,
  ) async {
    var readinessSignals = 0;
    await tester.pumpWidget(
      AppStartupGate(
        start: () => Future<Widget>.error(StateError('data store unavailable')),
        onReady: () async => readinessSignals++,
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.textContaining('data store unavailable'), findsOneWidget);
    expect(readinessSignals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows startup errors and retries without rebuilding the app', (
    tester,
  ) async {
    var attempts = 0;

    await tester.pumpWidget(
      AppStartupGate(
        start: () {
          attempts++;
          if (attempts == 1) return Future<Widget>.error(StateError('blocked'));
          return Future.value(const MaterialApp(home: Text('ready')));
        },
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('startup error: Bad state: blocked'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('can replace failed startup with the data-directory flow', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppStartupGate(
        start: () => Future<Widget>.error(StateError('missing disk')),
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () =>
            const MaterialApp(home: Text('choose directory')),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Choose data'));
    await tester.pumpAndSettle();

    expect(find.text('choose directory'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('surfaces a startup task that does not finish', (tester) async {
    final neverCompletes = Completer<Widget>();
    var readinessSignals = 0;

    await tester.pumpWidget(
      AppStartupGate(
        start: () => neverCompletes.future,
        onReady: () async => readinessSignals++,
        startupTimeout: const Duration(milliseconds: 10),
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
      ),
    );
    expect(find.text('loading'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();

    expect(find.textContaining('TimeoutException'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Choose data'), findsNothing);
    expect(find.text('Startup still running'), findsOneWidget);
    expect(readinessSignals, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'does not allow switching data while timed-out startup is active',
    (tester) async {
      final neverCompletes = Completer<Widget>();

      await tester.pumpWidget(
        AppStartupGate(
          start: () => neverCompletes.future,
          startupTimeout: const Duration(milliseconds: 10),
          loading: const MaterialApp(home: Text('loading')),
          errorBuilder: (_, error, _, retry, recover) =>
              _errorApp(error, retry, recover),
          recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 11));
      await tester.pump();

      expect(find.textContaining('TimeoutException'), findsOneWidget);
      expect(find.text('Choose data'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retry reuses an in-flight startup after its display timeout', (
    tester,
  ) async {
    final startup = Completer<Widget>();
    var attempts = 0;
    var readinessSignals = 0;

    await tester.pumpWidget(
      AppStartupGate(
        start: () {
          attempts++;
          return startup.future;
        },
        onReady: () async => readinessSignals++,
        startupTimeout: const Duration(milliseconds: 10),
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(find.textContaining('TimeoutException'), findsOneWidget);
    expect(readinessSignals, 0);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(attempts, 1);
    expect(find.textContaining('TimeoutException'), findsOneWidget);

    startup.complete(const MaterialApp(home: Text('ready')));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.text('ready'), findsOneWidget);
    expect(readinessSignals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a late startup success after the timeout without retry', (
    tester,
  ) async {
    final startup = Completer<Widget>();
    var attempts = 0;
    var readinessSignals = 0;

    await tester.pumpWidget(
      AppStartupGate(
        start: () {
          attempts++;
          return startup.future;
        },
        onReady: () async => readinessSignals++,
        startupTimeout: const Duration(milliseconds: 10),
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
      ),
    );

    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(find.textContaining('TimeoutException'), findsOneWidget);
    expect(readinessSignals, 0);

    startup.complete(const MaterialApp(home: Text('ready')));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.text('ready'), findsOneWidget);
    expect(readinessSignals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replaces a startup timeout with the actual late failure', (
    tester,
  ) async {
    final startup = Completer<Widget>();
    var attempts = 0;

    await tester.pumpWidget(
      AppStartupGate(
        start: () {
          attempts++;
          return startup.future;
        },
        startupTimeout: const Duration(milliseconds: 10),
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
      ),
    );

    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(find.textContaining('TimeoutException'), findsOneWidget);

    startup.completeError(StateError('late startup failure'));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.textContaining('late startup failure'), findsOneWidget);
    expect(find.textContaining('TimeoutException'), findsNothing);
    expect(find.text('Choose data'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('launch animation runs alongside unresolved app initialization', (
    tester,
  ) async {
    final startup = Completer<Widget>();
    final presentation = ValueNotifier(
      const YixueLaunchPresentation(
        motionLevel: YixueMotionLevel.full,
        variant: YixueLaunchVariant.compact,
      ),
    );
    addTearDown(presentation.dispose);

    await tester.pumpWidget(
      AppStartupGate(
        start: () => startup.future,
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
        launchPresentation: presentation,
      ),
    );

    expect(find.byKey(const ValueKey('launch-overlay')), findsOneWidget);
    expect(find.text('loading'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.byKey(const ValueKey('launch-overlay')), findsOneWidget);
    expect(find.text('loading'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('launch-overlay')), findsNothing);
    expect(find.text('loading'), findsOneWidget);

    startup.complete(const MaterialApp(home: Text('ready')));
    await tester.pumpAndSettle();
    expect(find.text('ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup error immediately reveals retry UI over the splash', (
    tester,
  ) async {
    final presentation = ValueNotifier(
      const YixueLaunchPresentation(
        motionLevel: YixueMotionLevel.full,
        variant: YixueLaunchVariant.full,
      ),
    );
    addTearDown(presentation.dispose);

    await tester.pumpWidget(
      AppStartupGate(
        start: () => Future<Widget>.error(StateError('blocked')),
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
        launchPresentation: presentation,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('startup error: Bad state: blocked'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byKey(const ValueKey('launch-overlay')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restored disabled motion removes the startup overlay', (
    tester,
  ) async {
    final presentation = ValueNotifier(const YixueLaunchPresentation());
    final startup = Completer<Widget>();
    addTearDown(presentation.dispose);

    await tester.pumpWidget(
      AppStartupGate(
        start: () => startup.future,
        loading: const MaterialApp(home: Text('loading')),
        errorBuilder: (_, error, _, retry, recover) =>
            _errorApp(error, retry, recover),
        recoveryBuilder: () => const MaterialApp(home: Text('recovery')),
        launchPresentation: presentation,
      ),
    );
    expect(find.byKey(const ValueKey('launch-overlay')), findsOneWidget);

    presentation.value = const YixueLaunchPresentation(
      motionLevel: YixueMotionLevel.off,
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('launch-overlay')), findsNothing);
    expect(find.text('loading'), findsOneWidget);
    startup.complete(const MaterialApp(home: Text('ready')));
    await tester.pumpAndSettle();
    expect(find.text('ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _errorApp(Object error, VoidCallback retry, VoidCallback? recover) =>
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Text('startup error: $error'),
            TextButton(onPressed: retry, child: const Text('Retry')),
            if (recover != null)
              TextButton(onPressed: recover, child: const Text('Choose data')),
            if (recover == null) const Text('Startup still running'),
          ],
        ),
      ),
    );
