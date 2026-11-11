import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:yixue_app/core/native_core_bridge.dart';

/// Returns the stable source id stored before the human-readable metadata.
///
/// Imported packages store sources as `id · name · license`; old records may
/// contain only the id, so both forms remain readable.
String dictionarySourceId(String rawSource) {
  final source = rawSource.trim();
  if (source.isEmpty) return 'unknown';
  return source.split(' · ').first.trim();
}

class DictionarySourcePreference {
  const DictionarySourcePreference({
    required this.id,
    required this.displayName,
    required this.license,
    this.enabled = true,
  });

  final String id;
  final String displayName;
  final String license;
  final bool enabled;

  DictionarySourcePreference copyWith({
    String? displayName,
    String? license,
    bool? enabled,
  }) => DictionarySourcePreference(
    id: id,
    displayName: displayName ?? this.displayName,
    license: license ?? this.license,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'displayName': displayName,
    'license': license,
    'enabled': enabled,
  };

  factory DictionarySourcePreference.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final displayName = json['displayName'];
    final license = json['license'];
    if (id is! String ||
        displayName is! String ||
        license is! String ||
        id.trim().isEmpty ||
        id.length > 128 ||
        displayName.trim().isEmpty ||
        displayName.length > 256 ||
        license.trim().isEmpty ||
        license.length > 256) {
      throw const FormatException('invalid dictionary source preference');
    }
    return DictionarySourcePreference(
      id: id.trim(),
      displayName: displayName.trim(),
      license: license.trim(),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
    );
  }
}

class DictionaryPreferences {
  const DictionaryPreferences({
    this.sources = const [
      DictionarySourcePreference(
        id: 'yixue-basic',
        displayName: '译学基础词典',
        license: '项目内置',
      ),
    ],
  });

  final List<DictionarySourcePreference> sources;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'sources': sources.map((source) => source.toJson()).toList(growable: false),
  };

  factory DictionaryPreferences.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 || json['sources'] is! List<dynamic>) {
      throw const FormatException('unsupported dictionary preference schema');
    }
    final rawSources = json['sources'] as List<dynamic>;
    if (rawSources.length > 128) {
      throw const FormatException('too many dictionary sources');
    }
    final sources = rawSources
        .map((value) {
          if (value is! Map<String, dynamic>) {
            throw const FormatException('invalid dictionary source object');
          }
          return DictionarySourcePreference.fromJson(value);
        })
        .toList(growable: false);
    final ids = sources.map((source) => source.id).toSet();
    if (ids.length != sources.length) {
      throw const FormatException('duplicate dictionary source id');
    }
    return DictionaryPreferences(sources: List.unmodifiable(sources));
  }

  bool isEnabled(String sourceId) =>
      sources.any((source) => source.id == sourceId && source.enabled);

  /// Sorts records by the user's source order and removes disabled sources.
  /// Unknown sources remain available after configured sources so old data is
  /// not silently lost; the user can import/register them again from settings.
  List<DictionaryEntryData> sortEntries(List<DictionaryEntryData> entries) {
    if (sources.isEmpty) return List.unmodifiable(entries);
    final ranks = <String, int>{
      for (var index = 0; index < sources.length; index++)
        sources[index].id: index,
    };
    final enabled = {
      for (final source in sources.where((source) => source.enabled)) source.id,
    };
    final indexed = <({DictionaryEntryData entry, int index})>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final sourceId = dictionarySourceId(entry.source);
      if (ranks.containsKey(sourceId) && !enabled.contains(sourceId)) continue;
      indexed.add((entry: entry, index: index));
    }
    indexed.sort((left, right) {
      final leftRank =
          ranks[left.entry.source] ??
          ranks[dictionarySourceId(left.entry.source)] ??
          sources.length;
      final rightRank =
          ranks[right.entry.source] ??
          ranks[dictionarySourceId(right.entry.source)] ??
          sources.length;
      final byRank = leftRank.compareTo(rightRank);
      return byRank == 0 ? left.index.compareTo(right.index) : byRank;
    });
    return List.unmodifiable(indexed.map((item) => item.entry));
  }

  DictionaryPreferences registerSource({
    required String id,
    required String displayName,
    required String license,
  }) {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) return this;
    final index = sources.indexWhere((source) => source.id == normalizedId);
    final nextSource = DictionarySourcePreference(
      id: normalizedId,
      displayName: displayName.trim().isEmpty
          ? normalizedId
          : displayName.trim(),
      license: license.trim().isEmpty ? '未提供' : license.trim(),
    );
    final next = [...sources];
    if (index >= 0) {
      next[index] = nextSource.copyWith(enabled: sources[index].enabled);
    } else {
      next.add(nextSource);
    }
    return DictionaryPreferences(sources: List.unmodifiable(next));
  }

  DictionaryPreferences setEnabled(String id, bool enabled) =>
      _mapSource(id, (source) => source.copyWith(enabled: enabled));

  DictionaryPreferences move(String id, int offset) {
    final index = sources.indexWhere((source) => source.id == id);
    final target = index + offset;
    if (index < 0 || target < 0 || target >= sources.length) return this;
    final next = [...sources];
    final source = next.removeAt(index);
    next.insert(target, source);
    return DictionaryPreferences(sources: List.unmodifiable(next));
  }

  DictionaryPreferences _mapSource(
    String id,
    DictionarySourcePreference Function(DictionarySourcePreference source) map,
  ) {
    final index = sources.indexWhere((source) => source.id == id);
    if (index < 0) return this;
    final next = [...sources];
    next[index] = map(next[index]);
    return DictionaryPreferences(sources: List.unmodifiable(next));
  }
}

abstract interface class DictionaryPreferencesStore {
  Future<DictionaryPreferences?> read();

  Future<void> write(DictionaryPreferences preferences);
}

class FileDictionaryPreferencesStore implements DictionaryPreferencesStore {
  FileDictionaryPreferencesStore(this.file);

  final File file;

  @override
  Future<DictionaryPreferences?> read() async {
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) return null;
      return DictionaryPreferences.fromJson(value);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on JsonUnsupportedObjectError {
      return null;
    }
  }

  @override
  Future<void> write(DictionaryPreferences preferences) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(preferences.toJson()), flush: true);
  }
}

class DictionaryPreferencesController extends ChangeNotifier {
  DictionaryPreferencesController({DictionaryPreferences? initialValue})
    : _value = initialValue ?? const DictionaryPreferences();

  DictionaryPreferences _value;

  DictionaryPreferences get value => _value;

  void update(DictionaryPreferences value) {
    _value = value;
    notifyListeners();
  }
}
