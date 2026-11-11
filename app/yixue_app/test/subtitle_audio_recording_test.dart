import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_audio_recording.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';

void main() {
  test(
    'empty lock-only session folders do not hide later audio history',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-history-empty-sessions-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));

      final recordingsRoot = Directory(
        '${appDataDirectory.path}${Platform.pathSeparator}'
        'simultaneous-interpretation${Platform.pathSeparator}recordings',
      );
      await recordingsRoot.create(recursive: true);
      const emptySessionCount = 250;
      final emptyDigests = List<String>.generate(
        emptySessionCount,
        (index) => (index + 1).toRadixString(16).padLeft(64, '0'),
      );
      for (final digest in emptyDigests) {
        final sessionDirectory = Directory(
          '${recordingsRoot.path}${Platform.pathSeparator}$digest',
        );
        await sessionDirectory.create();
        await File(
          '${sessionDirectory.path}${Platform.pathSeparator}.session.lock',
        ).create();
      }

      var sessionId = 'visible-after-empty-lock-directories';
      var digest = sha256.convert(utf8.encode(sessionId)).toString();
      for (
        var attempt = 0;
        digest.compareTo(emptyDigests.last) <= 0 && attempt < 100;
        attempt++
      ) {
        sessionId = 'visible-after-empty-lock-directories-$attempt';
        digest = sha256.convert(utf8.encode(sessionId)).toString();
      }
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        sessionId: sessionId,
        pcmBytes: Uint8List(3200),
        sampleRateHz: 16000,
        channelCount: 1,
      );
      expect(digest.compareTo(emptyDigests.last), greaterThan(0));

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );

      expect(recordings, hasLength(1));
      expect(recordings.single.sessionId, fixture.sessionId);
      expect(recordings.single.files, isEmpty);
      expect(recordings.single.recoveryCandidates, hasLength(1));
    },
  );

  test(
    'deleting a session with no recording root does not create one',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-delete-empty-root-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));

      final deleted =
          await SubtitleAudioSessionRecorder.deleteSessionRecordings(
            appDataDirectory: appDataDirectory,
            sessionId: 'session-without-audio',
          );

      expect(deleted, 0);
      expect(
        Directory(
          '${appDataDirectory.path}${Platform.pathSeparator}'
          'simultaneous-interpretation',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('checkpoints the WAV format and source path after the first audio frame', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-checkpoint-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));

    final recorder = SubtitleAudioSessionRecorder(
      appDataDirectory: appDataDirectory,
    );
    final frames = StreamController<AudioFrame>.broadcast();
    addTearDown(frames.close);
    addTearDown(recorder.dispose);

    await recorder.start(
      sessionId: 'checkpoint-session',
      captureAttemptId: 'capture-1',
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
    frames.add(_audioFrame(sessionId: 'checkpoint-session'));
    await checkpointed.timeout(const Duration(seconds: 5));

    final manifestPath = recorder.state.manifestRelativePath!;
    final manifest = jsonDecode(
      await File(
        '${appDataDirectory.path}/${manifestPath.replaceAll('/', Platform.pathSeparator)}',
      ).readAsString(),
    ) as Map<String, dynamic>;
    final source = (manifest['sources'] as List).single as Map<String, dynamic>;

    expect(manifest['status'], 'recording');
    expect(source['relativePath'], isA<String>());
    expect(source['sampleRateHz'], 16000);
    expect(source['channelCount'], 1);
    expect(source['dataBytes'], 3200);
  });

  test(
    'records multichannel WASAPI audio in an extensible WAV container',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-extensible-wav-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));

      final recorder = SubtitleAudioSessionRecorder(
        appDataDirectory: appDataDirectory,
      );
      final frames = StreamController<AudioFrame>.broadcast();
      addTearDown(frames.close);
      addTearDown(recorder.dispose);

      await recorder.start(
        sessionId: 'surround-session',
        captureAttemptId: 'capture-1',
        sources: <SubtitleSessionAudioSource>[
          SubtitleSessionAudioSource(
            sourceId: 'windows-system-output',
            sourceKind: SubtitleAudioSourceKind.systemOutput,
          ),
        ],
        frames: frames.stream,
      );
      final written = recorder.states.firstWhere(
        (state) => state.sources.single.dataBytes == 19200,
      );
      frames.add(
        _audioFrame(
          sessionId: 'surround-session',
          channelCount: 6,
          channelMask: 0x3f,
        ),
      );
      await written.timeout(const Duration(seconds: 5));
      await recorder.stop();

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );
      final recordingFile = recordings.single.files.single;
      final bytes = await recordingFile.file.readAsBytes();
      final header = ByteData.sublistView(bytes);

      expect(recordingFile.channelCount, 6);
      expect(recordingFile.channelMask, 0x3f);
      expect(recordingFile.headerBytes, 68);
      expect(bytes.length, 19268);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(header.getUint32(16, Endian.little), 40);
      expect(header.getUint16(20, Endian.little), 0xfffe);
      expect(header.getUint16(22, Endian.little), 6);
      expect(header.getUint32(40, Endian.little), 0x3f);
      expect(String.fromCharCodes(bytes.sublist(60, 64)), 'data');
      expect(header.getUint32(64, Endian.little), 19200);
    },
  );

  test(
    'records multichannel audio with an unspecified speaker layout',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-unspecified-layout-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final recorder = SubtitleAudioSessionRecorder(
        appDataDirectory: appDataDirectory,
      );
      final frames = StreamController<AudioFrame>.broadcast();
      addTearDown(frames.close);
      addTearDown(recorder.dispose);

      await recorder.start(
        sessionId: 'surround-session-unknown-layout',
        captureAttemptId: 'capture-1',
        sources: <SubtitleSessionAudioSource>[
          SubtitleSessionAudioSource(
            sourceId: 'windows-system-output',
            sourceKind: SubtitleAudioSourceKind.systemOutput,
          ),
        ],
        frames: frames.stream,
      );
      final written = recorder.states.firstWhere(
        (state) => state.sources.single.dataBytes == 19200,
      );
      frames.add(
        _audioFrame(
          sessionId: 'surround-session-unknown-layout',
          channelCount: 6,
        ),
      );
      await written.timeout(const Duration(seconds: 5));
      await recorder.stop();

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );
      final recordingFile = recordings.single.files.single;
      final bytes = await recordingFile.file.readAsBytes();
      final header = ByteData.sublistView(bytes);

      expect(recordingFile.channelCount, 6);
      expect(recordingFile.channelMask, 0);
      expect(recordingFile.headerBytes, 68);
      expect(bytes.length, 19268);
      expect(header.getUint32(40, Endian.little), 0);
      expect(header.getUint32(64, Endian.little), 19200);
    },
  );

  test('audio retention accepts only the active capture attempt and resets sequence per attempt', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-capture-attempts-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));

    final recorder = SubtitleAudioSessionRecorder(
      appDataDirectory: appDataDirectory,
    );
    final frames = StreamController<AudioFrame>.broadcast(sync: true);
    addTearDown(frames.close);
    addTearDown(recorder.dispose);

    await recorder.start(
      sessionId: 'capture-attempt-session',
      captureAttemptId: 'attempt-1',
      sources: <SubtitleSessionAudioSource>[
        SubtitleSessionAudioSource(
          sourceId: 'windows-system-output',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        ),
      ],
      frames: frames.stream,
    );

    AudioFrame frame(String attemptId, int sequence) => AudioFrame(
      sessionId: 'capture-attempt-session',
      captureAttemptId: attemptId,
      sourceId: 'windows-system-output',
      sourceKind: SubtitleAudioSourceKind.systemOutput,
      sequence: sequence,
      startTimeUs: sequence * 100000,
      sampleRateHz: 16000,
      channelCount: 1,
      sampleCount: 1600,
      sampleFormat: AudioPcmSampleFormat.signedInt16LittleEndian,
      pcmBytes: Uint8List(3200),
    );

    // Queue several frames across attempt changes before the async file
    // writer gets a turn. Accepted old-attempt frames must stay FIFO, while
    // frames from a paused/stale native capture are rejected at arrival.
    frames.add(frame('attempt-1', 0));
    frames.add(frame('attempt-1', 1));

    recorder.setCaptureAttemptId(null);
    frames.add(frame('attempt-1', 2));

    recorder.setCaptureAttemptId('attempt-2');
    frames.add(frame('attempt-2', 0));
    frames.add(frame('attempt-2', 1));

    recorder.setCaptureAttemptId('attempt-3');
    frames.add(frame('attempt-2', 2));
    frames.add(frame('attempt-3', 0));
    frames.add(frame('attempt-3', 1));

    final stopped = await recorder.stop();
    expect(stopped.status, SubtitleAudioRecordingStatus.stopped);
    expect(stopped.sources.single.framesWritten, 6);
    expect(stopped.sources.single.dataBytes, 19200);
    expect(stopped.sources.single.discontinuities, 2);
  });

  test(
    'completed recording with an empty WAV is visible but not playable',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-empty-wav-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        sessionId: 'empty-wav-session',
        pcmBytes: Uint8List(0),
        sampleRateHz: 16000,
        channelCount: 1,
        headerBytes: _buildPcm16WavHeader(
          sampleRateHz: 16000,
          channelCount: 1,
          dataBytes: 0,
        ),
        status: 'completed',
      );

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );

      expect(recordings, hasLength(1));
      expect(
        recordings.single.status,
        SubtitleAudioIndexedRecordingStatus.completed,
      );
      expect(recordings.single.files, isEmpty);
      expect(recordings.single.emptyAudioSources, 1);
    },
  );

  test(
    'completed capture with no audio frames remains visible in history',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-no-frames-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));

      final recorder = SubtitleAudioSessionRecorder(
        appDataDirectory: appDataDirectory,
      );
      final frames = StreamController<AudioFrame>.broadcast();
      addTearDown(frames.close);
      addTearDown(recorder.dispose);
      await recorder.start(
        sessionId: 'no-audio-frames-session',
        captureAttemptId: 'capture-1',
        sources: <SubtitleSessionAudioSource>[
          SubtitleSessionAudioSource(
            sourceId: 'windows-system-output',
            sourceKind: SubtitleAudioSourceKind.systemOutput,
          ),
        ],
        frames: frames.stream,
      );
      final stopped = await recorder.stop();
      expect(stopped.status, SubtitleAudioRecordingStatus.stopped);

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );

      expect(recordings, hasLength(1));
      expect(recordings.single.files, isEmpty);
      expect(recordings.single.emptyAudioSources, 1);
    },
  );

  test(
    'recovers uncheckpointed extensible WAV using its embedded PCM format',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-recovery-uncheckpointed-format-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final pcmBytes = Uint8List.fromList(
        List<int>.generate(1600 * 6 * 2, (index) => index % 251),
      );
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: pcmBytes,
        headerBytes: _buildExtensiblePcm16WavHeader(
          sampleRateHz: 16000,
          channelCount: 6,
          channelMask: 0,
          dataBytes: 0,
        ),
      );

      final indexed = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );
      expect(indexed.single.recoveryCandidates, hasLength(1));
      expect(indexed.single.recoveryCandidates.single.headerBytes, 68);
      expect(
        indexed.single.recoveryCandidates.single.dataBytes,
        pcmBytes.length,
      );
      expect(indexed.single.recoveryCandidates.single.sampleRateHz, 16000);
      expect(indexed.single.recoveryCandidates.single.channelCount, 6);

      final recoveredId =
          await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
            appDataDirectory: appDataDirectory,
            sessionId: fixture.sessionId,
            recordingId: fixture.recordingId,
            sourceId: fixture.sourceId,
            sourceKind: SubtitleAudioSourceKind.systemOutput,
          );
      final recovered = (await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      )).singleWhere((recording) => recording.recordingId == recoveredId);
      expect(recovered.files.single.headerBytes, 68);
      expect(recovered.files.single.channelCount, 6);
      expect(
        (await recovered.files.single.file.readAsBytes()).sublist(68),
        pcmBytes,
      );
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
    },
  );

  test(
    'does not offer classic or extensible header-only WAV as recoverable audio',
    () async {
      final emptyHeaders = <Uint8List>[
        _buildPcm16WavHeader(
          sampleRateHz: 16000,
          channelCount: 1,
          dataBytes: 0,
        ),
        _buildExtensiblePcm16WavHeader(
          sampleRateHz: 16000,
          channelCount: 6,
          channelMask: 0,
          dataBytes: 0,
        ),
      ];
      for (final headerBytes in emptyHeaders) {
        final appDataDirectory = await Directory.systemTemp.createTemp(
          'yixue-audio-recovery-header-only-',
        );
        addTearDown(() => appDataDirectory.delete(recursive: true));
        final fixture = await _createInterruptedFixture(
          appDataDirectory: appDataDirectory,
          sessionId: 'header-only-${headerBytes.length}',
          pcmBytes: Uint8List(0),
          headerBytes: headerBytes,
        );

        final indexed = await SubtitleAudioSessionRecorder.listSavedRecordings(
          appDataDirectory: appDataDirectory,
        );
        expect(indexed, hasLength(1));
        expect(indexed.single.files, isEmpty);
        expect(indexed.single.recoveryCandidates, isEmpty);
        expect(indexed.single.emptyAudioSources, 1);

        await expectLater(
          SubtitleAudioSessionRecorder.recoverInterruptedRecording(
            appDataDirectory: appDataDirectory,
            sessionId: fixture.sessionId,
            recordingId: fixture.recordingId,
            sourceId: fixture.sourceId,
            sourceKind: SubtitleAudioSourceKind.systemOutput,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
        final afterRecovery =
            await SubtitleAudioSessionRecorder.listSavedRecordings(
              appDataDirectory: appDataDirectory,
            );
        expect(afterRecovery.single.files, isEmpty);
        expect(afterRecovery.single.recoveryCandidates, isEmpty);
        expect(afterRecovery.single.emptyAudioSources, 1);
      }
    },
  );

  test(
    'keeps legacy interrupted raw PCM visible without guessing its format',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-recovery-index-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );

      expect(recordings, hasLength(1));
      expect(
        recordings.single.status,
        SubtitleAudioIndexedRecordingStatus.interrupted,
      );
      expect(recordings.single.files, isEmpty);
      expect(recordings.single.recoveryCandidates, hasLength(1));
      expect(recordings.single.recoveryCandidates.single.dataBytes, 4);
      expect(recordings.single.recoveryCandidates.single.sampleRateHz, isNull);
      expect(recordings.single.recoveryCandidates.single.channelCount, isNull);
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
    },
  );

  test(
    'refuses to delete an interrupted recording while recovery PCM exists',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-recovery-protect-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List(3200),
        sampleRateHz: 16000,
        channelCount: 1,
      );

      await expectLater(
        SubtitleAudioSessionRecorder.deleteRecording(
          appDataDirectory: appDataDirectory,
          sessionId: fixture.sessionId,
          recordingId: fixture.recordingId,
        ),
        throwsA(isA<StateError>()),
      );

      expect(await fixture.rawFile.exists(), isTrue);
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
    },
  );

  test(
    'recovers a zero-placeholder WAV into a copy and preserves the source',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-recovery-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List(3200),
        sampleRateHz: 16000,
        channelCount: 1,
      );

      final recoveredRecordingId =
          await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
            appDataDirectory: appDataDirectory,
            sessionId: fixture.sessionId,
            recordingId: fixture.recordingId,
            sourceId: fixture.sourceId,
            sourceKind: SubtitleAudioSourceKind.systemOutput,
          );
      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );
      final recovered = recordings.singleWhere(
        (recording) => recording.recordingId == recoveredRecordingId,
      );

      expect(recovered.files, hasLength(1));
      expect(recovered.files.single.sampleRateHz, 16000);
      expect(recovered.files.single.channelCount, 1);
      expect(recovered.files.single.dataBytes, 3200);
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
      expect(await recovered.files.single.file.length(), 3244);
    },
  );

  test('recovers legacy multichannel PCM into extensible WAV without changing source', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-recovery-surround-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final fixture = await _createInterruptedFixture(
      appDataDirectory: appDataDirectory,
      pcmBytes: Uint8List(1600 * 6 * 2),
      sampleRateHz: 16000,
      channelCount: 6,
    );

    final recoveredRecordingId =
        await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
          appDataDirectory: appDataDirectory,
          sessionId: fixture.sessionId,
          recordingId: fixture.recordingId,
          sourceId: fixture.sourceId,
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        );
    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    final recovered = recordings.singleWhere(
      (recording) => recording.recordingId == recoveredRecordingId,
    );

    expect(recovered.files, hasLength(1));
    expect(recovered.files.single.channelCount, 6);
    expect(recovered.files.single.channelMask, 0);
    expect(recovered.files.single.headerBytes, 68);
    expect(await recovered.files.single.file.length(), 19268);
    expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
  });

  test(
    'offers a copy upgrade for completed legacy multichannel PCM WAVs',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-completed-legacy-surround-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      const sampleRateHz = 16000;
      const channelCount = 6;
      final pcmBytes = Uint8List(1600 * channelCount * 2);
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: pcmBytes,
        sampleRateHz: sampleRateHz,
        channelCount: channelCount,
        headerBytes: _buildPcm16WavHeader(
          sampleRateHz: sampleRateHz,
          channelCount: channelCount,
          dataBytes: pcmBytes.length,
        ),
        status: 'completed',
      );

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );
      final legacy = recordings.single;
      expect(legacy.status, SubtitleAudioIndexedRecordingStatus.completed);
      expect(legacy.files, isEmpty);
      expect(legacy.recoveryCandidates, hasLength(1));
      expect(
        legacy.recoveryCandidates.single.legacyMultichannelUpgrade,
        isTrue,
      );

      final upgradedId =
          await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
            appDataDirectory: appDataDirectory,
            sessionId: fixture.sessionId,
            recordingId: fixture.recordingId,
            sourceId: fixture.sourceId,
            sourceKind: SubtitleAudioSourceKind.systemOutput,
            upgradeLegacyMultichannel: true,
          );
      final upgradedRecordings =
          await SubtitleAudioSessionRecorder.listSavedRecordings(
            appDataDirectory: appDataDirectory,
          );
      final upgraded = upgradedRecordings.singleWhere(
        (recording) => recording.recordingId == upgradedId,
      );

      expect(upgraded.status, SubtitleAudioIndexedRecordingStatus.completed);
      expect(upgraded.files, hasLength(1));
      expect(upgraded.files.single.headerBytes, 68);
      expect(upgraded.files.single.channelCount, channelCount);
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
    },
  );

  test(
    'recovers an interrupted extensible WAV with an unknown channel layout',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-recovery-extensible-unknown-layout-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List(1600 * 6 * 2),
        sampleRateHz: 16000,
        channelCount: 6,
        channelMask: 0,
        headerBytes: Uint8List(68),
      );

      final recoveredRecordingId =
          await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
            appDataDirectory: appDataDirectory,
            sessionId: fixture.sessionId,
            recordingId: fixture.recordingId,
            sourceId: fixture.sourceId,
            sourceKind: SubtitleAudioSourceKind.systemOutput,
          );
      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );
      final recovered = recordings.singleWhere(
        (recording) => recording.recordingId == recoveredRecordingId,
      );

      expect(recovered.files, hasLength(1));
      expect(recovered.files.single.channelCount, 6);
      expect(recovered.files.single.channelMask, 0);
      expect(recovered.files.single.headerBytes, 68);
      expect(await recovered.files.single.file.length(), 19268);
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
    },
  );

  test(
    'formal manifest takes precedence over valid temporary sidecars',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-manifest-primary-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List(3200),
        sampleRateHz: 16000,
        channelCount: 1,
      );
      final formal = jsonDecode(
        await fixture.manifestFile.readAsString(),
      ) as Map<String, dynamic>;
      final temporary = jsonDecode(jsonEncode(formal)) as Map<String, dynamic>;
      final temporarySource =
          (temporary['sources'] as List).single as Map<String, dynamic>;
      temporarySource['sampleRateHz'] = 8000;
      await File('${fixture.manifestFile.path}.tmp')
          .writeAsString(jsonEncode(temporary), flush: true);
      await File('${fixture.manifestFile.path}.bak')
          .writeAsString(jsonEncode(temporary), flush: true);

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );

      expect(recordings, hasLength(1));
      expect(recordings.single.recoveryCandidates, hasLength(1));
      expect(recordings.single.recoveryCandidates.single.sampleRateHz, 16000);
    },
  );

  test('uses a valid backup when the formal manifest is missing', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-manifest-backup-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final fixture = await _createInterruptedFixture(
      appDataDirectory: appDataDirectory,
      pcmBytes: Uint8List(3200),
      sampleRateHz: 16000,
      channelCount: 1,
    );
    final formalText = await fixture.manifestFile.readAsString();
    await fixture.manifestFile.delete();
    await File('${fixture.manifestFile.path}.tmp').writeAsString('{broken');
    await File('${fixture.manifestFile.path}.bak')
        .writeAsString(formalText, flush: true);

    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    expect(recordings, hasLength(1));
    expect(recordings.single.recoveryCandidates, hasLength(1));

    final recoveredId =
        await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
          appDataDirectory: appDataDirectory,
          sessionId: fixture.sessionId,
          recordingId: fixture.recordingId,
          sourceId: fixture.sourceId,
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        );
    expect(recoveredId, isNot(fixture.recordingId));
    expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
  });

  test(
    'uses a valid temporary manifest when the formal manifest is missing',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-manifest-temporary-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List(3200),
        sampleRateHz: 16000,
        channelCount: 1,
      );
      final temporary = jsonDecode(
        await fixture.manifestFile.readAsString(),
      ) as Map<String, dynamic>;
      final backupText = jsonEncode(temporary);
      final temporarySource =
          (temporary['sources'] as List).single as Map<String, dynamic>;
      temporarySource['sampleRateHz'] = 8000;
      await fixture.manifestFile.delete();
      await File('${fixture.manifestFile.path}.tmp')
          .writeAsString(jsonEncode(temporary), flush: true);
      await File('${fixture.manifestFile.path}.bak')
          .writeAsString(backupText, flush: true);

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );

      expect(recordings, hasLength(1));
      expect(recordings.single.recoveryCandidates, hasLength(1));
      expect(recordings.single.recoveryCandidates.single.sampleRateHz, 8000);
    },
  );

  test(
    'rejects malformed fallback manifests without changing source PCM',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-manifest-invalid-fallback-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List(3200),
        sampleRateHz: 16000,
        channelCount: 1,
      );
      final malformed = jsonDecode(
        await fixture.manifestFile.readAsString(),
      ) as Map<String, dynamic>;
      final malformedSource =
          (malformed['sources'] as List).single as Map<String, dynamic>;
      malformedSource['relativePath'] = '../outside.wav';
      await fixture.manifestFile.delete();
      await File('${fixture.manifestFile.path}.tmp')
          .writeAsString(jsonEncode(malformed), flush: true);
      await File('${fixture.manifestFile.path}.bak')
          .writeAsString(jsonEncode(malformed), flush: true);

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );
      expect(recordings, isEmpty);
      await expectLater(
        SubtitleAudioSessionRecorder.recoverInterruptedRecording(
          appDataDirectory: appDataDirectory,
          sessionId: fixture.sessionId,
          recordingId: fixture.recordingId,
          sourceId: fixture.sourceId,
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
      expect(
        await fixture.rawFile.parent.list().where((entity) {
          return entity is Directory &&
              entity.path != fixture.rawFile.parent.path;
        }).toList(),
        isEmpty,
      );
    },
  );

  test('rejects out-of-range fallback audio metadata', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-manifest-out-of-range-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final fixture = await _createInterruptedFixture(
      appDataDirectory: appDataDirectory,
      pcmBytes: Uint8List(3200),
      sampleRateHz: 16000,
      channelCount: 1,
    );
    final malformed = jsonDecode(
      await fixture.manifestFile.readAsString(),
    ) as Map<String, dynamic>;
    final malformedSource =
        (malformed['sources'] as List).single as Map<String, dynamic>;
    malformedSource['sampleRateHz'] = 0x7fffffff;
    final malformedText = jsonEncode(malformed);
    await fixture.manifestFile.delete();
    await File('${fixture.manifestFile.path}.tmp')
        .writeAsString(malformedText, flush: true);
    await File('${fixture.manifestFile.path}.bak')
        .writeAsString(malformedText, flush: true);

    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    expect(recordings, isEmpty);
    await expectLater(
      SubtitleAudioSessionRecorder.recoverInterruptedRecording(
        appDataDirectory: appDataDirectory,
        sessionId: fixture.sessionId,
        recordingId: fixture.recordingId,
        sourceId: fixture.sourceId,
        sourceKind: SubtitleAudioSourceKind.systemOutput,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
  });

  test(
    'does not use sidecars when a formal manifest exists but is invalid',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-invalid-formal-manifest-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List(3200),
        sampleRateHz: 16000,
        channelCount: 1,
      );
      final backup = await fixture.manifestFile.readAsString();
      await fixture.manifestFile.writeAsString('{broken', flush: true);
      await File('${fixture.manifestFile.path}.bak')
          .writeAsString(backup, flush: true);

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );

      expect(recordings, isEmpty);
      await expectLater(
        SubtitleAudioSessionRecorder.recoverInterruptedRecording(
          appDataDirectory: appDataDirectory,
          sessionId: fixture.sessionId,
          recordingId: fixture.recordingId,
          sourceId: fixture.sourceId,
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
    },
  );

  test('recovers a valid partial WAV header into a copy', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-partial-header-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final pcmBytes = Uint8List(3200);
    final expectedHeader = _buildPcm16WavHeader(
      sampleRateHz: 16000,
      channelCount: 1,
      dataBytes: pcmBytes.length,
    );
    final partialHeader = Uint8List(44);
    partialHeader.setRange(0, 17, expectedHeader);
    final fixture = await _createInterruptedFixture(
      appDataDirectory: appDataDirectory,
      pcmBytes: pcmBytes,
      sampleRateHz: 16000,
      channelCount: 1,
      headerBytes: partialHeader,
    );

    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    expect(recordings, hasLength(1));
    expect(recordings.single.recoveryCandidates, hasLength(1));

    final recoveredId =
        await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
          appDataDirectory: appDataDirectory,
          sessionId: fixture.sessionId,
          recordingId: fixture.recordingId,
          sourceId: fixture.sourceId,
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        );
    final recovered = (await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    )).singleWhere((recording) => recording.recordingId == recoveredId);
    expect(recovered.files, hasLength(1));
    expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
  });

  test(
    'accepts an exact finalized WAV header with nonzero high size bytes',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-large-finalized-header-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      // Crossing 16 MiB sets a high byte in the WAV data-size field. A complete
      // finalized header must match exactly even though recovery normally also
      // accepts a prefix followed by a zeroed placeholder tail.
      final pcmBytes = Uint8List(16 * 1024 * 1024);
      final header = _buildPcm16WavHeader(
        sampleRateHz: 16000,
        channelCount: 1,
        dataBytes: pcmBytes.length,
      );
      await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: pcmBytes,
        sampleRateHz: 16000,
        channelCount: 1,
        headerBytes: header,
      );

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );

      expect(recordings, hasLength(1));
      // A complete, exact WAV header is already playable and should be indexed
      // as a file. Recovery candidates are only for a zeroed or partial header
      // where the payload is still raw PCM.
      expect(recordings.single.files, hasLength(1));
      expect(recordings.single.files.single.dataBytes, pcmBytes.length);
      expect(recordings.single.recoveryCandidates, isEmpty);
    },
  );

  test('rejects an arbitrary damaged WAV header as interrupted PCM', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-damaged-header-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final damagedHeader = Uint8List(44);
    damagedHeader[0] = 0xff;
    final fixture = await _createInterruptedFixture(
      appDataDirectory: appDataDirectory,
      pcmBytes: Uint8List(3200),
      sampleRateHz: 16000,
      channelCount: 1,
      headerBytes: damagedHeader,
    );

    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    expect(recordings, hasLength(1));
    expect(recordings.single.files, isEmpty);
    expect(recordings.single.recoveryCandidates, isEmpty);
    await expectLater(
      SubtitleAudioSessionRecorder.recoverInterruptedRecording(
        appDataDirectory: appDataDirectory,
        sessionId: fixture.sessionId,
        recordingId: fixture.recordingId,
        sourceId: fixture.sourceId,
        sourceKind: SubtitleAudioSourceKind.systemOutput,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
  });

  test(
    'rejects misaligned interrupted PCM without changing the source',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-recovery-invalid-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));
      final fixture = await _createInterruptedFixture(
        appDataDirectory: appDataDirectory,
        pcmBytes: Uint8List.fromList(<int>[1, 2, 3]),
        sampleRateHz: 16000,
        channelCount: 1,
      );

      await expectLater(
        SubtitleAudioSessionRecorder.recoverInterruptedRecording(
          appDataDirectory: appDataDirectory,
          sessionId: fixture.sessionId,
          recordingId: fixture.recordingId,
          sourceId: fixture.sourceId,
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
    },
  );

  test('recovers PCM written after the last manifest checkpoint', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-recovery-after-checkpoint-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final pcmBytes = Uint8List(6400);
    for (var index = 0; index < pcmBytes.length; index++) {
      pcmBytes[index] = index % 251;
    }
    final fixture = await _createInterruptedFixture(
      appDataDirectory: appDataDirectory,
      pcmBytes: pcmBytes,
      sampleRateHz: 16000,
      channelCount: 1,
    );
    final manifest = jsonDecode(
      await fixture.manifestFile.readAsString(),
    ) as Map<String, dynamic>;
    final source = (manifest['sources'] as List).single as Map<String, dynamic>;
    // The first 3200-byte frame was checkpointed. A later frame reached the
    // PCM file, but the process ended before the manifest was rewritten.
    source['dataBytes'] = 3200;
    source['samplesPerChannel'] = 1600;
    source['framesWritten'] = 1;
    await fixture.manifestFile.writeAsString(jsonEncode(manifest), flush: true);

    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    expect(recordings, hasLength(1));
    expect(recordings.single.recoveryCandidates, hasLength(1));
    expect(recordings.single.recoveryCandidates.single.dataBytes, 6400);

    final recoveredId =
        await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
          appDataDirectory: appDataDirectory,
          sessionId: fixture.sessionId,
          recordingId: fixture.recordingId,
          sourceId: fixture.sourceId,
          sourceKind: SubtitleAudioSourceKind.systemOutput,
        );
    final recovered = (await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    )).singleWhere((recording) => recording.recordingId == recoveredId);
    expect(recovered.files, hasLength(1));
    expect(recovered.files.single.dataBytes, 6400);
    final recoveredBytes = await recovered.files.single.file.readAsBytes();
    expect(recoveredBytes.sublist(44), pcmBytes);
    expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
  });

  test('rejects interrupted PCM shorter than checkpointed metadata', () async {
    final appDataDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-recovery-metadata-mismatch-',
    );
    addTearDown(() => appDataDirectory.delete(recursive: true));
    final fixture = await _createInterruptedFixture(
      appDataDirectory: appDataDirectory,
      pcmBytes: Uint8List(3200),
      sampleRateHz: 16000,
      channelCount: 1,
    );
    final manifest = jsonDecode(
      await fixture.manifestFile.readAsString(),
    ) as Map<String, dynamic>;
    final source = (manifest['sources'] as List).single as Map<String, dynamic>;
    source['dataBytes'] = 3202;
    source['samplesPerChannel'] = 1601;
    await fixture.manifestFile.writeAsString(jsonEncode(manifest), flush: true);

    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    expect(recordings, hasLength(1));
    expect(recordings.single.recoveryCandidates, isEmpty);
    await expectLater(
      SubtitleAudioSessionRecorder.recoverInterruptedRecording(
        appDataDirectory: appDataDirectory,
        sessionId: fixture.sessionId,
        recordingId: fixture.recordingId,
        sourceId: fixture.sourceId,
        sourceKind: SubtitleAudioSourceKind.systemOutput,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await fixture.rawFile.readAsBytes(), fixture.originalBytes);
  });

  test('audio retention can retry after a clean startup failure', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'yixue-audio-retry-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final blockedRoot = File('${temporaryDirectory.path}/app-data');
    await blockedRoot.writeAsString('not a directory');
    final appDataDirectory = Directory(blockedRoot.path);
    final recorder = SubtitleAudioSessionRecorder(
      appDataDirectory: appDataDirectory,
    );
    final frames = StreamController<AudioFrame>.broadcast();
    addTearDown(frames.close);
    addTearDown(recorder.dispose);
    final sources = <SubtitleSessionAudioSource>[
      SubtitleSessionAudioSource(
        sourceId: 'windows-system-output',
        sourceKind: SubtitleAudioSourceKind.systemOutput,
      ),
    ];

    await expectLater(
      recorder.start(
        sessionId: 'first-attempt',
        captureAttemptId: 'capture-1',
        sources: sources,
        frames: frames.stream,
      ),
      throwsA(isA<Object>()),
    );
    expect(recorder.state.status, SubtitleAudioRecordingStatus.failed);

    await blockedRoot.delete();
    await appDataDirectory.create();
    final started = await recorder.start(
      sessionId: 'retry-attempt',
      captureAttemptId: 'capture-1',
      sources: sources,
      frames: frames.stream,
    );
    expect(started.status, SubtitleAudioRecordingStatus.recording);

    frames.add(
      AudioFrame(
        sessionId: 'retry-attempt',
        captureAttemptId: 'capture-1',
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
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final stopped = await recorder.stop();
    expect(stopped.status, SubtitleAudioRecordingStatus.stopped);
    expect(stopped.sources.single.framesWritten, 1);

    final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    expect(recordings, hasLength(1));
    expect(recordings.single.files, hasLength(1));
  });

  test(
    'unconfirmed capture stop keeps finalized audio marked incomplete',
    () async {
      final appDataDirectory = await Directory.systemTemp.createTemp(
        'yixue-audio-unconfirmed-stop-',
      );
      addTearDown(() => appDataDirectory.delete(recursive: true));

      final recorder = SubtitleAudioSessionRecorder(
        appDataDirectory: appDataDirectory,
      );
      final frames = StreamController<AudioFrame>.broadcast();
      addTearDown(frames.close);
      addTearDown(recorder.dispose);

      await recorder.start(
        sessionId: 'unconfirmed-stop-session',
        captureAttemptId: 'capture-1',
        sources: <SubtitleSessionAudioSource>[
          SubtitleSessionAudioSource(
            sourceId: 'windows-system-output',
            sourceKind: SubtitleAudioSourceKind.systemOutput,
          ),
        ],
        frames: frames.stream,
      );
      frames.add(
        AudioFrame(
          sessionId: 'unconfirmed-stop-session',
          captureAttemptId: 'capture-1',
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
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final stopped = await recorder.stop(
        failureReason: 'audio_capture_stop_unconfirmed',
      );
      expect(stopped.status, SubtitleAudioRecordingStatus.failed);
      expect(stopped.error, 'audio_capture_stop_unconfirmed');

      final recordings = await SubtitleAudioSessionRecorder.listSavedRecordings(
        appDataDirectory: appDataDirectory,
      );
      expect(recordings, hasLength(1));
      expect(
        recordings.single.status,
        SubtitleAudioIndexedRecordingStatus.failed,
      );
      expect(recordings.single.files, hasLength(1));
      expect(recordings.single.files.single.dataBytes, 3200);
    },
  );
}

AudioFrame _audioFrame({
  required String sessionId,
  int channelCount = 1,
  int? channelMask,
}) => AudioFrame(
  sessionId: sessionId,
  captureAttemptId: 'capture-1',
  sourceId: 'windows-system-output',
  sourceKind: SubtitleAudioSourceKind.systemOutput,
  sequence: 0,
  startTimeUs: 0,
  sampleRateHz: 16000,
  channelCount: channelCount,
  sampleCount: 1600,
  sampleFormat: AudioPcmSampleFormat.signedInt16LittleEndian,
  pcmBytes: Uint8List(1600 * channelCount * 2),
  channelMask: channelMask,
);

Future<_InterruptedFixture> _createInterruptedFixture({
  required Directory appDataDirectory,
  String sessionId = 'interrupted-session',
  required Uint8List pcmBytes,
  int? sampleRateHz,
  int? channelCount,
  Uint8List? headerBytes,
  int? channelMask,
  String status = 'recording',
}) async {
  const recordingId = '0123456789abcdef0123456789abcdef';
  const sourceId = 'windows-system-output';
  final sessionDigest = sha256.convert(utf8.encode(sessionId)).toString();
  final sourceDigest = sha256.convert(utf8.encode(sourceId)).toString();
  final separator = Platform.pathSeparator;
  final sessionDirectory = Directory(
    '${appDataDirectory.path}${separator}simultaneous-interpretation${separator}recordings${separator}$sessionDigest',
  );
  final recordingDirectory = Directory(
    '${sessionDirectory.path}${separator}$recordingId',
  );
  await recordingDirectory.create(recursive: true);
  await File('${sessionDirectory.path}${separator}.session.lock').create();
  final rawFile = File(
    '${recordingDirectory.path}${separator}systemOutput-$sourceDigest.wav',
  );
  final hasStoredFormat = sampleRateHz != null && channelCount != null;
  final expectedRelativePath =
      'simultaneous-interpretation/recordings/$sessionDigest/$recordingId/'
      'systemOutput-$sourceDigest.wav';
  final headerLength = headerBytes?.length ?? 44;
  final originalBytes = Uint8List(headerLength + pcmBytes.length);
  if (headerBytes != null) {
    if (headerBytes.length != 44 && headerBytes.length != 68) {
      throw ArgumentError.value(headerBytes.length, 'headerBytes.length');
    }
    originalBytes.setRange(0, headerLength, headerBytes);
  }
  originalBytes.setRange(headerLength, originalBytes.length, pcmBytes);
  await rawFile.writeAsBytes(originalBytes, flush: true);

  final manifestFile = File(
    '${recordingDirectory.path}${separator}manifest.json',
  );
  await manifestFile.writeAsString(
    jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'recordingId': recordingId,
      'sessionId': sessionId,
      'status': status,
      'format': 'wav-pcm-s16le',
      'startedAtUtc': '2026-10-19T00:00:00.000Z',
      'endedAtUtc': status == 'completed' ? '2026-10-19T00:01:00.000Z' : null,
      'error': null,
      'sources': <Object?>[
        <String, Object?>{
          'sourceId': sourceId,
          'sourceKind': 'systemOutput',
          'relativePath': hasStoredFormat ? expectedRelativePath : null,
          'container': hasStoredFormat ? 'wav' : null,
          'codec': hasStoredFormat ? 'pcm_s16le' : null,
          'sampleRateHz': sampleRateHz,
          'channelCount': channelCount,
          'channelMask': channelMask,
          'bitsPerSample': hasStoredFormat ? 16 : null,
          'dataBytes': hasStoredFormat ? pcmBytes.length : 0,
          'samplesPerChannel': hasStoredFormat
              ? pcmBytes.length ~/ (channelCount * 2)
              : 0,
          'framesWritten': hasStoredFormat && pcmBytes.isNotEmpty ? 1 : 0,
          'droppedFrames': 0,
          'discontinuities': 0,
          'firstSequence': null,
          'lastSequence': null,
          'startedAtUtc': hasStoredFormat ? '2026-10-19T00:00:00.000Z' : null,
          'endedAtUtc': null,
          'error': null,
        },
      ],
    }),
    flush: true,
  );
  return _InterruptedFixture(
    sessionId: sessionId,
    recordingId: recordingId,
    sourceId: sourceId,
    rawFile: rawFile,
    originalBytes: originalBytes,
    manifestFile: manifestFile,
  );
}

Uint8List _buildPcm16WavHeader({
  required int sampleRateHz,
  required int channelCount,
  required int dataBytes,
}) {
  final header = Uint8List(44);
  final data = ByteData.sublistView(header);
  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      header[offset + index] = value.codeUnitAt(index);
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, dataBytes + 36, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channelCount, Endian.little);
  data.setUint32(24, sampleRateHz, Endian.little);
  data.setUint32(28, sampleRateHz * channelCount * 2, Endian.little);
  data.setUint16(32, channelCount * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, dataBytes, Endian.little);
  return header;
}

Uint8List _buildExtensiblePcm16WavHeader({
  required int sampleRateHz,
  required int channelCount,
  required int channelMask,
  required int dataBytes,
}) {
  final header = Uint8List(68);
  final data = ByteData.sublistView(header);
  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      header[offset + index] = value.codeUnitAt(index);
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, dataBytes + 60, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 40, Endian.little);
  data.setUint16(20, 0xfffe, Endian.little);
  data.setUint16(22, channelCount, Endian.little);
  data.setUint32(24, sampleRateHz, Endian.little);
  data.setUint32(28, sampleRateHz * channelCount * 2, Endian.little);
  data.setUint16(32, channelCount * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint16(36, 22, Endian.little);
  data.setUint16(38, 16, Endian.little);
  data.setUint32(40, channelMask, Endian.little);
  header.setRange(44, 60, const <int>[
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x10,
    0x00,
    0x80,
    0x00,
    0x00,
    0xaa,
    0x00,
    0x38,
    0x9b,
    0x71,
  ]);
  writeAscii(60, 'data');
  data.setUint32(64, dataBytes, Endian.little);
  return header;
}

final class _InterruptedFixture {
  const _InterruptedFixture({
    required this.sessionId,
    required this.recordingId,
    required this.sourceId,
    required this.rawFile,
    required this.originalBytes,
    required this.manifestFile,
  });

  final String sessionId;
  final String recordingId;
  final String sourceId;
  final File rawFile;
  final Uint8List originalBytes;
  final File manifestFile;
}
