import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/streaming_asr_runtime.dart';
import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/streaming_asr.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';

const _expectedAutoCodes = <String, String>{
  'en-english.wav': 'en',
  'zh-chinese.wav': 'zh',
  'ja-japanese.wav': 'ja',
  'ko-korean.wav': 'ko',
  'fr-french.wav': 'und',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sampleDirectory = Platform.environment['YIXUE_ASR_TEST_WAVS'];
  final multilingualDirectory =
      Platform.environment['YIXUE_ASR_MULTILINGUAL_MODEL_DIR'];
  final bilingualDirectory =
      Platform.environment['YIXUE_ASR_BILINGUAL_MODEL_DIR'];
  final bilingualSampleDirectory =
      Platform.environment['YIXUE_ASR_BILINGUAL_TEST_WAVS'];
  final sherpaRuntimeDirectory =
      Platform.environment['YIXUE_SHERPA_RUNTIME_DIR'];
  final hasSherpaRuntimeDirectory =
      !Platform.isWindows || sherpaRuntimeDirectory != null;
  final hasMultilingualInputs =
      sampleDirectory != null &&
      multilingualDirectory != null &&
      hasSherpaRuntimeDirectory;
  final hasBilingualInputs =
      sampleDirectory != null &&
      bilingualDirectory != null &&
      bilingualSampleDirectory != null &&
      hasSherpaRuntimeDirectory;

  final hasBilingualModelStartupInputs =
      bilingualDirectory != null && hasSherpaRuntimeDirectory;

  test(
    'Zipformer model initializes without starting desktop audio capture',
    skip: hasBilingualModelStartupInputs
        ? false
        : 'Set YIXUE_ASR_BILINGUAL_MODEL_DIR and (on Windows) '
              'YIXUE_SHERPA_RUNTIME_DIR.',
    () async {
      _configureWindowsSherpaRuntime(sherpaRuntimeDirectory);
      final runtime = SherpaStreamingAsrRuntime(
        modelDirectory: Directory(bilingualDirectory!),
        numThreads: 2,
        workerTimeout: const Duration(minutes: 3),
      );
      final session = await runtime.openSession(
        sessionId: 'bilingual-model-startup-smoke',
        sourceId: 'fixture-audio',
        sourceKind: SubtitleAudioSourceKind.systemOutput,
        sourceLanguageCode: 'en',
      );

      try {
        expect(session.currentState.status, StreamingAsrStatus.ready);
      } finally {
        await session.close();
      }
      expect(session.currentState.status, StreamingAsrStatus.closed);
    },
  );

  test(
    'Whisper Auto labels English, Chinese, Japanese, Korean, and unknown speech',
    skip: hasMultilingualInputs
        ? false
        : 'Set YIXUE_ASR_TEST_WAVS, YIXUE_ASR_MULTILINGUAL_MODEL_DIR, '
              'and (on Windows) YIXUE_SHERPA_RUNTIME_DIR.',
    () async {
      _configureWindowsSherpaRuntime(sherpaRuntimeDirectory);
      final runtime = SherpaStreamingAsrRuntime(
        modelDirectory: Directory('unused-bilingual-model'),
        multilingualModelDirectory: Directory(multilingualDirectory!),
        numThreads: 2,
        workerTimeout: const Duration(minutes: 3),
      );
      final session = await runtime.openSession(
        sessionId: 'multilingual-smoke',
        sourceId: 'fixture-audio',
        sourceKind: SubtitleAudioSourceKind.microphone,
        sourceLanguageCode: 'auto',
      );
      final revisions = <TranscriptRevision>[];
      final subscription = session.revisions.listen(revisions.add);
      try {
        for (final entry in _expectedAutoCodes.entries) {
          final path =
              '${sampleDirectory!}${Platform.pathSeparator}${entry.key}';
          final wave = await _readPcm16Wave(File(path));
          final attemptId = 'auto-${entry.key}';
          session.beginCaptureAttempt(attemptId);
          await _feedWave(session, wave, attemptId, 'multilingual-smoke');
          await session.finishCaptureAttempt(attemptId);

          final recognized = revisions
              .where((revision) => revision.captureAttemptId == attemptId)
              .toList(growable: false);
          expect(recognized, isNotEmpty, reason: entry.key);
          expect(
            recognized.every((revision) => revision.isFinal),
            isTrue,
            reason: entry.key,
          );
          expect(
            recognized.every(
              (revision) => revision.languageCode == entry.value,
            ),
            isTrue,
            reason:
                '${entry.key}: ${recognized.map((revision) => revision.languageCode)}',
          );
          expect(
            recognized.every(
              (revision) =>
                  revision.startMs >= 0 && revision.endMs > revision.startMs,
            ),
            isTrue,
            reason: entry.key,
          );
          expect(
            recognized.every((revision) => revision.text.trim().isNotEmpty),
            isTrue,
            reason: entry.key,
          );
          // Report the sample result and timing evidence without treating a
          // small public fixture set as broad accuracy acceptance.
          // ignore: avoid_print
          print(
            'ASR_SMOKE ${entry.key} ${entry.value} '
            '${recognized.map((revision) => revision.text).join(' | ')} '
            'range=${recognized.first.startMs}-${recognized.last.endMs}ms',
          );
        }
      } finally {
        await subscription.cancel();
        await session.close();
      }
    },
  );

  test(
    'Whisper manual Japanese and Korean preserve selected language labels',
    skip: hasMultilingualInputs
        ? false
        : 'Set YIXUE_ASR_TEST_WAVS, YIXUE_ASR_MULTILINGUAL_MODEL_DIR, '
              'and (on Windows) YIXUE_SHERPA_RUNTIME_DIR.',
    () async {
      _configureWindowsSherpaRuntime(sherpaRuntimeDirectory);
      for (final entry in <({String file, String language})>[
        (file: 'ja-japanese.wav', language: 'ja'),
        (file: 'ko-korean.wav', language: 'ko'),
      ]) {
        final runtime = SherpaStreamingAsrRuntime(
          modelDirectory: Directory('unused-bilingual-model'),
          multilingualModelDirectory: Directory(multilingualDirectory!),
          numThreads: 2,
          workerTimeout: const Duration(minutes: 3),
        );
        final session = await runtime.openSession(
          sessionId: 'manual-${entry.language}',
          sourceId: 'fixture-audio',
          sourceKind: SubtitleAudioSourceKind.microphone,
          sourceLanguageCode: entry.language,
        );
        final revisions = <TranscriptRevision>[];
        final subscription = session.revisions.listen(revisions.add);
        try {
          final wave = await _readPcm16Wave(
            File('${sampleDirectory!}${Platform.pathSeparator}${entry.file}'),
          );
          final attemptId = 'manual-${entry.language}';
          session.beginCaptureAttempt(attemptId);
          await _feedWave(session, wave, attemptId, 'manual-${entry.language}');
          await session.finishCaptureAttempt(attemptId);
          final recognized = revisions
              .where((revision) => revision.captureAttemptId == attemptId)
              .toList(growable: false);
          expect(recognized, isNotEmpty, reason: entry.file);
          expect(
            recognized.every(
              (revision) => revision.languageCode == entry.language,
            ),
            isTrue,
            reason: entry.file,
          );
          expect(
            recognized.every((revision) => revision.text.trim().isNotEmpty),
            isTrue,
            reason: entry.file,
          );
        } finally {
          await subscription.cancel();
          await session.close();
        }
      }
    },
  );

  test(
    'Zipformer preserves streaming English and Chinese transcripts',
    skip: hasBilingualInputs
        ? false
        : 'Set YIXUE_ASR_TEST_WAVS, YIXUE_ASR_BILINGUAL_MODEL_DIR, '
              'YIXUE_ASR_BILINGUAL_TEST_WAVS, and (on Windows) '
              'YIXUE_SHERPA_RUNTIME_DIR.',
    () async {
      _configureWindowsSherpaRuntime(sherpaRuntimeDirectory);
      for (final entry in <({String file, String language})>[
        (file: '0.wav', language: 'en'),
        (file: '1.wav', language: 'zh'),
      ]) {
        final runtime = SherpaStreamingAsrRuntime(
          modelDirectory: Directory(bilingualDirectory!),
          numThreads: 2,
          workerTimeout: const Duration(minutes: 3),
        );
        final session = await runtime.openSession(
          sessionId: 'legacy-${entry.language}',
          sourceId: 'fixture-audio',
          sourceKind: SubtitleAudioSourceKind.microphone,
          sourceLanguageCode: entry.language,
        );
        final revisions = <TranscriptRevision>[];
        final subscription = session.revisions.listen(revisions.add);
        try {
          final wave = await _readPcm16Wave(
            File(
              '${bilingualSampleDirectory!}${Platform.pathSeparator}${entry.file}',
            ),
          );
          final attemptId = 'legacy-${entry.language}';
          session.beginCaptureAttempt(attemptId);
          await _feedWave(
            session,
            wave,
            attemptId,
            'legacy-${entry.language}',
            paceFrames: true,
          );
          await session.finishCaptureAttempt(attemptId);
          final recognized = revisions
              .where((revision) => revision.captureAttemptId == attemptId)
              .toList(growable: false);
          expect(recognized, isNotEmpty, reason: entry.file);
          expect(
            recognized.every(
              (revision) => revision.languageCode == entry.language,
            ),
            isTrue,
            reason: entry.file,
          );
          expect(
            recognized.any((revision) => revision.text.trim().isNotEmpty),
            isTrue,
            reason: entry.file,
          );
          // ignore: avoid_print
          print(
            'ASR_SMOKE zipformer-${entry.language} ${entry.file} '
            '${recognized.map((revision) => revision.text).join(' | ')}',
          );
        } finally {
          await subscription.cancel();
          await session.close();
        }
      }
    },
  );
}

void _configureWindowsSherpaRuntime(String? runtimeDirectory) {
  if (!Platform.isWindows) return;
  if (runtimeDirectory == null || runtimeDirectory.trim().isEmpty) {
    throw StateError('YIXUE_SHERPA_RUNTIME_DIR is required on Windows.');
  }
  final setDllDirectory = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('SetDllDirectoryW');
  final nativePath = runtimeDirectory.toNativeUtf16();
  try {
    if (setDllDirectory(nativePath) == 0) {
      throw StateError('Could not set the sherpa runtime directory.');
    }
  } finally {
    malloc.free(nativePath);
  }
}

Future<void> _feedWave(
  StreamingAsrSession session,
  _Pcm16Wave wave,
  String attemptId,
  String sessionId, {
  bool paceFrames = false,
}) async {
  final samplesPerFrame = (wave.sampleRate * 100) ~/ 1000;
  var offset = 0;
  var sequence = 0;
  while (offset < wave.sampleCount) {
    final frameSamples = (wave.sampleCount - offset).clamp(0, samplesPerFrame);
    final startByte = offset * wave.channelCount * 2;
    final endByte = startByte + frameSamples * wave.channelCount * 2;
    session.addAudio(
      AudioFrame(
        sessionId: sessionId,
        captureAttemptId: attemptId,
        sourceId: 'fixture-audio',
        sourceKind: SubtitleAudioSourceKind.microphone,
        sequence: sequence,
        startTimeUs:
            (offset * Duration.microsecondsPerSecond) ~/ wave.sampleRate,
        sampleRateHz: wave.sampleRate,
        channelCount: wave.channelCount,
        sampleCount: frameSamples,
        sampleFormat: AudioPcmSampleFormat.signedInt16LittleEndian,
        pcmBytes: Uint8List.sublistView(wave.bytes, startByte, endByte),
      ),
    );
    if (paceFrames) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    offset += frameSamples;
    sequence += 1;
  }
}

Future<_Pcm16Wave> _readPcm16Wave(File file) async {
  final bytes = await file.readAsBytes();
  if (bytes.length < 44 || ascii.decode(bytes.sublist(0, 4)) != 'RIFF') {
    throw FormatException('Not a RIFF/WAVE file: ${file.path}');
  }
  var offset = 12;
  var audioFormat = 0;
  var channels = 0;
  var sampleRate = 0;
  var bitsPerSample = 0;
  Uint8List? pcmBytes;
  final data = ByteData.sublistView(bytes);
  while (offset + 8 <= bytes.length) {
    final chunkName = ascii.decode(bytes.sublist(offset, offset + 4));
    final chunkLength = data.getUint32(offset + 4, Endian.little);
    final chunkStart = offset + 8;
    final chunkEnd = chunkStart + chunkLength;
    if (chunkEnd > bytes.length) {
      throw FormatException('Truncated WAV chunk in ${file.path}');
    }
    if (chunkName == 'fmt ' && chunkLength >= 16) {
      audioFormat = data.getUint16(chunkStart, Endian.little);
      channels = data.getUint16(chunkStart + 2, Endian.little);
      sampleRate = data.getUint32(chunkStart + 4, Endian.little);
      bitsPerSample = data.getUint16(chunkStart + 14, Endian.little);
    } else if (chunkName == 'data') {
      pcmBytes = Uint8List.sublistView(bytes, chunkStart, chunkEnd);
    }
    offset = chunkEnd + (chunkLength.isOdd ? 1 : 0);
  }
  if (audioFormat != 1 ||
      bitsPerSample != 16 ||
      channels <= 0 ||
      sampleRate <= 0 ||
      pcmBytes == null) {
    throw FormatException('Expected PCM16 WAV data: ${file.path}');
  }
  return _Pcm16Wave(
    bytes: pcmBytes,
    sampleRate: sampleRate,
    channelCount: channels,
    sampleCount: pcmBytes.length ~/ (channels * 2),
  );
}

final class _Pcm16Wave {
  const _Pcm16Wave({
    required this.bytes,
    required this.sampleRate,
    required this.channelCount,
    required this.sampleCount,
  });

  final Uint8List bytes;
  final int sampleRate;
  final int channelCount;
  final int sampleCount;
}
