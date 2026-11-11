import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/screenshot_translation_image_store.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory imageDirectory;
  late FileScreenshotTranslationImageStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'yixue-screenshot-images-test-',
    );
    imageDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}screenshot_translation',
    );
    store = FileScreenshotTranslationImageStore(imageDirectory);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('saves, reads, replaces, deletes, and inspects image bytes', () async {
    final firstBytes = Uint8List.fromList([137, 80, 78, 71, 1]);
    final replacementBytes = Uint8List.fromList([137, 80, 78, 71, 2, 3]);

    await store.save('screenshot_123-ab', firstBytes);
    expect(await store.read('screenshot_123-ab'), firstBytes);
    expect(
      await store.inspect(),
      ScreenshotTranslationImageStats(imageCount: 1, totalBytes: 5),
    );

    await store.save('screenshot_123-ab', replacementBytes);
    expect(await store.read('screenshot_123-ab'), replacementBytes);
    expect(
      await store.inspect(),
      ScreenshotTranslationImageStats(imageCount: 1, totalBytes: 6),
    );

    await store.delete('screenshot_123-ab');
    expect(await store.read('screenshot_123-ab'), isNull);
    expect(await store.inspect(), ScreenshotTranslationImageStats.empty);
    await store.delete('screenshot_123-ab');
  });

  test(
    'read rejects an in-root symlink to an image outside the store',
    () async {
      await imageDirectory.create(recursive: true);
      final externalBytes = Uint8List.fromList([9, 8, 7, 6]);
      final externalTarget = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}outside.png',
      );
      await externalTarget.writeAsBytes(externalBytes);
      final link = Link(
        '${imageDirectory.path}${Platform.pathSeparator}outside-image.png',
      );
      var linkCreated = false;

      try {
        try {
          await link.create(externalTarget.path);
          linkCreated = true;
        } on FileSystemException catch (error) {
          markTestSkipped('Symbolic-link creation was blocked: $error');
        }

        expect(
          await FileSystemEntity.type(link.path, followLinks: false),
          FileSystemEntityType.link,
        );
        await expectLater(
          store.read('outside-image'),
          throwsA(isA<FileSystemException>()),
        );
        expect(await externalTarget.readAsBytes(), externalBytes);
      } finally {
        if (linkCreated &&
            await FileSystemEntity.type(link.path, followLinks: false) ==
                FileSystemEntityType.link) {
          await link.delete();
        }
        if (await externalTarget.exists()) await externalTarget.delete();
      }
    },
  );

  test('image storage refuses a linked root directory', () async {
    final outsideDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}outside-store',
    );
    await outsideDirectory.create();
    final outsideImage = File(
      '${outsideDirectory.path}${Platform.pathSeparator}retained-image.png',
    );
    final bytes = Uint8List.fromList([3, 5, 8]);
    await outsideImage.writeAsBytes(bytes);
    final rootLink = Link(imageDirectory.path);
    var linkCreated = false;
    try {
      try {
        await rootLink.create(outsideDirectory.path);
        linkCreated = true;
      } on FileSystemException catch (error) {
        markTestSkipped('Directory-link creation was blocked: $error');
      }

      await expectLater(store.inspect(), throwsA(isA<FileSystemException>()));
      await expectLater(store.clearAll(), throwsA(isA<FileSystemException>()));
      await expectLater(
        store.save('must-not-follow-root-link', bytes),
        throwsA(isA<FileSystemException>()),
      );
      expect(await outsideImage.readAsBytes(), bytes);
    } finally {
      if (linkCreated &&
          await FileSystemEntity.type(rootLink.path, followLinks: false) ==
              FileSystemEntityType.link) {
        await rootLink.delete();
      }
    }
  });

  test(
    'read preserves null for missing images and rejects directories',
    () async {
      expect(await store.read('missing-image'), isNull);

      final directoryEntry = Directory(
        '${imageDirectory.path}${Platform.pathSeparator}directory-image.png',
      );
      await directoryEntry.create(recursive: true);

      await expectLater(
        store.read('directory-image'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'rejects empty, path-like, and overlong history IDs before file access',
    () async {
      for (final historyId in [
        '',
        '../outside',
        'nested/id',
        r'nested\id',
        'a' * 129,
      ]) {
        await expectLater(
          store.save(historyId, Uint8List.fromList([1])),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          store.read(historyId),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          store.delete(historyId),
          throwsA(isA<FormatException>()),
        );
      }
      expect(await imageDirectory.exists(), isFalse);
    },
  );

  test('inspect and clear only owned images in the storage directory', () async {
    await store.save('image-a', Uint8List.fromList([1, 2]));
    await store.save('image-b', Uint8List.fromList([3, 4, 5]));
    final notes = File(
      '${imageDirectory.path}${Platform.pathSeparator}notes.txt',
    );
    await notes.writeAsString('keep');
    final temporary = File(
      '${imageDirectory.path}${Platform.pathSeparator}.image-c.pending',
    );
    await temporary.writeAsString('partial');
    final crashedStaging = File(
      '${imageDirectory.path}${Platform.pathSeparator}image-c.png.88-999-1.pending',
    );
    await crashedStaging.writeAsBytes([10, 11, 12]);
    final nestedImage = File(
      '${imageDirectory.path}${Platform.pathSeparator}nested${Platform.pathSeparator}image-c.png',
    );
    await nestedImage.parent.create(recursive: true);
    await nestedImage.writeAsBytes([6, 7, 8, 9]);

    expect(
      await store.inspect(),
      ScreenshotTranslationImageStats(imageCount: 2, totalBytes: 5),
    );
    await store.clearAll();

    expect(await store.inspect(), ScreenshotTranslationImageStats.empty);
    expect(await notes.readAsString(), 'keep');
    expect(await temporary.readAsString(), 'partial');
    expect(await crashedStaging.exists(), isFalse);
    expect(await nestedImage.readAsBytes(), [6, 7, 8, 9]);
  });

  test('inspect removes stale owned staging files but keeps recent files', () async {
    await imageDirectory.create(recursive: true);
    final oldStaging = File(
      '${imageDirectory.path}${Platform.pathSeparator}orphan.png.88-999-1.pending',
    );
    final recentStaging = File(
      '${imageDirectory.path}${Platform.pathSeparator}active.png.99-1000-2.pending',
    );
    final unrelated = File(
      '${imageDirectory.path}${Platform.pathSeparator}notes.pending',
    );
    await oldStaging.writeAsBytes([1, 2, 3]);
    await oldStaging.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    await recentStaging.writeAsBytes([4, 5]);
    await unrelated.writeAsString('keep');

    expect(await store.inspect(), ScreenshotTranslationImageStats.empty);

    expect(await oldStaging.exists(), isFalse);
    expect(await recentStaging.exists(), isTrue);
    expect(await unrelated.readAsString(), 'keep');
  });

  test('inspect retains and reads an interrupted deletion backup', () async {
    await imageDirectory.create(recursive: true);
    final bytes = Uint8List.fromList([6, 2, 6, 4]);
    final original = File(
      '${imageDirectory.path}${Platform.pathSeparator}interrupted.png',
    );
    await original.writeAsBytes(bytes);
    final backup = File('${original.path}.88-999-1.rollback');
    await original.copy(backup.path);
    await original.delete();
    await backup.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );

    expect(
      await store.inspect(),
      ScreenshotTranslationImageStats(imageCount: 1, totalBytes: bytes.length),
    );
    expect(await original.exists(), isFalse);
    expect(await store.read('interrupted'), bytes);
    expect(await backup.exists(), isTrue);
  });

  test('deletion retries and removes an interrupted rollback backup', () async {
    await imageDirectory.create(recursive: true);
    final original = File(
      '${imageDirectory.path}${Platform.pathSeparator}interrupted-delete.png',
    );
    final backup = File('${original.path}.88-999-2.rollback');
    await backup.writeAsBytes(Uint8List.fromList([9, 8, 7]));

    await store.deleteImageAndThen('interrupted-delete', () async {});

    expect(await original.exists(), isFalse);
    expect(await backup.exists(), isFalse);
    expect(await store.inspect(), ScreenshotTranslationImageStats.empty);
  });

  test('batch deletion stages every image before history commit and restores all on failure', () async {
    final firstBytes = Uint8List.fromList([2, 4, 6]);
    final secondBytes = Uint8List.fromList([1, 3, 5, 7]);
    await store.save('batch-first', firstBytes);
    await store.save('batch-second', secondBytes);
    final oldLease = store.beginImageWrite('batch-first');

    await expectLater(
      store.deleteImagesAndThen(['batch-second', 'batch-first'], () async {
        expect(await store.read('batch-first'), isNotNull);
        expect(
          await File('${store.rootDirectory.path}/batch-first.png').exists(),
          isFalse,
        );
        expect(
          await File('${store.rootDirectory.path}/batch-second.png').exists(),
          isFalse,
        );
        expect(
          (await store.rootDirectory
              .list(followLinks: false)
              .where((entity) => entity.path.endsWith('.rollback'))
              .toList()),
          hasLength(2),
        );
        throw StateError('simulated history transaction failure');
      }),
      throwsA(isA<StateError>()),
    );

    expect(await store.read('batch-first'), firstBytes);
    expect(await store.read('batch-second'), secondBytes);
    expect(store.acceptsImageWriteLease('batch-first', oldLease), isFalse);
    final freshLease = store.beginImageWrite('batch-first');
    expect(store.acceptsImageWriteLease('batch-first', freshLease), isTrue);
    expect(
      await store.saveWithLease('batch-first', firstBytes, freshLease),
      isTrue,
    );
    expect(
      await store.inspect(),
      ScreenshotTranslationImageStats(
        imageCount: 2,
        totalBytes: firstBytes.length + secondBytes.length,
      ),
    );
  });

  test(
    'staging failure removes deletion tombstones but never revives old leases',
    () async {
      final bytes = Uint8List.fromList([1, 4, 9]);
      await store.save('first', bytes);
      await Directory('${imageDirectory.path}/second.png').create();
      final oldLease = store.beginImageWrite('first');
      var historyCalled = false;
      await expectLater(
        store.deleteImagesAndThen(['first', 'second'], () async {
          historyCalled = true;
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(historyCalled, isFalse);
      expect(await store.read('first'), bytes);
      expect(store.acceptsImageWriteLease('first', oldLease), isFalse);
      expect(
        store.acceptsImageWriteLease('first', store.beginImageWrite('first')),
        isTrue,
      );
      expect(
        store.acceptsImageWriteLease('second', store.beginImageWrite('second')),
        isTrue,
      );
    },
  );

  test('rollback cannot remove a newer queued deletion tombstone', () async {
    await store.save('shared', Uint8List.fromList([1]));
    final historyStarted = Completer<void>();
    final releaseHistory = Completer<void>();
    final first = store.deleteImageAndThen('shared', () async {
      historyStarted.complete();
      await releaseHistory.future;
      throw StateError('first history transaction failed');
    });
    final failed = expectLater(first, throwsStateError);
    await historyStarted.future;
    final second = store.deleteImageAndThen('shared', () async {
      expect(
        store.acceptsImageWriteLease('shared', store.beginImageWrite('shared')),
        isFalse,
      );
    });
    releaseHistory.complete();
    await failed;
    await second;
    expect(
      store.acceptsImageWriteLease('shared', store.beginImageWrite('shared')),
      isFalse,
    );
  });

  test(
    'batch rollback restores the image staged by the current deletion',
    () async {
      final currentBytes = Uint8List.fromList([9, 8, 7]);
      await store.save('rollback-prefers-current', currentBytes);
      final staleBackup = File(
        '${imageDirectory.path}${Platform.pathSeparator}'
        'rollback-prefers-current.png.88-900-1.rollback',
      );
      await staleBackup.writeAsBytes(Uint8List.fromList([1, 2, 3]));

      await expectLater(
        store.deleteImageAndThen('rollback-prefers-current', () async {
          throw StateError('simulated history transaction failure');
        }),
        throwsA(isA<StateError>()),
      );

      expect(await store.read('rollback-prefers-current'), currentBytes);
      expect(await staleBackup.exists(), isFalse);
      expect(
        (await imageDirectory.list(followLinks: false).toList()).where(
          (entity) => entity.path.endsWith('.rollback'),
        ),
        isEmpty,
      );
    },
  );

  test('recovery restores referenced backups and removes backups for deleted history', () async {
    await imageDirectory.create(recursive: true);
    final retainedBytes = Uint8List.fromList([8, 6, 4, 2]);
    final orphanBytes = Uint8List.fromList([7, 5, 3]);
    final retainedBackup = File(
      '${imageDirectory.path}${Platform.pathSeparator}'
      'retained.png.88-999-4.rollback',
    );
    final orphanImage = File(
      '${imageDirectory.path}${Platform.pathSeparator}orphaned.png',
    );
    final orphanBackup = File('${orphanImage.path}.88-999-5.rollback');
    final committedBackup = File(
      '${imageDirectory.path}${Platform.pathSeparator}'
      'committed.png.88-999-6.committed',
    );
    await retainedBackup.writeAsBytes(retainedBytes);
    await orphanImage.writeAsBytes(orphanBytes);
    await orphanBackup.writeAsBytes(orphanBytes);
    await committedBackup.writeAsBytes(Uint8List.fromList([6, 6]));

    await store.recoverPendingDeletionBackups((captureIds) async {
      expect(captureIds, ['orphaned', 'retained']);
      return {'retained'};
    });

    expect(await store.read('retained'), retainedBytes);
    expect(await orphanImage.exists(), isFalse);
    expect(await orphanBackup.exists(), isFalse);
    expect(await committedBackup.exists(), isFalse);
    expect(
      await store.inspect(),
      ScreenshotTranslationImageStats(
        imageCount: 1,
        totalBytes: retainedBytes.length,
      ),
    );
  });

  test(
    'deletion removes a crashed pending image stage for its capture',
    () async {
      await imageDirectory.create(recursive: true);
      final staging = File(
        '${imageDirectory.path}${Platform.pathSeparator}'
        'interrupted-stage.png.88-999-3.pending',
      );
      await staging.writeAsBytes(Uint8List.fromList([1, 4, 9]));

      expect(
        await store.hasImageOrDeletionResidue('interrupted-stage'),
        isTrue,
      );
      await store.deleteImageAndThen('interrupted-stage', () async {});

      expect(await staging.exists(), isFalse);
      expect(
        await store.hasImageOrDeletionResidue('interrupted-stage'),
        isFalse,
      );
    },
  );

  test(
    'failed atomic replacement preserves old image and removes staging file',
    () async {
      final originalBytes = Uint8List.fromList([1, 2, 3]);
      await store.save('same-id', originalBytes);
      final failingStore = FileScreenshotTranslationImageStore(
        imageDirectory,
        commit: (staged, destination) async {
          expect(staged.parent.path, destination.parent.path);
          expect(await staged.exists(), isTrue);
          throw FileSystemException('replacement blocked', destination.path);
        },
      );

      await expectLater(
        failingStore.save('same-id', Uint8List.fromList([9, 8, 7, 6])),
        throwsA(isA<FileSystemException>()),
      );

      expect(await store.read('same-id'), originalBytes);
      expect(
        await store.inspect(),
        ScreenshotTranslationImageStats(imageCount: 1, totalBytes: 3),
      );
      final leftovers = await imageDirectory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.pending'))
          .toList();
      expect(leftovers, isEmpty);
    },
  );

  test(
    'failed clear reports the error and leaves the image available to retry',
    () async {
      final bytes = Uint8List.fromList([4, 5, 6]);
      await store.save('retryable-image', bytes);
      final failingStore = FileScreenshotTranslationImageStore(
        imageDirectory,
        deleteImage: (image) async {
          throw FileSystemException('delete blocked', image.path);
        },
      );

      await expectLater(
        failingStore.clearAll(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.read('retryable-image'), bytes);
      expect(
        await store.inspect(),
        ScreenshotTranslationImageStats(imageCount: 1, totalBytes: 3),
      );

      await store.clearAll();
      expect(await store.inspect(), ScreenshotTranslationImageStats.empty);
    },
  );

  test(
    'reports filesystem errors when the storage root cannot be created',
    () async {
      final blocker = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}blocked-root',
      );
      await blocker.writeAsString('not a directory');
      final blockedStore = FileScreenshotTranslationImageStore(
        Directory(blocker.path),
      );

      await expectLater(
        blockedStore.save('valid-id', Uint8List.fromList([1])),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('history deletion waits for a saving image and rejects its later stale write', () async {
    final commitStarted = Completer<void>();
    final releaseCommit = Completer<void>();
    final coordinatedStore = FileScreenshotTranslationImageStore(
      imageDirectory,
      commit: (staged, destination) async {
        commitStarted.complete();
        await releaseCommit.future;
        await staged.rename(destination.path);
      },
    );
    final lease = coordinatedStore.beginImageWrite('delete-race');
    final bytes = Uint8List.fromList([7, 8, 9]);
    final saving = coordinatedStore.saveWithLease('delete-race', bytes, lease);
    await commitStarted.future;

    var historyDeleted = false;
    final deleting = coordinatedStore.deleteImageAndThen(
      'delete-race',
      () async => historyDeleted = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(historyDeleted, isFalse);

    releaseCommit.complete();
    expect(await saving, isTrue);
    await deleting;
    expect(historyDeleted, isTrue);
    expect(await coordinatedStore.read('delete-race'), isNull);
    expect(
      await coordinatedStore.saveWithLease('delete-race', bytes, lease),
      isFalse,
    );
    expect(await coordinatedStore.read('delete-race'), isNull);
  });

  test(
    'a save started after history deletion cannot recreate an orphan image',
    () async {
      final coordinatedStore = FileScreenshotTranslationImageStore(
        imageDirectory,
      );
      // Capture starts and reserves permission before the provider finishes,
      // but its image save does not enter the storage queue yet.
      final captureLease = coordinatedStore.beginImageWrite('deleted-shot');
      var historyDeleted = false;

      await coordinatedStore.deleteImageAndThen('deleted-shot', () async {
        historyDeleted = true;
      });
      expect(historyDeleted, isTrue);

      final saved = await coordinatedStore.saveWithLease(
        'deleted-shot',
        Uint8List.fromList([4, 5, 6]),
        captureLease,
      );

      expect(saved, isFalse);
      expect(await coordinatedStore.read('deleted-shot'), isNull);
      expect(
        await coordinatedStore.inspect(),
        ScreenshotTranslationImageStats.empty,
      );
    },
  );

  test(
    'failed history deletion restores the screenshot image for retry',
    () async {
      final bytes = Uint8List.fromList([4, 5, 6, 7]);
      await store.save('rollback-history-delete', bytes);

      await expectLater(
        store.deleteImageAndThen('rollback-history-delete', () async {
          throw StateError('simulated SQLite delete failure');
        }),
        throwsA(isA<StateError>()),
      );

      expect(await store.read('rollback-history-delete'), bytes);
      expect(
        await store.inspect(),
        ScreenshotTranslationImageStats(
          imageCount: 1,
          totalBytes: bytes.length,
        ),
      );
      final staging = await imageDirectory
          .list(followLinks: false)
          .where((entity) => entity.path.endsWith('.pending'))
          .toList();
      expect(staging, isEmpty);
    },
  );

  test(
    'committed cleanup residue is reported and retried without restoration',
    () async {
      final bytes = Uint8List.fromList([2, 7, 1, 8]);
      await store.save('deleted-history', bytes);
      var failCleanup = true;
      final cleanupFailingStore = FileScreenshotTranslationImageStore(
        imageDirectory,
        deleteImage: (image) async {
          if (image.path.endsWith('.committed') && failCleanup) {
            throw FileSystemException(
              'simulated committed cleanup failure',
              image.path,
            );
          }
          await image.delete();
        },
      );

      await expectLater(
        cleanupFailingStore.deleteImageAndThen('deleted-history', () async {}),
        throwsA(isA<ScreenshotTranslationImageCleanupPendingException>()),
      );
      final backup =
          (await imageDirectory
                      .list(followLinks: false)
                      .where((entity) => entity.path.endsWith('.committed'))
                      .toList())
                  .single
              as File;

      expect(
        await cleanupFailingStore.inspect(),
        ScreenshotTranslationImageStats(
          imageCount: 1,
          totalBytes: bytes.length,
        ),
      );
      expect(
        await FileSystemEntity.type(
          '${imageDirectory.path}${Platform.pathSeparator}deleted-history.png',
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
      expect(await backup.exists(), isTrue);

      failCleanup = false;
      expect(
        await cleanupFailingStore.inspect(),
        ScreenshotTranslationImageStats.empty,
      );
      expect(await backup.exists(), isFalse);
    },
  );

  test('clear waits for earlier writes and admits captures reserved after its barrier', () async {
    final commitStarted = Completer<void>();
    final releaseCommit = Completer<void>();
    final coordinatedStore = FileScreenshotTranslationImageStore(
      imageDirectory,
      commit: (staged, destination) async {
        if (!commitStarted.isCompleted) {
          commitStarted.complete();
          await releaseCommit.future;
        }
        await staged.rename(destination.path);
      },
    );
    final earlierLease = coordinatedStore.beginImageWrite('before-clear');
    final earlierSave = coordinatedStore.saveWithLease(
      'before-clear',
      Uint8List.fromList([1]),
      earlierLease,
    );
    await commitStarted.future;
    final lateOldLease = coordinatedStore.beginImageWrite('late-before-clear');
    final clearing = coordinatedStore.clearAll();
    final afterClearLease = coordinatedStore.beginImageWrite('after-clear');
    final lateOldSave = coordinatedStore.saveWithLease(
      'late-before-clear',
      Uint8List.fromList([2]),
      lateOldLease,
    );
    final afterClearSave = coordinatedStore.saveWithLease(
      'after-clear',
      Uint8List.fromList([3]),
      afterClearLease,
    );

    await Future<void>.delayed(Duration.zero);
    expect(await coordinatedStore.read('before-clear'), isNull);
    releaseCommit.complete();
    expect(await earlierSave, isTrue);
    await clearing;
    expect(await lateOldSave, isFalse);
    expect(await afterClearSave, isTrue);
    expect(await coordinatedStore.read('before-clear'), isNull);
    expect(await coordinatedStore.read('late-before-clear'), isNull);
    expect(await coordinatedStore.read('after-clear'), [3]);
  });
}
