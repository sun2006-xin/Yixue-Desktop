import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/translation_quality_guard.dart';

void main() {
  test('rejects collapsed repeated Chinese output', () {
    expect(TranslationQualityGuard.isSuspicious('hello', '哈哈哈哈哈哈哈哈哈哈'), isTrue);
  });

  test('rejects repeated phrase output', () {
    expect(TranslationQualityGuard.isSuspicious('teacher', '教师 教师 教师'), isTrue);
  });

  test('rejects symbol-only output for language input', () {
    expect(
      TranslationQualityGuard.isSuspicious(
        '老师',
        '~ ·',
        targetLanguage: 'english',
      ),
      isTrue,
    );
    expect(
      TranslationQualityGuard.isSuspicious(
        'hello',
        '…… /',
        targetLanguage: 'chinese',
      ),
      isTrue,
    );
    expect(TranslationQualityGuard.isSuspicious('2026', '—'), isFalse);
  });

  test('rejects model reasoning and answer envelopes', () {
    expect(
      TranslationQualityGuard.isSuspicious(
        'Technology changes life.',
        'Thinking...\n分析请求：目标语言是简体中文。',
      ),
      isTrue,
    );
    expect(
      TranslationQualityGuard.isSuspicious(
        'Technology changes life.',
        '{"translation":"技术改变生活。"}',
      ),
      isTrue,
    );
  });

  test('accepts normal translation and natural repeated words', () {
    expect(
      TranslationQualityGuard.isSuspicious(
        'Technology changes life.',
        '技术改变生活。',
      ),
      isFalse,
    );
    expect(
      TranslationQualityGuard.isSuspicious('very very good', '真的非常非常好'),
      isFalse,
    );
  });

  test('OCR layout markers do not hide untranslated Chinese output', () {
    const start = '⟦YIXUE_OCR_capture_123_0_START⟧';
    const end = '⟦YIXUE_OCR_capture_123_0_END⟧';
    expect(
      TranslationQualityGuard.isSuspicious(
        '$start\n你好世界\n$end',
        '$start\n你好世界\n$end',
        targetLanguage: 'english',
      ),
      isTrue,
    );
    expect(
      TranslationQualityGuard.isSuspicious(
        '$start\n你好世界\n$end',
        '$start\nHello world\n$end',
        targetLanguage: 'english',
      ),
      isFalse,
    );
  });

  test('accepts Hangul output for English, Chinese, and Japanese sources', () {
    const examples = <(String, String)>[
      ('Hello, how are you?', '안녕하세요, 잘 지내세요.'),
      ('我们明天再讨论这个方案。', '내일 이 계획을 다시 논의합시다.'),
      ('明日また会いましょう。', '내일 다시 만나요.'),
    ];

    for (final (source, korean) in examples) {
      expect(
        TranslationQualityGuard.isSuspicious(
          source,
          korean,
          targetLanguage: 'korean',
        ),
        isFalse,
        reason: '$source should accept Hangul output: $korean',
      );
    }
  });

  test('rejects unchanged Korean source for English, Chinese, and Japanese targets', () {
    const cases = <(String, String, String, String)>[
      ('english', 'Hello.', '안녕하세요', '안녕하세요 Hi'),
      ('chinese', '你好。', '안녕하세요', '안녕하세요 你'),
      ('japanese', 'こんにちは。', '안녕하세요', '안녕하세요 あ'),
    ];

    for (final (target, validTranslation, unchangedSource, mixedOutput)
        in cases) {
      expect(
        TranslationQualityGuard.isSuspicious(
          unchangedSource,
          unchangedSource,
          targetLanguage: target,
        ),
        isTrue,
        reason: '$target must reject unchanged Hangul source text',
      );
      expect(
        TranslationQualityGuard.isSuspicious(
          unchangedSource,
          mixedOutput,
          targetLanguage: target,
        ),
        isTrue,
        reason:
            '$target must reject Hangul source with only a token of target text',
      );
      expect(
        TranslationQualityGuard.isSuspicious(
          unchangedSource,
          validTranslation,
          targetLanguage: target,
        ),
        isFalse,
        reason: '$target should accept a translation in its writing system',
      );
    }
  });

  test('rejects short Korean source embedded in mixed-language output', () {
    const cases = <(String, String)>[
      ('english', '안녕 Hi'),
      ('chinese', '안녕 你好'),
      ('japanese', '안녕 こん'),
    ];

    for (final (target, mixedOutput) in cases) {
      expect(
        TranslationQualityGuard.isSuspicious(
          '안녕',
          mixedOutput,
          targetLanguage: target,
        ),
        isTrue,
        reason: '$target must reject source Hangul embedded in the output',
      );
    }
  });
}
