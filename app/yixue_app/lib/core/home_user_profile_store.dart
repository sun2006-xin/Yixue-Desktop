import 'dart:convert';
import 'dart:io';

import 'package:yixue_app/core/home_workbench.dart';

abstract interface class HomeUserProfileStore {
  Future<HomeUserProfileData?> read();

  Future<void> write(HomeUserProfileData profile);
}

class FileHomeUserProfileStore implements HomeUserProfileStore {
  FileHomeUserProfileStore(this.file);

  static const _maxFileBytes = 32 * 1024;

  final File file;

  @override
  Future<HomeUserProfileData?> read() async {
    try {
      if (!await file.exists() || await file.length() > _maxFileBytes) {
        return null;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      return HomeUserProfileData.fromJson(raw);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on JsonUnsupportedObjectError {
      return null;
    }
  }

  @override
  Future<void> write(HomeUserProfileData profile) async {
    final validated = HomeUserProfileData.fromJson(profile.toJson());
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(validated.toJson()), flush: true);
  }
}
