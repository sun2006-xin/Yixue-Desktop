import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/app_exit_cleanup_registry.dart';
import 'package:yixue_app/core/windows_app_close_controller.dart';

class _MemoryClosePreferenceStore implements WindowsAppClosePreferenceStore {
  WindowsClosePreference? value;
  var readCount = 0;

  @override
  Future<WindowsClosePreference?> read() async {
    readCount += 1;
    return value;
  }

  @override
  Future<void> write(WindowsClosePreference preference) async {
    value = preference;
  }
}

class _BlockingClosePreferenceStore implements WindowsAppClosePreferenceStore {
  final writeStarted = Completer<void>();
  final allowWriteToFinish = Completer<void>();
  WindowsClosePreference? value;

  @override
  Future<WindowsClosePreference?> read() async => null;

  @override
  Future<void> write(WindowsClosePreference preference) async {
    value = preference;
    writeStarted.complete();
    await allowWriteToFinish.future;
  }
}

class _BlockingReadClosePreferenceStore
    implements WindowsAppClosePreferenceStore {
  final readStarted = Completer<void>();
  final neverFinishingRead = Completer<WindowsClosePreference?>();

  @override
  Future<WindowsClosePreference?> read() {
    readStarted.complete();
    return neverFinishingRead.future;
  }

  @override
  Future<void> write(WindowsClosePreference preference) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native single-instance activation runs the full window restore flow',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      final windowCalls = <String>[];
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        windowCalls.add(call.method);
        return call.method == 'isMinimized' ? true : null;
      });
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(navigatorKey: navigatorKey);
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final reply = Completer<ByteData?>();
      await messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('restoreMainWindow'),
        ),
        reply.complete,
      );
      expect(
        const StandardMethodCodec().decodeEnvelope((await reply.future)!),
        isTrue,
      );
      expect(
        windowCalls,
        containsAllInOrder([
          'setPreventClose',
          'setSkipTaskbar',
          'isMinimized',
          'restore',
          'show',
          'focus',
        ]),
      );
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'native system shutdown runs the same media cleanup as an explicit quit',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      var cleanupRuns = 0;
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupRuns += 1;
      });
      addTearDown(unregisterCleanup);

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        processExit: () => processExitCalls += 1,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown'),
        ),
        reply.complete,
      );
      await tester.pump();
      await shutdownMessage;
      expect(
        const StandardMethodCodec().decodeEnvelope((await reply.future)!),
        isTrue,
      );
      await tester.pumpAndSettle();

      expect(cleanupRuns, 1);
      expect(processExitCalls, 1);
      expect(find.text('彻底退出'), findsNothing);
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'system shutdown does not exit while media cleanup is still running',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      final cleanupStarted = Completer<void>();
      final allowCleanupToFinish = Completer<void>();
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupStarted.complete();
        await allowCleanupToFinish.future;
      });
      addTearDown(unregisterCleanup);

      final controller = WindowsAppCloseController(
        navigatorKey: GlobalKey<NavigatorState>(),
        systemShutdownCleanupTimeout: const Duration(milliseconds: 50),
        processExit: () => processExitCalls += 1,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await controller.attach();

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown', true),
        ),
        reply.complete,
      );
      await tester.pump();
      await cleanupStarted.future;
      await tester.pump(const Duration(milliseconds: 60));

      expect(processExitCalls, 0);
      expect(reply.isCompleted, isFalse);

      allowCleanupToFinish.complete();
      await tester.pumpAndSettle();
      await shutdownMessage;

      expect(processExitCalls, 1);
      expect(reply.isCompleted, isTrue);
      expect(
        const StandardMethodCodec().decodeEnvelope((await reply.future)!),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets('system shutdown does not wait for a navigator during startup', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    const activationChannel = MethodChannel(
      'com.yixue.yixue_app/window_activation',
    );
    messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
    messenger.setMockMethodCallHandler(
      activationChannel,
      (call) async => call.method == 'ready',
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(activationChannel, null);
    });

    var cleanupRuns = 0;
    var processExitCalls = 0;
    final unregisterCleanup = AppExitCleanupRegistry.register(() async {
      cleanupRuns += 1;
    });
    addTearDown(unregisterCleanup);

    final controller = WindowsAppCloseController(
      navigatorKey: GlobalKey<NavigatorState>(),
      processExit: () => processExitCalls += 1,
      nativeCleanupWatchdogSignal: () async {},
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.attach();

    final reply = Completer<ByteData?>();
    final shutdownMessage = messenger.handlePlatformMessage(
      activationChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('systemShutdown'),
      ),
      reply.complete,
    );
    await tester.pump();

    expect(reply.isCompleted, isTrue);
    await shutdownMessage;
    expect(
      const StandardMethodCodec().decodeEnvelope((await reply.future)!),
      isTrue,
    );
    expect(cleanupRuns, 1);
    expect(processExitCalls, 1);
    expect(tester.takeException(), isNull);
    await controller.detach();
  }, skip: !Platform.isWindows);

  test(
    'tray icon is kept when failed-hide rollback cannot restore the window',
    () async {
      var disposed = false;
      final restored = await restoreWindowsWindowAfterTrayFailure(
        restoreTaskbar: () async {},
        showWindow: () async =>
            throw TimeoutException('synthetic show timeout'),
        disposeTrayIcon: () async => disposed = true,
        timeout: const Duration(milliseconds: 10),
      );

      expect(restored, isFalse);
      expect(disposed, isFalse);
    },
  );

  test(
    'tray icon is disposed only after taskbar and window are restored',
    () async {
      var disposed = false;
      final restored = await restoreWindowsWindowAfterTrayFailure(
        restoreTaskbar: () async {},
        showWindow: () async {},
        disposeTrayIcon: () async => disposed = true,
        timeout: const Duration(milliseconds: 10),
      );

      expect(restored, isTrue);
      expect(disposed, isTrue);
    },
  );

  testWidgets(
    'system shutdown removes its own close route when another route is above it',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      var processExitCalls = 0;
      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        processExit: () => processExitCalls++,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: FilledButton(
              onPressed: controller.requestClose,
              child: const Text('request-close'),
            ),
          ),
        ),
      );
      await controller.attach();
      await tester.tap(find.text('request-close'));
      await tester.pumpAndSettle();
      expect(find.text('关闭译学'), findsOneWidget);

      final navigator = navigatorKey.currentState!;
      unawaited(
        navigator.push<void>(
          DialogRoute<void>(
            context: navigator.context,
            builder: (_) =>
                const AlertDialog(content: Text('unrelated top route')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('unrelated top route'), findsOneWidget);

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown'),
        ),
        reply.complete,
      );
      await tester.pump();
      await tester.pumpAndSettle();
      await shutdownMessage;

      expect(processExitCalls, 1);
      expect(find.text('关闭译学'), findsNothing);
      expect(find.text('unrelated top route'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'system shutdown exits after a stuck close preference read times out',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      var cleanupRuns = 0;
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupRuns += 1;
      });
      addTearDown(unregisterCleanup);

      final store = _BlockingReadClosePreferenceStore();
      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        preferenceStore: store,
        closePreferenceReadTimeout: const Duration(milliseconds: 25),
        processExit: () => processExitCalls += 1,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final closeRequest = controller.requestClose();
      await store.readStarted.future;

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown'),
        ),
        reply.complete,
      );
      await tester.pump();
      await shutdownMessage;
      expect(
        const StandardMethodCodec().decodeEnvelope((await reply.future)!),
        isTrue,
      );

      await tester.pump(const Duration(milliseconds: 30));
      await closeRequest;
      await tester.pumpAndSettle();

      expect(cleanupRuns, 1);
      expect(processExitCalls, 1);
      expect(find.text('关闭译学'), findsNothing);
      expect(find.text('无法完成关闭操作'), findsNothing);
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'system shutdown during remembered hide choice runs media cleanup before exit',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      final windowCalls = <String>[];
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        windowCalls.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      var cleanupRuns = 0;
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupRuns++;
      });
      final store = _BlockingClosePreferenceStore();
      addTearDown(() {
        unregisterCleanup();
        if (!store.allowWriteToFinish.isCompleted) {
          store.allowWriteToFinish.complete();
        }
      });

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        preferenceStore: store,
        closePreferenceWriteTimeout: const Duration(milliseconds: 25),
        processExit: () => processExitCalls++,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final closeRequest = controller.requestClose();
      await tester.pumpAndSettle();
      await tester.tap(find.text('记住选择，下次不再询问'));
      await tester.pump();
      await tester.tap(find.text('隐藏到系统托盘'));
      await tester.pump();
      await store.writeStarted.future;

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown', true),
        ),
        reply.complete,
      );
      await tester.pump();
      await shutdownMessage;

      await tester.pump(const Duration(milliseconds: 30));
      await closeRequest;
      await tester.pumpAndSettle();

      expect(store.value, WindowsClosePreference.hideToTray);
      expect(cleanupRuns, 1);
      expect(processExitCalls, 1);
      expect(windowCalls, isNot(contains('hide')));
      expect(tester.takeException(), isNull);
      store.allowWriteToFinish.complete();
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'system shutdown exits after a cleanup failure without showing a retry dialog',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      var cleanupRuns = 0;
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupRuns++;
        if (cleanupRuns == 1) {
          throw StateError('synthetic transient shutdown cleanup failure');
        }
      });
      addTearDown(unregisterCleanup);

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        systemShutdownCleanupRetryDelay: Duration.zero,
        processExit: () => processExitCalls++,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown'),
        ),
        reply.complete,
      );
      await tester.pump();
      await shutdownMessage;
      await tester.pumpAndSettle();

      expect(cleanupRuns, 2);
      expect(processExitCalls, 1);
      expect(find.text('同传收尾未完成'), findsNothing);
      expect(find.text('无法完成关闭操作'), findsNothing);
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets('system shutdown bounds repeated cleanup failures', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    const activationChannel = MethodChannel(
      'com.yixue.yixue_app/window_activation',
    );
    messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
    messenger.setMockMethodCallHandler(
      activationChannel,
      (call) async => call.method == 'ready',
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(activationChannel, null);
    });

    var cleanupRuns = 0;
    var processExitCalls = 0;
    final unregisterCleanup = AppExitCleanupRegistry.register(() async {
      cleanupRuns++;
      throw StateError('synthetic persistent shutdown cleanup failure');
    });
    addTearDown(unregisterCleanup);

    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = WindowsAppCloseController(
      navigatorKey: navigatorKey,
      systemShutdownCleanupRetryDelay: Duration.zero,
      processExit: () => processExitCalls++,
      nativeCleanupWatchdogSignal: () async {},
    );
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
    );
    await controller.attach();

    final reply = Completer<ByteData?>();
    final shutdownMessage = messenger.handlePlatformMessage(
      activationChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('systemShutdown'),
      ),
      reply.complete,
    );
    await tester.pumpAndSettle();
    await shutdownMessage;

    expect(cleanupRuns, 3);
    expect(processExitCalls, 1);
    expect(reply.isCompleted, isTrue);
    expect(tester.takeException(), isNull);
    await controller.detach();
  }, skip: !Platform.isWindows);

  testWidgets(
    'system shutdown exits after its total cleanup deadline when cleanup never settles',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      final cleanupStarted = Completer<void>();
      final allowCleanupToFinish = Completer<void>();
      var cleanupRuns = 0;
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupRuns++;
        cleanupStarted.complete();
        await allowCleanupToFinish.future;
      });
      addTearDown(() {
        unregisterCleanup();
        if (!allowCleanupToFinish.isCompleted) {
          allowCleanupToFinish.complete();
        }
      });

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        systemShutdownFastCleanupTimeout: const Duration(milliseconds: 20),
        systemShutdownCleanupTotalTimeout: const Duration(milliseconds: 100),
        systemShutdownCleanupRetryDelay: Duration.zero,
        processExit: () => processExitCalls++,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown'),
        ),
        reply.complete,
      );
      await tester.pump();
      await cleanupStarted.future;
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 90));
      await tester.pumpAndSettle();
      await shutdownMessage;

      expect(cleanupRuns, 1);
      expect(processExitCalls, 1);
      expect(reply.isCompleted, isTrue);
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'system shutdown clips retry delay to the same total cleanup budget',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      final cleanupStarted = Completer<void>();
      var cleanupRuns = 0;
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupRuns++;
        if (!cleanupStarted.isCompleted) cleanupStarted.complete();
        throw StateError('synthetic shutdown cleanup failure');
      });
      addTearDown(unregisterCleanup);

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        systemShutdownCleanupTotalTimeout: const Duration(milliseconds: 100),
        systemShutdownCleanupRetryDelay: const Duration(seconds: 5),
        processExit: () => processExitCalls++,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown'),
        ),
        reply.complete,
      );
      await tester.pump();
      await cleanupStarted.future;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      await shutdownMessage;

      expect(cleanupRuns, 1);
      expect(processExitCalls, 1);
      expect(reply.isCompleted, isTrue);
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'system shutdown exits after a tray restore operation times out',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      final restoreStarted = Completer<void>();
      final blockedRestore = Completer<Object?>();
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        final arguments = call.arguments;
        if (call.method == 'setSkipTaskbar' &&
            arguments is Map &&
            arguments['isSkipTaskbar'] == false) {
          if (!restoreStarted.isCompleted) restoreStarted.complete();
          return blockedRestore.future;
        }
        if (call.method == 'isMinimized') return false;
        return null;
      });
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
        if (!blockedRestore.isCompleted) blockedRestore.complete(null);
      });

      var cleanupRuns = 0;
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupRuns++;
      });
      addTearDown(unregisterCleanup);

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        systemShutdownCleanupTotalTimeout: const Duration(milliseconds: 100),
        processExit: () => processExitCalls++,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final trayQuit = controller.requestTrayQuitForTesting();
      await tester.pump();
      await restoreStarted.future;

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown'),
        ),
        reply.complete,
      );
      await tester.pump();
      await shutdownMessage;
      await tester.pump(const Duration(milliseconds: 100));
      expect(processExitCalls, 0);

      await tester.pump(const Duration(milliseconds: 450));
      await trayQuit.timeout(const Duration(seconds: 2));

      expect(cleanupRuns, 0);
      expect(processExitCalls, 1);
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'system shutdown uses a short deadline when Windows cannot extend hidden-window grace',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const activationChannel = MethodChannel(
        'com.yixue.yixue_app/window_activation',
      );
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        activationChannel,
        (call) async => call.method == 'ready',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(activationChannel, null);
      });

      final cleanupStarted = Completer<void>();
      final allowCleanupToFinish = Completer<void>();
      var processExitCalls = 0;
      final unregisterCleanup = AppExitCleanupRegistry.register(() async {
        cleanupStarted.complete();
        await allowCleanupToFinish.future;
      });
      addTearDown(() {
        unregisterCleanup();
        if (!allowCleanupToFinish.isCompleted) {
          allowCleanupToFinish.complete();
        }
      });

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        systemShutdownFastCleanupTimeout: const Duration(milliseconds: 80),
        processExit: () => processExitCalls++,
        nativeCleanupWatchdogSignal: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
      await controller.attach();

      final reply = Completer<ByteData?>();
      final shutdownMessage = messenger.handlePlatformMessage(
        activationChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemShutdown'),
        ),
        reply.complete,
      );
      await tester.pump();
      await cleanupStarted.future;
      await tester.pump(const Duration(milliseconds: 100));
      expect(processExitCalls, 0);
      expect(reply.isCompleted, isFalse);
      allowCleanupToFinish.complete();
      await tester.pumpAndSettle();
      await shutdownMessage;

      expect(processExitCalls, 1);
      expect(reply.isCompleted, isTrue);
      expect(tester.takeException(), isNull);
      await controller.detach();
    },
    skip: !Platform.isWindows,
  );

  testWidgets('close choice fits the available desktop window width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));

    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = WindowsAppCloseController(navigatorKey: navigatorKey);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: controller.requestClose,
              child: const Text('关闭'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(
      tester
          .getSize(find.byKey(const ValueKey('close-dialog-description')))
          .width,
      lessThanOrEqualTo(520),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('shows quit progress while cleanup is still running', (
    tester,
  ) async {
    final cleanupStarted = Completer<void>();
    final allowCleanupToFinish = Completer<void>();
    final unregisterCleanup = AppExitCleanupRegistry.register(() async {
      cleanupStarted.complete();
      await allowCleanupToFinish.future;
    });
    final windowCalls = <String>[];
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call.method);
      return null;
    });
    addTearDown(() {
      unregisterCleanup();
      messenger.setMockMethodCallHandler(windowChannel, null);
      if (!allowCleanupToFinish.isCompleted) allowCleanupToFinish.complete();
    });

    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = WindowsAppCloseController(navigatorKey: navigatorKey);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: controller.requestClose,
              child: const Text('关闭'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('彻底退出'));
    await tester.pump();
    await cleanupStarted.future;
    await tester.pump();

    expect(find.byKey(const ValueKey('app-exit-progress')), findsOneWidget);
    expect(find.text('正在停止采集、完成录音并保存字幕。请稍候。'), findsOneWidget);
    expect(windowCalls, isNot(contains('close')));

    allowCleanupToFinish.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-exit-progress')), findsNothing);
    expect(windowCalls, contains('close'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('remembered close choice is saved and skips the next prompt', (
    tester,
  ) async {
    final calls = <String>[];
    final lifecycleEvents = <String>[];
    var processExitCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));

    final store = _MemoryClosePreferenceStore();
    final firstKey = GlobalKey<NavigatorState>();
    final firstController = WindowsAppCloseController(
      navigatorKey: firstKey,
      preferenceStore: store,
      processExit: () {
        lifecycleEvents.add('processExit');
        processExitCalls += 1;
      },
      nativeCleanupWatchdogSignal: () async {
        lifecycleEvents.add('watchdog');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: firstKey,
        home: Scaffold(
          body: FilledButton(
            onPressed: firstController.requestClose,
            child: const Text('关闭'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('记住选择，下次不再询问'));
    await tester.pump();
    await tester.tap(find.text('彻底退出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();

    expect(store.value, WindowsClosePreference.quit);
    expect(processExitCalls, 1);
    expect(lifecycleEvents, ['watchdog', 'processExit']);
    expect(calls, isNot(contains('close')));

    final secondKey = GlobalKey<NavigatorState>();
    final secondController = WindowsAppCloseController(
      navigatorKey: secondKey,
      preferenceStore: store,
      processExit: () => processExitCalls += 1,
      nativeCleanupWatchdogSignal: () async {
        lifecycleEvents.add('watchdog');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: secondKey,
        home: const Scaffold(body: Text('ready')),
      ),
    );
    final secondClose = secondController.requestClose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();
    await secondClose;

    expect(find.text('关闭译学'), findsNothing);
    expect(processExitCalls, 2);
    expect(calls, isNot(contains('close')));
  });

  testWidgets('explicit quit ignores saved hide-to-tray preference', (
    tester,
  ) async {
    final windowCalls = <String>[];
    final lifecycleEvents = <String>[];
    var processExitCalls = 0;
    final unregisterCleanup = AppExitCleanupRegistry.register(() async {
      lifecycleEvents.add('cleanup');
    }, name: 'explicit_quit_test');
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call.method);
      return null;
    });
    addTearDown(() {
      unregisterCleanup();
      messenger.setMockMethodCallHandler(windowChannel, null);
    });

    final store = _MemoryClosePreferenceStore()
      ..value = WindowsClosePreference.hideToTray;
    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = WindowsAppCloseController(
      navigatorKey: navigatorKey,
      preferenceStore: store,
      processExit: () {
        lifecycleEvents.add('processExit');
        processExitCalls += 1;
      },
      nativeCleanupWatchdogSignal: () async {
        lifecycleEvents.add('watchdog');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: FilledButton(
            onPressed: controller.requestQuit,
            child: const Text('悬浮球退出'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('悬浮球退出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();

    expect(store.readCount, 0);
    expect(processExitCalls, 1);
    expect(lifecycleEvents, ['cleanup', 'watchdog', 'processExit']);
    expect(windowCalls, isNot(contains('hide')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'arms the native close watchdog before any awaited window-manager shutdown call',
    (tester) async {
      final lifecycleEvents = <String>[];
      final taskbarUpdateStarted = Completer<void>();
      final allowTaskbarUpdateToFinish = Completer<void>();
      var processExitCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        if (call.method == 'setSkipTaskbar') {
          lifecycleEvents.add('setSkipTaskbar');
          if (!taskbarUpdateStarted.isCompleted) {
            taskbarUpdateStarted.complete();
          }
          await allowTaskbarUpdateToFinish.future;
        }
        return null;
      });
      addTearDown(() async {
        if (!allowTaskbarUpdateToFinish.isCompleted) {
          allowTaskbarUpdateToFinish.complete();
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        messenger.setMockMethodCallHandler(windowChannel, null);
      });

      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = WindowsAppCloseController(
        navigatorKey: navigatorKey,
        processExit: () {
          lifecycleEvents.add('processExit');
          processExitCalls++;
        },
        nativeCleanupWatchdogSignal: () async {
          lifecycleEvents.add('watchdog');
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: FilledButton(
              onPressed: controller.requestClose,
              child: const Text('关闭'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('彻底退出'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();

      expect(lifecycleEvents, contains('watchdog'));
      final taskbarUpdateIndex = lifecycleEvents.indexOf('setSkipTaskbar');
      expect(taskbarUpdateStarted.isCompleted, isFalse);
      expect(taskbarUpdateIndex, -1);
      expect(processExitCalls, 1);
      expect(
        lifecycleEvents.indexOf('watchdog'),
        lessThan(lifecycleEvents.indexOf('processExit')),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('returning after timeout cancels pending exit cleanup', (
    tester,
  ) async {
    final cleanupStarted = Completer<void>();
    final cleanupCancelled = Completer<void>();
    final unregisterCleanup = AppExitCleanupRegistry.register(() async {
      cleanupStarted.complete();
      await AppExitCleanupRegistry.activeCancellation!.whenCancelled;
      cleanupCancelled.complete();
    });
    final windowCalls = <String>[];
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call.method);
      if (call.method == 'isMinimized') return false;
      return null;
    });
    addTearDown(() {
      unregisterCleanup();
      messenger.setMockMethodCallHandler(windowChannel, null);
    });

    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = WindowsAppCloseController(
      navigatorKey: navigatorKey,
      exitCleanupTimeout: const Duration(seconds: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: controller.requestClose,
              child: const Text('关闭'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('彻底退出'));
    await tester.pump();
    await cleanupStarted.future;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('继续等待'), findsOneWidget);
    expect(find.text('返回译学'), findsOneWidget);
    await tester.tap(find.text('返回译学'));
    await tester.pumpAndSettle();
    await cleanupCancelled.future;
    expect(windowCalls, isNot(contains('close')));

    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cleanup timeout cannot force exit while media save is pending', (
    tester,
  ) async {
    final cleanupStarted = Completer<void>();
    final allowCleanupToFinish = Completer<void>();
    final unregisterCleanup = AppExitCleanupRegistry.register(() async {
      cleanupStarted.complete();
      await allowCleanupToFinish.future;
    });
    var processExitCalls = 0;
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isMinimized') return false;
      return null;
    });
    addTearDown(() {
      unregisterCleanup();
      messenger.setMockMethodCallHandler(windowChannel, null);
      if (!allowCleanupToFinish.isCompleted) allowCleanupToFinish.complete();
    });

    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = WindowsAppCloseController(
      navigatorKey: navigatorKey,
      exitCleanupTimeout: const Duration(seconds: 1),
      processExit: () => processExitCalls += 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: controller.requestClose,
              child: const Text('关闭'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('彻底退出'));
    await tester.pump();
    await cleanupStarted.future;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('继续等待'), findsOneWidget);
    expect(find.text('仍然退出'), findsNothing);
    expect(processExitCalls, 0);

    await tester.tap(find.text('继续等待'));
    await tester.pump();
    expect(find.byKey(const ValueKey('app-exit-progress')), findsOneWidget);
    expect(processExitCalls, 0);

    allowCleanupToFinish.complete();
    await tester.pumpAndSettle();
    expect(processExitCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a later quit attempt runs cleanup for a newly active session', (
    tester,
  ) async {
    final firstCleanupStarted = Completer<void>();
    final allowFirstCleanupToFinish = Completer<void>();
    final unregisterFirstCleanup = AppExitCleanupRegistry.register(() async {
      firstCleanupStarted.complete();
      await allowFirstCleanupToFinish.future;
    });
    final windowCalls = <String>[];
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call.method);
      if (call.method == 'isMinimized') return false;
      return null;
    });
    addTearDown(() {
      unregisterFirstCleanup();
      messenger.setMockMethodCallHandler(windowChannel, null);
      if (!allowFirstCleanupToFinish.isCompleted) {
        allowFirstCleanupToFinish.complete();
      }
    });

    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = WindowsAppCloseController(
      navigatorKey: navigatorKey,
      exitCleanupTimeout: const Duration(seconds: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: controller.requestClose,
              child: const Text('关闭'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('彻底退出'));
    await tester.pump();
    await firstCleanupStarted.future;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('返回译学'), findsOneWidget);

    await tester.tap(find.text('返回译学'));
    await tester.pumpAndSettle();
    allowFirstCleanupToFinish.complete();
    await tester.pump();
    unregisterFirstCleanup();

    var secondCleanupRuns = 0;
    final unregisterSecondCleanup = AppExitCleanupRegistry.register(() async {
      secondCleanupRuns++;
    });
    addTearDown(unregisterSecondCleanup);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('彻底退出'));
    await tester.pumpAndSettle();

    expect(secondCleanupRuns, 1);
    expect(windowCalls, contains('close'));
    expect(tester.takeException(), isNull);
  });
}
