import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/recording_media_player_dialog.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_audio_recording.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_media_playback_coordinator.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_post_session_service.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_history_navigation.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_history_page.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_recording_index_scan_registry.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_window_host.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_window_view.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_video_recording_index.dart';

void main() {
  test('active audio playback blocks deletion of only its own recording', () {
    final playbackKeys = <String>{r'session-1:recording-a:D:\data\one.wav'};

    expect(
      subtitleHistorySessionHasActiveAudioPlayback('session-1', playbackKeys),
      isTrue,
    );
    expect(
      subtitleHistorySessionHasActiveAudioPlayback('session-2', playbackKeys),
      isFalse,
    );
    expect(
      subtitleHistoryRecordingHasActiveAudioPlayback(
        'session-1',
        'recording-a',
        playbackKeys,
      ),
      isTrue,
    );
    expect(
      subtitleHistoryRecordingHasActiveAudioPlayback(
        'session-1',
        'recording-b',
        playbackKeys,
      ),
      isFalse,
    );
  });

  test(
    'history navigation waits until the topmost subtitle window is hidden',
    () async {
      final events = <String>[];
      final hideCompletion = Completer<void>();
      final subtitleWindow = _FakeSubtitleWindow(
        events: events,
        hideAction: () => hideCompletion.future,
      );

      final navigation = hideSubtitleWindowBeforeHistoryNavigation(
        subtitleWindow: subtitleWindow,
        onHidden: () => events.add('hidden'),
        openHistory: () async => events.add('history'),
      );

      expect(events, <String>['hide-start']);
      hideCompletion.complete();
      expect(await navigation, isNull);
      expect(events, <String>['hide-start', 'hide-end', 'hidden', 'history']);
      expect(subtitleWindow.isVisible, isFalse);
    },
  );

  test(
    'history does not open when the topmost subtitle window cannot be hidden',
    () async {
      final events = <String>[];
      final subtitleWindow = _FakeSubtitleWindow(
        events: events,
        hideAction: () =>
            Future<void>.error(StateError('child did not respond')),
      );

      final failure = await hideSubtitleWindowBeforeHistoryNavigation(
        subtitleWindow: subtitleWindow,
        onHidden: () => events.add('hidden'),
        onHideFailure: (_) => events.add('cleanup-requested'),
        openHistory: () async => events.add('history'),
      );

      expect(failure, isA<StateError>());
      expect(events, <String>['hide-start', 'cleanup-requested']);
    },
  );

  test(
    'history navigation remains active until the route is dismissed',
    () async {
      final events = <String>[];
      final historyClosed = Completer<void>();
      final subtitleWindow = _FakeSubtitleWindow(
        events: events,
        hideAction: () async {},
      );

      var navigationCompleted = false;
      final navigation = hideSubtitleWindowBeforeHistoryNavigation(
        subtitleWindow: subtitleWindow,
        openHistory: () {
          events.add('history-open');
          return historyClosed.future;
        },
      )..then((_) => navigationCompleted = true);

      await Future<void>.delayed(Duration.zero);
      expect(events, <String>['hide-start', 'hide-end', 'history-open']);
      expect(navigationCompleted, isFalse);

      historyClosed.complete();
      expect(await navigation, isNull);
      expect(navigationCompleted, isTrue);
    },
  );

  testWidgets('Escape returns from subtitle history to the workbench', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryNavigationHost(
          store: _ImmediateSubtitleSessionStore(),
          reviewStore: _ImmediateReviewStore(),
        ),
      ),
    );
    await tester.tap(find.text('打开字幕历史'));
    await tester.pumpAndSettle();

    expect(find.text('AI 同传 · 字幕历史'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('打开字幕历史'), findsOneWidget);
    expect(find.text('AI 同传 · 字幕历史'), findsNothing);
  });

  testWidgets(
    'first subtitle history load shows a skeleton, not a blank spinner',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final sessions = Completer<List<SubtitleSessionRecord>>();
      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(
              listSessionsLoader: () => sessions.future,
            ),
            reviewStore: _ImmediateReviewStore(),
          ),
        ),
      );
      await tester.pump();

      expect(find.bySemanticsLabel('正在加载字幕历史'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);

      sessions.complete(const <SubtitleSessionRecord>[]);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('正在加载字幕历史'), findsNothing);
      expect(find.text('还没有保存的字幕会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history header and scrolling stay usable in a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appDataDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yixue-narrow-history-'),
    ))!;
    addTearDown(() => appDataDirectory.delete(recursive: true));

    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleSessionHistoryPage(
          store: _ImmediateSubtitleSessionStore(),
          reviewStore: _ImmediateReviewStore(),
          appDataDirectory: appDataDirectory,
          audioRecordingLoader: (_) async => const [],
          videoRecordingLoader: (_) async => const [],
          sessionAudioDirectoryResolverForTesting: (_, _) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AI 同传 · 字幕历史'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pumpAndSettle();
    expect(find.text('数据如何保存'), findsOneWidget);
    expect(
      find.text('字幕保存在本机；录音/录屏需开启，远程复盘确认后发送。'),
      findsOneWidget,
    );
    expect(find.textContaining('字幕会话和确认后的字幕文本保存在本机'), findsNothing);
    await tester.tap(find.text('数据如何保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('字幕会话和确认后的字幕文本保存在本机'), findsOneWidget);
    await tester.tap(find.text('数据如何保存'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pumpAndSettle();

    expect(find.text('AI 同传 · 字幕历史'), findsOneWidget);
    expect(find.byTooltip('刷新历史'), findsOneWidget);
    expect(find.text('清理较早记录'), findsOneWidget);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty video recording explains why there is no playable image', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appDataDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yixue-empty-history-video-'),
    ))!;
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final emptyVideo = SubtitleVideoRecordingEntry(
      fileName: 'screen-empty-session.mp4',
      file: File('${appDataDirectory.path}${Platform.pathSeparator}empty.mp4'),
      modifiedAt: DateTime.utc(2026, 11, 5),
      sizeBytes: 0,
      duration: Duration.zero,
      isIncomplete: true,
      canAttemptPlayback: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleSessionHistoryPage(
          store: _ImmediateSubtitleSessionStore(),
          reviewStore: _ImmediateReviewStore(),
          appDataDirectory: appDataDirectory,
          sessionAudioDirectoryResolverForTesting: (_, _) async => null,
          audioRecordingLoader: (_) async => const [],
          videoRecordingLoader: (_) async => [emptyVideo],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('录屏文件为空（0 B），没有可播放的视频数据'), findsOneWidget);
    expect(find.text('没有画面可播放'), findsOneWidget);
    final unavailableButton = find.widgetWithText(FilledButton, '没有画面可播放');
    expect(tester.widget<FilledButton>(unavailableButton).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not play a partial video while its session is capturing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appDataDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yixue-active-history-video-'),
    ))!;
    addTearDown(() => appDataDirectory.delete(recursive: true));
    const sessionId = 'active-video-session';
    const fileName = 'screen-active-session.partial.mp4';
    final activeSession = _completedHistorySession(
      sessionId: sessionId,
      sourceText: 'active capture',
      status: SubtitleSessionHistoryStatus.capturing,
    );
    final partialVideo = SubtitleVideoRecordingEntry(
      fileName: fileName,
      file: File('${appDataDirectory.path}/$fileName'),
      modifiedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      sizeBytes: 256,
      duration: Duration.zero,
      isIncomplete: true,
      canAttemptPlayback: true,
      sessionId: sessionId,
    );
    var playbackFactoryCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleSessionHistoryPage(
          store: _ImmediateSubtitleSessionStore(sessions: [activeSession]),
          reviewStore: _ImmediateReviewStore(),
          appDataDirectory: appDataDirectory,
          sessionAudioDirectoryResolverForTesting: (_, _) async => null,
          audioRecordingLoader: (_) async => const [],
          videoRecordingLoader: (_) async => [partialVideo],
          recordingPlaybackControllerFactoryForTesting: (_) {
            playbackFactoryCalls += 1;
            return _HistoryFakePlaybackController(isVideo: true);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sessionCard = find.byKey(
      const PageStorageKey<String>('subtitle-session-active-video-session'),
    );
    await tester.ensureVisible(sessionCard);
    await tester.tap(sessionCard);
    await tester.pumpAndSettle();
    final recordingTile = find
        .ancestor(of: find.text(fileName), matching: find.byType(ListTile))
        .first;
    final playButton = find.descendant(
      of: recordingTile,
      matching: find.byIcon(Icons.play_circle_outline_rounded),
    );
    await tester.tap(playButton);
    await tester.pumpAndSettle();

    expect(find.text('关联会话仍在录制。请先停止录屏，结束后再播放这条未完成文件。'), findsOneWidget);
    expect(playbackFactoryCalls, 0);
    expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final audioStatus in const <SubtitleAudioIndexedRecordingStatus>[
    SubtitleAudioIndexedRecordingStatus.incomplete,
    SubtitleAudioIndexedRecordingStatus.unknown,
  ]) {
    testWidgets(
      'audio ${audioStatus.name} quality does not mark a stopped partial video as active',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final appDataDirectory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp(
            'yixue-stopped-history-video-${audioStatus.name}-',
          ),
        ))!;
        addTearDown(() => appDataDirectory.delete(recursive: true));
        final sessionId = 'stopped-video-${audioStatus.name}';
        final recordingId = 'quality-audio-${audioStatus.name}';
        final videoFileName = 'screen-$sessionId.partial.mp4';
        final audioRecording = SubtitleAudioIndexedRecording(
          sessionId: sessionId,
          recordingId: recordingId,
          status: audioStatus,
          startedAtUtc: DateTime.utc(2026, 10, 22, 10),
          endedAtUtc: DateTime.utc(2026, 10, 22, 10, 1),
          directory: appDataDirectory,
          files: const <SubtitleAudioIndexedFile>[],
          emptyAudioSources: 1,
          droppedFrames:
              audioStatus == SubtitleAudioIndexedRecordingStatus.incomplete
              ? 3
              : 0,
          discontinuities: 0,
          lossCountersKnown:
              audioStatus != SubtitleAudioIndexedRecordingStatus.unknown,
        );
        final videoRecording = SubtitleVideoRecordingEntry(
          fileName: videoFileName,
          file: File('${appDataDirectory.path}/$videoFileName'),
          modifiedAt: DateTime.utc(2026, 10, 22, 10, 1),
          sizeBytes: 128,
          duration: Duration.zero,
          isIncomplete: true,
          canAttemptPlayback: true,
          sessionId: sessionId,
        );
        final playableFile = File(
          '${appDataDirectory.path}/recovered-$videoFileName',
        );
        final controller = _HistoryFakePlaybackController(isVideo: true);
        var playbackFactoryCalls = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: SubtitleSessionHistoryPage(
              store: _ImmediateSubtitleSessionStore(),
              reviewStore: _ImmediateReviewStore(),
              appDataDirectory: appDataDirectory,
              audioRecordingLoader: (_) async => [audioRecording],
              videoRecordingLoader: (_) async => [videoRecording],
              videoPlayableRecordingResolverForTesting: (_, _) async =>
                  playableFile,
              recordingPlaybackControllerFactoryForTesting: (_) {
                playbackFactoryCalls++;
                return controller;
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();

        final audioCard = find.byKey(
          PageStorageKey<String>('standalone-audio-$recordingId'),
        );
        await tester.ensureVisible(audioCard);
        await tester.tap(audioCard);
        await tester.pump(const Duration(milliseconds: 350));
        final videoTile = find
            .ancestor(
              of: find.text(videoFileName),
              matching: find.byType(ListTile),
            )
            .first;
        final playIcon = find.descendant(
          of: videoTile,
          matching: find.byIcon(Icons.play_circle_outline_rounded),
        );
        final playButton = find
            .ancestor(of: playIcon, matching: find.byType(IconButton))
            .first;
        await tester.ensureVisible(playButton);
        final onPressed = tester.widget<IconButton>(playButton).onPressed;
        expect(onPressed, isNotNull);
        await tester.runAsync(() async {
          onPressed!.call();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump(const Duration(milliseconds: 50));
        for (
          var attempt = 0;
          attempt < 50 && find.byType(Dialog).evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('关联会话仍在录制。请先停止录屏，结束后再播放这条未完成文件。'), findsNothing);
        expect(find.byType(Dialog), findsOneWidget);
        expect(playbackFactoryCalls, 1);
        expect(controller.openedFile?.path, playableFile.path);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('关闭播放器'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isFalse);
      },
    );
  }

  testWidgets(
    'audio quality status does not block deleting a stopped partial video',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-stopped-video-delete-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      const sessionId = 'stopped-video-delete';
      const recordingId = 'quality-audio-delete';
      const videoFileName = 'screen-stopped-video-delete.partial.mp4';
      final audioRecording = SubtitleAudioIndexedRecording(
        sessionId: sessionId,
        recordingId: recordingId,
        status: SubtitleAudioIndexedRecordingStatus.incomplete,
        startedAtUtc: DateTime.utc(2026, 10, 22, 10),
        endedAtUtc: DateTime.utc(2026, 10, 22, 10, 1),
        directory: appDataDirectory,
        files: const <SubtitleAudioIndexedFile>[],
        emptyAudioSources: 1,
        droppedFrames: 3,
        discontinuities: 0,
        lossCountersKnown: true,
      );
      final videoRecording = SubtitleVideoRecordingEntry(
        fileName: videoFileName,
        file: File('${appDataDirectory.path}/$videoFileName'),
        modifiedAt: DateTime.utc(2026, 10, 22, 10, 1),
        sizeBytes: 128,
        duration: Duration.zero,
        isIncomplete: true,
        canAttemptPlayback: true,
        sessionId: sessionId,
      );
      var deleteCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            audioRecordingLoader: (_) async => [audioRecording],
            videoRecordingLoader: (_) async => [videoRecording],
            incompleteVideoDeleterForTesting: (_, _) async {
              deleteCalls++;
              return true;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      final audioCard = find.byKey(
        const PageStorageKey<String>('standalone-audio-$recordingId'),
      );
      await tester.ensureVisible(audioCard);
      await tester.tap(audioCard);
      await tester.pump(const Duration(milliseconds: 350));
      final deleteTooltip = find.byTooltip('处理未完成录屏：保留原文件或确认删除');
      final deleteButton = find
          .ancestor(of: deleteTooltip, matching: find.byType(IconButton))
          .first;
      await tester.ensureVisible(deleteButton);
      final onPressed = tester.widget<IconButton>(deleteButton).onPressed;
      expect(onPressed, isNotNull);
      onPressed!.call();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('处理未完成录屏'), findsOneWidget);
      await tester.tap(find.text('确认删除并放弃恢复'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      expect(deleteCalls, 1);
      expect(find.text('关联会话仍在进行。请先停止录屏，结束后再处理这条未完成文件。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'subtitle history is shown while the video index is still loading',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () =>
            Directory.systemTemp.createTemp('yixue-history-video-index-test-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final videoIndex = Completer<List<SubtitleVideoRecordingEntry>>();
      final reviewIndex = Completer<List<SubtitlePostSessionStoredReview>>();

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(),
            reviewStore: _DeferredReviewStore(reviewIndex.future),
            appDataDirectory: appDataDirectory,
            videoRecordingLoader: (_) => videoIndex.future,
          ),
        ),
      );

      final emptyHistory = find.text('还没有保存的字幕会话');
      for (
        var attempt = 0;
        attempt < 50 && emptyHistory.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(emptyHistory, findsOneWidget);
      expect(find.text('正在检查视频录制索引；字幕和录音历史已可查看。'), findsOneWidget);

      videoIndex.complete(const <SubtitleVideoRecordingEntry>[]);
      reviewIndex.complete(const <SubtitlePostSessionStoredReview>[]);
      for (
        var attempt = 0;
        attempt < 10 &&
            find.text('正在检查视频录制索引；字幕和录音历史已可查看。').evaluate().isNotEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(find.text('正在检查视频录制索引；字幕和录音历史已可查看。'), findsNothing);
      // The real audio index uses disk I/O and has its own bounded timeout.
      // Advance the fake clock so the widget test cannot leak that timer.
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('refresh keeps existing subtitle history visible while loading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final existing = _completedHistorySession(
      sessionId: 'refresh-preserves-history',
      sourceText: 'Existing subtitle remains visible',
    );
    final refreshedSessions = Completer<List<SubtitleSessionRecord>>();
    var listCalls = 0;
    final store = _ImmediateSubtitleSessionStore(
      sessions: [existing],
      listSessionsLoader: () {
        listCalls++;
        return listCalls == 1
            ? Future<List<SubtitleSessionRecord>>.value([existing])
            : refreshedSessions.future;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleSessionHistoryPage(
          store: store,
          reviewStore: _ImmediateReviewStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 个本地字幕会话'), findsOneWidget);

    await tester.tap(find.byTooltip('刷新历史'));
    await tester.pump();

    expect(find.text('1 个本地字幕会话'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('subtitle-history-refresh-progress')),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);

    refreshedSessions.complete([existing]);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subtitle-history-refresh-progress')),
      findsNothing,
    );
    expect(find.text('1 个本地字幕会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'refresh reuses an audio index scan that is still running after timeout',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-audio-flight-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final session = _completedHistorySession(
        sessionId: 'audio-index-flight',
        sourceText: 'audio history remains visible',
      );
      final audioIndex = Completer<List<SubtitleAudioIndexedRecording>>();
      var audioIndexCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(sessions: [session]),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, _) async => null,
            audioRecordingLoader: (_) {
              audioIndexCalls += 1;
              return audioIndexCalls == 1
                  ? audioIndex.future
                  : Future<List<SubtitleAudioIndexedRecording>>.value(
                      const <SubtitleAudioIndexedRecording>[],
                    );
            },
            videoRecordingLoader: (_) async => const [],
          ),
        ),
      );

      final loadingRecordings = find.text('正在检查会话录音…');
      for (
        var attempt = 0;
        attempt < 50 && loadingRecordings.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(loadingRecordings, findsOneWidget);
      expect(audioIndexCalls, 1);

      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(find.textContaining('独立录音目录暂时无法读取'), findsOneWidget);
      expect(audioIndexCalls, 1);

      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      expect(audioIndexCalls, 1);

      audioIndex.complete(const <SubtitleAudioIndexedRecording>[]);
      await tester.pump(const Duration(milliseconds: 100));

      expect(loadingRecordings, findsNothing);
      expect(find.textContaining('独立录音目录暂时无法读取'), findsNothing);
      expect(audioIndexCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh shares an in-flight video index scan and reloads after completion',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-video-flight-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final firstVideoIndex = Completer<List<SubtitleVideoRecordingEntry>>();
      var videoIndexCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, _) async => null,
            audioRecordingLoader: (_) async => const [],
            videoRecordingLoader: (_) {
              videoIndexCalls++;
              return videoIndexCalls == 1
                  ? firstVideoIndex.future
                  : Future<List<SubtitleVideoRecordingEntry>>.value(
                      const <SubtitleVideoRecordingEntry>[],
                    );
            },
          ),
        ),
      );

      for (var attempt = 0; attempt < 50 && videoIndexCalls == 0; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(videoIndexCalls, 1);

      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      expect(videoIndexCalls, 1);

      firstVideoIndex.complete(const <SubtitleVideoRecordingEntry>[]);
      for (
        var attempt = 0;
        attempt < 50 &&
            find.text('正在检查视频录制索引；字幕和录音历史已可查看。').evaluate().isNotEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(videoIndexCalls, 1);
      expect(find.text('正在检查视频录制索引；字幕和录音历史已可查看。'), findsNothing);

      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      for (var attempt = 0; attempt < 50 && videoIndexCalls < 2; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(videoIndexCalls, 2);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh retries a timed-out video index once without accepting stale data',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-video-timeout-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final firstVideoIndex = Completer<List<SubtitleVideoRecordingEntry>>();
      var videoIndexCalls = 0;
      const lateFileName = 'late-stale-recording.mp4';
      final lateVideo = SubtitleVideoRecordingEntry(
        fileName: lateFileName,
        file: File('${appDataDirectory.path}/$lateFileName'),
        modifiedAt: DateTime.utc(2026, 11, 4),
        sizeBytes: 100,
        duration: const Duration(seconds: 1),
        isIncomplete: false,
      );
      const freshFileName = 'fresh-retry-recording.mp4';
      final freshVideo = SubtitleVideoRecordingEntry(
        fileName: freshFileName,
        file: File('${appDataDirectory.path}/$freshFileName'),
        modifiedAt: DateTime.utc(2026, 11, 5),
        sizeBytes: 200,
        duration: const Duration(seconds: 2),
        isIncomplete: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, _) async => null,
            audioRecordingLoader: (_) async => const [],
            videoRecordingLoader: (_) {
              videoIndexCalls += 1;
              return videoIndexCalls == 1
                  ? firstVideoIndex.future
                  : videoIndexCalls == 2
                  ? Future<List<SubtitleVideoRecordingEntry>>.value(
                      <SubtitleVideoRecordingEntry>[freshVideo],
                    )
                  : Future<List<SubtitleVideoRecordingEntry>>.value(
                      const <SubtitleVideoRecordingEntry>[],
                    );
            },
          ),
        ),
      );

      final loadingVideoIndex = find.text('正在检查视频录制索引；字幕和录音历史已可查看。');
      for (
        var attempt = 0;
        attempt < 50 && loadingVideoIndex.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(videoIndexCalls, 1);
      expect(loadingVideoIndex, findsOneWidget);

      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(find.text('本机视频录制目录读取超时；可刷新历史再试一次。字幕和音频历史仍可使用。'), findsOneWidget);

      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      for (var attempt = 0; attempt < 50 && videoIndexCalls < 2; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(videoIndexCalls, 2);
      await tester.pumpAndSettle();
      expect(find.text(freshFileName), findsOneWidget);

      firstVideoIndex.complete([lateVideo]);
      await tester.pumpAndSettle();
      expect(loadingVideoIndex, findsNothing);
      expect(find.text(freshFileName), findsOneWidget);
      expect(find.text(lateFileName), findsNothing);
      expect(videoIndexCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    're-entry permits only one bounded video scan replacement after timeout',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-reentry-flight-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final audioIndex = Completer<List<SubtitleAudioIndexedRecording>>();
      final firstVideoIndex = Completer<List<SubtitleVideoRecordingEntry>>();
      final replacementVideoIndex =
          Completer<List<SubtitleVideoRecordingEntry>>();
      final resumedVideoIndex = Completer<List<SubtitleVideoRecordingEntry>>();
      var audioIndexCalls = 0;
      var videoIndexCalls = 0;

      SubtitleSessionHistoryPage buildPage() => SubtitleSessionHistoryPage(
        store: _ImmediateSubtitleSessionStore(),
        reviewStore: _ImmediateReviewStore(),
        appDataDirectory: appDataDirectory,
        sessionAudioDirectoryResolverForTesting: (_, _) async => null,
        audioRecordingLoader: (_) {
          audioIndexCalls++;
          return audioIndex.future;
        },
        videoRecordingLoader: (_) {
          videoIndexCalls++;
          return switch (videoIndexCalls) {
            1 => firstVideoIndex.future,
            2 => replacementVideoIndex.future,
            _ => resumedVideoIndex.future,
          };
        },
      );

      await tester.pumpWidget(MaterialApp(home: buildPage()));
      for (
        var attempt = 0;
        attempt < 50 && (audioIndexCalls == 0 || videoIndexCalls == 0);
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(audioIndexCalls, 1);
      expect(videoIndexCalls, 1);

      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(
        SubtitleRecordingIndexScanRegistry.instance.hasVideoScanCapacity(
          appDataDirectory,
        ),
        isTrue,
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      await tester.pumpWidget(MaterialApp(home: buildPage()));
      for (var attempt = 0; attempt < 50; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(audioIndexCalls, 1);
      expect(videoIndexCalls, 2);

      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(
        SubtitleRecordingIndexScanRegistry.instance.hasVideoScanCapacity(
          appDataDirectory,
        ),
        isFalse,
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      await tester.pumpWidget(MaterialApp(home: buildPage()));
      for (var attempt = 0; attempt < 50; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(audioIndexCalls, 1);
      expect(
        videoIndexCalls,
        2,
        reason: 'two unresolved scans must cap subsequent history re-entry',
      );

      expect(find.textContaining('视频目录仍有两次扫描未结束'), findsOneWidget);
      final videoWarningCard = find.ancestor(
        of: find.text('本机视频历史提示'),
        matching: find.byType(Card),
      );
      expect(videoWarningCard, findsOneWidget);
      expect(
        find.descendant(of: videoWarningCard, matching: find.text('重试')),
        findsNothing,
      );

      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      expect(
        videoIndexCalls,
        2,
        reason: 'a refresh at the scan cap must not start or rejoin a timed-out scan',
      );
      expect(find.text('正在检查视频录制索引；字幕和录音历史已可查看。'), findsNothing);

      audioIndex.complete(const <SubtitleAudioIndexedRecording>[]);
      firstVideoIndex.complete(const <SubtitleVideoRecordingEntry>[]);
      replacementVideoIndex.complete(const <SubtitleVideoRecordingEntry>[]);
      for (var attempt = 0; attempt < 50; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(
        SubtitleRecordingIndexScanRegistry.instance.hasVideoScanCapacity(
          appDataDirectory,
        ),
        isTrue,
      );
      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      expect(videoIndexCalls, 3);
      expect(find.textContaining('视频目录仍有两次扫描未结束'), findsNothing);
      expect(find.text('正在检查视频录制索引；字幕和录音历史已可查看。'), findsOneWidget);

      resumedVideoIndex.complete(const <SubtitleVideoRecordingEntry>[]);
      for (var attempt = 0; attempt < 50; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('正在检查视频录制索引；字幕和录音历史已可查看。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'session deletion waits for audio indexing and then removes its WAV',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-delete-audio-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      const sessionId = 'delete-session-audio-during-index';
      final session = _completedHistorySession(
        sessionId: sessionId,
        sourceText: 'session audio must not be orphaned',
      );
      final audioRecording = (await tester.runAsync(
        () => _createSyntheticAudioRecording(
          appDataDirectory: appDataDirectory,
          sessionId: sessionId,
        ),
      ))!;
      final wavFile = audioRecording.files.single.file;
      expect(await tester.runAsync(() => wavFile.exists()), isTrue);

      final delayedAudioIndex =
          Completer<List<SubtitleAudioIndexedRecording>>();
      final store = _MutableSubtitleSessionStore(sessions: [session]);
      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: store,
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, requestedSessionId) {
              expect(requestedSessionId, sessionId);
              return Future<Directory?>.value(audioRecording.directory.parent);
            },
            audioRecordingLoader: (_) => delayedAudioIndex.future,
            videoRecordingLoader: (_) async => const [],
          ),
        ),
      );

      final loadingRecordings = find.text('正在检查会话录音…');
      for (
        var attempt = 0;
        attempt < 50 && loadingRecordings.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(loadingRecordings, findsOneWidget);
      final disabledDelete = find.ancestor(
        of: find.byTooltip('正在检查录音，请稍后删除会话'),
        matching: find.byType(IconButton),
      );
      expect(disabledDelete, findsOneWidget);
      expect(tester.widget<IconButton>(disabledDelete).onPressed, isNull);
      expect(store.deletedSessionIds, isEmpty);

      delayedAudioIndex.complete([audioRecording]);
      for (
        var attempt = 0;
        attempt < 50 && loadingRecordings.evaluate().isNotEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(loadingRecordings, findsNothing);

      final deleteButton = find.ancestor(
        of: find.byTooltip('删除会话'),
        matching: find.byType(IconButton),
      );
      await tester.runAsync(() async {
        tester.widget<IconButton>(deleteButton).onPressed!.call();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('删除这次字幕会话？'), findsOneWidget);
      final confirmDelete = find.widgetWithText(FilledButton, '删除会话');
      await tester.runAsync(() async {
        tester.widget<FilledButton>(confirmDelete).onPressed!.call();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();

      expect(store.deletedSessionIds, [sessionId]);
      expect(await tester.runAsync(() => wavFile.exists()), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expired metadata generation cannot publish a stale review or clean storage',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-stale-review-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      const sessionId = 'stale-review-generation';
      final oldSession = _completedHistorySession(
        sessionId: sessionId,
        sourceText: 'old transcript snapshot',
      );
      final currentSession = _completedHistorySession(
        sessionId: sessionId,
        sourceText: 'current transcript snapshot',
      );
      final store = _MutableSubtitleSessionStore(sessions: [oldSession]);
      final delayedReviews = Completer<List<SubtitlePostSessionStoredReview>>();
      final reviewStore = _SequencedReviewStore(
        <Future<List<SubtitlePostSessionStoredReview>> Function()>[
          () => delayedReviews.future,
          () async => const <SubtitlePostSessionStoredReview>[],
        ],
      );
      final staleReview = _validStoredReviewFor(
        oldSession,
        summary: 'stale generated review must stay hidden',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: store,
            reviewStore: reviewStore,
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, _) async => null,
            audioRecordingLoader: (_) async => const [],
            videoRecordingLoader: (_) async => const [],
          ),
        ),
      );
      for (
        var attempt = 0;
        attempt < 50 && reviewStore.listReviewCalls < 1;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(reviewStore.listReviewCalls, 1);

      store.sessions[0] = currentSession;
      final refreshButtonFinder = find.ancestor(
        of: find.byTooltip('刷新历史'),
        matching: find.byType(IconButton),
      );
      final refreshButton = tester.widget<IconButton>(
        refreshButtonFinder.first,
      );
      // The toolbar reload remains available while background metadata is loading.
      // This refresh is how a newer history generation supersedes stale metadata.
      expect(refreshButton.onPressed, isNotNull);
      await tester.tap(find.byTooltip('刷新历史'));
      await tester.pump();
      delayedReviews.complete([staleReview]);
      for (
        var attempt = 0;
        attempt < 50 && reviewStore.listReviewCalls < 2;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(reviewStore.listReviewCalls, 2);
      expect(reviewStore.retainedSessionSets, hasLength(1));
      expect(reviewStore.retainedSessionSets.single, contains(sessionId));

      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      final sessionTile = find.byKey(
        const PageStorageKey<String>('subtitle-session-$sessionId'),
      );
      await tester.ensureVisible(sessionTile);
      await tester.tap(
        find.descendant(of: sessionTile, matching: find.text('视频')),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final refreshedTranscript = tester.widget<SelectableText>(
        find.byKey(
          const PageStorageKey<String>(
            'subtitle-history-source-segment-$sessionId',
          ),
        ),
      );
      expect(refreshedTranscript.data, contains('current transcript snapshot'));
      expect(
        find.text('stale generated review must stay hidden'),
        findsNothing,
      );
      expect(reviewStore.retainedSessionSets, hasLength(1));
      expect(reviewStore.retainedSessionSets.single, contains(sessionId));
      expect(reviewStore.deletedReviewIds, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('links a screen recording to its standalone audio history card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appDataDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp(
        'yixue-history-audio-video-link-test-',
      ),
    ))!;
    addTearDown(() => appDataDirectory.delete(recursive: true));
    const sessionId = 'audio-only-1b8a6b19-b11a-44f9-b4a7-ed7093b4186f';
    const recordingId = 'audio-video-link-recording';
    const fileName =
        'screen-20261022-100000-audio-only-1b8a6b19-b11a-44f9-b4a7-ed7093b4186f-1234-56789.partial.mp4';
    final audioRecording = SubtitleAudioIndexedRecording(
      sessionId: sessionId,
      recordingId: recordingId,
      status: SubtitleAudioIndexedRecordingStatus.completed,
      startedAtUtc: DateTime.utc(2026, 10, 22, 10),
      endedAtUtc: DateTime.utc(2026, 10, 22, 10, 1),
      directory: appDataDirectory,
      files: const <SubtitleAudioIndexedFile>[],
      emptyAudioSources: 1,
      droppedFrames: 0,
      discontinuities: 0,
      lossCountersKnown: true,
    );
    final videoRecording = SubtitleVideoRecordingEntry(
      fileName: fileName,
      file: File('${appDataDirectory.path}/$fileName'),
      modifiedAt: DateTime.utc(2026, 10, 22, 10, 1),
      sizeBytes: 128,
      duration: Duration.zero,
      isIncomplete: true,
      sessionId: sessionId,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleSessionHistoryPage(
          store: _ImmediateSubtitleSessionStore(),
          reviewStore: _ImmediateReviewStore(),
          appDataDirectory: appDataDirectory,
          audioRecordingLoader: (_) async => [audioRecording],
          videoRecordingLoader: (_) async => [videoRecording],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final audioCard = find.byKey(
      const PageStorageKey<String>('standalone-audio-$recordingId'),
    );
    expect(audioCard, findsOneWidget);
    await tester.tap(audioCard);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: audioCard, matching: find.text('本次会话录屏')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: audioCard, matching: find.text(fileName)),
      findsOneWidget,
    );
    expect(find.text(fileName), findsOneWidget);
    expect(
      find.descendant(of: audioCard, matching: find.text('无音频数据')),
      findsOneWidget,
    );
    expect(find.text('没有采集到音频数据，因此没有可播放 WAV。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large media history builds recordings in visible batches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appDataDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yixue-history-media-pages-'),
    ))!;
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final startedAt = DateTime.utc(2026, 10, 22, 10);
    final audioRecordings = List<SubtitleAudioIndexedRecording>.generate(
      40,
      (index) => SubtitleAudioIndexedRecording(
        sessionId: 'audio-session-$index',
        recordingId: 'audio-recording-$index',
        status: SubtitleAudioIndexedRecordingStatus.completed,
        startedAtUtc: startedAt.add(Duration(minutes: index)),
        endedAtUtc: startedAt.add(Duration(minutes: index + 1)),
        directory: appDataDirectory,
        files: const <SubtitleAudioIndexedFile>[],
        emptyAudioSources: 1,
        droppedFrames: 0,
        discontinuities: 0,
        lossCountersKnown: true,
      ),
    );
    final videoRecordings = List<SubtitleVideoRecordingEntry>.generate(
      40,
      (index) => SubtitleVideoRecordingEntry(
        fileName: 'history-video-$index.mp4',
        file: File('${appDataDirectory.path}/history-video-$index.mp4'),
        modifiedAt: startedAt.add(Duration(minutes: index)),
        sizeBytes: 1024,
        duration: const Duration(minutes: 1),
        isIncomplete: false,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleSessionHistoryPage(
          store: _ImmediateSubtitleSessionStore(),
          reviewStore: _ImmediateReviewStore(),
          appDataDirectory: appDataDirectory,
          audioRecordingLoader: (_) async => audioRecordings,
          videoRecordingLoader: (_) async => videoRecordings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('视频录制 · 显示 24 / 40 段'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('加载更多录屏'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('加载更多录屏'));
    await tester.pumpAndSettle();
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('视频录制 · 显示 40 / 40 段'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('仅录音 · 显示 24 / 40 条'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.text('加载更多录音'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('加载更多录音'));
    await tester.pumpAndSettle();
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('仅录音 · 显示 40 / 40 条'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('仅录音 · 显示 40 / 40 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rechecks the linked session after the incomplete-video confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp(
          'yixue-history-video-session-race-',
        ),
      ))!;
      const sessionId = '1b8a6b19-b11a-44f9-b4a7-ed7093b4186f';
      const fileName =
          'screen-20261022-100000-1b8a6b19-b11a-44f9-b4a7-ed7093b4186f-1234-56789.partial.mp4';
      final videoDirectory = Directory(
        '${appDataDirectory.path}${Platform.pathSeparator}'
        'simultaneous-interpretation${Platform.pathSeparator}video-recordings',
      );
      final partialFile = File(
        '${videoDirectory.path}${Platform.pathSeparator}$fileName',
      );
      await tester.runAsync(() async {
        await videoDirectory.create(recursive: true);
        await partialFile.writeAsBytes(List<int>.filled(128, 7), flush: true);
        await partialFile.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 3)),
        );
      });
      final store = _MutableSubtitleSessionStore(
        sessions: [
          _completedHistorySession(
            sessionId: sessionId,
            sourceText: 'completed before confirmation',
          ),
        ],
      );
      final recording = SubtitleVideoRecordingEntry(
        fileName: fileName,
        file: partialFile,
        modifiedAt: DateTime.now().subtract(const Duration(minutes: 3)),
        sizeBytes: 128,
        duration: Duration.zero,
        isIncomplete: true,
        canAttemptPlayback: true,
        sessionId: sessionId,
      );
      var deleteCalls = 0;
      addTearDown(() async {
        await tester.runAsync(() async {
          if (await appDataDirectory.exists()) {
            await appDataDirectory.delete(recursive: true);
          }
        });
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: store,
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, _) async => null,
            audioRecordingLoader: (_) async => const [],
            videoRecordingLoader: (_) async => [recording],
            incompleteVideoDeleterForTesting: (_, _) async {
              deleteCalls++;
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sessionCard = find.byKey(
        const PageStorageKey<String>('subtitle-session-$sessionId'),
      );
      await tester.ensureVisible(sessionCard);
      await tester.tap(sessionCard);
      await tester.pumpAndSettle();
      final recordingTile = find
          .ancestor(of: find.text(fileName), matching: find.byType(ListTile))
          .first;
      final processButton = find.descendant(
        of: recordingTile,
        matching: find.byIcon(Icons.delete_sweep_outlined),
      );
      await tester.tap(processButton);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('处理未完成录屏'), findsOneWidget);

      store.sessions
        ..clear()
        ..add(
          _completedHistorySession(
            sessionId: sessionId,
            sourceText: 'recording became active',
            status: SubtitleSessionHistoryStatus.capturing,
          ),
        );
      await tester.tap(find.text('确认删除并放弃恢复'));
      await tester.pumpAndSettle();

      expect(deleteCalls, 0);
      expect(partialFile.existsSync(), isTrue);
      expect(find.textContaining('仍在进行'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lets the user preserve a failed partial video or confirm local deletion',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp(
          'yixue-history-partial-video-disposition-',
        ),
      ))!;
      final videoDirectory = Directory(
        '${appDataDirectory.path}${Platform.pathSeparator}'
        'simultaneous-interpretation${Platform.pathSeparator}video-recordings',
      );
      const fileName =
          'screen-20261022-100000-1b8a6b19-b11a-44f9-b4a7-ed7093b4186f-1234-56789.partial.mp4';
      final partialFile = File(
        '${videoDirectory.path}${Platform.pathSeparator}$fileName',
      );
      final retainedBytes = List<int>.generate(128, (index) => index % 256);
      await tester.runAsync(() async {
        await videoDirectory.create(recursive: true);
        await partialFile.writeAsBytes(retainedBytes, flush: true);
        await partialFile.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 3)),
        );
      });
      final partialRecording = SubtitleVideoRecordingEntry(
        fileName: fileName,
        file: partialFile,
        modifiedAt: DateTime.now().subtract(const Duration(minutes: 3)),
        sizeBytes: retainedBytes.length,
        duration: Duration.zero,
        isIncomplete: true,
        sessionId: '1b8a6b19-b11a-44f9-b4a7-ed7093b4186f',
      );
      final deletionResult = Completer<bool>();
      final videoReloadCompleted = Completer<void>();
      var initialVideoSnapshot = true;
      addTearDown(() async {
        await tester.runAsync(() async {
          if (await appDataDirectory.exists()) {
            await appDataDirectory.delete(recursive: true);
          }
        });
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            audioRecordingLoader: (_) async =>
                <SubtitleAudioIndexedRecording>[],
            videoRecordingLoader: (directory) async {
              if (initialVideoSnapshot) {
                initialVideoSnapshot = false;
                return [partialRecording];
              }
              final recordings = await tester.runAsync(
                () => SubtitleVideoRecordingIndex.list(
                  appDataDirectory: directory,
                ),
              );
              if (!videoReloadCompleted.isCompleted) {
                videoReloadCompleted.complete();
              }
              return recordings ?? <SubtitleVideoRecordingEntry>[];
            },
            incompleteVideoDeleterForTesting: (directory, requestedName) async {
              final deleted = await tester.runAsync(
                () => SubtitleVideoRecordingIndex.deleteIncompleteRecording(
                  appDataDirectory: directory,
                  fileName: requestedName,
                ),
              );
              final result = deleted ?? false;
              if (!deletionResult.isCompleted) {
                deletionResult.complete(result);
              }
              return result;
            },
          ),
        ),
      );
      for (var attempt = 0; attempt < 6; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final processButton = find.byKey(
        const ValueKey<String>(
          'subtitle-history-process-incomplete-video-$fileName',
        ),
      );
      await tester.scrollUntilVisible(
        processButton,
        420,
        scrollable: find.byType(Scrollable).first,
      );
      expect(processButton, findsOneWidget);
      expect(find.textContaining('可保留原文件'), findsOneWidget);
      await tester.tap(processButton);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('处理未完成录屏'), findsNWidgets(2));
      expect(find.textContaining('译学暂不提供未完成 MP4 的修复操作'), findsOneWidget);
      expect(find.textContaining('删除后无法恢复这段录屏'), findsOneWidget);
      await tester.tap(find.text('保留原文件'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(partialFile.existsSync(), isTrue);
      expect(partialFile.readAsBytesSync(), retainedBytes);

      await tester.tap(processButton);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('确认删除并放弃恢复'));
      expect(await deletionResult.future, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      await videoReloadCompleted.future;
      await tester.pump();
      expect(partialFile.existsSync(), isFalse);
      expect(find.text(fileName), findsNothing);
      expect(tester.takeException(), isNull);
      expect(find.text('本机视频已删除。'), findsOneWidget);
    },
  );

  testWidgets(
    'history video card validates and opens the same file with a readable failure instead of a blank canvas',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-video-playback-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));

      const sessionId = 'd1f2c3a4-b5e6-47d8-9012-3456789abcde';
      const fileName = 'screen-20261024-120000-$sessionId-1234-56789.mp4';
      final videoDirectory = Directory(
        '${appDataDirectory.path}${Platform.pathSeparator}'
        'simultaneous-interpretation${Platform.pathSeparator}video-recordings',
      );
      await tester.runAsync(() async {
        await videoDirectory.create(recursive: true);
        await _writeSyntheticMp4(
          File('${videoDirectory.path}${Platform.pathSeparator}$fileName'),
        );
      });
      final indexedVideos = (await tester.runAsync(
        () => SubtitleVideoRecordingIndex.list(
          appDataDirectory: appDataDirectory,
        ),
      ))!;
      expect(indexedVideos, hasLength(1));
      expect(indexedVideos.single.isIncomplete, isFalse);
      expect(indexedVideos.single.sessionId, sessionId);
      final expectedFile = File(
        '${videoDirectory.path}${Platform.pathSeparator}$fileName',
      );
      final revalidatedFile = await tester.runAsync(
        () => SubtitleVideoRecordingIndex.resolvePlayableRecording(
          appDataDirectory: appDataDirectory,
          fileName: fileName,
        ),
      );
      expect(revalidatedFile?.absolute.path, expectedFile.absolute.path);

      final session = _completedHistorySession(
        sessionId: sessionId,
        sourceText: 'synthetic video history',
      );
      final controller = _HistoryFakePlaybackController(
        isVideo: true,
        failureOnOpen: '合成视频解码失败',
      );
      var playbackFactoryCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(sessions: [session]),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, _) async => null,
            audioRecordingLoader: (_) async => const [],
            videoRecordingLoader: (_) async => indexedVideos,
            videoPlayableRecordingResolverForTesting: (_, _) async =>
                expectedFile,
            recordingPlaybackControllerFactoryForTesting: (_) {
              playbackFactoryCalls += 1;
              return controller;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();

      final sessionTile = find.byKey(
        const PageStorageKey<String>('subtitle-session-$sessionId'),
      );
      await tester.ensureVisible(sessionTile);
      await tester.tap(
        find.descendant(of: sessionTile, matching: find.text('视频')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('场景类型：视频。'), findsOneWidget);
      final openVideo = find.byTooltip('播放本次录屏');
      for (
        var attempt = 0;
        attempt < 50 && find.text('本次会话录屏').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('本次会话录屏'), findsOneWidget);
      expect(openVideo, findsOneWidget);
      final playVideoIcon = find.descendant(
        of: sessionTile,
        matching: find.byIcon(Icons.play_circle_outline_rounded),
      );
      expect(playVideoIcon, findsOneWidget);
      final playVideoButton = find.ancestor(
        of: playVideoIcon,
        matching: find.byType(IconButton),
      );
      expect(
        tester.widget<IconButton>(playVideoButton.first).onPressed,
        isNotNull,
      );
      await tester.ensureVisible(playVideoButton.first);
      await tester.pump();
      expect(
        tester.widget<IconButton>(playVideoButton.first).onPressed,
        isNotNull,
        reason:
            'playback became busy before the video click: '
            'key=${SubtitleMediaPlaybackCoordinator.instance.activeKey}, '
            'mutation=${SubtitleMediaPlaybackCoordinator.instance.activeMutationKey}, '
            'rect=${tester.getRect(playVideoButton.first)}',
      );
      final playVideoRect = tester.getRect(playVideoButton.first);
      expect(playVideoRect.top, lessThan(tester.view.physicalSize.height));
      await tester.runAsync(() async {
        tester.widget<IconButton>(playVideoButton.first).onPressed!.call();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump(const Duration(milliseconds: 50));
      for (
        var attempt = 0;
        attempt < 50 && find.byType(Dialog).evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(Dialog), findsOneWidget);
      expect(playbackFactoryCalls, 1);
      expect(controller.openedFile?.absolute.path, expectedFile.absolute.path);
      expect(controller.isVideo, isTrue);
      expect(find.textContaining('合成视频解码失败'), findsOneWidget);
      expect(find.byKey(const Key('history-fake-video-surface')), findsNothing);
      final videoDialogSurface = find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Material && widget.type == MaterialType.card,
            ),
          )
          .first;
      expect(videoDialogSurface, findsOneWidget);
      expect(tester.getSize(videoDialogSurface).height, lessThanOrEqualTo(720));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭播放器'));
      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  testWidgets(
    'system-player handoff waits for history lease release and reports launch failure',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-handoff-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));

      const sessionId = 'a1b2c3d4-e5f6-47a8-9012-3456789abcde';
      const fileName = 'screen-20261025-120000-$sessionId-1234-56789.mp4';
      final videoFile = File('${appDataDirectory.path}/$fileName');
      final recording = SubtitleVideoRecordingEntry(
        fileName: fileName,
        file: videoFile,
        modifiedAt: DateTime.utc(2026, 10, 25, 12),
        sizeBytes: 128,
        duration: const Duration(seconds: 2),
        isIncomplete: false,
        sessionId: sessionId,
      );
      final controller = _HistoryFakePlaybackController(
        isVideo: true,
        waitForFirstFrame: true,
        waitForClose: true,
      );
      var launcherSawBusyLease = true;
      File? launchedFile;

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            audioRecordingLoader: (_) async => const [],
            videoRecordingLoader: (_) async => [recording],
            videoPlayableRecordingResolverForTesting: (_, _) async => videoFile,
            recordingPlaybackControllerFactoryForTesting: (_) => controller,
            recordingSystemPlayerLauncherForTesting: (file) async {
              launcherSawBusyLease =
                  SubtitleMediaPlaybackCoordinator.instance.isBusy;
              launchedFile = file;
              throw StateError('默认播放器不可用');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('播放 / 打开视频'));
      // Keep the controller's first-frame wait active. The loading indicator
      // continuously schedules frames, so pumpAndSettle cannot settle here.
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('正在等待视频画面…'), findsOneWidget);
      expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isTrue);

      final systemPlayerButton = find.byKey(
        const ValueKey('open-recording-in-system-player'),
      );
      await tester.ensureVisible(systemPlayerButton);
      await tester.tap(systemPlayerButton);
      await tester.pump();

      expect(controller.closeCalls, 1);
      expect(launchedFile, isNull);
      expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isTrue);
      expect(find.byType(Dialog), findsOneWidget);

      controller.finishClose();
      await tester.pumpAndSettle();

      expect(controller.disposeCalls, 1);
      expect(launchedFile?.path, videoFile.path);
      expect(launcherSawBusyLease, isFalse);
      expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isFalse);
      expect(find.byType(Dialog), findsNothing);
      expect(find.textContaining('系统播放器启动失败'), findsOneWidget);
      expect(find.textContaining('默认播放器不可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history recovers interrupted standalone audio, plays a copy, and preserves the source',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-audio-recovery-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      const sessionId = 'history-recover-standalone-audio';
      final fixture = (await tester.runAsync(
        () => _createInterruptedHistoryAudioFixture(
          appDataDirectory: appDataDirectory,
          sessionId: sessionId,
        ),
      ))!;
      final originalBytes = await tester.runAsync(fixture.rawFile.readAsBytes);
      final initialIndex = await tester.runAsync(
        () => SubtitleAudioSessionRecorder.listSavedRecordingsWithStatus(
          appDataDirectory: appDataDirectory,
        ),
      );
      expect(initialIndex!.recordings, hasLength(1));
      expect(initialIndex.recordings.single.recoveryCandidates, hasLength(1));
      final controller = _HistoryFakePlaybackController(isVideo: false);
      var playbackFactoryCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            videoRecordingLoader: (_) async => const [],
            recordingPlaybackControllerFactoryForTesting: (_) {
              playbackFactoryCalls++;
              return controller;
            },
          ),
        ),
      );
      for (
        var attempt = 0;
        attempt < 50 && find.text('仅录音 · 显示 1 / 1 条').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('仅录音 · 显示 1 / 1 条'), findsOneWidget);
      final card = find.byKey(
        const PageStorageKey<String>(
          'standalone-audio-0123456789abcdef0123456789abcdef',
        ),
      );
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 300));

      final recoverButton = find.widgetWithText(TextButton, '恢复');
      expect(recoverButton, findsOneWidget);
      await tester.ensureVisible(recoverButton);
      final recoveryAction = tester.widget<TextButton>(recoverButton);
      expect(recoveryAction.onPressed, isNotNull);
      expect(
        tester.getRect(recoverButton).bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height),
      );
      await tester.runAsync(() async {
        recoveryAction.onPressed!.call();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('恢复未完成录音'), findsOneWidget);
      expect(find.text('16000 Hz'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '创建恢复副本'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      for (
        var attempt = 0;
        attempt < 50 && find.byTooltip('关闭播放器').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(find.byTooltip('关闭播放器'), findsOneWidget);
      expect(playbackFactoryCalls, 1);
      expect(controller.openedFile, isNotNull);
      expect(controller.openedFile!.path, isNot(fixture.rawFile.path));
      expect(await tester.runAsync(controller.openedFile!.exists), isTrue);
      expect(await tester.runAsync(fixture.rawFile.readAsBytes), originalBytes);
      expect(
        await tester.runAsync(
          () => SubtitleAudioSessionRecorder.listSavedRecordings(
            appDataDirectory: appDataDirectory,
          ),
        ),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('关闭播放器'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isFalse);
    },
  );

  testWidgets(
    'history audio card validates and opens the same WAV path with a readable failure',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-audio-playback-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      const sessionId = 'e1f2c3a4-b5e6-47d8-9012-3456789abcde';
      final indexedRecording = (await tester.runAsync(
        () => _createSyntheticAudioRecording(
          appDataDirectory: appDataDirectory,
          sessionId: sessionId,
        ),
      ))!;
      final expectedFile = indexedRecording.files.single.file;
      expect(indexedRecording.sessionId, sessionId);
      final sessionAudioDirectory = indexedRecording.directory.parent;
      expect(await tester.runAsync(sessionAudioDirectory.exists), isTrue);
      final session = _completedHistorySession(
        sessionId: sessionId,
        sourceText: 'synthetic audio history',
      );
      final controller = _HistoryFakePlaybackController(
        isVideo: false,
        failureOnOpen: '合成录音解码失败',
      );
      var audioResolverCalls = 0;
      var playbackFactoryCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(sessions: [session]),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, _) async =>
                sessionAudioDirectory,
            audioRecordingLoader: (_) async => [indexedRecording],
            videoRecordingLoader: (_) async => const [],
            audioRecordingResolverForTesting: (_, _) async {
              audioResolverCalls += 1;
              return indexedRecording;
            },
            recordingPlaybackControllerFactoryForTesting: (_) {
              playbackFactoryCalls += 1;
              return controller;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();

      final sessionTile = find.byKey(
        const PageStorageKey<String>('subtitle-session-$sessionId'),
      );
      await tester.ensureVisible(sessionTile);
      await tester.tap(
        find.descendant(
          of: sessionTile,
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final openAudio = find.text('播放系统播放声音');
      for (
        var attempt = 0;
        attempt < 50 && openAudio.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('采集音频'), findsOneWidget);
      expect(find.text('这次会话没有找到保存的录音；字幕仍可查看和导出。'), findsNothing);
      expect(openAudio, findsOneWidget);
      final playAudioIcon = find.descendant(
        of: sessionTile,
        matching: find.byIcon(Icons.play_circle_outline_rounded),
      );
      final playAudioTile = find.ancestor(
        of: playAudioIcon,
        matching: find.byType(ListTile),
      );
      await tester.ensureVisible(playAudioTile.first);
      await tester.pumpAndSettle();
      final playAudioRect = tester.getRect(playAudioTile.first);
      expect(playAudioRect.top, lessThan(tester.view.physicalSize.height));
      final audioTileWidget = tester.widget<ListTile>(playAudioTile.first);
      expect(audioTileWidget.onTap, isNotNull);
      expect(
        SubtitleMediaPlaybackCoordinator.instance.isBusy,
        isFalse,
        reason:
            'unexpected playback lease before audio open: '
            '${SubtitleMediaPlaybackCoordinator.instance.activeKey}',
      );
      await tester.runAsync(() async {
        audioTileWidget.onTap!.call();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump(const Duration(milliseconds: 50));
      for (
        var attempt = 0;
        attempt < 50 && find.byType(Dialog).evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        audioResolverCalls,
        greaterThan(0),
        reason:
            'audio tile=$playAudioRect; session=${tester.getRect(sessionTile)}',
      );
      expect(playbackFactoryCalls, 1);
      expect(controller.openedFile?.absolute.path, expectedFile.absolute.path);
      expect(controller.isVideo, isFalse);
      expect(find.textContaining('合成录音解码失败'), findsOneWidget);
      expect(find.byKey(const Key('history-fake-video-surface')), findsNothing);
      final audioDialogSurface = find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Material && widget.type == MaterialType.card,
            ),
          )
          .first;
      expect(audioDialogSurface, findsOneWidget);
      expect(tester.getSize(audioDialogSurface).height, lessThanOrEqualTo(720));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭播放器'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
    },
  );

  testWidgets(
    'WAV system-player handoff waits for native close and lease release before reporting launch failure',
    (tester) async {
      tester.view
        ..physicalSize = const Size(1000, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yixue-history-wav-handoff-'),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));

      const sessionId = 'b2c3d4e5-f6a7-4890-1234-56789abcdef0';
      final indexedRecording = (await tester.runAsync(
        () => _createSyntheticAudioRecording(
          appDataDirectory: appDataDirectory,
          sessionId: sessionId,
        ),
      ))!;
      final expectedFile = indexedRecording.files.single.file;
      final sessionAudioDirectory = indexedRecording.directory.parent;
      expect(await tester.runAsync(sessionAudioDirectory.exists), isTrue);

      final controller = _HistoryFakePlaybackController(
        isVideo: false,
        waitForClose: true,
      );
      addTearDown(() async {
        controller.finishClose();
        // Unmount even when an earlier assertion failed before the test could
        // tap the dialog's close or system-player handoff action. Disposing the
        // route starts the same asynchronous controller shutdown as the UI.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 500));
        final released = await tester.runAsync(() async {
          final timeout = DateTime.now().add(const Duration(seconds: 2));
          while (SubtitleMediaPlaybackCoordinator.instance.isBusy &&
              DateTime.now().isBefore(timeout)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          return !SubtitleMediaPlaybackCoordinator.instance.isBusy;
        });
        expect(
          released,
          isTrue,
          reason: 'WAV playback teardown must release the global media lease',
        );
      });
      var launchCalls = 0;
      var launcherSawBusyLease = true;
      File? launchedFile;
      final session = _completedHistorySession(
        sessionId: sessionId,
        sourceText: 'synthetic WAV handoff history',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(sessions: [session]),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            sessionAudioDirectoryResolverForTesting: (_, _) async =>
                sessionAudioDirectory,
            audioRecordingLoader: (_) async => [indexedRecording],
            videoRecordingLoader: (_) async => const [],
            audioRecordingResolverForTesting: (_, _) async => indexedRecording,
            recordingPlaybackControllerFactoryForTesting: (_) => controller,
            recordingSystemPlayerLauncherForTesting: (file) async {
              launchCalls++;
              launcherSawBusyLease =
                  SubtitleMediaPlaybackCoordinator.instance.isBusy;
              launchedFile = file;
              throw StateError('WAV 系统播放器测试失败');
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();

      final sessionTile = find.byKey(
        const PageStorageKey<String>('subtitle-session-$sessionId'),
      );
      await tester.ensureVisible(sessionTile);
      await tester.tap(
        find.descendant(
          of: sessionTile,
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final openAudio = find.text('播放系统播放声音');
      for (
        var attempt = 0;
        attempt < 50 && openAudio.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(openAudio, findsOneWidget);

      final playAudioIcon = find.descendant(
        of: sessionTile,
        matching: find.byIcon(Icons.play_circle_outline_rounded),
      );
      final playAudioTile = find.ancestor(
        of: playAudioIcon,
        matching: find.byType(ListTile),
      );
      await tester.ensureVisible(playAudioTile.first);
      await tester.pumpAndSettle();
      final audioTile = tester.widget<ListTile>(playAudioTile.first);
      expect(audioTile.onTap, isNotNull);
      await tester.runAsync(() async {
        audioTile.onTap!.call();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump(const Duration(milliseconds: 100));
      for (
        var attempt = 0;
        attempt < 50 && find.byType(Dialog).evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(controller.openedFile?.absolute.path, expectedFile.absolute.path);
      expect(controller.isVideo, isFalse);
      expect(find.byType(Dialog), findsOneWidget);
      expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isTrue);
      await tester.tap(
        find.byKey(const ValueKey('open-recording-in-system-player')),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.closeCalls, 1);
      expect(controller.disposeCalls, 0);
      expect(launchCalls, 0);
      expect(launchedFile, isNull);
      expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isTrue);
      expect(find.byType(Dialog), findsOneWidget);

      controller.finishClose();
      bool handoffSettled() =>
          find.byType(Dialog).evaluate().isEmpty &&
          launchCalls == 1 &&
          !SubtitleMediaPlaybackCoordinator.instance.isBusy;
      for (var attempt = 0; attempt < 50 && !handoffSettled(); attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(
        handoffSettled(),
        isTrue,
        reason: 'WAV handoff must close the dialog, release its lease, and launch once',
      );
      // Advance the SnackBar entrance without requiring unrelated page
      // animations to stop scheduling frames.
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.closeCalls, 1);
      expect(controller.disposeCalls, 1);
      expect(launchCalls, 1);
      expect(launchedFile?.absolute.path, expectedFile.absolute.path);
      expect(launcherSawBusyLease, isFalse);
      expect(SubtitleMediaPlaybackCoordinator.instance.isBusy, isFalse);
      expect(find.byType(Dialog), findsNothing);
      expect(find.textContaining('系统播放器启动失败'), findsOneWidget);
      expect(find.textContaining('WAV 系统播放器测试失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large transcript history reveals subtitle cues in bounded batches',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final session = _largeCompletedSession(segmentCount: 100);
      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(sessions: [session]),
            reviewStore: _ImmediateReviewStore(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final sessionTile = find.byKey(
        const PageStorageKey<String>('subtitle-session-history-large'),
      );
      final tile = sessionTile;
      await tester.ensureVisible(tile);
      final sessionTitle = find.descendant(of: tile, matching: find.text('视频'));
      final expansionController = ExpansibleController.of(
        tester.element(sessionTitle),
      );
      expect(expansionController.isExpanded, isFalse);
      await tester.tapAt(tester.getCenter(sessionTitle));
      await tester.pump(const Duration(milliseconds: 300));
      expect(expansionController.isExpanded, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      final historyScroll = find.byType(Scrollbar).first;
      final historyPosition = tester
          .widget<Scrollbar>(historyScroll)
          .controller!
          .position;
      expect(find.textContaining('history-cue-000'), findsOneWidget);
      expect(find.text('继续加载字幕'), findsOneWidget);
      expect(
        historyPosition.maxScrollExtent,
        greaterThan(0),
        reason:
            'viewport=${historyPosition.viewportDimension}, '
            'pixels=${historyPosition.pixels}, '
            'list=${tester.getSize(find.byType(ListView).first)}, '
            'session=${tester.getRect(sessionTile)}, '
            'cue=${tester.getRect(find.textContaining('history-cue-000'))}, '
            'loadMore=${tester.getRect(find.text('继续加载字幕'))}',
      );

      final firstCue = find.textContaining('history-cue-000');
      await tester.ensureVisible(firstCue);
      await tester.pump();
      expect(
        tester.getRect(firstCue).overlaps(tester.getRect(historyScroll)),
        isTrue,
        reason:
            'cue=${tester.getRect(firstCue)}; '
            'viewport=${tester.getRect(historyScroll)}; '
            'session=${tester.getRect(sessionTile)}; '
            'loadMore=${tester.getRect(find.text('继续加载字幕'))}; '
            'pixels=${historyPosition.pixels}; '
            'max=${historyPosition.maxScrollExtent}',
      );
      expect(find.textContaining('history-cue-099'), findsNothing);
      expect(find.text('继续加载字幕'), findsOneWidget);

      final offsetBeforeWheel = historyPosition.pixels;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(990, 500),
          scrollDelta: const Offset(0, 300),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(historyPosition.pixels, greaterThan(offsetBeforeWheel));

      await tester.ensureVisible(find.text('继续加载字幕'));
      await tester.pump();
      expect(
        tester.getCenter(find.text('继续加载字幕')).dy,
        lessThan(tester.view.physicalSize.height),
      );
      await tester.tap(find.text('继续加载字幕'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('history-cue-040'), findsOneWidget);
      expect(find.text('继续加载字幕'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(sessionTile, findsOneWidget);
    },
  );

  testWidgets(
    'explains when a video session has no associated recording file',
    (tester) async {
      final appDataDirectory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp(
          'yixue-history-missing-session-video-',
        ),
      ))!;
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final session = _completedHistorySession(
        sessionId: 'missing-session-video',
        sourceText: 'sample subtitle',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: _ImmediateSubtitleSessionStore(sessions: [session]),
            reviewStore: _ImmediateReviewStore(),
            appDataDirectory: appDataDirectory,
            audioRecordingLoader: (_) async => const [],
            sessionAudioDirectoryResolverForTesting: (_, _) async => null,
            videoRecordingLoader: (_) async => const [],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final sessionCard = find.byKey(
        const PageStorageKey<String>('subtitle-session-missing-session-video'),
      );
      await tester.ensureVisible(sessionCard);
      await tester.tap(sessionCard);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('没有找到与本次会话关联的录屏。可能未开启录制，或文件已被移动或删除。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'subtitle history can select matching sessions beyond the visible page',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = _MutableSubtitleSessionStore(
        sessions: <SubtitleSessionRecord>[
          ...List<SubtitleSessionRecord>.generate(
            41,
            (index) => _completedHistorySession(
              sessionId: 'bulk-match-$index',
              sourceText: 'matching lecture $index',
            ),
          ),
          _completedHistorySession(
            sessionId: 'bulk-other',
            sourceText: 'unrelated lecture',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleSessionHistoryPage(
            store: store,
            reviewStore: _ImmediateReviewStore(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.enterText(find.byType(TextField).first, 'matching');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('全选筛选结果'), findsOneWidget);
      expect(find.text('显示 40 / 41 个字幕会话'), findsOneWidget);
      final selectAll = find.byKey(
        const ValueKey('subtitle-history-select-all'),
      );
      await tester.ensureVisible(selectAll);
      expect(tester.widget<OutlinedButton>(selectAll).onPressed, isNotNull);
      await tester.tap(selectAll);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('41 条已选'), findsOneWidget);
      expect(find.text('清空已选'), findsOneWidget);

      await tester.tap(selectAll);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('41 条已选'), findsNothing);

      await tester.tap(selectAll);
      await tester.pump(const Duration(milliseconds: 100));
      final deleteSelected = find.byKey(
        const ValueKey('subtitle-history-delete-selected'),
      );
      await tester.ensureVisible(deleteSelected);
      await tester.tap(deleteSelected);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('删除选中的 41 条字幕会话？'), findsOneWidget);
      await tester.tap(find.text('确认删除'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        store.deletedSessionIds,
        List<String>.generate(41, (index) => 'bulk-match-$index'),
      );
      expect(store.sessions.map((session) => session.sessionId), <String>[
        'bulk-other',
      ]);
      expect(find.text('没有匹配的字幕会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

final class _FakeSubtitleWindow implements SubtitleWindowController {
  _FakeSubtitleWindow({required this.events, required this.hideAction});

  final List<String> events;
  final Future<void> Function() hideAction;
  bool _visible = true;

  @override
  bool get isVisible => _visible;

  @override
  Future<void> hide() async {
    events.add('hide-start');
    await hideAction();
    _visible = false;
    events.add('hide-end');
  }

  @override
  Future<void> show(SubtitleWindowSnapshot snapshot) async {
    _visible = true;
  }

  @override
  Future<void> update(SubtitleWindowSnapshot snapshot) async {}

  @override
  Future<void> dispose() async {
    _visible = false;
  }
}

final class _HistoryNavigationHost extends StatelessWidget {
  const _HistoryNavigationHost({
    required this.store,
    required this.reviewStore,
  });

  final SubtitleSessionStore store;
  final SubtitlePostSessionReviewStore reviewStore;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => SubtitleSessionHistoryPage(
              store: store,
              reviewStore: reviewStore,
            ),
          ),
        ),
        child: const Text('打开字幕历史'),
      ),
    ),
  );
}

final class _ImmediateSubtitleSessionStore implements SubtitleSessionStore {
  _ImmediateSubtitleSessionStore({
    this.sessions = const <SubtitleSessionRecord>[],
    this.listSessionsLoader,
  });

  final List<SubtitleSessionRecord> sessions;
  final Future<List<SubtitleSessionRecord>> Function()? listSessionsLoader;

  @override
  Future<void> createSession(SubtitleSessionRecord session) async {}

  @override
  Future<bool> deleteSession(String sessionId) async => false;

  @override
  Future<int> deleteSessionsBefore(DateTime cutoffUtc) async => 0;

  @override
  Future<int> recoverInterruptedSessions() async => 0;

  @override
  Future<SubtitleSessionRecord?> readSession(String sessionId) async {
    for (final session in sessions) {
      if (session.sessionId == sessionId) return session;
    }
    return null;
  }

  @override
  Future<List<SubtitleSessionRecord>> listSessions() async =>
      listSessionsLoader == null ? sessions : await listSessionsLoader!();

  @override
  Future<void> saveConfirmedSegment(
    String sessionId,
    SubtitleSegment segment, {
    String? translatedTargetLanguageCode,
  }) async {}

  @override
  Future<void> updateSessionStatus(
    String sessionId,
    SubtitleSessionHistoryStatus status, {
    DateTime? endedAtUtc,
  }) async {}
}

final class _MutableSubtitleSessionStore implements SubtitleSessionStore {
  _MutableSubtitleSessionStore({
    required Iterable<SubtitleSessionRecord> sessions,
  }) : sessions = List<SubtitleSessionRecord>.of(sessions);

  final List<SubtitleSessionRecord> sessions;
  final List<String> deletedSessionIds = <String>[];

  @override
  Future<void> createSession(SubtitleSessionRecord session) async {
    sessions.add(session);
  }

  @override
  Future<bool> deleteSession(String sessionId) async {
    final initialLength = sessions.length;
    sessions.removeWhere((session) => session.sessionId == sessionId);
    if (sessions.length == initialLength) return false;
    deletedSessionIds.add(sessionId);
    return true;
  }

  @override
  Future<int> deleteSessionsBefore(DateTime cutoffUtc) async => 0;

  @override
  Future<int> recoverInterruptedSessions() async => 0;

  @override
  Future<SubtitleSessionRecord?> readSession(String sessionId) async {
    for (final session in sessions) {
      if (session.sessionId == sessionId) return session;
    }
    return null;
  }

  @override
  Future<List<SubtitleSessionRecord>> listSessions() async =>
      List<SubtitleSessionRecord>.unmodifiable(sessions);

  @override
  Future<void> saveConfirmedSegment(
    String sessionId,
    SubtitleSegment segment, {
    String? translatedTargetLanguageCode,
  }) async {}

  @override
  Future<void> updateSessionStatus(
    String sessionId,
    SubtitleSessionHistoryStatus status, {
    DateTime? endedAtUtc,
  }) async {}
}

SubtitleSessionRecord _completedHistorySession({
  required String sessionId,
  required String sourceText,
  SubtitleSessionHistoryStatus status = SubtitleSessionHistoryStatus.completed,
}) {
  final startedAt = DateTime.utc(2026, 10, 18, 12);
  final segment = SubtitleSegment.fromStoredFinalTranscript(
    TranscriptRevision(
      sessionId: sessionId,
      captureAttemptId: 'attempt-$sessionId',
      segmentId: 'segment-$sessionId',
      sourceId: 'system-output-1',
      sourceKind: SubtitleAudioSourceKind.systemOutput,
      startMs: 0,
      endMs: 800,
      text: sourceText,
      languageCode: 'en',
      revision: 1,
      isFinal: true,
    ),
    translatedText: '字幕 $sourceText',
    targetLanguageCode: 'zh',
  );
  return SubtitleSessionRecord(
    sessionId: sessionId,
    kind: SubtitleSessionKind.video,
    sourceKind: SubtitleAudioSourceKind.systemOutput,
    recognitionMode: SubtitleRecognitionMode.manual,
    targetLanguageCode: 'zh',
    startedAtUtc: startedAt,
    endedAtUtc: switch (status) {
      SubtitleSessionHistoryStatus.preparing ||
      SubtitleSessionHistoryStatus.capturing ||
      SubtitleSessionHistoryStatus.paused => null,
      SubtitleSessionHistoryStatus.completed ||
      SubtitleSessionHistoryStatus.interrupted ||
      SubtitleSessionHistoryStatus.failed => startedAt.add(
        const Duration(minutes: 2),
      ),
    },
    status: status,
    segments: [segment],
  );
}

SubtitlePostSessionStoredReview _validStoredReviewFor(
  SubtitleSessionRecord session, {
  required String summary,
}) {
  final segment = session.segments.single;
  final transcript = segment.transcript;
  final outputs = <SubtitlePostSessionOutputKind>{
    SubtitlePostSessionOutputKind.summary,
  };
  final request = SubtitlePostSessionRequest(
    sessionId: session.sessionId,
    sessionKind: session.kind,
    startedAtUtc: session.startedAtUtc,
    outputs: outputs,
    segments: <SubtitlePostSessionSourceSegment>[
      SubtitlePostSessionSourceSegment(
        captureAttemptId: transcript.captureAttemptId,
        segmentId: transcript.segmentId,
        sourceId: transcript.sourceId,
        sourceKind: transcript.sourceKind,
        startMs: transcript.startMs,
        endMs: transcript.endMs,
        sourceLanguageCode: transcript.languageCode,
        targetLanguageCode: session.targetLanguageCode,
        sourceText: transcript.text,
        translatedText: segment.translatedText,
      ),
    ],
  );
  final source = SubtitlePostSessionSourceRef(
    captureAttemptId: transcript.captureAttemptId,
    segmentId: transcript.segmentId,
    sourceId: transcript.sourceId,
    sourceKind: transcript.sourceKind,
    startMs: transcript.startMs,
    endMs: transcript.endMs,
  );
  final generatedAtUtc = DateTime.utc(2026, 10, 24, 12);
  final providerInfo = const SubtitlePostSessionProviderInfo(
    providerName: 'history test provider',
    kind: SubtitlePostSessionProviderKind.local,
  );
  final result = SubtitlePostSessionResult(
    generatedAtUtc: generatedAtUtc,
    summaryPoints: <SubtitlePostSessionInsight>[
      SubtitlePostSessionInsight(
        text: summary,
        sources: <SubtitlePostSessionSourceRef>[source],
      ),
    ],
    terms: const <SubtitlePostSessionTerm>[],
    actionItems: const <SubtitlePostSessionActionItem>[],
  );
  return SubtitlePostSessionStoredReview(
    sessionId: session.sessionId,
    inputDigest: subtitlePostSessionInputDigest(request),
    generatedAtUtc: generatedAtUtc,
    outputs: outputs,
    providerInfo: providerInfo,
    result: result,
  );
}

final class _HistoryFakePlaybackController extends RecordingPlaybackController {
  _HistoryFakePlaybackController({
    required this.isVideo,
    this.failureOnOpen,
    bool waitForFirstFrame = false,
    bool waitForClose = false,
  }) : _firstFrameGate = waitForFirstFrame ? Completer<void>() : null,
       _closeGate = waitForClose ? Completer<void>() : null;

  @override
  final bool isVideo;
  final String? failureOnOpen;
  final Completer<void>? _firstFrameGate;
  final Completer<void>? _closeGate;

  File? openedFile;
  var closeCalls = 0;
  var disposeCalls = 0;

  @override
  bool isLoading = true;
  @override
  bool isPlaying = false;
  @override
  Duration position = Duration.zero;
  @override
  final Duration duration = const Duration(seconds: 2);
  @override
  String? failureMessage;
  @override
  String? failureDetails;

  @override
  Widget buildVideoView() => const ColoredBox(
    key: Key('history-fake-video-surface'),
    color: Colors.grey,
  );

  @override
  Future<void> open(File file) async {
    openedFile = file;
    failureMessage = failureOnOpen;
    failureDetails = failureOnOpen == null ? null : '合成媒体的模拟播放失败';
    final firstFrameGate = _firstFrameGate;
    if (firstFrameGate != null) await firstFrameGate.future;
    isLoading = false;
    notifyListeners();
  }

  @override
  Future<void> togglePlayback() async {}

  @override
  Future<void> seek(Duration value) async {
    position = value;
    notifyListeners();
  }

  @override
  Future<void> close() async {
    closeCalls++;
    final firstFrameGate = _firstFrameGate;
    if (firstFrameGate != null && !firstFrameGate.isCompleted) {
      firstFrameGate.complete();
    }
    final closeGate = _closeGate;
    if (closeGate != null) await closeGate.future;
  }

  @override
  void dispose() {
    disposeCalls++;
    super.dispose();
  }

  void finishClose() {
    final gate = _closeGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

Future<({File rawFile, Uint8List originalBytes})>
_createInterruptedHistoryAudioFixture({
  required Directory appDataDirectory,
  required String sessionId,
}) async {
  const recordingId = '0123456789abcdef0123456789abcdef';
  const sourceId = 'windows-system-output';
  const sampleRateHz = 16000;
  const channelCount = 1;
  const dataBytes = 3200;
  final sessionDigest = sha256.convert(utf8.encode(sessionId)).toString();
  final sourceDigest = sha256.convert(utf8.encode(sourceId)).toString();
  final sessionDirectory = Directory(
    '${appDataDirectory.path}${Platform.pathSeparator}'
    'simultaneous-interpretation${Platform.pathSeparator}recordings${Platform.pathSeparator}'
    '$sessionDigest',
  );
  final recordingDirectory = Directory(
    '${sessionDirectory.path}${Platform.pathSeparator}$recordingId',
  );
  await recordingDirectory.create(recursive: true);
  await File('${sessionDirectory.path}${Platform.pathSeparator}.session.lock')
      .create();
  final rawFile = File(
    '${recordingDirectory.path}${Platform.pathSeparator}'
    'systemOutput-$sourceDigest.wav',
  );
  final expectedRelativePath =
      'simultaneous-interpretation/recordings/$sessionDigest/$recordingId/'
      'systemOutput-$sourceDigest.wav';
  final originalBytes = Uint8List(44 + dataBytes);
  await rawFile.writeAsBytes(originalBytes, flush: true);
  await File('${recordingDirectory.path}${Platform.pathSeparator}manifest.json')
      .writeAsString(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'recordingId': recordingId,
          'sessionId': sessionId,
          'status': 'recording',
          'format': 'wav-pcm-s16le',
          'startedAtUtc': '2026-10-19T00:00:00.000Z',
          'endedAtUtc': null,
          'error': 'synthetic_interrupted_fixture',
          'sources': <Object?>[
            <String, Object?>{
              'sourceId': sourceId,
              'sourceKind': 'systemOutput',
              'relativePath': expectedRelativePath,
              'container': 'wav',
              'codec': 'pcm_s16le',
              'sampleRateHz': sampleRateHz,
              'channelCount': channelCount,
              'channelMask': null,
              'bitsPerSample': 16,
              'dataBytes': dataBytes,
              'samplesPerChannel': dataBytes ~/ (channelCount * 2),
              'framesWritten': 1,
              'droppedFrames': 0,
              'discontinuities': 0,
              'firstSequence': 0,
              'lastSequence': 0,
              'startedAtUtc': '2026-10-19T00:00:00.000Z',
              'endedAtUtc': null,
              'error': 'synthetic_interrupted_fixture',
            },
          ],
        }),
        flush: true,
      );
  return (rawFile: rawFile, originalBytes: originalBytes);
}

Future<SubtitleAudioIndexedRecording> _createSyntheticAudioRecording({
  required Directory appDataDirectory,
  required String sessionId,
}) async {
  final recorder = SubtitleAudioSessionRecorder(
    appDataDirectory: appDataDirectory,
  );
  final frames = StreamController<AudioFrame>.broadcast();
  try {
    await recorder.start(
      sessionId: sessionId,
      captureAttemptId: 'history-playback-test-attempt',
      sources: <SubtitleSessionAudioSource>[
        SubtitleSessionAudioSource(
          sourceId: 'windows-system-output',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        ),
      ],
      frames: frames.stream,
    );
    final checkpointed = recorder.states.firstWhere(
      (state) => state.sources.any((source) => source.dataBytes == 3200),
    );
    frames.add(
      AudioFrame(
        sessionId: sessionId,
        captureAttemptId: 'history-playback-test-attempt',
        sourceId: 'windows-system-output',
        sourceKind: SubtitleAudioSourceKind.systemOutput,
        sequence: 0,
        startTimeUs: 0,
        sampleRateHz: 16000,
        channelCount: 1,
        sampleCount: 1600,
        sampleFormat: AudioPcmSampleFormat.signedInt16LittleEndian,
        pcmBytes: Uint8List(3200),
      ),
    );
    await checkpointed.timeout(const Duration(seconds: 5));
    await recorder.stop().timeout(const Duration(seconds: 5));
  } finally {
    await frames.close();
    await recorder.dispose();
  }

  final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
    appDataDirectory: appDataDirectory,
  );
  return recordings.singleWhere(
    (recording) => recording.sessionId == sessionId,
  );
}

Future<void> _writeSyntheticMp4(File file) async {
  const mvhdPayload = <int>[
    0, 0, 0, 0, // version and flags
    0, 0, 0, 0, // creation time
    0, 0, 0, 0, // modification time
    0, 0, 3, 232, // 1000 ticks per second
    0, 0, 3, 232, // 1000 ms duration
  ];
  final movieBeforeMdat = _historyMovieWithVideoSample(
    mvhdPayload: mvhdPayload,
    sampleOffset: 0,
  );
  final movie = _historyMovieWithVideoSample(
    mvhdPayload: mvhdPayload,
    sampleOffset: movieBeforeMdat.length + 8,
  );
  await file.writeAsBytes(<int>[
    ...movie,
    ..._historyMp4Box('mdat', const <int>[1, 2, 3, 4]),
  ], flush: true);
}

List<int> _historyMovieWithVideoSample({
  required List<int> mvhdPayload,
  required int sampleOffset,
}) => _historyMp4Box('moov', <int>[
  ..._historyMp4Box('mvhd', mvhdPayload),
  ..._historyMp4Box(
    'trak',
    _historyMp4Box('mdia', <int>[
      ..._historyHandlerBox('vide'),
      ..._historyMp4Box(
        'minf',
        _historyMp4Box('stbl', <int>[
          ..._historyMp4Box('stsd', <int>[
            0, 0, 0, 0, // version and flags
            0, 0, 0, 1, // one sample description
            ..._historyMp4Box('avc1', List<int>.filled(78, 0)),
          ]),
          ..._historyMp4Box('stsc', const <int>[
            0, 0, 0, 0, // version and flags
            0, 0, 0, 1, // one entry
            0, 0, 0, 1, // first chunk
            0, 0, 0, 1, // one sample per chunk
            0, 0, 0, 1, // sample description index
          ]),
          ..._historyMp4Box('stco', <int>[
            0, 0, 0, 0, // version and flags
            0, 0, 0, 1, // one chunk
            ..._historyUint32(sampleOffset),
          ]),
          ..._historyMp4Box('stsz', const <int>[
            0, 0, 0, 0, // version and flags
            0, 0, 0, 4, // fixed sample size
            0, 0, 0, 1, // one sample
          ]),
        ]),
      ),
    ]),
  ),
]);

List<int> _historyHandlerBox(String handlerType) =>
    _historyMp4Box('hdlr', <int>[
      0, 0, 0, 0, // version and flags
      0, 0, 0, 0, // pre-defined
      ...handlerType.codeUnits,
      ...List<int>.filled(12, 0), // reserved and name
    ]);

List<int> _historyMp4Box(String type, List<int> payload) => <int>[
  ..._historyUint32(payload.length + 8),
  ...type.codeUnits,
  ...payload,
];

List<int> _historyUint32(int value) => <int>[
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

SubtitleSessionRecord _largeCompletedSession({required int segmentCount}) {
  const sessionId = 'history-large';
  final startedAt = DateTime.utc(2026, 10, 18, 12);
  final segments = List<SubtitleSegment>.generate(segmentCount, (index) {
    final startMs = index * 1000;
    return SubtitleSegment.fromStoredFinalTranscript(
      TranscriptRevision(
        sessionId: sessionId,
        captureAttemptId: 'attempt-$index',
        segmentId: 'segment-$index',
        sourceId: 'system-output-1',
        sourceKind: SubtitleAudioSourceKind.systemOutput,
        startMs: startMs,
        endMs: startMs + 800,
        text: 'history-cue-${index.toString().padLeft(3, '0')}',
        languageCode: 'en',
        revision: 1,
        isFinal: true,
      ),
      translatedText: '历史字幕 $index',
      targetLanguageCode: 'zh',
    );
  });
  return SubtitleSessionRecord(
    sessionId: sessionId,
    kind: SubtitleSessionKind.video,
    sourceKind: SubtitleAudioSourceKind.systemOutput,
    recognitionMode: SubtitleRecognitionMode.manual,
    targetLanguageCode: 'zh',
    startedAtUtc: startedAt,
    endedAtUtc: startedAt.add(const Duration(minutes: 2)),
    status: SubtitleSessionHistoryStatus.completed,
    segments: segments,
  );
}

final class _ImmediateReviewStore implements SubtitlePostSessionReviewStore {
  @override
  Future<bool> deleteReview(String sessionId) async => false;

  @override
  Future<List<SubtitlePostSessionStoredReview>> listReviews() async => const [];

  @override
  Future<void> saveReview(SubtitlePostSessionStoredReview review) async {}

  @override
  Future<int> retainSessionIds(Set<String> sessionIds) async => 0;
}

final class _DeferredReviewStore implements SubtitlePostSessionReviewStore {
  const _DeferredReviewStore(this.reviews);

  final Future<List<SubtitlePostSessionStoredReview>> reviews;

  @override
  Future<bool> deleteReview(String sessionId) async => false;

  @override
  Future<List<SubtitlePostSessionStoredReview>> listReviews() => reviews;

  @override
  Future<int> retainSessionIds(Set<String> sessionIds) async => 0;

  @override
  Future<void> saveReview(SubtitlePostSessionStoredReview review) async {}
}

final class _SequencedReviewStore implements SubtitlePostSessionReviewStore {
  _SequencedReviewStore(this._responses);

  final List<Future<List<SubtitlePostSessionStoredReview>> Function()>
  _responses;
  final List<Set<String>> retainedSessionSets = <Set<String>>[];
  final List<String> deletedReviewIds = <String>[];
  var listReviewCalls = 0;

  @override
  Future<List<SubtitlePostSessionStoredReview>> listReviews() {
    final index = listReviewCalls++;
    if (index >= _responses.length) {
      return Future<List<SubtitlePostSessionStoredReview>>.error(
        StateError('Unexpected review-list read $index'),
      );
    }
    return _responses[index]();
  }

  @override
  Future<bool> deleteReview(String sessionId) async {
    deletedReviewIds.add(sessionId);
    return true;
  }

  @override
  Future<int> retainSessionIds(Set<String> sessionIds) async {
    retainedSessionSets.add(Set<String>.of(sessionIds));
    return 0;
  }

  @override
  Future<void> saveReview(SubtitlePostSessionStoredReview review) async {}
}
