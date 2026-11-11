import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/desktop_screen_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yixue.test/screen_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('preview release waits for native texture unregistration', () async {
    var checks = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'releasePreviewForNavigation') return null;
      if (call.method == 'isPreviewReleaseComplete') return ++checks >= 3;
      throw MissingPluginException('Unexpected method: ${call.method}');
    });
    final adapter = DesktopScreenCaptureAdapter(
      applicationDataDirectory: Directory.systemTemp,
      methodChannel: channel,
    );

    await adapter.releasePreviewForNavigation(
      timeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 1),
    );

    expect(checks, 3);
  });

  test(
    'legacy screen recording keeps its subtitle session in the MP4 name',
    () async {
      final dataDirectory = await Directory.systemTemp.createTemp(
        'yixue-screen-capture-session-',
      );
      addTearDown(() => dataDirectory.delete(recursive: true));
      const sessionId = '01234567-89ab-cdef-0123-456789abcdef';
      const captureAttemptId = 'capture-attempt-1';
      MethodCall? startCall;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startRecording') {
          startCall = call;
          return null;
        }
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
      final adapter = DesktopScreenCaptureAdapter(
        applicationDataDirectory: dataDirectory,
        methodChannel: channel,
        clock: () => DateTime(2026, 10, 20, 12, 34, 56, 123, 456),
      );

      final path = await adapter.startRecording(
        sessionId: sessionId,
        captureAttemptId: captureAttemptId,
      );

      expect(startCall?.arguments['sessionId'], sessionId);
      expect(startCall?.arguments['captureAttemptId'], captureAttemptId);
      expect(
        path.split(Platform.pathSeparator).last,
        matches(
          RegExp(
            r'^screen-20261020-123456-01234567-89ab-cdef-0123-456789abcdef-\d+-\d+\.partial\.mp4$',
          ),
        ),
      );
    },
  );

  test(
    'stop result exposes when the native audio track was not finalized',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stopRecording') {
          return <String, Object?>{
            'outputPath': 'screen-capture.mp4',
            'audioFinalized': false,
          };
        }
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
      final adapter = DesktopScreenCaptureAdapter(
        applicationDataDirectory: Directory.systemTemp,
        methodChannel: channel,
      );

      final path = await adapter.stopRecording();

      expect(path, 'screen-capture.mp4');
      expect(adapter.lastRecordingAudioFinalized, isFalse);
    },
  );

  test(
    'preview release fails closed if native never unregisters texture',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'releasePreviewForNavigation') return null;
        if (call.method == 'isPreviewReleaseComplete') return false;
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
      final adapter = DesktopScreenCaptureAdapter(
        applicationDataDirectory: Directory.systemTemp,
        methodChannel: channel,
      );

      await expectLater(
        adapter.releasePreviewForNavigation(
          timeout: const Duration(milliseconds: 10),
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test('preview release uses one deadline across native round trips', () async {
    var completionChecks = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'releasePreviewForNavigation') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return null;
      }
      if (call.method == 'isPreviewReleaseComplete') {
        completionChecks++;
        return false;
      }
      throw MissingPluginException('Unexpected method: ${call.method}');
    });
    final adapter = DesktopScreenCaptureAdapter(
      applicationDataDirectory: Directory.systemTemp,
      methodChannel: channel,
    );

    await expectLater(
      adapter.releasePreviewForNavigation(
        timeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<TimeoutException>()),
    );

    expect(completionChecks, 0);
  });

  test(
    'source selection waits for a release request that outlived its timeout',
    () async {
      final releaseAcknowledged = Completer<void>();
      var nativeReleaseComplete = false;
      var releaseRequests = 0;
      var selectedBeforeRelease = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'releasePreviewForNavigation') {
          releaseRequests++;
          await releaseAcknowledged.future;
          return null;
        }
        if (call.method == 'isPreviewReleaseComplete') {
          return nativeReleaseComplete;
        }
        if (call.method == 'selectSource') {
          selectedBeforeRelease = !nativeReleaseComplete;
          return <String, Object?>{
            'textureId': 7,
            'width': 800,
            'height': 600,
            'targetName': 'test window',
          };
        }
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
      final adapter = DesktopScreenCaptureAdapter(
        applicationDataDirectory: Directory.systemTemp,
        methodChannel: channel,
      );

      await expectLater(
        adapter.releasePreviewForNavigation(
          timeout: const Duration(milliseconds: 5),
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(releaseRequests, 1);

      releaseAcknowledged.complete();
      nativeReleaseComplete = true;
      final target = await adapter.selectSource();

      expect(target.textureId, 7);
      expect(
        releaseRequests,
        1,
        reason: 'a retry must reuse the pending release',
      );
      expect(selectedBeforeRelease, isFalse);
    },
  );
}
