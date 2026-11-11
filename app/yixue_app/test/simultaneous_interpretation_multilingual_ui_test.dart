import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/app_exit_cleanup_registry.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/desktop_audio_capture.dart';
import 'package:yixue_app/features/simultaneous_interpretation/desktop_screen_capture.dart';
import 'package:yixue_app/features/simultaneous_interpretation/multilingual_asr_model_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/simultaneous_interpretation_page.dart';
import 'package:yixue_app/features/simultaneous_interpretation/streaming_asr.dart';
import 'package:yixue_app/features/simultaneous_interpretation/streaming_asr_model_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_display_preferences.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_translation_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'audio recorder disposal is shared by overlapping exit and teardown paths',
    () async {
      final disposal = MemoizedAsyncDisposal();
      final releaseDisposal = Completer<void>();
      var disposeCalls = 0;

      Future<void> disposeRecorder() {
        disposeCalls++;
        return releaseDisposal.future;
      }

      final exitDisposal = disposal.run(disposeRecorder);
      final teardownDisposal = disposal.run(disposeRecorder);

      expect(identical(exitDisposal, teardownDisposal), isTrue);
      expect(disposeCalls, 1);

      releaseDisposal.complete();
      await Future.wait<void>([exitDisposal, teardownDisposal]);
      await disposal.run(disposeRecorder);

      expect(disposeCalls, 1);
    },
  );

  test(
    'audio recorder disposal can retry after a shared attempt fails',
    () async {
      final disposal = MemoizedAsyncDisposal();
      final failFirstDisposal = Completer<void>();
      var disposeCalls = 0;

      Future<void> disposeRecorder() {
        disposeCalls++;
        if (disposeCalls == 1) return failFirstDisposal.future;
        return Future<void>.value();
      }

      final exitDisposal = disposal.run(disposeRecorder);
      final teardownDisposal = disposal.run(disposeRecorder);

      expect(identical(exitDisposal, teardownDisposal), isTrue);
      expect(disposeCalls, 1);

      failFirstDisposal.completeError(StateError('temporary disposal failure'));
      await expectLater(exitDisposal, throwsA(isA<StateError>()));

      await disposal.run(disposeRecorder);
      expect(disposeCalls, 2);

      await disposal.run(disposeRecorder);
      expect(disposeCalls, 2);
    },
  );

  test(
    'screen capture adapter filters stale capture and recording events',
    () async {
      const screenChannel = MethodChannel('test/yixue-capture-identity');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(screenChannel, (call) async {
        if (call.method == 'selectSource') {
          return <String, Object?>{
            'textureId': 4,
            'width': 1920,
            'height': 1080,
            'targetName': '测试窗口',
            'captureInstanceId': 17,
          };
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(screenChannel, null),
      );

      final adapter = DesktopScreenCaptureAdapter(
        applicationDataDirectory: Directory.systemTemp,
        methodChannel: screenChannel,
        eventChannel: const EventChannel('test/yixue-capture-identity-events'),
      );
      final target = await adapter.selectSource();
      expect(target.captureInstanceId, 17);
      expect(
        adapter.isCurrentCaptureEvent(
          const DesktopScreenCaptureEvent(
            type: 'state',
            status: 'captureFailed',
            captureInstanceId: 17,
          ),
        ),
        isTrue,
      );
      expect(
        adapter.isCurrentCaptureEvent(
          const DesktopScreenCaptureEvent(
            type: 'state',
            status: 'captureFailed',
            captureInstanceId: 16,
          ),
        ),
        isFalse,
      );
      expect(
        adapter.isCurrentRecordingEvent(
          const DesktopScreenCaptureEvent(
            type: 'state',
            status: 'recordingFailed',
            sessionId: 'session-old',
            captureAttemptId: 'attempt-old',
          ),
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'laptop-width capture page keeps start action and transcript in first view',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-laptop-layout-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      const audioChannel = MethodChannel('test/yixue-laptop-layout-audio');
      const screenChannel = MethodChannel('test/yixue-laptop-layout-screen');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      messenger.setMockMethodCallHandler(screenChannel, (call) async {
        if (call.method == 'isSupported') return true;
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(audioChannel, null);
        messenger.setMockMethodCallHandler(screenChannel, null);
      });

      await _pumpWorkbench(
        tester,
        dataDirectory,
        audioChannel,
        screenCapture: DesktopScreenCaptureAdapter(
          applicationDataDirectory: dataDirectory,
          methodChannel: screenChannel,
          eventChannel: const EventChannel(
            'test/yixue-laptop-layout-screen-events',
          ),
        ),
        viewportSize: const Size(1333, 1066),
        devicePixelRatio: 1.5,
      );

      expect(find.text('未选择画面'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('screen-capture-select-preview')),
        findsNothing,
      );
      expect(find.textContaining('录制与音源'), findsOneWidget);
      expect(find.text('开始同传'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-session-pause')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subtitle-session-stop')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('subtitle-session-pause')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('subtitle-session-stop')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('subtitle-start-readiness')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('subtitle-open-setup')), findsOneWidget);
      expect(find.text('实时字幕'), findsOneWidget);
      expect(find.text('开始后，字幕会显示在这里'), findsOneWidget);
      expect(find.text('最近字幕历史'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('同传设置'), findsOneWidget);
      expect(find.text('画面与录制'), findsNothing);
      expect(
        tester.getTopLeft(find.text('同传设置')).dy,
        lessThan(tester.getTopLeft(find.text('最近字幕历史')).dy),
      );
      expect(
        tester.getBottomRight(find.text('开始后，字幕会显示在这里')).dy,
        lessThan(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('subtitle-open-setup')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('subtitle-setup-dialog-title')),
        findsOneWidget,
      );
      expect(find.text('本地语音识别模型'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-setup-close')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows screen recording target is selectable from the main capture card',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () =>
            Directory.systemTemp.createTemp('yixue-primary-recording-target-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      const audioChannel = MethodChannel(
        'test/yixue-primary-recording-target-audio',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

      await _pumpWorkbench(
        tester,
        dataDirectory,
        audioChannel,
        viewportSize: const Size(1440, 900),
      );

      final selectTarget = find.byKey(
        const ValueKey('screen-recording-select-target'),
      );
      expect(selectTarget, findsOneWidget);
      await tester.ensureVisible(selectTarget);
      expect(tester.widget<OutlinedButton>(selectTarget).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'recognition setup dialog does not reuse navigation anchors from expanded settings',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-setup-dialog-anchors-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      const audioChannel = MethodChannel('test/yixue-setup-dialog-anchors');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

      await _pumpWorkbench(tester, dataDirectory, audioChannel);
      await _expandUnifiedSettings(tester);
      final openSetup = find.byKey(const ValueKey('subtitle-open-setup'));
      await tester.ensureVisible(openSetup);
      await tester.tap(openSetup);
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('subtitle-setup-dialog-title')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('subtitle-setup-close')));
      await tester.pump(const Duration(milliseconds: 350));

      await _expandSettingsCategory(tester, 'subtitle-recording-settings');
      await tester.ensureVisible(openSetup);
      await tester.tap(openSetup);
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('subtitle-setup-dialog-title')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact Windows no-preview layout keeps recording and meeting inputs reachable',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-compact-capture-layout-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));
      const longMicrophoneName =
          '笔记本内置麦克风 - 很长的设备名称用于窄窗口省略号实际渲染测试兼容 Windows 常见 USB 音频设备名称一二三四五六七八九十';

      const audioChannel = MethodChannel(
        'test/yixue-compact-capture-layout-audio',
      );
      const recorderChannel = MethodChannel(
        'com.yixue.yixue_app/ai_tongchuan/screen_recording',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final recorderCalls = <String>[];
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') {
          return <dynamic>[
            <String, Object?>{
              'sourceId': 'windows-system-output',
              'sourceKind': 'systemOutput',
              'displayName': '系统播放声音',
              'description': 'Windows 默认播放混音',
            },
            <String, Object?>{
              'sourceId': 'microphone-built-in',
              'sourceKind': 'microphone',
              'displayName': longMicrophoneName,
              'description': '测试麦克风输入',
            },
            <String, Object?>{
              'sourceId': 'microphone-usb',
              'sourceKind': 'microphone',
              'displayName': 'USB 桌面麦克风',
              'description': '备用测试麦克风输入',
            },
          ];
        }
        return null;
      });
      messenger.setMockMethodCallHandler(recorderChannel, (call) async {
        recorderCalls.add(call.method);
        if (call.method == 'getState') {
          return <String, Object?>{
            'status': 'targetSelected',
            'targetName': '测试会议窗口',
          };
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(audioChannel, null);
        messenger.setMockMethodCallHandler(recorderChannel, null);
      });

      await _pumpWorkbench(
        tester,
        dataDirectory,
        audioChannel,
        viewportSize: const Size(860, 690),
      );

      await _expandUnifiedSettings(tester);
      final meetingOption = find.descendant(
        of: find.byType(SegmentedButton<SubtitleSessionKind>),
        matching: find.text('会议'),
      );
      await tester.ensureVisible(meetingOption);
      await tester.tap(meetingOption);
      await tester.pump();
      final microphoneControl = find.byKey(
        const ValueKey('subtitle-meeting-microphone-toggle'),
      );
      await tester.ensureVisible(microphoneControl);
      await tester.tap(microphoneControl);
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('subtitle-selected-microphone-source-name'),
              ),
            )
            .data,
        longMicrophoneName,
      );
      final selectedMicrophone = tester.widget<Text>(
        find.byKey(const ValueKey('subtitle-selected-microphone-source-name')),
      );
      expect(selectedMicrophone.maxLines, 1);
      expect(selectedMicrophone.overflow, TextOverflow.ellipsis);
      expect(
        tester
            .renderObject<RenderParagraph>(
              find.byKey(
                const ValueKey('subtitle-selected-microphone-source-name'),
              ),
            )
            .didExceedMaxLines,
        isTrue,
      );

      final microphoneShortcut = find.byKey(
        const ValueKey('subtitle-change-microphone-source'),
      );
      await tester.ensureVisible(microphoneShortcut);
      expect(microphoneShortcut.hitTestable(), findsOneWidget);
      await tester.tap(microphoneShortcut);
      await tester.pumpAndSettle();
      final microphoneDropdown = find.byKey(
        const ValueKey('subtitle-microphone-source-settings'),
      );
      expect(microphoneDropdown.hitTestable(), findsOneWidget);
      await tester.tap(microphoneDropdown);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('USB 桌面麦克风').last);
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('subtitle-selected-microphone-source-name'),
              ),
            )
            .data,
        'USB 桌面麦克风',
      );

      final selectTarget = find.byKey(
        const ValueKey('screen-recording-select-target'),
      );
      await tester.ensureVisible(selectTarget);
      expect(tester.widget<OutlinedButton>(selectTarget).onPressed, isNotNull);
      expect(selectTarget.hitTestable(), findsOneWidget);
      await tester.tap(selectTarget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(recorderCalls, contains('pickTarget'));

      final startSession = find.byKey(const ValueKey('subtitle-session-start'));
      await tester.ensureVisible(startSession);
      expect(startSession.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );

  testWidgets('simultaneous settings are grouped into collapsed categories', (
    tester,
  ) async {
    final dataDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yixue-settings-categories-'),
    ))!;
    addTearDown(() => dataDirectory.delete(recursive: true));

    const audioChannel = MethodChannel('test/yixue-settings-categories-audio');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(audioChannel, (call) async {
      if (call.method == 'enumerateSources') return <dynamic>[];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

    await _pumpWorkbench(tester, dataDirectory, audioChannel);
    await tester.tap(find.byKey(const ValueKey('subtitle-unified-settings')));
    await tester.pump(const Duration(milliseconds: 350));

    for (final key in const [
      'subtitle-language-settings',
      'subtitle-recording-settings',
      'subtitle-window-settings',
      'subtitle-privacy-settings',
    ]) {
      expect(
        tester
            .widget<ExpansionTile>(find.byKey(ValueKey(key)))
            .initiallyExpanded,
        isFalse,
      );
    }
    expect(find.text('语言与识别'), findsOneWidget);
    expect(find.text('录制与音源'), findsOneWidget);
    expect(find.text('字幕窗外观'), findsOneWidget);
    expect(find.text('采集与隐私'), findsOneWidget);
    expect(find.text('录屏目标'), findsOneWidget);

    await _expandSettingsCategory(tester, 'subtitle-language-settings');
    final qualityNotice = find.byKey(
      const ValueKey('asr-quality-boundary-notice'),
    );
    await tester.ensureVisible(qualityNotice);
    expect(qualityNotice, findsOneWidget);
    expect(find.textContaining('尚未完成逐语种准确率验收'), findsOneWidget);
    expect(
      find.ancestor(
        of: qualityNotice,
        matching: find.byKey(const ValueKey('subtitle-language-settings')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('subtitle-language-settings')),
        matching: find.text('采集来源'),
      ),
      findsNothing,
    );
    await _expandSettingsCategory(tester, 'subtitle-recording-settings');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('subtitle-recording-settings')),
        matching: find.text('采集来源'),
      ),
      findsOneWidget,
    );
    await _expandSettingsCategory(tester, 'subtitle-window-settings');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('subtitle-recording-settings')),
        matching: find.text('采集来源'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('subtitle-font-standard')),
      findsOneWidget,
    );
    await _expandSettingsCategory(tester, 'subtitle-privacy-settings');
    expect(find.byKey(const ValueKey('subtitle-font-standard')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'meeting mode exposes the selected microphone and can change it',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-meeting-microphone-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      const audioChannel = MethodChannel('test/yixue-meeting-microphone-audio');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') {
          return <dynamic>[
            <String, Object?>{
              'sourceId': 'system-output-1',
              'sourceKind': 'systemOutput',
              'displayName': '系统播放声音',
              'description': '测试系统音源',
            },
            <String, Object?>{
              'sourceId': 'microphone-1',
              'sourceKind': 'microphone',
              'displayName': '笔记本内置麦克风',
              'description': '测试麦克风输入',
            },
            <String, Object?>{
              'sourceId': 'microphone-2',
              'sourceKind': 'microphone',
              'displayName': 'USB 耳机麦克风',
              'description': '外接耳机麦克风',
            },
          ];
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

      await _pumpWorkbench(tester, dataDirectory, audioChannel);
      await _expandUnifiedSettings(tester);
      final meetingOption = find.descendant(
        of: find.byType(SegmentedButton<SubtitleSessionKind>),
        matching: find.text('会议'),
      );
      await tester.ensureVisible(meetingOption);
      await tester.tap(meetingOption);
      await tester.pump();

      final microphoneControl = find.byKey(
        const ValueKey('subtitle-meeting-microphone-toggle'),
      );
      expect(microphoneControl, findsOneWidget);
      expect(find.text('当前仅采集电脑播放声，本机发言不会进入字幕。'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(microphoneControl).value, isFalse);

      await tester.ensureVisible(microphoneControl);
      await tester.tap(microphoneControl);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(microphoneControl).value, isTrue);
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('subtitle-selected-microphone-source-name'),
              ),
            )
            .data,
        '笔记本内置麦克风',
      );

      final changeMicrophone = find.byKey(
        const ValueKey('subtitle-change-microphone-source'),
      );
      expect(changeMicrophone, findsOneWidget);
      await tester.ensureVisible(changeMicrophone);
      await tester.tap(changeMicrophone);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 350));
      final microphoneDropdown = find.byKey(
        const ValueKey('subtitle-microphone-source-settings'),
      );
      expect(microphoneDropdown, findsOneWidget);
      await tester.ensureVisible(microphoneDropdown);
      await tester.tap(microphoneDropdown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('USB 耳机麦克风').last);
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('subtitle-selected-microphone-source-name'),
              ),
            )
            .data,
        'USB 耳机麦克风',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows system audio entry identifies the default playback mix',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-audio-source-entry-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      const audioChannel = MethodChannel('test/yixue-audio-source-entry');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') {
          return <dynamic>[
            <String, Object?>{
              'sourceId': 'windows-system-output',
              'sourceKind': 'systemOutput',
              'displayName': '系统播放声音',
              'description': 'Windows WASAPI 默认播放设备系统混音',
            },
          ];
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

      await _pumpWorkbench(tester, dataDirectory, audioChannel);
      expect(find.text('Windows 默认播放混音'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('subtitle-change-audio-source')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.text(
          '启用后采集 Windows 当前默认输出设备的系统混音。要更换设备，请先停止同传，再到 Windows“系统 > 声音 > 输出”更改默认设备并重新开始。',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('subtitle-system-audio-source-windows-system-output'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );

  testWidgets('system audio enumeration failure is visible in the start card', (
    tester,
  ) async {
    final dataDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yixue-audio-source-error-'),
    ))!;
    addTearDown(() => dataDirectory.delete(recursive: true));

    const audioChannel = MethodChannel('test/yixue-audio-source-error');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(audioChannel, (call) async {
      if (call.method == 'enumerateSources') {
        throw PlatformException(code: 'enumeration_failed');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

    await _pumpWorkbench(tester, dataDirectory, audioChannel);

    expect(find.text('读取失败，请检查音频设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets(
    'system audio refresh shows a loading reason and keeps stale source choices from starting',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-audio-source-loading-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      const audioChannel = MethodChannel('test/yixue-audio-source-loading');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final refreshSources = Completer<Object?>();
      var enumerationCalls = 0;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') {
          enumerationCalls++;
          if (enumerationCalls == 1) {
            return <dynamic>[
              <String, Object?>{
                'sourceId': 'windows-system-output',
                'sourceKind': 'systemOutput',
                'displayName': '系统播放声音',
                'description': 'Windows WASAPI 默认播放设备系统混音',
              },
            ];
          }
          return refreshSources.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));
      addTearDown(() {
        if (!refreshSources.isCompleted) {
          refreshSources.complete(const <dynamic>[]);
        }
      });

      await _pumpWorkbench(tester, dataDirectory, audioChannel);
      expect(find.text('Windows 默认播放混音'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('subtitle-unified-settings')));
      await tester.pump(const Duration(milliseconds: 350));
      await _expandSettingsCategory(tester, 'subtitle-recording-settings');
      final refreshButton = find.byTooltip('刷新音源和麦克风设备');
      await tester.ensureVisible(refreshButton);
      await tester.tap(refreshButton);
      await tester.pump();

      expect(find.text('正在读取可用音源…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('subtitle-session-start')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '仅录音，不开字幕'))
            .onPressed,
        isNull,
      );
      expect(enumerationCalls, 2);

      refreshSources.complete(<dynamic>[
        <String, Object?>{
          'sourceId': 'windows-system-output',
          'sourceKind': 'systemOutput',
          'displayName': '系统播放声音',
          'description': 'Windows WASAPI 默认播放设备系统混音',
        },
      ]);
      await tester.pump();

      expect(find.text('正在读取可用音源…'), findsNothing);
      expect(find.text('Windows 默认播放混音'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '仅录音，不开字幕'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'system audio setting sets expectations for speech and song lyrics',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-system-audio-guidance-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      const audioChannel = MethodChannel(
        'test/yixue-system-audio-guidance-audio',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

      await _pumpWorkbench(tester, dataDirectory, audioChannel);
      await _expandUnifiedSettings(tester);
      await _expandSettingsCategory(tester, 'subtitle-recording-settings');

      expect(find.text('系统共享混音；适合对话、课程或会议，歌曲歌词识别不保证。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ASR failure has neutral recognition-specific copy separate from translation failure',
    (tester) async {
      var openedSettings = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtitleAsrFailureNotice(
              onOpenModelSettings: () => openedSettings = true,
            ),
          ),
        ),
      );

      expect(find.text('语音识别暂不可用'), findsOneWidget);
      expect(find.text('音源采集状态仍单独显示；可检查识别模型后重新开始同传。'), findsOneWidget);
      expect(find.textContaining('翻译失败'), findsNothing);
      expect(find.textContaining('录音失败'), findsNothing);
      expect(find.textContaining('正在等待可识别语音'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('subtitle-open-recognition-settings')),
      );
      expect(openedSettings, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recognition status stays visibly failed after cleanup closes the ASR runtime',
    (tester) async {
      const colors = ColorScheme.dark();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: colors),
          home: Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SubtitleAsrStatusIndicator(
                  key: const ValueKey('asr-status-after-cleanup-wide'),
                  state: StreamingAsrState(status: StreamingAsrStatus.closed),
                  sourceStatus: AudioCaptureSourceStatus.active,
                  sessionIsActive: false,
                  errorCodes: const ['asr_recognitionFailed'],
                ),
                SubtitleAsrStatusIndicator(
                  key: const ValueKey('asr-status-after-cleanup-compact'),
                  state: StreamingAsrState(status: StreamingAsrStatus.closed),
                  sourceStatus: AudioCaptureSourceStatus.active,
                  sessionIsActive: false,
                  errorCodes: const ['asr_recognitionFailed'],
                  compact: true,
                ),
                const SubtitleAsrFailureNotice(),
              ],
            ),
          ),
        ),
      );

      expect(find.text('识别 · 暂不可用'), findsNWidgets(2));
      final failureIcons = tester
          .widgetList<Icon>(find.byIcon(Icons.error_outline_rounded))
          .toList();
      expect(failureIcons, hasLength(2));
      for (final icon in failureIcons) {
        expect(icon.color, colors.error);
      }
      expect(find.text('语音识别暂不可用'), findsOneWidget);
      expect(find.textContaining('翻译失败'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'screen recording controls stay in the recording category at wide and compact widths',
    (tester) async {
      for (final size in const [Size(1440, 1000), Size(900, 1000)]) {
        final dataDirectory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('yixue-recording-layout-'),
        ))!;
        addTearDown(() => dataDirectory.delete(recursive: true));

        final suffix = size.width.toInt();
        final audioChannel = MethodChannel(
          'test/yixue-recording-layout-audio-$suffix',
        );
        final screenChannel = MethodChannel(
          'test/yixue-recording-layout-screen-$suffix',
        );
        final eventChannel = EventChannel(
          'test/yixue-recording-layout-events-$suffix',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(audioChannel, (call) async {
          if (call.method == 'enumerateSources') return <dynamic>[];
          return null;
        });
        messenger.setMockMethodCallHandler(screenChannel, (call) async {
          if (call.method == 'isSupported') return true;
          if (call.method == 'selectSource') {
            return <String, Object?>{
              'textureId': 7,
              'width': 1280,
              'height': 720,
              'targetName': '测试窗口',
              'captureInstanceId': 1,
            };
          }
          return null;
        });
        messenger.setMockStreamHandler(
          eventChannel,
          MockStreamHandler.inline(onListen: (arguments, events) {}),
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(audioChannel, null);
          messenger.setMockMethodCallHandler(screenChannel, null);
          messenger.setMockStreamHandler(eventChannel, null);
        });

        await _pumpWorkbench(
          tester,
          dataDirectory,
          audioChannel,
          screenCapture: DesktopScreenCaptureAdapter(
            applicationDataDirectory: dataDirectory,
            methodChannel: screenChannel,
            eventChannel: eventChannel,
          ),
          viewportSize: size,
        );
        final settings = find.byKey(
          const ValueKey('subtitle-unified-settings'),
        );
        await tester.ensureVisible(settings);
        await tester.tap(settings);
        await tester.pump(const Duration(milliseconds: 350));
        await _expandSettingsCategory(tester, 'subtitle-recording-settings');
        final selectTargetInSettings = find.byKey(
          const ValueKey('screen-capture-select-controls'),
        );
        expect(selectTargetInSettings, findsOneWidget);
        expect(
          find.ancestor(
            of: selectTargetInSettings,
            matching: find.byKey(const ValueKey('subtitle-recording-settings')),
          ),
          findsOneWidget,
          reason: 'first target selection should be grouped at ${size.width}px',
        );

        expect(
          find.byKey(const ValueKey('screen-capture-select-preview')),
          findsNothing,
          reason: 'the preview should not duplicate the settings action',
        );
        await tester.ensureVisible(selectTargetInSettings);
        await tester.tap(selectTargetInSettings);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('更换'), findsNothing);

        final recordButton = find.text('开始录屏（含系统声音）');
        expect(recordButton, findsOneWidget);
        await tester.ensureVisible(recordButton);
        expect(
          find.ancestor(
            of: recordButton,
            matching: find.byKey(const ValueKey('subtitle-recording-settings')),
          ),
          findsOneWidget,
          reason: 'recording controls should remain grouped at ${size.width}px',
        );
        final changeTarget = find.byKey(
          const ValueKey('screen-capture-change-target'),
        );
        expect(changeTarget, findsOneWidget);
        expect(
          find.ancestor(
            of: changeTarget,
            matching: find.byKey(const ValueKey('subtitle-recording-settings')),
          ),
          findsOneWidget,
          reason:
              'target changes should stay with recording at ${size.width}px',
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
  );

  testWidgets(
    'Windows production route selects a recording target without a preview texture',
    (tester) async {
      if (!Platform.isWindows) return;
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-recording-route-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      const audioChannel = MethodChannel('test/yixue-recording-route-audio');
      const recorderChannel = MethodChannel(
        'com.yixue.yixue_app/ai_tongchuan/screen_recording',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final recorderCalls = <String>[];
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      messenger.setMockMethodCallHandler(recorderChannel, (call) async {
        recorderCalls.add(call.method);
        if (call.method == 'getState') {
          return <String, Object?>{
            'status': 'targetSelected',
            'targetName': '测试会议窗口',
          };
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(audioChannel, null);
        messenger.setMockMethodCallHandler(recorderChannel, null);
      });

      await _pumpWorkbench(tester, dataDirectory, audioChannel);
      expect(find.text('录屏目标'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('screen-recording-select-target')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('screen-capture-select-preview')),
        findsNothing,
      );

      final selectTarget = find.byKey(
        const ValueKey('screen-recording-select-target'),
      );
      await tester.ensureVisible(selectTarget);
      expect(tester.widget<OutlinedButton>(selectTarget).onPressed, isNotNull);
      expect(selectTarget.hitTestable(), findsOneWidget);
      await tester.tap(selectTarget);
      await tester.pump(const Duration(milliseconds: 300));

      expect(recorderCalls, contains('pickTarget'));
      expect(find.textContaining('测试会议窗口'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exit waits for a pending screen picker before stopping capture',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-exit-screen-picker-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      final selectionResult = Completer<Map<String, Object?>?>();
      final screenCalls = <String>[];
      const audioChannel = MethodChannel('test/yixue-exit-screen-audio');
      const screenChannel = MethodChannel('test/yixue-exit-screen-capture');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      messenger.setMockMethodCallHandler(screenChannel, (call) async {
        screenCalls.add(call.method);
        if (call.method == 'isSupported') return true;
        if (call.method == 'selectSource') return selectionResult.future;
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(audioChannel, null);
        messenger.setMockMethodCallHandler(screenChannel, null);
      });

      await _pumpWorkbench(
        tester,
        dataDirectory,
        audioChannel,
        screenCapture: DesktopScreenCaptureAdapter(
          applicationDataDirectory: dataDirectory,
          methodChannel: screenChannel,
          eventChannel: const EventChannel('test/yixue-exit-screen-events'),
        ),
      );
      await _expandUnifiedSettings(tester);
      await _expandSettingsCategory(tester, 'subtitle-recording-settings');
      final screenCaptureButton = find.byKey(
        const ValueKey('screen-capture-select-controls'),
      );
      await tester.ensureVisible(screenCaptureButton);
      await tester.tap(screenCaptureButton);
      await tester.pump();
      expect(screenCalls, contains('selectSource'));

      final exitCleanup = AppExitCleanupRegistry.prepareForExit();
      await tester.pump();
      expect(screenCalls, isNot(contains('stopCapture')));

      selectionResult.complete(<String, Object?>{
        'textureId': 7,
        'width': 1280,
        'height': 720,
        'targetName': '测试窗口',
      });
      await tester.pump();
      await exitCleanup;
      expect(screenCalls, contains('stopCapture'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        screenCalls.where((method) => method == 'stopCapture'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'language selectors include registered languages and source Auto',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-multilingual-ui-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final audioChannel = const MethodChannel('test/yixue-audio-capture');
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

      await _pumpWorkbench(tester, dataDirectory, audioChannel);
      await _expandUnifiedSettings(tester);

      expect(find.text('中文 · 普通话'), findsOneWidget);
      expect(find.text('英语 · English'), findsOneWidget);

      final sourceLanguageSelector = find.byKey(
        const ValueKey('asr-language-原文语言'),
      );
      await tester.ensureVisible(sourceLanguageSelector);
      await tester.tap(sourceLanguageSelector);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('英语 · English'), findsWidgets);
      expect(find.text('中文 · 普通话'), findsWidgets);
      expect(find.text('日语 · 日本語'), findsWidgets);
      expect(find.text('韩语 · 한국어'), findsWidgets);
      expect(find.text('西班牙语 · Español'), findsWidgets);
      expect(find.text('法语 · Français'), findsWidgets);
      expect(find.text('德语 · Deutsch'), findsWidgets);
      expect(find.text('葡萄牙语 · Português'), findsWidgets);
      expect(find.text('俄语 · Русский'), findsWidgets);
      expect(find.text('自动识别'), findsWidgets);

      await tester.tap(find.text('日语 · 日本語').last);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const ValueKey('asr-language-译文语言')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('自动识别'), findsNothing);
      // Japanese remains visible in the source selector, but is omitted from
      // the target menu because a language cannot translate to itself.
      expect(find.text('日语 · 日本語'), findsOneWidget);
      expect(find.text('中文 · 普通话'), findsOneWidget);
      expect(find.text('韩语 · 한국어'), findsOneWidget);
      await tester.tap(find.text('中文 · 普通话').last);
      await tester.pump(const Duration(milliseconds: 350));

      await tester.ensureVisible(sourceLanguageSelector);
      await tester.tap(sourceLanguageSelector);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('西班牙语 · Español').last);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('Whisper Tiny 多语言'), findsOneWidget);
      expect(find.textContaining('西班牙语'), findsWidgets);
      final targetLanguageSelector = find.byKey(
        const ValueKey('asr-language-译文语言'),
      );
      await tester.ensureVisible(targetLanguageSelector);
      await tester.tap(targetLanguageSelector);
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('asr-language-option-译文语言-en')),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey('asr-language-option-译文语言-zh')),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey('asr-language-option-译文语言-ja')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('asr-language-option-译文语言-es')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Auto loads routes once and keeps usable directions when one is unavailable',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-multilingual-auto-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final audioChannel = const MethodChannel('test/yixue-auto-audio-capture');
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));

      final requests = <({List<String> sources, String target})>[];
      Future<LiveSubtitleTranslationSetup> loadSetup({
        required List<String> sourceLanguageCodes,
        required String targetLanguageCode,
      }) async {
        requests.add((
          sources: List<String>.of(sourceLanguageCodes),
          target: targetLanguageCode,
        ));
        final partialAutoRoute =
            targetLanguageCode == 'ko' &&
            sourceLanguageCodes.contains('ja') &&
            sourceLanguageCodes.length > 1;
        return LiveSubtitleTranslationSetup(
          executor: const _UnusedTranslationExecutor(),
          routeKind: SubtitleTranslationRouteKind.localProfile,
          providerLabel: '显式多语言 Provider',
          detail: partialAutoRoute ? '日语→韩语不可用，其余已配置方向继续翻译。' : null,
        );
      }

      await _pumpWorkbench(
        tester,
        dataDirectory,
        audioChannel,
        translationSetupLoader: loadSetup,
      );
      await _expandUnifiedSettings(tester);
      requests.clear();

      await tester.tap(find.byKey(const ValueKey('asr-language-原文语言')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('自动识别').last);
      await tester.pump(const Duration(milliseconds: 350));

      expect(requests, hasLength(1));
      expect(requests.single.target, 'en');
      expect(requests.single.sources, isNot(contains('auto')));
      expect(
        requests.single.sources.toSet(),
        containsAll(<String>{'zh', 'ja', 'ko'}),
      );
      expect(find.text('Whisper Tiny 多语言 INT8 + Silero VAD'), findsOneWidget);
      expect(find.textContaining('104 MB'), findsOneWidget);
      expect(find.textContaining('逐帧流式'), findsOneWidget);

      requests.clear();
      await tester.tap(find.byKey(const ValueKey('asr-language-译文语言')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('韩语 · 한국어').last);
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('自动识别'), findsOneWidget);
      expect(find.text('韩语 · 한국어'), findsOneWidget);
      expect(requests, hasLength(1));
      expect(requests.last.target, 'ko');
      expect(
        requests.last.sources.toSet(),
        containsAll(<String>{'en', 'zh', 'ja'}),
      );
      expect(
        find.textContaining('显式多语言 Provider'),
        findsWidgets,
        reason: 'an unavailable Auto direction must not disable other routes',
      );
      expect(find.textContaining('日语→韩语不可用'), findsOneWidget);

      final noticeButton = find.text('查看模型来源与许可');
      await tester.ensureVisible(noticeButton);
      await tester.tap(noticeButton);
      await tester.pump();
      expect(find.text('多语言识别模型来源与许可'), findsOneWidget);
      expect(
        find.textContaining('转换权重仓库未提供独立 model card 或 license 元数据'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'audio-only startup keeps failed source identity for stop retry',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-audio-only-retry-'),
      ))!;
      addTearDown(() async {
        await tester.runAsync(
          () => _deleteTemporaryDirectoryWhenReady(dataDirectory),
        );
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final audioChannel = const MethodChannel(
        'test/yixue-audio-only-retry-capture',
      );
      const eventChannel = EventChannel('test/yixue-audio-events');
      var startAttempts = 0;
      var stopAttempts = 0;
      final startArguments = <Map<Object?, Object?>>[];
      final stopArguments = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') {
          return <dynamic>[
            <String, Object?>{
              'sourceId': 'system-output-1',
              'sourceKind': 'systemOutput',
              'displayName': '系统播放声',
              'description': '测试音源',
            },
            <String, Object?>{
              'sourceId': 'microphone-1',
              'sourceKind': 'microphone',
              'displayName': '麦克风设备',
              'description': '测试麦克风',
            },
          ];
        }
        if (call.method == 'startSource') {
          startAttempts++;
          startArguments.add(call.arguments as Map<Object?, Object?>);
          if (startAttempts == 2) {
            throw PlatformException(
              code: 'simulated-start-failure',
              message: '模拟第二个音源启动失败',
            );
          }
          return null;
        }
        if (call.method == 'stopSource') {
          stopAttempts++;
          final arguments = call.arguments as Map<Object?, Object?>;
          stopArguments.add(arguments);
          if (arguments['sourceId'] == 'microphone-1' && stopAttempts == 1) {
            throw PlatformException(
              code: 'simulated-stop-failure',
              message: '模拟首次停止失败',
            );
          }
          return null;
        }
        return null;
      });
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(onListen: (arguments, events) {}),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(audioChannel, null));
      addTearDown(() => messenger.setMockStreamHandler(eventChannel, null));

      await _pumpWorkbench(tester, dataDirectory, audioChannel);
      await _expandUnifiedSettings(tester);
      await _expandSettingsCategory(tester, 'subtitle-recording-settings');
      for (var attempt = 0; attempt < 20; attempt++) {
        if (find.text('电脑播放声音').evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('电脑播放声音'), findsOneWidget);
      final settingsScroll = find.byType(Scrollable).first;
      final microphoneToggle = find.text('麦克风');
      await tester.scrollUntilVisible(
        microphoneToggle,
        220,
        scrollable: settingsScroll,
      );
      await tester.tap(microphoneToggle);
      await tester.pump();
      final startButton = find.text('仅录音，不开字幕');
      await tester.scrollUntilVisible(
        startButton,
        220,
        scrollable: settingsScroll,
      );
      final startControl = tester.widget<FilledButton>(
        find
            .ancestor(of: startButton, matching: find.byType(FilledButton))
            .first,
      );
      expect(startControl.onPressed, isNotNull);
      await tester.runAsync(
        () => (startControl.onPressed as dynamic)() as Future<void>,
      );
      await tester.pump();

      expect(startAttempts, 2);
      expect(startArguments, hasLength(2));
      expect(startArguments.last['captureAttemptId'], isNotEmpty);
      expect(
        startArguments.map((arguments) => arguments['sourceId']).toList(),
        <String>['system-output-1', 'microphone-1'],
      );
      expect(stopAttempts, 2);
      expect(
        stopArguments.map((arguments) => arguments['sourceId']).toList(),
        <String>['microphone-1', 'system-output-1'],
      );
      expect(find.text('停止并保存独立录音'), findsOneWidget);

      final stopAudioButton = find
          .ancestor(
            of: find.text('停止并保存独立录音'),
            matching: find.byType(FilledButton),
          )
          .first;
      final stopAudioControl = tester.widget<FilledButton>(stopAudioButton);
      await tester.runAsync(
        () => (stopAudioControl.onPressed as dynamic)() as Future<void>,
      );
      await tester.pump();

      expect(stopAttempts, 3);
      expect(
        stopArguments.map((arguments) => arguments['sessionId']).toSet(),
        hasLength(1),
      );
      expect(
        stopArguments.map((arguments) => arguments['sourceId']).toList(),
        <String>['microphone-1', 'system-output-1', 'microphone-1'],
      );
      expect(find.text('仅录音，不开字幕'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('transcript language badge displays detected language code', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SubtitleTranscriptLanguageBadge(languageCode: 'ja'),
        ),
      ),
    );

    expect(find.text('日语 · 日本語'), findsOneWidget);
    expect(find.text('自动识别'), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SubtitleTranscriptLanguageBadge(languageCode: 'und'),
        ),
      ),
    );
    expect(find.text('未知语种（und）'), findsOneWidget);
    expect(find.text('自动识别'), findsNothing);
  });

  testWidgets(
    'active capture notice stays visible and returns to live subtitles',
    (tester) async {
      final status = ValueNotifier<String?>('AI 同传正在采集音频');
      addTearDown(status.dispose);
      var returnedToSubtitles = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SimultaneousInterpretationActivityBanner(
              status: status,
              onReturn: () => returnedToSubtitles = true,
            ),
          ),
        ),
      );

      expect(find.text('AI 同传正在采集音频'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('return-to-live-subtitles')));
      expect(returnedToSubtitles, isTrue);

      status.value = null;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('active-subtitle-activity-banner')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'exit cleanup skips desktop capture that never became available',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-screen-exit-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const screenChannel = MethodChannel('test/yixue-screen-exit');
      final calls = <String>[];
      messenger.setMockMethodCallHandler(screenChannel, (call) async {
        calls.add(call.method);
        if (call.method == 'isSupported') return false;
        throw PlatformException(
          code: 'captureUnavailable',
          message: 'desktop capture is unavailable',
        );
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(screenChannel, null),
      );

      await _pumpWorkbench(
        tester,
        dataDirectory,
        const MethodChannel('test/yixue-screen-exit-audio'),
        screenCapture: DesktopScreenCaptureAdapter(
          applicationDataDirectory: dataDirectory,
          methodChannel: screenChannel,
          eventChannel: const EventChannel('test/yixue-screen-exit-events'),
        ),
      );
      calls.clear();

      await expectLater(AppExitCleanupRegistry.prepareForExit(), completes);
      expect(calls, isEmpty);
    },
  );

  testWidgets(
    'desktop capture initialization error keeps its code and can be retried',
    (tester) async {
      final dataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-screen-probe-'),
      ))!;
      addTearDown(() => dataDirectory.delete(recursive: true));

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const audioChannel = MethodChannel('test/yixue-screen-probe-audio');
      const screenChannel = MethodChannel('test/yixue-screen-probe');
      final calls = <String>[];
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        if (call.method == 'enumerateSources') return <dynamic>[];
        return null;
      });
      messenger.setMockMethodCallHandler(screenChannel, (call) async {
        calls.add(call.method);
        if (call.method == 'isSupported') {
          throw PlatformException(
            code: 'captureUnavailable',
            message: '桌面画面采集已关闭。',
          );
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(audioChannel, null);
        messenger.setMockMethodCallHandler(screenChannel, null);
      });

      await _pumpWorkbench(
        tester,
        dataDirectory,
        audioChannel,
        screenCapture: DesktopScreenCaptureAdapter(
          applicationDataDirectory: dataDirectory,
          methodChannel: screenChannel,
          eventChannel: const EventChannel('test/yixue-screen-probe-events'),
        ),
      );

      expect(find.textContaining('captureUnavailable'), findsWidgets);
      final settings = find.byKey(const ValueKey('subtitle-unified-settings'));
      await tester.ensureVisible(settings);
      await tester.tap(settings);
      await tester.pump(const Duration(milliseconds: 350));
      await _expandSettingsCategory(tester, 'subtitle-recording-settings');
      final retry = find.byKey(const ValueKey('screen-capture-retry-controls'));
      await tester.ensureVisible(retry);
      expect(find.text('重新检测采集'), findsWidgets);

      await tester.tap(retry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls.where((method) => method == 'isSupported'), hasLength(2));
      expect(find.textContaining('captureUnavailable'), findsWidgets);
    },
  );
}

Future<void> _pumpWorkbench(
  WidgetTester tester,
  Directory dataDirectory,
  MethodChannel audioChannel, {
  LiveSubtitleTranslationSetupLoader? translationSetupLoader,
  DesktopScreenCaptureAdapter? screenCapture,
  Size viewportSize = const Size(1440, 1000),
  double devicePixelRatio = 1,
}) async {
  tester.view.physicalSize = viewportSize;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final appDataDirectory = dataDirectory.path;
  final modelStore = StreamingAsrModelStore(
    applicationDataDirectory: dataDirectory,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: LiveSubtitleWorkbenchPage(
        capture: DesktopAudioCaptureAdapter(
          methodChannel: audioChannel,
          eventChannel: EventChannel('test/yixue-audio-events'),
        ),
        screenCapture: screenCapture,
        asrRuntime: _UnusedAsrRuntime(),
        modelStore: modelStore,
        multilingualModelStore: MultilingualAsrModelStore(
          applicationDataDirectory: dataDirectory,
        ),
        sessionStore: FileSubtitleSessionStore(
          Directory('$appDataDirectory/history'),
        ),
        displayPreferencesStore: FileSubtitleDisplayPreferencesStore(
          File('$appDataDirectory/display-preferences.json'),
        ),
        translationSetupLoader: translationSetupLoader ?? _loadLocalSetup,
        onOpenHistory: () async {},
        appDataDirectory: appDataDirectory,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _expandUnifiedSettings(WidgetTester tester) async {
  final settings = find.text('同传设置');
  await tester.ensureVisible(settings);
  await tester.tap(settings);
  await tester.pump(const Duration(milliseconds: 350));
  await _expandSettingsCategory(tester, 'subtitle-language-settings');
  final sourceLanguageField = find.descendant(
    of: find.byKey(const ValueKey('asr-language-原文语言')),
    matching: find.byType(DropdownButtonFormField<String>),
  );
  await tester.ensureVisible(sourceLanguageField);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _expandSettingsCategory(WidgetTester tester, String key) async {
  final category = find.byKey(ValueKey(key));
  final title = find.descendant(
    of: category,
    matching: find.text(switch (key) {
      'subtitle-language-settings' => '语言与识别',
      'subtitle-recording-settings' => '录制与音源',
      'subtitle-window-settings' => '字幕窗外观',
      'subtitle-privacy-settings' => '采集与隐私',
      _ => throw ArgumentError.value(key, 'key'),
    }),
  );
  await tester.ensureVisible(title);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(title);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<LiveSubtitleTranslationSetup> _loadLocalSetup({
  required List<String> sourceLanguageCodes,
  required String targetLanguageCode,
}) async => LiveSubtitleTranslationSetup(
  executor: const _UnusedTranslationExecutor(),
  routeKind: SubtitleTranslationRouteKind.localProfile,
  providerLabel: '本地测试 Provider',
);

Future<void> _deleteTemporaryDirectoryWhenReady(Directory directory) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (!await directory.exists()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException catch (error) {
      final errorCode = error.osError?.errorCode;
      if ((errorCode != 32 && errorCode != 5) || attempt == 39) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

final class _UnusedAsrRuntime implements StreamingAsrRuntime {
  @override
  Future<StreamingAsrSession> openSession({
    required String sessionId,
    required String sourceId,
    required SubtitleAudioSourceKind sourceKind,
    required String sourceLanguageCode,
  }) async => throw UnimplementedError();
}

final class _UnusedTranslationExecutor implements SubtitleTranslationExecutor {
  const _UnusedTranslationExecutor();

  @override
  Future<String> translate(SubtitleTranslationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<void> cancel(String requestId) async {}
}
