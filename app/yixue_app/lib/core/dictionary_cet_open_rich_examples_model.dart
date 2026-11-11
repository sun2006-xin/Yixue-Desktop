/// A source-traceable bilingual example that is still awaiting editorial
/// review. It is intentionally separate from project-authored examples.
class OpenCetRichExampleRow {
  const OpenCetRichExampleRow({
    required this.exampleId,
    required this.sourceId,
    required this.englishText,
    required this.chineseText,
    required this.englishUsername,
    required this.chineseUsername,
    this.reviewStatus = 'candidate',
  });

  final String exampleId;
  final String sourceId;
  final String englishText;
  final String chineseText;
  final String englishUsername;
  final String chineseUsername;
  final String reviewStatus;
}

/// The entry-level result of the source-grounded assistant audit.
///
/// This is deliberately separate from the formal ``reviewed``/``published``
/// states. It tells the UI which open-source rows passed the automated
/// assistant cross-check and which enrichment fields still need attention.
class OpenCetAssistantReviewRow {
  const OpenCetAssistantReviewRow({
    required this.qualityStatus,
    required this.remainingFlags,
    required this.sourceIds,
  });

  final String qualityStatus;
  final List<String> remainingFlags;
  final List<String> sourceIds;

  bool get hasGaps => remainingFlags.isNotEmpty;
}

/// Bounded source candidates for the future learning graph. These are not
/// fixed collocations or approved relations until editorial review completes.
class OpenCetRichMetadataRow {
  const OpenCetRichMetadataRow({
    required this.qualityStatus,
    required this.variants,
    required this.collocations,
    required this.relations,
    this.partOfSpeechCandidates = const [],
    this.pronunciationCandidates = const [],
    this.learningTags = const [],
    this.frequency = const {},
    this.reviewFields = const [],
    this.sourceIds = const [],
  });

  final String qualityStatus;
  final List<String> variants;
  final List<String> collocations;
  final Map<String, List<String>> relations;
  final List<OpenCetRichPartOfSpeechRow> partOfSpeechCandidates;
  final List<OpenCetRichPronunciationRow> pronunciationCandidates;
  final List<String> learningTags;
  final Map<String, int> frequency;
  final List<String> reviewFields;
  final List<String> sourceIds;
}

class OpenCetRichPartOfSpeechRow {
  const OpenCetRichPartOfSpeechRow({
    required this.value,
    required this.sourceId,
  });

  final String value;
  final String sourceId;
}

class OpenCetRichPronunciationRow {
  const OpenCetRichPronunciationRow({
    required this.value,
    required this.dialect,
    required this.notation,
    required this.sourceId,
    required this.partOfSpeech,
    this.sourceWord = '',
    this.resolution = '',
  });

  final String value;
  final String dialect;
  final String notation;
  final String sourceId;
  final String partOfSpeech;
  final String sourceWord;
  final String resolution;
}

/// A source-separated sense candidate for the future learning graph.
///
/// Glosses from different sources are deliberately kept as separate rows:
/// runtime ingestion must not pretend that two sources describe the same
/// meaning until an editor has aligned and reviewed them.
class OpenCetRichSenseRow {
  const OpenCetRichSenseRow({
    required this.sourceId,
    required this.senseId,
    required this.partOfSpeech,
    required this.englishGlosses,
    required this.chineseGlosses,
    required this.usageTags,
    required this.sourceExamples,
    required this.qualifier,
    this.reviewStatus = 'candidate',
  });

  final String sourceId;
  final String senseId;
  final String partOfSpeech;
  final List<String> englishGlosses;
  final List<String> chineseGlosses;
  final List<String> usageTags;
  final List<String> sourceExamples;
  final String qualifier;
  final String reviewStatus;
}
