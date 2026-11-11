import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/shell/window_title_bar.dart';

class _FakeWindowActions implements WindowActions {
  var minimized = false;
  var maximized = false;
  var closed = false;

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> minimize() async => minimized = true;

  @override
  Future<void> toggleMaximize() async => maximized = true;
}

void main() {
  testWidgets('custom title bar exposes native window controls', (
    tester,
  ) async {
    final actions = _FakeWindowActions();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WindowTitleBar(actions: actions)),
      ),
    );

    expect(find.text('译学'), findsNothing);
    expect(find.byKey(const ValueKey('window-drag-area')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('window-minimize')));
    await tester.tap(find.byKey(const ValueKey('window-maximize')));
    await tester.tap(find.byKey(const ValueKey('window-close')));

    expect(actions.minimized, isTrue);
    expect(actions.maximized, isTrue);
    expect(actions.closed, isTrue);
  });

  testWidgets('reader back action is available independently of its toolbar', (
    tester,
  ) async {
    final actions = _FakeWindowActions();
    var returned = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowTitleBar(actions: actions, onBack: () => returned = true),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('reader-shell-return')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-shell-return')));
    expect(returned, isTrue);
  });
}
