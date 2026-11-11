import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:yixue_app/features/simultaneous_interpretation/recording_media_player_dialog.dart';

import '../test/support/synthetic_media_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'production recording dialog renders a synthetic MP4 texture and disposes it',
    (tester) async {
      // Detaching the native video texture can make the Windows integration
      // host request platform semantics. This media-only test does not inspect
      // accessibility, so pin the test dispatcher off and avoid treating that
      // host-owned handle as a test leak.
      tester.binding.platformDispatcher.semanticsEnabledTestValue = false;
      final fixturePath = Platform.environment['YIXUE_TEST_MP4_FILE'];
      expect(
        fixturePath,
        isNotNull,
        reason: 'Run the Windows media smoke script to create a synthetic MP4.',
      );
      expect(
        isTrustedSyntheticMp4Fixture(fixturePath!),
        isTrue,
        reason:
            'Refuse to open media unless the Windows smoke wrapper created '
            'a marked synthetic fixture in its scoped temp folder.',
      );
      final fixture = File(fixturePath);
      expect(await fixture.exists(), isTrue);
      expect(await fixture.length(), greaterThan(4096));

      Future<void>? nativeClose;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: RecordingMediaPlayerDialog(
                  file: fixture,
                  title: '合成视频纹理验收',
                  onDialogDisposed: (close) => nativeClose = close,
                ),
              ),
            ),
          ),
        );
        final ready = await _waitForFlutterTexture(tester);
        expect(
          ready,
          isTrue,
          reason:
              'The production dialog must receive a decoded first frame, '
              'advance playback, and install a Flutter Texture before the '
              'loading overlay disappears.',
        );
        expect(
          find.byKey(const ValueKey('recording-video-viewport')),
          findsOneWidget,
        );
        expect(find.byType(Video), findsOneWidget);

        final textureFinder = find.descendant(
          of: find.byType(Video),
          matching: find.byType(Texture),
        );
        expect(textureFinder, findsOneWidget);
        expect(
          tester.widget<Texture>(textureFinder).textureId,
          greaterThanOrEqualTo(0),
        );
        expect(find.text('正在等待视频画面…'), findsNothing);
        expect(find.text('视频未能开始输出画面。'), findsNothing);
        expect(find.text('视频无法播放。'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        final close = nativeClose;
        if (close != null) {
          await tester.runAsync<void>(
            () => close.timeout(const Duration(seconds: 8)),
          );
        }
      }

      expect(
        nativeClose,
        isNotNull,
        reason: 'The dialog should report player cleanup.',
      );
      expect(find.byType(Texture), findsNothing);
      expect(tester.takeException(), isNull);
    },
    semanticsEnabled: false,
  );
}

Future<bool> _waitForFlutterTexture(WidgetTester tester) async {
  final timeout = Stopwatch()..start();
  const deadline = Duration(seconds: 25);
  const frameStep = Duration(milliseconds: 32);

  while (timeout.elapsed < deadline) {
    await tester.pump(frameStep);
    final hasTexture = find
        .descendant(of: find.byType(Video), matching: find.byType(Texture))
        .evaluate()
        .isNotEmpty;
    final waitingForFirstFrame = find.text('正在等待视频画面…').evaluate().isNotEmpty;
    if (hasTexture && !waitingForFirstFrame) return true;

    await tester.runAsync<void>(
      () => Future<void>.delayed(const Duration(milliseconds: 32)),
    );
  }
  return false;
}
