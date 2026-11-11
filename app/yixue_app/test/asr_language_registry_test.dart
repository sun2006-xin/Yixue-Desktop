import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/asr_language_registry.dart';

void main() {
  group('AsrLanguageRegistry', () {
    test('exposes nine canonical language codes as an immutable registry', () {
      expect(
        AsrLanguageRegistry.supportedLanguages.map((language) => language.code),
        <String>['en', 'zh', 'ja', 'ko', 'es', 'fr', 'de', 'pt', 'ru'],
      );
      expect(
        () => AsrLanguageRegistry.supportedLanguages.add(
          const AsrLanguage(
            code: 'fr',
            displayName: '法语',
            nativeName: 'Français',
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('normalizes case, separators, regional tags, and common aliases', () {
      expect(AsrLanguageRegistry.normalizeCode(' EN-us '), 'en');
      expect(AsrLanguageRegistry.normalizeCode('zh_CN'), 'zh');
      expect(AsrLanguageRegistry.normalizeCode('cmn-Hans-CN'), 'zh');
      expect(AsrLanguageRegistry.normalizeCode('jpn-JP'), 'ja');
      expect(AsrLanguageRegistry.normalizeCode('ko-KR'), 'ko');
      expect(AsrLanguageRegistry.normalizeCode('es-ES'), 'es');
      expect(AsrLanguageRegistry.normalizeCode('fr-FR'), 'fr');
      expect(AsrLanguageRegistry.normalizeCode('de-DE'), 'de');
      expect(AsrLanguageRegistry.normalizeCode('pt-BR'), 'pt');
      expect(AsrLanguageRegistry.normalizeCode('rus-RU'), 'ru');
    });

    test(
      'does not turn unknown or automatic selections into language codes',
      () {
        expect(AsrLanguageRegistry.normalizeCode('xx-XX'), isNull);
        expect(AsrLanguageRegistry.normalizeCode('auto'), isNull);
        expect(AsrLanguageRegistry.isSupportedCode('auto'), isFalse);
        expect(AsrLanguageRegistry.isSupportedCode('JA-jp'), isTrue);
      },
    );

    test(
      'provides localized and native display labels for supported codes',
      () {
        expect(AsrLanguageRegistry.displayLabel('EN'), '英语 · English');
        expect(AsrLanguageRegistry.displayLabel('zh-CN'), '中文 · 普通话');
        expect(AsrLanguageRegistry.displayLabel('ja'), '日语 · 日本語');
        expect(AsrLanguageRegistry.displayLabel('ko-KR'), '韩语 · 한국어');
        expect(AsrLanguageRegistry.displayLabel('es'), '西班牙语 · Español');
        expect(AsrLanguageRegistry.displayLabel('fr'), '法语 · Français');
        expect(AsrLanguageRegistry.displayLabel('de'), '德语 · Deutsch');
        expect(AsrLanguageRegistry.displayLabel('pt'), '葡萄牙语 · Português');
        expect(AsrLanguageRegistry.displayLabel('ru'), '俄语 · Русский');
        expect(AsrLanguageRegistry.displayLabel('xx'), isNull);
      },
    );

    test('keeps automatic recognition as a mode rather than a language', () {
      expect(
        AsrLanguageRegistry.parseRecognitionMode('auto'),
        AsrRecognitionMode.auto,
      );
      expect(
        AsrLanguageRegistry.parseRecognitionMode(' AUTOMATIC '),
        AsrRecognitionMode.auto,
      );
      expect(
        AsrLanguageRegistry.parseRecognitionMode('manual'),
        AsrRecognitionMode.manual,
      );
      expect(AsrLanguageRegistry.parseRecognitionMode('en'), isNull);
      expect(AsrRecognitionMode.auto.displayLabel, '自动识别');
      expect(AsrRecognitionMode.manual.displayLabel, '手动选择');
    });

    test('selects the same model family for every registered ASR language', () {
      expect(AsrLanguageRegistry.usesMultilingualModel('en'), isFalse);
      expect(AsrLanguageRegistry.usesMultilingualModel('zh-CN'), isFalse);
      for (final code in ['ja', 'ko', 'es', 'fr', 'de', 'pt', 'ru']) {
        expect(
          AsrLanguageRegistry.usesMultilingualModel(code),
          isTrue,
          reason: code,
        );
      }
      expect(AsrLanguageRegistry.usesMultilingualModel('auto'), isTrue);
      expect(AsrLanguageRegistry.usesMultilingualModel('xx'), isFalse);
    });
  });
}
