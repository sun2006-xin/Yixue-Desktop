import 'dart:convert';
import 'dart:io';

class LocalDataExportResult {
  const LocalDataExportResult({required this.destination, required this.files});

  final Directory destination;
  final List<String> files;
}

class LocalDataExportService {
  const LocalDataExportService._();

  static const _exportableFiles = <String>[
    'yixue.db',
    'appearance-preferences.json',
    'translation-preferences.json',
    'translation-terminology.json',
    'ui-preferences.json',
    'dictionary-preferences.json',
    'home-plan.json',
    'home-daily-plans.json',
    'home-focus-session.json',
    'home-user-profile.json',
    'learning-workspace.json',
    'learning-textbooks.json',
    'storage-policy.json',
  ];

  static Future<LocalDataExportResult> export({
    required Directory source,
    required Directory destinationParent,
    DateTime Function()? clock,
  }) async {
    final sourceDirectory = source.absolute;
    final targetParent = destinationParent.absolute;
    if (!_isSafeDestination(sourceDirectory, targetParent)) {
      throw const FormatException('导出位置不能位于译学资料库内部');
    }
    if (!await sourceDirectory.exists()) {
      throw const FileSystemException('译学资料库不存在');
    }
    await targetParent.create(recursive: true);

    final timestamp = (clock ?? DateTime.now)();
    final folderName =
        'yixue-data-export-${_stamp(timestamp)}-${timestamp.microsecond}';
    final destination = Directory(
      '${targetParent.path}${Platform.pathSeparator}$folderName',
    );
    await destination.create();

    final copied = <String>[];
    for (final name in _exportableFiles) {
      final sourceFile = File(
        '${sourceDirectory.path}${Platform.pathSeparator}$name',
      );
      if (!await sourceFile.exists()) continue;
      await sourceFile.copy(
        '${destination.path}${Platform.pathSeparator}$name',
      );
      copied.add(name);
    }
    await File(
      '${destination.path}${Platform.pathSeparator}export-manifest.json',
    ).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schemaVersion': 1,
        'product': '译学',
        'exportedFiles': copied,
        'excluded': ['模型权重与运行时缓存', '系统安全存储中的 API 密钥', '临时文件与日志'],
        'restoreNote': '这是用户数据备份；恢复前请关闭译学，并不要覆盖正在使用的数据库。',
      })}\n',
      flush: true,
    );
    return LocalDataExportResult(
      destination: destination,
      files: List.unmodifiable(copied),
    );
  }

  static bool _isSafeDestination(Directory source, Directory targetParent) {
    final sourcePath = _normalized(source.path);
    final targetPath = _normalized(targetParent.path);
    final separator = Platform.pathSeparator;
    return targetPath != sourcePath &&
        !targetPath.startsWith('$sourcePath$separator');
  }

  static String _normalized(String path) => path
      .replaceAll('/', '\\')
      .replaceFirst(RegExp(r'[\\]+$'), '')
      .toLowerCase();

  static String _stamp(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}'
      '${value.month.toString().padLeft(2, '0')}'
      '${value.day.toString().padLeft(2, '0')}-'
      '${value.hour.toString().padLeft(2, '0')}'
      '${value.minute.toString().padLeft(2, '0')}'
      '${value.second.toString().padLeft(2, '0')}';
}
