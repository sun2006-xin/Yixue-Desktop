import 'dart:async';
import 'dart:typed_data';

import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/desktop_audio_capture.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/screen_recording_startup_gate.dart';

AudioFrame _frame(int sequence) => AudioFrame(
  sessionId: 'recording-session',
  captureAttemptId: 'capture-attempt',
  sourceId: 'system-output',
  sourceKind: SubtitleAudioSourceKind.systemOutput,
  sequence: sequence,
  startTimeUs: sequence * 1000,
  sampleRateHz: 48000,
  channelCount: 2,
  sampleCount: 48,
  sampleFormat: AudioPcmSampleFormat.float32LittleEndian,
  pcmBytes: Uint8List(48 * 2 * 4),
);

AudioFrame _frameWithDiscontinuity(bool hasDiscontinuityBefore) => AudioFrame(
  sessionId: 'recording-session',
  captureAttemptId: 'capture-attempt',
  sourceId: 'system-output',
  sourceKind: SubtitleAudioSourceKind.systemOutput,
  sequence: 2,
  startTimeUs: 2000,
  sampleRateHz: 48000,
  channelCount: 2,
  sampleCount: 48,
  sampleFormat: AudioPcmSampleFormat.float32LittleEndian,
  pcmBytes: Uint8List(48 * 2 * 4),
  hasDiscontinuityBefore: hasDiscontinuityBefore,
);

void main() {
  test('unconfirmed recording audio cleanup keeps the MP4 partial', () {
    expect(
      screenRecordingMustPreservePartial(
        audioWriteFailed: false,
        sourceStopFailed: true,
        audioCleanupFailed: false,
      ),
      isTrue,
    );
    expect(
      screenRecordingMustPreservePartial(
        audioWriteFailed: false,
        sourceStopFailed: false,
        audioCleanupFailed: true,
      ),
      isTrue,
    );
    expect(
      screenRecordingMustPreservePartial(
        audioWriteFailed: true,
        sourceStopFailed: false,
        audioCleanupFailed: false,
      ),
      isTrue,
    );
    expect(
      screenRecordingMustPreservePartial(
        audioWriteFailed: false,
        sourceStopFailed: false,
        audioCleanupFailed: false,
      ),
      isFalse,
    );
  });

  test(
    'audio stream errors release the first-frame wait immediately',
    () async {
      final gate = ScreenRecordingAudioStartupGate();
      final firstFrame = gate.firstFrame;

      gate.fail();

      expect(await firstFrame, isNull);
      expect(gate.isCompleted, isTrue);
    },
  );

  test('audio frame gaps are rejected for screen recording', () {
    expect(
      screenRecordingAudioFrameFailure(_frameWithDiscontinuity(true)),
      contains('丢帧'),
    );
    expect(
      screenRecordingAudioFrameFailure(_frameWithDiscontinuity(false)),
      isNull,
    );
  });

  test('stop waits for an in-flight pre-roll audio write to settle', () async {
    final writeStarted = Completer<void>();
    final finishWrite = Completer<void>();
    var nativeStopStarted = false;
    var writeTail = Future<void>.value();
    writeTail = enqueueScreenRecordingAudioWrite(
      previous: writeTail,
      write: () async {
        writeStarted.complete();
        await finishWrite.future;
      },
      onError: (error, stackTrace) {},
    );

    final stop = () async {
      await writeTail;
      nativeStopStarted = true;
    }();
    await writeStarted.future;
    await Future<void>.delayed(Duration.zero);

    expect(nativeStopStarted, isFalse);
    finishWrite.complete();
    await stop;

    expect(nativeStopStarted, isTrue);
  });

  test('screen recording cleanup state gates new audio capture', () {
    expect(
      resolveScreenRecordingCleanupStatus(
        ownsAudioSource: false,
        source: null,
        sessionId: null,
      ),
      ScreenRecordingCleanupStatus.clear,
    );
    expect(
      resolveScreenRecordingCleanupStatus(
        ownsAudioSource: true,
        source: null,
        sessionId: 'old-session',
      ),
      ScreenRecordingCleanupStatus.unconfirmed,
    );
    expect(
      resolveScreenRecordingCleanupStatus(
        ownsAudioSource: true,
        source: DesktopAudioCaptureSource(
          sourceId: 'old-source',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
          displayName: '系统播放声',
          description: '测试音源',
        ),
        sessionId: 'old-session',
      ),
      ScreenRecordingCleanupStatus.retryable,
    );
    expect(
      canStartAudioCaptureAfterScreenRecordingCleanup(
        ScreenRecordingCleanupStatus.clear,
      ),
      isTrue,
    );
    expect(
      canStartAudioCaptureAfterScreenRecordingCleanup(
        ScreenRecordingCleanupStatus.clear,
        screenRecordingStopInProgress: true,
      ),
      isFalse,
      reason: 'A recording finalization must block a new audio session.',
    );
    expect(
      canStartAudioCaptureAfterScreenRecordingCleanup(
        ScreenRecordingCleanupStatus.clear,
        audioSubscriptionCleanupUnconfirmed: true,
      ),
      isFalse,
      reason: 'A failed listener cancellation must block a second recorder.',
    );
    expect(
      canStartAudioCaptureAfterScreenRecordingCleanup(
        ScreenRecordingCleanupStatus.retryable,
      ),
      isFalse,
    );
    expect(
      canStartAudioCaptureAfterScreenRecordingCleanup(
        ScreenRecordingCleanupStatus.unconfirmed,
      ),
      isFalse,
    );
  });

  test(
    'cancellation failure releases the one-shot subscription reference',
    () async {
      final controller = StreamController<AudioFrame>(
        onCancel: () async => throw StateError('native cleanup failed'),
      );
      addTearDown(controller.close);
      final deliveredFrames = <AudioFrame>[];
      final subscription = controller.stream.listen(deliveredFrames.add);
      final lease = ScreenRecordingAudioFrameSubscriptionLease(subscription);
      var subscriptionReferenceHeld = true;

      await expectLater(
        cancelScreenRecordingAudioFrameSubscription(
          lease: lease,
          onCancellationAttemptComplete: () =>
              subscriptionReferenceHeld = false,
        ),
        throwsA(isA<StateError>()),
      );

      expect(subscriptionReferenceHeld, isFalse);
      expect(
        canStartAudioCaptureAfterScreenRecordingCleanup(
          ScreenRecordingCleanupStatus.clear,
          audioSubscriptionCleanupUnconfirmed: subscriptionReferenceHeld,
        ),
        isTrue,
      );
      controller.add(_frame(1));
      await Future<void>.delayed(Duration.zero);
      expect(deliveredFrames, isEmpty);
    },
  );

  test('disposal handles an async subscription cancellation failure', () async {
    final controller = StreamController<AudioFrame>(
      onCancel: () async => throw StateError('native cleanup failed'),
    );
    addTearDown(controller.close);
    final subscription = controller.stream.listen((_) {});

    await cancelScreenRecordingAudioFrameSubscriptionForDisposal(
      lease: ScreenRecordingAudioFrameSubscriptionLease(subscription),
    );
  });

  test('stop and disposal share one pending frame cancellation', () async {
    final cancellation = Completer<void>();
    var cancelCalls = 0;
    final controller = StreamController<AudioFrame>(
      onCancel: () {
        cancelCalls += 1;
        return cancellation.future;
      },
    );
    addTearDown(controller.close);
    final lease = ScreenRecordingAudioFrameSubscriptionLease(
      controller.stream.listen((_) {}),
    );

    var stopCleanupAttemptFinished = false;
    final stopCancellation = cancelScreenRecordingAudioFrameSubscription(
      lease: lease,
      onCancellationAttemptComplete: () => stopCleanupAttemptFinished = true,
    );
    final disposalCancellation =
        cancelScreenRecordingAudioFrameSubscriptionForDisposal(lease: lease);
    await Future<void>.delayed(Duration.zero);

    expect(cancelCalls, 1);
    expect(stopCleanupAttemptFinished, isFalse);
    cancellation.complete();
    await Future.wait([stopCancellation, disposalCancellation]);

    expect(cancelCalls, 1);
    expect(stopCleanupAttemptFinished, isTrue);
  });

  test(
    'unconfirmed screen audio stop keeps original source identity for retry',
    () async {
      const source = DesktopAudioCaptureSource(
        sourceId: 'stale-system-output',
        sourceKind: SubtitleAudioSourceKind.systemOutput,
        displayName: '系统播放声',
        description: '测试音源',
      );
      const sessionId = 'previous-recording-session';
      final stopCalls = <(String, String)>[];

      Future<void> stopSource({
        required String sourceId,
        required String sessionId,
      }) async {
        stopCalls.add((sourceId, sessionId));
        if (stopCalls.length == 1)
          throw StateError('native stop not confirmed');
      }

      await expectLater(
        retryUnconfirmedScreenRecordingAudioStop(
          ownsAudioSource: true,
          source: source,
          sessionId: sessionId,
          stopSource: stopSource,
        ),
        throwsA(isA<StateError>()),
      );
      expect(stopCalls, <(String, String)>[(source.sourceId, sessionId)]);

      await retryUnconfirmedScreenRecordingAudioStop(
        ownsAudioSource: true,
        source: source,
        sessionId: sessionId,
        stopSource: stopSource,
      );
      expect(stopCalls, <(String, String)>[
        (source.sourceId, sessionId),
        (source.sourceId, sessionId),
      ]);
    },
  );

  test('unowned screen audio never stops a shared source', () async {
    var stopCalls = 0;
    await retryUnconfirmedScreenRecordingAudioStop(
      ownsAudioSource: false,
      source: null,
      sessionId: null,
      stopSource: ({required sourceId, required sessionId}) async {
        stopCalls++;
      },
    );
    expect(stopCalls, 0);
  });

  test('pre-roll keeps overflow latched when it happens during startup', () {
    final preRoll = ScreenRecordingAudioPreRoll(maxFrames: 2);
    expect(preRoll.add(_frame(1)), isTrue);
    expect(preRoll.add(_frame(2)), isTrue);

    // This represents an overflow after the initial gate check, while the
    // native recorder is still starting.
    expect(preRoll.add(_frame(3)), isFalse);
    expect(preRoll.hasOverflowed, isTrue);
    expect(preRoll.takeBatch().map((frame) => frame.sequence), [1, 2]);
    expect(preRoll.hasOverflowed, isTrue);
  });

  test('pre-roll batches preserve order for frames arriving during flush', () {
    final preRoll = ScreenRecordingAudioPreRoll(maxFrames: 3);
    preRoll.add(_frame(1));
    preRoll.add(_frame(2));

    final firstBatch = preRoll.takeBatch();
    preRoll.add(_frame(3));

    expect(firstBatch.map((frame) => frame.sequence), [1, 2]);
    expect(preRoll.takeBatch().map((frame) => frame.sequence), [3]);
    expect(preRoll.isEmpty, isTrue);
  });
}
