import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/screenshot_translation_image_store.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_archive_controller.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';

void main() {
  test('full retry cache blocks deletion before closing or cancelling the active capture', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-full-cache-delete-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final core = ArchiveFakeCore();
    var imageSaveAttempts = 0;
    final store = FileScreenshotTranslationImageStore(
      directory,
      commit: (staged, destination) async {
        imageSaveAttempts++;
        if (imageSaveAttempts <=
            ScreenshotTranslationRuntime.maxRetryableImageSaveCount) {
          throw const FileSystemException('image write failure');
        }
        await staged.rename(destination.path);
      },
    );
    final providerStarted = Completer<void>();
    final providerResult = Completer<String>();
    var deferProvider = false;
    var cancellations = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => CapturedData(
        width: 1,
        height: 1,
        bytes: Uint8List.fromList([8]),
        left: 0,
      ),
      recognize: (_, [_]) async => 'Hello',
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) {
            core.history.add(
              entry(historyEntryId, screenshotCaptureId: screenshotCaptureId),
            );
            if (deferProvider) {
              providerStarted.complete();
              return providerResult.future;
            }
            return Future.value('译文');
          },
      cancelTranslation: () async {
        cancellations++;
        return true;
      },
      imageStore: store,
    );
    final archive = ScreenshotTranslationArchiveController(
      coreFactory: () => core,
      imageStore: store,
      purgeRetryableImageSave: runtime.purgeRetryableImageSave,
      beforeDeleteHistoryEntry: runtime.deleteHistoryEntry,
      beforeDeleteCaptureImage: runtime.prepareCaptureImageDeletion,
      cancelCaptureImageDeletion: runtime.cancelCaptureImageDeletion,
    );
    addTearDown(runtime.dispose);
    addTearDown(archive.dispose);
    addTearDown(() {
      if (!providerResult.isCompleted) providerResult.complete('译文');
    });
    for (
      var i = 0;
      i < ScreenshotTranslationRuntime.maxRetryableImageSaveCount;
      i++
    ) {
      await runtime.startCapture();
    }
    deferProvider = true;
    final capture = runtime.startCapture();
    await providerStarted.future;
    final before = runtime.session!;
    final row = core.history.last;
    final oldLease = store.beginImageWrite(row.captureId);
    final retainedIds = runtime.retryableImageSaves
        .map((item) => item.captureId)
        .toList();

    await expectLater(
      runtime.deleteHistoryEntry(row.id),
      throwsA(isA<ScreenshotTranslationRetryCacheFullException>()),
    );
    await expectLater(
      runtime.prepareCaptureImageDeletion(row.captureId),
      throwsA(isA<ScreenshotTranslationRetryCacheFullException>()),
    );
    final result = await archive.deleteEntry(row);

    expect(result.historyDeleted, isFalse);
    expect(result.imageDeleted, isFalse);
    expect(result.error, isA<ScreenshotTranslationRetryCacheFullException>());
    expect(runtime.session, same(before));
    expect(runtime.session!.imageBytes, [8]);
    expect(runtime.session!.status, ScreenshotTranslationStatus.translating);
    expect(cancellations, 0);
    expect(core.deletedIds, isEmpty);
    expect(core.history.last, row);
    expect(store.acceptsImageWriteLease(row.captureId, oldLease), isTrue);
    expect(
      runtime.retryableImageSaveCacheCount,
      ScreenshotTranslationRuntime.maxRetryableImageSaveCount,
    );
    expect(
      runtime.retryableImageSaveCacheBytes,
      ScreenshotTranslationRuntime.maxRetryableImageSaveCount,
    );
    expect(
      runtime.retryableImageSaves.map((item) => item.captureId),
      retainedIds,
    );
    expect(await store.read(row.captureId), isNull);
    providerResult.complete('译文');
    await capture;
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.saved,
    );
    expect(await store.read(row.captureId), [8]);

    final savedImageDeletion = await archive.deleteEntry(row);
    expect(savedImageDeletion.historyDeleted, isTrue);
    expect(savedImageDeletion.imageDeleted, isTrue);
    expect(await store.read(row.captureId), isNull);
  });
  test('history rollback retains pixels when deletion closes the session before its first image save', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-history-before-image-save-rollback-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final core = ArchiveFakeCore()..failNextHistoryDelete = true;
    final store = FileScreenshotTranslationImageStore(directory);
    final historyCommitted = Completer<void>();
    final providerResult = Completer<String>();
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => CapturedData(
        width: 1,
        height: 1,
        bytes: Uint8List.fromList([6, 7]),
        left: 0,
      ),
      recognize: (_, [_]) async => 'Hello',
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) {
            // Model the service's history commit preceding its returned Future.
            core.history.add(
              entry(historyEntryId, screenshotCaptureId: screenshotCaptureId),
            );
            historyCommitted.complete();
            return providerResult.future;
          },
      imageStore: store,
    );
    final archive = ScreenshotTranslationArchiveController(
      coreFactory: () => core,
      imageStore: store,
      purgeRetryableImageSave: runtime.purgeRetryableImageSave,
      beforeDeleteHistoryEntry: runtime.deleteHistoryEntry,
      beforeDeleteCaptureImage: runtime.prepareCaptureImageDeletion,
      cancelCaptureImageDeletion: runtime.cancelCaptureImageDeletion,
    );
    addTearDown(runtime.dispose);
    addTearDown(archive.dispose);
    final capture = runtime.startCapture();
    await historyCommitted.future;
    final row = core.history.single;
    final oldLease = store.beginImageWrite(row.captureId);
    expect(runtime.retryableImageSaveCacheCount, 0);
    final sessionClosed = Completer<void>();
    runtime.addListener(() {
      if (runtime.session == null && !sessionClosed.isCompleted) {
        sessionClosed.complete();
      }
    });
    final deletion = archive.deleteEntry(row);
    await sessionClosed.future;
    final bytesAtClose = runtime.retryableImageSaveCacheBytes;
    // Release the provider after deletion has already invalidated the
    // session revision, so _translate cannot start its first image save.
    providerResult.complete('译文');
    await capture;
    final result = await deletion;

    expect(result.historyDeleted, isFalse);
    expect(core.history.single, row);
    expect(bytesAtClose, 2);
    expect(runtime.retryableImageSaveCacheBytes, 2);
    expect(store.acceptsImageWriteLease(row.captureId, oldLease), isFalse);
    expect(await store.read(row.captureId), isNull);
    expect(await runtime.retryImageSave(captureId: row.captureId), isTrue);
    expect(await store.read(row.captureId), [6, 7]);
  });
  for (final batch in [false, true]) {
    for (final stagingFailure in [false, true]) {
      test(
        '${batch ? 'batch' : 'single'} deletion preserves retry pixels and permits a fresh lease after ${stagingFailure ? 'staging' : 'history'} failure',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'yixue-delete-retry-rollback-',
          );
          addTearDown(() async {
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          });
          var failSave = true;
          final imageStore = FileScreenshotTranslationImageStore(
            directory,
            commit: (staged, destination) async {
              if (failSave) {
                throw const FileSystemException('initial image write failure');
              }
              await staged.rename(destination.path);
            },
          );
          final core = ArchiveFakeCore();
          final runtime = ScreenshotTranslationRuntime(
            capture: () async => CapturedData(
              width: 1,
              height: 1,
              bytes: Uint8List.fromList([7]),
              left: 0,
            ),
            recognize: (_, [_]) async => 'Hello',
            translate:
                (
                  source,
                  direction, {
                  required origin,
                  required historyEntryId,
                  required screenshotCaptureId,
                }) async {
                  core.history.add(
                    entry(
                      historyEntryId,
                      screenshotCaptureId: screenshotCaptureId,
                    ),
                  );
                  return '译文';
                },
            imageStore: imageStore,
          );
          final controller = ScreenshotTranslationArchiveController(
            coreFactory: () => core,
            imageStore: imageStore,
            purgeRetryableImageSave: runtime.purgeRetryableImageSave,
            beforeDeleteHistoryEntry: runtime.deleteHistoryEntry,
            beforeDeleteCaptureImage: runtime.prepareCaptureImageDeletion,
            cancelCaptureImageDeletion: runtime.cancelCaptureImageDeletion,
          );
          addTearDown(runtime.dispose);
          addTearDown(controller.dispose);
          await runtime.startCapture();
          final first = core.history.single;
          final captureId = first.captureId;
          final oldLease = imageStore.beginImageWrite(captureId);
          final selected = [first];
          if (batch) {
            final second = entry('zzz-batch-second');
            core.history.add(second);
            selected.add(second);
          }
          if (stagingFailure) {
            final blockedId = batch ? selected.last.captureId : captureId;
            await Directory('${directory.path}/$blockedId.png').create();
          } else {
            core.failNextHistoryDelete = true;
          }

          if (batch) {
            await expectLater(
              controller.deleteSelectedHistoryEntries(
                selected,
                deleteHistory: (ids) async =>
                    core.deleteTranslationHistory(ids),
              ),
              throwsA(isA<Object>()),
            );
          } else {
            final result = await controller.deleteEntry(first);
            expect(result.historyDeleted, isFalse);
          }

          expect(core.history, selected);
          expect(runtime.retryableImageSaveCacheBytes, 1);
          expect(runtime.retryableImageSaves.single.captureId, captureId);
          expect(
            imageStore.acceptsImageWriteLease(captureId, oldLease),
            isFalse,
          );
          expect(
            imageStore.acceptsImageWriteLease(
              captureId,
              imageStore.beginImageWrite(captureId),
            ),
            isTrue,
          );
          if (stagingFailure) {
            final blockedId = batch ? selected.last.captureId : captureId;
            await Directory('${directory.path}/$blockedId.png').delete();
          }
          failSave = false;
          expect(await runtime.retryImageSave(captureId: captureId), isTrue);
          expect(await imageStore.read(captureId), [7]);
        },
      );
    }
  }
  test(
    'image store factory uses app data and leaves missing paths memory-only',
    () {
      final store = screenshotTranslationImageStoreForAppDataDirectory(
        r'C:\app data\yixue',
      );

      expect(store, isA<FileScreenshotTranslationImageStore>());
      expect(
        (store! as FileScreenshotTranslationImageStore).rootDirectory.path,
        Directory(r'C:\app data\yixue').uri
            .resolve('screenshot_translation')
            .toFilePath(),
      );
      expect(screenshotTranslationImageStoreForAppDataDirectory(null), isNull);
      expect(screenshotTranslationImageStoreForAppDataDirectory('  '), isNull);
    },
  );

  for (final completesAfterRollback in [false, true]) {
    test(
      'late retry ${completesAfterRollback ? 'after' : 'during'} failed deletion preserves pixels for a new lease',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'yixue-inflight-delete-rollback-',
        );
        addTearDown(() async {
          if (await directory.exists()) await directory.delete(recursive: true);
        });
        var failSave = true;
        final backingStore = FileScreenshotTranslationImageStore(
          directory,
          commit: (staged, destination) async {
            if (failSave) {
              throw const FileSystemException('initial image write failure');
            }
            await staged.rename(destination.path);
          },
        );
        final imageStore = _DeferredBatchImageStore(backingStore);
        final core = ArchiveFakeCore();
        final runtime = ScreenshotTranslationRuntime(
          capture: () async => CapturedData(
            width: 1,
            height: 1,
            bytes: Uint8List.fromList([4, 5]),
            left: 0,
          ),
          recognize: (_, [_]) async => 'Hello',
          translate:
              (
                source,
                direction, {
                required origin,
                required historyEntryId,
                required screenshotCaptureId,
              }) async {
                core.history.add(
                  entry(
                    historyEntryId,
                    screenshotCaptureId: screenshotCaptureId,
                  ),
                );
                return '译文';
              },
          imageStore: imageStore,
        );
        final controller = ScreenshotTranslationArchiveController(
          coreFactory: () => core,
          imageStore: imageStore,
          purgeRetryableImageSave: runtime.purgeRetryableImageSave,
          beforeDeleteHistoryEntry: runtime.deleteHistoryEntry,
          beforeDeleteCaptureImage: runtime.prepareCaptureImageDeletion,
          cancelCaptureImageDeletion: runtime.cancelCaptureImageDeletion,
        );
        addTearDown(runtime.dispose);
        addTearDown(controller.dispose);
        await runtime.startCapture();
        final history = core.history.single;
        failSave = false;
        imageStore.deferNextSave = true;
        final retry = runtime.retryImageSave(captureId: history.captureId);
        await imageStore.saveStarted.future;
        final historyStarted = Completer<void>();
        final releaseHistory = Completer<void>();
        final deletion = controller.deleteSelectedHistoryEntries(
          [history],
          deleteHistory: (_) async {
            historyStarted.complete();
            await releaseHistory.future;
            throw StateError('history transaction failed');
          },
        );
        final failed = expectLater(deletion, throwsStateError);
        await historyStarted.future;
        expect(
          await runtime.retryImageSave(captureId: history.captureId),
          isFalse,
        );
        if (completesAfterRollback) {
          releaseHistory.complete();
          await failed;
        }
        imageStore.releaseSave.complete();
        expect(await retry, isFalse);
        expect(runtime.retryableImageSaveCacheBytes, 2);
        if (!completesAfterRollback) {
          releaseHistory.complete();
          await failed;
        }
        expect(core.history.single, history);
        expect(
          await runtime.retryImageSave(captureId: history.captureId),
          isTrue,
        );
        expect(await backingStore.read(history.captureId), [4, 5]);
      },
    );
  }

  test(
    'loads screenshot-only pages with search text and advances the offset',
    () async {
      final core = ArchiveFakeCore()
        ..pages = [
          [entry('shot-1'), entry('shot-2')],
          [entry('shot-3')],
        ];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: MemoryArchiveImageStore(),
        pageSize: 2,
      );

      await controller.search('  api error  ');
      await controller.loadNextPage();

      expect(core.pageCalls, [
        (
          limit: 2,
          offset: 0,
          origin: 'screenshot_translation',
          query: 'api error',
        ),
        (
          limit: 2,
          offset: 2,
          origin: 'screenshot_translation',
          query: 'api error',
        ),
      ]);
      expect(controller.entries.map((row) => row.id), [
        'shot-1',
        'shot-2',
        'shot-3',
      ]);
      expect(controller.hasMore, isFalse);
    },
  );

  test(
    'a reentrant new search supersedes old results and releases loading state',
    () async {
      final core = ArchiveFakeCore()
        ..pages = [
          [entry('new-result')],
          [entry('stale-result')],
        ];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: MemoryArchiveImageStore(),
      );
      var launchedNewSearch = false;
      Future<void>? newSearch;
      controller.addListener(() {
        if (controller.isLoading && !launchedNewSearch) {
          launchedNewSearch = true;
          newSearch = controller.search('new query');
        }
      });

      await controller.search('old query');
      await newSearch;

      expect(core.pageCalls.map((call) => call.query), [
        'new query',
        'old query',
      ]);
      expect(controller.entries.map((row) => row.id), ['new-result']);
      expect(controller.query, 'new query');
      expect(controller.isLoading, isFalse);
    },
  );

  test(
    'reads associated screenshot bytes and reports image storage size',
    () async {
      final imageStore = MemoryArchiveImageStore()
        ..images['capture-1'] = Uint8List.fromList([4, 5, 6]);
      final screenshotEntry = entry('shot-1', screenshotCaptureId: 'capture-1');
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: ArchiveFakeCore.new,
        imageStore: imageStore,
      )..entries = [screenshotEntry];

      expect(await controller.readImage(screenshotEntry), [4, 5, 6]);
      expect(
        await controller.inspectImages(),
        const ScreenshotTranslationImageStats(imageCount: 1, totalBytes: 3),
      );
      expect(
        () =>
            controller.readImage(entry('quick-1', origin: 'quick_translation')),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'does not serve an image for a history row no longer in the archive',
    () async {
      final imageStore = MemoryArchiveImageStore()
        ..images['shot-1'] = Uint8List.fromList([4, 5, 6]);
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: ArchiveFakeCore.new,
        imageStore: imageStore,
      );

      expect(await controller.readImage(entry('shot-1')), isNull);
    },
  );

  test('deletes image before screenshot text history', () async {
    final order = <String>[];
    final imageStore = MemoryArchiveImageStore(order: order)
      ..images['shot-1'] = Uint8List.fromList([1, 2, 3]);
    final core = ArchiveFakeCore(order: order)..history = [entry('shot-1')];
    var coreFactoryCalls = 0;
    final controller = ScreenshotTranslationArchiveController(
      coreFactory: () {
        coreFactoryCalls++;
        return core;
      },
      imageStore: imageStore,
    );

    final result = await controller.deleteEntry(entry('shot-1'));

    expect(order, ['image:shot-1', 'history:shot-1']);
    expect(result.imageDeleted, isTrue);
    expect(result.historyDeleted, isTrue);
    expect(imageStore.images, isEmpty);
    expect(controller.imageStats, ScreenshotTranslationImageStats.empty);
    expect(coreFactoryCalls, 1);
  });

  test(
    'deleting one translation version keeps the shared capture image',
    () async {
      final imageStore = MemoryArchiveImageStore()
        ..images['capture-shared'] = Uint8List.fromList([1, 2, 3]);
      final first = entry('capture-shared');
      final second = entry(
        'capture-shared-v1',
        screenshotCaptureId: 'capture-shared',
      );
      final core = ArchiveFakeCore()..history = [first, second];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );

      final result = await controller.deleteEntry(first);

      expect(result.historyDeleted, isTrue);
      expect(result.imageDeleted, isFalse);
      expect(imageStore.images.keys, ['capture-shared']);
      expect(core.history.map((row) => row.id), ['capture-shared-v1']);
    },
  );

  test('serializes version deletion across archive controllers sharing an image store', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-archive-shared-delete-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final firstImageStore = FileScreenshotTranslationImageStore(directory);
    final secondImageStore = FileScreenshotTranslationImageStore(directory);
    await firstImageStore.save('capture-shared', Uint8List.fromList([1, 2]));

    final first = entry(
      'capture-shared',
      screenshotCaptureId: 'capture-shared',
    );
    final second = entry(
      'capture-shared-v1',
      screenshotCaptureId: 'capture-shared',
    );
    final core = ArchiveFakeCore()..history = [first, second];
    final firstDeleteEntered = Completer<void>();
    final allowFirstDeleteToContinue = Completer<void>();
    var secondDeleteEntered = false;
    final firstController = ScreenshotTranslationArchiveController(
      coreFactory: () => core,
      imageStore: firstImageStore,
      beforeDeleteHistoryEntry: (id) async {
        if (id == first.id) {
          firstDeleteEntered.complete();
          await allowFirstDeleteToContinue.future;
        }
      },
    );
    final secondController = ScreenshotTranslationArchiveController(
      coreFactory: () => core,
      imageStore: secondImageStore,
      beforeDeleteHistoryEntry: (id) async {
        if (id == second.id) secondDeleteEntered = true;
      },
    );

    final firstDelete = firstController.deleteEntry(first);
    await firstDeleteEntered.future;
    final secondDelete = secondController.deleteEntry(second);
    await Future<void>.delayed(Duration.zero);
    expect(secondDeleteEntered, isFalse);

    allowFirstDeleteToContinue.complete();
    final results = await Future.wait([firstDelete, secondDelete]);

    expect(results.every((result) => result.historyDeleted), isTrue);
    expect(secondDeleteEntered, isTrue);
    expect(core.history, isEmpty);
    expect(await secondImageStore.read('capture-shared'), isNull);
    firstController.dispose();
    secondController.dispose();
  });

  test('deleting the full version group removes one shared image', () async {
    final imageStore = MemoryArchiveImageStore()
      ..images['capture-shared'] = Uint8List.fromList([1, 2, 3]);
    final rows = [
      entry('capture-shared'),
      entry('capture-shared-v1', screenshotCaptureId: 'capture-shared'),
    ];
    final core = ArchiveFakeCore()..history = rows.toList();
    final controller = ScreenshotTranslationArchiveController(
      coreFactory: () => core,
      imageStore: imageStore,
    );

    await controller.deleteSelectedHistoryEntries(
      rows,
      deleteHistory: (ids) async => core.deleteTranslationHistory(ids),
    );

    expect(imageStore.images, isEmpty);
    expect(core.history, isEmpty);
    expect(core.deletedIds, ['capture-shared', 'capture-shared-v1']);
  });

  test(
    'uses exact screenshot history lookup before deleting an image',
    () async {
      final imageStore = MemoryArchiveImageStore()
        ..images['shot-1'] = Uint8List.fromList([1, 2, 3]);
      final core = ArchiveFakeCore()
        ..history = [entry('shot-1', sourceText: 'current OCR text')];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );

      final result = await controller.deleteEntry(
        entry('shot-1', sourceText: 'stale OCR text'),
      );

      expect(result.historyDeleted, isFalse);
      expect(result.imageDeleted, isFalse);
      expect(imageStore.images, contains('shot-1'));
      expect(core.validationCalls, [
        (id: 'shot-1', sourceText: 'stale OCR text'),
      ]);
      expect(core.pageCalls, isEmpty);
    },
  );

  test(
    'falls back to paged validation only for an older native command',
    () async {
      final core = ArchiveFakeCore()
        ..history = [entry('shot-legacy')]
        ..validationErrorCode = 'unknown_command';
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: MemoryArchiveImageStore(),
      );

      final result = await controller.deleteEntry(entry('shot-legacy'));

      expect(result.historyDeleted, isTrue);
      expect(core.pageCalls.single.query, 'Hello');
      expect(core.deletedIds, ['shot-legacy']);
    },
  );

  test(
    'does not fall back when exact history validation reports another error',
    () async {
      final imageStore = MemoryArchiveImageStore()
        ..images['shot-1'] = Uint8List.fromList([1]);
      final core = ArchiveFakeCore()
        ..history = [entry('shot-1')]
        ..validationErrorCode = 'storage_error';
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );

      final result = await controller.deleteEntry(entry('shot-1'));

      expect(result.historyDeleted, isFalse);
      expect(imageStore.images.containsKey('shot-1'), isTrue);
      expect(core.pageCalls, isEmpty);
      expect(core.deletedIds, isEmpty);
    },
  );

  test(
    'generic selected history deletion commits rows after its first image',
    () async {
      final order = <String>[];
      final imageStore = CoordinatedArchiveImageStore(order: order)
        ..images['shot-1'] = Uint8List.fromList([1])
        ..images['shot-2'] = Uint8List.fromList([2]);
      final rows = [
        entry('shot-1'),
        entry('quick-1', origin: 'quick_translation'),
        entry('shot-2'),
      ];
      final core = ArchiveFakeCore(order: order)..history = rows.toList();
      var coreFactoryCalls = 0;
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () {
          coreFactoryCalls++;
          return core;
        },
        imageStore: imageStore,
      );

      await controller.deleteSelectedHistoryEntries(
        rows,
        deleteHistory: (ids) async {
          core.deleteTranslationHistory(ids);
        },
      );

      expect(order, [
        'coordinated:shot-1',
        'image:shot-1',
        'history:shot-1,quick-1,shot-2',
        'coordinated:shot-2',
        'image:shot-2',
      ]);
      expect(core.deletedIds, ['shot-1', 'quick-1', 'shot-2']);
      expect(core.history, isEmpty);
      expect(imageStore.images, isEmpty);
      expect(coreFactoryCalls, 1);
      expect(core.validationCalls, [
        (id: 'shot-1', sourceText: 'Hello'),
        (id: 'shot-2', sourceText: 'Hello'),
      ]);
    },
  );

  test(
    'batch staging failure restores images and keeps history intact',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-batch-cleanup-pending-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      var failSecondImageDelete = true;
      final imageStore = FileScreenshotTranslationImageStore(
        directory,
        deleteImage: (image) async {
          if (image.path.endsWith('shot-2.png') && failSecondImageDelete) {
            throw FileSystemException(
              'simulated second screenshot delete failure',
              image.path,
            );
          }
          await image.delete();
        },
      );
      await imageStore.save('shot-1', Uint8List.fromList([1]));
      await imageStore.save('shot-2', Uint8List.fromList([2, 3]));
      final rows = [entry('shot-1'), entry('shot-2')];
      final core = ArchiveFakeCore()..history = rows.toList();
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );
      addTearDown(controller.dispose);

      await expectLater(
        controller.deleteSelectedHistoryEntries(
          rows,
          deleteHistory: (ids) async => core.deleteTranslationHistory(ids),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(controller.lastDeleteResult?.historyDeleted, isFalse);
      expect(controller.lastDeleteResult?.imageCleanupPending, isFalse);
      expect(core.history, rows);
      expect(core.deletedIds, isEmpty);
      expect(await imageStore.read('shot-1'), Uint8List.fromList([1]));
      expect(await imageStore.read('shot-2'), Uint8List.fromList([2, 3]));

      failSecondImageDelete = false;
      expect(
        await imageStore.inspect(),
        const ScreenshotTranslationImageStats(imageCount: 2, totalBytes: 3),
      );
    },
  );

  test(
    'batch delete clears pending status when inspection retry succeeds',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-batch-cleanup-retry-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      var failCleanupOnce = true;
      final imageStore = FileScreenshotTranslationImageStore(
        directory,
        deleteImage: (image) async {
          if (image.path.endsWith('.committed') && failCleanupOnce) {
            failCleanupOnce = false;
            throw FileSystemException(
              'simulated transient screenshot cleanup failure',
              image.path,
            );
          }
          await image.delete();
        },
      );
      await imageStore.save('shot-1', Uint8List.fromList([1]));
      await imageStore.save('shot-2', Uint8List.fromList([2]));
      final rows = [entry('shot-1'), entry('shot-2')];
      final core = ArchiveFakeCore()..history = rows.toList();
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );
      addTearDown(controller.dispose);

      await controller.deleteSelectedHistoryEntries(
        rows,
        deleteHistory: (ids) async => core.deleteTranslationHistory(ids),
      );

      expect(controller.lastDeleteResult?.historyDeleted, isTrue);
      expect(controller.lastDeleteResult?.imageCleanupPending, isFalse);
      expect(controller.lastDeleteResult?.imageDeleted, isTrue);
      expect(controller.imageStats, ScreenshotTranslationImageStats.empty);
    },
  );

  test(
    'mixed history deletion adjusts archive paging by rows actually loaded',
    () async {
      final history = List.generate(6, (index) => entry('shot-$index'));
      final core = ArchiveFakeCore()..history = history.toList();
      final controller =
          ScreenshotTranslationArchiveController(
              coreFactory: () => core,
              imageStore: MemoryArchiveImageStore(),
              pageSize: 2,
            )
            ..entries = history.take(4).toList()
            ..offset = 4;

      await controller.deleteSelectedHistoryEntries([
        history.first,
        history.last,
      ], deleteHistory: (ids) async => core.deleteTranslationHistory(ids));

      expect(controller.entries.map((row) => row.id), [
        'shot-1',
        'shot-2',
        'shot-3',
      ]);
      expect(controller.offset, 3);

      await controller.loadNextPage();

      expect(core.pageCalls.last.offset, 3);
      expect(controller.entries.map((row) => row.id), [
        'shot-1',
        'shot-2',
        'shot-3',
        'shot-4',
      ]);
    },
  );

  test('deleting a loaded row below the archive cap reopens paging', () async {
    final loaded = entry('shot-loaded');
    final unlisted = entry('shot-unlisted');
    final core = ArchiveFakeCore()..history = [loaded, unlisted];
    final controller =
        ScreenshotTranslationArchiveController(
            coreFactory: () => core,
            imageStore: MemoryArchiveImageStore(),
          )
          ..entries = [loaded]
          ..offset = 5000
          ..hasMore = false
          ..isCapped = true;

    await controller.deleteSelectedHistoryEntries([
      loaded,
      unlisted,
    ], deleteHistory: (ids) async => core.deleteTranslationHistory(ids));

    expect(controller.offset, 4999);
    expect(controller.isCapped, isFalse);
    expect(controller.hasMore, isTrue);
  });

  test(
    'deleting an image purges its retry snapshot bytes from the runtime',
    () async {
      final runtime = _runtimeWithFailedImageSave();
      await runtime.startCapture();
      final historyId = runtime.session!.id;
      expect(runtime.retryableImageSaveCacheBytes, 1);

      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => ArchiveFakeCore()..history = [entry(historyId)],
        imageStore: MemoryArchiveImageStore(),
        purgeRetryableImageSave: runtime.purgeRetryableImageSave,
      );

      final result = await controller.deleteEntry(entry(historyId));

      expect(result.historyDeleted, isTrue);
      expect(runtime.retryableImageSaveCacheCount, 0);
      expect(runtime.retryableImageSaveCacheBytes, 0);
      expect(runtime.retryableImageSaves, isEmpty);
      runtime.dispose();
    },
  );

  test('image deletion failure leaves the history row intact', () async {
    final order = <String>[];
    final imageStore = MemoryArchiveImageStore(order: order)..failDelete = true;
    final core = ArchiveFakeCore(order: order)..history = [entry('shot-1')];
    final controller = ScreenshotTranslationArchiveController(
      coreFactory: () => core,
      imageStore: imageStore,
    );

    final result = await controller.deleteEntry(entry('shot-1'));

    expect(result.imageDeleted, isFalse);
    expect(result.historyDeleted, isFalse);
    expect(result.error, isNotNull);
    expect(order, ['image:shot-1']);
    expect(core.deletedIds, isEmpty);
  });

  test(
    'image deletion failure preserves retry bytes while history remains',
    () async {
      final runtime = _runtimeWithFailedImageSave();
      await runtime.startCapture();
      final historyId = runtime.session!.id;
      expect(runtime.retryableImageSaveCacheBytes, 1);
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.failed,
      );

      final imageStore = MemoryArchiveImageStore()..failDelete = true;
      final core = ArchiveFakeCore()..history = [entry(historyId)];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
        purgeRetryableImageSave: runtime.purgeRetryableImageSave,
      );

      final result = await controller.deleteEntry(entry(historyId));
      await runtime.retryImageSave(historyEntryId: historyId);

      expect(result.imageDeleted, isFalse);
      expect(result.historyDeleted, isFalse);
      expect(runtime.retryableImageSaveCacheCount, 1);
      expect(runtime.retryableImageSaveCacheBytes, 1);
      expect(runtime.retryableImageSaves.single.captureId, historyId);
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.failed,
      );
      runtime.dispose();
    },
  );

  test(
    'history delete failure reports already-deleted image and retry is safe',
    () async {
      final order = <String>[];
      final imageStore = MemoryArchiveImageStore(order: order);
      final core = ArchiveFakeCore(order: order)
        ..history = [entry('shot-1')]
        ..failNextHistoryDelete = true;
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );

      final first = await controller.deleteEntry(entry('shot-1'));
      final retry = await controller.deleteEntry(entry('shot-1'));

      expect(first.imageDeleted, isTrue);
      expect(first.historyDeleted, isFalse);
      expect(first.error, isNotNull);
      expect(retry.imageDeleted, isTrue);
      expect(retry.historyDeleted, isTrue);
      expect(order, [
        'image:shot-1',
        'history:shot-1',
        'image:shot-1',
        'history:shot-1',
      ]);
    },
  );

  test(
    'file archive restores its screenshot when history deletion fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-history-rollback-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final imageStore = FileScreenshotTranslationImageStore(directory);
      final bytes = Uint8List.fromList([7, 8, 9]);
      await imageStore.save('shot-1', bytes);
      final core = ArchiveFakeCore()
        ..history = [entry('shot-1')]
        ..failNextHistoryDelete = true;
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );

      final result = await controller.deleteEntry(entry('shot-1'));

      expect(result.imageDeleted, isFalse);
      expect(result.historyDeleted, isFalse);
      expect(core.history.map((row) => row.id), ['shot-1']);
      expect(await imageStore.read('shot-1'), bytes);
      controller.dispose();
    },
  );

  test(
    'file archive reports committed history when image cleanup is pending',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-image-cleanup-pending-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      var failCleanup = true;
      final imageStore = FileScreenshotTranslationImageStore(
        directory,
        deleteImage: (image) async {
          if (image.path.endsWith('.committed') && failCleanup) {
            throw FileSystemException(
              'simulated screenshot cleanup failure',
              image.path,
            );
          }
          await image.delete();
        },
      );
      final bytes = Uint8List.fromList([7, 8, 9]);
      await imageStore.save('shot-1', bytes);
      final historyEntry = entry('shot-1');
      final core = ArchiveFakeCore()..history = [historyEntry];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );
      addTearDown(controller.dispose);

      final result = await controller.deleteEntry(historyEntry);

      expect(result.historyDeleted, isTrue);
      expect(result.imageCleanupPending, isTrue);
      expect(result.imageDeleted, isFalse);
      expect(core.history, isEmpty);
      expect(controller.entries, isEmpty);
      expect(
        controller.imageStats,
        ScreenshotTranslationImageStats(
          imageCount: 1,
          totalBytes: bytes.length,
        ),
      );
      expect(await controller.readImage(historyEntry), isNull);

      failCleanup = false;
      expect(
        await controller.inspectImages(),
        ScreenshotTranslationImageStats.empty,
      );
    },
  );

  test(
    'single delete clears pending status when the inspect retry succeeds',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-image-cleanup-retry-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      var failCleanupOnce = true;
      final imageStore = FileScreenshotTranslationImageStore(
        directory,
        deleteImage: (image) async {
          if (image.path.endsWith('.committed') && failCleanupOnce) {
            failCleanupOnce = false;
            throw FileSystemException(
              'simulated transient screenshot cleanup failure',
              image.path,
            );
          }
          await image.delete();
        },
      );
      await imageStore.save('shot-retry', Uint8List.fromList([3, 2, 1]));
      final historyEntry = entry('shot-retry');
      final core = ArchiveFakeCore()..history = [historyEntry];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );
      addTearDown(controller.dispose);

      final result = await controller.deleteEntry(historyEntry);

      expect(result.historyDeleted, isTrue);
      expect(result.imageCleanupPending, isFalse);
      expect(result.imageDeleted, isTrue);
      expect(controller.imageStats, ScreenshotTranslationImageStats.empty);
    },
  );

  test(
    'batch delete stages all screenshot images before history commit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-batch-delete-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final imageStore = FileScreenshotTranslationImageStore(directory);
      await imageStore.save('shot-batch-a', Uint8List.fromList([1, 2]));
      await imageStore.save('shot-batch-b', Uint8List.fromList([3, 4, 5]));
      final first = entry('shot-batch-a');
      final second = entry('shot-batch-b');
      final core = ArchiveFakeCore()..history = [first, second];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );
      addTearDown(controller.dispose);

      await controller.deleteSelectedHistoryEntries(
        [first, second],
        deleteHistory: (ids) async {
          expect(ids, ['shot-batch-a', 'shot-batch-b']);
          expect(
            await File('${directory.path}/shot-batch-a.png').exists(),
            isFalse,
          );
          expect(
            await File('${directory.path}/shot-batch-b.png').exists(),
            isFalse,
          );
          expect(
            (await directory
                .list(followLinks: false)
                .where((entity) => entity.path.endsWith('.rollback'))
                .toList()),
            hasLength(2),
          );
          core.deleteTranslationHistory(ids);
        },
      );

      expect(core.history, isEmpty);
      expect(controller.lastDeleteResult?.historyDeleted, isTrue);
      expect(await imageStore.inspect(), ScreenshotTranslationImageStats.empty);
    },
  );

  test(
    'recovery reconciles marked backups against live screenshot history',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-deletion-recovery-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final imageStore = FileScreenshotTranslationImageStore(directory);
      final retainedBackup = File(
        '${directory.path}/retained.png.88-999-1.rollback',
      );
      final deletedBackup = File(
        '${directory.path}/deleted.png.88-999-2.rollback',
      );
      final retainedBytes = Uint8List.fromList([7, 8, 9]);
      final deletedBytes = Uint8List.fromList([1, 3, 5]);
      await retainedBackup.writeAsBytes(retainedBytes);
      await deletedBackup.writeAsBytes(deletedBytes);
      final core = ArchiveFakeCore()..history = [entry('retained')];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );
      addTearDown(controller.dispose);

      await controller.recoverPendingImageDeletions();

      expect(await imageStore.read('retained'), retainedBytes);
      expect(await File('${directory.path}/deleted.png').exists(), isFalse);
      expect(await deletedBackup.exists(), isFalse);
    },
  );

  test(
    'recovery preserves rollback markers when the native lookup is unavailable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-legacy-bridge-recovery-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final imageStore = FileScreenshotTranslationImageStore(directory);
      final backup = File('${directory.path}/deleted.png.88-999-3.rollback');
      await backup.writeAsBytes(Uint8List.fromList([4, 5, 6]));
      final core = ArchiveFakeCore()
        ..referenceLookupErrorCode = 'unknown_command';
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );
      addTearDown(controller.dispose);

      await controller.recoverPendingImageDeletions();

      expect(await backup.exists(), isTrue);
      expect(await File('${directory.path}/deleted.png').exists(), isFalse);

      core.referenceLookupErrorCode = null;
      await controller.recoverPendingImageDeletions();

      expect(await backup.exists(), isFalse);
      expect(await File('${directory.path}/deleted.png').exists(), isFalse);
    },
  );

  test('recovery splits reference lookups into native-size batches', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-archive-reference-batches-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final imageStore = FileScreenshotTranslationImageStore(directory);
    final ids = List<String>.generate(
      501,
      (index) => 'batch-recovery-${index.toString().padLeft(3, '0')}',
      growable: false,
    );
    for (var index = 0; index < ids.length; index++) {
      await File('${directory.path}/${ids[index]}.png.88-999-$index.rollback')
          .writeAsBytes([index % 255]);
    }
    final core = ArchiveFakeCore()
      ..history = ids.map((id) => entry(id)).toList(growable: false);
    final controller = ScreenshotTranslationArchiveController(
      coreFactory: () => core,
      imageStore: imageStore,
    );
    addTearDown(controller.dispose);

    await controller.recoverPendingImageDeletions();

    expect(core.referenceBatchSizes, [500, 1]);
    expect(await imageStore.read(ids.first), [0]);
    expect(
      (await directory.list(followLinks: false).toList()).where(
        (entity) => entity.path.endsWith('.rollback'),
      ),
      isEmpty,
    );
  });

  test(
    'history deletion failure preserves retry bytes while history remains',
    () async {
      final runtime = _runtimeWithFailedImageSave();
      await runtime.startCapture();
      final historyId = runtime.session!.id;
      expect(runtime.retryableImageSaveCacheBytes, 1);

      final core = ArchiveFakeCore()
        ..history = [entry(historyId)]
        ..failNextHistoryDelete = true;
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: MemoryArchiveImageStore(),
        purgeRetryableImageSave: runtime.purgeRetryableImageSave,
      );

      final result = await controller.deleteEntry(entry(historyId));
      await runtime.retryImageSave(historyEntryId: historyId);

      expect(result.imageDeleted, isTrue);
      expect(result.historyDeleted, isFalse);
      expect(runtime.retryableImageSaveCacheCount, 1);
      expect(runtime.retryableImageSaveCacheBytes, 1);
      expect(runtime.retryableImageSaves.single.captureId, historyId);
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.failed,
      );
      runtime.dispose();
    },
  );

  test(
    'does not delete a quick-translation row with a forged screenshot origin',
    () async {
      final order = <String>[];
      final imageStore = MemoryArchiveImageStore(order: order)
        ..images['shared-id'] = Uint8List.fromList([8]);
      final core = ArchiveFakeCore(order: order)
        ..history = [entry('shared-id', origin: 'quick_translation')];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: imageStore,
      );

      final result = await controller.deleteEntry(entry('shared-id'));

      expect(result.imageDeleted, isFalse);
      expect(result.historyDeleted, isFalse);
      expect(result.error, isNotNull);
      expect(order, isEmpty);
      expect(imageStore.images.keys, ['shared-id']);
      expect(core.deletedIds, isEmpty);
    },
  );

  test(
    'stops at the native history offset cap and exposes capped state',
    () async {
      final core = ArchiveFakeCore()
        ..history = List.generate(5600, (index) => entry('shot-$index'));
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: MemoryArchiveImageStore(),
        pageSize: 500,
      );

      await controller.loadFirstPage();
      while (controller.hasMore) {
        await controller.loadNextPage();
      }

      expect(controller.isCapped, isTrue);
      expect(controller.hasMore, isFalse);
      expect(controller.offset, 5500);
      expect(core.pageCalls.map((call) => call.offset), [
        0,
        500,
        1000,
        1500,
        2000,
        2500,
        3000,
        3500,
        4000,
        4500,
        5000,
      ]);
      expect(core.pageCalls.every((call) => call.offset <= 5000), isTrue);
    },
  );

  test(
    'a page size that does not divide the native cap never repeats rows',
    () async {
      final core = ArchiveFakeCore()
        ..history = List.generate(5200, (index) => entry('shot-$index'));
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: MemoryArchiveImageStore(),
        pageSize: 30,
      );

      await controller.loadFirstPage();
      while (controller.hasMore) {
        await controller.loadNextPage();
      }

      final ids = controller.entries.map((row) => row.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.length, 5030);
      expect(core.pageCalls.last.offset, 5000);
      expect(core.pageCalls.every((call) => call.offset <= 5000), isTrue);
      expect(controller.isCapped, isTrue);
    },
  );

  test(
    'controller disposal during image clearing does not notify afterward',
    () async {
      final imageStore = MemoryArchiveImageStore()
        ..clearGate = Completer<void>();
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: ArchiveFakeCore.new,
        imageStore: imageStore,
      );

      final clearing = controller.clearAllImages();
      controller.dispose();
      imageStore.clearGate!.complete();

      await expectLater(clearing, completes);
    },
  );

  test(
    'archive deletion waits for an active image save and removes it atomically',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-archive-delete-race-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final commitStarted = Completer<void>();
      final releaseCommit = Completer<void>();
      final writerStore = FileScreenshotTranslationImageStore(
        directory,
        commit: (staged, destination) async {
          commitStarted.complete();
          await releaseCommit.future;
          await staged.rename(destination.path);
        },
      );
      final lease = writerStore.beginImageWrite('shot-active-save');
      final saving = writerStore.saveWithLease(
        'shot-active-save',
        Uint8List.fromList([3, 2, 1]),
        lease,
      );
      await commitStarted.future;
      final core = ArchiveFakeCore()..history = [entry('shot-active-save')];
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        // Runtime and archive own separate handles for the same root.
        imageStore: FileScreenshotTranslationImageStore(directory),
      );

      var deletionFinished = false;
      final deleting = controller
          .deleteEntry(entry('shot-active-save'))
          .then((result) => deletionFinished = result.historyDeleted);
      await Future<void>.delayed(Duration.zero);
      expect(deletionFinished, isFalse);

      releaseCommit.complete();
      expect(await saving, isTrue);
      await deleting;

      expect(deletionFinished, isTrue);
      expect(await writerStore.read('shot-active-save'), isNull);
      expect(core.deletedIds, ['shot-active-save']);
    },
  );

  test('clearing images preserves screenshot text history', () async {
    final runtime = _runtimeWithFailedImageSave();
    await runtime.startCapture();
    expect(runtime.retryableImageSaveCacheBytes, 1);
    final imageStore = MemoryArchiveImageStore()
      ..images['shot-1'] = Uint8List.fromList([1, 2]);
    final core = ArchiveFakeCore()..history = [entry('shot-1')];
    final controller = ScreenshotTranslationArchiveController(
      coreFactory: () => core,
      imageStore: imageStore,
      purgeInvalidatedImageSaves: runtime.purgeInvalidatedImageSaves,
    );

    await controller.clearAllImages();

    expect(imageStore.images, isEmpty);
    expect(core.deletedIds, isEmpty);
    expect(core.history.map((row) => row.id), ['shot-1']);
    expect(runtime.retryableImageSaveCacheCount, 0);
    expect(runtime.retryableImageSaveCacheBytes, 0);
    runtime.dispose();
  });

  test(
    'clearing saved images invalidates the active session image status',
    () async {
      final imageStore = MemoryArchiveImageStore();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => CapturedData(
          width: 1,
          height: 1,
          bytes: Uint8List.fromList([7]),
          left: 0,
        ),
        recognize: (_, [_]) async => 'text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => 'translated',
        imageStore: imageStore,
      );
      await runtime.startCapture();
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.saved,
      );
      final controller = ScreenshotTranslationArchiveController(
        coreFactory: ArchiveFakeCore.new,
        imageStore: imageStore,
        purgeInvalidatedImageSaves: runtime.purgeInvalidatedImageSaves,
      );

      await controller.clearAllImages();

      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.invalidated,
      );
      expect(imageStore.images, isEmpty);
      runtime.dispose();
    },
  );

  test('clearing removes old retries but preserves captures begun after clear starts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-archive-clear-new-capture-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final deleteStarted = Completer<void>();
    final releaseDelete = Completer<void>();
    var failNextCommit = true;
    final imageStore = FileScreenshotTranslationImageStore(
      directory,
      commit: (staged, destination) async {
        if (failNextCommit) {
          failNextCommit = false;
          throw const FileSystemException('simulated save failure');
        }
        await staged.rename(destination.path);
      },
      deleteImage: (image) async {
        deleteStarted.complete();
        await releaseDelete.future;
        await image.delete();
      },
    );
    final recognitionStarted = Completer<void>();
    final releaseRecognition = Completer<void>();
    var holdRecognition = false;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => CapturedData(
        width: 1,
        height: 1,
        bytes: Uint8List.fromList([7]),
        left: 0,
      ),
      recognize: (_, [_]) async {
        if (holdRecognition) {
          recognitionStarted.complete();
          await releaseRecognition.future;
          return 'new text';
        }
        return 'old text';
      },
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => 'translated',
      imageStore: imageStore,
    );
    await runtime.startCapture();
    expect(runtime.retryableImageSaveCacheBytes, 1);
    await imageStore.save('seed-image', Uint8List.fromList([9]));
    holdRecognition = true;
    final controller = ScreenshotTranslationArchiveController(
      coreFactory: ArchiveFakeCore.new,
      imageStore: imageStore,
      purgeInvalidatedImageSaves: runtime.purgeInvalidatedImageSaves,
    );

    final clearing = controller.clearAllImages();
    await deleteStarted.future;
    final capture = runtime.startCapture();
    await recognitionStarted.future;

    releaseDelete.complete();
    await clearing;
    expect(runtime.retryableImageSaveCacheBytes, 0);
    expect(runtime.retryableImageSaves, isEmpty);
    releaseRecognition.complete();
    await capture;

    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.saved,
    );
    expect(await imageStore.read(runtime.session!.id), [7]);
    runtime.dispose();
  });

  test('failed image clear still releases in-memory retry snapshots', () async {
    final runtime = _runtimeWithFailedImageSave();
    await runtime.startCapture();
    expect(runtime.retryableImageSaveCacheBytes, 1);
    final imageStore = MemoryArchiveImageStore()..failClear = true;
    final controller = ScreenshotTranslationArchiveController(
      coreFactory: ArchiveFakeCore.new,
      imageStore: imageStore,
      purgeInvalidatedImageSaves: runtime.purgeInvalidatedImageSaves,
    );

    await expectLater(controller.clearAllImages(), throwsStateError);

    expect(runtime.retryableImageSaves, isEmpty);
    expect(runtime.retryableImageSaveCacheBytes, 0);
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.invalidated,
    );
    runtime.dispose();
  });
}

ScreenshotTranslationRuntime _runtimeWithFailedImageSave() =>
    ScreenshotTranslationRuntime(
      capture: () async => CapturedData(
        width: 1,
        height: 1,
        bytes: Uint8List.fromList([7]),
        left: 0,
      ),
      recognize: (_, [_]) async => 'text',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => 'translated',
      imageStore: FailingRuntimeImageStore(),
    );

TranslationHistoryEntryData entry(
  String id, {
  String origin = 'screenshot_translation',
  String sourceText = 'Hello',
  String? screenshotCaptureId,
}) => TranslationHistoryEntryData(
  id: id,
  sourceText: sourceText,
  translatedText: '你好',
  providerId: 'test',
  createdAt: '2026-10-07T00:00:00Z',
  origin: origin,
  screenshotCaptureId: screenshotCaptureId,
);

class _DeferredBatchImageStore extends Fake
    implements
        ScreenshotTranslationCoordinatedImageStore,
        ScreenshotTranslationBatchDeletionImageStore {
  _DeferredBatchImageStore(this.delegate);
  final FileScreenshotTranslationImageStore delegate;
  final saveStarted = Completer<void>();
  final releaseSave = Completer<void>();
  bool deferNextSave = false;

  @override
  ScreenshotTranslationImageWriteLease beginImageWrite(String id) =>
      delegate.beginImageWrite(id);
  @override
  bool acceptsImageWriteLease(
    String id,
    ScreenshotTranslationImageWriteLease lease,
  ) => delegate.acceptsImageWriteLease(id, lease);
  @override
  Future<bool> saveWithLease(
    String id,
    Uint8List bytes,
    ScreenshotTranslationImageWriteLease lease,
  ) async {
    if (deferNextSave) {
      deferNextSave = false;
      saveStarted.complete();
      await releaseSave.future;
    }
    return delegate.saveWithLease(id, bytes, lease);
  }

  @override
  Future<T> deleteImagesAndThen<T>(
    List<String> ids,
    Future<T> Function() deleteHistory,
  ) => delegate.deleteImagesAndThen(ids, deleteHistory);
  @override
  Future<T> deleteImageAndThen<T>(
    String id,
    Future<T> Function() deleteHistory,
  ) => delegate.deleteImageAndThen(id, deleteHistory);
  @override
  Future<ScreenshotTranslationImageStats> inspect() => delegate.inspect();
  @override
  Future<T> serializeArchiveDeletion<T>(Future<T> Function() operation) =>
      delegate.serializeArchiveDeletion(operation);
  @override
  Future<bool> hasImageOrDeletionResidue(String id) =>
      delegate.hasImageOrDeletionResidue(id);
  @override
  Future<Uint8List?> read(String id) => delegate.read(id);
  @override
  Future<void> save(String id, Uint8List bytes) => delegate.save(id, bytes);
  @override
  Future<void> delete(String id) => delegate.delete(id);
  @override
  Future<void> clearAll() => delegate.clearAll();
}

class ArchiveFakeCore
    implements
        AppCore,
        PagedTranslationHistoryCore,
        ScreenshotTranslationHistoryValidationCore,
        ScreenshotCaptureImageDeletionCore,
        ScreenshotCaptureImageReferenceCore,
        DeletableTranslationHistoryCore {
  ArchiveFakeCore({this.order});

  final List<String>? order;
  final pageCalls = <({int limit, int offset, String? origin, String query})>[];
  List<List<TranslationHistoryEntryData>> pages = [];
  List<TranslationHistoryEntryData> history = [];
  final deletedIds = <String>[];
  final validationCalls = <({String id, String sourceText})>[];
  final referenceBatchSizes = <int>[];
  String? validationErrorCode;
  String? referenceLookupErrorCode;
  var failNextHistoryDelete = false;
  var _pageIndex = 0;

  @override
  List<TranslationHistoryEntryData> listTranslationHistoryPage({
    int limit = 50,
    int offset = 0,
    String? origin,
    String query = '',
  }) {
    pageCalls.add((limit: limit, offset: offset, origin: origin, query: query));
    if (_pageIndex < pages.length) return pages[_pageIndex++];
    final filtered = history.where((row) {
      if (origin != null && row.origin != origin) return false;
      if (query.isNotEmpty &&
          !row.sourceText.toLowerCase().contains(query.toLowerCase()) &&
          !row.translatedText.toLowerCase().contains(query.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
    return filtered.skip(offset.clamp(0, 5000).toInt()).take(limit).toList();
  }

  @override
  bool validateScreenshotTranslationHistory({
    required String id,
    required String sourceText,
  }) {
    validationCalls.add((id: id, sourceText: sourceText));
    final validationErrorCode = this.validationErrorCode;
    if (validationErrorCode != null) {
      throw CoreBridgeException(
        validationErrorCode,
        'simulated screenshot history validation failure',
      );
    }
    return history.any(
      (row) =>
          row.id == id &&
          row.origin == 'screenshot_translation' &&
          row.sourceText == sourceText,
    );
  }

  @override
  List<String> screenshotCaptureIdsOrphanedByHistoryDeletion(List<String> ids) {
    final selectedIds = ids.toSet();
    final selectedCaptureIds = history
        .where(
          (row) =>
              selectedIds.contains(row.id) &&
              row.origin == 'screenshot_translation',
        )
        .map((row) => row.captureId)
        .toSet();
    return selectedCaptureIds
        .where(
          (captureId) => !history.any(
            (row) =>
                row.origin == 'screenshot_translation' &&
                row.captureId == captureId &&
                !selectedIds.contains(row.id),
          ),
        )
        .toList();
  }

  @override
  List<String> referencedScreenshotCaptureIds(List<String> captureIds) {
    referenceBatchSizes.add(captureIds.length);
    final referenceLookupErrorCode = this.referenceLookupErrorCode;
    if (referenceLookupErrorCode != null) {
      throw CoreBridgeException(
        referenceLookupErrorCode,
        'simulated screenshot image reference lookup failure',
      );
    }
    final requested = captureIds.toSet();
    return history
        .where((row) => row.origin == 'screenshot_translation')
        .map((row) => row.captureId)
        .where(requested.contains)
        .toSet()
        .toList();
  }

  @override
  void deleteTranslationHistory(List<String> ids) {
    order?.add('history:${ids.join(',')}');
    if (failNextHistoryDelete) {
      failNextHistoryDelete = false;
      throw StateError('simulated history delete failure');
    }
    deletedIds.addAll(ids);
    history.removeWhere((row) => ids.contains(row.id));
  }

  @override
  CoreHealth health() =>
      const CoreHealth(schemaVersion: 1, coreVersion: 'test');

  @override
  void dispose() {}

  @override
  void recordCompletedTranslation(CompletedTranslationData translation) {}

  @override
  List<TranslationHistoryEntryData> listTranslationHistory({int limit = 500}) =>
      history;

  @override
  void saveProviderProfile(ProviderProfileData profile) {}

  @override
  void deleteProviderProfile(String providerId) {}

  @override
  List<ProviderProfileData> listProviderProfiles() => const [];

  @override
  void recordActivity(ActivityEventData activity) {}

  @override
  HomeSnapshotData homeSnapshot(String localDate, {int recentLimit = 10}) =>
      const HomeSnapshotData(
        learningMinutes: 0,
        readingPages: 0,
        masteredWords: 0,
        completedExercises: 0,
        recent: [],
      );
}

class MemoryArchiveImageStore implements ScreenshotTranslationImageStore {
  MemoryArchiveImageStore({this.order});

  final List<String>? order;
  final images = <String, Uint8List>{};
  var failDelete = false;
  var failClear = false;
  Completer<void>? clearGate;

  @override
  Future<void> save(String historyId, Uint8List pngBytes) async =>
      images[historyId] = Uint8List.fromList(pngBytes);

  @override
  Future<Uint8List?> read(String historyId) async => images[historyId];

  @override
  Future<void> delete(String historyId) async {
    order?.add('image:$historyId');
    if (failDelete) throw FileSystemException('simulated image delete failure');
    images.remove(historyId);
  }

  @override
  Future<ScreenshotTranslationImageStats> inspect() async =>
      ScreenshotTranslationImageStats(
        imageCount: images.length,
        totalBytes: images.values.fold(0, (sum, bytes) => sum + bytes.length),
      );

  @override
  Future<void> clearAll() async {
    await clearGate?.future;
    if (failClear) throw StateError('simulated image clear failure');
    images.clear();
  }
}

class CoordinatedArchiveImageStore
    implements ScreenshotTranslationCoordinatedImageStore {
  CoordinatedArchiveImageStore({this.order});

  final List<String>? order;
  final _leaseIssuer = FileScreenshotTranslationImageStore(
    Directory('unused-coordinated-archive-test'),
  );
  final images = <String, Uint8List>{};

  @override
  ScreenshotTranslationImageWriteLease beginImageWrite(String historyId) =>
      _leaseIssuer.beginImageWrite(historyId);

  @override
  bool acceptsImageWriteLease(
    String historyId,
    ScreenshotTranslationImageWriteLease lease,
  ) => _leaseIssuer.acceptsImageWriteLease(historyId, lease);

  @override
  Future<bool> saveWithLease(
    String historyId,
    Uint8List pngBytes,
    ScreenshotTranslationImageWriteLease lease,
  ) async {
    if (!acceptsImageWriteLease(historyId, lease)) return false;
    await save(historyId, pngBytes);
    return true;
  }

  @override
  Future<void> save(String historyId, Uint8List pngBytes) async {
    images[historyId] = Uint8List.fromList(pngBytes);
  }

  @override
  Future<Uint8List?> read(String historyId) async => images[historyId];

  @override
  Future<void> delete(String historyId) async {
    order?.add('image:$historyId');
    images.remove(historyId);
  }

  @override
  Future<ScreenshotTranslationImageStats> inspect() async =>
      ScreenshotTranslationImageStats(
        imageCount: images.length,
        totalBytes: images.values.fold(0, (sum, bytes) => sum + bytes.length),
      );

  @override
  Future<void> clearAll() async => images.clear();

  @override
  Future<T> deleteImageAndThen<T>(
    String historyId,
    Future<T> Function() deleteHistory,
  ) async {
    order?.add('coordinated:$historyId');
    final previousImage = images[historyId] == null
        ? null
        : Uint8List.fromList(images[historyId]!);
    await delete(historyId);
    try {
      return await deleteHistory();
    } catch (_) {
      if (previousImage != null) images[historyId] = previousImage;
      rethrow;
    }
  }

  @override
  Future<T> serializeArchiveDeletion<T>(Future<T> Function() operation) =>
      _leaseIssuer.serializeArchiveDeletion(operation);

  @override
  Future<bool> hasImageOrDeletionResidue(String historyId) async =>
      images.containsKey(historyId);
}

class FailingRuntimeImageStore implements ScreenshotTranslationImageStore {
  @override
  Future<void> save(String historyId, Uint8List pngBytes) async {
    throw StateError('disk unavailable');
  }

  @override
  Future<Uint8List?> read(String historyId) async => null;

  @override
  Future<void> delete(String historyId) async {}

  @override
  Future<ScreenshotTranslationImageStats> inspect() async =>
      ScreenshotTranslationImageStats.empty;

  @override
  Future<void> clearAll() async {}
}
