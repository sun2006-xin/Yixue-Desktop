final class TranslationQualityGuard {
  const TranslationQualityGuard._();

  static final RegExp _screenshotOcrBlockMarker = RegExp(
    r'⟦YIXUE_OCR_[A-Za-z0-9_-]{1,80}_\d+_(?:START|END)⟧',
  );

  static bool isSuspicious(
    String source,
    String translation, {
    String? targetLanguage,
  }) {
    final output = translation.trim();
    if (output.isEmpty) return true;
    if (output.length > 20000) return true;
    final qualitySource = source.replaceAll(_screenshotOcrBlockMarker, '');
    final qualityOutput = output.replaceAll(_screenshotOcrBlockMarker, '');
    if (qualityOutput.trim().isEmpty) return true;

    // A generative model must return the translation only. Thinking traces,
    // analysis headings and serialized answer envelopes are not translations.
    final lower = qualityOutput.toLowerCase();
    const metaMarkers = <String>[
      'thinking...',
      'analysis:',
      'final answer:',
      'translation:',
      '翻译结果：',
      '翻译如下：',
      '分析请求',
      '目标语言',
      '原文：',
      '译文：',
    ];
    if (metaMarkers.any((marker) => lower.contains(marker.toLowerCase()))) {
      return true;
    }
    if ((qualityOutput.startsWith('{') && qualityOutput.endsWith('}')) ||
        (qualityOutput.startsWith('[') && qualityOutput.endsWith(']'))) {
      return true;
    }

    final compact = qualityOutput.replaceAll(RegExp(r'\s+'), '');
    if (compact.length >= 8) {
      final first = compact.runes.first;
      final sameCount = compact.runes.where((rune) => rune == first).length;
      if (sameCount / compact.runes.length >= 0.75) return true;
    }

    final repeatedCjk = RegExp(
      r'([\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff])\1{3,}',
    ).hasMatch(compact);
    if (repeatedCjk) return true;

    final sourceLatin = RegExp(r'[A-Za-z]').allMatches(qualitySource).length;
    final sourceCjk = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]')
        .allMatches(qualitySource)
        .length;
    final sourceHangul = RegExp(r'[\uac00-\ud7af]')
        .allMatches(qualitySource)
        .length;
    final sourceHangulText = qualitySource.replaceAll(
      RegExp(r'[^\uac00-\ud7af]'),
      '',
    );
    final outputLatin = RegExp(r'[A-Za-z]').allMatches(qualityOutput).length;
    final outputCjk = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]')
        .allMatches(qualityOutput)
        .length;
    final outputHangul = RegExp(r'[\uac00-\ud7af]')
        .allMatches(qualityOutput)
        .length;
    final outputHangulText = qualityOutput.replaceAll(
      RegExp(r'[^\uac00-\ud7af]'),
      '',
    );
    final outputKana = RegExp(r'[\u3040-\u309f\u30a0-\u30ff\u31f0-\u31ffー]')
        .allMatches(qualityOutput)
        .length;
    final sourceHasLanguage =
        sourceLatin > 0 || sourceCjk > 0 || sourceHangul > 0;
    final outputHasLanguage =
        outputLatin > 0 || outputCjk > 0 || outputHangul > 0 || outputKana > 0;
    if (sourceHasLanguage && !outputHasLanguage) return true;
    if (targetLanguage == 'chinese' &&
        sourceLatin >= 4 &&
        outputCjk == 0 &&
        outputLatin >= sourceLatin * 0.8) {
      return true;
    }
    if (targetLanguage == 'english' &&
        sourceCjk >= 2 &&
        outputLatin == 0 &&
        outputCjk >= sourceCjk * 0.8) {
      return true;
    }
    final outputTargetScript = switch (targetLanguage) {
      'english' => outputLatin,
      'chinese' => outputCjk,
      'japanese' => outputCjk + outputKana,
      _ => 0,
    };
    if (sourceHangul > 0 &&
        targetLanguage != 'korean' &&
        (outputHangulText.contains(sourceHangulText) ||
            (outputHangul >= sourceHangul * 0.8 &&
                outputHangul > outputTargetScript))) {
      return true;
    }
    if (targetLanguage == 'korean' && sourceHasLanguage && outputHangul == 0) {
      return true;
    }

    final units = qualityOutput
        .split(RegExp(r'[\s,，。.!！？；;：:、]+'))
        .where((unit) => unit.isNotEmpty)
        .toList();
    if (units.length >= 3) {
      for (var index = 0; index <= units.length - 3; index++) {
        if (units[index] == units[index + 1] &&
            units[index] == units[index + 2]) {
          return true;
        }
      }
    }
    return false;
  }
}
