import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_video_recording_index.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_audio_recording.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';

import 'support/synthetic_media_fixture.dart';

/// Opt-in Windows decoder smoke test.
///
/// Set YIXUE_MEDIAKIT_NATIVE_DIR to the directory containing libmpv-2.dll,
/// and add the same directory to PATH before running this test. The tests
/// create silent WAV/MP4 fixtures under the OS temp directory; set
/// YIXUE_TEST_MP4_FILE to opt into the generated Windows H.264/AAC fixture.
void main() {
  final nativeDirectory = Platform.environment['YIXUE_MEDIAKIT_NATIVE_DIR'];
  final mp4FixturePath = Platform.environment['YIXUE_TEST_MP4_FILE'];
  if (mp4FixturePath != null &&
      mp4FixturePath.isNotEmpty &&
      !isTrustedSyntheticMp4Fixture(mp4FixturePath)) {
    throw StateError(
      'YIXUE_TEST_MP4_FILE must point to the marked synthetic fixture created '
      'by tool/test-windows-media-smoke.ps1; refusing to open arbitrary media.',
    );
  }
  final skipReason = !Platform.isWindows
      ? 'MediaKit native smoke test requires Windows.'
      : nativeDirectory == null || nativeDirectory.isEmpty
      ? 'Set YIXUE_MEDIAKIT_NATIVE_DIR to the directory containing libmpv-2.dll.'
      : null;
  final mp4SkipReason =
      skipReason ??
      (mp4FixturePath == null || mp4FixturePath.isEmpty
          ? 'Set YIXUE_TEST_MP4_FILE to a synthetic H.264 MP4 fixture.'
          : null);

  test(
    'accepts only a marked synthetic MP4 inside its scoped temp folder',
    skip: !Platform.isWindows
        ? 'Synthetic fixture guard is Windows-only.'
        : null,
    () async {
      final untrustedDirectory = await Directory.systemTemp.createTemp(
        'yixue-untrusted-video-',
      );
      final trustedDirectory = await Directory.systemTemp.createTemp(
        'yixue-media-smoke-guard-',
      );
      try {
        final arbitraryVideo = File(
          '${untrustedDirectory.path}\\user-video.mp4',
        );
        await arbitraryVideo.writeAsBytes(<int>[0, 1, 2, 3]);
        expect(isTrustedSyntheticMp4Fixture(arbitraryVideo.path), isFalse);

        await File('${trustedDirectory.path}\\$syntheticMediaFixtureMarker')
            .writeAsString('YIXUE_SYNTHETIC_MEDIA_FIXTURE_V1', flush: true);
        final syntheticVideo = File(
          '${trustedDirectory.path}\\synthetic-screen-recording.mp4',
        );
        await syntheticVideo.writeAsBytes(<int>[0, 1, 2, 3]);
        expect(isTrustedSyntheticMp4Fixture(syntheticVideo.path), isTrue);
      } finally {
        await untrustedDirectory.delete(recursive: true);
        await trustedDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'MediaKit opens a PCM WAV and advances playback on Windows',
    skip: skipReason,
    () => _verifyNativePlayback(_silentPcmWave(channels: 2)),
  );
  test(
    'MediaKit opens a legacy-compatible six-channel extensible WAV',
    skip: skipReason,
    () => _verifyNativePlayback(_silentPcmWave(channels: 6, extensible: true)),
  );
  test(
    'MediaKit opens WAV bytes produced by the subtitle recording pipeline',
    skip: skipReason,
    _verifyRecordedWavePlayback,
  );
  test(
    'MediaKit decodes recovered interrupted PCM from the audio history pipeline',
    skip: skipReason,
    _verifyRecoveredInterruptedRecordingPlayback,
  );
  test(
    'MediaKit decodes synthetic H.264 video and advances playback',
    skip: mp4SkipReason,
    () => _verifyNativeVideoPlayback(File(mp4FixturePath!)),
  );
}

Future<void> _verifyRecordedWavePlayback() async {
  final nativeLibrary = File(
    '${Platform.environment['YIXUE_MEDIAKIT_NATIVE_DIR']}\\libmpv-2.dll',
  );
  expect(await nativeLibrary.exists(), isTrue);

  final appDataDirectory = await Directory.systemTemp.createTemp(
    'yixue-recorded-wave-smoke-',
  );
  final frames = StreamController<AudioFrame>.broadcast();
  final recorder = SubtitleAudioSessionRecorder(
    appDataDirectory: appDataDirectory,
  );

  try {
    await recorder.start(
      sessionId: 'media-kit-recording-smoke',
      captureAttemptId: 'capture-1',
      sources: <SubtitleSessionAudioSource>[
        SubtitleSessionAudioSource(
          sourceId: 'windows-system-output',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        ),
      ],
      frames: frames.stream,
    );
    for (var sequence = 0; sequence < 30; sequence++) {
      frames.add(
        AudioFrame(
          sessionId: 'media-kit-recording-smoke',
          captureAttemptId: 'capture-1',
          sourceId: 'windows-system-output',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
          sequence: sequence,
          startTimeUs: sequence * 100000,
          sampleRateHz: 48000,
          channelCount: 2,
          sampleCount: 4800,
          sampleFormat: AudioPcmSampleFormat.signedInt16LittleEndian,
          // Silence keeps this desktop decoder smoke test inaudible.
          pcmBytes: Uint8List(4800 * 2 * 2),
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final stopped = await recorder.stop();
    expect(stopped.status, SubtitleAudioRecordingStatus.stopped);
    expect(stopped.sources.single.framesWritten, 30);

    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    expect(recordings, hasLength(1));
    expect(recordings.single.files, hasLength(1));
    expect(recordings.single.files.single.dataBytes, 48000 * 3 * 2 * 2);

    await _verifyNativePlaybackFile(recordings.single.files.single.file);
  } finally {
    await recorder.dispose();
    await frames.close();
    await appDataDirectory.delete(recursive: true);
  }
}

Future<void> _verifyRecoveredInterruptedRecordingPlayback() async {
  const sessionId = 'media-kit-recovery-smoke-session';
  const recordingId = '0123456789abcdef0123456789abcdef';
  const sourceId = 'windows-system-output';
  const sampleRateHz = 16000;
  const channelCount = 1;
  const durationSeconds = 2;
  const dataBytes = sampleRateHz * durationSeconds * channelCount * 2;
  final appDataDirectory = await Directory.systemTemp.createTemp(
    'yixue-recovered-audio-smoke-',
  );
  final sessionDigest = sha256.convert(utf8.encode(sessionId)).toString();
  final sourceDigest = sha256.convert(utf8.encode(sourceId)).toString();
  final sessionDirectory = Directory(
    '${appDataDirectory.path}\\simultaneous-interpretation\\recordings\\$sessionDigest',
  );
  final recordingDirectory = Directory(
    '${sessionDirectory.path}\\$recordingId',
  );
  final expectedRelativePath =
      'simultaneous-interpretation/recordings/$sessionDigest/$recordingId/'
      'systemOutput-$sourceDigest.wav';
  final rawFile = File(
    '${recordingDirectory.path}\\systemOutput-$sourceDigest.wav',
  );

  try {
    await recordingDirectory.create(recursive: true);
    await File('${sessionDirectory.path}\\.session.lock').create();

    // Simulate a process interrupted after PCM was written but before the WAV
    // header and completion manifest were finalized.
    final rawBytes = Uint8List(44 + dataBytes);
    final rawData = ByteData.sublistView(rawBytes);
    for (var sample = 0; sample < sampleRateHz * durationSeconds; sample++) {
      final value = (8000 * math.sin(2 * math.pi * 440 * sample / sampleRateHz))
          .round();
      rawData.setInt16(44 + sample * 2, value, Endian.little);
    }
    await rawFile.writeAsBytes(rawBytes, flush: true);

    final startedAtUtc = '2026-11-05T00:00:00.000Z';
    await File('${recordingDirectory.path}\\manifest.json').writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'recordingId': recordingId,
        'sessionId': sessionId,
        'status': 'recording',
        'format': 'wav-pcm-s16le',
        'startedAtUtc': startedAtUtc,
        'endedAtUtc': null,
        'error': 'synthetic_interrupted_fixture',
        'sources': <Object?>[
          <String, Object?>{
            'sourceId': sourceId,
            'sourceKind': SubtitleAudioSourceKind.systemOutput.name,
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
            'startedAtUtc': startedAtUtc,
            'endedAtUtc': null,
            'error': 'synthetic_interrupted_fixture',
          },
        ],
      }),
      flush: true,
    );

    final sourceBytesBeforeRecovery = await rawFile.readAsBytes();
    final beforeRecovery =
        await SubtitleAudioSessionRecorder.listSavedRecordingsWithStatus(
          appDataDirectory: appDataDirectory,
        );
    expect(beforeRecovery.recordings, hasLength(1));
    expect(beforeRecovery.recordings.single.recoveryCandidates, hasLength(1));
    expect(
      beforeRecovery.recordings.single.recoveryCandidates.single.dataBytes,
      dataBytes,
    );

    final recoveredRecordingId =
        await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
          appDataDirectory: appDataDirectory,
          sessionId: sessionId,
          recordingId: recordingId,
          sourceId: sourceId,
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        );
    final afterRecovery =
        await SubtitleAudioSessionRecorder.listSavedRecordingsWithStatus(
          appDataDirectory: appDataDirectory,
        );
    final recoveredRecording = afterRecovery.recordings.singleWhere(
      (recording) => recording.recordingId == recoveredRecordingId,
    );
    expect(recoveredRecording.files, hasLength(1));
    final recoveredWave = recoveredRecording.files.single.file;
    final recoveredBytes = await recoveredWave.readAsBytes();
    expect(recoveredBytes.length, 44 + dataBytes);
    expect(recoveredBytes.take(4), <int>[0x52, 0x49, 0x46, 0x46]);
    expect(recoveredBytes.skip(44).any((byte) => byte != 0), isTrue);
    expect(await rawFile.readAsBytes(), sourceBytesBeforeRecovery);

    // Keep the real decoder path silent while verifying the recovered audio
    // stream and playback position on Windows.
    await _verifyNativePlaybackFile(
      recoveredWave,
      muted: true,
      expectedSampleRateHz: sampleRateHz,
      expectedChannelCount: channelCount,
    );
  } finally {
    await appDataDirectory.delete(recursive: true);
  }
}

Future<void> _verifyNativePlayback(
  Uint8List waveBytes, {
  bool muted = false,
}) async {
  final nativeLibrary = File(
    '${Platform.environment['YIXUE_MEDIAKIT_NATIVE_DIR']}\\libmpv-2.dll',
  );
  expect(await nativeLibrary.exists(), isTrue);

  final temporaryDirectory = await Directory.systemTemp.createTemp(
    'yixue-media-kit-smoke-',
  );
  final wav = File('${temporaryDirectory.path}\\silent.wav');
  try {
    await wav.writeAsBytes(waveBytes, flush: true);
    await _verifyNativePlaybackFile(wav, muted: muted);
  } finally {
    await temporaryDirectory.delete(recursive: true);
  }
}

Future<void> _verifyNativePlaybackFile(
  File wav, {
  bool muted = false,
  int? expectedSampleRateHz,
  int? expectedChannelCount,
}) async {
  final nativeDirectory = Platform.environment['YIXUE_MEDIAKIT_NATIVE_DIR'];
  final nativeLibrary = File('$nativeDirectory\\libmpv-2.dll');
  expect(await nativeLibrary.exists(), isTrue);

  late final Player player;
  var playerCreated = false;
  final errors = <String>[];
  final positions = <Duration>[];
  final advancedPosition = Completer<void>();
  late final Future<AudioParams> audioParamsFuture;
  StreamSubscription<String>? errorSubscription;
  StreamSubscription<Duration>? positionSubscription;

  try {
    MediaKit.ensureInitialized();
    player = Player(configuration: PlayerConfiguration(muted: muted));
    playerCreated = true;
    audioParamsFuture = player.stream.audioParams
        .firstWhere(
          (value) =>
              value.sampleRate != null &&
              value.sampleRate! > 0 &&
              value.channelCount != null &&
              value.channelCount! > 0,
        )
        .timeout(const Duration(seconds: 10));
    errorSubscription = player.stream.error.listen((value) {
      if (value.trim().isNotEmpty) errors.add(value);
    });
    positionSubscription = player.stream.position.listen((value) {
      if (value > Duration.zero &&
          (positions.isEmpty || value > positions.last)) {
        positions.add(value);
        if (positions.length >= 2 && !advancedPosition.isCompleted) {
          advancedPosition.complete();
        }
      }
    });
    await player
        .open(Media(wav.absolute.uri.toString()), play: true)
        .timeout(const Duration(seconds: 20));
    final duration = await player.stream.duration
        .firstWhere((value) => value > Duration.zero)
        .timeout(const Duration(seconds: 10));
    final audioParams = await audioParamsFuture;
    final position = await player.stream.position
        .firstWhere((value) => value > Duration.zero)
        .timeout(const Duration(seconds: 10));
    await advancedPosition.future.timeout(const Duration(seconds: 10));

    expect(duration, greaterThan(Duration.zero));
    if (expectedSampleRateHz != null) {
      expect(audioParams.sampleRate, expectedSampleRateHz);
    }
    if (expectedChannelCount != null) {
      expect(audioParams.channelCount, expectedChannelCount);
    }
    expect(position, greaterThan(Duration.zero));
    expect(positions.length, greaterThanOrEqualTo(2));
    expect(positions[1], greaterThan(positions[0]));
    expect(errors, isEmpty);
  } finally {
    await errorSubscription?.cancel();
    await positionSubscription?.cancel();
    if (playerCreated) await player.dispose();
  }
}

Future<void> _verifyNativeVideoPlayback(File mp4) async {
  expect(await mp4.exists(), isTrue);
  expect(mp4.path.toLowerCase(), endsWith('.mp4'));

  final appDataDirectory = await Directory.systemTemp.createTemp(
    'yixue-video-history-smoke-',
  );
  try {
    final recordingsDirectory = Directory(
      '${appDataDirectory.path}${Platform.pathSeparator}'
      'simultaneous-interpretation${Platform.pathSeparator}'
      'video-recordings',
    );
    await recordingsDirectory.create(recursive: true);
    const sessionId = '6b5f141d-fb43-4925-95da-fc095654d252';
    const recordingName = 'screen-20261105-090000-$sessionId-1234-56789.mp4';
    final historyFile = await mp4.copy(
      '${recordingsDirectory.path}${Platform.pathSeparator}$recordingName',
    );

    final indexed = await SubtitleVideoRecordingIndex.list(
      appDataDirectory: appDataDirectory,
    );
    expect(indexed, hasLength(1));
    expect(indexed.single.fileName, recordingName);
    expect(indexed.single.sessionId, sessionId);
    expect(indexed.single.isIncomplete, isFalse);
    expect(indexed.single.canAttemptPlayback, isTrue);

    final playable = await SubtitleVideoRecordingIndex.resolvePlayableRecording(
      appDataDirectory: appDataDirectory,
      fileName: recordingName,
    );
    expect(playable?.path, historyFile.path);
    await _verifyDecodedNativeVideoPlayback(playable!);
  } finally {
    await appDataDirectory.delete(recursive: true);
  }
}

Future<void> _verifyDecodedNativeVideoPlayback(File mp4) async {
  expect(await mp4.exists(), isTrue);
  expect(mp4.path.toLowerCase(), endsWith('.mp4'));

  late final Player player;
  var playerCreated = false;
  final errors = <String>[];
  final playerLogs = <String>[];
  final positions = <Duration>[];
  final advancedPosition = Completer<void>();
  StreamSubscription<String>? errorSubscription;
  StreamSubscription<Duration>? positionSubscription;
  StreamSubscription<dynamic>? logSubscription;

  try {
    MediaKit.ensureInitialized();
    player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        logLevel: MPVLogLevel.debug,
      ),
    );
    playerCreated = true;
    errorSubscription = player.stream.error.listen((value) {
      if (value.trim().isNotEmpty) errors.add(value);
    });
    positionSubscription = player.stream.position.listen((value) {
      if (value > Duration.zero &&
          (positions.isEmpty || value > positions.last)) {
        positions.add(value);
        if (positions.length >= 2 && !advancedPosition.isCompleted) {
          advancedPosition.complete();
        }
      }
    });
    logSubscription = player.stream.log.listen((value) {
      playerLogs.add(value.toString());
    });

    // The production VideoController selects `vid=auto`; mirror that headless
    // setup without creating a Flutter texture in this native decoder smoke.
    await player.setVideoTrack(VideoTrack.auto());
    final videoParamsFuture = player.stream.videoParams
        .firstWhere(
          (value) =>
              value.w != null &&
              value.w! > 0 &&
              value.h != null &&
              value.h! > 0,
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException('''
MediaKit did not report decoded MP4 video dimensions.
Current player state: ${player.state}
Player errors: $errors
Recent player logs: ${playerLogs.reversed.take(80).toList().reversed.join('\n')}
'''),
        );
    final durationFuture = player.stream.duration
        .firstWhere((value) => value > Duration.zero)
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'MediaKit did not report a positive MP4 duration.',
          ),
        );
    final audioParamsFuture = player.stream.audioParams
        .firstWhere(
          (value) =>
              value.sampleRate != null &&
              value.sampleRate! > 0 &&
              value.channelCount != null &&
              value.channelCount! > 0,
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'MediaKit did not report decoded AAC audio parameters.',
          ),
        );
    await player
        .open(Media(mp4.absolute.uri.toString()), play: true)
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'MediaKit did not finish opening the synthetic MP4.',
          ),
        );

    final videoParams = await videoParamsFuture;
    final duration = await durationFuture;
    final audioParams = await audioParamsFuture;
    await advancedPosition.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException(
        'MediaKit opened the MP4 but playback position did not advance.',
      ),
    );

    expect(videoParams.w, greaterThan(0));
    expect(videoParams.h, greaterThan(0));
    expect(duration, greaterThan(Duration.zero));
    expect(audioParams.sampleRate, greaterThan(0));
    expect(audioParams.channelCount, greaterThan(0));
    expect(positions.length, greaterThanOrEqualTo(2));
    expect(positions[1], greaterThan(positions[0]));
    expect(errors, isEmpty);
  } finally {
    await errorSubscription?.cancel();
    await positionSubscription?.cancel();
    await logSubscription?.cancel();
    if (playerCreated) await player.dispose();
  }
}

Uint8List _silentPcmWave({required int channels, bool extensible = false}) {
  const sampleRate = 48000;
  const bitsPerSample = 16;
  const durationSeconds = 3;
  final dataLength =
      sampleRate * channels * (bitsPerSample ~/ 8) * durationSeconds;
  final formatLength = extensible ? 40 : 16;
  final headerLength = extensible ? 68 : 44;
  final bytes = Uint8List(headerLength + dataLength);
  final data = ByteData.sublistView(bytes);

  _writeAscii(bytes, 0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  _writeAscii(bytes, 8, 'WAVE');
  _writeAscii(bytes, 12, 'fmt ');
  data.setUint32(16, formatLength, Endian.little);
  data.setUint16(20, extensible ? 0xfffe : 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(
    28,
    sampleRate * channels * (bitsPerSample ~/ 8),
    Endian.little,
  );
  data.setUint16(32, channels * (bitsPerSample ~/ 8), Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  final dataHeaderOffset = extensible ? 60 : 36;
  final dataSizeOffset = extensible ? 64 : 40;
  if (extensible) {
    data.setUint16(36, 22, Endian.little);
    data.setUint16(38, bitsPerSample, Endian.little);
    data.setUint32(40, 0, Endian.little);
    data.setUint32(44, 1, Endian.little);
    data.setUint16(48, 0, Endian.little);
    data.setUint16(50, 0x0010, Endian.little);
    bytes.setRange(52, 60, const <int>[
      0x80,
      0x00,
      0x00,
      0xaa,
      0x00,
      0x38,
      0x9b,
      0x71,
    ]);
  }
  _writeAscii(bytes, dataHeaderOffset, 'data');
  data.setUint32(dataSizeOffset, dataLength, Endian.little);
  return bytes;
}

void _writeAscii(Uint8List target, int offset, String value) {
  for (var index = 0; index < value.length; index++) {
    target[offset + index] = value.codeUnitAt(index);
  }
}
