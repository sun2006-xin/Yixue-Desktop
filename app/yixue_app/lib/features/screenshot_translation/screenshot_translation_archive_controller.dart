import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/screenshot_translation_image_store.dart';

/// Creates persistent screenshot storage for a normal app shell.
///
/// Preview/test shells without a library directory keep captures in the active
/// session only and do not create files in an inferred user-data location.
ScreenshotTranslationImageStore?
screenshotTranslationImageStoreForAppDataDirectory(String? appDataDirectory) {
  final path = appDataDirectory?.trim();
  if (path == null || path.isEmpty) return null;
  return FileScreenshotTranslationImageStore(
    Directory(
      Directory(path).uri.resolve('screenshot_translation').toFilePath(),
    ),
  );
}

final class ScreenshotTranslationArchiveDeleteResult {
  const ScreenshotTranslationArchiveDeleteResult({
    required this.imageDeleted,
    required this.historyDeleted,
    this.imageCleanupPending = false,
    this.error,
  });

  final bool imageDeleted;
  final bool historyDeleted;
  final bool imageCleanupPending;
  final Object? error;
}

/// State and operations for the screenshot archive/workbench.
///
/// This stays separate from presentation so search, paging, image retention,
/// and the image-before-history deletion rule can be tested without a window.
final class ScreenshotTranslationArchiveController extends ChangeNotifier {
  ScreenshotTranslationArchiveController({
    required this.coreFactory,
    required this.imageStore,
    this.pageSize = 50,
    this.purgeRetryableImageSave,
    this.purgeInvalidatedImageSaves,
    this.beforeDeleteHistoryEntry,
    this.beforeDeleteCaptureImage,
    this.cancelCaptureImageDeletion,
  }) : assert(pageSize > 0);

  static const screenshotOrigin = 'screenshot_translation';

  final AppCore Function() coreFactory;
  final ScreenshotTranslationImageStore imageStore;
  final int pageSize;
  final void Function(String captureId)? purgeRetryableImageSave;
  final VoidCallback? purgeInvalidatedImageSaves;
  final Future<void> Function(String historyEntryId)? beforeDeleteHistoryEntry;
  final Future<void> Function(String captureId)? beforeDeleteCaptureImage;
  final void Function(String captureId)? cancelCaptureImageDeletion;

  List<TranslationHistoryEntryData> entries = const [];
  String query = '';
  int offset = 0;
  bool hasMore = true;
  bool isCapped = false;
  bool isLoading = false;
  Object? lastError;
  ScreenshotTranslationImageStats imageStats =
      ScreenshotTranslationImageStats.empty;
  ScreenshotTranslationArchiveDeleteResult? lastDeleteResult;
  int _generation = 0;
  int _pendingLoads = 0;
  bool _disposed = false;
  Future<void> _historyDeletionTail = Future<void>.value();
  Future<void>? _imageRecoveryInFlight;

  static const _nativeOffsetCap = 5000;
  static const _nativePageLimitCap = 500;
  static const _nativeScreenshotReferenceLookupCap = 500;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> search(String value) async {
    if (_disposed) return;
    query = value.trim();
    offset = 0;
    hasMore = true;
    isCapped = false;
    entries = const [];
    lastError = null;
    final generation = ++_generation;
    await _loadPage(generation, replace: true);
  }

  Future<void> loadFirstPage() async {
    if (_disposed) return;
    offset = 0;
    hasMore = true;
    isCapped = false;
    entries = const [];
    lastError = null;
    final generation = ++_generation;
    await _loadPage(generation, replace: true);
  }

  Future<void> loadNextPage() async {
    if (_disposed || isLoading || !hasMore || isCapped) return;
    await _loadPage(_generation, replace: false);
  }

  Future<void> _loadPage(int generation, {required bool replace}) async {
    if (_disposed || !hasMore) return;
    final pageOffset = replace ? 0 : offset;
    final requestedLimit = _pageLimitAt(pageOffset);
    final pageQuery = query;
    _pendingLoads++;
    isLoading = true;
    _notify();
    AppCore? core;
    try {
      core = coreFactory();
      if (core is! PagedTranslationHistoryCore) {
        throw StateError('Translation history paging is unavailable');
      }
      final pagedCore = core as PagedTranslationHistoryCore;
      final page = pagedCore
          .listTranslationHistoryPage(
            limit: requestedLimit,
            offset: pageOffset,
            origin: screenshotOrigin,
            query: pageQuery,
          )
          .where((row) => row.origin == screenshotOrigin)
          .toList();
      if (generation != _generation) return;
      entries = replace ? page : [...entries, ...page];
      offset = (pageOffset.toInt() + page.length).toInt();
      isCapped =
          pageOffset >= _nativeOffsetCap && page.length == requestedLimit;
      hasMore = page.length == requestedLimit && !isCapped;
      lastError = null;
    } catch (error) {
      if (generation == _generation) lastError = error;
    } finally {
      core?.dispose();
      _pendingLoads--;
      isLoading = _pendingLoads > 0;
      _notify();
    }
  }

  int _pageLimitAt(int pageOffset) {
    final configuredLimit = pageSize.clamp(1, _nativePageLimitCap).toInt();
    if (pageOffset >= _nativeOffsetCap) return configuredLimit;
    final untilNativeCap = _nativeOffsetCap - pageOffset;
    return configuredLimit < untilNativeCap ? configuredLimit : untilNativeCap;
  }

  Future<Uint8List?> readImage(TranslationHistoryEntryData entry) {
    _requireScreenshotEntry(entry);
    if (!entries.any(
      (listed) => listed.id == entry.id && listed.captureId == entry.captureId,
    )) {
      return Future<Uint8List?>.value(null);
    }
    return imageStore.read(entry.captureId);
  }

  Future<ScreenshotTranslationImageStats> inspectImages() async {
    await recoverPendingImageDeletions();
    imageStats = await imageStore.inspect();
    _notify();
    return imageStats;
  }

  /// Resolves deletion backups left by a process exit while archive deletion
  /// was crossing the SQLite commit boundary. Only explicitly marked backups
  /// are reconciled; ordinary images may belong to an unfinished translation.
  Future<void> recoverPendingImageDeletions() {
    final current = _imageRecoveryInFlight;
    if (current != null) return current;

    late final Future<void> recovery;
    recovery =
        _serializeHistoryDeletion(() async {
          final store = imageStore;
          if (store is! ScreenshotTranslationDeletionRecoveryImageStore) return;
          final recoveryStore =
              store as ScreenshotTranslationDeletionRecoveryImageStore;
          AppCore? core;
          try {
            await recoveryStore.recoverPendingDeletionBackups((
              captureIds,
            ) async {
              core ??= coreFactory();
              final referenceCore = core;
              if (referenceCore is! ScreenshotCaptureImageReferenceCore) {
                // Keep rollback markers intact until the bridge can determine
                // whether each history row still exists.
                return null;
              }
              final screenshotReferenceCore =
                  referenceCore as ScreenshotCaptureImageReferenceCore;
              try {
                final referencedIds = <String>{};
                for (
                  var offset = 0;
                  offset < captureIds.length;
                  offset += _nativeScreenshotReferenceLookupCap
                ) {
                  final candidateEnd =
                      offset + _nativeScreenshotReferenceLookupCap;
                  final end = candidateEnd < captureIds.length
                      ? candidateEnd
                      : captureIds.length;
                  referencedIds.addAll(
                    screenshotReferenceCore.referencedScreenshotCaptureIds(
                      captureIds.sublist(offset, end),
                    ),
                  );
                }
                return referencedIds;
              } on CoreBridgeException catch (error) {
                if (error.code != 'unknown_command') rethrow;
                // A Dart UI can be newer than its bundled Rust bridge. The image
                // store leaves pending markers untouched for a later retry.
                return null;
              }
            });
          } finally {
            core?.dispose();
          }
        }).whenComplete(() {
          if (identical(_imageRecoveryInFlight, recovery)) {
            _imageRecoveryInFlight = null;
          }
        });
    _imageRecoveryInFlight = recovery;
    return recovery;
  }

  Future<ScreenshotTranslationImageStats> clearAllImages() async {
    try {
      await imageStore.clearAll();
    } finally {
      // clearAll invalidates old write leases even when filesystem cleanup
      // fails. Release their retry bytes but preserve leases issued after the
      // clear operation's linearization point.
      purgeInvalidatedImageSaves?.call();
    }
    return inspectImages();
  }

  Future<ScreenshotTranslationArchiveDeleteResult> deleteEntry(
    TranslationHistoryEntryData entry,
  ) => _serializeHistoryDeletion(() => _deleteEntry(entry));

  Future<ScreenshotTranslationArchiveDeleteResult> _deleteEntry(
    TranslationHistoryEntryData entry,
  ) async {
    _requireScreenshotEntry(entry);
    lastDeleteResult = null;
    var imageDeleted = false;
    var historyCommitted = false;
    var captureIds = <String>[];
    final preparedCaptureIds = <String>{};
    AppCore? core;
    try {
      // Reuse one handle for validation and deletion instead of reopening the
      // SQLite engine for the same history action.
      final validationCore = coreFactory();
      core = validationCore;
      if (!_screenshotHistoryMatches(validationCore, entry)) {
        throw StateError(
          'Translation history entry is not a persisted screenshot row',
        );
      }
      if (validationCore is! DeletableTranslationHistoryCore) {
        throw StateError('Translation history deletion is unavailable');
      }
      final deletableCore = validationCore as DeletableTranslationHistoryCore;

      // Settle a translation version being removed. The session/image ID is
      // independent from the version row ID and may still be shared by rows.
      final beforeDeleteHistory = beforeDeleteHistoryEntry;
      if (beforeDeleteHistory != null) await beforeDeleteHistory(entry.id);
      captureIds = _orphanedCaptureIds(validationCore, [entry.id], [entry]);
      for (final captureId in captureIds) {
        final beforeDeleteCaptureImage = this.beforeDeleteCaptureImage;
        if (beforeDeleteCaptureImage != null) {
          preparedCaptureIds.add(captureId);
          await beforeDeleteCaptureImage(captureId);
        }
      }
      // A settled provider can have committed one final version while the
      // deletion callback was waiting. Recheck before removing its shared file.
      captureIds = _orphanedCaptureIds(validationCore, [entry.id], [entry]);

      Future<void> deleteHistory() async {
        deletableCore.deleteTranslationHistory([entry.id]);
        historyCommitted = true;
        for (final captureId in captureIds) {
          purgeRetryableImageSave?.call(captureId);
        }
        final wasListed = entries.any((row) => row.id == entry.id);
        entries = entries.where((row) => row.id != entry.id).toList();
        if (wasListed) _adjustOffsetAfterDeletedEntries(1);
      }

      for (var index = 0; index < captureIds.length; index++) {
        final captureId = captureIds[index];
        final isLastImage = index == captureIds.length - 1;
        final store = imageStore;
        if (store is ScreenshotTranslationCoordinatedImageStore) {
          await store.deleteImageAndThen(
            captureId,
            isLastImage ? deleteHistory : () async {},
          );
          imageDeleted = true;
        } else {
          await imageStore.delete(captureId);
          imageDeleted = true;
          if (isLastImage) await deleteHistory();
        }
      }
      if (captureIds.isEmpty) await deleteHistory();
      try {
        imageStats = await imageStore.inspect();
      } catch (_) {
        // Statistics are advisory and must not block history deletion.
      }
      return _publishDeleteResult(
        ScreenshotTranslationArchiveDeleteResult(
          imageDeleted: imageDeleted,
          historyDeleted: true,
        ),
      );
    } catch (error) {
      var imageCleanupPending = false;
      if (historyCommitted) {
        try {
          imageStats = await imageStore.inspect();
        } catch (_) {
          // Statistics are advisory; the committed history deletion remains
          // authoritative even when image cleanup needs a later retry.
        }
        imageCleanupPending = await _hasImageCleanupPending(captureIds);
        if (!imageCleanupPending && captureIds.isNotEmpty) {
          imageDeleted = true;
        }
      }
      return _publishDeleteResult(
        ScreenshotTranslationArchiveDeleteResult(
          imageDeleted: imageDeleted,
          historyDeleted: historyCommitted,
          imageCleanupPending: imageCleanupPending,
          error: error,
        ),
      );
    } finally {
      for (final captureId in {...preparedCaptureIds, ...captureIds}) {
        if (!historyCommitted || !captureIds.contains(captureId)) {
          cancelCaptureImageDeletion?.call(captureId);
        }
      }
      core?.dispose();
    }
  }

  /// Deletes a mixed selection while coordinating screenshot images with
  /// its history rows. Batch-capable stores stage every selected image before
  /// committing rows; cleanup failures after that point remain retryable.
  Future<void> deleteSelectedHistoryEntries(
    List<TranslationHistoryEntryData> selectedEntries, {
    required Future<void> Function(List<String> ids) deleteHistory,
  }) => _serializeHistoryDeletion(
    () => _deleteSelectedHistoryEntries(
      selectedEntries,
      deleteHistory: deleteHistory,
    ),
  );

  Future<void> _deleteSelectedHistoryEntries(
    List<TranslationHistoryEntryData> selectedEntries, {
    required Future<void> Function(List<String> ids) deleteHistory,
  }) async {
    if (selectedEntries.isEmpty) return;
    lastDeleteResult = null;
    final uniqueEntries = <String, TranslationHistoryEntryData>{};
    for (final entry in selectedEntries) {
      uniqueEntries.putIfAbsent(entry.id, () => entry);
    }
    final entries = uniqueEntries.values.toList(growable: false);
    final screenshots = entries
        .where((entry) => entry.origin == screenshotOrigin)
        .toList(growable: false);
    var imageDeleted = false;
    var historyCommitted = false;
    var imageCleanupPending = false;
    Object? imageCleanupError;
    var captureIds = <String>[];
    final preparedCaptureIds = <String>{};
    AppCore? validationCore;
    try {
      if (screenshots.isNotEmpty) {
        // Validate the selection and image references on one Core handle.
        final core = coreFactory();
        validationCore = core;
        for (final entry in screenshots) {
          _requireScreenshotEntry(entry);
          if (!_screenshotHistoryMatches(core, entry)) {
            throw StateError(
              'Translation history entry ${entry.id} is not a persisted screenshot row',
            );
          }
        }
      }
      final beforeDeleteHistory = beforeDeleteHistoryEntry;
      for (final entry in screenshots) {
        if (beforeDeleteHistory != null) await beforeDeleteHistory(entry.id);
      }
      captureIds = validationCore == null
          ? const <String>[]
          : _orphanedCaptureIds(
              validationCore,
              entries.map((entry) => entry.id).toList(growable: false),
              screenshots,
            );
      for (final captureId in captureIds) {
        final beforeDeleteCaptureImage = this.beforeDeleteCaptureImage;
        if (beforeDeleteCaptureImage != null) {
          preparedCaptureIds.add(captureId);
          await beforeDeleteCaptureImage(captureId);
        }
      }
      if (validationCore != null) {
        captureIds = _orphanedCaptureIds(
          validationCore,
          entries.map((entry) => entry.id).toList(growable: false),
          screenshots,
        );
      }
      final selectedHistoryIds = entries
          .map((entry) => entry.id)
          .toList(growable: false);
      final screenshotIds = screenshots.map((entry) => entry.id).toSet();
      Future<void> deleteSelectedRows() async {
        if (historyCommitted) return;
        await deleteHistory(selectedHistoryIds);
        historyCommitted = true;
        for (final captureId in captureIds) {
          purgeRetryableImageSave?.call(captureId);
        }
      }

      void removeListedScreenshotRows() {
        final previousArchiveCount = this.entries.length;
        this.entries = this.entries
            .where((entry) => !screenshotIds.contains(entry.id))
            .toList();
        final removedListedCount = previousArchiveCount - this.entries.length;
        _adjustOffsetAfterDeletedEntries(removedListedCount);
      }

      final store = imageStore;
      if (captureIds.isNotEmpty &&
          store is ScreenshotTranslationBatchDeletionImageStore) {
        final batchStore =
            store as ScreenshotTranslationBatchDeletionImageStore;
        try {
          // File-backed storage stages every capture image before deleting any
          // selected history rows, making a process exit recoverable for the
          // entire selection.
          await batchStore.deleteImagesAndThen(captureIds, deleteSelectedRows);
          imageDeleted = true;
        } on ScreenshotTranslationImageCleanupPendingException catch (error) {
          if (!historyCommitted) rethrow;
          imageCleanupPending = true;
          imageCleanupError ??= error;
        } catch (error) {
          if (!historyCommitted) rethrow;
          imageCleanupPending = true;
          imageCleanupError ??= error;
        }
      } else {
        for (final captureId in captureIds) {
          var thisImageDeleted = false;
          try {
            if (store is ScreenshotTranslationCoordinatedImageStore) {
              // Compatibility stores still commit history after the first
              // image has been staged. The file store uses the batch contract
              // above so every selected image is staged first.
              await store.deleteImageAndThen(captureId, deleteSelectedRows);
              thisImageDeleted = true;
            } else {
              await imageStore.delete(captureId);
              thisImageDeleted = true;
            }
          } on ScreenshotTranslationImageCleanupPendingException catch (error) {
            if (!historyCommitted) rethrow;
            imageCleanupPending = true;
            imageCleanupError ??= error;
          } catch (error) {
            if (!historyCommitted) rethrow;
            imageCleanupPending = true;
            imageCleanupError ??= error;
          }
          imageDeleted = imageDeleted || thisImageDeleted;
        }
      }

      if (!historyCommitted) await deleteSelectedRows();
      removeListedScreenshotRows();
      try {
        imageStats = await imageStore.inspect();
      } catch (_) {
        // Statistics are advisory and do not change deletion success.
      }
      if (imageCleanupPending) {
        imageCleanupPending = await _hasImageCleanupPending(captureIds);
        if (!imageCleanupPending) {
          imageCleanupError = null;
          if (captureIds.isNotEmpty) imageDeleted = true;
        }
      }
      lastDeleteResult = ScreenshotTranslationArchiveDeleteResult(
        imageDeleted: imageDeleted,
        historyDeleted: true,
        imageCleanupPending: imageCleanupPending,
        error: imageCleanupError,
      );
      _notify();
    } catch (error) {
      if (historyCommitted) {
        final screenshotIds = screenshots.map((entry) => entry.id).toSet();
        final previousArchiveCount = this.entries.length;
        this.entries = this.entries
            .where((entry) => !screenshotIds.contains(entry.id))
            .toList();
        _adjustOffsetAfterDeletedEntries(
          previousArchiveCount - this.entries.length,
        );
        try {
          imageStats = await imageStore.inspect();
        } catch (_) {
          // Preserve the committed result even if advisory stats are stale.
        }
        imageCleanupPending = await _hasImageCleanupPending(captureIds);
        if (!imageCleanupPending && captureIds.isNotEmpty) {
          imageDeleted = true;
        }
        lastDeleteResult = ScreenshotTranslationArchiveDeleteResult(
          imageDeleted: imageDeleted,
          historyDeleted: true,
          imageCleanupPending: imageCleanupPending,
          error: imageCleanupPending ? error : null,
        );
        _notify();
        return;
      }
      lastDeleteResult = ScreenshotTranslationArchiveDeleteResult(
        imageDeleted: imageDeleted,
        historyDeleted: false,
        error: error,
      );
      _notify();
      rethrow;
    } finally {
      for (final captureId in {...preparedCaptureIds, ...captureIds}) {
        if (!historyCommitted || !captureIds.contains(captureId)) {
          cancelCaptureImageDeletion?.call(captureId);
        }
      }
      validationCore?.dispose();
    }
  }

  List<String> _orphanedCaptureIds(
    AppCore core,
    List<String> selectedHistoryIds,
    List<TranslationHistoryEntryData> selectedScreenshots,
  ) {
    final knownCaptureIds = selectedScreenshots
        .map((entry) => entry.captureId)
        .toSet();
    if (core case ScreenshotCaptureImageDeletionCore deletionCore) {
      try {
        final ids = deletionCore.screenshotCaptureIdsOrphanedByHistoryDeletion(
          selectedHistoryIds,
        );
        return ids
            .where(knownCaptureIds.contains)
            .toSet()
            .toList(growable: false);
      } on CoreBridgeException catch (error) {
        // Older native bridges cannot report shared references. They are safe
        // to use only for rows without the new capture ID field.
        if (error.code != 'unknown_command' &&
            error.code != 'unsupported_command') {
          rethrow;
        }
      }
    }
    if (selectedScreenshots.every(
      (entry) => entry.screenshotCaptureId == null,
    )) {
      return selectedScreenshots
          .map((entry) => entry.captureId)
          .toSet()
          .toList(growable: false);
    }
    return const [];
  }

  ScreenshotTranslationArchiveDeleteResult _publishDeleteResult(
    ScreenshotTranslationArchiveDeleteResult result,
  ) {
    lastDeleteResult = result;
    _notify();
    return result;
  }

  Future<bool> _hasImageCleanupPending(List<String> captureIds) async {
    if (captureIds.isEmpty) return false;
    final store = imageStore;
    if (store is! ScreenshotTranslationCoordinatedImageStore) return true;
    for (final captureId in captureIds) {
      try {
        if (await store.hasImageOrDeletionResidue(captureId)) return true;
      } on Object {
        // An unreadable path is not evidence that local bytes are gone.
        return true;
      }
    }
    return false;
  }

  void _adjustOffsetAfterDeletedEntries(int removedListedCount) {
    if (removedListedCount <= 0) return;
    offset = (offset - removedListedCount).clamp(0, offset).toInt();
    if (isCapped && offset < _nativeOffsetCap) {
      isCapped = false;
      hasMore = true;
    }
  }

  Future<T> _serializeHistoryDeletion<T>(Future<T> Function() operation) {
    final previous = _historyDeletionTail;
    final settled = Completer<void>();
    _historyDeletionTail = settled.future;
    return () async {
      await previous;
      try {
        final store = imageStore;
        if (store is ScreenshotTranslationCoordinatedImageStore) {
          return await store.serializeArchiveDeletion(operation);
        }
        return await operation();
      } finally {
        if (!settled.isCompleted) settled.complete();
      }
    }();
  }

  bool _screenshotHistoryMatches(
    AppCore core,
    TranslationHistoryEntryData entry,
  ) {
    if (core case ScreenshotTranslationHistoryValidationCore validationCore) {
      try {
        return validationCore.validateScreenshotTranslationHistory(
          id: entry.id,
          sourceText: entry.sourceText,
        );
      } on CoreBridgeException catch (error) {
        // A newer Dart UI may be paired with an older native library. Keep
        // the safe legacy lookup for that one protocol mismatch only.
        if (error.code != 'unknown_command') rethrow;
      }
    }
    if (core is! PagedTranslationHistoryCore) return false;
    final pagedCore = core as PagedTranslationHistoryCore;
    for (
      var pageOffset = 0;
      pageOffset <= _nativeOffsetCap;
      pageOffset += _nativePageLimitCap
    ) {
      final rows = pagedCore
          .listTranslationHistoryPage(
            limit: _nativePageLimitCap,
            offset: pageOffset,
            origin: screenshotOrigin,
            query: entry.sourceText,
          )
          .where((row) => row.origin == screenshotOrigin)
          .toList();
      if (rows.any((row) => row.id == entry.id)) return true;
      if (rows.length < _nativePageLimitCap) return false;
    }
    return false;
  }

  static void _requireScreenshotEntry(TranslationHistoryEntryData entry) {
    if (entry.origin != screenshotOrigin) {
      throw ArgumentError.value(
        entry.origin,
        'entry.origin',
        'Only screenshot translation history can use the image archive',
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
