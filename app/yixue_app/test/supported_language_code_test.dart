import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/supported_language_code.dart';

void main() {
  group('canonicalSupportedLanguageCode', () {
    test('normalizes supported aliases, case, scripts, and regions', () {
      const cases = <String, String>{
        'EN': 'en',
        'eng': 'en',
        'English': 'en',
        'zh': 'zh',
        'zho-TW': 'zh',
        'chi': 'zh',
        'cmn-Hans-CN': 'zh',
        'Mandarin': 'zh',
        'jpn-JP': 'ja',
        'Japanese': 'ja',
        'kor-KR': 'ko',
        'Korean': 'ko',
        'es-ES': 'es',
        'spa': 'es',
        'French': 'fr',
        'de-DE': 'de',
        'pt-BR': 'pt',
        'rus': 'ru',
      };

      for (final entry in cases.entries) {
        expect(
          canonicalSupportedLanguageCode(entry.key),
          entry.value,
          reason: 'language tag ${entry.key} should canonicalize',
        );
      }

      expect(canonicalSupportedLanguageCode('ZH_hant_tw'), 'zh');
      expect(canonicalSupportedLanguageCode(''), isNull);
      expect(canonicalSupportedLanguageCode('  '), isNull);
      expect(canonicalSupportedLanguageCode('en--US'), isNull);
      expect(canonicalSupportedLanguageCode('xx-XX'), isNull);
    });
  });

  group('isTraditionalChineseLanguageTag', () {
    test('detects traditional script and regional tags', () {
      for (final tag in <String>['zh-Hant', 'zh_Hant_TW', 'zho-HK', 'cmn-MO']) {
        expect(
          isTraditionalChineseLanguageTag(tag),
          isTrue,
          reason: 'language tag $tag should be treated as traditional Chinese',
        );
      }

      for (final tag in <String>['zh', 'zh-Hans-CN', 'en-TW', 'zh-']) {
        expect(
          isTraditionalChineseLanguageTag(tag),
          isFalse,
          reason:
              'language tag $tag should not be treated as traditional Chinese',
        );
      }
    });
  });
}
