import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yixue_app/core/native_core_bridge.dart';

class DictionaryPackageImportResult {
  const DictionaryPackageImportResult({
    required this.packageId,
    required this.displayName,
    required this.license,
    required this.entries,
  });

  final String packageId;
  final String displayName;
  final String license;
  final List<DictionaryEntryData> entries;
}

class DictionaryPackageException implements Exception {
  const DictionaryPackageException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DictionaryPackageService {
  const DictionaryPackageService();

  static const schemaVersion = 1;
  static const maxPackageBytes = 100 * 1024 * 1024;
  static const maxEntries = 100000;

  /// A structurally complete, intentionally tiny package that users can copy
  /// and edit. The placeholder license is deliberately not importable.
  static const templateJson = '''{
  "schema_version": 1,
  "id": "my-dictionary.en-zh",
  "name": "我的英汉词典",
  "language_pair": "en-zh",
  "license": "请填写词典数据的真实许可证",
  "entries": [
    {
      "word": "example",
      "ipa": "/ɪɡˈzɑːmpəl/",
      "part_of_speech": "n. 名词",
      "meanings": ["例子；实例"],
      "example": "This is an example sentence.",
      "example_translation": "这是一个例句。"
    }
  ]
}
''';

  static const importGuidance = '''
词典文件不是翻译模型，也不是 Word、PDF、Excel 或模型文件；当前只能导入 UTF-8 编码的英汉（en-zh）JSON v1。
只导入你拥有、公开许可或已经获准使用的词典数据（包括你自己制作的数据）。牛津、朗文、柯林斯等商业词典必须先取得明确授权，不能因为“能下载”就直接导入或随软件分发。
导入前请把模板中的示例许可证替换为真实许可，并保留来源、版本和修改说明。
软件只解析词条数据，不执行 JSON 中的代码、不访问网络；单个文件不超过 100 MB，最多 100000 条词条。''';

  static const _templateLicense = '请填写词典数据的真实许可证';

  Future<DictionaryPackageImportResult> readFile(File file) async {
    final length = await file.length();
    if (length > maxPackageBytes) {
      throw const DictionaryPackageException('词典包超过 100 MB，已拒绝导入');
    }
    return parse(await file.readAsBytes());
  }

  DictionaryPackageImportResult parse(Uint8List bytes) {
    if (bytes.length > maxPackageBytes) {
      throw const DictionaryPackageException('词典包超过 100 MB，已拒绝导入');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      throw const DictionaryPackageException('词典包不是有效的 UTF-8 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const DictionaryPackageException('词典包顶层必须是对象');
    }
    if (decoded['schema_version'] != schemaVersion) {
      throw const DictionaryPackageException('词典包版本不受支持');
    }
    final id = _text(decoded['id'], '词典包缺少安全的 id');
    final name = _text(decoded['name'], '词典包缺少名称');
    final license = _text(decoded['license'], '词典包缺少许可信息');
    if (license == _templateLicense) {
      throw const DictionaryPackageException('请先填写词典数据的真实许可证，再导入词典包');
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{1,63}$').hasMatch(id)) {
      throw const DictionaryPackageException('词典包 id 只能包含字母、数字、点、下划线和连字符');
    }
    if (decoded['language_pair'] != 'en-zh') {
      throw const DictionaryPackageException('当前只支持 en-zh 英汉词典包');
    }
    final rawEntries = decoded['entries'];
    if (rawEntries is! List<dynamic> ||
        rawEntries.isEmpty ||
        rawEntries.length > maxEntries) {
      throw const DictionaryPackageException('词典包 entries 数量无效');
    }
    final entries = <DictionaryEntryData>[];
    for (var index = 0; index < rawEntries.length; index++) {
      final raw = rawEntries[index];
      if (raw is! Map<String, dynamic>) {
        throw DictionaryPackageException('第 ${index + 1} 条词典记录格式无效');
      }
      final word = _text(raw['word'], '第 ${index + 1} 条缺少单词');
      final meanings = raw['meanings'];
      if (meanings is! List<dynamic> ||
          meanings.isEmpty ||
          meanings.length > 32 ||
          meanings.any((item) => item is! String || item.trim().isEmpty)) {
        throw DictionaryPackageException('第 ${index + 1} 条释义格式无效');
      }
      entries.add(
        DictionaryEntryData(
          id: 'package.$id.${index + 1}',
          word: word,
          ipa: _text(raw['ipa'], '第 ${index + 1} 条缺少音标'),
          partOfSpeech: _text(raw['part_of_speech'], '第 ${index + 1} 条缺少词性'),
          meanings: meanings.cast<String>().map((item) => item.trim()).toList(),
          example: _text(raw['example'], '第 ${index + 1} 条缺少例句'),
          exampleTranslation: _text(
            raw['example_translation'],
            '第 ${index + 1} 条缺少例句翻译',
          ),
          source: '$id · $name · $license',
        ),
      );
    }
    return DictionaryPackageImportResult(
      packageId: id,
      displayName: name,
      license: license,
      entries: List.unmodifiable(entries),
    );
  }

  static String _text(dynamic value, String message) {
    if (value is! String) throw DictionaryPackageException(message);
    final text = value.trim();
    if (text.isEmpty || text.length > 2000) {
      throw DictionaryPackageException(message);
    }
    return text;
  }
}
