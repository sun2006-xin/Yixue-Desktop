import 'dictionary_cet_open_entries_part01.dart';
import 'dictionary_cet_open_entries_part02.dart';
import 'dictionary_cet_open_entries_part03.dart';
import 'dictionary_cet_open_entries_part04.dart';
import 'dictionary_cet_open_entries_part05.dart';
import 'dictionary_cet_open_entries_part06.dart';
import 'dictionary_cet_open_entries_part07.dart';
import 'dictionary_cet_open_entries_part08.dart';

/// Pinned metadata for the open vocabulary source used by the CET baseline.
///
/// This source is a word-list and basic-translation layer derived from ECDICT;
/// it is not the Oxford dictionary and it is not treated as project-authored
/// or human-reviewed content. The source attribution and MIT notice are kept
/// in the project dictionary-source register.
const openCetDictionarySourceId = 'open-ecdict';
const openCetDictionarySourceVersion = 'wordtyper-vocabularies-2.0.0';
const openCetDictionarySourceUrl =
    'https://github.com/grhliu/wordtyper-vocabularies';
const openCetDictionarySourceLicense = 'MIT';

const openCet4SourceWordCount = 3815;
const openCet6SourceWordCount = 5371;
const openCetUniqueWordCount = 5759;
const openCetSourceMissingPhoneticRecordCount = 35;
const openCetMissingPhoneticCount = 29;

/// One row from the open word-list layer.
class OpenCetDictionaryRow {
  const OpenCetDictionaryRow({
    required this.word,
    required this.ipa,
    required this.coverageBands,
    required this.sourceTranslations,
  });

  final String word;
  final String ipa;
  final List<String> coverageBands;
  final List<String> sourceTranslations;

  String get partOfSpeech => _openPartOfSpeech(sourceTranslations);

  List<String> get meanings => _openMeanings(sourceTranslations);
}

final yxOpenCetDictionaryRows = List<OpenCetDictionaryRow>.unmodifiable(
  [
    ...yxOpenCetWireRowsPart01,
    ...yxOpenCetWireRowsPart02,
    ...yxOpenCetWireRowsPart03,
    ...yxOpenCetWireRowsPart04,
    ...yxOpenCetWireRowsPart05,
    ...yxOpenCetWireRowsPart06,
    ...yxOpenCetWireRowsPart07,
    ...yxOpenCetWireRowsPart08,
  ].map(_parseOpenCetRow),
);

OpenCetDictionaryRow _parseOpenCetRow(String wire) {
  final fields = wire.split('|');
  if (fields.length != 4 || fields.any((field) => field.trim().isEmpty)) {
    throw FormatException('Invalid open CET row: $wire');
  }
  final translations = fields[3]
      .split('~')
      .map((translation) => translation.trim())
      .where((translation) => translation.isNotEmpty)
      .toList(growable: false);
  if (translations.isEmpty) {
    throw FormatException('Open CET row needs a translation: $wire');
  }
  final bands = fields[2]
      .split(',')
      .map((band) => band.trim())
      .where((band) => band.isNotEmpty)
      .toList(growable: false);
  if (bands.isEmpty) {
    throw FormatException('Open CET row needs a coverage band: $wire');
  }
  return OpenCetDictionaryRow(
    word: fields[0].trim().toLowerCase(),
    ipa: fields[1].trim(),
    coverageBands: List.unmodifiable(bands),
    sourceTranslations: List.unmodifiable(translations),
  );
}

const _openPartOfSpeechPrefixes = <String, String>{
  'vt.vi.': 'v. 动词',
  'vi.vt.': 'v. 动词',
  'interj.': 'interj. 感叹词',
  'prep.': 'prep. 介词',
  'conj.': 'conj. 连词',
  'adv.': 'adv. 副词',
  'aux.': 'aux. 助动词',
  'pron.': 'pron. 代词',
  'num.': 'num. 数词',
  'pref.': 'pref. 前缀',
  'pl.': 'n. 名词',
  'vt.': 'v. 动词',
  'vi.': 'v. 动词',
  'n.': 'n. 名词',
  'v.': 'v. 动词',
  'a.': 'adj. 形容词',
};

String _openPartOfSpeech(Iterable<String> translations) {
  final labels = <String>[];
  for (final translation in translations) {
    for (final item in _openPartOfSpeechPrefixes.entries) {
      if (_hasOpenPrefix(translation, item.key)) {
        if (!labels.contains(item.value)) labels.add(item.value);
        break;
      }
    }
  }
  return labels.isEmpty ? '待审校' : labels.join('/');
}

List<String> _openMeanings(Iterable<String> translations) {
  final meanings = <String>[];
  for (final translation in translations) {
    var cleaned = translation;
    for (final prefix in _openPartOfSpeechPrefixes.keys) {
      if (_hasOpenPrefix(cleaned, prefix)) {
        cleaned = cleaned.substring(prefix.length).trimLeft();
        break;
      }
    }
    cleaned = cleaned.replaceFirst(RegExp(r'^(?:\[[^\]]+\]\s*)+'), '');
    for (final meaning in cleaned.split(RegExp(r'[,，;；]'))) {
      final value = meaning.trim();
      if (value.isNotEmpty && !meanings.contains(value)) meanings.add(value);
    }
  }
  return List.unmodifiable(meanings.isEmpty ? const ['待人工补充'] : meanings);
}

bool _hasOpenPrefix(String value, String prefix) {
  if (!value.startsWith(prefix)) return false;
  return value.length == prefix.length ||
      value.substring(prefix.length, prefix.length + 1).trim().isEmpty;
}
