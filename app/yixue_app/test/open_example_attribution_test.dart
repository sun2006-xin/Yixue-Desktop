import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_cet_open_rich_examples_model.dart';
import 'package:yixue_app/features/learning/open_example_attribution.dart';

void main() {
  testWidgets(
    'Tatoeba attribution opens source links and labels missing authors',
    (tester) async {
      final openedUris = <Uri>[];
      const candidate = OpenCetRichExampleRow(
        exampleId: 'tatoeba:606530:1351367',
        sourceId: 'tatoeba_en_cmn',
        englishText: 'Take a small step forward.',
        chineseText: '向前迈出一小步。',
        englishUsername: r'\N',
        chineseUsername: '',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OpenExampleAttribution(
              candidate: candidate,
              onOpenUri: (uri) => openedUris.add(uri),
            ),
          ),
        ),
      );

      expect(find.text('英文作者未提供 · 中文作者未提供'), findsOneWidget);
      final licenseLink = find.byKey(const ValueKey('tatoeba-license-url'));
      final licenseRect = tester.getRect(licenseLink);
      expect(licenseRect.height, greaterThanOrEqualTo(44));
      final englishSourceLink = find.byKey(
        const ValueKey('tatoeba-source-606530'),
      );
      final chineseSourceLink = find.byKey(
        const ValueKey('tatoeba-source-1351367'),
      );
      expect(tester.getRect(englishSourceLink).top, licenseRect.top);
      expect(tester.getRect(chineseSourceLink).top, licenseRect.top);
      await tester.tap(licenseLink);
      await tester.tap(englishSourceLink);
      await tester.tap(chineseSourceLink);

      expect(openedUris, <Uri>[
        Uri.parse('https://creativecommons.org/licenses/by/2.0/fr/'),
        Uri.parse('https://tatoeba.org/en/sentences/show/606530'),
        Uri.parse('https://tatoeba.org/en/sentences/show/1351367'),
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('copies a Tatoeba URL if opening it fails', (tester) async {
    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    const candidate = OpenCetRichExampleRow(
      exampleId: 'tatoeba:606530:1351367',
      sourceId: 'tatoeba_en_cmn',
      englishText: 'Take a small step forward.',
      chineseText: '向前迈出一小步。',
      englishUsername: 'source-author',
      chineseUsername: 'translator',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OpenExampleAttribution(
            candidate: candidate,
            onOpenUri: (_) => throw StateError('browser unavailable'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('tatoeba-license-url')));
    await tester.pumpAndSettle();

    expect(copiedText, 'https://creativecommons.org/licenses/by/2.0/fr/');
    expect(find.text('链接已复制，可粘贴到浏览器打开。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
