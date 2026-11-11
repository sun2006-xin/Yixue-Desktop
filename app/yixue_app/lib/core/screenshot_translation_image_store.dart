import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

abstract interface class ScreenshotTranslationImageStore {
  Future<void> save(String historyId, Uint8List pngBytes);

  Future<Uint8List?> read(String historyId);

  Future<void> delete(String historyId);

  Future<ScreenshotTranslationImageStats> inspect();

  Future<void> clearAll();
}

/// Adds capture-time write leases and serialized image/history deletion.
///
/// A runtime reserves a lease when capture begins. A later history deletion
/// invalidates that lease synchronously, so provider work that completes after
/// the deletion cannot recreate an orphaned image.
abstract interface class ScreenshotTranslationCoordinatedImageStore
    implements ScreenshotTranslationImageStore {
  ScreenshotTranslationImageWriteLease beginImageWrite(String historyId);

  bool acceptsImageWriteLease(
    String historyId,
    ScreenshotTranslationImageWriteLease lease,
  );

  Future<bool> saveWithLease(
    String historyId,
    Uint8List pngBytes,
    ScreenshotTranslationImageWriteLease lease,
  );

  /// Stages the image, commits the history callback, and restores the image
  /// when the callback fails. Implementations must serialize by image ID.
  Future<T> deleteImageAndThen<T>(
    String historyId,
    Future<T> Function() deleteHistory,
  );

  /// Serializes archive row/reference checks in this Dart isolate, so two
  /// version deletions cannot both miss the orphaned image.
  Future<T> serializeArchiveDeletion<T>(Future<T> Function() operation);

  /// Checks the target image and its deletion backups after cleanup retries.
  Future<bool> hasImageOrDeletionResidue(String historyId);
}

/// Adds one transaction boundary for deleting several capture images and rows.
/// Every image must be staged before [deleteHistory] runs.
abstract interface class ScreenshotTranslationBatchDeletionImageStore {
  Future<T> deleteImagesAndThen<T>(
    List<String> captureIds,
    Future<T> Function() deleteHistory,
  );
}

/// Resolves crash-interrupted image deletions against persisted screenshot rows.
abstract interface class ScreenshotTranslationDeletionRecoveryImageStore {
  Future<void> recoverPendingDeletionBackups(
    Future<Set<String>?> Function(List<String> captureIds)
    findReferencedCaptureIds,
  );
}

/// Opaque permission captured before asynchronous OCR/provider work begins.
final class ScreenshotTranslationImageWriteLease {
  const ScreenshotTranslationImageWriteLease._(
    this.historyId,
    this._coordinator,
    this._generation,
    this._clearGeneration,
    this._clearBarrier,
    this._validAtCreation,
  );

  final String historyId;
  final _ScreenshotTranslationImageStoreCoordinator _coordinator;
  final int _generation;
  final int _clearGeneration;
  final Future<void> _clearBarrier;
  final bool _validAtCreation;
}

final class ScreenshotTranslationImageStats {
  const ScreenshotTranslationImageStats({
    required this.imageCount,
    required this.totalBytes,
  });

  static const empty = ScreenshotTranslationImageStats(
    imageCount: 0,
    totalBytes: 0,
  );

  final int imageCount;
  final int totalBytes;

  @override
  bool operator ==(Object other) =>
      other is ScreenshotTranslationImageStats &&
      imageCount == other.imageCount &&
      totalBytes == other.totalBytes;

  @override
  int get hashCode => Object.hash(imageCount, totalBytes);
}

/// The history row was deleted, but a staged screenshot could not be fully
/// removed. The caller can offer the local-image cleanup action as a retry.
final class ScreenshotTranslationImageCleanupPendingException
    implements Exception {
  const ScreenshotTranslationImageCleanupPendingException({
    required this.path,
    required this.cause,
  });

  final String path;
  final Object cause;

  @override
  String toString() => 'Screenshot image cleanup is pending for $path: $cause';
}

typedef ScreenshotTranslationImageCommit = Future<void> Function(
  File staged,
  File destination,
);
typedef ScreenshotTranslationImageDelete = Future<void> Function(File image);

/// Stores screenshot-region PNGs in a dedicated directory.
///
/// Image names are derived only from validated internal history IDs. Each
/// write is staged beside its destination and atomically replaced so a failed
/// write cannot damage the previous image.
final class FileScreenshotTranslationImageStore
    implements
        ScreenshotTranslationCoordinatedImageStore,
        ScreenshotTranslationBatchDeletionImageStore,
        ScreenshotTranslationDeletionRecoveryImageStore {
  FileScreenshotTranslationImageStore(
    this.rootDirectory, {
    ScreenshotTranslationImageCommit? commit,
    ScreenshotTranslationImageDelete? deleteImage,
  }) : _commit = commit ?? _atomicReplace,
       _deleteImage = deleteImage ?? _deleteFile,
       _coordinator = _coordinatorFor(rootDirectory);

  static const _maxHistoryIdLength = 128;
  static const _orphanedStagingFileAge = Duration(days: 1);
  static final _safeHistoryId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _ownedImageName = RegExp(r'^[A-Za-z0-9_-]{1,128}\.png$');
  static final _ownedStagingName = RegExp(
    r'^([A-Za-z0-9_-]{1,128}\.png)\.\d+-\d+-\d+\.pending$',
  );
  static final _ownedDeletionBackupName = RegExp(
    r'^([A-Za-z0-9_-]{1,128}\.png)\.\d+-\d+-\d+\.rollback$',
  );
  static final _ownedCommittedDeletionBackupName = RegExp(
    r'^([A-Za-z0-9_-]{1,128}\.png)\.\d+-\d+-\d+\.committed$',
  );
  static int _stagingSequence = 0;
  static Future<void> _archiveDeletionTail = Future<void>.value();
  static final Map<String, _ScreenshotTranslationImageStoreCoordinator>
  _coordinators = {};

  final Directory rootDirectory;
  final ScreenshotTranslationImageCommit _commit;
  final ScreenshotTranslationImageDelete _deleteImage;
  final _ScreenshotTranslationImageStoreCoordinator _coordinator;

  static _ScreenshotTranslationImageStoreCoordinator _coordinatorFor(
    Directory root,
  ) {
    var key = root.absolute.path;
    while (key.length > 3 && (key.endsWith('/') || key.endsWith(r'\'))) {
      key = key.substring(0, key.length - 1);
    }
    if (Platform.isWindows) key = key.toLowerCase();
    return _coordinators.putIfAbsent(
      key,
      _ScreenshotTranslationImageStoreCoordinator.new,
    );
  }

  @override
  ScreenshotTranslationImageWriteLease beginImageWrite(String historyId) {
    _imageFile(historyId);
    return _coordinator.beginImageWrite(historyId);
  }

  @override
  bool acceptsImageWriteLease(
    String historyId,
    ScreenshotTranslationImageWriteLease lease,
  ) => _coordinator.accepts(lease, historyId);

  @override
  Future<void> save(String historyId, Uint8List pngBytes) async {
    final lease = beginImageWrite(historyId);
    if (!await saveWithLease(historyId, pngBytes, lease)) {
      throw StateError('Screenshot image write was invalidated');
    }
  }

  @override
  Future<bool> saveWithLease(
    String historyId,
    Uint8List pngBytes,
    ScreenshotTranslationImageWriteLease lease,
  ) {
    final destination = _imageFile(historyId);
    if (!_coordinator.accepts(lease, historyId)) {
      return Future<bool>.value(false);
    }
    return _coordinator.runForId(historyId, lease._clearBarrier, () async {
      await _ensureRootDirectory(create: true);
      final token =
          '$pid-${DateTime.now().microsecondsSinceEpoch}-${++_stagingSequence}';
      final staged = File('${destination.path}.$token.pending');
      try {
        await staged.writeAsBytes(pngBytes, flush: true);
        await _commit(staged, destination);
      } finally {
        if (await staged.exists()) await staged.delete();
      }
      return true;
    });
  }

  @override
  Future<T> serializeArchiveDeletion<T>(Future<T> Function() operation) =>
      _serializeArchiveDeletion(operation);

  @override
  Future<bool> hasImageOrDeletionResidue(String historyId) async {
    final image = _imageFile(historyId);
    if (!await _ensureRootDirectory(create: false)) return false;
    if (await FileSystemEntity.type(image.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return true;
    }
    return _hasDeletionBackup(historyId);
  }

  static Future<T> _serializeArchiveDeletion<T>(
    Future<T> Function() operation,
  ) {
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
  Future<Uint8List?> read(String historyId) async {
    final image = _imageFile(historyId);
    if (!await _ensureRootDirectory(create: false)) return null;
    final type = await FileSystemEntity.type(image.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      // A process can stop after staging an image for deletion but before its
      // history callback commits. Recover only when a caller still has a
      // history row to read; inspect() must never resurrect a deleted row.
      final backup = await _findDeletionBackup(historyId);
      if (backup == null) return null;
      return backup.readAsBytes();
    }
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Screenshot image entry is not a regular file',
        image.path,
      );
    }
    return await image.readAsBytes();
  }

  @override
  Future<void> delete(String historyId) async {
    await deleteImageAndThen(historyId, () async {});
  }

  @override
  Future<T> deleteImageAndThen<T>(
    String historyId,
    Future<T> Function() deleteHistory,
  ) => deleteImagesAndThen([historyId], deleteHistory);

  @override
  Future<T> deleteImagesAndThen<T>(
    List<String> captureIds,
    Future<T> Function() deleteHistory,
  ) {
    final ids = captureIds.toSet().toList()..sort();
    for (final captureId in ids) {
      _imageFile(captureId);
    }
    if (ids.isEmpty) return deleteHistory();

    final deletion = _coordinator.invalidateForDeletions(ids);
    return _coordinator.runForIds(ids, deletion.barrier, () async {
      var historyCommitted = false;
      try {
        final rootExists = await _ensureRootDirectory(create: false);
        final stagedById = <String, List<File>>{};
        try {
          if (rootExists) {
            for (final captureId in ids) {
              final staged = await _stageAndDeleteImage(_imageFile(captureId));
              if (staged != null) stagedById[captureId] = [staged];
            }
          }
        } on Object catch (error) {
          try {
            for (final captureId in ids.reversed) {
              await _restorePendingDeletionBackups(
                captureId,
                preferredBackup: stagedById[captureId]?.lastOrNull,
              );
            }
          } on Object catch (rollbackError) {
            throw FileSystemException(
              'Screenshot staging failed ($error) and rollback failed ($rollbackError)',
              stagedById.values.firstOrNull?.firstOrNull?.path,
            );
          }
          rethrow;
        }

        final T result;
        try {
          result = await deleteHistory();
          historyCommitted = true;
        } on Object catch (error) {
          try {
            for (final captureId in ids.reversed) {
              await _restorePendingDeletionBackups(
                captureId,
                preferredBackup: stagedById[captureId]?.lastOrNull,
              );
            }
          } on Object catch (rollbackError) {
            final failedBackup = stagedById.values
                .expand((backups) => backups)
                .firstOrNull;
            throw FileSystemException(
              'History deletion failed ($error) and screenshot rollback failed ($rollbackError)',
              failedBackup?.path,
            );
          }
          rethrow;
        }

        File? cleanupCandidate;
        Object? cleanupError;
        for (final captureId in ids) {
          try {
            for (final pendingBackup in await _findDeletionBackups(captureId)) {
              cleanupCandidate = pendingBackup;
              try {
                final committedBackup = await _markDeletionBackupCommitted(
                  pendingBackup,
                );
                cleanupCandidate = committedBackup;
                await _deleteOwnedEntry(committedBackup);
                cleanupCandidate = null;
              } on Object catch (error) {
                cleanupError ??= error;
              }
            }
            for (final committedBackup in await _findCommittedDeletionBackups(
              captureId,
            )) {
              cleanupCandidate = committedBackup;
              try {
                await _deleteOwnedEntry(committedBackup);
                cleanupCandidate = null;
              } on Object catch (error) {
                cleanupError ??= error;
              }
            }
            for (final pendingStaging in await _findStagingFiles(captureId)) {
              cleanupCandidate = pendingStaging;
              try {
                await _deleteOwnedEntry(pendingStaging);
                cleanupCandidate = null;
              } on Object catch (error) {
                cleanupError ??= error;
              }
            }
          } on Object catch (error) {
            cleanupError ??= error;
          }
        }
        if (cleanupError != null) {
          final pendingIds = <String>[];
          for (final captureId in ids) {
            if (await _hasDeletionBackup(captureId)) pendingIds.add(captureId);
          }
          if (pendingIds.isNotEmpty) {
            throw ScreenshotTranslationImageCleanupPendingException(
              path:
                  cleanupCandidate?.path ??
                  stagedById.values
                      .expand((backups) => backups)
                      .firstOrNull
                      ?.path ??
                  _imageFile(pendingIds.first).path,
              cause: cleanupError,
            );
          }
        }
        return result;
      } finally {
        if (!historyCommitted) {
          // History still owns these captures. Keep old leases stale while
          // allowing a newly issued lease after the failed transaction.
          _coordinator.cancelDeletions(deletion.generations);
        }
      }
    });
  }

  @override
  Future<void> recoverPendingDeletionBackups(
    Future<Set<String>?> Function(List<String> captureIds)
    findReferencedCaptureIds,
  ) async {
    final discovered = await _pendingDeletionBackupIds();
    final lockedIds = {...discovered.pending, ...discovered.committed}.toList()
      ..sort();
    if (lockedIds.isEmpty) return;

    await _coordinator.runForIds(
      lockedIds,
      _coordinator.clearBarrier,
      () async {
        final current = await _pendingDeletionBackupIds();
        final lockedIdSet = lockedIds.toSet();
        final currentPendingIds = current.pending
            .where(lockedIdSet.contains)
            .toList(growable: false);
        final currentCommittedIds = current.committed
            .where(lockedIdSet.contains)
            .toList(growable: false);
        if (currentPendingIds.isEmpty && currentCommittedIds.isEmpty) return;
        for (final captureId in currentCommittedIds) {
          for (final committedBackup in await _findCommittedDeletionBackups(
            captureId,
          )) {
            await _deleteOwnedEntry(committedBackup);
          }
        }
        if (currentPendingIds.isEmpty) return;
        // Without a reference query, a pending backup may represent either a
        // committed deletion or a history row that still needs its image.
        // Keep the marker so a compatible bridge can decide on a later launch.
        final referenced = await findReferencedCaptureIds(currentPendingIds);
        if (referenced == null) return;
        for (final captureId in currentPendingIds) {
          final backups = await _findDeletionBackups(captureId);
          if (backups.isEmpty) continue;
          final image = _imageFile(captureId);
          if (referenced.contains(captureId)) {
            final imageType = await FileSystemEntity.type(
              image.path,
              followLinks: false,
            );
            if (imageType == FileSystemEntityType.notFound) {
              await _restoreDeletionBackup(backups.first, image);
            } else if (imageType != FileSystemEntityType.file) {
              throw FileSystemException(
                'Cannot recover screenshot over a non-regular destination',
                image.path,
              );
            }
            for (final duplicate in await _findDeletionBackups(captureId)) {
              await _deleteOwnedEntry(duplicate);
            }
          } else {
            await _deleteOwnedEntry(image);
            for (final orphanedBackup in backups) {
              await _deleteOwnedEntry(orphanedBackup);
            }
          }
        }
      },
    );
  }

  Future<void> _restorePendingDeletionBackups(
    String captureId, {
    File? preferredBackup,
  }) async {
    final backups = await _findDeletionBackups(captureId);
    if (backups.isEmpty) return;
    final image = _imageFile(captureId);
    final imageType = await FileSystemEntity.type(
      image.path,
      followLinks: false,
    );
    if (imageType == FileSystemEntityType.notFound) {
      final preferredPath = preferredBackup?.path;
      final backup = preferredPath == null
          ? backups.first
          : backups.firstWhere(
              (candidate) => candidate.path == preferredPath,
              orElse: () => backups.first,
            );
      await _restoreDeletionBackup(backup, image);
    } else if (imageType != FileSystemEntityType.file) {
      throw FileSystemException(
        'Cannot roll back screenshot over a non-regular destination',
        image.path,
      );
    }
    for (final duplicate in await _findDeletionBackups(captureId)) {
      await _deleteOwnedEntry(duplicate);
    }
  }

  Future<({List<String> pending, List<String> committed})>
  _pendingDeletionBackupIds() async {
    if (!await _ensureRootDirectory(create: false)) {
      return (pending: const <String>[], committed: const <String>[]);
    }
    final pendingIds = <String>{};
    final committedIds = <String>{};
    await for (final entity in rootDirectory.list(followLinks: false)) {
      final name = _fileName(entity.path);
      final pendingMatch = _ownedDeletionBackupName.firstMatch(name);
      final committedMatch = _ownedCommittedDeletionBackupName.firstMatch(name);
      if (pendingMatch == null && committedMatch == null) continue;
      final imageName = pendingMatch?.group(1) ?? committedMatch!.group(1)!;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      final captureId = imageName.substring(
        0,
        imageName.length - '.png'.length,
      );
      if (pendingMatch != null && type == FileSystemEntityType.file) {
        pendingIds.add(captureId);
      } else if (pendingMatch != null && type == FileSystemEntityType.link) {
        throw FileSystemException(
          'Screenshot rollback entry is not a regular file',
          entity.path,
        );
      } else if (committedMatch != null &&
          (type == FileSystemEntityType.file ||
              type == FileSystemEntityType.link)) {
        committedIds.add(captureId);
      }
    }
    return (
      pending: pendingIds.toList()..sort(),
      committed: committedIds.toList()..sort(),
    );
  }

  @override
  Future<ScreenshotTranslationImageStats> inspect() async {
    if (!await _ensureRootDirectory(create: false)) {
      return ScreenshotTranslationImageStats.empty;
    }

    var imageCount = 0;
    var totalBytes = 0;
    final stagingCutoff = DateTime.now().subtract(_orphanedStagingFileAge);
    await for (final entity in rootDirectory.list(followLinks: false)) {
      final name = _fileName(entity.path);
      final isImage = _isOwnedImageName(name);
      final isStaging = _ownedStagingName.hasMatch(name);
      final deletionBackup = _ownedDeletionBackupName.firstMatch(name);
      final committedDeletionBackup = _ownedCommittedDeletionBackupName
          .hasMatch(name);
      if (!isImage &&
          !isStaging &&
          deletionBackup == null &&
          !committedDeletionBackup) {
        continue;
      }

      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (committedDeletionBackup) {
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.link) {
          continue;
        }
        try {
          await _deleteOwnedEntry(File(entity.path));
        } on Object {
          // Keep reporting residue so the settings page can show that local
          // cleanup still needs attention.
        }
        final remainingType = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (remainingType == FileSystemEntityType.notFound) continue;
        imageCount++;
        if (remainingType == FileSystemEntityType.file) {
          totalBytes += await File(entity.path).length();
        }
        continue;
      }
      if (deletionBackup != null) {
        if (type != FileSystemEntityType.file) continue;
        final destination = File(
          '${rootDirectory.path}${Platform.pathSeparator}${deletionBackup.group(1)}',
        );
        if (await FileSystemEntity.type(destination.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          // Keep the rollback copy until a history row explicitly reads it or
          // the user clears saved images. The store cannot know whether its
          // database callback committed before a process crash.
          imageCount++;
          totalBytes += await File(entity.path).length();
        }
        continue;
      }
      if (type != FileSystemEntityType.file) continue;

      final file = File(entity.path);
      if (isImage) {
        imageCount++;
        totalBytes += await file.length();
      } else if ((await file.lastModified()).isBefore(stagingCutoff)) {
        // The type was checked without following links, so this is the same
        // owned regular-file cleanup performed by _deleteOwnedEntry without a
        // second filesystem type lookup.
        await _deleteImage(file);
      }
    }
    return ScreenshotTranslationImageStats(
      imageCount: imageCount,
      totalBytes: totalBytes,
    );
  }

  @override
  Future<void> clearAll() => _coordinator.clearAll(_clearOwnedImages);

  Future<void> _clearOwnedImages() async {
    if (!await _ensureRootDirectory(create: false)) return;
    await for (final entity in rootDirectory.list(followLinks: false)) {
      if (_isOwnedImageOrStagingOrDeletionBackup(_fileName(entity.path))) {
        await _deleteOwnedEntry(File(entity.path));
      }
    }
  }

  Future<File?> _stageAndDeleteImage(File image) async {
    final type = await FileSystemEntity.type(image.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      final historyId = _fileName(image.path)
          .replaceFirst(RegExp(r'\.png$'), '');
      final backups = await _findDeletionBackups(historyId);
      return backups.isEmpty ? null : backups.first;
    }
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Screenshot image entry is not a regular file',
        image.path,
      );
    }

    final token =
        '$pid-${DateTime.now().microsecondsSinceEpoch}-${++_stagingSequence}';
    final backupPath = '${image.path}.$token.rollback';

    final backup = File(backupPath);
    await image.copy(backup.path);
    try {
      await _deleteImage(image);
    } catch (_) {
      try {
        final imageType = await FileSystemEntity.type(
          image.path,
          followLinks: false,
        );
        if ((imageType == FileSystemEntityType.notFound ||
                imageType == FileSystemEntityType.file) &&
            await backup.exists()) {
          // A failing filesystem hook may have partially modified the source.
          // Replace it from the staged copy rather than trusting its contents.
          await _atomicReplace(backup, image);
        }
      } on Object {
        // Preserve the staged copy if cleanup or recovery is unavailable.
      }
      rethrow;
    }
    return backup;
  }

  Future<bool> _ensureRootDirectory({required bool create}) async {
    var type = await FileSystemEntity.type(
      rootDirectory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound && create) {
      await rootDirectory.create(recursive: true);
      type = await FileSystemEntity.type(
        rootDirectory.path,
        followLinks: false,
      );
    }
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Screenshot image storage root is not a regular directory',
        rootDirectory.path,
      );
    }
    return true;
  }

  Future<File?> _findDeletionBackup(String historyId) async {
    final backups = await _findDeletionBackups(historyId);
    return backups.isEmpty ? null : backups.first;
  }

  Future<List<File>> _findDeletionBackups(String historyId) async {
    final expectedImageName = '$historyId.png';
    final backups = <File>[];
    if (!await _ensureRootDirectory(create: false)) return backups;
    await for (final entity in rootDirectory.list(followLinks: false)) {
      final match = _ownedDeletionBackupName.firstMatch(_fileName(entity.path));
      if (match?.group(1) != expectedImageName) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        backups.add(File(entity.path));
      } else if (type == FileSystemEntityType.link) {
        throw FileSystemException(
          'Screenshot rollback entry is not a regular file',
          entity.path,
        );
      }
    }
    return backups;
  }

  Future<List<File>> _findCommittedDeletionBackups(String historyId) async {
    final expectedImageName = '$historyId.png';
    final backups = <File>[];
    if (!await _ensureRootDirectory(create: false)) return backups;
    await for (final entity in rootDirectory.list(followLinks: false)) {
      final match = _ownedCommittedDeletionBackupName.firstMatch(
        _fileName(entity.path),
      );
      if (match?.group(1) != expectedImageName) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        backups.add(File(entity.path));
      } else if (type != FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Screenshot committed cleanup entry is not a file or link',
          entity.path,
        );
      }
    }
    return backups;
  }

  Future<List<File>> _findStagingFiles(String historyId) async {
    final expectedImageName = '$historyId.png';
    final stagingFiles = <File>[];
    if (!await _ensureRootDirectory(create: false)) return stagingFiles;
    await for (final entity in rootDirectory.list(followLinks: false)) {
      final match = _ownedStagingName.firstMatch(_fileName(entity.path));
      if (match?.group(1) != expectedImageName) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        stagingFiles.add(File(entity.path));
      } else if (type != FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Screenshot staging entry is not a file or link',
          entity.path,
        );
      }
    }
    return stagingFiles;
  }

  Future<bool> _hasDeletionBackup(String historyId) async {
    try {
      if (!await _ensureRootDirectory(create: false)) return false;
      final expectedImageName = '$historyId.png';
      await for (final entity in rootDirectory.list(followLinks: false)) {
        final name = _fileName(entity.path);
        final rollback = _ownedDeletionBackupName.firstMatch(name);
        final committed = _ownedCommittedDeletionBackupName.firstMatch(name);
        final staging = _ownedStagingName.firstMatch(name);
        if (rollback?.group(1) != expectedImageName &&
            committed?.group(1) != expectedImageName &&
            staging?.group(1) != expectedImageName) {
          continue;
        }
        if (await FileSystemEntity.type(entity.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return true;
        }
      }
      return false;
    } on Object {
      // A failed cleanup should still be reported as pending when a backup
      // cannot be safely inspected.
      return true;
    }
  }

  Future<void> _restoreDeletionBackup(File backup, File image) async {
    final imageType = await FileSystemEntity.type(
      image.path,
      followLinks: false,
    );
    if (imageType != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Cannot restore screenshot because its destination already exists',
        image.path,
      );
    }

    final backupType = await FileSystemEntity.type(
      backup.path,
      followLinks: false,
    );
    switch (backupType) {
      case FileSystemEntityType.file:
        await File(backup.path).rename(image.path);
      case FileSystemEntityType.link:
        await Link(backup.path).rename(image.path);
      case FileSystemEntityType.notFound:
        throw FileSystemException(
          'Screenshot rollback copy is missing',
          backup.path,
        );
      case FileSystemEntityType.directory:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        throw FileSystemException(
          'Screenshot rollback entry is not a regular file',
          backup.path,
        );
    }
  }

  Future<File> _markDeletionBackupCommitted(File backup) async {
    if (!_ownedDeletionBackupName.hasMatch(_fileName(backup.path))) {
      throw FileSystemException(
        'Screenshot rollback entry has an invalid name',
        backup.path,
      );
    }
    final type = await FileSystemEntity.type(backup.path, followLinks: false);
    final committedPath = backup.path.replaceFirst(
      RegExp(r'\.rollback$'),
      '.committed',
    );
    switch (type) {
      case FileSystemEntityType.file:
        await File(backup.path).rename(committedPath);
      case FileSystemEntityType.link:
        await Link(backup.path).rename(committedPath);
      case FileSystemEntityType.notFound:
        throw FileSystemException(
          'Screenshot rollback copy is missing',
          backup.path,
        );
      case FileSystemEntityType.directory:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        throw FileSystemException(
          'Screenshot rollback entry is not a regular file',
          backup.path,
        );
    }
    return File(committedPath);
  }

  Future<void> _deleteOwnedEntry(File image) async {
    switch (await FileSystemEntity.type(image.path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.file:
        await _deleteImage(image);
      case FileSystemEntityType.link:
        await Link(image.path).delete();
      case FileSystemEntityType.directory:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        throw FileSystemException(
          'Screenshot image entry is not a regular file',
          image.path,
        );
    }
  }

  File _imageFile(String historyId) {
    _validateHistoryId(historyId);
    return File('${rootDirectory.path}${Platform.pathSeparator}$historyId.png');
  }

  static void _validateHistoryId(String historyId) {
    if (historyId.length > _maxHistoryIdLength ||
        !_safeHistoryId.hasMatch(historyId)) {
      throw const FormatException('Invalid screenshot history ID');
    }
  }

  static bool _isOwnedImageName(String name) => _ownedImageName.hasMatch(name);

  static bool _isOwnedImageOrStagingFile(String name) =>
      _isOwnedImageName(name) || _ownedStagingName.hasMatch(name);

  static bool _isOwnedImageOrStagingOrDeletionBackup(String name) =>
      _isOwnedImageOrStagingFile(name) ||
      _ownedDeletionBackupName.hasMatch(name) ||
      _ownedCommittedDeletionBackupName.hasMatch(name);

  static String _fileName(String path) =>
      path.split(Platform.pathSeparator).last;

  static Future<void> _deleteFile(File image) => image.delete();

  static Future<void> _atomicReplace(File staged, File destination) async {
    if (!Platform.isWindows) {
      await staged.rename(destination.path);
      return;
    }

    // REPLACE_EXISTING | WRITE_THROUGH keeps a previous image intact when
    // replacement fails. The destination is never deleted before the move.
    final move = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final from = staged.path.toNativeUtf16();
    final to = destination.path.toNativeUtf16();
    try {
      if (move(from, to, 9) == 0) {
        throw FileSystemException(
          'Atomic screenshot image replacement failed',
          destination.path,
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }
}

final class _ScreenshotTranslationImageStoreCoordinator {
  int _clearGeneration = 0;
  Future<void> _clearBarrier = Future<void>.value();
  final Map<String, int> _imageGenerations = {};
  final Set<String> _deletedImageIds = {};
  final Map<String, Future<void>> _idTails = {};

  ScreenshotTranslationImageWriteLease beginImageWrite(String historyId) =>
      ScreenshotTranslationImageWriteLease._(
        historyId,
        this,
        _imageGenerations[historyId] ?? 0,
        _clearGeneration,
        _clearBarrier,
        !_deletedImageIds.contains(historyId),
      );

  bool accepts(ScreenshotTranslationImageWriteLease lease, String historyId) =>
      identical(lease._coordinator, this) &&
      lease.historyId == historyId &&
      lease._validAtCreation &&
      !_deletedImageIds.contains(historyId) &&
      lease._generation == (_imageGenerations[historyId] ?? 0) &&
      lease._clearGeneration == _clearGeneration;

  /// Invalidates captured writes synchronously, before waiting on the ID queue.
  Future<void> invalidateForDeletion(String historyId) {
    return invalidateForDeletions([historyId]).barrier;
  }

  ({Future<void> barrier, Map<String, int> generations}) invalidateForDeletions(
    Iterable<String> historyIds,
  ) {
    final generations = <String, int>{};
    for (final historyId in historyIds.toSet()) {
      _imageGenerations[historyId] = (_imageGenerations[historyId] ?? 0) + 1;
      generations[historyId] = _imageGenerations[historyId]!;
      _deletedImageIds.add(historyId);
    }
    return (barrier: _clearBarrier, generations: generations);
  }

  void cancelDeletions(Map<String, int> generations) {
    for (final entry in generations.entries) {
      // A newer deletion may already be queued for the same capture.
      if (_imageGenerations[entry.key] == entry.value) {
        _deletedImageIds.remove(entry.key);
      }
    }
  }

  Future<void> get clearBarrier => _clearBarrier;

  Future<T> runForId<T>(
    String historyId,
    Future<void> clearBarrier,
    Future<T> Function() operation,
  ) => runForIds([historyId], clearBarrier, operation);

  Future<T> runForIds<T>(
    List<String> historyIds,
    Future<void> clearBarrier,
    Future<T> Function() operation,
  ) {
    final ids = historyIds.toSet().toList()..sort();
    if (ids.isEmpty) return operation();
    final previous = ids
        .map((historyId) => _idTails[historyId] ?? Future<void>.value())
        .toSet()
        .toList(growable: false);
    final finished = Completer<void>();
    for (final historyId in ids) {
      _idTails[historyId] = finished.future;
    }
    return () async {
      try {
        for (final prior in previous) {
          await prior;
        }
        await clearBarrier;
        return await operation();
      } finally {
        if (!finished.isCompleted) finished.complete();
        for (final historyId in ids) {
          if (identical(_idTails[historyId], finished.future)) {
            _idTails.remove(historyId);
          }
        }
      }
    }();
  }

  Future<void> clearAll(Future<void> Function() clearFiles) {
    // This generation increment is the clear operation's linearization point.
    // Captures begun afterward receive the new barrier and may write only once
    // the clear has finished. Writes already queued are awaited and then erased.
    _clearGeneration++;
    final previousBarrier = _clearBarrier;
    final previousOperations = _idTails.values.toList(growable: false);
    final finished = Completer<void>();
    _clearBarrier = finished.future;

    return () async {
      try {
        await previousBarrier;
        await Future.wait(previousOperations);
        await clearFiles();
      } finally {
        if (!finished.isCompleted) finished.complete();
      }
    }();
  }
}
