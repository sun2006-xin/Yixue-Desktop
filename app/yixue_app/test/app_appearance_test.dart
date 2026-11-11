import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/app_appearance.dart';

void main() {
  test('appearance defaults to the vitality official theme', () {
    final controller = AppearanceController();

    expect(controller.value.officialTheme, YixueOfficialTheme.vitality);
    expect(controller.value.motionLevel, YixueMotionLevel.full);
    expect(
      controller.value.styleFor(YixueWorkspace.reader),
      YixueVisualStyle.vitality,
    );
  });

  test('official theme changes preserve the motion choice', () {
    final controller = AppearanceController();
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setMotionLevel(YixueMotionLevel.reduced);
    controller.setOfficialTheme(YixueOfficialTheme.light);

    expect(controller.value.officialTheme, YixueOfficialTheme.light);
    expect(controller.value.motionLevel, YixueMotionLevel.reduced);
    expect(notifications, 2);
  });

  test('workspace style can override and then resume the global style', () {
    final controller = AppearanceController();

    controller.setWorkspaceStyle(YixueWorkspace.reader, YixueVisualStyle.focus);
    expect(
      controller.value.styleFor(YixueWorkspace.reader),
      YixueVisualStyle.focus,
    );
    expect(
      controller.value.styleFor(YixueWorkspace.learning),
      YixueVisualStyle.vitality,
    );

    controller.setWorkspaceStyle(YixueWorkspace.reader, null);
    expect(
      controller.value.styleFor(YixueWorkspace.reader),
      YixueVisualStyle.vitality,
    );
  });

  test('setting the same appearance value does not notify listeners', () {
    final controller = AppearanceController();
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setOfficialTheme(YixueOfficialTheme.vitality);
    controller.setMotionLevel(YixueMotionLevel.full);
    controller.setWorkspaceStyle(YixueWorkspace.home, null);

    expect(notifications, 0);
  });

  test(
    'custom theme tokens round-trip through the local preference store',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-theme-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      const spec = CustomThemeSpec(
        name: '清晨纸页',
        background: Color(0xFFF4F8FA),
        surface: Color(0xFFFFFFFF),
        accent: Color(0xFF2678D9),
        outline: Color(0xFFD5E0E8),
        sidebarTop: Color(0xFF163C56),
        sidebarBottom: Color(0xFF2B8D83),
        sidebarForeground: Color(0xFFFFFFFF),
        sidebarGlow: Color(0xFF7AE0B2),
        selectedStart: Color(0xFF2678D9),
        selectedEnd: Color(0xFF42C98B),
        topStart: Color(0xFF163C56),
        topEnd: Color(0xFF236A78),
        topForeground: Color(0xFFFFFFFF),
        topBorder: Color(0xFF62BBD0),
        fontFamily: '霞鹜文楷',
        backgroundImagePath: 'D:\\Themes\\morning.png',
        statusBarColor: Color(0xFF174A63),
      );
      final store = FileAppearancePreferenceStore(
        File('${directory.path}\\appearance.json'),
      );
      final controller = AppearanceController();
      controller.setCustomTheme(spec);
      controller.setMotionLevel(YixueMotionLevel.reduced);
      await store.write(controller.value);

      final restored = await store.read();
      expect(restored?.customTheme?.name, '清晨纸页');
      expect(restored?.customTheme?.accent, spec.accent);
      expect(restored?.customTheme?.fontFamily, spec.fontFamily);
      expect(
        restored?.customTheme?.backgroundImagePath,
        spec.backgroundImagePath,
      );
      expect(restored?.customTheme?.statusBarColor, spec.statusBarColor);
      expect(restored?.motionLevel, YixueMotionLevel.reduced);
    },
  );

  test(
    'appearance preference store preserves per-page visual styles',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-style-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileAppearancePreferenceStore(
        File('${directory.path}\\appearance.json'),
      );
      final controller = AppearanceController();
      controller.setWorkspaceStyle(
        YixueWorkspace.reader,
        YixueVisualStyle.focus,
      );
      controller.setWorkspaceStyle(
        YixueWorkspace.home,
        YixueVisualStyle.vitality,
      );
      await store.write(controller.value);

      final restored = await store.read();
      expect(restored?.styleFor(YixueWorkspace.reader), YixueVisualStyle.focus);
      expect(
        restored?.styleFor(YixueWorkspace.home),
        YixueVisualStyle.vitality,
      );
    },
  );

  test('older custom theme packages use safe defaults for new fields', () {
    final json = <String, dynamic>{
      'schemaVersion': 1,
      'name': '旧主题包',
      'colors': <String, String>{
        'background': '#F4F8FA',
        'surface': '#FFFFFF',
        'accent': '#2678D9',
        'outline': '#D5E0E8',
        'sidebarTop': '#163C56',
        'sidebarBottom': '#2B8D83',
        'sidebarForeground': '#FFFFFF',
        'sidebarGlow': '#7AE0B2',
        'selectedStart': '#2678D9',
        'selectedEnd': '#42C98B',
        'topStart': '#163C56',
        'topEnd': '#236A78',
        'topForeground': '#FFFFFF',
        'topBorder': '#62BBD0',
      },
    };

    final spec = CustomThemeSpec.fromJson(json);
    expect(spec.fontFamily, 'Microsoft YaHei UI');
    expect(spec.backgroundImagePath, isNull);
    expect(spec.statusBarColor, spec.topStart);
  });
}
