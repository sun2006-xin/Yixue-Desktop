import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/recording_media_player_dialog.dart';

void main() {
  test('playback readiness requires two consecutive position advances', () {
    final progress = RecordingPlaybackProgressTracker();

    expect(progress.observe(Duration.zero), isFalse);
    expect(progress.observe(const Duration(milliseconds: 20)), isFalse);
    expect(progress.observe(const Duration(milliseconds: 40)), isTrue);
  });

  test('stalled or backward positions reset playback progress', () {
    final progress = RecordingPlaybackProgressTracker();

    expect(progress.observe(const Duration(milliseconds: 20)), isFalse);
    expect(progress.observe(const Duration(milliseconds: 20)), isFalse);
    expect(progress.observe(const Duration(milliseconds: 40)), isFalse);
    expect(progress.observe(const Duration(milliseconds: 30)), isFalse);
    expect(progress.observe(const Duration(milliseconds: 50)), isFalse);
    expect(progress.observe(const Duration(milliseconds: 70)), isTrue);
  });

  test(
    'waits for VideoController first-frame readiness after player open',
    () async {
      final playerOpen = Completer<void>();
      final firstFrameRendered = Completer<void>();
      final videoPlaybackProgress = Completer<void>();
      final playerFailure = Completer<void>();
      var ready = false;
      final readiness = waitForRecordingVideoReady(
        playerOpen: playerOpen.future,
        firstFrameRendered: firstFrameRendered.future,
        videoPlaybackProgress: videoPlaybackProgress.future,
        playerFailure: playerFailure.future,
        stopRequested: Completer<void>().future,
        shouldStop: () => false,
        openTimeout: const Duration(seconds: 2),
        firstFrameTimeout: const Duration(seconds: 2),
      ).then((_) => ready = true);

      playerOpen.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);

      firstFrameRendered.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
        ready,
        isFalse,
        reason: 'A resized texture is not playback progress.',
      );

      videoPlaybackProgress.complete();
      await readiness;
      expect(ready, isTrue);
    },
  );

  test(
    'stops waiting for first-frame readiness immediately when closed',
    () async {
      final stopRequested = Completer<void>();
      final firstFrameRendered = Completer<void>();
      final readiness = waitForRecordingVideoReady(
        playerOpen: Future<void>.value(),
        firstFrameRendered: firstFrameRendered.future,
        videoPlaybackProgress: Completer<void>().future,
        playerFailure: Completer<void>().future,
        stopRequested: stopRequested.future,
        shouldStop: () => stopRequested.isCompleted,
        openTimeout: const Duration(seconds: 1),
        firstFrameTimeout: const Duration(seconds: 30),
      );

      stopRequested.complete();
      await expectLater(readiness, completes);
      expect(firstFrameRendered.isCompleted, isFalse);
    },
  );

  test(
    'reports player-open and first-frame timeouts as separate stages',
    () async {
      final playerFailure = Completer<void>();
      await expectLater(
        waitForRecordingVideoReady(
          playerOpen: Completer<void>().future,
          firstFrameRendered: Completer<void>().future,
          videoPlaybackProgress: Completer<void>().future,
          playerFailure: playerFailure.future,
          stopRequested: Completer<void>().future,
          shouldStop: () => false,
          openTimeout: Duration.zero,
          firstFrameTimeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<RecordingPlaybackTimeout>().having(
            (error) => error.stage,
            'stage',
            RecordingPlaybackTimeoutStage.playerOpen,
          ),
        ),
      );

      await expectLater(
        waitForRecordingVideoReady(
          playerOpen: Future<void>.value(),
          firstFrameRendered: Completer<void>().future,
          videoPlaybackProgress: Completer<void>().future,
          playerFailure: playerFailure.future,
          stopRequested: Completer<void>().future,
          shouldStop: () => false,
          openTimeout: const Duration(seconds: 1),
          firstFrameTimeout: Duration.zero,
        ),
        throwsA(
          isA<RecordingPlaybackTimeout>().having(
            (error) => error.stage,
            'stage',
            RecordingPlaybackTimeoutStage.firstVideoFrame,
          ),
        ),
      );
    },
  );

  test('surfaces decoder failure while the first frame is pending', () async {
    final playerFailure = Completer<void>();
    final readiness = waitForRecordingVideoReady(
      playerOpen: Future<void>.value(),
      firstFrameRendered: Completer<void>().future,
      videoPlaybackProgress: Completer<void>().future,
      playerFailure: playerFailure.future,
      stopRequested: Completer<void>().future,
      shouldStop: () => false,
      openTimeout: const Duration(seconds: 1),
      firstFrameTimeout: const Duration(seconds: 30),
    );

    playerFailure.complete();
    await expectLater(readiness, throwsA(isA<FormatException>()));
  });

  test(
    'waits for audio metadata and playback before declaring a WAV ready',
    () async {
      final playerOpen = Completer<void>();
      final durationAvailable = Completer<void>();
      final audioPlaybackProgress = Completer<void>();
      final playerFailure = Completer<void>();
      var ready = false;
      final readiness = waitForRecordingAudioReady(
        playerOpen: playerOpen.future,
        audioDurationAvailable: durationAvailable.future,
        audioPlaybackProgress: audioPlaybackProgress.future,
        playerFailure: playerFailure.future,
        stopRequested: Completer<void>().future,
        shouldStop: () => false,
        openTimeout: const Duration(seconds: 2),
        durationTimeout: const Duration(seconds: 2),
      ).then((_) => ready = true);

      playerOpen.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      durationAvailable.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse, reason: 'Track metadata alone is not playback.');
      audioPlaybackProgress.complete();
      await readiness;
      expect(ready, isTrue);
    },
  );

  test(
    'reports audio readiness timeout when playback never advances',
    () async {
      await expectLater(
        waitForRecordingAudioReady(
          playerOpen: Future<void>.value(),
          audioDurationAvailable: Future<void>.value(),
          audioPlaybackProgress: Completer<void>().future,
          playerFailure: Completer<void>().future,
          stopRequested: Completer<void>().future,
          shouldStop: () => false,
          openTimeout: const Duration(seconds: 1),
          durationTimeout: Duration.zero,
        ),
        throwsA(
          isA<RecordingPlaybackTimeout>().having(
            (error) => error.stage,
            'stage',
            RecordingPlaybackTimeoutStage.audioPlayback,
          ),
        ),
      );
    },
  );

  testWidgets('shows an in-app video surface and seek controls', (
    tester,
  ) async {
    final videoFile = File('fixture.mp4');
    final controller = _FakeRecordingPlaybackController(isVideo: true);

    await _openDialog(tester, file: videoFile, controller: controller);

    expect(controller.openedFile?.path, videoFile.path);
    expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);
    expect(find.byTooltip('向后 10 秒'), findsOneWidget);
    expect(find.byTooltip('播放'), findsOneWidget);
    expect(find.byTooltip('向前 10 秒'), findsOneWidget);
  });

  testWidgets('keeps the in-app media dialog compact on desktop', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = _FakeRecordingPlaybackController(isVideo: true);
    await _openDialog(
      tester,
      file: File('history.mp4'),
      controller: controller,
    );

    final contentSurface = find.descendant(
      of: find.byType(Dialog),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ConstrainedBox && widget.constraints.maxHeight == 720,
      ),
    );
    expect(contentSurface, findsOneWidget);
    expect(tester.getSize(contentSurface).height, lessThanOrEqualTo(720));
    expect(find.byTooltip('播放'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fits a history video to its recorded aspect ratio and viewport',
    (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _FakeRecordingPlaybackController(
        isVideo: true,
        videoAspectRatio: 4 / 3,
      );
      await _openDialog(
        tester,
        file: File('four-three-history.mp4'),
        controller: controller,
      );

      final videoViewport = find.byKey(
        const ValueKey('recording-video-viewport'),
      );
      expect(videoViewport, findsOneWidget);
      final viewportSize = tester.getSize(videoViewport);
      expect(viewportSize.height, lessThanOrEqualTo(450));
      expect(viewportSize.width / viewportSize.height, closeTo(4 / 3, 0.02));
      expect(find.byTooltip('播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keeps short video dialogs scrollable and exposes the system-player handoff',
    (tester) async {
      tester.view
        ..physicalSize = const Size(360, 300)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _FakeRecordingPlaybackController(isVideo: true);
      Future<void>? disposedPlayer;
      var handoffRequested = false;
      final recordingFile = File('short-viewport-history.mp4');
      await _openDialog(
        tester,
        file: recordingFile,
        controller: controller,
        onDialogDisposed: (close) => disposedPlayer = close,
        onSystemPlayerHandoffRequested: () => handoffRequested = true,
        externalPlayerLauncher: (_) async {
          fail(
            'History playback should close before handing off to the caller.',
          );
        },
      );

      final dialog = find.byType(Dialog);
      final scrollable = find.descendant(
        of: dialog,
        matching: find.byType(Scrollable),
      );
      expect(dialog, findsOneWidget);
      expect(scrollable, findsOneWidget);
      final scrollPosition = tester.state<ScrollableState>(scrollable).position;
      expect(scrollPosition.maxScrollExtent, greaterThan(0));
      final initialScrollOffset = scrollPosition.pixels;
      await tester.drag(scrollable, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(scrollPosition.pixels, greaterThan(initialScrollOffset));
      final systemPlayerButton = find.byKey(
        const ValueKey('open-recording-in-system-player'),
      );
      expect(systemPlayerButton, findsOneWidget);
      await tester.ensureVisible(systemPlayerButton);
      final viewportRect = tester.getRect(scrollable);
      final buttonRect = tester.getRect(systemPlayerButton);
      expect(buttonRect.top, greaterThanOrEqualTo(viewportRect.top));
      expect(buttonRect.bottom, lessThanOrEqualTo(viewportRect.bottom));
      expect(tester.takeException(), isNull);

      await tester.tap(systemPlayerButton);
      await tester.pumpAndSettle();
      await disposedPlayer;
      expect(handoffRequested, isTrue);
      expect(controller.closed, isTrue);
      expect(controller.disposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offers explicit player choices and reports only that system open was requested',
    (tester) async {
      final videoFile = File('history.mp4');
      var mediaKitControllerCreated = false;
      File? launchedFile;
      tester.view
        ..physicalSize = const Size(320, 360)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => RecordingMediaPlayerDialog(
                      file: videoFile,
                      title: '历史录屏',
                      preferExternalPlayer: true,
                      controllerFactory: (_) {
                        mediaKitControllerCreated = true;
                        throw StateError('系统播放器成功时不应初始化 MediaKit');
                      },
                      externalPlayerLauncher: (file) async {
                        launchedFile = file;
                      },
                    ),
                  ),
                  child: const Text('打开历史录屏'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开历史录屏'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(launchedFile, isNull);
      expect(mediaKitControllerCreated, isFalse);
      expect(find.text('选择播放方式'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-recording-in-app-player')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('open-recording-in-system-player')),
        findsOneWidget,
      );
      final systemPlayerButton = find.byKey(
        const ValueKey('open-recording-in-system-player'),
      );
      final dialogConstraints = find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ConstrainedBox &&
              widget.constraints.maxHeight > 295 &&
              widget.constraints.maxHeight < 296,
        ),
      );
      expect(dialogConstraints, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(systemPlayerButton);
      await tester.tap(systemPlayerButton);
      await tester.pumpAndSettle();

      expect(launchedFile?.path, videoFile.path);
      expect(find.text('已请求打开系统播放器'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-recording-in-app-player')),
        findsOneWidget,
      );
      expect(find.byType(Dialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keeps both player choices available after system open fails', (
    tester,
  ) async {
    final videoFile = File('history.mp4');
    final controller = _FakeRecordingPlaybackController(isVideo: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RecordingMediaPlayerDialog(
                    file: videoFile,
                    title: '历史录屏',
                    preferExternalPlayer: true,
                    controllerFactory: (_) => controller,
                    externalPlayerLauncher: (_) async {
                      throw StateError('没有可用的系统视频播放器');
                    },
                  ),
                ),
                child: const Text('打开历史录屏'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开历史录屏'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(controller.openedFile, isNull);
    expect(
      find.byKey(const ValueKey('open-recording-in-app-player')),
      findsOneWidget,
    );
    final systemPlayerButton = find.byKey(
      const ValueKey('open-recording-in-system-player'),
    );
    expect(systemPlayerButton, findsOneWidget);
    await tester.tap(systemPlayerButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('没有可用的系统视频播放器'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-recording-in-app-player')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('open-recording-in-app-player')),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.openedFile?.path, videoFile.path);
    expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers WAV playback in app after Windows accepts system open', (
    tester,
  ) async {
    final audioFile = File('history.wav');
    final controller = _FakeRecordingPlaybackController(isVideo: false);
    File? launchedFile;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RecordingMediaPlayerDialog(
                    file: audioFile,
                    title: '历史录音',
                    preferExternalPlayer: true,
                    controllerFactory: (_) => controller,
                    externalPlayerLauncher: (file) async {
                      launchedFile = file;
                    },
                  ),
                ),
                child: const Text('打开历史录音'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开历史录音'));
    await tester.pumpAndSettle();

    expect(launchedFile, isNull);
    expect(controller.openedFile, isNull);
    expect(find.text('选择播放方式'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('open-recording-in-system-player')),
    );
    await tester.pumpAndSettle();

    expect(launchedFile?.path, audioFile.path);
    expect(find.text('已请求打开系统播放器'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-recording-in-app-player')),
      findsOneWidget,
    );
    expect(controller.openedFile, isNull);
    await tester.tap(
      find.byKey(const ValueKey('open-recording-in-app-player')),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.openedFile?.path, audioFile.path);
    expect(find.text('本机录音'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a readable decode error instead of a blank video', (
    tester,
  ) async {
    final videoFile = File('broken.mp4');
    final controller = _FakeRecordingPlaybackController(
      isVideo: true,
      failureOnOpen: '测试解码错误：找不到视频帧',
    );

    await _openDialog(tester, file: videoFile, controller: controller);

    expect(find.textContaining('测试解码错误：找不到视频帧'), findsOneWidget);
    expect(find.byKey(const Key('fake-video-surface')), findsNothing);
  });

  testWidgets('opens a failed recording with the system player on request', (
    tester,
  ) async {
    final videoFile = File('broken.mp4');
    final controller = _FakeRecordingPlaybackController(
      isVideo: true,
      failureOnOpen: '测试解码错误：找不到视频帧',
    );
    File? launchedFile;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RecordingMediaPlayerDialog(
                    file: videoFile,
                    title: '测试媒体',
                    controllerFactory: (_) => controller,
                    externalPlayerLauncher: (file) async {
                      launchedFile = file;
                    },
                  ),
                ),
                child: const Text('打开媒体'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开媒体'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(
      find.byKey(const ValueKey('open-recording-in-system-player')),
    );
    await tester.pumpAndSettle();

    expect(launchedFile?.path, videoFile.path);
    expect(controller.closed, isTrue);
    expect(find.textContaining('测试解码错误：找不到视频帧'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-recording-in-app-player')),
      findsOneWidget,
    );
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('keeps system-player fallback available if video stays blank', (
    tester,
  ) async {
    final videoFile = File('blank-frame.mp4');
    final controller = _FakeRecordingPlaybackController(
      isVideo: true,
      waitForOpen: true,
    );
    final inAppController = _FakeRecordingPlaybackController(isVideo: true);
    File? launchedFile;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RecordingMediaPlayerDialog(
                    file: videoFile,
                    title: '空白视频',
                    controllerFactory: (_) => controller.openedFile == null
                        ? controller
                        : inAppController,
                    externalPlayerLauncher: (file) async {
                      launchedFile = file;
                    },
                  ),
                ),
                child: const Text('打开媒体'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开媒体'));
    await tester.pump();

    expect(find.text('正在等待视频画面…'), findsOneWidget);
    final fallback = find.byKey(
      const ValueKey('open-recording-in-system-player'),
    );
    expect(fallback, findsOneWidget);
    await tester.ensureVisible(fallback);
    await tester.tap(fallback);
    await tester.pumpAndSettle();

    expect(launchedFile?.path, videoFile.path);
    expect(controller.closed, isTrue);
    expect(find.text('已请求打开系统播放器'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-recording-in-app-player')),
      findsOneWidget,
    );
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('open-recording-in-app-player')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(inAppController.openedFile?.path, videoFile.path);
    expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the media error visible when the system player fails', (
    tester,
  ) async {
    final controller = _FakeRecordingPlaybackController(
      isVideo: true,
      failureOnOpen: '测试解码错误',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RecordingMediaPlayerDialog(
                    file: File('broken.mp4'),
                    title: '测试媒体',
                    controllerFactory: (_) => controller,
                    externalPlayerLauncher: (_) async {
                      throw StateError('no associated player');
                    },
                  ),
                ),
                child: const Text('打开媒体'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开媒体'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('open-recording-in-system-player')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('打开系统播放器失败'), findsOneWidget);
    expect(find.textContaining('no associated player'), findsOneWidget);
    expect(find.textContaining('测试解码错误'), findsOneWidget);
  });

  testWidgets('keeps loading while the video controller is opening', (
    tester,
  ) async {
    final videoFile = File('waiting.mp4');
    final controller = _FakeRecordingPlaybackController(
      isVideo: true,
      waitForOpen: true,
    );

    await _tapOpenDialog(tester, file: videoFile, controller: controller);
    await tester.pump();
    expect(find.text('正在等待视频画面…'), findsOneWidget);

    controller.finishOpen();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在等待视频画面…'), findsNothing);
    expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);
  });

  testWidgets(
    'keeps loading while the video frame is pending after native open',
    (tester) async {
      final controller = _FakeRecordingPlaybackController(
        isVideo: true,
        waitForFirstFrame: true,
      );

      await _tapOpenDialog(
        tester,
        file: File('first-frame-pending.mp4'),
        controller: controller,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.nativeOpenCompleted, isTrue);
      expect(controller.isLoading, isTrue);
      expect(find.text('正在等待视频画面…'), findsOneWidget);
      expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);

      controller.finishFirstFrame();
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.isLoading, isFalse);
      expect(find.text('正在等待视频画面…'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hands off a waiting video only after its controller closes and disposes once',
    (tester) async {
      final controller = _FakeRecordingPlaybackController(
        isVideo: true,
        waitForFirstFrame: true,
        waitForClose: true,
      );
      var handoffRequested = false;
      var directSystemLaunches = 0;

      await _tapOpenDialog(
        tester,
        file: File('pending-frame.mp4'),
        controller: controller,
        onSystemPlayerHandoffRequested: () => handoffRequested = true,
        externalPlayerLauncher: (_) async {
          directSystemLaunches++;
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('正在等待视频画面…'), findsOneWidget);
      final systemPlayerButton = find.byKey(
        const ValueKey('open-recording-in-system-player'),
      );
      await tester.ensureVisible(systemPlayerButton);
      await tester.tap(systemPlayerButton);
      await tester.pump();

      expect(controller.closeCalls, 1);
      expect(controller.disposed, isFalse);
      expect(handoffRequested, isFalse);
      expect(directSystemLaunches, 0);
      expect(find.byType(Dialog), findsOneWidget);

      controller.finishClose();
      await tester.pumpAndSettle();

      expect(controller.closeCalls, 1);
      expect(controller.disposeCalls, 1);
      expect(handoffRequested, isTrue);
      expect(directSystemLaunches, 0);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('waits for native player close before disposing the controller', (
    tester,
  ) async {
    final audioFile = File('fixture.wav');
    final controller = _FakeRecordingPlaybackController(
      isVideo: false,
      waitForClose: true,
    );
    Future<void>? reportedNativeClose;

    await _openDialog(
      tester,
      file: audioFile,
      controller: controller,
      onDialogDisposed: (pendingClose) => reportedNativeClose = pendingClose,
    );
    expect(find.text('本机录音'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭播放器'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(controller.closed, isTrue);
    expect(controller.disposed, isFalse);
    expect(reportedNativeClose, isNotNull);

    // A timeout must not dispose the notifier while MediaKit's native close
    // future is still running; the timeout does not cancel that future.
    await tester.pump(const Duration(seconds: 7));
    expect(controller.disposed, isFalse);

    controller.finishClose();
    await tester.pump();
    expect(controller.disposed, isTrue);
  });

  testWidgets(
    'does not create a native player after close wins the file check',
    (tester) async {
      final fileType = Completer<FileSystemEntityType>();
      var mediaKitInitialized = false;
      var playerCreated = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => RecordingMediaPlayerDialog(
                      file: File('delayed.mp4'),
                      title: '待检查的视频',
                      fileTypeResolver: (_) => fileType.future,
                      mediaKitInitializer: () => mediaKitInitialized = true,
                      playerFactory: () {
                        playerCreated = true;
                        throw StateError('播放器不应在关闭后创建');
                      },
                    ),
                  ),
                  child: const Text('打开媒体'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开媒体'));
      await tester.pump();
      await tester.tap(find.byTooltip('关闭播放器'));
      await tester.pumpAndSettle();

      fileType.complete(FileSystemEntityType.file);
      await tester.pumpAndSettle();

      expect(playerCreated, isFalse);
      expect(mediaKitInitialized, isFalse);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openDialog(
  WidgetTester tester, {
  required File file,
  required _FakeRecordingPlaybackController controller,
  void Function(Future<void>?)? onDialogDisposed,
  VoidCallback? onSystemPlayerHandoffRequested,
  Future<void> Function(File file)? externalPlayerLauncher,
}) async {
  await _tapOpenDialog(
    tester,
    file: file,
    controller: controller,
    onDialogDisposed: onDialogDisposed,
    onSystemPlayerHandoffRequested: onSystemPlayerHandoffRequested,
    externalPlayerLauncher: externalPlayerLauncher,
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapOpenDialog(
  WidgetTester tester, {
  required File file,
  required _FakeRecordingPlaybackController controller,
  void Function(Future<void>?)? onDialogDisposed,
  VoidCallback? onSystemPlayerHandoffRequested,
  Future<void> Function(File file)? externalPlayerLauncher,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => RecordingMediaPlayerDialog(
                  file: file,
                  title: '测试媒体',
                  preferExternalPlayer: false,
                  controllerFactory: (_) => controller,
                  onDialogDisposed: onDialogDisposed,
                  onSystemPlayerHandoffRequested:
                      onSystemPlayerHandoffRequested,
                  externalPlayerLauncher: externalPlayerLauncher,
                ),
              ),
              child: const Text('打开媒体'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开媒体'));
  await tester.pump();
}

final class _FakeRecordingPlaybackController
    extends RecordingPlaybackController {
  _FakeRecordingPlaybackController({
    required this.isVideo,
    this.videoAspectRatio = 16 / 9,
    this.failureOnOpen,
    bool waitForOpen = false,
    bool waitForFirstFrame = false,
    bool waitForClose = false,
  }) : _openGate = waitForOpen ? Completer<void>() : null,
       _firstFrameGate = waitForFirstFrame ? Completer<void>() : null,
       _closeGate = waitForClose ? Completer<void>() : null;

  @override
  final bool isVideo;

  @override
  final double videoAspectRatio;

  final String? failureOnOpen;
  final Completer<void>? _openGate;
  final Completer<void>? _firstFrameGate;
  final Completer<void>? _closeGate;
  final Completer<void> _stopRequested = Completer<void>();
  File? openedFile;
  var closed = false;
  var disposed = false;
  var closeCalls = 0;
  var disposeCalls = 0;
  var nativeOpenCompleted = false;
  @override
  var isLoading = true;
  @override
  var isPlaying = false;
  @override
  var position = Duration.zero;
  @override
  final duration = const Duration(seconds: 40);
  @override
  String? failureMessage;
  @override
  String? failureDetails;

  @override
  Widget buildVideoView() =>
      const ColoredBox(key: Key('fake-video-surface'), color: Colors.black);

  @override
  Future<void> open(File file) async {
    openedFile = file;
    final openGate = _openGate;
    if (openGate != null) await openGate.future;
    nativeOpenCompleted = true;
    failureMessage = failureOnOpen;
    failureDetails = failureOnOpen == null ? null : '模拟解码器错误详情';
    notifyListeners();
    final firstFrameGate = _firstFrameGate;
    if (firstFrameGate != null) await firstFrameGate.future;
    isLoading = false;
    notifyListeners();
  }

  @override
  Future<void> togglePlayback() async {
    isPlaying = !isPlaying;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
    notifyListeners();
  }

  @override
  Future<void> close() async {
    closeCalls++;
    closed = true;
    if (!_stopRequested.isCompleted) _stopRequested.complete();
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
    disposed = true;
    super.dispose();
  }

  void finishOpen() => _openGate?.complete();

  void finishFirstFrame() => _firstFrameGate?.complete();

  void finishClose() => _closeGate?.complete();
}
