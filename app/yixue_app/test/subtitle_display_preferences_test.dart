import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_display_preferences.dart';

void main() {
  test('legacy preferences use the default accent color', () {
    final preferences = SubtitleDisplayPreferences.fromJson(<String, dynamic>{
      'schemaVersion': 1,
      'mode': SubtitleDisplayMode.translatedOnly.name,
      'fontScale': SubtitleFontScale.large.name,
      'highContrast': false,
      'windowOpacity': 0.72,
    });

    expect(preferences.mode, SubtitleDisplayMode.translatedOnly);
    expect(preferences.colorPreset, SubtitleColorPreset.ice);
  });

  test('color preference persists through the local file store', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-subtitle-display-preferences-',
    );
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final store = FileSubtitleDisplayPreferencesStore(
      File('${directory.path}${Platform.pathSeparator}display.json'),
    );

    await store.write(
      const SubtitleDisplayPreferences(
        colorPreset: SubtitleColorPreset.mint,
        fontScale: SubtitleFontScale.large,
      ),
    );
    final restored = await store.read();

    expect(restored.colorPreset, SubtitleColorPreset.mint);
    expect(restored.fontScale, SubtitleFontScale.large);
  });
}
