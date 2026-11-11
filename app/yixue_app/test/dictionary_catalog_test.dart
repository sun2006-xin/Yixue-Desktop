import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_catalog.dart';

DictionaryCatalogManifest _manifest({
  DictionaryQualityStatus status = DictionaryQualityStatus.published,
  bool redistributionAllowed = true,
}) {
  return DictionaryCatalogManifest(
    id: 'yixue-starter.en-zh',
    name: '译学自写英汉基础词典',
    version: '0.2.0',
    languagePair: 'en-zh',
    license: '自写内容 · 译学项目许可',
    attribution: '由花鱼鱼整理与维护',
    redistributionAllowed: redistributionAllowed,
    sourceRecords: const [
      DictionarySourceRecord(
        id: 'yixue-authored',
        name: '译学自写',
        version: '0.2.0',
        license: '自写内容 · 译学项目许可',
        attribution: '花鱼鱼',
      ),
    ],
    entries: [
      DictionaryCatalogEntry(
        entryId: 'yixue-starter.hello',
        languagePair: 'en-zh',
        lemma: 'hello',
        variants: const [],
        ipa: const {'uk': '/həˈləʊ/'},
        partOfSpeech: 'int. 感叹词',
        senses: const [
          DictionarySense(
            id: 'hello-1',
            meanings: ['你好；喂'],
            usage: '用于打招呼或引起注意',
            domain: '日常沟通',
            examples: [
              DictionaryExample(
                text: 'Hello, nice to meet you.',
                translation: '你好，很高兴认识你。',
                sourceId: 'yixue-authored',
              ),
            ],
          ),
        ],
        collocations: const ['say hello', 'hello there'],
        learningTags: const ['日常', '初级', '口语'],
        coverageBands: const ['foundation', 'cet4'],
        relations: const {
          'synonyms': ['hi'],
        },
        sourceIds: const ['yixue-authored'],
        quality: DictionaryQuality(
          status: status,
          reviewer: '译学编辑',
          reviewedAt: '2026-09-14',
        ),
      ),
    ],
  );
}

void main() {
  test('projects the bundled seed into the expandable v2 catalog', () {
    final catalog = builtInDictionaryCatalog();

    expect(catalog.entries.length, greaterThanOrEqualTo(60));
    expect(catalog.entries.first.entryId, startsWith('yixue-basic.'));
    expect(catalog.sourceRecords.single.id, 'yixue-authored');
    expect(catalog.toV1Package()['entries'], hasLength(catalog.entries.length));
  });

  test('serializes rich entries and exports a compatible v1 package', () {
    final manifest = _manifest();
    final decoded = jsonDecode(jsonEncode(manifest.toJson()));
    final restored = DictionaryCatalogManifest.fromJson(decoded);

    expect(restored.entries.single.entryId, 'yixue-starter.hello');
    expect(
      restored.entries.single.senses.single.examples.single.translation,
      '你好，很高兴认识你。',
    );
    expect(restored.entries.single.learningTags, contains('口语'));
    expect(restored.entries.single.coverageBands, contains('cet4'));

    final v1 = restored.toV1Package();
    expect(v1['schema_version'], 1);
    expect(v1['language_pair'], 'en-zh');
    expect((v1['entries'] as List).single['word'], 'hello');
    expect((v1['entries'] as List).single['example_translation'], '你好，很高兴认识你。');
  });

  test('does not export drafts or private catalogs as public v1 packages', () {
    expect(
      () => _manifest(status: DictionaryQualityStatus.draft).toV1Package(),
      throwsA(isA<DictionaryCatalogException>()),
    );
    expect(
      () => _manifest(redistributionAllowed: false).toV1Package(),
      throwsA(isA<DictionaryCatalogException>()),
    );
  });

  test('rejects entries that reference an unknown source record', () {
    final json =
        jsonDecode(jsonEncode(_manifest().toJson())) as Map<String, dynamic>;
    final entries = json['entries']! as List<Object?>;
    final entry = entries.single! as Map<String, Object?>;
    entry['source_ids'] = ['missing-source'];

    expect(
      () => DictionaryCatalogManifest.fromJson(json),
      throwsA(
        isA<DictionaryCatalogException>().having(
          (error) => error.message,
          'message',
          contains('source_ids'),
        ),
      ),
    );
  });

  test('reports coverage progress without claiming completion', () {
    final profiles = {
      for (final profile in dictionaryCoverageProfiles) profile.id: profile,
    };

    expect(profiles.keys, containsAll(['cet4', 'cet6', 'graduate', 'oxford']));
    expect(profiles['cet4']!.status, DictionaryCoverageStatus.building);
    expect(profiles['cet6']!.status, DictionaryCoverageStatus.building);
    expect(profiles['graduate']!.status, DictionaryCoverageStatus.building);
    expect(profiles['oxford']!.status, DictionaryCoverageStatus.planned);
    expect(profiles['oxford']!.description, contains('不复制牛津版权内容'));
  });

  test(
    'indexes exact words, variants, and coverage bands for published entries',
    () {
      final catalog = builtInDictionaryCatalog();
      final index = DictionaryCatalogIndex(catalog);

      expect(index.lookupExact('ABILITY')!.lemma, 'ability');
      expect(
        index.search('evid').map((entry) => entry.lemma),
        containsAll(<String>['evidence', 'evident']),
      );
      expect(index.countForCoverageBand('foundation'), greaterThan(0));
      expect(index.search('apple', coverageBand: 'cet4'), isEmpty);

      final custom = _manifest();
      final customIndex = DictionaryCatalogIndex(custom);
      expect(customIndex.lookupExact('HELLO')!.entryId, 'yixue-starter.hello');
      expect(customIndex.countForCoverageBand('cet4'), 1);
    },
  );

  test('keeps the next self-authored batch visible by coverage band', () {
    final catalog = builtInDictionaryCatalog();
    final index = DictionaryCatalogIndex(catalog);

    expect(catalog.entries.length, greaterThanOrEqualTo(240));
    expect(index.lookupExact('ACADEMIC')!.coverageBands, contains('cet4'));
    expect(
      index.lookupExact('HYPOTHESIS')!.coverageBands,
      contains('graduate'),
    );
    expect(index.lookupExact('SUSTAINABLE')!.coverageBands, contains('cet6'));
    expect(index.countForCoverageBand('cet4'), greaterThan(0));
    expect(index.countForCoverageBand('cet6'), greaterThan(0));
    expect(index.countForCoverageBand('graduate'), greaterThan(0));
  });

  test('reports actual coverage without turning planned bands into claims', () {
    final catalog = builtInDictionaryCatalog();
    final report = DictionaryCoverageReport.fromManifest(catalog);

    expect(report.totalEntries, catalog.entries.length);
    expect(report.publishedEntries, catalog.entries.length);
    expect(report.countFor('foundation'), greaterThan(0));
    expect(report.countFor('cet4'), greaterThan(0));
    expect(report.countFor('cet6'), greaterThan(0));
    expect(report.countFor('graduate'), greaterThan(0));
    expect(report.countFor('oxford'), 0);
    expect(report.statusFor('oxford'), DictionaryCoverageStatus.planned);
  });

  test(
    'ships the first YX-500 slice with searchable exam and academic bands',
    () {
      final catalog = builtInDictionaryCatalog();
      final index = DictionaryCatalogIndex(catalog);

      expect(catalog.entries.length, greaterThanOrEqualTo(500));
      expect(catalog.version, '0.4.0');
      expect(catalog.sourceRecords.single.version, '0.4.0');
      expect(index.lookupExact('algorithm')!.coverageBands, contains('cet4'));
      expect(index.lookupExact('methodology')!.coverageBands, contains('cet6'));
      expect(
        index.lookupExact('interpretation')!.coverageBands,
        contains('graduate'),
      );
      expect(index.lookupExact('well-being')!.lemma, 'well-being');
      expect(index.search('collabor').single.lemma, 'collaborate');
    },
  );

  test('ships the first CET4 vocabulary coverage batch', () {
    final catalog = builtInDictionaryCatalog();
    final index = DictionaryCatalogIndex(catalog);

    expect(catalog.entries.length, greaterThanOrEqualTo(600));
    expect(catalog.version, '0.4.0');
    expect(catalog.sourceRecords.single.version, '0.4.0');
    expect(index.lookupExact('absence')!.coverageBands, contains('cet4'));
    expect(index.lookupExact('coordinate')!.coverageBands, contains('cet4'));
    expect(index.lookupExact('duration')!.coverageBands, contains('cet4'));
  });
}
