import 'dart:convert';
import 'dart:io';

abstract interface class SidebarPreferenceStore {
  Future<bool?> readSidebarExpanded();

  Future<void> writeSidebarExpanded(bool value);
}

class FileUiPreferenceStore implements SidebarPreferenceStore {
  FileUiPreferenceStore(this.file);

  final File file;

  @override
  Future<bool?> readSidebarExpanded() async {
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> || value['schemaVersion'] != 1) {
        return null;
      }
      return value['sidebarExpanded'] is bool
          ? value['sidebarExpanded'] as bool
          : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeSidebarExpanded(bool value) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'schemaVersion': 1, 'sidebarExpanded': value}),
      flush: true,
    );
  }
}
