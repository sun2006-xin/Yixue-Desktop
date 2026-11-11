import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/translation_terminology.dart';

void main() {
  test(
    'round trips directional terminology rules through local JSON',
    () async {
      final directory = await Directory.systemTemp.createTemp('yixue-terms-');
      final file = File('${directory.path}\\translation-terminology.json');
      final store = FileTranslationTerminologyStore(file);
      const terminology = TranslationTerminology([
        TranslationTermRule(
          id: 'term-1',
          source: 'inference engine',
          target: '推理引擎',
          direction: TerminologyDirection.englishToChinese,
        ),
      ]);

      await store.write(terminology);
      final restored = await store.read();

      expect(restored?.rules.single.source, 'inference engine');
      expect(restored?.rules.single.target, '推理引擎');
      expect(
        restored?.rules.single.direction,
        TerminologyDirection.englishToChinese,
      );
      await directory.delete(recursive: true);
    },
  );

  test('ignores malformed or oversized terminology files safely', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-terms-');
    final file = File('${directory.path}\\translation-terminology.json');
    await file.writeAsString('{"schemaVersion":99,"rules":[]}');

    expect(await FileTranslationTerminologyStore(file).read(), isNull);
    await directory.delete(recursive: true);
  });

  test('matches only rules for the requested direction', () {
    const terminology = TranslationTerminology([
      TranslationTermRule(
        id: 'en-zh',
        source: 'model package',
        target: '模型包',
        direction: TerminologyDirection.englishToChinese,
      ),
      TranslationTermRule(
        id: 'zh-en',
        source: '模型包',
        target: 'model package',
        direction: TerminologyDirection.chineseToEnglish,
      ),
    ]);

    expect(
      terminology.forDirection(TerminologyDirection.englishToChinese).single.id,
      'en-zh',
    );
  });

  test('protects a user term and restores its fixed translation', () {
    const terminology = TranslationTerminology([
      TranslationTermRule(
        id: 'engine',
        source: 'inference engine',
        target: '推理引擎',
        direction: TerminologyDirection.englishToChinese,
      ),
    ]);
    final protected = terminology.protect(
      'The inference engine is ready.',
      TerminologyDirection.englishToChinese,
    );

    expect(protected.maskedText, isNot(contains('inference engine')));
    expect(protected.maskedText, contains(TranslationTerminology.termSentinel));
    expect(
      protected.restore('推理 ${TranslationTerminology.termSentinel} 已就绪。'),
      '推理 推理引擎 已就绪。',
    );
  });

  test(
    'keeps screenshot layout marker identity while protecting user terms',
    () {
      const terminology = TranslationTerminology([
        TranslationTermRule(
          id: 'ocr',
          source: 'OCR',
          target: '文字识别',
          direction: TerminologyDirection.englishToChinese,
        ),
      ]);
      const marker = '⟦YIXUE_OCR_capture_123_0_START⟧';
      final protected = terminology.protect(
        '$marker\nOCR results',
        TerminologyDirection.englishToChinese,
      );

      expect(protected.maskedText, '$marker\nYXTERM results');
      expect(
        protected.restore(
          '$marker\n${TranslationTerminology.termSentinel} results',
        ),
        '$marker\n文字识别 results',
      );
    },
  );
}
