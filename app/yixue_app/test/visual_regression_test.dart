import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/yixue_app.dart';
import 'package:yixue_app/features/brand/brand_mark.dart';
import 'package:yixue_app/features/brand/launch_gate.dart';

void main() {
  testWidgets('Windows launch hold matches the approved pure brand surface', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: LaunchBrandSurface(progress: 0.57, reduced: false),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage(YixueBrandMark.assetPath),
        tester.element(find.byKey(const ValueKey('launch-overlay'))),
      );
    });
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('launch-overlay')),
      matchesGoldenFile('goldens/launch-overlay-v3.png'),
    );
  });

  testWidgets('Windows shell matches the approved sidebar proportions', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage(YixueBrandMark.assetPath),
        tester.element(find.byType(Scaffold)),
      );
    });
    await tester.pump();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/sidebar-shell-v3.png'),
    );
  });

  testWidgets('Windows workspace remains clean when the sidebar is hidden', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.byKey(const ValueKey('sidebar-collapse-button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage(YixueBrandMark.assetPath),
        tester.element(find.byType(Scaffold)),
      );
    });
    await tester.pump();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/sidebar-collapsed-v1.png'),
    );
  });

  testWidgets('Windows home dashboard matches the calm productivity layout', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(YixueApp(clock: () => DateTime(2026, 9, 15)));
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage(YixueBrandMark.assetPath),
        tester.element(find.byType(Scaffold)),
      );
    });
    await tester.pump();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/home-dashboard-v1.png'),
    );
  });
}
