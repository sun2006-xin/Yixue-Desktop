import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_catalog.dart';
import 'package:yixue_app/core/dictionary_cet_open_assistant_verified.dart';
import 'package:yixue_app/core/dictionary_cet_open_entries.dart';
import 'package:yixue_app/core/dictionary_service.dart';

void main() {
  const dictionary = LocalDictionaryService();

  test('pins the open CET4/CET6 vocabulary baseline', () {
    expect(openCet4SourceWordCount, 3815);
    expect(openCet6SourceWordCount, 5371);
    expect(openCetUniqueWordCount, 5759);
    expect(openCetSourceMissingPhoneticRecordCount, 35);
    expect(yxOpenCetDictionaryRows, hasLength(openCetUniqueWordCount));
    expect(
      yxOpenCetDictionaryRows.where((row) => row.ipa == '—'),
      hasLength(openCetMissingPhoneticCount),
    );
  });

  test('keeps every imported row searchable and structurally safe', () {
    final words = <String>{};
    for (final row in yxOpenCetDictionaryRows) {
      expect(row.word, matches(RegExp(r"^[A-Za-z][A-Za-z' -]*$")));
      expect(row.meanings, isNotEmpty);
      expect(row.coverageBands, isNotEmpty);
      expect(
        words.add(row.word),
        isTrue,
        reason: 'duplicate imported word: ${row.word}',
      );
    }

    expect(dictionary.entries.length, greaterThanOrEqualTo(5759));
    expect(dictionary.lookup('abbreviation'), isNotNull);
    expect(dictionary.lookup('abbreviation')?.meanings, isNotEmpty);
    expect(dictionary.lookup('abbreviation')?.hasExample, isTrue);
    expect(dictionary.lookup('abbreviation')?.hasCandidateExamples, isTrue);
    expect(dictionary.lookup('abbreviation')?.exampleIsOpenCandidate, isTrue);
    expect(
      dictionary.lookup('abbreviation')?.exampleCandidates.first.sourceId,
      'tatoeba-cc-by-2.0-fr',
    );
    expect(dictionary.lookup('abandon')?.hasCandidateMetadata, isTrue);
    expect(dictionary.lookup('abandon')?.hasCandidateSenses, isTrue);
    expect(dictionary.lookup('abandon')?.sourceExampleCandidates, isNotEmpty);
    expect(dictionary.lookup('abandon')?.partOfSpeechCandidates, isNotEmpty);
    expect(dictionary.lookup('abandon')?.pronunciationCandidates, isNotEmpty);
    expect(dictionary.lookup('abandon')?.learningTags, contains('cet4'));
    expect(dictionary.lookup('abandon')?.frequency, isNotEmpty);
    expect(
      dictionary.lookup('abandon')?.qualityStatus,
      'published_with_assistant_enrichment',
    );
    expect(dictionary.lookup('abandon')?.reviewFields, isEmpty);
    expect(
      dictionary.lookup('abandon')?.candidateSourceIds,
      containsAll(['open-ecdict', 'wordnet-3.0']),
    );
    expect(dictionary.lookup('abandon')?.senseCandidates, isNotEmpty);
    expect(
      dictionary.lookup('abandon')?.senseCandidates.first.sourceId,
      isNotEmpty,
    );
    expect(
      dictionary.lookup('abandon')?.senseCandidates.first.reviewStatus,
      'candidate',
    );
    expect(dictionary.lookup('abandon')?.variants, contains('abandoned'));
    expect(
      dictionary.lookup('abandon')?.collocationCandidates,
      contains('abandon you'),
    );
    expect(
      dictionary.lookup('abandon')?.relationCandidates['derivations'],
      contains('abandonment'),
    );
    expect(dictionary.lookup('abrupt')?.hasExample, isFalse);
    expect(dictionary.lookup('abrupt')?.qualityStatus, 'assistant_verified');
    expect(dictionary.lookup('ability')?.exampleIsOpenCandidate, isFalse);
    expect(dictionary.lookup('pea')?.meanings, contains('豌豆'));
    expect(dictionary.lookup('pea')?.partOfSpeech, contains('n.'));
    expect(dictionary.lookup('reservior')?.source, 'open-ecdict');
    expect(dictionary.lookup('well-known'), isNotNull);
  });

  test('imports the full assistant verification index with visible gaps', () {
    expect(yxOpenCetAssistantReviewRows, hasLength(openCetUniqueWordCount));
    expect(
      yxOpenCetAssistantReviewRows.values.where(
        (row) => row.qualityStatus == 'assistant_verified',
      ),
      hasLength(5745),
    );
    expect(
      yxOpenCetAssistantReviewRows.values.where(
        (row) => row.qualityStatus == 'assistant_verified_with_gaps',
      ),
      hasLength(14),
    );
    expect(
      dictionary.lookup('first-rate')?.qualityStatus,
      'assistant_verified_with_gaps',
    );
    expect(
      dictionary.lookup('first-rate')?.reviewFields,
      contains('pronunciation'),
    );
  });

  test('reports open CET coverage without relabelling it as authored', () {
    final report = DictionaryCoverageReport.fromRuntimeDictionary(
      dictionary.entries,
    );

    expect(report.totalEntries, greaterThanOrEqualTo(openCetUniqueWordCount));
    expect(
      report.countFor('cet4', publishedOnly: false),
      greaterThanOrEqualTo(3815),
    );
    expect(
      report.countFor('cet6', publishedOnly: false),
      greaterThanOrEqualTo(5371),
    );
    expect(report.publishedEntries, lessThan(report.totalEntries));
    expect(
      report.countFor('cet4', publishedOnly: false),
      greaterThan(report.countFor('cet4')),
    );
    expect(
      dictionary.lookup('abandon')?.coverageBands,
      containsAll(['cet4', 'cet6']),
    );
  });
}
