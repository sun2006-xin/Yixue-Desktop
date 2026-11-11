import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_package_service.dart';

Uint8List _jsonBytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, Object> _validPackage() => {
  'schema_version': 1,
  'id': 'demo.en-zh',
  'name': '我的学习词典',
  'language_pair': 'en-zh',
  'license': 'CC BY-NC 4.0',
  'entries': [
    {
      'word': 'inference',
      'ipa': '/ˈɪnfərəns/',
      'part_of_speech': 'n. 名词',
      'meanings': ['推理；推断'],
      'example': 'The inference is supported by the evidence.',
      'example_translation': '这个推断有证据支持。',
    },
  ],
};

void main() {
  const service = DictionaryPackageService();

  test('provides a structurally complete editable template', () {
    final template = jsonDecode(DictionaryPackageService.templateJson);

    expect(template, isA<Map<String, dynamic>>());
    expect(template['schema_version'], 1);
    expect(template['language_pair'], 'en-zh');
    expect(template['license'], '请填写词典数据的真实许可证');
    expect(template['entries'], hasLength(1));
  });

  test('rejects the unedited template instead of treating its placeholder as a license', () {
    expect(
      () => service.parse(
        Uint8List.fromList(utf8.encode(DictionaryPackageService.templateJson)),
      ),
      throwsA(
        isA<DictionaryPackageException>().having(
          (error) => error.message,
          'message',
          contains('请先填写词典数据的真实许可证'),
        ),
      ),
    );
  });

  test(
    'exposes import guidance without implying commercial dictionary rights',
    () {
      expect(
        DictionaryPackageService.importGuidance,
        contains('只导入你拥有、公开许可或已经获准使用的词典数据'),
      );
      expect(DictionaryPackageService.importGuidance, contains('牛津、朗文、柯林斯'));
      expect(DictionaryPackageService.importGuidance, contains('词典文件不是翻译模型'));
      expect(DictionaryPackageService.importGuidance, contains('UTF-8'));
      expect(
        DictionaryPackageService.importGuidance,
        contains('不执行 JSON 中的代码'),
      );
    },
  );

  test('parses an English-Chinese package and namespaces entry IDs', () {
    final result = service.parse(_jsonBytes(_validPackage()));

    expect(result.displayName, '我的学习词典');
    expect(result.license, 'CC BY-NC 4.0');
    expect(result.entries.single.id, 'package.demo.en-zh.1');
    expect(result.entries.single.word, 'inference');
    expect(result.entries.single.source, contains('我的学习词典'));
  });

  test('rejects an unsupported language pair before importing entries', () {
    final value = _validPackage()..['language_pair'] = 'zh-en';

    expect(
      () => service.parse(_jsonBytes(value)),
      throwsA(
        isA<DictionaryPackageException>().having(
          (error) => error.message,
          'message',
          contains('只支持 en-zh'),
        ),
      ),
    );
  });

  test('rejects packages without a license or entries', () {
    final missingLicense = _validPackage()..remove('license');
    final missingEntries = _validPackage()..['entries'] = <Object>[];

    expect(() => service.parse(_jsonBytes(missingLicense)), throwsException);
    expect(() => service.parse(_jsonBytes(missingEntries)), throwsException);
  });
}
