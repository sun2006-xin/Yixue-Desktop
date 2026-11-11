import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/screenshot_translation_image_store.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_archive_controller.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_workbench_settings.dart';

void main() {
  test(
    'deleting history waits for a pending retranslation before removal',
    () async {
      final store = _DeferredImageStore();
      final core = _HistoryCore();
      final retranslationStarted = Completer<void>();
      final releaseRetranslation = Completer<void>();
      final runtimeCleared = Completer<void>();
      var deferNextTranslation = false;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => CapturedData(
          width: 1,
          height: 1,
          bytes: Uint8List.fromList([1, 2, 3]),
          left: 0,
        ),
        recognize: (_, [_]) async => 'original source',
        imageStore: store,
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              if (deferNextTranslation) {
                deferNextTranslation = false;
                retranslationStarted.complete();
                await releaseRetranslation.future;
              }
              core.history.add(
                TranslationHistoryEntryData(
                  id: historyEntryId,
                  sourceText: source,
                  translatedText: '译文',
                  providerId: 'test',
                  createdAt: '2026-10-08T00:00:00Z',
                  origin: origin,
                  screenshotCaptureId: screenshotCaptureId,
                ),
              );
              return '译文';
            },
      );
      runtime.addListener(() {
        if (runtime.session == null && !runtimeCleared.isCompleted) {
          runtimeCleared.complete();
        }
      });
      final archive = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: store,
        purgeRetryableImageSave: runtime.purgeRetryableImageSave,
        beforeDeleteHistoryEntry: runtime.deleteHistoryEntry,
      );
      addTearDown(runtime.dispose);
      addTearDown(archive.dispose);

      await runtime.startCapture();
      final historyEntry = core.history.single;
      deferNextTranslation = true;
      final retranslation = runtime.retranslate('edited source');
      await retranslationStarted.future;

      var deletionFinished = false;
      final deleting = archive.deleteEntry(historyEntry).then((result) {
        deletionFinished = true;
        return result;
      });
      await runtimeCleared.future;
      expect(deletionFinished, isFalse);
      releaseRetranslation.complete();
      final deletion = await deleting;
      expect(deletion.historyDeleted, isTrue);
      await retranslation;

      expect(core.history, hasLength(1));
      expect(core.history.single.id, '${historyEntry.id}-v1');
      expect(core.history.single.screenshotCaptureId, historyEntry.captureId);
      expect(store.images, contains(historyEntry.captureId));
      expect(runtime.session, isNull);
    },
  );

  for (final clearAll in [false, true]) {
    final operation = clearAll ? 'clear' : 'delete';
    test(
      '$operation cannot restore retry bytes when lease inspection also fails',
      () async {
        final store = _DeferredImageStore()..deferNextSave = true;
        final core = _HistoryCore();
        final runtime = _runtime(store, core);
        final archive = _archive(store, core, runtime);
        addTearDown(runtime.dispose);
        addTearDown(archive.dispose);
        final capture = runtime.startCapture();
        await store.saveStarted.future;
        await _invalidate(archive, core, clearAll);

        store.failDeferredSave = true;
        store.throwNextLeaseCheck = true;
        store.releaseSave.complete();
        await capture;

        expect(runtime.retryableImageSaveCacheBytes, 0);
        expect(runtime.retryableImageSaves, isEmpty);
        expect(
          runtime.session!.imageSaveStatus,
          ScreenshotTranslationImageSaveStatus.invalidated,
        );
        expect(store.images, isEmpty);
      },
    );
    test(
      '$operation does not restore retry bytes after a late write failure',
      () async {
        final store = _DeferredImageStore()..deferNextSave = true;
        final core = _HistoryCore();
        final runtime = _runtime(store, core);
        final archive = _archive(store, core, runtime);
        addTearDown(runtime.dispose);
        addTearDown(archive.dispose);

        final capture = runtime.startCapture();
        await store.saveStarted.future;
        final id = runtime.session!.id;
        await _invalidate(archive, core, clearAll);
        expect(runtime.retryableImageSaveCacheBytes, 0);

        store.failDeferredSave = true;
        store.releaseSave.complete();
        await capture;

        expect(runtime.retryableImageSaves, isEmpty);
        expect(runtime.retryableImageSaveCacheCount, 0);
        expect(runtime.retryableImageSaveCacheBytes, 0);
        expect(
          runtime.session!.imageSaveStatus,
          ScreenshotTranslationImageSaveStatus.invalidated,
        );
        expect(runtime.session!.translatedText, '译文');
        expect(await runtime.retryImageSave(historyEntryId: id), isFalse);
        expect(store.images, isEmpty);
        expect(core.history, clearAll ? hasLength(1) : isEmpty);
      },
    );

    testWidgets('settings reports an invalidated $operation retry as unsaved', (
      tester,
    ) async {
      final store = _DeferredImageStore()..failNextSave = true;
      final core = _HistoryCore();
      final runtime = _runtime(store, core);
      final archive = _archive(store, core, runtime);
      final desktop = _desktop();
      addTearDown(runtime.dispose);
      addTearDown(archive.dispose);
      addTearDown(desktop.dispose);
      await runtime.startCapture();
      expect(runtime.retryableImageSaveCacheBytes, 3);
      store.deferNextSave = true;
      await tester.pumpWidget(_settings(runtime, archive, desktop));
      final retry = find.widgetWithText(TextButton, '重试');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pump();
      expect(store.saveStarted.isCompleted, isTrue);

      if (clearAll) {
        await _invalidate(archive, core, clearAll);
      } else {
        // Flush completed fake-zone queue futures before this operation enters
        // the real async zone for the deferred image-save race.
        await tester.pump();
        await tester.runAsync(() => _invalidate(archive, core, clearAll));
      }
      store.releaseSave.complete();
      final invalidatedFeedback = find.textContaining('原图未能保存');
      for (
        var attempt = 0;
        attempt < 20 && invalidatedFeedback.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(runtime.retryableImageSaves, isEmpty);
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.invalidated,
      );
      expect(store.images, isEmpty);
      expect(find.text('原图保存重试已完成。'), findsNothing);
      expect(find.textContaining('原图未能保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await runtime.shutdown();
    });
  }

  test('failed clear cannot restore bytes from a late save failure', () async {
    final store = _DeferredImageStore()
      ..deferNextSave = true
      ..failClearAfterInvalidation = true;
    final core = _HistoryCore();
    final runtime = _runtime(store, core);
    final archive = _archive(store, core, runtime);
    addTearDown(runtime.dispose);
    addTearDown(archive.dispose);
    final capture = runtime.startCapture();
    await store.saveStarted.future;
    await expectLater(archive.clearAllImages(), throwsStateError);
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.invalidated,
    );

    store.failDeferredSave = true;
    store.releaseSave.complete();
    await capture;

    expect(runtime.retryableImageSaves, isEmpty);
    expect(runtime.retryableImageSaveCacheBytes, 0);
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.invalidated,
    );
    expect(core.history, hasLength(1));
    expect(runtime.session!.translatedText, '译文');
  });

  testWidgets(
    'settings reports a successful retry only after image persistence',
    (tester) async {
      final store = _DeferredImageStore()..failNextSave = true;
      final core = _HistoryCore();
      final runtime = _runtime(store, core);
      final archive = _archive(store, core, runtime);
      final desktop = _desktop();
      addTearDown(runtime.dispose);
      addTearDown(archive.dispose);
      addTearDown(desktop.dispose);
      await runtime.startCapture();
      final id = runtime.session!.id;
      store.deferNextSave = true;
      await tester.pumpWidget(_settings(runtime, archive, desktop));
      final retry = find.widgetWithText(TextButton, '重试');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pump();
      expect(store.saveStarted.isCompleted, isTrue);
      expect(store.images, isEmpty);
      expect(find.text('原图保存重试已完成。'), findsNothing);

      store.releaseSave.complete();
      await tester.pumpAndSettle();

      expect(store.images[id], [1, 2, 3]);
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.saved,
      );
      expect(runtime.retryableImageSaves, isEmpty);
      expect(find.text('原图保存重试已完成。'), findsOneWidget);
      expect(find.textContaining('原图未能保存'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await runtime.shutdown();
    },
  );
}

ScreenshotTranslationRuntime _runtime(
  _DeferredImageStore store,
  _HistoryCore core,
) => ScreenshotTranslationRuntime(
  capture: () async => CapturedData(
    width: 1,
    height: 1,
    bytes: Uint8List.fromList([1, 2, 3]),
    left: 0,
  ),
  recognize: (_, [_]) async => 'source',
  translate:
      (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async {
        core.history.add(
          TranslationHistoryEntryData(
            id: historyEntryId,
            sourceText: source,
            translatedText: '译文',
            providerId: 'test',
            createdAt: '2026-10-08T00:00:00Z',
            origin: origin,
            screenshotCaptureId: screenshotCaptureId,
          ),
        );
        return '译文';
      },
  imageStore: store,
);

ScreenshotTranslationArchiveController _archive(
  _DeferredImageStore store,
  _HistoryCore core,
  ScreenshotTranslationRuntime runtime,
) => ScreenshotTranslationArchiveController(
  coreFactory: () => core,
  imageStore: store,
  purgeRetryableImageSave: runtime.purgeRetryableImageSave,
  purgeInvalidatedImageSaves: runtime.purgeInvalidatedImageSaves,
);

Future<void> _invalidate(
  ScreenshotTranslationArchiveController archive,
  _HistoryCore core,
  bool clearAll,
) async {
  if (clearAll) {
    await archive.clearAllImages();
  } else {
    final result = await archive.deleteEntry(core.history.single);
    expect(result.imageDeleted, isTrue);
    expect(result.historyDeleted, isTrue);
  }
}

Widget _settings(
  ScreenshotTranslationRuntime runtime,
  ScreenshotTranslationArchiveController archive,
  ScreenshotTranslationDesktopController desktop,
) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: ScreenshotTranslationWorkbenchSettings(
        controller: desktop,
        archiveController: archive,
        runtime: runtime,
      ),
    ),
  ),
);

ScreenshotTranslationDesktopController _desktop() =>
    ScreenshotTranslationDesktopController(
      store: _Preferences(),
      hotKeys: _HotKeys(),
      createOrb: () async => _Orb(),
      onCapture: () async {},
      onOpenMain: () async {},
      onOpenSettings: () async {},
      onHideMain: () async {},
      onReleaseSession: () async {},
      onCloseChildren: () async {},
      onExit: () async {},
    );

class _Preferences extends Fake
    implements ScreenshotTranslationPreferencesStore {}

class _HotKeys extends Fake implements ScreenshotGlobalHotKey {}

class _Orb extends Fake implements ScreenshotOrbHandle {}

class _HistoryCore extends Fake
    implements
        AppCore,
        PagedTranslationHistoryCore,
        DeletableTranslationHistoryCore,
        ScreenshotCaptureImageDeletionCore {
  final history = <TranslationHistoryEntryData>[];

  @override
  List<TranslationHistoryEntryData> listTranslationHistoryPage({
    int limit = 50,
    int offset = 0,
    String? origin,
    String query = '',
  }) => history
      .where((row) => row.origin == origin && row.sourceText.contains(query))
      .skip(offset)
      .take(limit)
      .toList();

  @override
  void deleteTranslationHistory(List<String> ids) =>
      history.removeWhere((row) => ids.contains(row.id));

  @override
  List<String> screenshotCaptureIdsOrphanedByHistoryDeletion(List<String> ids) {
    final selectedIds = ids.toSet();
    final selectedCaptureIds = history
        .where((row) => selectedIds.contains(row.id))
        .map((row) => row.screenshotCaptureId ?? row.id)
        .toSet();
    final remainingCaptureIds = history
        .where((row) => !selectedIds.contains(row.id))
        .map((row) => row.screenshotCaptureId ?? row.id)
        .toSet();
    return selectedCaptureIds.difference(remainingCaptureIds).toList();
  }

  @override
  void dispose() {}
}

// Only uses the file store to issue opaque leases. No file operation is invoked:
// writes and invalidation below are deterministic in-memory test boundaries.
class _DeferredImageStore
    implements ScreenshotTranslationCoordinatedImageStore {
  final _leaseIssuer = FileScreenshotTranslationImageStore(
    Directory('unused-archive-race-test'),
  );
  Future<void> _archiveDeletionTail = Future<void>.value();
  final _leases = <String, ScreenshotTranslationImageWriteLease>{};
  final images = <String, Uint8List>{};
  final saveStarted = Completer<void>();
  final releaseSave = Completer<void>();
  bool failNextSave = false;
  bool deferNextSave = false;
  bool failDeferredSave = false;
  bool throwNextLeaseCheck = false;
  bool failClearAfterInvalidation = false;

  @override
  ScreenshotTranslationImageWriteLease beginImageWrite(String historyId) {
    final lease = _leaseIssuer.beginImageWrite(historyId);
    _leases[historyId] = lease;
    return lease;
  }

  @override
  bool acceptsImageWriteLease(
    String historyId,
    ScreenshotTranslationImageWriteLease lease,
  ) {
    if (throwNextLeaseCheck) {
      throwNextLeaseCheck = false;
      throw StateError('simulated lease inspection failure');
    }
    return identical(_leases[historyId], lease);
  }

  @override
  Future<bool> saveWithLease(
    String historyId,
    Uint8List pngBytes,
    ScreenshotTranslationImageWriteLease lease,
  ) async {
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('initial save failure');
    }
    if (deferNextSave) {
      deferNextSave = false;
      saveStarted.complete();
      await releaseSave.future;
      if (failDeferredSave) {
        throw const FileSystemException('late save failure');
      }
    }
    if (!acceptsImageWriteLease(historyId, lease)) return false;
    images[historyId] = Uint8List.fromList(pngBytes);
    return true;
  }

  @override
  Future<void> save(String historyId, Uint8List pngBytes) async =>
      images[historyId] = Uint8List.fromList(pngBytes);

  @override
  Future<Uint8List?> read(String historyId) async => images[historyId];

  @override
  Future<void> delete(String historyId) async {
    _leases.remove(historyId);
    images.remove(historyId);
  }

  @override
  Future<T> deleteImageAndThen<T>(
    String historyId,
    Future<T> Function() deleteHistory,
  ) async {
    final previousImage = images[historyId] == null
        ? null
        : Uint8List.fromList(images[historyId]!);
    await delete(historyId);
    try {
      final result = await deleteHistory();
      return result;
    } catch (_) {
      if (previousImage != null) images[historyId] = previousImage;
      rethrow;
    }
  }

  @override
  Future<T> serializeArchiveDeletion<T>(Future<T> Function() operation) {
    final previous = _archiveDeletionTail;
    final settled = Completer<void>();
    _archiveDeletionTail = settled.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        if (!settled.isCompleted) settled.complete();
      }
    }();
  }

  @override
  Future<bool> hasImageOrDeletionResidue(String historyId) async =>
      images.containsKey(historyId);

  @override
  Future<void> clearAll() async {
    _leases.clear();
    images.clear();
    if (failClearAfterInvalidation) {
      throw StateError('simulated clear failure after invalidation');
    }
  }

  @override
  Future<ScreenshotTranslationImageStats> inspect() async =>
      ScreenshotTranslationImageStats(
        imageCount: images.length,
        totalBytes: images.values.fold(
          0,
          (total, bytes) => total + bytes.lengthInBytes,
        ),
      );
}
