final class TranslationFormatProtector {
  TranslationFormatProtector._();

  static const sentinel = 'YXFMT';

  static final RegExp _protectedPattern = RegExp(
    r'YXFMT'
    r'|`[^`\r\n]+`'
    r'|\*\*[^*\r\n]+\*\*'
    r'|https?://[A-Za-z0-9/#?&=._~:%+\-]*[A-Za-z0-9/#?&=_~%+\-]'
    r'|\$\{[^{}\r\n]+\}'
    r'|\{[^{}\r\n]+\}'
    r'|%[A-Za-z_][A-Za-z0-9_]*%'
    r'|(?:Ctrl|Alt|Shift|Cmd|Option|Win)(?:\+[A-Za-z0-9]+)+'
    r'|[A-Za-z]:\\[^\s，。！？；、]+'
    r'|[A-Za-z0-9_.-]+\.(?:pdf|docx?|pptx?|xlsx?|csv|json|bin|gguf|onnx|txt|md)'
    r'|\b[A-Za-z][A-Za-z0-9.+-]*/[A-Za-z0-9.+-]+\b'
    r'|/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+'
    r'|(?:SHA|MD)-?\d+'
    r'|Content-Type'
    r'|\b(?:API|CPU|GPU|RAM|GET|POST|JSON|HTTP|HTTPS|URL|OCR|ASR|TTS)\b'
    r'|[$€£¥]\d+(?:\.\d+)?'
    r'|\b\d+(?:\.\d+)?\s*(?:KiB|MiB|GiB|KB|MB|GB|TB|ms|Hz|kHz|MHz|GHz)\b'
    r'|\b\d{1,2}:\d{2}\b'
    r'|\b[vV]?\d+(?:\.\d+){1,3}\b'
    r'|\b\d+(?:\.\d+)?%'
    r'|\b[A-Z]-\d+\b'
    r'|\b\d+[–—-]\d+\b',
  );

  static ProtectedTranslationInput protect(String sourceText) {
    final spans = <String>[];
    final masked = sourceText.replaceAllMapped(_protectedPattern, (match) {
      spans.add(match.group(0)!);
      return sentinel;
    });
    return ProtectedTranslationInput._(masked, List.unmodifiable(spans));
  }
}

final class ProtectedTranslationInput {
  const ProtectedTranslationInput._(this.maskedText, this.spans);

  final String maskedText;
  final List<String> spans;

  String restore(String translatedText) {
    final parts = translatedText.split(TranslationFormatProtector.sentinel);
    if (parts.length - 1 != spans.length) {
      throw const TranslationFormatException('placeholder_integrity_failed');
    }
    if (spans.isEmpty) return translatedText;

    final restored = StringBuffer(parts.first);
    for (var index = 0; index < spans.length; index += 1) {
      restored
        ..write(spans[index])
        ..write(parts[index + 1]);
    }
    return restored.toString();
  }
}

final class TranslationFormatException implements Exception {
  const TranslationFormatException(this.code);

  final String code;

  @override
  String toString() => 'TranslationFormatException($code)';
}
