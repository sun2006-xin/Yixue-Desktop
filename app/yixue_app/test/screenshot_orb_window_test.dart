import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/features/brand/brand_mark.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_orb_window.dart';
import 'package:yixue_app/features/settings/screenshot_translation_settings_card.dart';

import 'screenshot_translation_preferences_test.dart' as fakes;

void main() {
  testWidgets('right menu waits for the expanded viewport layout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(56, 56));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final navigatorKey = GlobalKey<NavigatorState>();
    final observedViewportSizes = <Size>[];
    final observer = _RecordingNavigatorObserver(() {
      final overlay = navigatorKey.currentState?.overlay;
      final renderObject = overlay?.context.findRenderObject();
      if (renderObject is RenderBox && renderObject.hasSize) {
        observedViewportSizes.add(renderObject.size);
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [observer],
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ScreenshotOrbWindow(
              onCapture: () {},
              onMenu: (_) {},
              onDrag: () async {},
              beforeMenu: () async {
                await tester.binding.setSurfaceSize(const Size(240, 280));
              },
            ),
          ),
        ),
      ),
    );
    observedViewportSizes.clear();

    final rightClick = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('screenshot-orb'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();

    expect(observedViewportSizes, hasLength(1));
    expect(observedViewportSizes.single, const Size(240, 280));
  });

  testWidgets('right menu opens after the secondary click is released', (
    tester,
  ) async {
    var beforeMenuCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ScreenshotOrbWindow(
              onCapture: () {},
              onMenu: (_) {},
              onDrag: () async {},
              beforeMenu: () async => beforeMenuCalls++,
            ),
          ),
        ),
      ),
    );

    final rightClick = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('screenshot-orb'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    expect(beforeMenuCalls, 0);
    expect(find.byType(PopupMenuItem<ScreenshotOrbMenuAction>), findsNothing);

    await rightClick.up();
    await tester.pumpAndSettle();

    expect(beforeMenuCalls, 1);
    expect(
      find.byType(PopupMenuItem<ScreenshotOrbMenuAction>),
      findsNWidgets(7),
    );
  });

  testWidgets('right mouse button is detected when other button bits are set', (
    tester,
  ) async {
    var captures = 0;
    await tester.pumpWidget(_orbApp(onCapture: () => captures++));

    final rightClick = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('screenshot-orb'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton | kPrimaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();

    expect(captures, 0);
    expect(
      find.byType(PopupMenuItem<ScreenshotOrbMenuAction>),
      findsNWidgets(7),
    );
  });

  final approvedActions = {
    '截屏翻译': ScreenshotOrbMenuAction.capture,
    '划词查词': ScreenshotOrbMenuAction.dictionaryLookup,
    '打开译学工作台': ScreenshotOrbMenuAction.openMain,
    '快捷键设置': ScreenshotOrbMenuAction.shortcutSettings,
    '关闭悬浮球': ScreenshotOrbMenuAction.disableOrb,
    '退出译学': ScreenshotOrbMenuAction.quit,
  };
  for (final entry in approvedActions.entries) {
    testWidgets('right menu emits only the ${entry.value.name} action', (
      tester,
    ) async {
      var captures = 0;
      final actions = <ScreenshotOrbMenuAction>[];
      await tester.pumpWidget(
        _orbApp(onCapture: () => captures++, onMenu: actions.add),
      );
      final click = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('screenshot-orb'))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await click.up();
      await tester.pumpAndSettle();
      expect(captures, 0);
      expect(actions, isEmpty);
      expect(find.byKey(const ValueKey('orb-capture-ripple')), findsNothing);
      expect(
        find.byType(PopupMenuItem<ScreenshotOrbMenuAction>),
        findsNWidgets(7),
      );
      await tester.tap(find.text(entry.key).last);
      await tester.pumpAndSettle();
      expect(actions, [entry.value]);
      expect(captures, 0);
    });
  }
  testWidgets('right menu can be explicitly dismissed without a command', (
    tester,
  ) async {
    final actions = <ScreenshotOrbMenuAction>[];
    var afterMenuCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenshotOrbWindow(
            onCapture: () {},
            onMenu: actions.add,
            onDrag: () async {},
            afterMenu: () async => afterMenuCalls++,
          ),
        ),
      ),
    );
    final rightClick = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('screenshot-orb'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('screenshot-orb-menu-dismiss')));
    await tester.pumpAndSettle();

    expect(find.byType(PopupMenuItem<ScreenshotOrbMenuAction>), findsNothing);
    expect(actions, isEmpty);
    expect(afterMenuCalls, 1);
  });
  testWidgets(
    'hover animates within fixed orb bounds; capture ripple runs once',
    (tester) async {
      var captures = 0;
      await tester.pumpWidget(_orbApp(onCapture: () => captures++));
      final orb = find.byKey(const ValueKey('screenshot-orb'));
      expect(tester.getSize(orb), const Size(56, 56));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(orb));
      await tester.pump();
      final hover = tester.widget<AnimatedScale>(
        find.byKey(const ValueKey('orb-hover-scale')),
      );
      expect(hover.scale, greaterThan(1));
      expect(hover.duration, const Duration(milliseconds: 200));
      expect(tester.getSize(orb), const Size(56, 56));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.hasRunningAnimations, isFalse);
      await mouse.down(tester.getCenter(orb));
      await tester.pump();
      final press = tester.widget<AnimatedScale>(
        find.byKey(const ValueKey('orb-press-scale')),
      );
      expect(press.scale, lessThan(1));
      expect(press.duration, const Duration(milliseconds: 90));
      await tester.pump(const Duration(milliseconds: 100));
      await mouse.up();
      await tester.pump();
      expect(captures, 1);
      final ripple = find.byKey(const ValueKey('orb-capture-ripple'));
      expect(ripple, findsOneWidget);
      final initialOpacity = tester.widget<Opacity>(ripple).opacity;
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<Opacity>(ripple).opacity, lessThan(initialOpacity));
      await tester.pump(const Duration(milliseconds: 320));
      expect(ripple, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pump(const Duration(seconds: 5));
      expect(ripple, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AnimatedScale>(
              find.byKey(const ValueKey('orb-hover-scale')),
            )
            .scale,
        1,
      );
    },
  );
  testWidgets('hover highlight stays inside the orb with no cast shadow', (
    tester,
  ) async {
    await tester.pumpWidget(_orbApp());
    final orb = find.byKey(const ValueKey('screenshot-orb'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(orb));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(tester.getSize(orb), const Size(56, 56));
    expect(find.byKey(const ValueKey('orb-hover-highlight')), findsOneWidget);
    final surface = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('orb-surface')),
    );
    expect((surface.decoration! as BoxDecoration).boxShadow, isEmpty);
    expect(
      tester
          .widget<AnimatedScale>(find.byKey(const ValueKey('orb-hover-scale')))
          .scale,
      greaterThanOrEqualTo(1.06),
    );

    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets('capture gives a visible ring and flash after pointer release', (
    tester,
  ) async {
    var captures = 0;
    await tester.pumpWidget(_orbApp(onCapture: () => captures++));
    final orb = find.byKey(const ValueKey('screenshot-orb'));
    final click = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await click.addPointer(location: tester.getCenter(orb));
    await click.down(tester.getCenter(orb));
    await tester.pump(const Duration(milliseconds: 45));
    expect(
      tester
          .widget<AnimatedScale>(find.byKey(const ValueKey('orb-press-scale')))
          .scale,
      lessThan(0.94),
    );
    await click.up();
    await tester.pump();

    expect(captures, 1);
    expect(find.byKey(const ValueKey('orb-capture-flash')), findsOneWidget);
    final ring = tester.widget<Opacity>(
      find.byKey(const ValueKey('orb-capture-ripple')),
    );
    final initialRingScale = tester
        .widget<Transform>(find.byKey(const ValueKey('orb-capture-ring-scale')))
        .transform
        .storage
        .first;
    await tester.pump(const Duration(milliseconds: 180));
    expect(
      tester
          .widget<Opacity>(find.byKey(const ValueKey('orb-capture-ripple')))
          .opacity,
      lessThan(ring.opacity),
    );
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('orb-capture-ring-scale')),
          )
          .transform
          .storage
          .first,
      greaterThan(initialRingScale),
    );

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('orb-capture-flash')), findsNothing);
  });

  testWidgets(
    'reduced motion retains immediate hover press and capture feedback',
    (tester) async {
      await tester.pumpWidget(_orbApp(disableAnimations: true));
      final orb = find.byKey(const ValueKey('screenshot-orb'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(orb));
      await tester.pump();
      expect(
        tester
            .widget<AnimatedScale>(
              find.byKey(const ValueKey('orb-hover-scale')),
            )
            .duration,
        Duration.zero,
      );
      expect(tester.hasRunningAnimations, isFalse);
      await mouse.down(tester.getCenter(orb));
      await tester.pump();
      expect(
        tester
            .widget<AnimatedScale>(
              find.byKey(const ValueKey('orb-press-scale')),
            )
            .scale,
        lessThan(1),
      );
      expect(
        tester
            .widget<AnimatedScale>(
              find.byKey(const ValueKey('orb-press-scale')),
            )
            .duration,
        Duration.zero,
      );
      await mouse.up();
      await tester.pump();
      final ripple = find.byKey(const ValueKey('orb-capture-ripple'));
      expect(ripple, findsOneWidget);
      final opacity = tester.widget<Opacity>(ripple).opacity;
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.widget<Opacity>(ripple).opacity, opacity);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pump(const Duration(milliseconds: 80));
      expect(ripple, findsNothing);
      await mouse.removePointer();
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'drag escape pointer cancel and menu escape restore neutral input',
    (tester) async {
      var captures = 0, drags = 0, restores = 0;
      final drag = Completer<void>();
      await tester.pumpWidget(
        _orbApp(
          onCapture: () => captures++,
          onDrag: () async {
            drags++;
            await drag.future;
          },
          afterMenu: () async => restores++,
        ),
      );
      final center = tester.getCenter(
        find.byKey(const ValueKey('screenshot-orb')),
      );
      final pointer = await tester.startGesture(center);
      await pointer.moveBy(const Offset(12, 0));
      await tester.pump();
      expect(drags, 1);
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const ValueKey('orb-pointer-region')),
            )
            .cursor,
        SystemMouseCursors.grabbing,
      );
      drag.complete();
      await pointer.up();
      await tester.pumpAndSettle();
      expect(captures, 0);
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const ValueKey('orb-pointer-region')),
            )
            .cursor,
        SystemMouseCursors.click,
      );
      final cancel = await tester.startGesture(center);
      await cancel.cancel();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AnimatedScale>(
              find.byKey(const ValueKey('orb-press-scale')),
            )
            .scale,
        1,
      );
      final escape = await tester.startGesture(center);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await escape.up();
      await tester.pumpAndSettle();
      expect(captures, 0);
      final right = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(restores, 1);
      expect(find.byType(PopupMenuItem<ScreenshotOrbMenuAction>), findsNothing);
      await tester.tap(find.byKey(const ValueKey('screenshot-orb')));
      await tester.pumpAndSettle();
      expect(captures, 1);
    },
  );
  testWidgets(
    'circular orb exposes capture semantics and leaves corners to background',
    (tester) async {
      var captures = 0, background = 0;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => background++,
              child: Center(
                child: ScreenshotOrbWindow(
                  onCapture: () => captures++,
                  onMenu: (_) {},
                  onDrag: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      final orb = find.byKey(const ValueKey('screenshot-orb'));
      final node = tester.getSemantics(
        find.byKey(const ValueKey('orb-capture-semantics')),
      );
      expect(
        node,
        matchesSemantics(
          label: '截屏翻译',
          isButton: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
      );
      await tester.tapAt(tester.getTopLeft(orb) + const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(background, 1);
      expect(captures, 0);
      await tester.tap(orb);
      await tester.pumpAndSettle();
      expect(captures, 1);
      semantics.dispose();
    },
  );
  testWidgets(
    'exit recovery has visible native close control that retries exit through close listener',
    (tester) async {
      var exits = 0, closeEvents = 0;
      Future<void>? retry;
      final desktop = fakes.createDesktop(
        fakes.MemoryPrefs(),
        fakes.FakeHotKeys(),
        fakes.FakeOrb(),
        onExit: () async {
          if (++exits == 1) throw StateError('host close failed');
        },
      );
      await desktop.initialize();
      await desktop.quit();
      final listener = _CloseListener(() {
        closeEvents++;
        retry = desktop.handleMainClose();
      });
      windowManager.addListener(listener);
      final nativeCalls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          nativeCalls.add(call.method);
          if (call.method == 'close') {
            tester.binding.channelBuffers.push(
              'window_manager',
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('onEvent', {'eventName': 'close'}),
              ),
              (_) {},
            );
          }
          return null;
        },
      );
      addTearDown(() {
        windowManager.removeListener(listener);
        messenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        );
        desktop.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationExitRecovery(controller: desktop),
        ),
      );
      final close = find.byKey(const ValueKey('window-close'));
      expect(close, findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      await retry;
      expect(nativeCalls, ['close']);
      expect(closeEvents, 1);
      expect(exits, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'focused orb has visible focus and Enter/Space activate capture',
    (tester) async {
      var captures = 0;
      await tester.pumpWidget(_orbApp(onCapture: () => captures++));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(captures, 0);
      final surface = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('orb-surface')),
      );
      final surfaceDecoration = surface.decoration! as BoxDecoration;
      expect(surfaceDecoration.border!.top.width, 2.5);
      expect(surfaceDecoration.boxShadow, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(captures, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(captures, 2);
    },
  );
  testWidgets(
    'exit recovery offers only exit retry and prevents duplicate host calls',
    (tester) async {
      var exits = 0, recoveries = 0;
      final retry = Completer<void>();
      final desktop = fakes.createDesktop(
        fakes.MemoryPrefs(),
        fakes.FakeHotKeys(),
        fakes.FakeOrb(),
        onExit: () async {
          if (++exits == 1) throw StateError('host close failed');
          await retry.future;
        },
        onExitFailure: () async => recoveries++,
      );
      await desktop.initialize();
      await desktop.quit();
      expect(recoveries, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationExitRecovery(controller: desktop),
        ),
      );
      expect(find.text('退出未完成'), findsOneWidget);
      expect(find.byType(ScreenshotTranslationSettingsCard), findsNothing);
      await tester.tap(find.text('重试退出'));
      await tester.pump();
      expect(find.text('正在退出…'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      final duplicate = desktop.quit();
      expect(exits, 2);
      retry.complete();
      await duplicate;
      expect(exits, 2);
      await tester.pumpWidget(const SizedBox());
      desktop.dispose();
    },
  );
  testWidgets(
    'viewport restoration failure still dispatches menu and permits reopening',
    (tester) async {
      final actions = <ScreenshotOrbMenuAction>[];
      var restores = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScreenshotOrbWindow(
              onCapture: () {},
              onMenu: actions.add,
              onDrag: () async {},
              afterMenu: () async {
                restores++;
                throw StateError('native resize failed');
              },
            ),
          ),
        ),
      );
      for (final label in ['退出译学', '打开译学工作台', '快捷键设置']) {
        final click = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('screenshot-orb'))),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await click.up();
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(actions, [
        ScreenshotOrbMenuAction.quit,
        ScreenshotOrbMenuAction.openMain,
        ScreenshotOrbMenuAction.shortcutSettings,
      ]);
      expect(restores, 3);
    },
  );
  for (final label in ['打开译学工作台', '退出译学', 'cancel']) {
    testWidgets('right menu $label restores the orb viewport', (tester) async {
      final events = <String>[];
      ScreenshotOrbMenuAction? action;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScreenshotOrbWindow(
              onCapture: () => events.add('capture'),
              onMenu: (value) => action = value,
              onDrag: () async {},
              beforeMenu: () async => events.add('expand'),
              afterMenu: () async => events.add('restore'),
            ),
          ),
        ),
      );
      final click = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('screenshot-orb'))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await click.up();
      await tester.pumpAndSettle();
      if (label == 'cancel') {
        Navigator.of(tester.element(find.byType(ScreenshotOrbWindow))).pop();
      } else {
        await tester.tap(find.text(label));
      }
      await tester.pumpAndSettle();
      expect(events, ['expand', 'restore']);
      expect(action, switch (label) {
        '打开译学工作台' => ScreenshotOrbMenuAction.openMain,
        '退出译学' => ScreenshotOrbMenuAction.quit,
        _ => null,
      });
    });
  }
  for (final cancel in ['escape', 'button', 'save failure']) {
    testWidgets('recording $cancel restores the original system chord', (
      tester,
    ) async {
      final store = fakes.MemoryPrefs();
      final events = <String>[];
      final driver = fakes.FakeHotKeys(events: events);
      final desktop = fakes.createDesktop(
        store,
        driver,
        fakes.FakeOrb(),
        events: events,
      );
      await desktop.initialize();
      final staleCallback = driver.pressed!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScreenshotTranslationSettingsCard(controller: desktop),
          ),
        ),
      );
      await tester.tap(find.text('修改快捷键'));
      await tester.pumpAndSettle();
      expect(desktop.hotKeyRecording, isTrue);
      staleCallback();
      expect(events, isNot(contains('capture')));
      if (cancel == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else if (cancel == 'button') {
        await tester.tap(find.text('取消录制'));
      } else {
        store.fail = true;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.keyU,
          physicalKey: PhysicalKeyboardKey.keyU,
        );
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.keyU,
          physicalKey: PhysicalKeyboardKey.keyU,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
      await tester.pumpAndSettle();
      expect(desktop.hotKeyRecording, isFalse);
      expect(desktop.hotKeyRegistered, isTrue);
      expect(desktop.preferences.hotKey, const ScreenshotHotKey());
      expect(store.value.hotKey, const ScreenshotHotKey());
      if (cancel == 'save failure') {
        expect(desktop.saveError, isNotNull);
        expect(find.text(desktop.saveError!), findsOneWidget);
      }
      driver.pressed!();
      expect(events, contains('capture'));
      await tester.pumpWidget(const SizedBox());
      await desktop.shutdown();
      desktop.dispose();
    });
  }
  test(
    'snap uses nearest physical monitor with scaled 12 logical px margin',
    () {
      final displays = [
        const ScreenshotOrbDisplay(Rect.fromLTWH(-1920, 0, 1920, 1080), 1),
        const ScreenshotOrbDisplay(Rect.fromLTWH(0, 0, 2560, 1600), 1.5),
      ];
      expect(
        snapScreenshotOrb(const Offset(-100, 300), displays),
        const Offset(-68, 300),
      );
      expect(
        snapScreenshotOrb(const Offset(-400, 300), displays),
        const Offset(-400, 12),
      );
      expect(
        snapScreenshotOrb(const Offset(2500, 600), displays),
        const Offset(2458, 600),
      );
      final restored = snapScreenshotOrb(const Offset(9000, 9000), displays);
      expect(restored.dx, lessThanOrEqualTo(2458));
      expect(restored.dy, lessThanOrEqualTo(1498));
    },
  );
  test('hover resize preserves the orb screen anchor on the right edge', () {
    const workArea = Rect.fromLTWH(0, 0, 2560, 1600);
    const scale = 1.5;
    const display = ScreenshotOrbDisplay(workArea, scale);
    final anchor = snapScreenshotOrb(const Offset(2559, 760), const [display]);
    final compact = layoutScreenshotOrbWindow(
      anchor: anchor,
      workArea: workArea,
      scale: scale,
      logicalSize: const Size(56, 56),
    );
    final expanded = layoutScreenshotOrbWindow(
      anchor: anchor,
      workArea: workArea,
      scale: scale,
      logicalSize: const Size(140, 96),
    );

    Offset globalOrbOrigin(ScreenshotOrbWindowLayout layout) =>
        layout.origin + layout.contentOffset * scale;
    expect(globalOrbOrigin(compact), anchor);
    expect(globalOrbOrigin(expanded), anchor);
    expect(expanded.origin.dx, workArea.right - 140 * scale);
    expect(expanded.origin.dx + expanded.physicalSize.width, workArea.right);
  });

  testWidgets('56 logical px branded orb is still and left click captures', (
    tester,
  ) async {
    var captures = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: ScreenshotOrbWindow(
            onCapture: () => captures++,
            onMenu: (_) {},
            onDrag: () async {},
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('screenshot-orb'))),
      const Size(56, 56),
    );
    final image = tester.widget<Image>(find.byKey(const ValueKey('orb-brand')));
    expect((image.image as AssetImage).assetName, YixueBrandMark.assetPath);
    final surface = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('orb-surface')),
    );
    expect((surface.decoration! as BoxDecoration).gradient!.colors, [
      AppTheme.vitality().colorScheme.primary,
      YixueShellPalette.vitality.selectedEnd,
    ]);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.tap(find.byKey(const ValueKey('screenshot-orb')));
    await tester.pump();
    expect(captures, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.hasRunningAnimations, isFalse);
  });
  testWidgets(
    'movement below 5 px remains click; threshold drag never captures',
    (tester) async {
      var captures = 0, drags = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScreenshotOrbWindow(
              onCapture: () => captures++,
              onMenu: (_) {},
              onDrag: () async {
                drags++;
              },
            ),
          ),
        ),
      );
      final center = tester.getCenter(
        find.byKey(const ValueKey('screenshot-orb')),
      );
      var gesture = await tester.startGesture(center);
      await gesture.moveTo(center + const Offset(4, 0));
      await gesture.up();
      expect(captures, 1);
      gesture = await tester.startGesture(center);
      await gesture.moveTo(center + const Offset(5, 0));
      await gesture.moveTo(center + const Offset(12, 0));
      await gesture.up();
      await tester.pump();
      expect(captures, 1);
      expect(drags, 1);
    },
  );
  test('orb native viewport only has stable and context-menu modes', () {
    expect(ScreenshotOrbWindowMode.values, [
      ScreenshotOrbWindowMode.orb,
      ScreenshotOrbWindowMode.contextMenu,
    ]);
    expect(
      screenshotOrbWindowSizeForMode(ScreenshotOrbWindowMode.orb),
      const Size(56, 56),
    );
    expect(
      screenshotOrbWindowSizeForMode(ScreenshotOrbWindowMode.contextMenu),
      const Size(240, 360),
    );
  });

  testWidgets(
    'repeated hover at the right edge keeps orb bounds and viewport fixed',
    (tester) async {
      const viewport = Size(135, 56);
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                Positioned(
                  left: viewport.width - ScreenshotOrbWindow.diameter,
                  top: 0,
                  child: ScreenshotOrbWindow(
                    onCapture: () {},
                    onMenu: (_) {},
                    onDrag: () async {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final orb = find.byKey(const ValueKey('screenshot-orb'));
      final initialBounds = tester.getRect(orb);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: initialBounds.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      Size overlaySize() =>
          (navigatorKey.currentState!.overlay!.context.findRenderObject()!
                  as RenderBox)
              .size;

      for (var cycle = 0; cycle < 3; cycle++) {
        expect(tester.getSize(orb), const Size(56, 56));
        expect(tester.getRect(orb), initialBounds);
        expect(overlaySize(), viewport);
        expect(
          tester
              .widget<AnimatedScale>(
                find.byKey(const ValueKey('orb-hover-scale')),
              )
              .scale,
          greaterThan(1),
        );

        await mouse.moveTo(const Offset(78, 28));
        await tester.pump(const Duration(milliseconds: 220));
        expect(
          tester
              .widget<AnimatedScale>(
                find.byKey(const ValueKey('orb-hover-scale')),
              )
              .scale,
          1,
        );
        await mouse.moveTo(initialBounds.center);
        await tester.pump(const Duration(milliseconds: 220));
      }

      expect(tester.getRect(orb), initialBounds);
      expect(overlaySize(), viewport);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    },
  );

  testWidgets('right menu has exactly approved actions and orb semantics', (
    tester,
  ) async {
    ScreenshotOrbMenuAction? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenshotOrbWindow(
            onCapture: () {},
            onMenu: (value) => action = value,
            onDrag: () async {},
          ),
        ),
      ),
    );
    final center = tester.getCenter(
      find.byKey(const ValueKey('screenshot-orb')),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byKey(const ValueKey('orb-capture-semantics')), findsOneWidget);
    await mouse.removePointer();
    final click = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await click.up();
    await tester.pumpAndSettle();
    expect(find.text('打开译学工作台'), findsOneWidget);
    expect(find.text('快捷键设置'), findsOneWidget);
    expect(find.text('划词查词'), findsOneWidget);
    expect(find.text('关闭悬浮球'), findsOneWidget);
    expect(find.text('退出译学'), findsOneWidget);
    expect(find.text('收起菜单'), findsOneWidget);
    expect(
      find.byType(PopupMenuItem<ScreenshotOrbMenuAction>),
      findsNWidgets(7),
    );
    expect(find.byType(PopupMenuDivider), findsNWidgets(3));
    expect(find.byIcon(Icons.crop_free_rounded), findsOneWidget);
    expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
    expect(find.byIcon(Icons.dashboard_outlined), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_alt_outlined), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    expect(find.byIcon(Icons.power_settings_new_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    await tester.tap(find.text('快捷键设置'));
    await tester.pumpAndSettle();
    expect(action, ScreenshotOrbMenuAction.shortcutSettings);
  });
  testWidgets('right menu dispatches each of the seven approved actions', (
    tester,
  ) async {
    const labels = <String, ScreenshotOrbMenuAction>{
      '截屏翻译': ScreenshotOrbMenuAction.capture,
      '划词查词': ScreenshotOrbMenuAction.dictionaryLookup,
      '打开译学工作台': ScreenshotOrbMenuAction.openMain,
      '快捷键设置': ScreenshotOrbMenuAction.shortcutSettings,
      '关闭悬浮球': ScreenshotOrbMenuAction.disableOrb,
      '退出译学': ScreenshotOrbMenuAction.quit,
    };
    final actions = <ScreenshotOrbMenuAction>[];
    await tester.pumpWidget(_orbApp(onMenu: actions.add));

    for (final entry in labels.entries) {
      final rightClick = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('screenshot-orb'))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await rightClick.up();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('screenshot-orb-menu-${entry.value.name}')),
      );
      await tester.pumpAndSettle();
    }

    expect(actions, labels.values.toList());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'legacy settings reject occupied chord and keep the saved shortcut',
    (tester) async {
      final store = fakes.MemoryPrefs();
      final driver = fakes.FakeHotKeys();
      final desktop = fakes.createDesktop(store, driver, fakes.FakeOrb());
      await desktop.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScreenshotTranslationSettingsCard(controller: desktop),
          ),
        ),
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(store.value.orbEnabled, isFalse);
      const occupied = ScreenshotHotKey(
        keyCode: 0x70018,
        modifiers: ['control', 'alt'],
      );
      driver.conflictKey = occupied;
      await tester.tap(find.text('修改快捷键'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyU,
        physicalKey: PhysicalKeyboardKey.keyU,
      );
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.keyU,
        physicalKey: PhysicalKeyboardKey.keyU,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(desktop.preferences.hotKey.label, 'Ctrl+Alt+Y');
      expect(
        store.value.hotKey,
        const ScreenshotTranslationPreferences().hotKey,
      );
      expect(desktop.hotKeyRegistered, isTrue);
      expect(find.textContaining('占用'), findsWidgets);
      expect(find.text('修改快捷键'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await desktop.shutdown();
      desktop.dispose();
    },
  );
}

final class _RecordingNavigatorObserver extends NavigatorObserver {
  _RecordingNavigatorObserver(this.onRoutePushed);

  final VoidCallback onRoutePushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onRoutePushed();
    super.didPush(route, previousRoute);
  }
}

Widget _orbApp({
  VoidCallback? onCapture,
  ValueChanged<ScreenshotOrbMenuAction>? onMenu,
  Future<void> Function()? onDrag,
  Future<void> Function()? afterMenu,
  bool disableAnimations = false,
}) => MaterialApp(
  theme: AppTheme.vitality(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: ScreenshotOrbWindow(
          onCapture: onCapture ?? () {},
          onMenu: onMenu ?? (_) {},
          onDrag: onDrag ?? () async {},
          afterMenu: afterMenu,
        ),
      ),
    ),
  ),
);

class _CloseListener with WindowListener {
  _CloseListener(this.onClose);
  final VoidCallback onClose;
  @override
  void onWindowClose() => onClose();
}
