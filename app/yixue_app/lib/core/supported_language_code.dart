/// Canonicalizes the language tags supported by the local translation routes.
///
/// Region and script subtags are accepted for matching. Callers that need to
/// distinguish a script, such as simplified from traditional Chinese, must
/// also inspect [isTraditionalChineseLanguageTag].
String? canonicalSupportedLanguageCode(String? value) {
  final normalized = value?.trim().toLowerCase().replaceAll('_', '-');
  if (normalized == null || normalized.isEmpty) return null;
  final parts = normalized.split('-');
  if (parts.any((part) => part.isEmpty)) return null;
  return switch (parts.first) {
    'en' || 'eng' || 'english' => 'en',
    'zh' || 'zho' || 'chi' || 'cmn' || 'chinese' || 'mandarin' => 'zh',
    'ja' || 'jpn' || 'japanese' => 'ja',
    'ko' || 'kor' || 'korean' => 'ko',
    'es' || 'spa' || 'spanish' => 'es',
    'fr' || 'fra' || 'fre' || 'french' => 'fr',
    'de' || 'deu' || 'ger' || 'german' => 'de',
    'pt' || 'por' || 'portuguese' => 'pt',
    'ru' || 'rus' || 'russian' => 'ru',
    _ => null,
  };
}

bool isTraditionalChineseLanguageTag(String? value) {
  final normalized = value?.trim().toLowerCase().replaceAll('_', '-');
  if (normalized == null || normalized.isEmpty) return false;
  final parts = normalized.split('-');
  if (parts.any((part) => part.isEmpty)) return false;
  if (!const <String>{
    'zh',
    'zho',
    'chi',
    'cmn',
    'chinese',
    'mandarin',
  }.contains(parts.first)) {
    return false;
  }
  return parts.contains('hant') ||
      const <String>{'tw', 'hk', 'mo'}.contains(parts.last);
}
