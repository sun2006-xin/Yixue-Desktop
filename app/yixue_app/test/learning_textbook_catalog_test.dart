import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/learning_textbook_catalog.dart';

Map<String, Object?> _manifest({
  String license = 'CC BY 4.0',
  List<Object?>? lessons,
}) => <String, Object?>{
  'schema_version': 1,
  'id': 'school-english-middle',
  'title': '我的初中英语课',
  'age_band': '初中',
  'level': 'middle',
  'version': '自制 1.0',
  'language': 'en-zh',
  'license_name': license,
  'license_url': 'https://creativecommons.org/licenses/by/4.0/',
  'rights_holder': '我自己制作',
  'source_url': '',
  'redistribution_allowed': false,
  'lessons':
      lessons ??
      [
        <String, Object?>{
          'id': 'unit-1',
          'title': '问候',
          'source_text': 'Hello, world.',
          'translation': '你好，世界。',
          'vocabulary': ['hello', 'world'],
        },
      ],
};

void main() {
  const service = LearningTextbookPackageService();

  test('parses a structured package and records its import metadata', () {
    final package = service.parse(
      Uint8List.fromList(utf8.encode(jsonEncode(_manifest()))),
      fileName: 'middle-course.json',
    );

    expect(package.origin, LearningTextbookOrigin.userImported);
    expect(package.lessons.single.sourceText, 'Hello, world.');
    expect(package.licenseName, 'CC BY 4.0');
    expect(package.importedFrom, 'middle-course.json');
  });

  test('parses a ZIP package only through its manifest', () {
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'learning-textbook.json',
          utf8.encode(jsonEncode(_manifest())).length,
          utf8.encode(jsonEncode(_manifest())),
        ),
      );
    final bytes = ZipEncoder().encode(archive);
    expect(bytes, isNotNull);

    final package = service.parse(
      Uint8List.fromList(bytes),
      fileName: 'middle-course.yxtbook',
    );
    expect(package.lessons.single.id, 'unit-1');
  });

  test('rejects a package with placeholder or missing rights information', () {
    expect(
      () => service.parse(
        Uint8List.fromList(
          utf8.encode(jsonEncode(_manifest(license: '请填写真实许可证或授权说明'))),
        ),
        fileName: 'invalid.json',
      ),
      throwsA(isA<LearningTextbookPackageException>()),
    );
    expect(
      () => service.parse(
        Uint8List.fromList(
          utf8.encode(jsonEncode({..._manifest()..remove('rights_holder')})),
        ),
        fileName: 'invalid.json',
      ),
      throwsA(isA<LearningTextbookPackageException>()),
    );
  });

  test('imports a UTF-8 document as one local lesson', () {
    final package = service.parseDocument(
      bytes: Uint8List.fromList(utf8.encode('One paragraph.\n\nAnother one.')),
      fileName: 'my-course.txt',
      title: '我的课程',
      ageBand: '高中',
      level: 'high',
      version: '自制 1.0',
      licenseName: '我自有内容',
      rightsHolder: '我自己制作',
    );

    expect(package.lessons.single.sourceText, 'One paragraph.\n\nAnother one.');
    expect(package.lessons.single.translation, isEmpty);
    expect(package.redistributionAllowed, isFalse);
  });

  test('splits a long UTF-8 document into bounded readable lessons', () {
    final text = List.generate(
      260,
      (index) => 'Paragraph $index ${'practice and learning ' * 9}.',
    ).join('\n\n');
    final package = service.parseDocument(
      bytes: Uint8List.fromList(utf8.encode(text)),
      fileName: 'long-course.md',
      title: 'Long course',
      ageBand: 'General',
      level: 'custom',
      version: 'Local import',
      licenseName: 'User authorized copy',
      rightsHolder: 'User supplied material',
    );

    expect(package.lessons.length, greaterThan(1));
    expect(package.lessons.length, lessThanOrEqualTo(200));
    expect(
      package.lessons.every(
        (lesson) =>
            lesson.sourceText.length <=
            LearningTextbookPackageService.maxDocumentLessonCharacters,
      ),
      isTrue,
    );
    expect(package.lessons.map((lesson) => lesson.sourceText).join(), text);
  });

  test('uses the latest eligible paragraph or word boundary', () {
    final text = '${'a' * 3000}\n${'b' * 400} ${'c' * 1000}';
    final chunks = LearningTextbookPackageService.splitTextPreservingBoundaries(
      text,
      maxCharacters: 4000,
    );

    expect(chunks.first.length, 3402);
    expect(chunks.first.endsWith(' '), isTrue);
    expect(chunks.join(), text);
  });

  test('keeps UTF-16 surrogate pairs intact when a chunk ends nearby', () {
    const text = 'abc😀xyz';
    final chunks = LearningTextbookPackageService.splitTextPreservingBoundaries(
      text,
      maxCharacters: 4,
    );

    expect(chunks.first, 'abc');
    expect(chunks[1].startsWith('😀'), isTrue);
    expect(chunks.join(), text);
  });

  test('persists imported packages in the local store', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-textbook-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileLearningTextbookStore(
      File('${directory.path}${Platform.pathSeparator}textbooks.json'),
    );
    final package = service.parse(
      Uint8List.fromList(utf8.encode(jsonEncode(_manifest()))),
      fileName: 'middle-course.json',
    );

    await store.write([package]);
    final restored = await store.read();
    expect(restored.single.id, package.id);
    expect(restored.single.lessons.single.title, '问候');
  });
}
