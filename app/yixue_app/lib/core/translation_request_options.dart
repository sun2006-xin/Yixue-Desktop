/// Options that travel with one translation request.
///
/// Keeping this separate from a concrete provider lets the quick translation
/// page request optional capabilities without knowing whether the selected
/// provider is local, compatible, or vendor-specific.
class TranslationRequestOptions {
  const TranslationRequestOptions({
    this.webSearchEnabled = false,
    this.preserveLineBreaks,
  });

  /// Requests bounded web references before the selected model translates.
  ///
  /// This is opt-in and defaults to false. A provider must have a real search
  /// adapter before the request can use this option.
  final bool webSearchEnabled;

  /// Overrides the user's general formatting preference for one request.
  ///
  /// Screenshot translation sets this to true because its OCR layout uses
  /// paragraph boundaries to position translations over the original image.
  final bool? preserveLineBreaks;
}

/// One source returned by a web-search adapter.
///
/// Source text is untrusted reference material. It is never treated as an
/// instruction, executable content, or a replacement for the translation.
class TranslationWebSearchSource {
  const TranslationWebSearchSource({
    required this.title,
    required this.uri,
    this.snippet,
  });

  final String title;
  final String uri;
  final String? snippet;
}

/// Bounded, auditable references that a search adapter hands to a model.
class TranslationWebSearchContext {
  const TranslationWebSearchContext({
    required this.query,
    required this.referenceText,
    required this.searchedAt,
    this.sources = const <TranslationWebSearchSource>[],
  });

  final String query;
  final String referenceText;
  final DateTime searchedAt;
  final List<TranslationWebSearchSource> sources;
}

/// Independent retrieval boundary for future provider-specific web search.
///
/// An implementation may call an approved HTTPS search service or a model
/// provider's native search endpoint. It must return bounded references and
/// must not open a browser or silently upload the full document.
abstract interface class TranslationWebSearchAdapter {
  Future<TranslationWebSearchContext> retrieve({
    required String sourceText,
    required String sourceLanguage,
    required String targetLanguage,
  });
}
