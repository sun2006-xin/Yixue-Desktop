import 'dart:convert';
import 'dart:io';

import 'package:yixue_app/core/home_workbench.dart';

abstract interface class HomeFocusSessionStore {
  Future<HomeFocusSessionData?> read();

  Future<void> write(HomeFocusSessionData session);

  Future<void> clear();
}

class FileHomeFocusSessionStore implements HomeFocusSessionStore {
  FileHomeFocusSessionStore(this.file);

  static const _maxFileBytes = 32 * 1024;

  final File file;

  @override
  Future<HomeFocusSessionData?> read() async {
    try {
      if (!await file.exists() || await file.length() > _maxFileBytes) {
        return null;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      return HomeFocusSessionData.fromJson(raw);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on JsonUnsupportedObjectError {
      return null;
    }
  }

  @override
  Future<void> write(HomeFocusSessionData session) async {
    final validated = HomeFocusSessionData.fromJson(session.toJson());
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(validated.toJson()), flush: true);
  }

  @override
  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Clearing a missing or already-removed local session is idempotent.
    }
  }
}
