import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/local_data_export_service.dart';

void main() {
  test(
    'exports allowlisted local data and writes an exclusion manifest',
    () async {
      final root = await Directory.systemTemp.createTemp('yixue-data-export-');
      addTearDown(() => root.delete(recursive: true));
      final source = Directory('${root.path}\\user-data')..createSync();
      final destination = Directory('${root.path}\\backup');
      File('${source.path}\\yixue.db').writeAsStringSync('db');
      File('${source.path}\\appearance-preferences.json')
          .writeAsStringSync('{"schemaVersion":1}');
      File('${source.path}\\private-cache.tmp').writeAsStringSync('skip');

      final result = await LocalDataExportService.export(
        source: source,
        destinationParent: destination,
        clock: () => DateTime(2026, 9, 13, 2, 3, 4, 5),
      );

      expect(result.files, ['yixue.db', 'appearance-preferences.json']);
      expect(
        File('${result.destination.path}\\yixue.db').readAsStringSync(),
        'db',
      );
      expect(
        File('${result.destination.path}\\private-cache.tmp').existsSync(),
        isFalse,
      );
      final manifest = File('${result.destination.path}\\export-manifest.json')
          .readAsStringSync();
      expect(manifest, contains('API 密钥'));
      expect(manifest, contains('模型权重与运行时缓存'));
    },
  );

  test('rejects exporting into the data directory itself', () async {
    final root = await Directory.systemTemp.createTemp('yixue-data-export-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}\\user-data')..createSync();

    expect(
      LocalDataExportService.export(
        source: source,
        destinationParent: Directory('${source.path}\\backup'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'includes textbook and learning workspace files in the backup',
    () async {
      final root = await Directory.systemTemp.createTemp('yixue-data-export-');
      addTearDown(() => root.delete(recursive: true));
      final source = Directory('${root.path}\\user-data')..createSync();
      final destination = Directory('${root.path}\\backup');
      File('${source.path}\\learning-textbooks.json')
          .writeAsStringSync('{"schema_version":1,"packages":[]}');
      File('${source.path}\\learning-workspace.json')
          .writeAsStringSync('{"schema_version":2}');
      File('${source.path}\\model-cache.bin').writeAsStringSync('skip');

      final result = await LocalDataExportService.export(
        source: source,
        destinationParent: destination,
        clock: () => DateTime(2026, 9, 16, 2, 3, 4, 5),
      );

      expect(result.files, [
        'learning-workspace.json',
        'learning-textbooks.json',
      ]);
      expect(
        File('${result.destination.path}\\learning-textbooks.json')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${result.destination.path}\\model-cache.bin').existsSync(),
        isFalse,
      );
    },
  );
}
