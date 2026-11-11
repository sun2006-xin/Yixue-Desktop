/// A deterministic word-level score for the preview pronunciation flow.
///
/// It compares the speech recognizer's text with the target text. It is not a
/// phoneme, accent, intonation, or clinical pronunciation assessment.
final class PronunciationScoreResult {
  const PronunciationScoreResult({
    required this.targetText,
    required this.recognizedText,
    required this.expectedTokens,
    required this.recognizedTokens,
    required this.matchedTokens,
    required this.missingTokens,
    required this.extraTokens,
    required this.score,
  });

  final String targetText;
  final String recognizedText;
  final List<String> expectedTokens;
  final List<String> recognizedTokens;
  final List<String> matchedTokens;
  final List<String> missingTokens;
  final List<String> extraTokens;
  final int score;

  String get grade => switch (score) {
    >= 90 => '优秀',
    >= 75 => '良好',
    _ => '继续练习',
  };

  String get detail {
    if (expectedTokens.isEmpty) return '没有可评分的目标词。';
    if (score == 100) return '词语全部匹配。';
    final missing = missingTokens.isEmpty ? '' : '缺少：${missingTokens.join('、')}';
    final extra = extraTokens.isEmpty ? '' : '多出：${extraTokens.join('、')}';
    return [missing, extra].where((item) => item.isNotEmpty).join('；');
  }
}

PronunciationScoreResult scorePronunciation({
  required String targetText,
  required String recognizedText,
}) {
  final expected = pronunciationTokens(targetText);
  final recognized = pronunciationTokens(recognizedText);
  final lcs = _longestCommonSubsequence(expected, recognized);
  final matched = lcs.length;
  final denominator = expected.length > recognized.length
      ? expected.length
      : recognized.length;
  final score = denominator == 0 ? 0 : ((matched / denominator) * 100).round();

  final missing = _unmatchedTokens(expected, lcs);
  final extra = _unmatchedTokens(recognized, lcs);
  return PronunciationScoreResult(
    targetText: targetText,
    recognizedText: recognizedText,
    expectedTokens: List.unmodifiable(expected),
    recognizedTokens: List.unmodifiable(recognized),
    matchedTokens: List.unmodifiable(lcs),
    missingTokens: List.unmodifiable(missing),
    extraTokens: List.unmodifiable(extra),
    score: score.clamp(0, 100),
  );
}

List<String> pronunciationTokens(String value) => RegExp(
      r"[A-Za-zÀ-ÖØ-öø-ÿ0-9]+(?:['’][A-Za-zÀ-ÖØ-öø-ÿ0-9]+)?",
    )
    .allMatches(value.toLowerCase())
    .map((match) => match.group(0)!.replaceAll('’', "'"))
    .toList(growable: false);

List<String> _longestCommonSubsequence(List<String> left, List<String> right) {
  final table = List.generate(
    left.length + 1,
    (_) => List<int>.filled(right.length + 1, 0),
  );
  for (var i = left.length - 1; i >= 0; i--) {
    for (var j = right.length - 1; j >= 0; j--) {
      table[i][j] = left[i] == right[j]
          ? table[i + 1][j + 1] + 1
          : (table[i + 1][j] > table[i][j + 1]
                ? table[i + 1][j]
                : table[i][j + 1]);
    }
  }
  final result = <String>[];
  var i = 0;
  var j = 0;
  while (i < left.length && j < right.length) {
    if (left[i] == right[j]) {
      result.add(left[i]);
      i++;
      j++;
    } else if (table[i + 1][j] >= table[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return result;
}

List<String> _unmatchedTokens(List<String> source, List<String> matched) {
  final remaining = [...matched];
  final unmatched = <String>[];
  for (final token in source) {
    final index = remaining.indexOf(token);
    if (index >= 0) {
      remaining.removeAt(index);
    } else {
      unmatched.add(token);
    }
  }
  return unmatched;
}
