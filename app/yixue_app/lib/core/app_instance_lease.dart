import 'dart:io';

import 'app_data_directory.dart';

/// Identifies an existing process that still owns the app-data lease.
///
/// Keeping this separate from generic filesystem failures lets startup explain
/// the real recovery action instead of suggesting a different data directory.
final class AppInstanceLeaseConflictException implements Exception {
  const AppInstanceLeaseConflictException();

  @override
  String toString() => 'The local Yixue data is in use by another process.';
}

bool isAppInstanceLeaseContention(Object error) {
  if (error is! FileSystemException) return false;
  return error.message.toLowerCase().contains('lock failed') &&
      error.osError?.errorCode == 33;
}

/// Holds the app-data root for the lifetime of one desktop application process.
///
/// The lock is intentionally non-blocking: a second process must not wait and
/// later start unexpectedly after the first process exits. On macOS Dart file
/// locks are process-scoped, so this lease must be acquired and retained by the
/// app's main isolate. Keep this lock file distinct from per-store operation
/// locks and do not open it through another handle while the lease is active.
final class AppInstanceLease {
  static AppInstanceLease? _processLease;

  AppInstanceLease._(this._handle);

  final RandomAccessFile _handle;
  var _closed = false;

  static bool get hasProcessLease => _processLease != null;

  /// Keeps [lease] alive until the application process exits.
  static void retainForProcessLifetime(AppInstanceLease lease) {
    final current = _processLease;
    if (current != null && !identical(current, lease)) {
      throw StateError('An app-data lease is already retained.');
    }
    _processLease = lease;
  }

  static Future<void> releaseAfterFailedLaunch(AppInstanceLease lease) async {
    if (identical(_processLease, lease)) _processLease = null;
    await lease.close();
  }

  /// Releases the process-retained lease when startup fails after the store
  /// has opened but before the main application is returned. Startup can be
  /// retried in the same process, so leaving this lock retained would make
  /// that retry look like a second application instance.
  static Future<void> releaseProcessLeaseAfterFailedLaunch() async {
    final lease = _processLease;
    if (lease == null) return;
    _processLease = null;
    await lease.close();
  }

  static Future<AppInstanceLease> acquire(Directory dataDirectory) async {
    await dataDirectory.create(recursive: true);
    final lockFile = File(
      joinAppDataPath(dataDirectory.absolute.path, '.yixue-instance.lock'),
    );
    final handle = await lockFile.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return AppInstanceLease._(handle);
    } catch (error) {
      await handle.close();
      if (isAppInstanceLeaseContention(error)) {
        throw const AppInstanceLeaseConflictException();
      }
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _handle.unlock();
    } on FileSystemException {
      // Closing the handle below still releases the lock.
    }
    await _handle.close();
  }
}
