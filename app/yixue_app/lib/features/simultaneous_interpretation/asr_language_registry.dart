/// Recognition mode is independent from a language code. In particular,
/// `auto` is never a language and must not be persisted as a transcript code.
enum AsrRecognitionMode {
  manual,
  auto;

  String get displayLabel => switch (this) {
    AsrRecognitionMode.manual => '手动选择',
    AsrRecognitionMode.auto => '自动识别',
  };
}

/// Immutable language metadata shared by ASR model and UI catalogs.
///
/// Registration describes the canonical language identifiers and labels. It
/// does not mean that an ASR model is installed or has passed quality gates.
final class AsrLanguage {
  const AsrLanguage({
    required this.code,
    required this.displayName,
    required this.nativeName,
  });

  /// Canonical primary language code used by this registry.
  final String code;

  /// Chinese localized name shown in language selectors.
  final String displayName;

  /// Name written in the language's native script.
  final String nativeName;

  String get label => '$displayName · $nativeName';
}

/// Canonical ASR language identifiers and recognition-mode parsing helpers.
///
/// The registry is deliberately limited to metadata and code normalization;
/// model availability, runtime compatibility, translation routes, and
/// language-specific acceptance remain separate capabilities.
final class AsrLanguageRegistry {
  AsrLanguageRegistry._();

  static const AsrLanguage english = AsrLanguage(
    code: 'en',
    displayName: '英语',
    nativeName: 'English',
  );
  static const AsrLanguage chinese = AsrLanguage(
    code: 'zh',
    displayName: '中文',
    nativeName: '普通话',
  );
  static const AsrLanguage japanese = AsrLanguage(
    code: 'ja',
    displayName: '日语',
    nativeName: '日本語',
  );
  static const AsrLanguage korean = AsrLanguage(
    code: 'ko',
    displayName: '韩语',
    nativeName: '한국어',
  );
  static const AsrLanguage spanish = AsrLanguage(
    code: 'es',
    displayName: '西班牙语',
    nativeName: 'Español',
  );
  static const AsrLanguage french = AsrLanguage(
    code: 'fr',
    displayName: '法语',
    nativeName: 'Français',
  );
  static const AsrLanguage german = AsrLanguage(
    code: 'de',
    displayName: '德语',
    nativeName: 'Deutsch',
  );
  static const AsrLanguage portuguese = AsrLanguage(
    code: 'pt',
    displayName: '葡萄牙语',
    nativeName: 'Português',
  );
  static const AsrLanguage russian = AsrLanguage(
    code: 'ru',
    displayName: '俄语',
    nativeName: 'Русский',
  );

  /// Registered languages in stable selector order.
  ///
  /// This is a const list and cannot be changed by callers.
  static const List<AsrLanguage> supportedLanguages = <AsrLanguage>[
    english,
    chinese,
    japanese,
    korean,
    spanish,
    french,
    german,
    portuguese,
    russian,
  ];

  static final Map<String, AsrLanguage> _languagesByCode =
      Map<String, AsrLanguage>.unmodifiable(<String, AsrLanguage>{
        for (final language in supportedLanguages) language.code: language,
      });

  /// Converts a supported language code or common alias to its canonical code.
  ///
  /// Regional/script tags such as `zh-Hans-CN` and `ja-JP` resolve to their
  /// primary language code. Unknown codes and automatic-mode values return
  /// `null`; automatic detection is represented by [AsrRecognitionMode.auto].
  static String? normalizeCode(String? value) {
    if (value == null) return null;
    final normalized = value.trim().toLowerCase().replaceAll('_', '-');
    if (normalized.isEmpty) return null;

    final parts = normalized.split('-');
    if (parts.any(
      (part) => part.isEmpty || !RegExp(r'^[a-z0-9]{1,8}$').hasMatch(part),
    )) {
      return null;
    }

    return switch (parts.first) {
      'en' || 'eng' || 'english' => english.code,
      'zh' ||
      'zho' ||
      'chi' ||
      'cmn' ||
      'chinese' ||
      'mandarin' => chinese.code,
      'ja' || 'jpn' || 'japanese' => japanese.code,
      'ko' || 'kor' || 'korean' => korean.code,
      'es' || 'spa' || 'spanish' => spanish.code,
      'fr' || 'fra' || 'fre' || 'french' => french.code,
      'de' || 'deu' || 'ger' || 'german' => german.code,
      'pt' || 'por' || 'portuguese' => portuguese.code,
      'ru' || 'rus' || 'russian' => russian.code,
      _ => null,
    };
  }

  /// Returns the registered language for a code or common alias.
  static AsrLanguage? languageForCode(String? value) {
    final code = normalizeCode(value);
    return code == null ? null : _languagesByCode[code];
  }

  /// Whether [value] identifies one of the registered language codes.
  ///
  /// Automatic mode is intentionally not a supported language code.
  static bool isSupportedCode(String? value) => languageForCode(value) != null;

  /// Whether recognition for [value] uses the multilingual segmented model.
  ///
  /// English and Chinese use the bundled streaming model. Every other
  /// registered language and automatic detection use the multilingual model.
  /// Unknown values return false so callers can validate them separately.
  static bool usesMultilingualModel(String? value) {
    final normalized = value?.trim().toLowerCase().replaceAll('_', '-') ?? '';
    if (normalized == 'auto' ||
        normalized == 'automatic' ||
        normalized == '自动识别') {
      return true;
    }
    final code = normalizeCode(value);
    return code != null && code != english.code && code != chinese.code;
  }

  /// Gets a localized/native display label, or `null` for an unknown code.
  static String? displayLabel(String? value) => languageForCode(value)?.label;

  /// Parses the independent recognition-mode value.
  ///
  /// Unknown values return `null` so callers can handle corrupt or newer
  /// persisted settings explicitly instead of silently guessing a language.
  static AsrRecognitionMode? parseRecognitionMode(String? value) {
    if (value == null) return null;
    return switch (value.trim().toLowerCase()) {
      'manual' || '手动选择' => AsrRecognitionMode.manual,
      'auto' || 'automatic' || '自动识别' => AsrRecognitionMode.auto,
      _ => null,
    };
  }
}
