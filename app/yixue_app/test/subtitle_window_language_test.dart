import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_window_view.dart';

void main() {
  testWidgets('subtitle window stays compact and shows the newest cue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final snapshot = _snapshot(
      cues: const <SubtitleWindowCue>[
        SubtitleWindowCue(
          cueId: 'english-1',
          sourceText: 'Good morning.',
          languageCode: 'en',
        ),
        SubtitleWindowCue(
          cueId: 'japanese-1',
          sourceText: 'おはようございます。',
          languageCode: 'ja',
        ),
        SubtitleWindowCue(
          cueId: 'unknown-1',
          sourceText: 'Unrecognized words stay visible.',
          languageCode: 'und',
          translationStatusLabel: '语种未识别，原文保留',
        ),
      ],
    );

    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleWindowView(
            snapshot: snapshot,
            onClose: () => closed = true,
          ),
        ),
      ),
    );

    expect(find.text('Unrecognized words stay visible.'), findsOneWidget);
    expect(find.text('语种未识别，原文保留'), findsOneWidget);
    expect(find.text('Good morning.'), findsNothing);
    expect(find.text('おはようございます'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('关闭字幕窗'));
    expect(closed, isTrue);
  });

  test('legacy subtitle-window JSON without cue language still decodes', () {
    final snapshot = SubtitleWindowSnapshot.fromJson(<String, Object?>{
      'schemaVersion': 1,
      'sessionId': 'legacy-session',
      'sessionKind': SubtitleSessionKind.meeting.name,
      'sessionStatus': SubtitleSessionStatus.capturing.name,
      'sourceKind': SubtitleAudioSourceKind.systemOutput.name,
      'sourceLabel': '会议音频',
      'sourceStatusLabel': '运行中',
      'sourceLanguageLabel': '英语',
      'targetLanguageLabel': '中文',
      'cues': <Object?>[
        <String, Object?>{
          'cueId': 'legacy-cue',
          'sourceText': 'Legacy subtitle.',
          'sourceIsFinal': true,
        },
      ],
    });

    expect(snapshot.cues.single.sourceText, 'Legacy subtitle.');
    expect(snapshot.cues.single.languageCode, isNull);
  });

  testWidgets('subtitle window settings can change accent and direction', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final selectedActions = <SubtitleWindowControlAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleWindowView(
            snapshot: _snapshot(
              cues: const <SubtitleWindowCue>[
                SubtitleWindowCue(
                  cueId: 'settings-cue',
                  sourceText: 'Good morning.',
                  translatedText: '早上好。',
                  languageCode: 'en',
                ),
              ],
            ),
            onControlAction: selectedActions.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('字幕设置'));
    await tester.pumpAndSettle();
    expect(find.text('字号'), findsOneWidget);
    expect(find.textContaining('反向'), findsOneWidget);

    final amberAccent = find.ancestor(
      of: find.text('琥珀'),
      matching: find.byType(ActionChip),
    );
    await tester.ensureVisible(amberAccent);
    await tester.pumpAndSettle();
    await tester.tap(amberAccent);
    expect(selectedActions.last, SubtitleWindowControlAction.colorAmber);
    final reverseDirection = find.textContaining('反向');
    final reverseDirectionChip = find.ancestor(
      of: reverseDirection,
      matching: find.byType(ActionChip),
    );
    await tester.ensureVisible(reverseDirectionChip);
    await tester.pumpAndSettle();
    await tester.tap(reverseDirectionChip);
    expect(selectedActions.last, SubtitleWindowControlAction.switchDirection);
  });
}

SubtitleWindowSnapshot _snapshot({required Iterable<SubtitleWindowCue> cues}) =>
    SubtitleWindowSnapshot(
      sessionId: 'language-window-session',
      sessionKind: SubtitleSessionKind.meeting,
      sessionStatus: SubtitleSessionStatus.capturing,
      sourceKind: SubtitleAudioSourceKind.systemOutput,
      sourceLabel: '会议音频',
      sourceStatusLabel: '正在识别',
      sourceLanguageLabel: '自动识别',
      targetLanguageLabel: '中文',
      cues: cues,
    );
