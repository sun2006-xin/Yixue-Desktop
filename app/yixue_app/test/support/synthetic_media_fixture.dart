import 'dart:io';

const syntheticMediaFixtureMarker = '.yixue-media-smoke-fixture';

/// Accepts only the marked video emitted by the opt-in Windows smoke wrapper.
/// This makes a stale or manually supplied environment variable fail closed
/// instead of having a test read a user's recording.
bool isTrustedSyntheticMp4Fixture(String path) {
  if (!Platform.isWindows || path.trim().isEmpty) return false;

  try {
    final candidate = File(path).absolute;
    final parent = candidate.parent;
    final tempRoot = _normalizeWindowsPath(Directory.systemTemp.absolute.path);
    final parentPath = _normalizeWindowsPath(parent.path);
    final candidatePath = _normalizeWindowsPath(candidate.path);
    final fixtureDirectoryName = parentPath.split('\\').last;
    final scopedTempPrefix = '$tempRoot\\yixue-media-smoke-';
    final expectedPath = _normalizeWindowsPath(
      '${parent.path}\\synthetic-screen-recording.mp4',
    );

    if (!parentPath.startsWith(scopedTempPrefix) ||
        parentPath.substring(scopedTempPrefix.length).contains('\\') ||
        !fixtureDirectoryName.startsWith('yixue-media-smoke-') ||
        candidatePath != expectedPath ||
        FileSystemEntity.typeSync(parent.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(candidate.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return false;
    }

    final marker = File('${parent.path}\\$syntheticMediaFixtureMarker');
    return FileSystemEntity.typeSync(marker.path, followLinks: false) ==
            FileSystemEntityType.file &&
        marker.readAsStringSync() == 'YIXUE_SYNTHETIC_MEDIA_FIXTURE_V1';
  } on Object {
    return false;
  }
}

String _normalizeWindowsPath(String path) =>
    path.replaceAll('/', '\\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();
