import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/features/brand/launch_gate.dart';

void main() {
  testWidgets('full launch reveals the brand before the workspace', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LaunchGate(
          motionLevel: YixueMotionLevel.full,
          child: ColoredBox(
            key: ValueKey('workspace-ready'),
            color: Colors.white,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('launch-overlay')), findsOneWidget);
    expect(find.byKey(const ValueKey('yixue-brand-mark')), findsOneWidget);
    expect(find.text('译学'), findsOneWidget);
    expect(find.text('让世界，可以理解'), findsOneWidget);
    expect(find.text('让世界，可以理解。'), findsNothing);
    final slogan = tester.widget<Text>(find.text('让世界，可以理解'));
    expect(slogan.style?.decoration, TextDecoration.none);
    final launchMark = tester.widget<SizedBox>(
      find.byKey(const ValueKey('launch-brand-mark')),
    );
    expect(launchMark.width, greaterThanOrEqualTo(280));
    expect(launchMark.height, greaterThanOrEqualTo(280));

    await tester.pump(const Duration(milliseconds: 2500));

    expect(find.byKey(const ValueKey('launch-overlay')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('yixue-brand-master-image')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 3200));

    expect(find.byKey(const ValueKey('launch-overlay')), findsNothing);
    expect(find.byKey(const ValueKey('workspace-ready')), findsOneWidget);
  });

  testWidgets('finishing the launch reveal keeps workspace state mounted', (
    tester,
  ) async {
    var initCount = 0;
    var disposeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LaunchGate(
          motionLevel: YixueMotionLevel.full,
          child: _LifecycleProbe(
            onInit: () => initCount++,
            onDispose: () => disposeCount++,
          ),
        ),
      ),
    );

    expect(initCount, 1);
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('workspace-ready')), findsOneWidget);
    expect(initCount, 1);
    expect(disposeCount, 0);
  });

  testWidgets('disabled launch enters the workspace immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LaunchGate(
          motionLevel: YixueMotionLevel.off,
          child: ColoredBox(
            key: ValueKey('workspace-ready'),
            color: Colors.white,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('launch-overlay')), findsNothing);
    expect(find.byKey(const ValueKey('workspace-ready')), findsOneWidget);
  });

  testWidgets('compact launch reveals the workspace without a long wait', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LaunchGate(
          motionLevel: YixueMotionLevel.full,
          variant: YixueLaunchVariant.compact,
          child: ColoredBox(
            key: ValueKey('workspace-ready'),
            color: Colors.white,
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 1900));

    expect(find.byKey(const ValueKey('launch-overlay')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1800));

    expect(find.byKey(const ValueKey('launch-overlay')), findsNothing);
  });

  testWidgets('reduced motion uses a 250 millisecond static reveal', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LaunchGate(
          motionLevel: YixueMotionLevel.reduced,
          child: ColoredBox(
            key: ValueKey('workspace-ready'),
            color: Colors.white,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('yixue-brand-master-image')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('launch-overlay')), findsNothing);
  });
}

class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe({required this.onInit, required this.onDispose});

  final VoidCallback onInit;
  final VoidCallback onDispose;

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

class _LifecycleProbeState extends State<_LifecycleProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(key: ValueKey('workspace-ready'), color: Colors.white);
}
