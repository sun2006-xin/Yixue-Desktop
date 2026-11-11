import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/yixue_app.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/features/learning/learning_workspace.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_archive_controller.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_workspace.dart';

import 'screenshot_translation_archive_controller_test.dart'
    show ArchiveFakeCore, MemoryArchiveImageStore;

final _now = DateTime(2026, 10, 8, 10);

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openUnknownWords(WidgetTester tester, String word) async {
  await _tap(tester, 'learning-card-vocabulary');
  await _tap(tester, 'learning-vocabulary-stage-screenshot-words');
  await _tap(tester, 'learning-vocabulary-open-list');
  expect(
    find.byKey(ValueKey('learning-screenshot-word-$word')),
    findsOneWidget,
  );
  await _tap(tester, 'learning-vocabulary-back-to-ranges');
  await _tap(tester, 'learning-vocabulary-start-cycle');
  expect(find.byKey(const ValueKey('learning-word-card')), findsOneWidget);
  await _tap(tester, 'learning-reveal');
}

void main() {
  testWidgets(
    'unknown word enters review from its catalog with an empty dictionary',
    (tester) async {
      final store = MemoryLearningStore();
      await LearningRepository(store, clock: () => _now).addScreenshotWord(
        word: 'xylophotonic',
        sourceContext: 'A xylophotonic pulse arrives.',
        sourceTranslation: '一个脉冲到达。',
        sourceHistoryId: 'shot-unknown',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LearningWorkspace(
            store: store,
            loadEntries: () async => const [],
            clock: () => _now,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openUnknownWords(tester, 'xylophotonic');
      expect(find.text('尚未填写释义'), findsOneWidget);
      expect(find.text('A xylophotonic pulse arrives.'), findsOneWidget);
      expect(find.text('一个脉冲到达。'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('learning-screenshot-meaning-field')),
        '用户确认的脉冲属性',
      );
      await _tap(tester, 'learning-screenshot-save-meaning');
      expect((await store.read())!.items.single.meaningSource, 'user');
      await _tap(tester, 'learning-result-mastered');
      expect((await store.read())!.items.single.reviewCount, 1);
    },
  );

  testWidgets(
    'deleted history and image leave reloaded word snapshots reviewable',
    (tester) async {
      const history = TranslationHistoryEntryData(
        id: 'shot-deleted',
        sourceText: 'A xylophotonic pulse arrives.',
        translatedText: '一个脉冲到达。',
        providerId: 'offline',
        createdAt: '2026-10-08T10:00:00Z',
        origin: 'screenshot_translation',
      );
      final core = ArchiveFakeCore()..history = [history];
      final images = MemoryArchiveImageStore();
      await images.save(history.id, Uint8List.fromList([1, 2, 3]));
      final learning = MemoryLearningStore();
      await LearningRepository(learning, clock: () => _now).addScreenshotWord(
        word: 'xylophotonic',
        sourceContext: history.sourceText,
        sourceTranslation: history.translatedText,
        sourceHistoryId: history.id,
        userMeaning: '用户确认的脉冲属性',
      );
      final archive = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: images,
      );
      addTearDown(archive.dispose);
      final deletion = await archive.deleteEntry(history);
      expect(deletion.historyDeleted, isTrue);
      expect(deletion.imageDeleted, isTrue);
      expect(core.history, isEmpty);
      expect(await images.read(history.id), isNull);
      final restored = MemoryLearningStore();
      await restored.write(
        LearningStateData.fromJson((await learning.read())!.toJson()),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LearningWorkspace(
            store: restored,
            loadEntries: () async => const [],
            clock: () => _now,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openUnknownWords(tester, 'xylophotonic');
      expect(find.text('用户确认的脉冲属性'), findsWidgets);
      expect(find.text('你填写的释义'), findsOneWidget);
      expect(find.text(history.sourceText), findsOneWidget);
      expect(find.text(history.translatedText), findsOneWidget);
      await _tap(tester, 'learning-result-mastered');
      final item = (await restored.read())!.items.single;
      expect(item.reviewCount, 1);
      expect(item.sourceHistoryId, history.id);
      expect(item.sourceContext, history.sourceText);
      expect(item.sourceTranslation, history.translatedText);
    },
  );

  testWidgets(
    'shell screenshot writes retain learning edits and refresh the visible page',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryLearningStore();
      await tester.pumpWidget(
        YixueApp(
          learningStore: store,
          clock: () => _now,
          dictionaryLookupLoader: (_) async => null,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('截屏翻译'));
      await tester.pumpAndSettle();
      final add = tester
          .widget<ScreenshotTranslationWorkspace>(
            find.byType(ScreenshotTranslationWorkspace),
          )
          .onAddScreenshotWord!;
      await add(
        word: 'xylophotonic',
        sourceContext: 'A xylophotonic pulse arrives.',
        sourceTranslation: '一个脉冲到达。',
        sourceHistoryId: 'shot-a',
      );
      await add(
        word: 'zebrographic',
        sourceContext: 'A zebrographic shape appears.',
        sourceTranslation: '一个形状出现。',
        sourceHistoryId: 'shot-z',
      );
      await tester.tap(find.text('学习'));
      await tester.pumpAndSettle();
      await _openUnknownWords(tester, 'xylophotonic');
      await tester.enterText(
        find.byKey(const ValueKey('learning-screenshot-meaning-field')),
        '用户确认的脉冲属性',
      );
      await _tap(tester, 'learning-screenshot-save-meaning');
      await _tap(tester, 'learning-result-mastered');
      final before = (await store.read())!;
      expect(before.session, isNotNull);
      await add(
        word: 'nebulographic',
        sourceContext: 'A nebulographic pattern forms.',
        sourceTranslation: '一个图案形成。',
        sourceHistoryId: 'shot-b',
      );
      await tester.pumpAndSettle();
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
      expect(find.byType(LearningWorkspace), findsOneWidget);
      // The active queue still points to the second word after data refresh.
      expect(find.byKey(const ValueKey('learning-word-card')), findsOneWidget);
      expect(find.text('zebrographic'), findsOneWidget);
    },
  );

  testWidgets(
    'external screenshot word preserves visible drafts and updates the catalog',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryLearningStore();
      await tester.pumpWidget(
        YixueApp(
          learningStore: store,
          clock: () => _now,
          dictionaryLookupLoader: (_) async => null,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('截屏翻译'));
      await tester.pumpAndSettle();
      final add = tester
          .widget<ScreenshotTranslationWorkspace>(
            find.byType(ScreenshotTranslationWorkspace),
          )
          .onAddScreenshotWord!;
      await add(
        word: 'xylophotonic',
        sourceContext: 'A xylophotonic pulse arrives.',
        sourceTranslation: '一个脉冲到达。',
        sourceHistoryId: 'shot-draft',
      );
      await tester.tap(find.text('学习'));
      await tester.pumpAndSettle();
      await _openUnknownWords(tester, 'xylophotonic');
      final pageState = tester.state(find.byType(LearningWorkspace));
      final note = find.byKey(const ValueKey('learning-note-field'));
      final meaning = find.byKey(
        const ValueKey('learning-screenshot-meaning-field'),
      );
      await tester.ensureVisible(note);
      await tester.enterText(note, '仍未保存的笔记草稿');
      await tester.ensureVisible(meaning);
      await tester.enterText(meaning, '仍未保存的释义草稿');
      await add(
        word: 'nebulographic',
        sourceContext: 'A nebulographic pattern forms.',
        sourceTranslation: '一个图案形成。',
        sourceHistoryId: 'shot-new',
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(LearningWorkspace)), same(pageState));
      expect(tester.widget<TextField>(note).controller!.text, '仍未保存的笔记草稿');
      expect(tester.widget<TextField>(meaning).controller!.text, '仍未保存的释义草稿');
      expect(
        find.byKey(const ValueKey('learning-answer-visible')),
        findsOneWidget,
      );
      expect(
        (await store.read())!.items
            .firstWhere((item) => item.word == 'xylophotonic')
            .meaning,
        isNull,
      );
      await _tap(tester, 'learning-end');
      await _tap(tester, 'learning-vocabulary-open-list');
      expect(
        find.byKey(const ValueKey('learning-screenshot-word-nebulographic')),
        findsOneWidget,
      );
    },
  );
}
