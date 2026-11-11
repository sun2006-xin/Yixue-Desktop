import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_store.dart';

void main() {
  late Directory rootDirectory;
  late FileSubtitleSessionStore store;

  setUp(() async {
    rootDirectory = await Directory.systemTemp.createTemp(
      'yixue-subtitle-session-store-',
    );
    store = FileSubtitleSessionStore(
      rootDirectory,
      now: () => DateTime.utc(2026, 10, 11, 12),
    );
  });

  tearDown(() async {
    if (await rootDirectory.exists()) {
      await rootDirectory.delete(recursive: true);
    }
  });

  test(
    'writes manual and auto modes to v2 manifests and reads them back',
    () async {
      for (final mode in SubtitleRecognitionMode.values) {
        final sessionId = 'session-${mode.name}';
        await store.createSession(_record(sessionId, mode));

        final manifestFile = _manifestFile(rootDirectory, sessionId);
        final manifest = jsonDecode(await manifestFile.readAsString());
        expect(manifest, isA<Map<String, dynamic>>());
        expect((manifest as Map<String, dynamic>)['schemaVersion'], 2);
        expect(manifest['recognitionMode'], mode.name);

        final restored = await store.readSession(sessionId);
        expect(restored?.recognitionMode, mode);
      }
    },
  );

  test(
    'rejects creating a new session without an explicit recognition mode',
    () async {
      await expectLater(
        store.createSession(_record('missing-mode', null)),
        throwsA(
          isA<SubtitleSessionStoreException>().having(
            (error) => error.code,
            'code',
            'recognition_mode_required',
          ),
        ),
      );
    },
  );

  test(
    'keeps a corrupt session file while listing and recovering other sessions',
    () async {
      const corruptSessionId = 'corrupt-session';
      const validSessionId = 'valid-session';
      await store.createSession(
        _record(corruptSessionId, SubtitleRecognitionMode.manual),
      );
      await store.createSession(
        _record(validSessionId, SubtitleRecognitionMode.manual),
      );
      final corruptManifest = _manifestFile(rootDirectory, corruptSessionId);
      await corruptManifest.writeAsString('{not-json');

      await expectLater(store.recoverInterruptedSessions(), completes);
      final sessions = await store.listSessions();

      expect(
        sessions.map((session) => session.sessionId),
        contains(validSessionId),
      );
      expect(
        sessions.map((session) => session.sessionId),
        isNot(contains(corruptSessionId)),
      );
      expect(await corruptManifest.readAsString(), '{not-json');
      expect(store.corruptSessionCount, 1);
    },
  );

  test(
    'skips a corrupt cue and keeps the rest of the session readable',
    () async {
      const sessionId = 'partially-corrupt-session';
      await store.createSession(
        _record(
          sessionId,
          SubtitleRecognitionMode.manual,
          segments: <SubtitleSegment>[
            _japaneseCue(sessionId),
            _japaneseCue(sessionId, segmentId: 'segment-2', startMs: 1200),
          ],
        ),
      );

      final manifest = _manifestFile(rootDirectory, sessionId);
      final cueFiles = await manifest.parent
          .list(recursive: true)
          .where(
            (entity) =>
                entity is File &&
                entity.path.endsWith('.json') &&
                entity.path != manifest.path,
          )
          .cast<File>()
          .toList();
      expect(cueFiles, hasLength(2));
      await cueFiles.first.writeAsString('{not-json');

      final restored = await store.readSession(sessionId);
      final listed = await store.listSessions();

      expect(restored?.segments, hasLength(1));
      expect(restored?.segments.single.transcript.segmentId, isNotEmpty);
      expect(restored?.corruptSegmentCount, 1);
      expect(listed.single.corruptSegmentCount, 1);
      expect(await cueFiles.first.exists(), isTrue);
    },
  );

  test(
    'reads v1 as unknown and never infers auto from detected cue language',
    () async {
      const sessionId = 'legacy-session';
      await store.createSession(
        _record(
          sessionId,
          SubtitleRecognitionMode.manual,
          segments: <SubtitleSegment>[_japaneseCue(sessionId)],
        ),
      );

      final manifestFile = _manifestFile(rootDirectory, sessionId);
      final legacyManifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      legacyManifest['schemaVersion'] = 1;
      legacyManifest.remove('recognitionMode');
      await manifestFile.writeAsString(jsonEncode(legacyManifest));

      final restoredLegacy = await store.readSession(sessionId);
      expect(restoredLegacy?.recognitionMode, isNull);
      expect(restoredLegacy?.segments.single.transcript.languageCode, 'ja');

      await store.updateSessionStatus(
        sessionId,
        SubtitleSessionHistoryStatus.capturing,
      );
      final migratedManifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final restoredAfterWrite = await store.readSession(sessionId);
      expect(migratedManifest['schemaVersion'], 2);
      expect(migratedManifest['recognitionMode'], isNull);
      expect(restoredAfterWrite?.recognitionMode, isNull);
    },
  );

  test(
    'restores auto cues that already match the saved target language',
    () async {
      const sessionId = 'same-language-session';
      await store.createSession(
        _record(
          sessionId,
          SubtitleRecognitionMode.auto,
          targetLanguageCode: 'ja',
          segments: <SubtitleSegment>[_japaneseCue(sessionId)],
        ),
      );

      final restored = await store.readSession(sessionId);

      expect(
        restored?.segments.single.translationStatus.name,
        'skippedSameLanguage',
      );
      expect(restored?.segments.single.transcript.text, 'こんにちは。');
    },
  );
}

SubtitleSessionRecord _record(
  String sessionId,
  SubtitleRecognitionMode? recognitionMode, {
  String targetLanguageCode = 'zh',
  Iterable<SubtitleSegment> segments = const <SubtitleSegment>[],
}) => SubtitleSessionRecord(
  sessionId: sessionId,
  kind: SubtitleSessionKind.meeting,
  sourceKind: SubtitleAudioSourceKind.systemOutput,
  recognitionMode: recognitionMode,
  targetLanguageCode: targetLanguageCode,
  startedAtUtc: DateTime.utc(2026, 10, 11, 10),
  status: SubtitleSessionHistoryStatus.preparing,
  segments: segments,
);

SubtitleSegment _japaneseCue(
  String sessionId, {
  String segmentId = 'segment-1',
  int startMs = 100,
}) => SubtitleSegment.fromStoredFinalTranscript(
  TranscriptRevision(
    sessionId: sessionId,
    captureAttemptId: 'attempt-1',
    segmentId: segmentId,
    sourceId: 'system-output',
    sourceKind: SubtitleAudioSourceKind.systemOutput,
    startMs: startMs,
    endMs: startMs + 800,
    text: 'こんにちは。',
    languageCode: 'ja',
    revision: 1,
    isFinal: true,
  ),
);

File _manifestFile(Directory root, String sessionId) {
  final digest = sha256.convert(utf8.encode(sessionId));
  return File(
    '${root.absolute.path}${Platform.pathSeparator}session-$digest'
    '${Platform.pathSeparator}session.json',
  );
}
