import 'dictionary_service.dart';

enum DictionaryQualityStatus { draft, reviewed, published, withdrawn }

extension DictionaryQualityStatusWireName on DictionaryQualityStatus {
  String get wireName => switch (this) {
    DictionaryQualityStatus.draft => 'draft',
    DictionaryQualityStatus.reviewed => 'reviewed',
    DictionaryQualityStatus.published => 'published',
    DictionaryQualityStatus.withdrawn => 'withdrawn',
  };

  static DictionaryQualityStatus? fromWireName(String value) {
    for (final status in DictionaryQualityStatus.values) {
      if (status.wireName == value) return status;
    }
    return null;
  }
}

enum DictionaryCoverageStatus { seed, building, planned }

extension DictionaryCoverageStatusWireName on DictionaryCoverageStatus {
  String get wireName => switch (this) {
    DictionaryCoverageStatus.seed => 'seed',
    DictionaryCoverageStatus.building => 'building',
    DictionaryCoverageStatus.planned => 'planned',
  };
}

class DictionaryCoverageProfile {
  const DictionaryCoverageProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.status,
  });

  final String id;
  final String label;
  final String description;
  final DictionaryCoverageStatus status;
}

/// Coverage is an editorial target, not a claim that the current seed already
/// contains every word in that band. Each band is expanded only after source,
/// licensing, meaning, example, and human review are recorded.
const dictionaryCoverageProfiles = <DictionaryCoverageProfile>[
  DictionaryCoverageProfile(
    id: 'foundation',
    label: '译学基础词典',
    description: '当前随包的自写英汉学习词条，作为快速翻译和学习功能的最小公共基础。',
    status: DictionaryCoverageStatus.seed,
  ),
  DictionaryCoverageProfile(
    id: 'cet4',
    label: '大学英语四级',
    description: '按公开考试要求建立覆盖校验集，再逐条补充义项、搭配和双语例句。',
    status: DictionaryCoverageStatus.building,
  ),
  DictionaryCoverageProfile(
    id: 'cet6',
    label: '大学英语六级',
    description: '在四级基础上扩展抽象义、学术语域、固定搭配和阅读常见用法。',
    status: DictionaryCoverageStatus.building,
  ),
  DictionaryCoverageProfile(
    id: 'graduate',
    label: '考研英语',
    description: '按公开要求和真题语境建立扩展包，不把未经授权的真题整句复制进词典。',
    status: DictionaryCoverageStatus.building,
  ),
  DictionaryCoverageProfile(
    id: 'oxford',
    label: '牛津级学习覆盖目标',
    description: '目标是达到完整词形、词性、义项、语域、搭配和例句的学习覆盖，不复制牛津版权内容。',
    status: DictionaryCoverageStatus.planned,
  ),
];

/// Records what the official CET evidence can actually prove. The official
/// pages currently expose the syllabus and assessment structure, not a
/// machine-readable CET4/CET6 word list.
class DictionaryScopeAudit {
  const DictionaryScopeAudit({
    required this.officialSourceTitle,
    required this.officialSourceUrl,
    required this.machineComparable,
    required this.statusLabel,
    required this.detail,
  });

  final String officialSourceTitle;
  final String officialSourceUrl;
  final bool machineComparable;
  final String statusLabel;
  final String detail;
}

const cetEnglishDictionaryScopeAudit = DictionaryScopeAudit(
  officialSourceTitle: '全国大学英语四、六级考试大纲（2016年修订版）',
  officialSourceUrl: 'https://cet.neea.edu.cn/res/Home/1704/55b02330ac17274664f06d9d3db8249d.pdf',
  machineComparable: false,
  statusLabel: '官方资料已登记 · 无可机器比对词表',
  detail: '当前只能证明考试大纲与考核范围入口已核实，开放词目数量不等同官方词表完成。',
);

/// A read-only snapshot of the coverage that is actually present in a
/// catalogue. Planned profiles remain planned; a non-zero count alone is not
/// treated as proof that an exam or commercial dictionary has been completed.
class DictionaryCoverageReport {
  DictionaryCoverageReport({
    required this.totalEntries,
    required this.publishedEntries,
    required Map<String, int> entriesByBand,
    required Map<String, int> publishedEntriesByBand,
    required this.entriesWithoutCoverageBand,
  }) : entriesByBand = Map.unmodifiable(entriesByBand),
       publishedEntriesByBand = Map.unmodifiable(publishedEntriesByBand);

  factory DictionaryCoverageReport.fromManifest(
    DictionaryCatalogManifest manifest,
  ) {
    final allCounts = <String, int>{};
    final publishedCounts = <String, int>{};
    var publishedEntries = 0;
    var entriesWithoutCoverageBand = 0;

    for (final entry in manifest.entries) {
      final bands = entry.coverageBands
          .map(_normalizeLookup)
          .where((band) => band.isNotEmpty)
          .toSet();
      if (bands.isEmpty) entriesWithoutCoverageBand++;
      for (final band in bands) {
        allCounts[band] = (allCounts[band] ?? 0) + 1;
      }
      if (entry.quality.status == DictionaryQualityStatus.published) {
        publishedEntries++;
        for (final band in bands) {
          publishedCounts[band] = (publishedCounts[band] ?? 0) + 1;
        }
      }
    }

    return DictionaryCoverageReport(
      totalEntries: manifest.entries.length,
      publishedEntries: publishedEntries,
      entriesByBand: allCounts,
      publishedEntriesByBand: publishedCounts,
      entriesWithoutCoverageBand: entriesWithoutCoverageBand,
    );
  }

  /// Reports the complete runtime vocabulary, including open source base
  /// rows that are searchable but still awaiting project editorial enrichment.
  ///
  /// This is deliberately separate from [fromManifest]: the authored v2
  /// catalogue is publishable, while the open CET layer is a traceable
  /// foundation and must not be silently labelled as authored content.
  factory DictionaryCoverageReport.fromRuntimeDictionary(
    Iterable<DictionaryEntry> entries,
  ) {
    final allCounts = <String, int>{};
    final publishedCounts = <String, int>{};
    var totalEntries = 0;
    var publishedEntries = 0;
    var entriesWithoutCoverageBand = 0;

    for (final entry in entries) {
      totalEntries++;
      final bands = entry.coverageBands
          .map(_normalizeLookup)
          .where((band) => band.isNotEmpty)
          .toSet();
      if (bands.isEmpty) entriesWithoutCoverageBand++;
      for (final band in bands) {
        allCounts[band] = (allCounts[band] ?? 0) + 1;
      }
      if (entry.hasExample && !entry.needsEditorialEnrichment) {
        publishedEntries++;
        for (final band in bands) {
          publishedCounts[band] = (publishedCounts[band] ?? 0) + 1;
        }
      }
    }

    return DictionaryCoverageReport(
      totalEntries: totalEntries,
      publishedEntries: publishedEntries,
      entriesByBand: allCounts,
      publishedEntriesByBand: publishedCounts,
      entriesWithoutCoverageBand: entriesWithoutCoverageBand,
    );
  }

  final int totalEntries;
  final int publishedEntries;
  final Map<String, int> entriesByBand;
  final Map<String, int> publishedEntriesByBand;
  final int entriesWithoutCoverageBand;

  int countFor(String coverageBand, {bool publishedOnly = true}) {
    final band = _normalizeLookup(coverageBand);
    if (band.isEmpty) return 0;
    final counts = publishedOnly ? publishedEntriesByBand : entriesByBand;
    return counts[band] ?? 0;
  }

  DictionaryCoverageStatus statusFor(String coverageBand) {
    final band = _normalizeLookup(coverageBand);
    for (final profile in dictionaryCoverageProfiles) {
      if (profile.id == band) return profile.status;
    }
    return DictionaryCoverageStatus.planned;
  }
}

class DictionaryCatalogException implements Exception {
  const DictionaryCatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DictionarySourceRecord {
  const DictionarySourceRecord({
    required this.id,
    required this.name,
    required this.version,
    required this.license,
    required this.attribution,
    this.url,
    this.notes,
  });

  final String id;
  final String name;
  final String version;
  final String license;
  final String attribution;
  final String? url;
  final String? notes;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'version': version,
    'license': license,
    'attribution': attribution,
    if (url != null) 'url': url,
    if (notes != null) 'notes': notes,
  };

  factory DictionarySourceRecord.fromJson(Map<String, dynamic> json) =>
      DictionarySourceRecord(
        id: _requiredText(json['id'], 'source record 缺少 id'),
        name: _requiredText(json['name'], 'source record 缺少 name'),
        version: _requiredText(json['version'], 'source record 缺少 version'),
        license: _requiredText(json['license'], 'source record 缺少 license'),
        attribution: _requiredText(
          json['attribution'],
          'source record 缺少 attribution',
        ),
        url: _optionalText(json['url'], 'source record url 格式无效'),
        notes: _optionalText(json['notes'], 'source record notes 格式无效'),
      );
}

class DictionaryExample {
  const DictionaryExample({
    required this.text,
    required this.translation,
    required this.sourceId,
  });

  final String text;
  final String translation;
  final String sourceId;

  Map<String, Object> toJson() => <String, Object>{
    'text': text,
    'translation': translation,
    'source_id': sourceId,
  };

  factory DictionaryExample.fromJson(Map<String, dynamic> json) =>
      DictionaryExample(
        text: _requiredText(json['text'], 'example 缺少 text'),
        translation: _requiredText(
          json['translation'],
          'example 缺少 translation',
        ),
        sourceId: _requiredText(json['source_id'], 'example 缺少 source_id'),
      );
}

class DictionarySense {
  const DictionarySense({
    required this.id,
    required this.meanings,
    required this.usage,
    required this.domain,
    required this.examples,
  });

  final String id;
  final List<String> meanings;
  final String usage;
  final String domain;
  final List<DictionaryExample> examples;

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'meanings': meanings,
    'usage': usage,
    'domain': domain,
    'examples': examples.map((example) => example.toJson()).toList(),
  };

  factory DictionarySense.fromJson(Map<String, dynamic> json) {
    final meanings = _requiredTextList(json['meanings'], 'sense meanings');
    final rawExamples = json['examples'];
    if (rawExamples is! List<dynamic> || rawExamples.isEmpty) {
      throw const DictionaryCatalogException('sense examples 必须至少有一条');
    }
    return DictionarySense(
      id: _requiredText(json['id'], 'sense 缺少 id'),
      meanings: meanings,
      usage: _requiredText(json['usage'], 'sense 缺少 usage'),
      domain: _requiredText(json['domain'], 'sense 缺少 domain'),
      examples: List.unmodifiable(
        rawExamples.map((value) {
          if (value is! Map<String, dynamic>) {
            throw const DictionaryCatalogException('sense example 格式无效');
          }
          return DictionaryExample.fromJson(value);
        }),
      ),
    );
  }
}

class DictionaryQuality {
  const DictionaryQuality({
    required this.status,
    required this.reviewer,
    required this.reviewedAt,
    this.notes,
  });

  final DictionaryQualityStatus status;
  final String reviewer;
  final String reviewedAt;
  final String? notes;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.wireName,
    'reviewer': reviewer,
    'reviewed_at': reviewedAt,
    if (notes != null) 'notes': notes,
  };

  factory DictionaryQuality.fromJson(Map<String, dynamic> json) {
    final status = DictionaryQualityStatusWireName.fromWireName(
      json['status'] as String? ?? '',
    );
    if (status == null) {
      throw const DictionaryCatalogException('quality status 不受支持');
    }
    return DictionaryQuality(
      status: status,
      reviewer: _requiredText(json['reviewer'], 'quality 缺少 reviewer'),
      reviewedAt: _requiredText(json['reviewed_at'], 'quality 缺少 reviewed_at'),
      notes: _optionalText(json['notes'], 'quality notes 格式无效'),
    );
  }
}

class DictionaryCatalogEntry {
  const DictionaryCatalogEntry({
    required this.entryId,
    required this.languagePair,
    required this.lemma,
    required this.variants,
    required this.ipa,
    required this.partOfSpeech,
    required this.senses,
    required this.collocations,
    required this.learningTags,
    this.coverageBands = const [],
    required this.relations,
    required this.sourceIds,
    required this.quality,
  });

  final String entryId;
  final String languagePair;
  final String lemma;
  final List<String> variants;
  final Map<String, String> ipa;
  final String partOfSpeech;
  final List<DictionarySense> senses;
  final List<String> collocations;
  final List<String> learningTags;
  final List<String> coverageBands;
  final Map<String, List<String>> relations;
  final List<String> sourceIds;
  final DictionaryQuality quality;

  DictionaryEntry toRuntimeEntry() {
    final sense = senses.first;
    final example = sense.examples.first;
    return DictionaryEntry(
      word: lemma,
      ipa: ipa['uk'] ?? ipa['us'] ?? ipa.values.first,
      partOfSpeech: partOfSpeech,
      meanings: sense.meanings,
      example: example.text,
      exampleTranslation: example.translation,
      source: sourceIds.first,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'entry_id': entryId,
    'language_pair': languagePair,
    'lemma': lemma,
    'variants': variants,
    'ipa': ipa,
    'part_of_speech': partOfSpeech,
    'senses': senses.map((sense) => sense.toJson()).toList(),
    'collocations': collocations,
    'learning_tags': learningTags,
    'coverage_bands': coverageBands,
    'relations': relations,
    'source_ids': sourceIds,
    'quality': quality.toJson(),
  };

  factory DictionaryCatalogEntry.fromJson(Map<String, dynamic> json) {
    final rawIpa = json['ipa'];
    final rawSenses = json['senses'];
    final rawRelations = json['relations'];
    if (rawIpa is! Map<String, dynamic> || rawIpa.isEmpty) {
      throw const DictionaryCatalogException('entry ipa 必须是非空对象');
    }
    if (rawSenses is! List<dynamic> || rawSenses.isEmpty) {
      throw const DictionaryCatalogException('entry senses 必须至少有一项');
    }
    if (rawRelations is! Map<String, dynamic>) {
      throw const DictionaryCatalogException('entry relations 必须是对象');
    }
    final relations = <String, List<String>>{};
    for (final item in rawRelations.entries) {
      relations[item.key] = _requiredTextList(
        item.value,
        'entry relations.${item.key}',
      );
    }
    return DictionaryCatalogEntry(
      entryId: _requiredText(json['entry_id'], 'entry 缺少 entry_id'),
      languagePair: _requiredText(
        json['language_pair'],
        'entry 缺少 language_pair',
      ),
      lemma: _requiredText(json['lemma'], 'entry 缺少 lemma'),
      variants: _optionalTextList(json['variants'], 'entry variants 格式无效'),
      ipa: Map.unmodifiable(
        rawIpa.map((key, value) {
          if (value is! String || value.trim().isEmpty) {
            throw const DictionaryCatalogException('entry ipa 值无效');
          }
          return MapEntry(key, value.trim());
        }),
      ),
      partOfSpeech: _requiredText(
        json['part_of_speech'],
        'entry 缺少 part_of_speech',
      ),
      senses: List.unmodifiable(
        rawSenses.map((value) {
          if (value is! Map<String, dynamic>) {
            throw const DictionaryCatalogException('entry sense 格式无效');
          }
          return DictionarySense.fromJson(value);
        }),
      ),
      collocations: _optionalTextList(
        json['collocations'],
        'entry collocations 格式无效',
      ),
      learningTags: _optionalTextList(
        json['learning_tags'],
        'entry learning_tags 格式无效',
      ),
      coverageBands: _optionalTextList(
        json['coverage_bands'],
        'entry coverage_bands 格式无效',
      ),
      relations: Map.unmodifiable(relations),
      sourceIds: _requiredTextList(json['source_ids'], 'entry 缺少 source_ids'),
      quality: _quality(json['quality']),
    );
  }
}

/// In-memory lookup used by quick translation and the future learning page.
/// It exposes only published entries by default, so draft or withdrawn content
/// cannot accidentally appear in user-facing explanations.
class DictionaryCatalogIndex {
  DictionaryCatalogIndex(
    DictionaryCatalogManifest manifest, {
    bool includeUnpublished = false,
  }) : _entries = List.unmodifiable(
         manifest.entries.where(
           (entry) =>
               includeUnpublished ||
               entry.quality.status == DictionaryQualityStatus.published,
         ),
       ),
       _exact = _buildExact(
         manifest.entries.where(
           (entry) =>
               includeUnpublished ||
               entry.quality.status == DictionaryQualityStatus.published,
         ),
       );

  final List<DictionaryCatalogEntry> _entries;
  final Map<String, DictionaryCatalogEntry> _exact;

  DictionaryCatalogEntry? lookupExact(String query) {
    final normalized = _normalizeLookup(query);
    if (normalized.isEmpty) return null;
    return _exact[normalized];
  }

  List<DictionaryCatalogEntry> search(
    String query, {
    String? coverageBand,
    int limit = 20,
  }) {
    if (limit <= 0) return const [];
    final normalized = _normalizeLookup(query);
    if (normalized.isEmpty) return const [];
    final band = coverageBand == null ? null : _normalizeLookup(coverageBand);
    final matches = <DictionaryCatalogEntry>[];
    final exact = _exact[normalized];
    if (exact != null && _matchesBand(exact, band)) {
      matches.add(exact);
    }
    for (final entry in _entries) {
      if (matches.any((item) => item.entryId == entry.entryId)) continue;
      if (!_matchesBand(entry, band)) continue;
      final searchable = <String>[
        entry.lemma,
        ...entry.variants,
      ].map(_normalizeLookup);
      if (searchable.any((value) => value.contains(normalized))) {
        matches.add(entry);
        if (matches.length == limit) break;
      }
    }
    return List.unmodifiable(matches.take(limit));
  }

  List<DictionaryCatalogEntry> forCoverageBand(
    String coverageBand, {
    int? limit,
  }) {
    final band = _normalizeLookup(coverageBand);
    if (band.isEmpty) return const [];
    final entries = _entries
        .where((entry) => _matchesBand(entry, band))
        .toList(growable: false);
    if (limit == null || limit >= entries.length) {
      return List.unmodifiable(entries);
    }
    if (limit <= 0) return const [];
    return List.unmodifiable(entries.take(limit));
  }

  int countForCoverageBand(String coverageBand) =>
      forCoverageBand(coverageBand).length;

  static Map<String, DictionaryCatalogEntry> _buildExact(
    Iterable<DictionaryCatalogEntry> entries,
  ) {
    final exact = <String, DictionaryCatalogEntry>{};
    for (final entry in entries) {
      for (final term in [entry.lemma, ...entry.variants]) {
        final normalized = _normalizeLookup(term);
        if (normalized.isNotEmpty) exact.putIfAbsent(normalized, () => entry);
      }
    }
    return Map.unmodifiable(exact);
  }

  static bool _matchesBand(
    DictionaryCatalogEntry entry,
    String? normalizedBand,
  ) {
    if (normalizedBand == null || normalizedBand.isEmpty) return true;
    return entry.coverageBands.map(_normalizeLookup).contains(normalizedBand);
  }
}

String _normalizeLookup(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

class DictionaryCatalogManifest {
  const DictionaryCatalogManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.languagePair,
    required this.license,
    required this.attribution,
    required this.redistributionAllowed,
    required this.sourceRecords,
    required this.entries,
  });

  static const schemaVersion = 2;

  final String id;
  final String name;
  final String version;
  final String languagePair;
  final String license;
  final String attribution;
  final bool redistributionAllowed;
  final List<DictionarySourceRecord> sourceRecords;
  final List<DictionaryCatalogEntry> entries;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': schemaVersion,
    'id': id,
    'name': name,
    'version': version,
    'language_pair': languagePair,
    'license': license,
    'attribution': attribution,
    'redistribution_allowed': redistributionAllowed,
    'source_records': sourceRecords.map((source) => source.toJson()).toList(),
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  factory DictionaryCatalogManifest.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != schemaVersion) {
      throw const DictionaryCatalogException('词典内部 v2 版本不受支持');
    }
    final rawSources = json['source_records'];
    final rawEntries = json['entries'];
    if (rawSources is! List<dynamic> || rawSources.isEmpty) {
      throw const DictionaryCatalogException('source_records 必须至少有一项');
    }
    if (rawEntries is! List<dynamic> || rawEntries.isEmpty) {
      throw const DictionaryCatalogException('entries 必须至少有一项');
    }
    final sourceRecords = List<DictionarySourceRecord>.unmodifiable(
      rawSources.map<DictionarySourceRecord>((value) {
        if (value is! Map<String, dynamic>) {
          throw const DictionaryCatalogException('source record 格式无效');
        }
        return DictionarySourceRecord.fromJson(value);
      }),
    );
    final sourceIds = sourceRecords.map((source) => source.id).toSet();
    if (sourceIds.length != sourceRecords.length) {
      throw const DictionaryCatalogException('source_records 存在重复 id');
    }
    final entries = List<DictionaryCatalogEntry>.unmodifiable(
      rawEntries.map<DictionaryCatalogEntry>((value) {
        if (value is! Map<String, dynamic>) {
          throw const DictionaryCatalogException('entry 格式无效');
        }
        final entry = DictionaryCatalogEntry.fromJson(value);
        if (entry.languagePair != json['language_pair']) {
          throw const DictionaryCatalogException('entry language_pair 与词典不一致');
        }
        for (final sourceId in entry.sourceIds) {
          if (!sourceIds.contains(sourceId)) {
            throw const DictionaryCatalogException(
              'entry source_ids 引用了不存在的来源',
            );
          }
        }
        for (final sense in entry.senses) {
          for (final example in sense.examples) {
            if (!sourceIds.contains(example.sourceId)) {
              throw const DictionaryCatalogException(
                'example source_id 引用了不存在的来源',
              );
            }
          }
        }
        return entry;
      }),
    );
    final ids = entries.map((entry) => entry.entryId).toSet();
    if (ids.length != entries.length) {
      throw const DictionaryCatalogException('entries 存在重复 entry_id');
    }
    return DictionaryCatalogManifest(
      id: _requiredText(json['id'], '词典缺少 id'),
      name: _requiredText(json['name'], '词典缺少 name'),
      version: _requiredText(json['version'], '词典缺少 version'),
      languagePair: _requiredText(json['language_pair'], '词典缺少 language_pair'),
      license: _requiredText(json['license'], '词典缺少 license'),
      attribution: _requiredText(json['attribution'], '词典缺少 attribution'),
      redistributionAllowed: json['redistribution_allowed'] is bool
          ? json['redistribution_allowed'] as bool
          : false,
      sourceRecords: sourceRecords,
      entries: entries,
    );
  }

  /// Converts reviewed, publishable entries to the existing user import
  /// contract. The public v1 package intentionally keeps only the fields the
  /// current runtime and database can persist; v2 remains the authoring SSOT.
  Map<String, Object?> toV1Package() {
    if (!redistributionAllowed) {
      throw const DictionaryCatalogException('个人词典不允许导出为公开词典包');
    }
    if (entries.any(
      (entry) => entry.quality.status != DictionaryQualityStatus.published,
    )) {
      throw const DictionaryCatalogException('只有 published 词条才能导出公开词典包');
    }
    return <String, Object?>{
      'schema_version': 1,
      'id': id,
      'name': name,
      'language_pair': languagePair,
      'license': license,
      'entries': entries.map((entry) {
        final runtime = entry.toRuntimeEntry();
        return <String, Object>{
          'word': runtime.word,
          'ipa': runtime.ipa,
          'part_of_speech': runtime.partOfSpeech,
          'meanings': runtime.meanings,
          'example': runtime.example,
          'example_translation': runtime.exampleTranslation,
        };
      }).toList(),
    };
  }
}

/// Presents the bundled self-authored seed in the v2 authoring shape without
/// changing the runtime/database v1 contract. The richer fields are ready for
/// later editorial passes; the current seed remains the single source used by
/// quick translation until a generated v2 package is adopted by the runtime.
DictionaryCatalogManifest builtInDictionaryCatalog() {
  const dictionary = LocalDictionaryService();
  return DictionaryCatalogManifest(
    id: 'yixue-basic.en-zh',
    name: '译学自写英汉基础词典',
    version: '0.4.0',
    languagePair: 'en-zh',
    license: '译学自写内容 · 译学项目许可',
    attribution: '花鱼鱼',
    redistributionAllowed: true,
    sourceRecords: const [
      DictionarySourceRecord(
        id: 'yixue-authored',
        name: '译学自写',
        version: '0.4.0',
        license: '译学自写内容 · 译学项目许可',
        attribution: '花鱼鱼',
      ),
    ],
    entries: dictionary.entries
        .where((entry) => !entry.needsEditorialEnrichment)
        .map(
          (entry) => DictionaryCatalogEntry(
            entryId: 'yixue-basic.${entry.word}',
            languagePair: 'en-zh',
            lemma: entry.word,
            variants: const [],
            ipa: {'uk': entry.ipa},
            partOfSpeech: entry.partOfSpeech,
            senses: [
              DictionarySense(
                id: 'yixue-basic.${entry.word}.1',
                meanings: entry.meanings,
                usage: '常用学习词义；需要结合上下文选择含义。',
                domain: '日常 / 学习 / 阅读',
                examples: [
                  DictionaryExample(
                    text: entry.example,
                    translation: entry.exampleTranslation,
                    sourceId: 'yixue-authored',
                  ),
                ],
              ),
            ],
            collocations: const [],
            learningTags: const ['日常', '学习', '英汉'],
            coverageBands: entry.coverageBands,
            relations: const {},
            sourceIds: const ['yixue-authored'],
            quality: const DictionaryQuality(
              status: DictionaryQualityStatus.published,
              reviewer: '译学项目维护者',
              reviewedAt: '2026-09-15',
            ),
          ),
        )
        .toList(growable: false),
  );
}

DictionaryQuality _quality(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const DictionaryCatalogException('entry 缺少 quality');
  }
  return DictionaryQuality.fromJson(value);
}

String _requiredText(dynamic value, String message) {
  if (value is! String) throw DictionaryCatalogException(message);
  final text = value.trim();
  if (text.isEmpty || text.length > 2_000) {
    throw DictionaryCatalogException(message);
  }
  return text;
}

String? _optionalText(dynamic value, String message) {
  if (value == null) return null;
  return _requiredText(value, message);
}

List<String> _requiredTextList(dynamic value, String message) {
  if (value is! List<dynamic> || value.isEmpty || value.length > 128) {
    throw DictionaryCatalogException(message);
  }
  return List.unmodifiable(value.map((item) => _requiredText(item, message)));
}

List<String> _optionalTextList(dynamic value, String message) {
  if (value == null) return const [];
  if (value is! List<dynamic> || value.length > 128) {
    throw DictionaryCatalogException(message);
  }
  return List.unmodifiable(value.map((item) => _requiredText(item, message)));
}
