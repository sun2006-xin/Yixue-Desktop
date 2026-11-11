import 'dart:convert';
import 'dart:io';

/// Joins a validated relative path to the user's app-data directory.
///
/// This intentionally rejects absolute paths and traversal segments so feature
/// storage cannot escape the configured local-data root.
String joinAppDataPath(String directoryPath, String relativePath) {
  final relative = relativePath.trim();
  if (relative.isEmpty ||
      relative.contains('\u0000') ||
      (Platform.isWindows
          ? RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(relative) ||
                relative.startsWith(r'\\')
          : relative.startsWith('/'))) {
    throw ArgumentError.value(relativePath, 'relativePath');
  }

  final segments = relative.split(RegExp(r'[\\/]'));
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw ArgumentError.value(relativePath, 'relativePath');
  }

  var joined = Directory(directoryPath).absolute.path;
  for (final segment in segments) {
    joined = '$joined${Platform.pathSeparator}$segment';
  }
  return joined;
}

String resolveAppDataPath({
  required String? configuredDirectory,
  String? storedDirectory,
  required String executablePath,
}) {
  final configured = configuredDirectory?.trim();
  if (configured != null && configured.isNotEmpty) return configured;
  final stored = storedDirectory?.trim();
  if (stored != null && stored.isNotEmpty) return stored;

  // Preview packages are versioned directories. Keep their state beside the
  // release root so launching a newer preview does not create a new database.
  final normalized = executablePath.replaceAll('/', '\\');
  final parts = normalized.split('\\');
  final releasesIndex = parts.indexWhere(
    (part) => part.toLowerCase() == 'releases',
  );
  final isPreviewPackage =
      releasesIndex >= 0 &&
      releasesIndex + 2 < parts.length &&
      parts[releasesIndex + 1].toLowerCase() == 'preview';
  if (isPreviewPackage) {
    final root = parts.take(releasesIndex).join('\\');
    if (root.isNotEmpty) {
      return '$root${Platform.pathSeparator}user-data';
    }
  }

  return '${File(executablePath).parent.path}${Platform.pathSeparator}user-data';
}

/// Keeps an implicit Windows Debug launch separate from release user data.
String isolatedDebugAppDataPath({
  required String tempDirectoryPath,
  required int processId,
}) =>
    '${Directory(tempDirectoryPath).absolute.path}${Platform.pathSeparator}'
    'Yixue-debug-$processId';

String resolveAppDataPreferenceFilePath({
  required String executablePath,
  String? configuredDirectory,
}) {
  final configured = configuredDirectory?.trim();
  if (configured != null && configured.isNotEmpty) {
    return '${Directory(configured).absolute.path}${Platform.pathSeparator}data-location.json';
  }
  final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
  if (Platform.isWindows && localAppData != null && localAppData.isNotEmpty) {
    return '${Directory(localAppData).absolute.path}${Platform.pathSeparator}Yixue${Platform.pathSeparator}data-location.json';
  }
  return '${File(executablePath).parent.path}${Platform.pathSeparator}.yixue-data-location.json';
}

class AppDataDirectoryPreferenceStore {
  const AppDataDirectoryPreferenceStore(this.file);

  static const _schemaVersion = 1;
  static const _maxFileBytes = 64 * 1024;
  static const _maxPathLength = 4096;

  final File file;

  Future<String?> read() async {
    try {
      if (!await file.exists() || await file.length() > _maxFileBytes) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != _schemaVersion) {
        return null;
      }
      return _normalizePath(decoded['dataDirectory']);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> write(String dataDirectory) async {
    final normalized = _normalizePath(dataDirectory);
    if (normalized == null) {
      throw const FormatException('data directory must be an absolute path');
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object>{
        'schemaVersion': _schemaVersion,
        'dataDirectory': normalized,
      }),
      flush: true,
    );
  }

  static String? _normalizePath(Object? rawPath) {
    if (rawPath is! String) return null;
    final path = rawPath.trim();
    if (path.isEmpty ||
        path.length > _maxPathLength ||
        path.contains('\u0000') ||
        !_isAbsolutePath(path)) {
      return null;
    }
    return Directory(path).absolute.path;
  }
}

bool _isAbsolutePath(String path) {
  if (Platform.isWindows) {
    return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
  }
  return path.startsWith('/');
}
