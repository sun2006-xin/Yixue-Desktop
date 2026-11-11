import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/learning_workbench.dart';

void main() {
  final now = DateTime(2026, 10, 8, 10);

  test(
    'legacy JSON file preserves counters after screenshot add and reload',
    () async {
      final scratch = await Directory('build/learning-migration-tests')
          .create(recursive: true);
      final temporary = await scratch.createTemp('legacy-');
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/learning.json');
      final initial = await LearningRepository(
        MemoryLearningStore(),
        clock: () => now,
      ).ensureDefaultSet(['hello']);
      final oldItem =
          initial.items.single
              .copyWith(
                stage: 3,
                reviewCount: 8,
                correctCount: 6,
                againCount: 2,
                lastReviewedAt: now.toIso8601String(),
              )
              .toJson()
            ..['schema_version'] = 1;
      for (final key in [
        'meaning',
        'meaning_source',
        'source_context',
        'source_translation',
        'source_history_id',
      ]) {
        oldItem.remove(key);
      }
      final legacy = initial.toJson()
        ..['schema_version'] = 1
        ..['sets'] = [initial.sets.single.toJson()..['schema_version'] = 1]
        ..['items'] = [oldItem];
      await file.writeAsString(jsonEncode(legacy));
      final store = FileLearningStore(file);
      await LearningRepository(store, clock: () => now).addScreenshotWord(
        word: 'xylophotonic',
        sourceContext: 'A xylophotonic pulse arrives.',
        sourceTranslation: '一个脉冲到达。',
        sourceHistoryId: 'shot-migrated',
      );
      final restored = (await FileLearningStore(file).read())!;
      final hello = restored.items.firstWhere((item) => item.word == 'hello');
      expect(hello.stage, 3);
      expect(hello.reviewCount, 8);
      expect(hello.correctCount, 6);
      expect(hello.againCount, 2);
      expect(hello.lastReviewedAt, now.toIso8601String());
      expect(hello.meaning, isNull);
      expect(hello.sourceContext, isNull);
      expect(restored.items.map((item) => item.word), contains('xylophotonic'));
    },
  );

  test(
    'adding B preserves A meaning, review counters, queue and other sets',
    () async {
      final store = MemoryLearningStore();
      final screenshots = LearningRepository(store, clock: () => now);
      final learning = LearningRepository(store, clock: () => now);
      await screenshots.addScreenshotWord(
        word: 'quasar',
        sourceContext: 'A quasar shines.',
        sourceTranslation: '类星体很亮。',
        sourceHistoryId: 'shot-a',
      );
      await learning.ensureDefaultSet(['hello']);
      await learning.saveScreenshotWordMeaning(
        itemId: 'screenshot-words::quasar',
        meaning: '类星体（用户确认）',
      );
      await learning.addScreenshotWord(
        word: 'zebra',
        sourceContext: 'A zebra runs.',
        sourceTranslation: '斑马奔跑。',
        sourceHistoryId: 'shot-z',
      );
      await learning.startSession(
        setId: learningScreenshotWordsSetId,
        mode: LearningPromptMode.recognition,
      );
      await learning.recordReview(result: LearningReviewResult.mastered);
      final before = (await store.read())!;
      expect(before.session, isNotNull);
      expect(
        before.items.firstWhere((item) => item.word == 'quasar').reviewCount,
        1,
      );

      await screenshots.addScreenshotWord(
        word: 'nebula',
        sourceContext: 'A nebula glows.',
        sourceTranslation: '星云发光。',
        sourceHistoryId: 'shot-b',
      );
      final after = (await store.read())!;
      for (final original in before.items) {
        expect(
          after.items.firstWhere((item) => item.id == original.id).toJson(),
          original.toJson(),
        );
      }
      expect(
        after.reviews.map((review) => review.toJson()).toList(),
        before.reviews.map((review) => review.toJson()).toList(),
      );
      expect(after.session!.toJson(), before.session!.toJson());
      expect(after.sets.map((set) => set.id), contains(learningDefaultSetId));
      expect(after.items.map((item) => item.word), contains('nebula'));
    },
  );

  test(
    'review and screenshot addition serialize across repository instances',
    () async {
      final store = MemoryLearningStore();
      final screenshots = LearningRepository(store, clock: () => now);
      final learning = LearningRepository(store, clock: () => now);
      await screenshots.addScreenshotWord(
        word: 'quasar',
        sourceContext: 'A quasar shines.',
        sourceTranslation: '类星体很亮。',
        sourceHistoryId: 'shot-a',
      );
      await learning.startSession(
        setId: learningScreenshotWordsSetId,
        mode: LearningPromptMode.recognition,
      );
      await Future.wait<Object?>([
        learning.recordReview(result: LearningReviewResult.again),
        screenshots.addScreenshotWord(
          word: 'nebula',
          sourceContext: 'A nebula glows.',
          sourceTranslation: '星云发光。',
          sourceHistoryId: 'shot-b',
        ),
      ]);
      final after = (await store.read())!;
      final quasar = after.items.firstWhere((item) => item.word == 'quasar');
      expect(quasar.reviewCount, 1);
      expect(quasar.againCount, 1);
      expect(after.reviews, hasLength(1));
      expect(after.items.map((item) => item.word), contains('nebula'));
      expect(after.session, isNull);
    },
  );

  test(
    'file repositories sharing a path serialize read-modify-write operations',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'yixue-learning-shared-file-queue-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final file = File('${scratch.path}/learning.json');
      final releaseFirstCommit = Completer<void>();
      final firstCommitEntered = Completer<void>();
      var firstCommitBlocked = false;

      Future<void> replace(File staged, File destination) async {
        if (await destination.exists()) await destination.delete();
        await staged.rename(destination.path);
      }

      final firstStore = FileLearningStore(
        file,
        commit: (staged, destination) async {
          if (destination.path == file.path && !firstCommitBlocked) {
            firstCommitBlocked = true;
            firstCommitEntered.complete();
            await releaseFirstCommit.future;
          }
          await replace(staged, destination);
        },
      );
      final secondReadStarted = Completer<void>();
      final secondStore = _InstrumentedFileLearningStore(
        file,
        readStarted: secondReadStarted,
        commit: replace,
      );
      final firstRepository = LearningRepository(firstStore, clock: () => now);
      final secondRepository = LearningRepository(secondStore, clock: () => now);

      final firstAdd = firstRepository.addScreenshotWord(
        word: 'quasar',
        sourceContext: 'A quasar shines.',
        sourceTranslation: '类星体很亮。',
        sourceHistoryId: 'shared-file-a',
      );
      await firstCommitEntered.future;
      final secondAdd = secondRepository.addScreenshotWord(
        word: 'nebula',
        sourceContext: 'A nebula glows.',
        sourceTranslation: '星云发光。',
        sourceHistoryId: 'shared-file-b',
      );
      await Future.any<void>([
        secondReadStarted.future,
        Future<void>.delayed(const Duration(milliseconds: 100)),
      ]);
      expect(
        secondReadStarted.isCompleted,
        isFalse,
        reason: 'A second repository must not read a stale snapshot before '
            'the first file transaction commits.',
      );
      releaseFirstCommit.complete();
      await Future.wait([firstAdd, secondAdd]);
      expect(secondReadStarted.isCompleted, isTrue);

      final restored = (await FileLearningStore(file).read())!;
      expect(
        restored.items.map((item) => item.word),
        containsAll(['quasar', 'nebula']),
      );
      final quasar = restored.items.firstWhere((item) => item.word == 'quasar');
      final nebula = restored.items.firstWhere((item) => item.word == 'nebula');
      expect(quasar.sourceContext, 'A quasar shines.');
      expect(quasar.sourceTranslation, '类星体很亮。');
      expect(quasar.sourceHistoryId, 'shared-file-a');
      expect(nebula.sourceContext, 'A nebula glows.');
      expect(nebula.sourceTranslation, '星云发光。');
      expect(nebula.sourceHistoryId, 'shared-file-b');
    },
  );

  test('clear waits for an in-flight repository read-modify-write', () async {
    final scratch = await Directory.systemTemp.createTemp(
      'yixue-learning-clear-queue-',
    );
    addTearDown(() => scratch.delete(recursive: true));
    final file = File('${scratch.path}/learning.json');
    final seed = LearningRepository(FileLearningStore(file), clock: () => now);
    await seed.addScreenshotWord(
      word: 'quasar',
      sourceContext: 'A quasar shines.',
      sourceTranslation: '类星体很亮。',
      sourceHistoryId: 'clear-race-seed',
    );

    final readStarted = Completer<void>();
    final releaseRead = Completer<void>();
    final store = _InstrumentedFileLearningStore(
      file,
      readStarted: readStarted,
      releaseRead: releaseRead,
    );
    final repository = LearningRepository(store, clock: () => now);
    final add = repository.addScreenshotWord(
      word: 'nebula',
      sourceContext: 'A nebula glows.',
      sourceTranslation: '星云发光。',
      sourceHistoryId: 'clear-race-add',
    );
    await readStarted.future;

    final clearCompleted = Completer<void>();
    final clear = store.clear().then((_) => clearCompleted.complete());
    await Future.any<void>([
      clearCompleted.future,
      Future<void>.delayed(const Duration(milliseconds: 100)),
    ]);
    expect(
      clearCompleted.isCompleted,
      isFalse,
      reason: 'Clear must be ordered after the repository transaction that '
          'already read the prior state.',
    );

    releaseRead.complete();
    await Future.wait([add, clear]);
    expect(await FileLearningStore(file).read(), isNull);
  });
}

final class _InstrumentedFileLearningStore extends FileLearningStore {
  _InstrumentedFileLearningStore(
    super.file, {
    this.readStarted,
    this.releaseRead,
    super.commit,
  });

  final Completer<void>? readStarted;
  final Completer<void>? releaseRead;

  @override
  Future<LearningStateData?> read() async {
    final state = await super.read();
    final started = readStarted;
    if (started != null && !started.isCompleted) started.complete();
    final release = releaseRead;
    if (release != null) await release.future;
    return state;
  }
}
