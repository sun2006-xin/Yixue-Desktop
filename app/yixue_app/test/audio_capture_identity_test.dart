import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/desktop_screen_recording.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('audio capture identity', () {
    test('rejects delayed frames from an earlier capture attempt', () {
      final frame = _frame(attemptId: 'attempt-old');

      expect(
        audioFrameMatchesCaptureIdentity(
          frame,
          sessionId: 'session-1',
          captureAttemptId: 'attempt-current',
          sourceId: 'system-output',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        ),
        isFalse,
      );
      expect(
        audioFrameMatchesCaptureIdentity(
          frame,
          sessionId: 'session-1',
          captureAttemptId: 'attempt-old',
          sourceId: 'system-output',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        ),
        isTrue,
      );
    });

    test('screen recording reuses an active subtitle session without audio', () {
      expect(
        resolveScreenRecordingSessionId(
          fallbackSessionId: 'standalone-video',
          activeSubtitleSessionId: 'subtitle-session',
        ),
        'subtitle-session',
      );
    });

    test('screen recording keeps standalone and audio-only session identity', () {
      expect(
        resolveScreenRecordingSessionId(
          fallbackSessionId: 'standalone-video',
          activeAudioOnlySessionId: 'audio-only-session',
        ),
        'audio-only-session',
      );
      expect(
        resolveScreenRecordingSessionId(
          fallbackSessionId: 'standalone-video',
        ),
        'standalone-video',
      );
    });
  });

  test(
    'carries capture attempt identity through the Windows recorder channel',
    () async {
      const channel = MethodChannel(
        'com.yixue.yixue_app/ai_tongchuan/screen_recording',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'startRecording') {
          return <String, Object?>{'status': 'recording'};
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final adapter = DesktopScreenRecordingAdapter(channel: channel);
      final state = await adapter.startRecording(
        recordingDirectory: Directory.systemTemp,
        sessionId: 'session-1',
        retainAudio: true,
        audioCaptureAttemptId: 'attempt-current',
        audioSourceId: 'system-output',
        audioTimelineStartQpc100ns: 100,
      );
      await adapter.writeAudioFrames(<AudioFrame>[_frame()]);

      expect(state.isRecording, isTrue);
      expect(calls, hasLength(2));
      expect(
        (calls.first.arguments!
            as Map<Object?, Object?>)['audioCaptureAttemptId'],
        'attempt-current',
      );
      final frames =
          (calls.last.arguments! as Map<Object?, Object?>)['frames']! as List;
      expect(
        (frames.single as Map<Object?, Object?>)['captureAttemptId'],
        'attempt-current',
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'requests a partial output when stopping after an audio integrity failure',
    () async {
      const channel = MethodChannel(
        'com.yixue.yixue_app/ai_tongchuan/screen_recording',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodCall? stopCall;
      messenger.setMockMethodCallHandler(channel, (call) async {
        stopCall = call;
        return <String, Object?>{
          'status': 'failed',
          'message': '录音存在丢帧，未完成文件已保留。',
          'path': 'capture.partial.mp4',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final state = await DesktopScreenRecordingAdapter(
        channel: channel,
      ).stopRecording(
        preservePartial: true,
        failureMessage: '录音存在丢帧，未完成文件已保留。',
      );

      expect(state.status, 'failed');
      expect(state.path, 'capture.partial.mp4');
      expect(
        stopCall?.arguments,
        <String, Object?>{
          'preservePartial': true,
          'failureMessage': '录音存在丢帧，未完成文件已保留。',
        },
      );
    },
    skip: !Platform.isWindows,
  );
}

AudioFrame _frame({String attemptId = 'attempt-current'}) => AudioFrame(
  sessionId: 'session-1',
  captureAttemptId: attemptId,
  sourceId: 'system-output',
  sourceKind: SubtitleAudioSourceKind.systemOutput,
  sequence: 1,
  startTimeUs: 0,
  qpcTime100ns: 100,
  sampleRateHz: 8_000,
  channelCount: 1,
  sampleCount: 80,
  sampleFormat: AudioPcmSampleFormat.float32LittleEndian,
  pcmBytes: Uint8List(80 * Float32List.bytesPerElement),
);
