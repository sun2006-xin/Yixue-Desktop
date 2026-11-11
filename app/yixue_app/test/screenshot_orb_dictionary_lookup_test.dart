import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_orb_dictionary_lookup_dialog.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';

void main() {
  testWidgets('orb lookup history retains the screenshot context snapshots', (
    tester,
  ) async {
    final lookupHistory = _MemoryLookupHistoryStore();

    await tester.pumpWidget(
      _host(
        lookupHistory,
        lookup: (_) async => const DictionaryEntry(
          word: 'word',
          ipa: '/wɜːd/',
          partOfSpeech: '名词',
          meanings: ['单词'],
          example: '',
          exampleTranslation: '',
        ),
        sourceContext: 'This word appears in the selected sentence.',
        sourceRecognizedText:
            'A full OCR paragraph containing the selected sentence.',
        sourceTranslation: '完整截图译文。',
        sourceHistoryId: 'capture-42',
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-orb-dictionary')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('screenshot-orb-dictionary-query')),
      'word',
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-submit')),
    );
    await tester.pumpAndSettle();

    final record = (await lookupHistory.read()).single;
    expect(record.sessionId, 'capture-42');
    expect(record.sourceContext, 'This word appears in the selected sentence.');
    expect(
      record.recognizedTextSnapshot,
      'A full OCR paragraph containing the selected sentence.',
    );
    expect(record.translationSnapshot, '完整截图译文。');

    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-history-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('word · word'));
    await tester.pumpAndSettle();

    expect(
      find.text('This word appears in the selected sentence.'),
      findsOneWidget,
    );
    expect(
      find.text('A full OCR paragraph containing the selected sentence.'),
      findsOneWidget,
    );
    expect(find.text('完整截图译文。'), findsOneWidget);
    expect(find.text('来自截图翻译记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('orb lookup saves a word with its screenshot context', (
    tester,
  ) async {
    final history = _MemoryLookupHistoryStore();
    String? savedWord;
    String? savedContext;
    String? savedTranslation;
    String? savedHistoryId;

    await tester.pumpWidget(
      _host(
        history,
        lookup: (_) async => const DictionaryEntry(
          word: 'apple',
          ipa: '/\u02c8\xe6p.\u0259l/',
          partOfSpeech: 'n.',
          meanings: ['\u82f9\u679c'],
          example: '',
          exampleTranslation: '',
        ),
        sourceContext: 'An apple a day.',
        sourceRecognizedText: 'An apple a day keeps the doctor away.',
        sourceTranslation:
            '\u4e00\u5929\u4e00\u82f9\u679c\uff0c\u533b\u751f\u8fdc\u79bb\u6211\u3002',
        sourceHistoryId: 'capture-save-7',
        saveToVocabulary: (word, source, translation, historyId) async {
          savedWord = word;
          savedContext = source;
          savedTranslation = translation;
          savedHistoryId = historyId;
          return true;
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-orb-dictionary')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('screenshot-orb-dictionary-query')),
      'apple',
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-save-word')),
    );
    await tester.pumpAndSettle();

    expect(savedWord, 'apple');
    expect(savedContext, 'An apple a day.');
    expect(
      savedTranslation,
      '\u4e00\u5929\u4e00\u82f9\u679c\uff0c\u533b\u751f\u8fdc\u79bb\u6211\u3002',
    );
    expect(savedHistoryId, 'capture-save-7');
    expect(find.text('\u5df2\u52a0\u5165\u5b66\u4e60\u8bcd\u6c47'), findsOneWidget);
  });

  testWidgets('orb lookup can save the word with its screenshot context', (
    tester,
  ) async {
    final history = _MemoryLookupHistoryStore();
    String? savedWord;
    String? savedContext;
    String? savedTranslation;
    String? savedHistoryId;

    await tester.pumpWidget(
      _host(
        history,
        lookup: (_) async => const DictionaryEntry(
          word: 'apple',
          ipa: '/\u02c8\xe6p.\u0259l/',
          partOfSpeech: 'n.',
          meanings: ['\u82f9\u679c'],
          example: '',
          exampleTranslation: '',
        ),
        sourceContext: 'An apple a day.',
        sourceRecognizedText: 'An apple a day keeps the doctor away.',
        sourceTranslation: '\u4e00\u5929\u4e00\u82f9\u679c\uff0c\u533b\u751f\u8fdc\u79bb\u6211\u3002',
        sourceHistoryId: 'capture-save-7',
        saveToVocabulary: (word, source, translation, historyId) async {
          savedWord = word;
          savedContext = source;
          savedTranslation = translation;
          savedHistoryId = historyId;
          return true;
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-orb-dictionary')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('screenshot-orb-dictionary-query')),
      'apple',
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-save-word')),
    );
    await tester.pumpAndSettle();

    expect(savedWord, 'apple');
    expect(savedContext, 'An apple a day.');
    expect(savedTranslation, '\u4e00\u5929\u4e00\u82f9\u679c\uff0c\u533b\u751f\u8fdc\u79bb\u6211\u3002');
    expect(savedHistoryId, 'capture-save-7');
    expect(find.text('\u5df2\u52a0\u5165\u5b66\u4e60\u8bcd\u6c47'), findsOneWidget);
  });

  testWidgets(
    'orb dictionary dialog searches both languages and reopens recent queries',
    (tester) async {
      final lookupHistory = _MemoryLookupHistoryStore();

      await tester.pumpWidget(_host(lookupHistory));
      await tester.tap(find.byKey(const ValueKey('open-orb-dictionary')));
      await tester.pumpAndSettle();

      final query = find.byKey(
        const ValueKey('screenshot-orb-dictionary-query'),
      );
      await tester.enterText(query, 'apple');
      await tester.tap(
        find.byKey(const ValueKey('screenshot-orb-dictionary-submit')),
      );
      await tester.pumpAndSettle();
      expect(find.text('apple'), findsWidgets);
      expect(find.textContaining('苹果'), findsWidgets);

      await tester.enterText(query, '苹果');
      await tester.tap(
        find.byKey(const ValueKey('screenshot-orb-dictionary-submit')),
      );
      await tester.pumpAndSettle();
      expect(find.text('苹果'), findsWidgets);
      expect(await lookupHistory.read(), hasLength(2));
      expect((await lookupHistory.read()).first.lookupQuery, '苹果');
      expect((await lookupHistory.read()).first.sessionId, isEmpty);
      expect((await lookupHistory.read()).first.sourceContext, isEmpty);
      expect((await lookupHistory.read()).first.translationSnapshot, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('screenshot-orb-dictionary-history-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('苹果 · apple'), findsOneWidget);
      await tester.tap(find.text('苹果 · apple'));
      await tester.pumpAndSettle();
      expect(find.text('独立查词 · 未关联截图原文或译文'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭查词弹窗'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_host(lookupHistory));
      await tester.tap(find.byKey(const ValueKey('open-orb-dictionary')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('screenshot-orb-dictionary-history-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('苹果 · apple'), findsOneWidget);
    },
  );

  testWidgets('orb lookup history can delete one record or clear all', (
    tester,
  ) async {
    final first = _lookupRecord('first');
    final second = _lookupRecord('second');
    final lookupHistory = _MemoryLookupHistoryStore()..seed([first, second]);
    await tester.pumpWidget(_host(lookupHistory));
    await tester.tap(find.byKey(const ValueKey('open-orb-dictionary')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-history-toggle')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除 language 查词记录').first);
    await tester.pumpAndSettle();
    expect((await lookupHistory.read()).map((record) => record.sessionId), [
      'second',
    ]);
    expect(find.text('first · language'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-history-clear')),
    );
    await tester.pumpAndSettle();
    expect(find.text('清空查词记录？'), findsOneWidget);
    await tester.tap(find.text('清空记录'));
    await tester.pumpAndSettle();
    expect(await lookupHistory.read(), isEmpty);
    expect(find.text('second · language'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pending lookup cannot overwrite a later history deletion', (
    tester,
  ) async {
    final existing = _lookupRecord('existing');
    final lookupHistory = _DelayedAddLookupHistoryStore()..seed([existing]);
    await tester.pumpWidget(
      _host(
        lookupHistory,
        lookup: (_) async => const DictionaryEntry(
          word: 'apple',
          ipa: '/ˈæp.əl/',
          partOfSpeech: '名词',
          meanings: ['苹果'],
          example: '',
          exampleTranslation: '',
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-orb-dictionary')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-history-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('screenshot-orb-dictionary-query')),
      'apple',
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-submit')),
    );
    await tester.pump();
    await lookupHistory.addStarted.future;

    await tester.tap(find.byTooltip('删除 language 查词记录'));
    await tester.pump();
    lookupHistory.releaseAdd.complete();
    await tester.pumpAndSettle();

    final remaining = await lookupHistory.read();
    expect(remaining, hasLength(1));
    expect(remaining.single.entry.word, 'apple');
    expect(find.text('existing · language'), findsNothing);
    expect(find.text('apple · apple'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows and persists dictionary forms and usage notes', (
    tester,
  ) async {
    final lookupHistory = _MemoryLookupHistoryStore();
    await tester.pumpWidget(
      _host(
        lookupHistory,
        lookup: (word) async => word == 'study'
            ? const DictionaryEntry(
                word: 'study',
                ipa: '/ˈstʌdi/',
                partOfSpeech: 'n. 名词',
                meanings: ['学习；研究'],
                example: 'Study the example carefully.',
                exampleTranslation: '仔细研究这个例子。',
                variants: ['studies', 'studied', 'studying'],
                collocationCandidates: ['study abroad', 'a careful study'],
                relationCandidates: {
                  '派生词': ['student', 'studious'],
                },
              )
            : null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-orb-dictionary')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('screenshot-orb-dictionary-query')),
      'study',
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-orb-dictionary-submit')),
    );
    await tester.pumpAndSettle();

    expect(find.text('词形'), findsOneWidget);
    expect(find.text('studies · studied · studying'), findsOneWidget);
    expect(find.text('常用搭配'), findsOneWidget);
    expect(find.text('study abroad · a careful study'), findsOneWidget);
    expect(find.text('派生词'), findsOneWidget);
    expect(find.text('student · studious'), findsOneWidget);

    final historyToggle = find.byKey(
      const ValueKey('screenshot-orb-dictionary-history-toggle'),
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(historyToggle);
    await tester.pumpAndSettle();
    final historyEntry = find.text('study · study');
    await tester.ensureVisible(historyEntry);
    await tester.pumpAndSettle();
    await tester.tap(historyEntry);
    await tester.pumpAndSettle();

    expect(find.text('studies · studied · studying'), findsOneWidget);
    expect(find.text('study abroad · a careful study'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'runtime routes the orb dictionary command to the main lookup dialog',
    () async {
      var opened = false;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => null,
        recognize: (_, [__]) async => '',
        translate: (
          _,
          _, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '',
        onOpenDictionaryLookup:
            ({
              sourceContext,
              sourceRecognizedText,
              sourceTranslation,
              sourceHistoryId,
            }) async {
              opened = true;
              expect(sourceContext, isNull);
              expect(sourceRecognizedText, isNull);
              expect(sourceTranslation, isNull);
              expect(sourceHistoryId, isNull);
            },
      );

      await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'openDictionaryLookup',
          requestId: 'orb-dictionary-open',
          payload: const {},
        ),
      );

      expect(opened, isTrue);
      await runtime.shutdown();
    },
  );

  test(
    'runtime forwards the active screenshot snapshots to orb lookup',
    () async {
      String? capturedContext;
      String? capturedRecognizedText;
      String? capturedTranslation;
      String? capturedHistoryId;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async =>
            CapturedData(width: 1, height: 1, bytes: Uint8List.fromList([1])),
        recognize: (_, [_]) async => 'Current OCR source.',
        translate: (
          _,
          _, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '当前截图译文。',
        onOpenDictionaryLookup:
            ({
              sourceContext,
              sourceRecognizedText,
              sourceTranslation,
              sourceHistoryId,
            }) async {
              capturedContext = sourceContext;
              capturedRecognizedText = sourceRecognizedText;
              capturedTranslation = sourceTranslation;
              capturedHistoryId = sourceHistoryId;
            },
      );
      addTearDown(() async {
        await runtime.shutdown();
        runtime.dispose();
      });

      await runtime.startCapture();
      await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'openDictionaryLookup',
          requestId: 'open-lookup-with-context',
          payload: const {},
        ),
      );

      expect(capturedContext, 'Current OCR source.');
      expect(capturedRecognizedText, 'Current OCR source.');
      expect(capturedTranslation, '当前截图译文。');
      expect(capturedHistoryId, runtime.session?.id);
    },
  );
}

class _MemoryLookupHistoryStore
    implements ScreenshotDictionaryLookupHistoryStore {
  List<ScreenshotDictionaryLookupHistoryRecord> _entries = const [];

  void seed(List<ScreenshotDictionaryLookupHistoryRecord> records) {
    _entries = List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read() async =>
      List.unmodifiable(_entries);

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) async {
    _entries = [
      record,
      ..._entries,
    ].take(screenshotDictionaryLookupHistoryLimit).toList(growable: false);
    return List.unmodifiable(_entries);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(
    String id,
  ) async {
    _entries = _entries
        .where((entry) => entry.id != id)
        .toList(growable: false);
    return List.unmodifiable(_entries);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear() async {
    _entries = const [];
    return const [];
  }
}

final class _DelayedAddLookupHistoryStore
    implements ScreenshotDictionaryLookupHistoryStore {
  List<ScreenshotDictionaryLookupHistoryRecord> _entries = const [];
  final addStarted = Completer<void>();
  final releaseAdd = Completer<void>();
  Future<void> _tail = Future<void>.value();

  void seed(List<ScreenshotDictionaryLookupHistoryRecord> records) {
    _entries = List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read() async {
    await _tail;
    return List.unmodifiable(_entries);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) {
    final operation = _tail.then<List<ScreenshotDictionaryLookupHistoryRecord>>(
      (_) async {
        addStarted.complete();
        await releaseAdd.future;
        _entries = <ScreenshotDictionaryLookupHistoryRecord>[
          record,
          ..._entries,
        ].take(screenshotDictionaryLookupHistoryLimit).toList(growable: false);
        return List.unmodifiable(_entries);
      },
    );
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(String id) {
    final operation = _tail.then<List<ScreenshotDictionaryLookupHistoryRecord>>(
      (_) async {
        _entries = _entries
            .where((record) => record.id != id)
            .toList(growable: false);
        return List.unmodifiable(_entries);
      },
    );
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear() {
    final operation = _tail.then((_) async {
      _entries = const [];
      return const <ScreenshotDictionaryLookupHistoryRecord>[];
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}

ScreenshotDictionaryLookupHistoryRecord _lookupRecord(String sessionId) =>
    ScreenshotDictionaryLookupHistoryRecord(
      entry: const ScreenshotDictionaryLookupResult(
        word: 'language',
        ipa: '/ˈlæŋɡwɪdʒ/',
        partOfSpeech: '名词',
        meanings: ['语言'],
        example: 'Language helps people share ideas.',
        exampleTranslation: '语言帮助人们分享想法。',
        qualityStatus: 'verified',
        examples: [],
        variants: [],
        collocations: [],
        relations: {},
      ),
      sessionId: sessionId,
      sourceContext: '',
      translationSnapshot: '',
      recordedAt: DateTime.utc(2026, 10, 20),
    );

Widget _host(
  ScreenshotDictionaryLookupHistoryStore store, {
  Future<DictionaryEntry?> Function(String word)? lookup,
  ScreenshotOrbDictionarySaveToVocabulary? saveToVocabulary,
  String? sourceContext,
  String? sourceRecognizedText,
  String? sourceTranslation,
  String? sourceHistoryId,
}) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        key: const ValueKey('open-orb-dictionary'),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => ScreenshotOrbDictionaryLookupDialog(
            lookupDictionary:
                lookup ??
                (word) async {
                  const local = LocalDictionaryService();
                  return local.lookup(word) ?? local.lookupChinese(word);
                },
            lookupHistoryStore: store,
            saveToVocabulary: saveToVocabulary,
            sourceContext: sourceContext,
            sourceRecognizedText: sourceRecognizedText,
            sourceTranslation: sourceTranslation,
            sourceHistoryId: sourceHistoryId,
          ),
        ),
        child: const Text('open'),
      ),
    ),
  ),
);
