import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/yixue_app.dart';

void main() {
  testWidgets('desktop workspace content keeps the full available width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1706, 1066);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp(showLaunchAnimation: false));
    await tester.pump(const Duration(milliseconds: 300));

    // The app starts on Quick Translation, so navigate away and back to make
    // this a real workspace-switch regression check rather than an initial
    // layout-only check.
    await tester.tap(find.text('首页').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-primary-continue')), findsOneWidget);

    await tester.tap(find.text('快速翻译').first);
    await tester.pumpAndSettle();

    final header = find.byKey(const ValueKey('quick-translation-header'));
    expect(header, findsOneWidget);
    expect(tester.getSize(header).width, inInclusiveRange(500, 900));
    expect(
      find.byKey(const ValueKey('quick-translation-more-actions')),
      findsOneWidget,
    );
    expect(find.text('英语（自动检测）'), findsOneWidget);
    expect(find.text('中文（简体）'), findsOneWidget);
    final sourceEditor = find.byType(TextField).first;
    expect(tester.getSize(sourceEditor).width, greaterThanOrEqualTo(250));

    await tester.tap(find.text('阅读器').first);
    await tester.pumpAndSettle();

    final readerCard = find.byKey(const ValueKey('reader-placeholder-card'));
    expect(readerCard, findsOneWidget);
    expect(tester.getSize(readerCard).width, greaterThanOrEqualTo(400));
    expect(find.text('暂未接入'), findsOneWidget);

    await tester.tap(find.text('快速翻译').first);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(TextField).first).width,
      greaterThanOrEqualTo(250),
    );

    await tester.tap(find.text('截屏翻译').first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('screenshot-workbench-capture')),
      findsOneWidget,
    );

    await tester.tap(find.text('学习').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('learning-home-header')), findsOneWidget);

    await tester.tap(find.text('AI 同传').first);
    await tester.pumpAndSettle();
    expect(find.text('字幕资料库尚未启用。'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
