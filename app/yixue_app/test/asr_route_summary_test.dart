import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/asr_route_summary.dart';

void main() {
  testWidgets('shows the active English and Chinese streaming route', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AsrRouteSummary(
            sourceLanguageLabel: '英语 · English',
            routeKind: AsrRouteKind.englishChineseStreaming,
            preparationState: AsrModelPreparationState.ready,
          ),
        ),
      ),
    );

    expect(find.text('本次识别将使用'), findsOneWidget);
    expect(find.text('当前原文：英语 · English'), findsOneWidget);
    expect(find.textContaining('英语、中文'), findsOneWidget);
    expect(find.textContaining('流式'), findsWidgets);
    expect(find.text('本地模型已就绪'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets(
    'shows the active multilingual segmented route and missing state',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AsrRouteSummary(
              sourceLanguageLabel: '日语 · 日本語',
              routeKind: AsrRouteKind.multilingualSegmented,
              preparationState: AsrModelPreparationState.notInstalled,
            ),
          ),
        ),
      );

      expect(find.textContaining('Whisper Tiny'), findsOneWidget);
      expect(
        find.textContaining('日语、韩语、西班牙语、法语、德语、葡萄牙语、俄语和自动识别'),
        findsOneWidget,
      );
      expect(find.text('当前原文：日语 · 日本語'), findsOneWidget);
      expect(find.text('识别模型未安装'), findsOneWidget);
      expect(find.textContaining('语音段'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    },
  );

  testWidgets(
    'keeps model preparation status explicit while checking or unknown',
    (tester) async {
      Future<void> pump(AsrModelPreparationState preparationState) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AsrRouteSummary(
                sourceLanguageLabel: '自动识别',
                routeKind: AsrRouteKind.multilingualSegmented,
                preparationState: preparationState,
              ),
            ),
          ),
        );
      }

      await pump(AsrModelPreparationState.checking);
      expect(find.text('正在检查本地模型'), findsOneWidget);

      await pump(AsrModelPreparationState.unknown);
      expect(find.text('模型状态未知'), findsOneWidget);
      expect(find.textContaining('重新检查'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    },
  );
}
