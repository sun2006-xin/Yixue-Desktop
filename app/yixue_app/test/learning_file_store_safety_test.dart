import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/learning_workbench.dart';

void main() {
  test(
    'rejects a corrupt existing learning file instead of returning empty',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-learning-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}learning.json',
      );
      const contents = '{not valid json';
      await file.writeAsString(contents);

      final store = FileLearningStore(file);
      await expectLater(store.read(), throwsFormatException);
      await expectLater(
        store.write(const LearningStateData.empty()),
        throwsFormatException,
      );
      expect(await file.readAsString(), contents);
    },
  );

  test(
    'keeps the previous learning file when atomic replacement fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-learning-store-commit-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}learning.json',
      );
      final initialStore = FileLearningStore(file);
      await initialStore.write(const LearningStateData.empty());
      await file.writeAsString('${await file.readAsString()}\n');
      final original = await file.readAsString();

      final failingStore = FileLearningStore(
        file,
        commit: (staged, destination) async {
          if (destination.path == file.path) {
            throw FileSystemException(
              'injected replacement failure',
              file.path,
            );
          }
          await staged.rename(destination.path);
        },
      );

      await expectLater(
        failingStore.write(const LearningStateData.empty()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), original);
      final backup = File('${file.path}.backup');
      expect(await backup.readAsString(), original);
      final pendingFiles = await directory
          .list()
          .where((entry) => entry.path.endsWith('.pending'))
          .toList();
      expect(pendingFiles, isEmpty);
    },
  );

  test('serializes writes from stores that share one file path', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-learning-store-shared-path-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(
      '${directory.path}${Platform.pathSeparator}learning.json',
    );
    await FileLearningStore(file).write(const LearningStateData.empty());

    final firstMainCommitEntered = Completer<void>();
    final releaseFirstMainCommit = Completer<void>();
    var firstMainCommitBlocked = false;
    var activeCommits = 0;
    var maximumConcurrentCommits = 0;
    Future<void> commit(File staged, File destination) async {
      activeCommits += 1;
      if (activeCommits > maximumConcurrentCommits) {
        maximumConcurrentCommits = activeCommits;
      }
      try {
        if (destination.path == file.path && !firstMainCommitBlocked) {
          firstMainCommitBlocked = true;
          firstMainCommitEntered.complete();
          await releaseFirstMainCommit.future;
        }
        if (await destination.exists()) await destination.delete();
        await staged.rename(destination.path);
      } finally {
        activeCommits -= 1;
      }
    }

    final firstStore = FileLearningStore(file, commit: commit);
    final secondStore = FileLearningStore(file, commit: commit);
    final firstWrite = firstStore.write(const LearningStateData.empty());
    await firstMainCommitEntered.future;
    final secondWrite = secondStore.write(const LearningStateData.empty());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(maximumConcurrentCommits, 1);

    releaseFirstMainCommit.complete();
    await Future.wait([firstWrite, secondWrite]);
    expect(maximumConcurrentCommits, 1);
    expect(await FileLearningStore(file).read(), isNotNull);
  });
}
