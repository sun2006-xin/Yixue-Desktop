import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_screenshot/screenshot.dart';

final class ScreenshotHotKey {
  const ScreenshotHotKey({
    this.keyCode = 0x7001c,
    this.modifiers = const ['control', 'alt'],
  });
  final int keyCode;
  final List<String> modifiers;
  PhysicalKeyboardKey get key => PhysicalKeyboardKey.findKeyByCode(keyCode)!;
  String get label => [
    ...modifiers.map(
      (v) => switch (v) {
        'control' => 'Ctrl',
        'alt' => 'Alt',
        'shift' => 'Shift',
        'meta' => 'Win',
        _ => v,
      },
    ),
    _physicalKeyboardKeyName(keyCode),
  ].join('+');
  Map<String, Object?> toJson() => {'keyCode': keyCode, 'modifiers': modifiers};
  factory ScreenshotHotKey.fromJson(Map value) {
    final code = value['keyCode'];
    final raw = value['modifiers'];
    const accepted = {'control', 'alt', 'shift', 'meta'};
    if (code is! int ||
        PhysicalKeyboardKey.findKeyByCode(code) == null ||
        raw is! List ||
        raw.isEmpty ||
        raw.any((v) => !accepted.contains(v))) {
      throw const FormatException('Invalid screenshot shortcut');
    }
    final key = PhysicalKeyboardKey.findKeyByCode(code)!;
    if ([
      PhysicalKeyboardKey.controlLeft,
      PhysicalKeyboardKey.controlRight,
      PhysicalKeyboardKey.altLeft,
      PhysicalKeyboardKey.altRight,
      PhysicalKeyboardKey.shiftLeft,
      PhysicalKeyboardKey.shiftRight,
      PhysicalKeyboardKey.metaLeft,
      PhysicalKeyboardKey.metaRight,
    ].contains(key)) {
      throw const FormatException('Shortcut must contain a non-modifier key');
    }
    return ScreenshotHotKey(
      keyCode: code,
      modifiers: List.unmodifiable(
        raw.cast<String>().toSet().toList()..sort(
          (a, b) => ['control', 'alt', 'shift', 'meta']
              .indexOf(a)
              .compareTo(['control', 'alt', 'shift', 'meta'].indexOf(b)),
        ),
      ),
    );
  }
  @override
  bool operator ==(Object other) =>
      other is ScreenshotHotKey &&
      keyCode == other.keyCode &&
      listEquals(modifiers, other.modifiers);
  @override
  int get hashCode => Object.hash(keyCode, Object.hashAll(modifiers));
}

/// Formats a USB HID physical key without relying on Flutter's debug names.
/// `PhysicalKeyboardKey.debugName` is intentionally null in release builds,
/// which otherwise leaves the global shortcut label ending in `+`.
String _physicalKeyboardKeyName(int usbHidUsage) {
  final page = usbHidUsage >> 16;
  final usage = usbHidUsage & 0xffff;
  if (page == 0x07) {
    if (usage >= 0x04 && usage <= 0x1d) {
      return String.fromCharCode(0x41 + usage - 0x04);
    }
    if (usage >= 0x1e && usage <= 0x27) {
      return '1234567890'[usage - 0x1e];
    }
    if (usage >= 0x3a && usage <= 0x45) {
      return 'F${usage - 0x3a + 1}';
    }
    if (usage >= 0x68 && usage <= 0x73) {
      return 'F${usage - 0x68 + 13}';
    }
    const names = <int, String>{
      0x28: 'Enter',
      0x29: 'Esc',
      0x2a: 'Backspace',
      0x2b: 'Tab',
      0x2c: 'Space',
      0x2d: '-',
      0x2e: '=',
      0x2f: '[',
      0x30: ']',
      0x31: r'\',
      0x32: '#',
      0x33: ';',
      0x34: "'",
      0x35: '`',
      0x36: ',',
      0x37: '.',
      0x38: '/',
      0x39: 'Caps Lock',
      0x46: 'Print Screen',
      0x47: 'Scroll Lock',
      0x48: 'Pause',
      0x49: 'Insert',
      0x4a: 'Home',
      0x4b: 'Page Up',
      0x4c: 'Delete',
      0x4d: 'End',
      0x4e: 'Page Down',
      0x4f: 'Right',
      0x50: 'Left',
      0x51: 'Down',
      0x52: 'Up',
      0x53: 'Num Lock',
      0x54: 'Numpad /',
      0x55: 'Numpad *',
      0x56: 'Numpad -',
      0x57: 'Numpad +',
      0x58: 'Numpad Enter',
      0x62: 'Numpad 0',
      0x63: 'Numpad .',
      0x65: 'Menu',
      0x67: 'Numpad =',
      0xe0: 'Left Ctrl',
      0xe1: 'Left Shift',
      0xe2: 'Left Alt',
      0xe3: 'Left Win',
      0xe4: 'Right Ctrl',
      0xe5: 'Right Shift',
      0xe6: 'Right Alt',
      0xe7: 'Right Win',
    };
    if (usage >= 0x59 && usage <= 0x61) {
      return 'Numpad ${usage - 0x59 + 1}';
    }
    final name = names[usage];
    if (name != null) return name;
  }
  return 'Key 0x${usbHidUsage.toRadixString(16).padLeft(8, '0')}';
}

/// Absolute Windows physical screen pixels; negative display origins are valid.
final class ScreenshotOrbPosition {
  const ScreenshotOrbPosition(this.x, this.y);
  final double x, y;
  Map<String, Object?> toJson() => {'x': x, 'y': y};
  @override
  bool operator ==(Object other) =>
      other is ScreenshotOrbPosition && x == other.x && y == other.y;
  @override
  int get hashCode => Object.hash(x, y);
}

final class ScreenshotTranslationPreferences {
  const ScreenshotTranslationPreferences({
    this.orbEnabled = true,
    this.saveScreenshotImages = true,
    this.hotKey = const ScreenshotHotKey(),
    this.orbPosition,
    this.pinnedRegion,
  });
  final bool orbEnabled;
  final bool saveScreenshotImages;
  final ScreenshotHotKey hotKey;
  final ScreenshotOrbPosition? orbPosition;
  final ScreenshotBounds? pinnedRegion;
  ScreenshotTranslationPreferences copyWith({
    bool? orbEnabled,
    bool? saveScreenshotImages,
    ScreenshotHotKey? hotKey,
    ScreenshotOrbPosition? orbPosition,
    ScreenshotBounds? pinnedRegion,
    bool clearPinnedRegion = false,
  }) => ScreenshotTranslationPreferences(
    orbEnabled: orbEnabled ?? this.orbEnabled,
    saveScreenshotImages: saveScreenshotImages ?? this.saveScreenshotImages,
    hotKey: hotKey ?? this.hotKey,
    orbPosition: orbPosition ?? this.orbPosition,
    pinnedRegion: clearPinnedRegion ? null : pinnedRegion ?? this.pinnedRegion,
  );
  Map<String, Object?> toJson() => {
    'schemaVersion': 3,
    'orbEnabled': orbEnabled,
    'saveScreenshotImages': saveScreenshotImages,
    'hotKey': hotKey.toJson(),
    'orbPosition': orbPosition?.toJson(),
    if (pinnedRegion case final region?)
      'pinnedRegion': {
        'left': region.left,
        'top': region.top,
        'width': region.width,
        'height': region.height,
      },
  };
  factory ScreenshotTranslationPreferences.fromJson(Map value) {
    final schemaVersion = value['schemaVersion'];
    if ((schemaVersion != 1 && schemaVersion != 2 && schemaVersion != 3) ||
        (value.containsKey('orbEnabled') && value['orbEnabled'] is! bool) ||
        (value.containsKey('saveScreenshotImages') &&
            value['saveScreenshotImages'] is! bool)) {
      throw const FormatException('Unsupported screenshot preference schema');
    }
    final position = value['orbPosition'];
    final rawRegion = value['pinnedRegion'];
    final hotKey = value['hotKey'];
    if (position != null &&
        (position is! Map ||
            position['x'] is! num ||
            position['y'] is! num ||
            !(position['x'] as num).isFinite ||
            !(position['y'] as num).isFinite)) {
      throw const FormatException('Invalid orb position');
    }
    if (hotKey != null && hotKey is! Map) {
      throw const FormatException('Invalid shortcut');
    }
    ScreenshotBounds? pinnedRegion;
    if (rawRegion != null) {
      if (rawRegion is! Map || rawRegion.length != 4) {
        throw const FormatException('Invalid pinned screenshot region');
      }
      final left = rawRegion['left'];
      final top = rawRegion['top'];
      final width = rawRegion['width'];
      final height = rawRegion['height'];
      const minCoordinate = -0x80000000;
      const maxCoordinate = 0x7fffffff;
      if (left is! int ||
          top is! int ||
          width is! int ||
          height is! int ||
          left < minCoordinate ||
          top < minCoordinate ||
          width < 1 ||
          height < 1 ||
          width > 32768 ||
          height > 32768 ||
          left + width > maxCoordinate ||
          top + height > maxCoordinate ||
          width * height > 20000000) {
        throw const FormatException('Invalid pinned screenshot region');
      }
      pinnedRegion = ScreenshotBounds(
        left: left,
        top: top,
        width: width,
        height: height,
      );
    }
    return ScreenshotTranslationPreferences(
      orbEnabled: value['orbEnabled'] as bool? ?? true,
      saveScreenshotImages: value['saveScreenshotImages'] as bool? ?? true,
      hotKey: hotKey == null
          ? const ScreenshotHotKey()
          : ScreenshotHotKey.fromJson(hotKey as Map),
      orbPosition: position == null
          ? null
          : ScreenshotOrbPosition(
              (position['x'] as num).toDouble(),
              (position['y'] as num).toDouble(),
            ),
      pinnedRegion: pinnedRegion,
    );
  }
  @override
  bool operator ==(Object other) =>
      other is ScreenshotTranslationPreferences &&
      orbEnabled == other.orbEnabled &&
      saveScreenshotImages == other.saveScreenshotImages &&
      hotKey == other.hotKey &&
      orbPosition == other.orbPosition &&
      pinnedRegion == other.pinnedRegion;
  @override
  int get hashCode => Object.hash(
    orbEnabled,
    saveScreenshotImages,
    hotKey,
    orbPosition,
    pinnedRegion,
  );
}

abstract interface class ScreenshotTranslationPreferencesStore {
  Future<ScreenshotTranslationPreferences> read();
  Future<void> write(ScreenshotTranslationPreferences value);
}

typedef ScreenshotPreferenceCommit = Future<void> Function(
  File staged,
  File destination,
);

/// Owns same-directory staging files only; never rewrites a file during load.
final class FileScreenshotTranslationPreferencesStore
    implements ScreenshotTranslationPreferencesStore {
  FileScreenshotTranslationPreferencesStore(
    this.file, {
    ScreenshotPreferenceCommit? commit,
  }) : _commit = commit ?? _atomicReplace;
  final File file;
  final ScreenshotPreferenceCommit _commit;
  Future<void> _tail = Future.value();
  Future<ScreenshotTranslationPreferences?> _readFile(File source) async {
    try {
      final raw = jsonDecode(await source.readAsString());
      return raw is Map ? ScreenshotTranslationPreferences.fromJson(raw) : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<ScreenshotTranslationPreferences> read() async =>
      await _readFile(file) ??
      await _readFile(File('${file.path}.backup')) ??
      const ScreenshotTranslationPreferences();
  @override
  Future<void> write(ScreenshotTranslationPreferences value) {
    final operation = _tail.then((_) => _write(value));
    _tail = operation.then((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _write(ScreenshotTranslationPreferences value) async {
    // Validate before touching disk, including finite physical coordinates.
    ScreenshotTranslationPreferences.fromJson(value.toJson());
    await file.parent.create(recursive: true);
    final token = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final staged = File('${file.path}.$token.pending');
    final backupStage = File('${file.path}.$token.backup.pending');
    try {
      await staged.writeAsString(jsonEncode(value.toJson()), flush: true);
      final previous = await _readFile(file);
      if (previous != null) {
        await backupStage.writeAsString(
          jsonEncode(previous.toJson()),
          flush: true,
        );
        await _commit(backupStage, File('${file.path}.backup'));
      }
      await _commit(staged, file);
    } finally {
      for (final owned in [staged, backupStage]) {
        if (await owned.exists()) await owned.delete();
      }
    }
  }

  static Future<void> _atomicReplace(File staged, File destination) async {
    if (!Platform.isWindows) {
      await staged.rename(destination.path);
      return;
    }
    // MoveFileEx(REPLACE_EXISTING|WRITE_THROUGH) keeps the old destination
    // intact on failure. Never delete the valid file before replacement.
    final move = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final from = staged.path.toNativeUtf16(),
        to = destination.path.toNativeUtf16();
    try {
      if (move(from, to, 9) == 0) {
        throw FileSystemException(
          'Atomic preference replacement failed',
          destination.path,
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }
}
