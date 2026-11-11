import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_result_window.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';

void main() {
  const entry = ScreenshotDictionaryLookupResult(
    word: 'language',
    ipa: '/ˈlæŋɡwɪdʒ/',
    partOfSpeech: '名词',
    meanings: ['语言'],
    example: 'Language helps people share ideas.',
    exampleTranslation: '语言帮助人们分享想法。',
    qualityStatus: 'verified',
    examples: [],
    variants: ['languages'],
    collocations: ['spoken language'],
    relations: {
      '相关词': ['linguistic'],
    },
  );

  test('file store round trips lookup snapshots independently', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-screenshot-lookups-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}lookups.json');
    final firstStore = FileScreenshotDictionaryLookupHistoryStore(file);
    final record = ScreenshotDictionaryLookupHistoryRecord(
      entry: entry,
      lookupQuery: 'Language',
      sessionId: 'capture-1',
      sourceContext: 'The study of language helps people.',
      recognizedTextSnapshot:
          'Full OCR snapshot: The study of language helps people.',
      translationSnapshot: '语言研究有助于人们。',
      recordedAt: DateTime.utc(2026, 10, 20),
    );

    await firstStore.add(record);
    final reopened = await FileScreenshotDictionaryLookupHistoryStore(file)
        .read();

    expect(reopened, hasLength(1));
    expect(reopened.single.entry.word, 'language');
    expect(reopened.single.lookupQuery, 'Language');
    expect(reopened.single.entry.meanings, ['语言']);
    expect(reopened.single.entry.variants, ['languages']);
    expect(reopened.single.entry.collocations, ['spoken language']);
    expect(reopened.single.entry.relations, {
      '相关词': ['linguistic'],
    });
    expect(reopened.single.sessionId, 'capture-1');
    expect(
      reopened.single.sourceContext,
      'The study of language helps people.',
    );
    expect(
      reopened.single.recognizedTextSnapshot,
      'Full OCR snapshot: The study of language helps people.',
    );
    expect(reopened.single.translationSnapshot, '语言研究有助于人们。');
    expect(reopened.single.recordedAt, record.recordedAt);
    expect(await file.exists(), isTrue);
  });

  test(
    'file store round trips model word trials as a distinct history kind',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-screenshot-model-trial-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}lookups.json',
      );
      final store = FileScreenshotDictionaryLookupHistoryStore(file);
      final record = ScreenshotDictionaryLookupHistoryRecord.modelTrial(
        lookupQuery: 'language',
        sessionId: 'capture-model-trial',
        sourceContext: 'The study of language helps people.',
        recognizedTextSnapshot:
            'Full OCR snapshot: The study of language helps people.',
        translationSnapshot: '语言研究有助于人们。',
        modelTranslation: '语言',
        recordedAt: DateTime.utc(2026, 10, 20),
      );

      await store.add(record);
      final reopened = await FileScreenshotDictionaryLookupHistoryStore(file)
          .read();

      expect(reopened, hasLength(1));
      expect(reopened.single.isModelTranslation, isTrue);
      expect(reopened.single.lookupQuery, 'language');
      expect(reopened.single.modelTranslation, '语言');
      expect(reopened.single.entry.meanings, isEmpty);
      expect(
        reopened.single.sourceContext,
        'The study of language helps people.',
      );
      expect(
        reopened.single.recognizedTextSnapshot,
        'Full OCR snapshot: The study of language helps people.',
      );
      expect(reopened.single.translationSnapshot, '语言研究有助于人们。');
    },
  );

  test(
    'unique record IDs let removal target only one duplicate lookup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-screenshot-lookups-unique-id-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}lookups.json',
      );
      final store = FileScreenshotDictionaryLookupHistoryStore(file);
      ScreenshotDictionaryLookupHistoryRecord record(String id) =>
          ScreenshotDictionaryLookupHistoryRecord(
            entry: entry,
            recordId: id,
            lookupQuery: 'language',
            sessionId: 'same-capture',
            sourceContext: 'Same source text.',
            translationSnapshot: '同一段译文。',
            recordedAt: DateTime.utc(2026, 10, 20),
          );
      final first = record('lookup-1');
      final second = record('lookup-2');
      await store.add(first);
      await store.add(second);

      final persisted = await FileScreenshotDictionaryLookupHistoryStore(file)
          .read();
      expect(persisted.map((value) => value.id), ['lookup-2', 'lookup-1']);
      await FileScreenshotDictionaryLookupHistoryStore(file).remove(first.id);

      final remaining = await FileScreenshotDictionaryLookupHistoryStore(file)
          .read();
      expect(remaining.map((value) => value.id), ['lookup-2']);
    },
  );

  test(
    'schema v1 lookup records remain readable without a saved query',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-screenshot-lookups-v1-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}lookups.json',
      );
      final record = ScreenshotDictionaryLookupHistoryRecord(
        entry: entry,
        sessionId: 'capture-legacy',
        sourceContext: 'A language sample.',
        translationSnapshot: '语言样例。',
        recordedAt: DateTime.utc(2026, 10, 20),
      );
      final legacyRecord = record.toJson()..remove('lookupQuery');
      final legacyEntry =
          Map<String, Object?>.from(legacyRecord['entry']! as Map)
            ..remove('variants')
            ..remove('collocations')
            ..remove('relations');
      legacyRecord['entry'] = legacyEntry;
      await file.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'entries': [legacyRecord],
        }),
      );

      final reopened = await FileScreenshotDictionaryLookupHistoryStore(file)
          .read();

      expect(reopened, hasLength(1));
      expect(reopened.single.lookupQuery, 'language');
      expect(reopened.single.entry.variants, isEmpty);
      expect(reopened.single.entry.collocations, isEmpty);
      expect(reopened.single.entry.relations, isEmpty);
    },
  );

  test('file store keeps only the most recent 24 lookups', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-screenshot-lookups-cap-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FileScreenshotDictionaryLookupHistoryStore(
      File('${directory.path}${Platform.pathSeparator}lookups.json'),
    );

    for (var index = 0; index < 25; index++) {
      await store.add(
        ScreenshotDictionaryLookupHistoryRecord(
          entry: entry,
          sessionId: 'capture-$index',
          sourceContext: 'source $index',
          translationSnapshot: 'translation $index',
          recordedAt: DateTime.utc(2026, 10, 20, 0, 0, index),
        ),
      );
    }

    final records = await store.read();
    expect(records, hasLength(screenshotDictionaryLookupHistoryLimit));
    expect(records.first.sessionId, 'capture-24');
    expect(records.last.sessionId, 'capture-1');
  });

  test(
    'file store removes one lookup and clears history across reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-screenshot-lookups-delete-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}lookups.json',
      );
      final store = FileScreenshotDictionaryLookupHistoryStore(file);
      final first = ScreenshotDictionaryLookupHistoryRecord(
        entry: entry,
        sessionId: 'first',
        sourceContext: 'first context',
        translationSnapshot: 'first translation',
        recordedAt: DateTime.utc(2026, 10, 20),
      );
      final second = ScreenshotDictionaryLookupHistoryRecord(
        entry: entry,
        sessionId: 'second',
        sourceContext: 'second context',
        translationSnapshot: 'second translation',
        recordedAt: DateTime.utc(2026, 10, 21),
      );
      await store.add(first);
      await store.add(second);

      final remaining = await store.remove(second.id);
      expect(remaining.map((record) => record.sessionId), ['first']);
      expect(
        (await FileScreenshotDictionaryLookupHistoryStore(
          file,
        ).read()).map((record) => record.sessionId),
        ['first'],
      );

      expect(await store.clear(), isEmpty);
      expect(
        await FileScreenshotDictionaryLookupHistoryStore(file).read(),
        isEmpty,
      );
    },
  );

  test(
    'separate stores do not lose concurrent lookup history writes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-screenshot-lookups-concurrent-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}lookups.json',
      );
      final firstStore = FileScreenshotDictionaryLookupHistoryStore(file);
      final secondStore = FileScreenshotDictionaryLookupHistoryStore(file);
      ScreenshotDictionaryLookupHistoryRecord record(String id) =>
          ScreenshotDictionaryLookupHistoryRecord(
            entry: entry,
            sessionId: id,
            sourceContext: 'source $id',
            translationSnapshot: 'translation $id',
            recordedAt: DateTime.utc(2026, 10, 20),
          );
      final sessionIds = <String>{
        for (var index = 0; index < 8; index++) 'first-$index',
        for (var index = 0; index < 8; index++) 'second-$index',
      };

      await Future.wait([
        for (var index = 0; index < 8; index++) ...[
          firstStore.add(record('first-$index')),
          secondStore.add(record('second-$index')),
        ],
      ]);

      final reopened = await FileScreenshotDictionaryLookupHistoryStore(file)
          .read();
      expect(reopened.map((item) => item.sessionId).toSet(), sessionIds);
      expect(
        jsonDecode(await file.readAsString()),
        isA<Map<String, dynamic>>(),
      );
    },
  );

  test(
    'damaged history is preserved and reported instead of appearing empty',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-screenshot-lookups-damaged-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}lookups.json',
      );
      const damagedJson = '{"schemaVersion":1,"entries":[broken';
      await file.writeAsString(damagedJson);
      final store = FileScreenshotDictionaryLookupHistoryStore(file);

      await expectLater(store.read(), throwsA(isA<FileSystemException>()));

      expect(await file.readAsString(), damagedJson);
      expect(await File('${file.path}.corrupt').exists(), isTrue);
    },
  );

  testWidgets('successful lookup survives result-window disposal and reopen', (
    tester,
  ) async {
    final persistedRecords = <ScreenshotDictionaryLookupHistoryRecord>[];

    Widget resultWindow() => MaterialApp(
      home: ScreenshotTranslationResultWindow(
        session: ScreenshotTranslationSession(
          id: 'capture-1',
          recognizedText: 'The study of language helps people.',
          translatedText: '语言研究有助于人们。',
          status: ScreenshotTranslationStatus.completed,
        ),
        onCapture: () {},
        onRetranslate: (_) {},
        onHistory: () {},
        onClose: () {},
        lookupHistoryStore: _MemoryScreenshotDictionaryLookupHistoryStore(
          persistedRecords,
        ),
        onLookupDictionary: (_) async => entry,
      ),
    );

    await tester.pumpWidget(resultWindow());
    await tester.tap(find.byType(TextField));
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 13,
      extentOffset: 21,
    );
    await tester.pump();
    tester
        .state<EditableTextState>(
          find.descendant(
            of: find.byType(TextField),
            matching: find.byType(EditableText),
          ),
        )
        .showToolbar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('查词释义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(resultWindow());
    await tester.pumpAndSettle();
    expect(find.byTooltip('查词记录 1'), findsOneWidget);
    await tester.tap(find.byTooltip('查词记录 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('language'));
    await tester.pumpAndSettle();
    expect(find.text('查词记录 · language'), findsOneWidget);
    expect(find.text('词典释义快照'), findsOneWidget);
    expect(find.text('词形：languages'), findsOneWidget);
    expect(find.text('常用搭配：spoken language'), findsOneWidget);
    expect(find.text('相关词：linguistic'), findsOneWidget);
    expect(find.text('The study of language helps people.'), findsOneWidget);
    expect(find.text('语言研究有助于人们。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stalled history read does not block a successful lookup', (
    tester,
  ) async {
    final store = _NeverCompletingReadHistoryStore();
    await tester.pumpWidget(_resultWindow(store, entry));
    await _openDictionaryLookup(tester);

    // Do not settle while the lookup spinner is visible. Advance the fake
    // clock past the bounded history-read wait instead.
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('language'), findsOneWidget);
    expect(find.text('• 语言'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('查词记录 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a stalled history write shows the successful lookup and timeout',
    (tester) async {
      await tester.pumpWidget(
        _resultWindow(_NeverCompletingAddHistoryStore(), entry),
      );
      await _openDictionaryLookup(tester);

      // The lookup callback succeeds; only local-history persistence stalls.
      await tester.pump();
      expect(find.text('正在查询本地词典…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('language'), findsOneWidget);
      expect(find.text('• 语言'), findsOneWidget);
      expect(find.text('正在查询本地词典…'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('查词成功；本机查词记录保存超时，状态未确认。释义仍可查看。'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _resultWindow(
  ScreenshotDictionaryLookupHistoryStore store,
  ScreenshotDictionaryLookupResult entry,
) => MaterialApp(
  home: ScreenshotTranslationResultWindow(
    session: ScreenshotTranslationSession(
      id: 'stalled-history-test',
      recognizedText: 'The study of language helps people.',
      translatedText: '语言研究有助于人们。',
      status: ScreenshotTranslationStatus.completed,
    ),
    onCapture: () {},
    onRetranslate: (_) {},
    onHistory: () {},
    onClose: () {},
    lookupHistoryStore: store,
    onLookupDictionary: (_) async => entry,
  ),
);

Future<void> _openDictionaryLookup(WidgetTester tester) async {
  await tester.tap(find.byType(TextField));
  final field = tester.widget<TextField>(find.byType(TextField));
  field.controller!.selection = const TextSelection(
    baseOffset: 13,
    extentOffset: 21,
  );
  await tester.pump();
  tester
      .state<EditableTextState>(
        find.descendant(
          of: find.byType(TextField),
          matching: find.byType(EditableText),
        ),
      )
      .showToolbar();
  await tester.pumpAndSettle();
  await tester.tap(find.text('查词释义'));
}

final class _MemoryScreenshotDictionaryLookupHistoryStore
    implements ScreenshotDictionaryLookupHistoryStore {
  _MemoryScreenshotDictionaryLookupHistoryStore(this.records);

  final List<ScreenshotDictionaryLookupHistoryRecord> records;

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read() async =>
      List.unmodifiable(records.take(screenshotDictionaryLookupHistoryLimit));

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) async {
    records.insert(0, record);
    if (records.length > screenshotDictionaryLookupHistoryLimit) {
      records.removeRange(
        screenshotDictionaryLookupHistoryLimit,
        records.length,
      );
    }
    return List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(
    String id,
  ) async {
    records.removeWhere((record) => record.id == id);
    return List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear() async {
    records.clear();
    return const [];
  }
}

final class _NeverCompletingReadHistoryStore
    implements ScreenshotDictionaryLookupHistoryStore {
  final List<ScreenshotDictionaryLookupHistoryRecord> records = [];

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read() =>
      Completer<List<ScreenshotDictionaryLookupHistoryRecord>>().future;

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) async {
    records.insert(0, record);
    return List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(
    String id,
  ) async {
    records.removeWhere((record) => record.id == id);
    return List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear() async {
    records.clear();
    return const [];
  }
}

final class _NeverCompletingAddHistoryStore
    implements ScreenshotDictionaryLookupHistoryStore {
  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read() async =>
      const [];

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) => Completer<List<ScreenshotDictionaryLookupHistoryRecord>>().future;

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(String id) =>
      Completer<List<ScreenshotDictionaryLookupHistoryRecord>>().future;

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear() =>
      Completer<List<ScreenshotDictionaryLookupHistoryRecord>>().future;
}
