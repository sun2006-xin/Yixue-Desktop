/// Adjusts display casing without changing the transcript stored in history.
///
/// Some speech models emit English entirely in uppercase. Sentence case is
/// easier to read in a subtitle overlay, while mixed-case text and non-English
/// text are left untouched.
String formatSubtitleTextForDisplay(
  String text, {
  required String languageCode,
}) {
  final language = languageCode
      .trim()
      .toLowerCase()
      .split(RegExp('[-_]'))
      .first;
  if (language != 'en' ||
      !RegExp(r'[A-Z]').hasMatch(text) ||
      RegExp(r'[a-z]').hasMatch(text)) {
    return text;
  }

  var result = text.toLowerCase().replaceAllMapped(
    RegExp(r'(^|[.!?]\s+)([a-z])'),
    (match) => '${match[1]}${match[2]!.toUpperCase()}',
  );
  result = result.replaceAll(RegExp(r'\bi\b'), 'I');
  for (final acronym in const <String>[
    'AI',
    'DNA',
    'EU',
    'FBI',
    'NASA',
    'UK',
    'UN',
    'US',
    'USA',
  ]) {
    result = result.replaceAll(
      RegExp('\\b${acronym.toLowerCase()}\\b', caseSensitive: false),
      acronym,
    );
  }
  return result;
}
