import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_pagination.dart';
import 'package:yixue_app/core/native_core_bridge.dart';

void main() {
  test('loads every stored dictionary page until the final page', () async {
    final dictionary = _PagedDictionaryCore(
      List<DictionaryEntryData>.generate(205, _entry),
    );

    final entries = await loadStoredDictionaryEntries(dictionary);

    expect(entries, hasLength(205));
    expect(entries.first.word, 'word-0');
    expect(entries.last.word, 'word-204');
    expect(dictionary.pageRequests, const [(100, 0), (100, 100), (100, 200)]);
    expect(dictionary.legacyLookupCalls, 0);
  });

  test(
    'falls back to the bounded legacy lookup for an older native core',
    () async {
      final dictionary = _PagedDictionaryCore(
        const [],
        pageFailure: const CoreBridgeException(
          'unknown_command',
          'bridge command is unknown',
        ),
        legacyEntries: List<DictionaryEntryData>.generate(50, _entry),
      );

      final entries = await loadStoredDictionaryEntries(dictionary);

      expect(entries, hasLength(50));
      expect(dictionary.legacyLookupCalls, 1);
    },
  );

  test('does not hide storage failures behind the legacy fallback', () async {
    final dictionary = _PagedDictionaryCore(
      const [],
      pageFailure: const CoreBridgeException(
        'storage_error',
        'local storage operation failed',
      ),
    );

    await expectLater(
      loadStoredDictionaryEntries(dictionary),
      throwsA(isA<CoreBridgeException>()),
    );
    expect(dictionary.legacyLookupCalls, 0);
  });
}

DictionaryEntryData _entry(int index) => DictionaryEntryData(
  id: 'entry-$index',
  word: 'word-$index',
  ipa: '',
  partOfSpeech: 'n.',
  meanings: const ['meaning'],
  example: '',
  exampleTranslation: '',
  source: 'test',
);

final class _PagedDictionaryCore
    implements DictionaryCore, PagedDictionaryCore {
  _PagedDictionaryCore(
    this.pages, {
    this.pageFailure,
    this.legacyEntries = const [],
  });

  final List<DictionaryEntryData> pages;
  final CoreBridgeException? pageFailure;
  final List<DictionaryEntryData> legacyEntries;
  final List<(int, int)> pageRequests = [];
  var legacyLookupCalls = 0;

  @override
  List<DictionaryEntryData> lookupDictionary(String word, {int limit = 10}) {
    legacyLookupCalls++;
    return legacyEntries.take(limit).toList(growable: false);
  }

  @override
  void saveDictionaryEntry(DictionaryEntryData entry) =>
      throw UnimplementedError();

  @override
  List<String> listFavoriteWords() => throw UnimplementedError();

  @override
  void setFavoriteWord(String word, bool favorite) =>
      throw UnimplementedError();

  @override
  DictionaryEntryPageData listDictionaryEntryPage({
    String word = '',
    int limit = 50,
    int offset = 0,
  }) {
    pageRequests.add((limit, offset));
    final failure = pageFailure;
    if (failure != null) throw failure;
    final start = offset.clamp(0, pages.length).toInt();
    final end = (offset + limit).clamp(0, pages.length).toInt();
    return DictionaryEntryPageData(
      entries: pages.sublist(start, end),
      hasMore: end < pages.length,
    );
  }
}
