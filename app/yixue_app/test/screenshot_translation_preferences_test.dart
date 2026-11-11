import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_window_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  recordingAndPositionRegressions();

  test('capture hides and restores the layered orb even on failure', () async {
    final events = <String>[];
    final orb = _CaptureAwareOrb(events);
    final desktop = createDesktop(
      MemoryPrefs(),
      FakeHotKeys(events: events),
      orb,
      events: events,
    );
    await desktop.initialize();
    events.clear();

    final captured = await desktop.captureWithOrbHidden(() async {
      events.add('capture');
      return 'pixels';
    });
    expect(captured, 'pixels');
    expect(events, ['orb-hide', 'capture', 'orb-show']);

    events.clear();
    await expectLater(
      desktop.captureWithOrbHidden(() async {
        events.add('capture');
        throw StateError('capture failed');
      }),
      throwsStateError,
    );
    expect(events, ['orb-hide', 'capture', 'orb-show']);

    await desktop.quit();
    desktop.dispose();
  });

  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'yixue-screenshot-prefs-test-',
    );
    file = File('${directory.path}/screenshot-translation-preferences.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'missing preferences use enabled orb and Ctrl+Alt+Y without writing',
    () async {
      final prefs = await FileScreenshotTranslationPreferencesStore(file)
          .read();
      expect(prefs.orbEnabled, isTrue);
      expect(prefs.saveScreenshotImages, isTrue);
      expect(prefs.hotKey.label, 'Ctrl+Alt+Y');
      expect(prefs.orbPosition, isNull);
      expect(await file.exists(), isFalse);
    },
  );
  test(
    'shortcut labels stay readable when release debug names are removed',
    () {
      expect(const ScreenshotHotKey(keyCode: 0x7001c).label, 'Ctrl+Alt+Y');
      expect(const ScreenshotHotKey(keyCode: 0x70045).label, 'Ctrl+Alt+F12');
      expect(const ScreenshotHotKey(keyCode: 0x7004f).label, 'Ctrl+Alt+Right');
      expect(
        const ScreenshotHotKey(keyCode: 0x700ff).label,
        'Ctrl+Alt+Key 0x000700ff',
      );
    },
  );
  test(
    'versioned preferences round trip negative physical position and key',
    () async {
      final prefs = ScreenshotTranslationPreferences(
        orbEnabled: false,
        saveScreenshotImages: false,
        hotKey: const ScreenshotHotKey(
          keyCode: 0x70018,
          modifiers: ['control', 'shift'],
        ),
        orbPosition: const ScreenshotOrbPosition(-1700, 140),
        pinnedRegion: const ScreenshotBounds(
          left: -1920,
          top: 80,
          width: 1200,
          height: 700,
        ),
      );
      final store = FileScreenshotTranslationPreferencesStore(file);
      await store.write(prefs);
      expect(await store.read(), prefs);
      expect(jsonDecode(await file.readAsString())['schemaVersion'], 3);
      expect(prefs.copyWith(clearPinnedRegion: true).pinnedRegion, isNull);
    },
  );
  test(
    'v1 preferences default image saving on and preserve existing settings',
    () async {
      await file.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'orbEnabled': false,
          'hotKey': {
            'keyCode': 0x70018,
            'modifiers': ['control', 'shift'],
          },
          'orbPosition': {'x': -1720, 'y': 145},
        }),
      );
      final legacy = await FileScreenshotTranslationPreferencesStore(file)
          .read();

      expect(legacy.saveScreenshotImages, isTrue);
      expect(legacy.orbEnabled, isFalse);
      expect(
        legacy.hotKey,
        const ScreenshotHotKey(
          keyCode: 0x70018,
          modifiers: ['control', 'shift'],
        ),
      );
      expect(legacy.orbPosition, const ScreenshotOrbPosition(-1720, 145));
      expect(legacy.toJson()['schemaVersion'], 3);
      expect(jsonDecode(await file.readAsString())['schemaVersion'], 1);
    },
  );
  test('v2 preferences remain readable after pinned regions are added', () {
    final preferences = ScreenshotTranslationPreferences.fromJson({
      'schemaVersion': 2,
      'orbEnabled': false,
      'saveScreenshotImages': false,
      'hotKey': const ScreenshotHotKey().toJson(),
    });

    expect(preferences.orbEnabled, isFalse);
    expect(preferences.saveScreenshotImages, isFalse);
    expect(preferences.pinnedRegion, isNull);
    expect(preferences.toJson()['schemaVersion'], 3);
  });
  test('image saving preference participates in copy, equality, and hash', () {
    const defaults = ScreenshotTranslationPreferences();
    final disabled = defaults.copyWith(saveScreenshotImages: false);

    expect(disabled.saveScreenshotImages, isFalse);
    expect(disabled.orbEnabled, defaults.orbEnabled);
    expect(disabled.hotKey, defaults.hotKey);
    expect(disabled.orbPosition, defaults.orbPosition);
    expect(disabled, isNot(defaults));
    expect(disabled.copyWith(), disabled);
    expect(disabled.copyWith().hashCode, disabled.hashCode);
  });
  test(
    'corrupt and unknown schema recover safely without replacing source',
    () async {
      for (final text in [
        '{',
        '{"schemaVersion":99}',
        '{"schemaVersion":1,"orbEnabled":"yes"}',
      ]) {
        await file.writeAsString(text);
        expect(
          await FileScreenshotTranslationPreferencesStore(file).read(),
          const ScreenshotTranslationPreferences(),
        );
        expect(await file.readAsString(), text);
      }
    },
  );
  test(
    'corrupt main file recovers previous valid committed preferences',
    () async {
      final store = FileScreenshotTranslationPreferencesStore(file);
      const previous = ScreenshotTranslationPreferences(orbEnabled: false);
      await store.write(previous);
      await store.write(const ScreenshotTranslationPreferences());
      await file.writeAsString('{');
      expect(await store.read(), previous);
    },
  );
  test('failed atomic replacement leaves previous main value intact', () async {
    final store = FileScreenshotTranslationPreferencesStore(file);
    const previous = ScreenshotTranslationPreferences(orbEnabled: false);
    await store.write(previous);
    final failing = FileScreenshotTranslationPreferencesStore(
      file,
      commit: (_, _) async =>
          throw const FileSystemException('replacement blocked'),
    );
    await expectLater(
      failing.write(const ScreenshotTranslationPreferences()),
      throwsA(isA<FileSystemException>()),
    );
    expect(await store.read(), previous);
    expect(
      (await directory.list().toList()).where(
        (e) => e.path.endsWith('.pending'),
      ),
      isEmpty,
    );
  });
  test('nonfinite position and unsupported shortcut are rejected', () {
    expect(
      () => ScreenshotTranslationPreferences.fromJson({
        'schemaVersion': 1,
        'orbEnabled': true,
        'orbPosition': {'x': double.infinity, 'y': 0},
      }),
      throwsFormatException,
    );
    expect(
      () => ScreenshotHotKey.fromJson({
        'keyCode': -1,
        'modifiers': ['unknown'],
      }),
      throwsFormatException,
    );
  });

  test('pinned region validation enforces bounds and the 20 MP ceiling', () {
    final encoded = ScreenshotTranslationPreferences(
      pinnedRegion: const ScreenshotBounds(
        left: -1920,
        top: 0,
        width: 5000,
        height: 5000,
      ),
    ).toJson();

    expect(
      () => ScreenshotTranslationPreferences.fromJson(encoded),
      throwsFormatException,
    );
    expect(
      () => ScreenshotTranslationPreferences.fromJson({
        'schemaVersion': 3,
        'pinnedRegion': {'left': 0x7fffffff, 'top': 0, 'width': 2, 'height': 1},
      }),
      throwsFormatException,
    );
  });

  test('orb changes preserve the hotkey; conflicts reject saving and restore the old key', () async {
    final store = MemoryPrefs();
    final driver = FakeHotKeys();
    final orb = FakeOrb();
    final desktop = createDesktop(store, driver, orb);
    await desktop.initialize();
    expect(driver.registerCount, 1);
    expect(orb.opened, 1);
    await desktop.update(desktop.preferences.copyWith(orbEnabled: false));
    expect(driver.registerCount, 1);
    expect(orb.closed, 1);
    const changed = ScreenshotHotKey(
      keyCode: 0x70018,
      modifiers: ['control', 'alt'],
    );
    driver.conflictKey = changed;
    final changedResult = await desktop.update(
      desktop.preferences.copyWith(hotKey: changed),
    );
    expect(changedResult, isFalse);
    expect(store.value.hotKey, const ScreenshotTranslationPreferences().hotKey);
    expect(
      desktop.preferences.hotKey,
      const ScreenshotTranslationPreferences().hotKey,
    );
    expect(desktop.hotKeyRegistered, isTrue);
    expect(desktop.hotKeyError, contains('占用'));
    driver.conflictKey = null;
    final rebound = await desktop.update(
      desktop.preferences.copyWith(hotKey: changed),
    );
    expect(rebound, isTrue);
    expect(store.value.hotKey, changed);
    expect(desktop.preferences.hotKey, changed);
    expect(desktop.hotKeyRegistered, isTrue);
    expect(desktop.hotKeyError, isNull);
    await desktop.shutdown();
    desktop.dispose();
  });
  test(
    'disableOrb message restores main, persists preference, then closes orb',
    () async {
      final events = <String>[];
      final store = MemoryPrefs()..events = events;
      final orb = FakeOrb(events: events);
      final desktop = createDesktop(
        store,
        FakeHotKeys(events: events),
        orb,
        events: events,
      );
      await desktop.initialize();
      events.clear();

      await desktop.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'disableOrb',
          requestId: 'disable-orb',
          payload: const {},
        ),
      );

      expect(events, ['show', 'persist', 'orb-close']);
      expect(store.writes, 1);
      expect(store.value.orbEnabled, isFalse);
      expect(desktop.preferences.orbEnabled, isFalse);
      expect(orb.closed, 1);
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test(
    'save failure retains prior preferences and runtime registration',
    () async {
      final store = MemoryPrefs();
      final driver = FakeHotKeys();
      final orb = FakeOrb();
      final events = <String>[];
      final desktop = createDesktop(store, driver, orb, events: events);
      await desktop.initialize();
      store.fail = true;
      expect(
        await desktop.update(desktop.preferences.copyWith(orbEnabled: false)),
        isFalse,
      );
      expect(desktop.preferences.orbEnabled, isTrue);
      expect(store.value.orbEnabled, isTrue);
      expect(events, ['show']);
      expect(orb.closed, 0);
      expect(driver.unregisterCount, 0);
      expect(desktop.saveError, isNotNull);
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test(
    'failed hotkey rollback never leaves an uncommitted chord registered',
    () async {
      final store = MemoryPrefs();
      final driver = FakeHotKeys();
      final desktop = createDesktop(store, driver, FakeOrb());
      await desktop.initialize();
      final original = desktop.preferences.hotKey;
      const changed = ScreenshotHotKey(
        keyCode: 0x70018,
        modifiers: ['control', 'alt'],
      );
      store.fail = true;

      expect(
        await desktop.update(desktop.preferences.copyWith(hotKey: changed)),
        isFalse,
      );
      expect(desktop.preferences.hotKey, original);
      expect(desktop.hotKeyRegistered, isTrue);
      expect(driver.registeredKey, original);

      driver.conflictKey = original;
      expect(
        await desktop.update(desktop.preferences.copyWith(hotKey: changed)),
        isFalse,
      );

      expect(store.value.hotKey, original);
      expect(desktop.preferences.hotKey, original);
      expect(desktop.hotKeyRegistered, isFalse);
      expect(driver.registeredKey, isNull);
      expect(desktop.hotKeyError, contains('恢复失败'));

      store.fail = false;
      driver.conflictKey = null;
      await desktop.retryHotKey();
      expect(desktop.hotKeyRegistered, isTrue);
      expect(driver.registeredKey, original);
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test(
    'failed unregister suppresses the uncommitted hotkey callback',
    () async {
      final store = MemoryPrefs();
      final driver = FakeHotKeys();
      final events = <String>[];
      final desktop = createDesktop(store, driver, FakeOrb(), events: events);
      await desktop.initialize();
      const original = ScreenshotHotKey();
      const changed = ScreenshotHotKey(
        keyCode: 0x70018,
        modifiers: ['control', 'alt'],
      );
      store.fail = true;
      driver.failOnUnregisterCall = 2;

      expect(
        await desktop.update(desktop.preferences.copyWith(hotKey: changed)),
        isFalse,
      );
      expect(desktop.preferences.hotKey, original);
      expect(driver.registeredKey, changed);
      expect(desktop.hotKeyRegistered, isFalse);
      driver.pressed?.call();
      expect(events, isNot(contains('capture')));

      store.fail = false;
      driver.failOnUnregisterCall = null;
      await desktop.retryHotKey();
      expect(desktop.preferences.hotKey, original);
      expect(desktop.hotKeyRegistered, isTrue);
      expect(driver.registeredKey, original);
      events.clear();
      driver.pressed?.call();
      expect(events, ['capture']);
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test(
    'position persistence survives restart and does not recreate orb',
    () async {
      final store = MemoryPrefs();
      final driver = FakeHotKeys();
      final orb = FakeOrb();
      final desktop = createDesktop(store, driver, orb);
      await desktop.initialize();
      await desktop.saveOrbPosition(const ScreenshotOrbPosition(-1200, 300));
      expect(store.value.orbPosition, const ScreenshotOrbPosition(-1200, 300));
      expect(orb.opened, 1);
      await desktop.shutdown();
      desktop.dispose();
      final restoredOrb = FakeOrb();
      final restored = createDesktop(store, FakeHotKeys(), restoredOrb);
      await restored.initialize();
      expect(restoredOrb.position, store.value.orbPosition);
      await restored.shutdown();
      restored.dispose();
    },
  );
  test('close enabled hides, restore opens, quit unregisters and clears children before exit', () async {
    final events = <String>[];
    final desktop = createDesktop(
      MemoryPrefs(),
      FakeHotKeys(events: events),
      FakeOrb(events: events),
      events: events,
    );
    await desktop.initialize();
    events.clear();
    await desktop.handleMainClose();
    expect(events, ['hide']);
    await desktop.openMain();
    expect(events.last, 'show');
    events.clear();
    await desktop.quit();
    expect(events, [
      'unregister',
      'release',
      'orb-close',
      'children-close',
      'exit',
    ]);
    await desktop.quit();
    expect(events.where((e) => e == 'exit').length, 1);
    desktop.dispose();
  });
  test('orb quit delegates to the shared host close flow without shutting down first', () async {
    final events = <String>[];
    final orb = FakeOrb(events: events);
    final desktop = createDesktop(
      MemoryPrefs(),
      FakeHotKeys(events: events),
      orb,
      events: events,
      onRequestHostExit: () async => events.add('request-host-exit'),
    );
    await desktop.initialize();
    events.clear();

    await desktop.handleMessage(
      ScreenshotTranslationWindowMessage(
        type: 'quitRequested',
        requestId: 'quit-from-orb',
        payload: const {},
      ),
    );

    expect(events, ['request-host-exit']);
    expect(orb.closed, 0);
    desktop.dispose();
  });
  test('close disabled exits and unregisters key; hotkey never fires after shutdown', () async {
    final events = <String>[];
    final driver = FakeHotKeys(events: events);
    final desktop = createDesktop(
      MemoryPrefs(const ScreenshotTranslationPreferences(orbEnabled: false)),
      driver,
      FakeOrb(),
      events: events,
    );
    await desktop.initialize();
    events.clear();
    driver.pressed!();
    expect(events, ['capture']);
    events.clear();
    await desktop.handleMainClose();
    expect(events, ['unregister', 'release', 'children-close', 'exit']);
    driver.pressed?.call();
    expect(events.where((e) => e == 'capture'), isEmpty);
    desktop.dispose();
  });
  test(
    'failed orb creation leaves main window visible when close is requested',
    () async {
      final events = <String>[];
      final desktop = createDesktop(
        MemoryPrefs(),
        FakeHotKeys(),
        FakeOrb(),
        events: events,
        orbFailure: true,
      );
      await desktop.initialize();
      expect(desktop.orbError, isNotNull);
      await desktop.handleMainClose();
      expect(events, contains('show'));
      expect(events, isNot(contains('hide')));
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test(
    'failed recording pause keeps the uncertain shortcut inactive',
    () async {
      final events = <String>[];
      final driver = FakeHotKeys();
      final desktop = createDesktop(
        MemoryPrefs(),
        driver,
        FakeOrb(),
        events: events,
      );
      await desktop.initialize();
      final stale = driver.pressed!;
      driver.failOnUnregisterCall = 1;

      expect(await desktop.beginHotKeyRecording(), isFalse);
      expect(desktop.hotKeyRecording, isFalse);
      expect(desktop.hotKeyRegistered, isFalse);
      stale();
      expect(events, isEmpty);

      driver.failOnUnregisterCall = null;
      await desktop.retryHotKey();
      expect(desktop.hotKeyRegistered, isTrue);
      driver.pressed!.call();
      expect(events, ['capture']);
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test('starting a new recording clears a stale shortcut error', () async {
    final store = MemoryPrefs();
    final driver = FakeHotKeys()..conflictKey = const ScreenshotHotKey();
    final desktop = createDesktop(store, driver, FakeOrb());
    await desktop.initialize();
    expect(desktop.hotKeyError, isNotNull);

    driver.conflictKey = null;
    expect(await desktop.beginHotKeyRecording(), isTrue);
    expect(desktop.hotKeyError, isNull);
    await desktop.endHotKeyRecording();
    await desktop.shutdown();
    desktop.dispose();
  });
}

void recordingAndPositionRegressions() {
  test(
    'orb disable waits for successful main restore before saving and closing',
    () async {
      final store = MemoryPrefs();
      final restored = Completer<void>();
      final orb = FakeOrb();
      final desktop = createDesktop(
        store,
        FakeHotKeys(),
        orb,
        onOpenMain: () => restored.future,
      );
      await desktop.initialize();
      final update = desktop.update(
        desktop.preferences.copyWith(orbEnabled: false),
      );
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 0);
      expect(store.value.orbEnabled, isTrue);
      expect(desktop.preferences.orbEnabled, isTrue);
      expect(orb.closed, 0);
      restored.complete();
      expect(await update, isTrue);
      expect(store.writes, 1);
      expect(store.value.orbEnabled, isFalse);
      expect(desktop.preferences.orbEnabled, isFalse);
      expect(orb.closed, 1);
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test(
    'close retries failed exit without restoring released business state',
    () async {
      final events = <String>[];
      var exits = 0;
      final desktop = createDesktop(
        MemoryPrefs(),
        FakeHotKeys(events: events),
        FakeOrb(events: events),
        events: events,
        onExit: () async {
          events.add('exit');
          if (++exits == 1) throw StateError('host close failed');
        },
        onExitFailure: () async {
          events.add('exit-recovery');
          throw StateError('recovery focus failed');
        },
      );
      await desktop.initialize();
      events.clear();
      await desktop.quit();
      expect(desktop.exitFailed, isTrue);
      expect(desktop.exitInProgress, isFalse);
      expect(desktop.lifecycleError, contains('显示失败'));
      await desktop.handleMainClose();
      expect(exits, 2);
      expect(desktop.exitFailed, isFalse);
      expect(events, [
        'unregister',
        'release',
        'orb-close',
        'children-close',
        'exit',
        'exit-recovery',
        'exit',
      ]);
      desktop.dispose();
    },
  );
  test(
    'failed host exit notifies and a second quit retries host exit',
    () async {
      var exits = 0, notifications = 0;
      final desktop = createDesktop(
        MemoryPrefs(),
        FakeHotKeys(),
        FakeOrb(),
        onExit: () async {
          if (++exits == 1) throw StateError('host close failed');
        },
      );
      await desktop.initialize();
      desktop.addListener(() => notifications++);
      await desktop.quit();
      expect(desktop.lifecycleError, isNotNull);
      expect(notifications, greaterThan(0));
      await desktop.quit();
      expect(exits, 2);
      desktop.dispose();
    },
  );
  test(
    'disabling orb preserves old settings and orb when restoring main fails',
    () async {
      final store = MemoryPrefs();
      final events = <String>[];
      final orb = FakeOrb(events: events);
      final desktop = createDesktop(
        store,
        FakeHotKeys(),
        orb,
        onOpenMain: () async {
          throw StateError('main focus failed');
        },
      );
      await desktop.initialize();
      events.clear();
      expect(
        await desktop.update(desktop.preferences.copyWith(orbEnabled: false)),
        isFalse,
      );
      expect(events, isEmpty);
      expect(orb.closed, 0);
      expect(store.writes, 0);
      expect(store.value.orbEnabled, isTrue);
      expect(desktop.preferences.orbEnabled, isTrue);
      expect(desktop.lifecycleError, isNotNull);
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test(
    'explicit quit runs all cleanup and exits even when cleanup fails',
    () async {
      final events = <String>[];
      final desktop = ScreenshotTranslationDesktopController(
        store: MemoryPrefs(),
        hotKeys: FakeHotKeys(events: events),
        createOrb: () async => FakeOrb(events: events),
        onCapture: () async {},
        onOpenMain: () async {
          events.add('show');
        },
        onOpenSettings: () async {},
        onHideMain: () async {},
        onReleaseSession: () async {
          events.add('release');
          throw StateError('release failed');
        },
        onCloseChildren: () async {
          events.add('children-close');
          throw StateError('child did not respond');
        },
        onExit: () async {
          events.add('exit');
        },
      );
      await desktop.initialize();
      events.clear();
      await desktop.quit();
      expect(events, [
        'unregister',
        'release',
        'orb-close',
        'children-close',
        'exit',
      ]);
      desktop.dispose();
    },
  );
  test(
    'real Dart hotkey adapter maps Windows conflict and can rebind',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('dev.leanflutter.plugins/hotkey_manager');
      const events = MethodChannel(
        'dev.leanflutter.plugins/hotkey_manager_event',
      );
      var conflict = true;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'register' && conflict) {
          throw PlatformException(code: 'hotkey_conflict', details: 1409);
        }
        return true;
      });
      final desktop = createDesktop(
        MemoryPrefs(),
        MainEngineScreenshotHotKey(),
        FakeOrb(),
      );
      try {
        await desktop.initialize();
        expect(desktop.hotKeyRegistered, isFalse);
        expect(desktop.hotKeyError, contains('占用'));
        expect(desktop.preferences.hotKey, const ScreenshotHotKey());
        conflict = false;
        const key = ScreenshotHotKey(
          keyCode: 0x70018,
          modifiers: ['control', 'shift'],
        );
        expect(
          await desktop.update(desktop.preferences.copyWith(hotKey: key)),
          isTrue,
        );
        expect(desktop.hotKeyRegistered, isTrue);
        expect(desktop.preferences.hotKey, key);
        await desktop.shutdown();
        expect(calls, ['register', 'register', 'unregister']);
      } finally {
        await desktop.shutdown();
        desktop.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(events, null);
      }
    },
  );
  test('queued position save cannot undo a newer orb toggle', () async {
    final store = MemoryPrefs();
    final desktop = createDesktop(store, FakeHotKeys(), FakeOrb());
    await desktop.initialize();
    final toggle = desktop.update(
      desktop.preferences.copyWith(orbEnabled: false),
    );
    final move = desktop.saveOrbPosition(const ScreenshotOrbPosition(-600, 80));
    await Future.wait([toggle, move]);
    expect(store.value.orbEnabled, isFalse);
    expect(store.value.orbPosition, const ScreenshotOrbPosition(-600, 80));
    await desktop.shutdown();
    desktop.dispose();
  });
  test('ordinary settings updates preserve the latest pinned region', () async {
    const region = ScreenshotBounds(
      left: -1280,
      top: 60,
      width: 900,
      height: 600,
    );
    final store = MemoryPrefs(
      const ScreenshotTranslationPreferences(pinnedRegion: region),
    );
    final desktop = createDesktop(store, FakeHotKeys(), FakeOrb());
    await desktop.initialize();

    await desktop.update(
      const ScreenshotTranslationPreferences(orbEnabled: false),
    );

    expect(store.value.orbEnabled, isFalse);
    expect(store.value.pinnedRegion, region);
    await desktop.shutdown();
    desktop.dispose();
  });
  test(
    'recording suspends the active shortcut and cancellation restores it',
    () async {
      final events = <String>[];
      final driver = FakeHotKeys();
      final desktop = createDesktop(
        MemoryPrefs(),
        driver,
        FakeOrb(),
        events: events,
      );
      await desktop.initialize();
      final stale = driver.pressed!;
      expect(await desktop.beginHotKeyRecording(), isTrue);
      stale();
      expect(events, isEmpty);
      expect(desktop.hotKeyRegistered, isFalse);
      await desktop.endHotKeyRecording();
      expect(desktop.hotKeyRegistered, isTrue);
      expect(desktop.preferences.hotKey, const ScreenshotHotKey());
      await desktop.shutdown();
      desktop.dispose();
    },
  );
  test(
    'recording suppresses the shortcut while unregister is pending',
    () async {
      final events = <String>[];
      final driver = FakeHotKeys();
      final desktop = createDesktop(
        MemoryPrefs(),
        driver,
        FakeOrb(),
        events: events,
      );
      await desktop.initialize();
      final stale = driver.pressed!;
      final unregisterStarted = Completer<void>();
      final unregisterGate = Completer<void>();
      driver.unregisterStarted = unregisterStarted;
      driver.unregisterGate = unregisterGate;

      final recording = desktop.beginHotKeyRecording();
      await unregisterStarted.future;
      stale();
      expect(events, isEmpty);

      unregisterGate.complete();
      expect(await recording, isTrue);
      stale();
      expect(events, isEmpty);
      expect(desktop.hotKeyRecording, isTrue);
      expect(desktop.hotKeyRegistered, isFalse);
      await desktop.endHotKeyRecording();
      await desktop.shutdown();
      desktop.dispose();
    },
  );
}

ScreenshotTranslationDesktopController createDesktop(
  MemoryPrefs store,
  ScreenshotGlobalHotKey driver,
  FakeOrb orb, {
  List<String>? events,
  bool orbFailure = false,
  Future<void> Function()? onExit,
  Future<void> Function()? onOpenMain,
  Future<void> Function()? onExitFailure,
  Future<void> Function()? onRequestHostExit,
}) => ScreenshotTranslationDesktopController(
  store: store,
  hotKeys: driver,
  createOrb: () async {
    if (orbFailure) throw StateError('child unavailable');
    return orb;
  },
  onCapture: () async {
    events?.add('capture');
  },
  onOpenMain:
      onOpenMain ??
      () async {
        events?.add('show');
      },
  onOpenSettings: () async {
    events?.add('settings');
  },
  onHideMain: () async {
    events?.add('hide');
  },
  onReleaseSession: () async {
    events?.add('release');
  },
  onCloseChildren: () async {
    events?.add('children-close');
  },
  onExit:
      onExit ??
      () async {
        events?.add('exit');
      },
  onExitFailure: onExitFailure,
  onRequestHostExit: onRequestHostExit,
);

class MemoryPrefs implements ScreenshotTranslationPreferencesStore {
  MemoryPrefs([this.value = const ScreenshotTranslationPreferences()]);
  ScreenshotTranslationPreferences value;
  List<String>? events;
  bool fail = false;
  int writes = 0;
  @override
  Future<ScreenshotTranslationPreferences> read() async => value;
  @override
  Future<void> write(ScreenshotTranslationPreferences prefs) async {
    writes++;
    if (fail) throw const FileSystemException('blocked');
    value = prefs;
    events?.add('persist');
  }
}

class FakeHotKeys implements ScreenshotGlobalHotKey {
  FakeHotKeys({this.events});
  final List<String>? events;
  ScreenshotHotKey? conflictKey;
  int registerCount = 0, unregisterCount = 0;
  VoidCallback? pressed;
  ScreenshotHotKey? registeredKey;
  int? failOnUnregisterCall;
  Completer<void>? unregisterStarted;
  Completer<void>? unregisterGate;
  @override
  Future<void> register(ScreenshotHotKey key, VoidCallback onPressed) async {
    registerCount++;
    if (key == conflictKey) {
      throw const ScreenshotHotKeyRegistrationException(
        'hotkey_conflict',
        1409,
      );
    }
    pressed = onPressed;
    registeredKey = key;
  }

  @override
  Future<void> unregister() async {
    unregisterCount++;
    events?.add('unregister');
    if (unregisterCount == failOnUnregisterCall) {
      throw StateError('simulated hotkey unregister failure');
    }
    if (unregisterStarted case final started?) {
      if (!started.isCompleted) started.complete();
    }
    await unregisterGate?.future;
    pressed = null;
    registeredKey = null;
  }
}

class FakeOrb implements ScreenshotOrbHandle {
  FakeOrb({this.events});
  final List<String>? events;
  int opened = 0, closed = 0;
  ScreenshotOrbPosition? position;
  @override
  Future<void> open(ScreenshotOrbPosition? value) async {
    opened++;
    position = value;
  }

  @override
  Future<void> close() async {
    closed++;
    events?.add('orb-close');
  }
}

class _CaptureAwareOrb extends FakeOrb
    implements ScreenshotOrbCaptureVisibility {
  _CaptureAwareOrb(List<String> events) : super(events: events);

  @override
  Future<void> hideForCapture() async => events?.add('orb-hide');

  @override
  Future<void> restoreAfterCapture() async => events?.add('orb-show');
}
