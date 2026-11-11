import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_window_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windows = MethodChannel('mixin.one/desktop_multi_window');
  const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
  const nativeWindow = MethodChannel(
    'yixue/screenshot_translation/native_window',
  );
  test('child retirement is limited to the current host connection', () {
    expect(
      canRetireScreenshotTranslationChild(
        activeHostEpoch: 'host-1',
        activeConnectionGeneration: 2,
        requestedHostEpoch: 'host-1',
        requestedConnectionGeneration: 1,
      ),
      isFalse,
    );
    expect(
      canRetireScreenshotTranslationChild(
        activeHostEpoch: 'host-1',
        activeConnectionGeneration: 2,
        requestedHostEpoch: 'host-1',
        requestedConnectionGeneration: 2,
      ),
      isTrue,
    );
    expect(
      canRetireScreenshotTranslationChild(
        activeHostEpoch: 'host-2',
        activeConnectionGeneration: 1,
        requestedHostEpoch: 'host-1',
        requestedConnectionGeneration: 1,
      ),
      isFalse,
    );
  });
  test(
    'a startup result child accepts only scoped retirement before claim',
    () {
      expect(
        canRetireScreenshotTranslationChild(
          activeHostEpoch: null,
          activeConnectionGeneration: null,
          requestedHostEpoch: 'host-starting',
          requestedConnectionGeneration: null,
        ),
        isTrue,
      );
      expect(
        canRetireScreenshotTranslationChild(
          activeHostEpoch: 'active-host',
          activeConnectionGeneration: 4,
          requestedHostEpoch: 'active-host',
          requestedConnectionGeneration: null,
        ),
        isFalse,
      );
      expect(
        canRetireScreenshotTranslationChild(
          activeHostEpoch: null,
          activeConnectionGeneration: null,
          requestedHostEpoch: null,
          requestedConnectionGeneration: 4,
        ),
        isFalse,
      );
    },
  );
  test('a window shown after shutdown is hidden again', () async {
    final showStarted = Completer<void>();
    final finishShow = Completer<void>();
    var closing = false;
    var visible = false;
    final showing = showScreenshotChildWindowUnlessClosing(
      isClosing: () => closing,
      show: () async {
        showStarted.complete();
        await finishShow.future;
        visible = true;
      },
      hide: () async => visible = false,
    );

    await showStarted.future;
    closing = true;
    finishShow.complete();
    expect(await showing, isFalse);
    expect(visible, isFalse);
  });
  test('native orb is not shown if shutdown wins during resize', () async {
    var closing = false;
    var showCalls = 0;
    final shown = await showScreenshotOrbAfterPlacement(
      resize: () async => closing = true,
      canShow: () => !closing,
      isClosing: () => closing,
      show: () async => showCalls++,
      hide: () async {},
    );

    expect(shown, isFalse);
    expect(showCalls, 0);
  });
  test('native orb is hidden if shutdown wins during show', () async {
    final showStarted = Completer<void>();
    final finishShow = Completer<void>();
    var closing = false;
    var visible = false;
    final showing = showScreenshotOrbAfterPlacement(
      resize: () async {},
      canShow: () => !closing,
      isClosing: () => closing,
      show: () async {
        showStarted.complete();
        await finishShow.future;
        visible = true;
      },
      hide: () async => visible = false,
    );

    await showStarted.future;
    closing = true;
    finishShow.complete();

    expect(await showing, isFalse);
    expect(visible, isFalse);
  });
  test(
    'a superseded orb placement does not hide its newer placement',
    () async {
      final showStarted = Completer<void>();
      final finishShow = Completer<void>();
      var generation = 1;
      var closing = false;
      var visible = false;
      var hideCalls = 0;
      final showing = showScreenshotOrbAfterPlacement(
        resize: () async {},
        canShow: () => !closing && generation == 1,
        isClosing: () => closing,
        show: () async {
          showStarted.complete();
          await finishShow.future;
          visible = true;
        },
        hide: () async {
          hideCalls++;
          visible = false;
        },
      );

      await showStarted.future;
      generation = 2;
      finishShow.complete();

      expect(await showing, isFalse);
      expect(hideCalls, 0);
      expect(visible, isTrue);
    },
  );
  test('closeAll bounds a hung child-window enumeration', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final neverCompletes = Completer<Object?>();
    messenger.setMockMethodCallHandler(windows, (call) async {
      if (call.method == 'getAllWindows') return neverCompletes.future;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(windows, null);
    });

    final stopwatch = Stopwatch()..start();
    await expectLater(
      ScreenshotTranslationWindowSession.closeAll(
        WindowController.fromWindowId('shutdown-parent'),
        enumerationTimeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 300)));
  });

  test(
    'a stale host probe never retires a result child owned by a newer host',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const childId = 'newer-host-owned-result-child';
      const parentId = 'stale-host-probe-parent';
      final arguments = const ScreenshotTranslationWindowArguments(
        role: ScreenshotTranslationWindowRole.result,
        parentWindowId: parentId,
      ).encode();
      var createCalls = 0;
      var shutdownCalls = 0;
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') {
          return [
            {'windowId': childId, 'windowArgument': arguments},
          ];
        }
        if (call.method == 'createWindow') createCalls++;
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method != 'invokeMethod') return null;
        final request = ScreenshotTranslationWindowMessage.fromMap(
          (call.arguments as Map)['arguments'],
        );
        if (request.type == 'probe') {
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: request.requestId,
            payload: const {'errorCode': 'stale_update'},
          ).toMap();
        }
        if (request.type == 'shutdownRequested') shutdownCalls++;
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: const {},
        ).toMap();
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });

      await expectLater(
        ScreenshotTranslationWindowSession.create(
          parent: WindowController.fromWindowId(parentId),
          role: ScreenshotTranslationWindowRole.result,
          readinessTimeout: const Duration(milliseconds: 500),
        ),
        throwsA(isA<ScreenshotTranslationWindowConnectionException>()),
      );

      expect(shutdownCalls, 0);
      expect(createCalls, 0);
      final liveChildren = await WindowController.getAll();
      expect(liveChildren.map((child) => child.windowId), contains(childId));
    },
  );

  test(
    'closing an old owner preserves the new child-to-parent handler',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const childId = 'screenshot-result-parent-handler-owner';
      const parentId = 'screenshot-result-parent-handler-parent';
      final arguments = const ScreenshotTranslationWindowArguments(
        role: ScreenshotTranslationWindowRole.result,
        parentWindowId: parentId,
      ).encode();
      var childAlive = true;
      var registerCalls = 0;
      var unregisterCalls = 0;
      String? activeHostEpoch;
      int? activeConnectionGeneration;
      final incomingRequests = <String>[];
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') {
          return childAlive
              ? [
                  {'windowId': childId, 'windowArgument': arguments},
                ]
              : <Object>[];
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method == 'registerMethodHandler') {
          registerCalls++;
          return null;
        }
        if (call.method == 'unregisterMethodHandler') {
          unregisterCalls++;
          return null;
        }
        if (call.method != 'invokeMethod') return null;
        final request = ScreenshotTranslationWindowMessage.fromMap(
          (call.arguments as Map)['arguments'],
        );
        if (request.type == 'probe') {
          activeHostEpoch = request.payload['hostEpoch'] as String;
          activeConnectionGeneration =
              request.payload['connectionGeneration'] as int;
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: request.requestId,
            payload: {
              'hostEpoch': activeHostEpoch,
              'connectionGeneration': activeConnectionGeneration,
            },
          ).toMap();
        }
        if (request.type == 'shutdownRequested') {
          final ownsChild =
              request.payload['hostEpoch'] == activeHostEpoch &&
              request.payload['connectionGeneration'] ==
                  activeConnectionGeneration;
          if (ownsChild) childAlive = false;
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: request.requestId,
            payload: {'retired': ownsChild},
          ).toMap();
        }
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: const {},
        ).toMap();
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });

      var oldCallbackCalls = 0;
      final oldHandle = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId(parentId),
        role: ScreenshotTranslationWindowRole.result,
        onMessage: (message) async {
          oldCallbackCalls++;
          return null;
        },
      );
      var newCallbackCalls = 0;
      final newHandle = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId(parentId),
        role: ScreenshotTranslationWindowRole.result,
        onMessage: (message) async {
          newCallbackCalls++;
          incomingRequests.add(message.requestId);
          return null;
        },
      );

      await oldHandle.close();
      final inbound = ScreenshotTranslationWindowMessage(
        type: 'dictionaryLookupRequested',
        requestId: 'new-child-return-message',
        payload: const {},
      );
      final response =
          await dispatchScreenshotTranslationParentMessageForTesting(
            windowId: childId,
            call: MethodCall('screenshot_translation_message', inbound.toMap()),
          );

      expect(oldCallbackCalls, 0);
      expect(newCallbackCalls, 1);
      expect(incomingRequests, ['new-child-return-message']);
      expect(
        ScreenshotTranslationWindowMessage.fromMap(response).requestId,
        'new-child-return-message',
      );
      expect(registerCalls, 1);
      expect(unregisterCalls, 0);

      await newHandle.close();
      expect(childAlive, isFalse);
      expect(unregisterCalls, 1);
    },
  );

  test('a timed-out old result handle cannot retire a child claimed by a newer connection', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const childId = 'result-child-new-connection-owns';
    const parentId = 'result-child-new-connection-parent';
    final arguments = const ScreenshotTranslationWindowArguments(
      role: ScreenshotTranslationWindowRole.result,
      parentWindowId: parentId,
    ).encode();
    var childAlive = true;
    String? activeHostEpoch;
    int? activeConnectionGeneration;
    final connectionGenerations = <int>[];
    ScreenshotTranslationWindowMessage? oldUpdate;
    final oldUpdateAcknowledgement = Completer<Object?>();
    var refusedRetirements = 0;
    messenger.setMockMethodCallHandler(windows, (call) async {
      if (call.method == 'getAllWindows') {
        return childAlive
            ? [
                {'windowId': childId, 'windowArgument': arguments},
              ]
            : <Object>[];
      }
      if (call.method == 'createWindow') return childId;
      return null;
    });
    messenger.setMockMethodCallHandler(channels, (call) async {
      if (call.method != 'invokeMethod') return null;
      final request = ScreenshotTranslationWindowMessage.fromMap(
        (call.arguments as Map)['arguments'],
      );
      if (request.type == 'probe') {
        activeHostEpoch = request.payload['hostEpoch'] as String;
        activeConnectionGeneration =
            request.payload['connectionGeneration'] as int;
        connectionGenerations.add(activeConnectionGeneration!);
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: {
            'hostEpoch': activeHostEpoch,
            'connectionGeneration': activeConnectionGeneration,
          },
        ).toMap();
      }
      if (request.type == 'sessionUpdated' && oldUpdate == null) {
        oldUpdate = request;
        return oldUpdateAcknowledgement.future;
      }
      if (request.type == 'shutdownRequested') {
        final ownsChild =
            request.payload['hostEpoch'] == activeHostEpoch &&
            request.payload['connectionGeneration'] ==
                activeConnectionGeneration;
        if (ownsChild) childAlive = false;
        if (!ownsChild) refusedRetirements++;
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: {'retired': ownsChild},
        ).toMap();
      }
      return ScreenshotTranslationWindowMessage(
        type: 'ack',
        requestId: request.requestId,
        payload: const {},
      ).toMap();
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(windows, null);
      messenger.setMockMethodCallHandler(channels, null);
    });

    final parent = WindowController.fromWindowId(parentId);
    final oldHandle = await ScreenshotTranslationWindowSession.create(
      parent: parent,
      role: ScreenshotTranslationWindowRole.result,
      activationAcknowledgementTimeout: const Duration(milliseconds: 20),
    );
    final oldGeneration = connectionGenerations.last;
    final newHandle = await ScreenshotTranslationWindowSession.create(
      parent: parent,
      role: ScreenshotTranslationWindowRole.result,
      activationAcknowledgementTimeout: const Duration(milliseconds: 20),
    );
    expect(connectionGenerations.last, greaterThan(oldGeneration));

    await expectLater(
      oldHandle.update(
        const ScreenshotTranslationSession(
          id: 'old-connection-payload',
          recognizedText: 'old',
          status: ScreenshotTranslationStatus.completed,
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(refusedRetirements, 0);
    expect(childAlive, isTrue);

    final oldRequest = oldUpdate!;
    oldUpdateAcknowledgement.complete(
      ScreenshotTranslationWindowMessage(
        type: 'ack',
        requestId: oldRequest.requestId,
        payload: const {},
      ).toMap(),
    );
    await newHandle.update(
      const ScreenshotTranslationSession(
        id: 'new-connection-payload',
        recognizedText: 'new',
        status: ScreenshotTranslationStatus.completed,
      ),
    );
    await newHandle.close();
    expect(childAlive, isFalse);
  });

  test(
    'orb readiness stays hidden until configured with persisted position',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final windowCalls = <String>[];
      final messages = <ScreenshotTranslationWindowMessage>[];
      messenger.setMockMethodCallHandler(windows, (call) async {
        windowCalls.add(call.method);
        if (call.method == 'getAllWindows') return <Object>[];
        if (call.method == 'createWindow') return 'configured-orb';
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method != 'invokeMethod') return null;
        final request = ScreenshotTranslationWindowMessage.fromMap(
          (call.arguments as Map)['arguments'],
        );
        messages.add(request);
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: const {},
        ).toMap();
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });
      final orb = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId('orb-parent'),
        role: ScreenshotTranslationWindowRole.orb,
      );
      expect(windowCalls, ['getAllWindows', 'createWindow']);
      expect(messages.map((m) => m.type), ['probe']);
      await orb.open(const ScreenshotOrbPosition(-56, 300));
      expect(messages.map((m) => m.type), ['probe', 'orbConfigured']);
      expect(messages.last.payload['position'], {'x': -56.0, 'y': 300.0});
      expect(windowCalls, ['getAllWindows', 'createWindow']);
    },
  );
  test(
    'result window sends image bytes once per session and after clearing',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final messages = <ScreenshotTranslationWindowMessage>[];
      final firstUpdateStarted = Completer<void>();
      final firstUpdateAcknowledgement = Completer<Object?>();
      ScreenshotTranslationWindowMessage? pendingInitialUpdate;
      var returnCacheMissOnNextReuse = false;
      var returnEmptyAckOnNextReuse = false;
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') return <Object>[];
        if (call.method == 'createWindow') return 'result-payload-reuse';
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method != 'invokeMethod') return null;
        final request = ScreenshotTranslationWindowMessage.fromMap(
          (call.arguments as Map)['arguments'],
        );
        messages.add(request);
        if (request.type == 'probe') {
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: request.requestId,
            payload: {'hostEpoch': request.payload['hostEpoch']},
          ).toMap();
        }
        if (request.type == 'sessionUpdated' && pendingInitialUpdate == null) {
          pendingInitialUpdate = request;
          firstUpdateStarted.complete();
          return firstUpdateAcknowledgement.future;
        }
        if (request.payload['reuseImageForSessionId'] == 'payload-session') {
          if (returnCacheMissOnNextReuse) {
            returnCacheMissOnNextReuse = false;
            return ScreenshotTranslationWindowMessage(
              type: 'ack',
              requestId: request.requestId,
              payload: const {'errorCode': 'result_image_cache_miss'},
            ).toMap();
          }
          if (returnEmptyAckOnNextReuse) {
            returnEmptyAckOnNextReuse = false;
            return ScreenshotTranslationWindowMessage(
              type: 'ack',
              requestId: request.requestId,
              payload: const {},
            ).toMap();
          }
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: request.requestId,
            payload: const {'imageReusedForSessionId': 'payload-session'},
          ).toMap();
        }
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: const {},
        ).toMap();
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });

      final resultWindow = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId('payload-parent'),
        role: ScreenshotTranslationWindowRole.result,
      );
      final session = ScreenshotTranslationSession(
        id: 'payload-session',
        imageBytes: Uint8List.fromList(List<int>.filled(4096, 7)),
        status: ScreenshotTranslationStatus.recognizing,
      );

      final firstUpdate = resultWindow.update(session);
      await firstUpdateStarted.future;
      final secondUpdate = resultWindow.update(
        session.withState(ScreenshotTranslationStatus.translating),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        messages.where((message) => message.type == 'sessionUpdated'),
        hasLength(1),
      );
      final initial = pendingInitialUpdate!;
      firstUpdateAcknowledgement.complete(
        ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: initial.requestId,
          payload: const {},
        ).toMap(),
      );
      await Future.wait([firstUpdate, secondUpdate]);
      await resultWindow.update(
        session.withState(ScreenshotTranslationStatus.completed),
      );

      List<ScreenshotTranslationWindowMessage> updates() => messages
          .where((message) => message.type == 'sessionUpdated')
          .toList();

      int transferredBytes(Iterable<ScreenshotTranslationWindowMessage> sent) =>
          sent.fold<int>(0, (total, message) {
            final value = message.payload['session'];
            if (value is! Map || !value.containsKey('imageBytes')) return total;
            final bytes = value['imageBytes'] as Uint8List?;
            return total + (bytes?.lengthInBytes ?? 0);
          });

      var sessionUpdates = updates();
      expect(sessionUpdates, hasLength(3));
      expect(
        transferredBytes(sessionUpdates),
        session.imageBytes!.lengthInBytes,
      );
      expect(
        sessionUpdates[0].payload['session'] is Map &&
            (sessionUpdates[0].payload['session'] as Map).containsKey(
              'imageBytes',
            ),
        isTrue,
      );
      for (final update in sessionUpdates.skip(1)) {
        expect(
          (update.payload['session'] as Map).containsKey('imageBytes'),
          isFalse,
        );
        expect(update.payload['reuseImageForSessionId'], 'payload-session');
      }

      returnCacheMissOnNextReuse = true;
      await resultWindow.update(
        session.withState(ScreenshotTranslationStatus.failed),
      );
      sessionUpdates = updates();
      expect(sessionUpdates, hasLength(5));
      expect(
        sessionUpdates[3].payload['reuseImageForSessionId'],
        'payload-session',
      );
      expect(
        (sessionUpdates[4].payload['session'] as Map).containsKey('imageBytes'),
        isTrue,
      );
      expect(
        transferredBytes(sessionUpdates),
        session.imageBytes!.lengthInBytes * 2,
      );

      returnEmptyAckOnNextReuse = true;
      await resultWindow.update(
        session.withState(ScreenshotTranslationStatus.cancelled),
      );
      sessionUpdates = updates();
      expect(sessionUpdates, hasLength(7));
      expect(
        sessionUpdates[5].payload['reuseImageForSessionId'],
        'payload-session',
      );
      expect(
        (sessionUpdates[6].payload['session'] as Map).containsKey('imageBytes'),
        isTrue,
      );
      expect(
        transferredBytes(sessionUpdates),
        session.imageBytes!.lengthInBytes * 3,
      );

      await resultWindow.update(null);
      await resultWindow.update(session);
      sessionUpdates = updates();
      expect(sessionUpdates, hasLength(9));
      expect(sessionUpdates[7].payload['session'], isNull);
      expect(
        (sessionUpdates[8].payload['session'] as Map)['imageBytes'],
        orderedEquals(session.imageBytes!),
      );
    },
  );
  test(
    'an older result handle never resends over a newer connection',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const childId = 'shared-result-connection-generation';
      const parentId = 'shared-result-parent';
      final arguments = const ScreenshotTranslationWindowArguments(
        role: ScreenshotTranslationWindowRole.result,
        parentWindowId: parentId,
      ).encode();
      final requests = <ScreenshotTranslationWindowMessage>[];
      final delayedOldReuse = Completer<Object?>();
      final oldReuseStarted = Completer<void>();
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') {
          return [
            {'windowId': childId, 'windowArgument': arguments},
          ];
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method != 'invokeMethod') return null;
        final request = ScreenshotTranslationWindowMessage.fromMap(
          (call.arguments as Map)['arguments'],
        );
        requests.add(request);
        if (request.type == 'probe') {
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: request.requestId,
            payload: {'hostEpoch': request.payload['hostEpoch']},
          ).toMap();
        }
        if (request.type == 'sessionUpdated' &&
            request.payload['reuseImageForSessionId'] == 'older-session') {
          oldReuseStarted.complete();
          return delayedOldReuse.future;
        }
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: const {},
        ).toMap();
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });

      final oldHandle = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId(parentId),
        role: ScreenshotTranslationWindowRole.result,
      );
      final olderSession = ScreenshotTranslationSession(
        id: 'older-session',
        imageBytes: Uint8List.fromList([1, 2, 3, 4]),
        status: ScreenshotTranslationStatus.recognizing,
      );
      await oldHandle.update(olderSession);
      final delayedOldUpdate = oldHandle.update(
        olderSession.withState(ScreenshotTranslationStatus.translating),
      );
      await oldReuseStarted.future;

      final newHandle = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId(parentId),
        role: ScreenshotTranslationWindowRole.result,
      );
      final newerSession = ScreenshotTranslationSession(
        id: 'newer-session',
        imageBytes: Uint8List.fromList([5, 6, 7, 8]),
        status: ScreenshotTranslationStatus.recognizing,
      );
      await newHandle.update(newerSession);

      final olderRequest = requests.lastWhere(
        (request) =>
            request.type == 'sessionUpdated' &&
            request.payload['reuseImageForSessionId'] == 'older-session',
      );
      final newerRequest = requests.lastWhere(
        (request) =>
            request.type == 'sessionUpdated' &&
            (request.payload['session'] as Map?)?['id'] == 'newer-session',
      );
      expect(
        newerRequest.payload['connectionGeneration'],
        greaterThan(olderRequest.payload['connectionGeneration'] as int),
      );
      delayedOldReuse.complete(
        ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: olderRequest.requestId,
          payload: const {'errorCode': 'stale_update'},
        ).toMap(),
      );
      await expectLater(
        delayedOldUpdate,
        throwsA(isA<ScreenshotTranslationResultHandleSupersededException>()),
      );
      await expectLater(
        oldHandle.update(
          olderSession.withState(ScreenshotTranslationStatus.failed),
        ),
        throwsA(isA<ScreenshotTranslationResultHandleSupersededException>()),
      );

      final sessionUpdates = requests
          .where((request) => request.type == 'sessionUpdated')
          .toList();
      expect(sessionUpdates, hasLength(3));
      expect(
        sessionUpdates.any(
          (request) =>
              (request.payload['session'] as Map?)?['id'] == 'older-session' &&
              request.payload.containsKey('connectionGeneration') &&
              (request.payload['session'] as Map).containsKey('imageBytes') &&
              request.payload['updateSequence'] ==
                  olderRequest.payload['updateSequence'],
        ),
        isFalse,
      );
    },
  );
  test('an incompatible old result child is retired and replaced', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final childIds = <String>['old-result-child'];
    final createdArguments = const ScreenshotTranslationWindowArguments(
      role: ScreenshotTranslationWindowRole.result,
      parentWindowId: 'epoch-recovery-parent',
    ).encode();
    var createdFreshChild = false;
    messenger.setMockMethodCallHandler(windows, (call) async {
      if (call.method == 'getAllWindows') {
        return childIds
            .map((id) => {'windowId': id, 'windowArgument': createdArguments})
            .toList();
      }
      if (call.method == 'createWindow') {
        createdFreshChild = true;
        childIds.add('fresh-result-child');
        return 'fresh-result-child';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(channels, (call) async {
      if (call.method != 'invokeMethod') return null;
      final values = call.arguments as Map;
      final childId = (values['channel'] as String).split('/').last;
      final request = ScreenshotTranslationWindowMessage.fromMap(
        values['arguments'],
      );
      if (request.type == 'shutdownRequested') {
        childIds.remove(childId);
      }
      return ScreenshotTranslationWindowMessage(
        type: 'ack',
        requestId: request.requestId,
        payload: childId == 'fresh-result-child' && request.type == 'probe'
            ? {'hostEpoch': request.payload['hostEpoch']}
            : const {},
      ).toMap();
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(windows, null);
      messenger.setMockMethodCallHandler(channels, null);
    });

    final resultWindow = await ScreenshotTranslationWindowSession.create(
      parent: WindowController.fromWindowId('epoch-recovery-parent'),
      role: ScreenshotTranslationWindowRole.result,
      readinessTimeout: const Duration(milliseconds: 250),
    );

    expect(createdFreshChild, isTrue);
    expect(resultWindow.controller.windowId, 'fresh-result-child');
    expect(childIds, ['fresh-result-child']);
  });
  test(
    'a result child that never acknowledges is retired within one deadline',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final childIds = <String>['silent-result-child'];
      final arguments = const ScreenshotTranslationWindowArguments(
        role: ScreenshotTranslationWindowRole.result,
        parentWindowId: 'silent-child-parent',
      ).encode();
      final probedChildren = <String>[];
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') {
          return childIds
              .map((id) => {'windowId': id, 'windowArgument': arguments})
              .toList();
        }
        if (call.method == 'createWindow') {
          childIds.add('responsive-result-child');
          return 'responsive-result-child';
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method != 'invokeMethod') return null;
        final values = call.arguments as Map;
        final childId = (values['channel'] as String).split('/').last;
        final request = ScreenshotTranslationWindowMessage.fromMap(
          values['arguments'],
        );
        if (request.type == 'probe') {
          probedChildren.add(childId);
          if (childId == 'silent-result-child') {
            return Completer<Object?>().future;
          }
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: request.requestId,
            payload: {'hostEpoch': request.payload['hostEpoch']},
          ).toMap();
        }
        if (request.type == 'shutdownRequested') childIds.remove(childId);
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: const {},
        ).toMap();
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });

      final stopwatch = Stopwatch()..start();
      final resultWindow = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId('silent-child-parent'),
        role: ScreenshotTranslationWindowRole.result,
        readinessTimeout: const Duration(milliseconds: 800),
      );

      expect(resultWindow.controller.windowId, 'responsive-result-child');
      expect(probedChildren.toSet(), {
        'silent-result-child',
        'responsive-result-child',
      });
      expect(probedChildren.last, 'responsive-result-child');
      expect(childIds, ['responsive-result-child']);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1100)));
    },
  );
  for (final role in [
    ScreenshotTranslationWindowRole.orb,
    ScreenshotTranslationWindowRole.result,
  ]) {
    test(
      '${role.name} child is retired when activation acknowledgement times out',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const childId = 'activation-timeout-child';
        final childIds = <String>[childId];
        final arguments = ScreenshotTranslationWindowArguments(
          role: role,
          parentWindowId: 'activation-timeout-parent',
        ).encode();
        final requests = <String>[];
        final pendingActivation = Completer<Object?>();
        messenger.setMockMethodCallHandler(windows, (call) async {
          if (call.method == 'getAllWindows') {
            return childIds
                .map((id) => {'windowId': id, 'windowArgument': arguments})
                .toList();
          }
          return null;
        });
        messenger.setMockMethodCallHandler(channels, (call) async {
          if (call.method != 'invokeMethod') return null;
          final values = call.arguments as Map;
          final request = ScreenshotTranslationWindowMessage.fromMap(
            values['arguments'],
          );
          requests.add(request.type);
          if (request.type == 'probe') {
            return ScreenshotTranslationWindowMessage(
              type: 'ack',
              requestId: request.requestId,
              payload: role == ScreenshotTranslationWindowRole.result
                  ? {'hostEpoch': request.payload['hostEpoch']}
                  : const {},
            ).toMap();
          }
          if (request.type == 'shutdownRequested') {
            childIds.remove(childId);
            return ScreenshotTranslationWindowMessage(
              type: 'ack',
              requestId: request.requestId,
              payload: const {},
            ).toMap();
          }
          return pendingActivation.future;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(windows, null);
          messenger.setMockMethodCallHandler(channels, null);
        });

        final child = await ScreenshotTranslationWindowSession.create(
          parent: WindowController.fromWindowId('activation-timeout-parent'),
          role: role,
          readinessTimeout: const Duration(milliseconds: 250),
          activationAcknowledgementTimeout: const Duration(milliseconds: 20),
        );

        await expectLater(
          role == ScreenshotTranslationWindowRole.orb
              ? child.open(null)
              : child.update(
                  const ScreenshotTranslationSession(
                    id: 'late-result',
                    recognizedText: 'must not appear later',
                    status: ScreenshotTranslationStatus.completed,
                  ),
                ),
          throwsA(isA<TimeoutException>()),
        );

        expect(requests, contains('shutdownRequested'));
        expect(childIds, isEmpty);
      },
    );
  }
  test(
    'orb configuration acknowledgement waits for placement and first frame',
    () async {
      final placed = Completer<void>();
      final firstFrameRasterized = Completer<void>();
      var completed = false;
      var activated = false;
      final message = ScreenshotTranslationWindowMessage(
        type: 'orbConfigured',
        requestId: 'orb-first-frame',
        payload: const {},
      );

      final acknowledgement =
          acknowledgeScreenshotOrbConfiguredAfterFrame(
            message: message,
            position: () => placed.future,
            firstFrameRasterized: firstFrameRasterized.future,
            activate: () async {
              activated = true;
            },
            onFailure: () async {},
          ).then((value) {
            completed = true;
            return value;
          });

      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(activated, isFalse);
      placed.complete();
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(activated, isFalse);

      firstFrameRasterized.complete();
      final response = await acknowledgement;
      expect(completed, isTrue);
      expect(activated, isTrue);
      expect(response['type'], 'ack');
      expect(response['requestId'], 'orb-first-frame');
    },
  );
  test(
    'a child that misses its first frame is closed without activation',
    () async {
      final neverRasterizes = Completer<void>();
      var activated = false;
      var closed = false;

      await expectLater(
        activateScreenshotChildAfterFrame(
          firstFrameRasterized: neverRasterizes.future,
          timeout: const Duration(milliseconds: 10),
          activate: () async {
            activated = true;
          },
          onFailure: () async {
            closed = true;
          },
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(activated, isFalse);
      expect(closed, isTrue);
    },
  );
  test(
    'an orb closed during placement cannot show after a late first frame',
    () async {
      final placement = Completer<void>();
      var closing = false;
      var activated = false;
      var cleanupRequested = false;
      final message = ScreenshotTranslationWindowMessage(
        type: 'orbConfigured',
        requestId: 'orb-closed-during-placement',
        payload: const {},
      );

      final activation = acknowledgeScreenshotOrbConfiguredAfterFrame(
        message: message,
        position: () => placement.future,
        firstFrameRasterized: Future<void>.value(),
        canActivate: () => !closing,
        activate: () async => activated = true,
        onFailure: () async => cleanupRequested = true,
      );
      await Future<void>.delayed(Duration.zero);
      closing = true;
      placement.complete();

      await expectLater(activation, throwsA(isA<StateError>()));
      expect(activated, isFalse);
      expect(cleanupRequested, isTrue);
    },
  );
  test(
    'a superseded orb configuration is acknowledged without showing or cleanup',
    () async {
      final oldPositioned = Completer<void>();
      final oldFrame = Completer<void>();
      final newFrame = Completer<void>();
      var generation = 1;
      var activated = 0;
      var cleanupRequested = 0;
      final oldMessage = ScreenshotTranslationWindowMessage(
        type: 'orbConfigured',
        requestId: 'orb-config-old',
        payload: const {},
      );
      final newMessage = ScreenshotTranslationWindowMessage(
        type: 'orbConfigured',
        requestId: 'orb-config-new',
        payload: const {},
      );

      final oldAck = acknowledgeScreenshotOrbConfiguredAfterFrame(
        message: oldMessage,
        position: () => oldPositioned.future,
        firstFrameRasterized: oldFrame.future,
        canActivate: () => generation == 1,
        isClosing: () => false,
        activate: () async => activated++,
        onFailure: () async => cleanupRequested++,
      );
      await Future<void>.delayed(Duration.zero);
      oldPositioned.complete();
      await Future<void>.delayed(Duration.zero);
      generation = 2;

      final newAck = acknowledgeScreenshotOrbConfiguredAfterFrame(
        message: newMessage,
        position: () async {},
        firstFrameRasterized: newFrame.future,
        canActivate: () => generation == 2,
        isClosing: () => false,
        activate: () async => activated++,
        onFailure: () async => cleanupRequested++,
      );
      await Future<void>.delayed(Duration.zero);
      newFrame.complete();
      final newResponse = await newAck;
      oldFrame.complete();
      final oldResponse = await oldAck;

      expect(newResponse['requestId'], 'orb-config-new');
      expect(oldResponse['requestId'], 'orb-config-old');
      expect(activated, 1);
      expect(cleanupRequested, 0);
    },
  );
  for (final role in [
    ScreenshotTranslationWindowRole.orb,
    ScreenshotTranslationWindowRole.result,
  ]) {
    testWidgets(
      '${role.name} child requests Windows no-activate only for the orb',
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = <String>[];
        final nativeCalls = <String>[];
        final arguments = ScreenshotTranslationWindowArguments(
          role: role,
          parentWindowId: 'taskbar-parent',
        );
        messenger.setMockMethodCallHandler(windows, (call) async {
          if (call.method == 'getWindowDefinition') {
            return {
              'windowId': 'taskbar-child',
              'windowArgument': arguments.encode(),
            };
          }
          return null;
        });
        messenger.setMockMethodCallHandler(channels, (call) async => null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async {
            events.add('window_manager:${call.method}');
            if (call.method == 'isFullScreen' ||
                call.method == 'isMaximized' ||
                call.method == 'isMinimized') {
              return false;
            }
            if (call.method == 'getTitle') return 'screenshot-child';
            if (call.method == 'setAlwaysOnTop' && !Platform.isWindows) {
              throw PlatformException(
                code: 'stop_after_result_window_boundary',
              );
            }
            return null;
          },
        );
        messenger.setMockMethodCallHandler(nativeWindow, (call) async {
          nativeCalls.add(call.method);
          events.add('native_window:${call.method}');
          throw PlatformException(code: 'stop_after_native_window_boundary');
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(windows, null);
          messenger.setMockMethodCallHandler(channels, null);
          messenger.setMockMethodCallHandler(nativeWindow, null);
          messenger.setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            null,
          );
        });

        await runScreenshotTranslationChildWindow(
          await WindowController.fromCurrentEngine(),
        );
        await tester.pump();

        final expectedEvents = <String>[
          'window_manager:ensureInitialized',
          'window_manager:waitUntilReadyToShow',
        ];
        if (role == ScreenshotTranslationWindowRole.orb) {
          expectedEvents.addAll([
            'window_manager:setAsFrameless',
            'window_manager:setBackgroundColor',
            'window_manager:setMinimumSize',
            'window_manager:setBounds',
            'window_manager:setResizable',
            'window_manager:setSkipTaskbar',
            if (Platform.isWindows) 'native_window:setNoActivate',
          ]);
        } else {
          expectedEvents.addAll([
            'window_manager:setTitleBarStyle',
            'window_manager:setMinimumSize',
            'window_manager:setBounds',
            'window_manager:setSkipTaskbar',
            'window_manager:setPreventClose',
            // Widget tests mock the child ID but do not create its native
            // HWND. On Windows this verifies setup through title-based lookup;
            // the native topmost/show/placement path needs a real child window.
            if (Platform.isWindows) ...[
              'window_manager:getTitle',
              'window_manager:setTitle',
              'window_manager:setTitle',
            ] else
              'window_manager:setAlwaysOnTop',
          ]);
        }
        expect(events, containsAllInOrder(expectedEvents));
        expect(
          nativeCalls,
          Platform.isWindows && role == ScreenshotTranslationWindowRole.orb
              ? ['setNoActivate']
              : isEmpty,
        );
      },
    );
  }
  testWidgets(
    'startup exception unregisters handlers and closes only its child',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      final args = const ScreenshotTranslationWindowArguments(
        role: ScreenshotTranslationWindowRole.result,
        parentWindowId: 'failure-parent',
      ).encode();
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getWindowDefinition') {
          return {'windowId': 'startup-failure', 'windowArgument': args};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        calls.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          calls.add(call.method);
          if (call.method == 'ensureInitialized') {
            throw PlatformException(code: 'test_startup_failure');
          }
          return null;
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        );
      });
      await runScreenshotTranslationChildWindow(
        WindowController.fromWindowId('startup-failure'),
      );
      await tester.pump();
      expect(
        calls,
        containsAllInOrder([
          'registerMethodHandler',
          'ensureInitialized',
          'unregisterMethodHandler',
          'setPreventClose',
          'close',
        ]),
      );
      expect(calls, isNot(contains('show')));
      expect(calls, isNot(contains('destroy')));
    },
  );

  test(
    'failed child is closed, its handler is released, and a fresh child works',
    () async {
      final ids = <String>[];
      final retired = <String>[];
      final unregistered = <String>[];
      var created = 0;
      final args = const ScreenshotTranslationWindowArguments(
        role: ScreenshotTranslationWindowRole.result,
        parentWindowId: 'lifecycle-parent',
      ).encode();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') {
          return ids
              .map((id) => {'windowId': id, 'windowArgument': args})
              .toList();
        }
        if (call.method == 'createWindow') {
          final id = 'lifecycle-${++created}';
          ids.add(id);
          return id;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        final values = call.arguments as Map;
        if (call.method == 'unregisterMethodHandler') {
          unregistered.add(values['channel'] as String);
          return null;
        }
        if (call.method != 'invokeMethod') return null;
        final request = ScreenshotTranslationWindowMessage.fromMap(
          values['arguments'],
        );
        final id = (values['channel'] as String).split('/').last;
        if (request.type == 'shutdownRequested') {
          retired.add(id);
          ids.remove(id);
        } else if (id == 'lifecycle-1') {
          throw PlatformException(code: 'child_startup_failed');
        }
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: request.type == 'probe'
              ? {'hostEpoch': request.payload['hostEpoch']}
              : const {},
        ).toMap();
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });
      final healthy = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId('lifecycle-parent'),
        role: ScreenshotTranslationWindowRole.result,
        readinessTimeout: const Duration(milliseconds: 60),
      );
      expect(retired, ['lifecycle-1']);
      expect(unregistered, ['yixue/screenshot_translation/window/lifecycle-1']);
      expect(healthy.controller.windowId, 'lifecycle-2');
      expect(created, 2);
      expect(ids, ['lifecycle-2']);
    },
  );

  test(
    'a hung handler registration is bounded and isolated to its child id',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const parentId = 'hung-parent-handler-registration-parent';
      final ids = <String>[];
      var created = 0;
      var childRetirements = 0;
      final args = const ScreenshotTranslationWindowArguments(
        role: ScreenshotTranslationWindowRole.result,
        parentWindowId: parentId,
      ).encode();
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') {
          return ids
              .map((id) => {'windowId': id, 'windowArgument': args})
              .toList();
        }
        if (call.method == 'createWindow') {
          final id = 'hung-parent-registration-${++created}';
          ids.add(id);
          return id;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        final values = call.arguments as Map;
        if (call.method == 'registerMethodHandler' &&
            (values['channel'] as String).endsWith(
              'hung-parent-registration-1',
            )) {
          return Completer<Object?>().future;
        }
        if (call.method == 'invokeMethod') {
          final request = ScreenshotTranslationWindowMessage.fromMap(
            values['arguments'],
          );
          final id = (values['channel'] as String).split('/').last;
          if (request.type == 'probe') {
            return ScreenshotTranslationWindowMessage(
              type: 'ack',
              requestId: request.requestId,
              payload: {'hostEpoch': request.payload['hostEpoch']},
            ).toMap();
          }
          if (request.type == 'shutdownRequested') {
            childRetirements++;
            ids.remove(id);
            return ScreenshotTranslationWindowMessage(
              type: 'ack',
              requestId: request.requestId,
              payload: {'retired': true},
            ).toMap();
          }
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });

      final stopwatch = Stopwatch()..start();
      await expectLater(
        ScreenshotTranslationWindowSession.create(
          parent: WindowController.fromWindowId(parentId),
          role: ScreenshotTranslationWindowRole.result,
          readinessTimeout: const Duration(milliseconds: 30),
        ),
        throwsA(isA<ScreenshotTranslationWindowConnectionException>()),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(childRetirements, 1);
      expect(ids, isEmpty);

      final retry = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId(parentId),
        role: ScreenshotTranslationWindowRole.result,
        readinessTimeout: const Duration(milliseconds: 300),
      );
      expect(retry.controller.windowId, 'hung-parent-registration-2');
      expect(created, 2);
      await retry.close();
    },
  );

  test(
    'repeated child startup failures stop creating unbounded child windows',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const parentId = 'startup-failure-budget-parent';
      final ids = <String>[];
      var created = 0;
      var failProbe = false;
      final args = const ScreenshotTranslationWindowArguments(
        role: ScreenshotTranslationWindowRole.orb,
        parentWindowId: parentId,
      ).encode();
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') {
          return ids
              .map((id) => {'windowId': id, 'windowArgument': args})
              .toList();
        }
        if (call.method == 'createWindow') {
          final id = 'startup-failure-budget-${++created}';
          ids.add(id);
          return id;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        final values = call.arguments as Map;
        if (call.method == 'invokeMethod') {
          final request = ScreenshotTranslationWindowMessage.fromMap(
            values['arguments'],
          );
          if (request.type == 'probe') {
            if (failProbe) {
              throw PlatformException(code: 'child_startup_failed');
            }
            return ScreenshotTranslationWindowMessage(
              type: 'ack',
              requestId: request.requestId,
              payload: const {},
            ).toMap();
          }
          if (request.type == 'shutdownRequested') {
            ids.remove((values['channel'] as String).split('/').last);
            return ScreenshotTranslationWindowMessage(
              type: 'ack',
              requestId: request.requestId,
              payload: {'retired': true},
            ).toMap();
          }
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });

      // Establish a clean successful streak boundary before inducing faults.
      final healthy = await ScreenshotTranslationWindowSession.create(
        parent: WindowController.fromWindowId(parentId),
        role: ScreenshotTranslationWindowRole.orb,
      );
      await healthy.close();
      expect(ids, isEmpty);
      failProbe = true;
      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          ScreenshotTranslationWindowSession.create(
            parent: WindowController.fromWindowId(parentId),
            role: ScreenshotTranslationWindowRole.orb,
            readinessTimeout: const Duration(milliseconds: 80),
          ),
          throwsA(isA<ScreenshotTranslationWindowConnectionException>()),
        );
      }
      await expectLater(
        ScreenshotTranslationWindowSession.create(
          parent: WindowController.fromWindowId(parentId),
          role: ScreenshotTranslationWindowRole.orb,
          readinessTimeout: const Duration(milliseconds: 80),
        ),
        throwsA(
          isA<ScreenshotTranslationWindowConnectionException>().having(
            (error) => error.message,
            'message',
            contains('consecutive'),
          ),
        ),
      );
      // One healthy baseline plus the three failed child windows.
      expect(created, 4);
      expect(ids, isEmpty);
    },
  );

  test(
    'hung readiness probe obeys one overall deadline and still cleans up',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var cleaned = false;
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'getAllWindows') return <Object>[];
        if (call.method == 'createWindow') return 'hung-probe-child';
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method != 'invokeMethod') return null;
        final request = ScreenshotTranslationWindowMessage.fromMap(
          (call.arguments as Map)['arguments'],
        );
        if (request.type == 'probe') return Completer<Object?>().future;
        if (request.type == 'shutdownRequested') cleaned = true;
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: request.requestId,
          payload: const {},
        ).toMap();
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });
      final stopwatch = Stopwatch()..start();
      await expectLater(
        ScreenshotTranslationWindowSession.create(
          parent: WindowController.fromWindowId('hung-parent'),
          role: ScreenshotTranslationWindowRole.result,
          readinessTimeout: const Duration(milliseconds: 70),
        ),
        throwsA(isA<Exception>()),
      );
      expect(stopwatch.elapsedMilliseconds, lessThan(300));
      expect(cleaned, isTrue);
    },
  );
}
