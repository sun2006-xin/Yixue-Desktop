import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/app_data_directory.dart';

void main() {
  test('default user data never shares Flutter runtime data directory', () {
    final path = resolveAppDataPath(
      configuredDirectory: null,
      executablePath: r'D:\preview\yixue_app.exe',
    );

    expect(path, r'D:\preview\user-data');
    expect(path, isNot(r'D:\preview\data'));
  });

  test('implicit Windows Debug data stays under a separate temp directory', () {
    final path = isolatedDebugAppDataPath(
      tempDirectoryPath: r'C:\Users\test\AppData\Local\Temp',
      processId: 4120,
    );

    expect(path, r'C:\Users\test\AppData\Local\Temp\Yixue-debug-4120');
    expect(path, isNot(r'C:\Users\test\AppData\Local\Yixue'));
    expect(path, isNot(r'D:\Yixue\user-data'));
  });

  test('configured D drive data directory remains authoritative', () {
    final path = resolveAppDataPath(
      configuredDirectory: r'D:\Yixue\user-data',
      executablePath: r'D:\preview\yixue_app.exe',
    );

    expect(path, r'D:\Yixue\user-data');
  });

  test('stored user-selected directory outranks the executable default', () {
    final path = resolveAppDataPath(
      configuredDirectory: null,
      storedDirectory: r'D:\译学资料库',
      executablePath: r'D:\preview\yixue_app.exe',
    );

    expect(path, r'D:\译学资料库');
  });

  test(
    'data location pointer has a stable path outside the selected data folder',
    () {
      final path = resolveAppDataPreferenceFilePath(
        executablePath: r'D:\Yixue\releases\preview\v1\yixue_app.exe',
        configuredDirectory: r'D:\Yixue\user-data',
      );

      expect(path, r'D:\Yixue\user-data\data-location.json');
    },
  );

  test(
    'data directory preference round trips and rejects relative paths',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-data-location-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}location.json',
      );
      final store = AppDataDirectoryPreferenceStore(file);

      await store.write(r'D:\Yixue\user-data');

      expect(await store.read(), r'D:\Yixue\user-data');
      await expectLater(
        store.write('relative-user-data'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('malformed data directory preference fails closed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-data-location-invalid-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(
      '${directory.path}${Platform.pathSeparator}location.json',
    );
    await file.writeAsString('{"schemaVersion":1,"dataDirectory":"relative"}');

    expect(await AppDataDirectoryPreferenceStore(file).read(), isNull);
  });

  test(
    'versioned preview executables share the release-root data directory',
    () {
      final path = resolveAppDataPath(
        configuredDirectory: null,
        executablePath:
            r'D:\Yixue\releases\preview\v0.1.0-preview.abc\yixue_app.exe',
      );

      expect(path, r'D:\Yixue\user-data');
    },
  );
}
