import 'dart:typed_data';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_ocr_layout.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/core/translation_execution_route.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_result_window.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_workspace.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_window_entry.dart';

void main() {
  Future<void> showSourcePane(WidgetTester tester) async {
    final imageResultTab = find.text('OCR 原文');
    final textOnlyResultTab = find.text('原文');
    if (imageResultTab.evaluate().isNotEmpty) {
      await tester.tap(imageResultTab.first);
      await tester.pumpAndSettle();
    } else if (textOnlyResultTab.evaluate().isNotEmpty) {
      await tester.tap(textOnlyResultTab.first);
      await tester.pumpAndSettle();
    }
  }

  Future<void> showTranslationPane(WidgetTester tester) async {
    if (find.byType(TabBar).evaluate().isEmpty) return;
    final translationTab = find.text('译文');
    if (translationTab.evaluate().isEmpty) return;
    await tester.tap(translationTab.first);
    await tester.pumpAndSettle();
  }

  Future<void> expectSourceAndTranslation(
    WidgetTester tester, {
    required String source,
    required String translation,
  }) async {
    await showSourcePane(tester);
    expect(find.text(source), findsOneWidget);
    await showTranslationPane(tester);
    expect(find.text(translation), findsOneWidget);
    await showSourcePane(tester);
    expect(find.text(source), findsOneWidget);
  }

  test('screenshot OCR failures give actionable messages', () {
    expect(
      screenshotTranslationErrorMessage('ocr_timeout'),
      '本机 OCR 处理超时，请缩小截图区域后重试。',
    );
    expect(
      screenshotTranslationErrorMessage('ocr_output_limit'),
      '截图文字过多，请缩小选区或分段截图。',
    );
    expect(
      screenshotTranslationErrorMessage('ocr_unavailable'),
      '本机 OCR 未就绪，请检查 OCR 配置后重新截取。',
    );
    expect(
      screenshotTranslationErrorMessage('ocr_failed'),
      '本机 OCR 处理失败，请检查截图内容或 OCR 配置后重试。',
    );
  });

  testWidgets('empty screenshot result offers a first capture action', (
    tester,
  ) async {
    var captureCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: null,
          onCapture: () => captureCalls++,
          onRetranslate: (_) {},
          onHistory: () {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('开始截屏'), findsOneWidget);
    expect(find.text('点击“开始截屏”选择要翻译的区域。'), findsOneWidget);
    expect(find.text('重新截取'), findsNothing);

    await tester.tap(find.text('开始截屏'));
    expect(captureCalls, 1);
    expect(tester.takeException(), isNull);
  });

  group('result wordbook selection', () {
    testWidgets(
      'model word translation enters lookup history and survives reopening',
      (tester) async {
        final historyStore = _MemoryScreenshotLookupHistoryStore();

        Widget resultWindow() => MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: ScreenshotTranslationSession(
              id: 'model-trial-capture',
              recognizedText: 'hello world in a lesson',
              translatedText: '课堂中的你好世界',
              status: ScreenshotTranslationStatus.completed,
              imageBytes: Uint8List.fromList([1]),
            ),
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
            lookupHistoryStore: historyStore,
            onLookupDictionary: (_) async => null,
            onTranslateSelectedWord: (_, __) async => '你好',
          ),
        );

        await tester.pumpWidget(resultWindow());
        await showSourcePane(tester);
        await tester.tap(find.byType(TextField));
        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        tester
            .state<EditableTextState>(
              find.descendant(
                of: find.byType(TextField),
                matching: find.byType(EditableText),
              ),
            )
            .showToolbar();
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
        );
        await tester.pumpAndSettle();
        expect(find.text('模型试译 · 非词典释义'), findsOneWidget);
        expect(find.text('你好'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();

        final saved = await historyStore.read();
        expect(saved, hasLength(1));
        expect(saved.single.lookupQuery, 'hello');
        expect(saved.single.sourceContext, contains('hello'));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(resultWindow());
        await tester.pumpAndSettle();
        await showSourcePane(tester);
        await tester.tap(find.byTooltip('查词记录 1'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(ListTile).last);
        await tester.pumpAndSettle();

        expect(find.text('模型试译记录 · hello'), findsOneWidget);
        expect(find.text('模型试译结果 · 非词典释义'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('你好'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('hello world in a lesson'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('课堂中的你好世界'),
          ),
          findsOneWidget,
        );
        expect(find.text('词典释义'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'late word ACK cannot overwrite feedback for updated text in the same session',
      (tester) async {
        final pending = Completer<ScreenshotWordAddStatus>();
        Widget result(String text, String translation) => MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: ScreenshotTranslationSession(
              id: 'same-id',
              recognizedText: text,
              translatedText: translation,
              status: ScreenshotTranslationStatus.completed,
            ),
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
            onAddScreenshotWord: (_) => pending.future,
          ),
        );
        await tester.pumpWidget(result('hello context', '原译文'));
        await showSourcePane(tester);
        await tester.tap(find.byType(TextField));
        tester.widget<TextField>(find.byType(TextField)).controller!.selection =
            const TextSelection(baseOffset: 0, extentOffset: 5);
        await tester.pump();
        tester
            .state<EditableTextState>(
              find.descendant(
                of: find.byType(TextField),
                matching: find.byType(EditableText),
              ),
            )
            .showToolbar();
        await tester.pumpAndSettle();
        await tester.tap(find.text('加入截屏生词'));
        await tester.pump();
        await tester.pumpWidget(result('different context', '新译文'));
        pending.complete(ScreenshotWordAddStatus.added);
        await tester.pumpAndSettle();
        expect(find.text('已加入截屏生词'), findsNothing);
        expect(find.text('正在加入截屏生词…'), findsNothing);
        expect(find.text('different context'), findsOneWidget);
        expect(find.text('新译文'), findsOneWidget);
      },
    );

    Future<EditableTextState> showSelection(
      WidgetTester tester,
      String text,
      TextSelection selection, {
      Key key = const ValueKey('selected-result-window'),
      String sessionId = 'selected-session',
      String translatedText = '文章译文快照',
      ScreenshotTranslationStatus status =
          ScreenshotTranslationStatus.completed,
      Future<ScreenshotWordAddStatus> Function(ScreenshotWordRequest)? save,
      Future<ScreenshotDictionaryLookupResult?> Function(String)? lookup,
      ScreenshotDictionaryLookupHistoryStore? lookupHistoryStore,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            key: key,
            session: ScreenshotTranslationSession(
              id: sessionId,
              recognizedText: text,
              translatedText: translatedText,
              status: status,
              imageBytes: Uint8List.fromList([1]),
            ),
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
            onAddScreenshotWord:
                save ?? (_) async => ScreenshotWordAddStatus.added,
            onLookupDictionary: lookup,
            lookupHistoryStore: lookupHistoryStore,
          ),
        ),
      );
      await showSourcePane(tester);
      await tester.tap(find.byType(TextField));
      final field = tester.widget<TextField>(find.byType(TextField));
      field.controller!.selection = selection;
      await tester.pump();
      final editable = tester.state<EditableTextState>(
        find.descendant(
          of: find.byType(TextField),
          matching: find.byType(EditableText),
        ),
      );
      editable.showToolbar();
      await tester.pumpAndSettle();
      return editable;
    }

    testWidgets(
      'keeps a clear OCR lookup action visible and queries the selected term',
      (tester) async {
        String? requested;
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'persistent-lookup-action',
                recognizedText: '我正在学习语言',
                translatedText: 'I am learning a language.',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onLookupDictionary: (word) async {
                requested = word;
                return null;
              },
            ),
          ),
        );

        expect(find.text('选中 OCR 原文中的中文或英文词语，再点查释义。'), findsOneWidget);
        final lookupButton = find.byKey(
          const ValueKey('screenshot-source-dictionary-lookup'),
        );
        expect(find.text('选词查释义'), findsOneWidget);
        expect(tester.widget<TextButton>(lookupButton).onPressed, isNull);

        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 3,
          extentOffset: 5,
        );
        await tester.pump();
        expect(find.text('查询“学习”'), findsOneWidget);
        expect(tester.widget<TextButton>(lookupButton).onPressed, isNotNull);
        await tester.tap(lookupButton);
        await tester.pumpAndSettle();

        expect(requested, '学习');
        expect(find.text('本地词典暂未收录“学习”。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('offers model translation when the local dictionary misses', (
      tester,
    ) async {
      String? translatedWord;
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: const ScreenshotTranslationSession(
              id: 'model-word-fallback',
              recognizedText: 'hello world',
              translatedText: '你好世界',
              status: ScreenshotTranslationStatus.completed,
            ),
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
            onLookupDictionary: (_) async => null,
            onTranslateSelectedWord: (word, _) async {
              translatedWord = word;
              return '你好';
            },
          ),
        ),
      );

      final sourceField = tester.widget<TextField>(find.byType(TextField));
      sourceField.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
      );
      await tester.pumpAndSettle();
      final translateButton = find.byKey(
        const ValueKey('screenshot-model-word-translation'),
      );
      expect(translateButton, findsOneWidget);
      await tester.tap(translateButton);
      await tester.pumpAndSettle();

      expect(translatedWord, 'hello');
      expect(find.text('模型试译 · 非词典释义'), findsOneWidget);
      expect(find.text('你好'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a new OCR selection invalidates a pending dictionary miss fallback',
      (tester) async {
        final pendingLookup = Completer<ScreenshotDictionaryLookupResult?>();
        final historyStore = _MemoryScreenshotLookupHistoryStore();
        String? translatedWord;
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'pending-dictionary-selection-race',
                recognizedText: 'hello world',
                translatedText: '你好世界',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              lookupHistoryStore: historyStore,
              onLookupDictionary: (_) => pendingLookup.future,
              onTranslateSelectedWord: (word, _) async {
                translatedWord = word;
                return '不应显示的旧选词译文';
              },
            ),
          ),
        );

        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pump();

        // The lookup button may take focus and collapse the original range.
        // That is not a new user selection and must not cancel this request.
        sourceField.controller!.selection = const TextSelection.collapsed(
          offset: 5,
        );
        await tester.pump();
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 6,
          extentOffset: 11,
        );
        await tester.pump();

        pendingLookup.complete(null);
        await tester.pumpAndSettle();

        final staleFallback = find.byKey(
          const ValueKey('screenshot-model-word-translation'),
        );
        if (staleFallback.evaluate().isNotEmpty) {
          await tester.tap(staleFallback);
          await tester.pumpAndSettle();
        }
        expect(staleFallback, findsNothing);
        expect(translatedWord, isNull);
        expect(await historyStore.read(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'lookup button focus collapse keeps the pending dictionary lookup valid',
      (tester) async {
        final pendingLookup = Completer<ScreenshotDictionaryLookupResult?>();
        String? translatedWord;
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'pending-dictionary-focus-collapse',
                recognizedText: 'hello world',
                translatedText: '你好世界',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onLookupDictionary: (_) => pendingLookup.future,
              onTranslateSelectedWord: (word, _) async {
                translatedWord = word;
                return '你好';
              },
            ),
          ),
        );

        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pump();
        sourceField.controller!.selection = const TextSelection.collapsed(
          offset: 5,
        );
        await tester.pump();

        pendingLookup.complete(null);
        await tester.pumpAndSettle();
        expect(find.text('本地词典暂未收录“hello”。'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
        );
        await tester.pumpAndSettle();
        expect(translatedWord, 'hello');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'does not show a model result after the selected word changes',
      (tester) async {
        final translation = Completer<String>();
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'model-word-selection-race',
                recognizedText: 'hello world',
                translatedText: '你好世界',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onLookupDictionary: (_) async => null,
              onTranslateSelectedWord: (_, __) => translation.future,
            ),
          ),
        );

        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
        );
        await tester.pump();

        sourceField.controller!.selection = const TextSelection(
          baseOffset: 6,
          extentOffset: 11,
        );
        await tester.pump();
        expect(find.text('查询“world”'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();
        expect(find.text('本地词典暂未收录“world”。'), findsOneWidget);

        translation.complete('你好');
        await tester.pumpAndSettle();

        expect(find.text('模型试译 · 非词典释义'), findsNothing);
        expect(find.text('本地词典暂未收录“world”。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'selection change invalidates the old model translation action',
      (tester) async {
        final translation = Completer<String>();
        final cancellation = Completer<bool>();
        String? requestedOperationId;
        String? cancelledOperationId;
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'model-word-selection-only-race',
                recognizedText: 'hello world',
                translatedText: '你好世界',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onLookupDictionary: (_) async => null,
              onTranslateSelectedWord: (_, operationId) {
                requestedOperationId = operationId;
                return translation.future;
              },
              onCancelSelectedWordTranslation: (operationId) async {
                cancelledOperationId = operationId;
                return cancellation.future;
              },
            ),
          ),
        );

        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
        );
        await tester.pump();

        sourceField.controller!.selection = const TextSelection(
          baseOffset: 6,
          extentOffset: 11,
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
          findsNothing,
        );
        expect(requestedOperationId, isNotNull);
        expect(cancelledOperationId, requestedOperationId);
        expect(find.textContaining('正在请求停止旧试译'), findsOneWidget);
        cancellation.complete(true);
        await tester.pumpAndSettle();
        expect(find.text('旧试译已停止，请重新查词。'), findsOneWidget);

        translation.complete('你好');
        await tester.pumpAndSettle();

        expect(find.text('模型试译 · 非词典释义'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a refused cancellation feedback settles when the stale translation ends',
      (tester) async {
        final translation = Completer<String>();
        final cancellation = Completer<bool>();
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'model-word-cancel-refused',
                recognizedText: 'hello world',
                translatedText: '你好世界',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onLookupDictionary: (_) async => null,
              onTranslateSelectedWord: (_, __) => translation.future,
              onCancelSelectedWordTranslation: (_) => cancellation.future,
            ),
          ),
        );

        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
        );
        await tester.pump();

        sourceField.controller!.selection = const TextSelection(
          baseOffset: 6,
          extentOffset: 11,
        );
        await tester.pump();
        cancellation.complete(false);
        await tester.pumpAndSettle();
        expect(find.text('旧试译仍在处理中，完成后再查词。'), findsOneWidget);

        translation.complete('你好');
        await tester.pumpAndSettle();
        expect(find.text('旧试译已结束，请重新查词。'), findsOneWidget);
        expect(find.text('模型试译 · 非词典释义'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'a late refusal acknowledgement reports an already settled translation',
      (tester) async {
        final translation = Completer<String>();
        final cancellation = Completer<bool>();
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'model-word-cancel-ack-late',
                recognizedText: 'hello world',
                translatedText: '你好世界',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onLookupDictionary: (_) async => null,
              onTranslateSelectedWord: (_, __) => translation.future,
              onCancelSelectedWordTranslation: (_) => cancellation.future,
            ),
          ),
        );

        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
        );
        await tester.pump();
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 6,
          extentOffset: 11,
        );
        await tester.pump();

        translation.complete('你好');
        await tester.pumpAndSettle();
        cancellation.complete(false);
        await tester.pumpAndSettle();

        expect(find.text('旧试译已结束，请重新查词。'), findsOneWidget);
        expect(find.text('模型试译 · 非词典释义'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'a stale cancellation cannot replace feedback for a newer word lookup',
      (tester) async {
        final translation = Completer<String>();
        final cancellation = Completer<bool>();
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'model-word-new-lookup-wins',
                recognizedText: 'hello world',
                translatedText: '你好世界',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onLookupDictionary: (_) async => null,
              onTranslateSelectedWord: (_, __) => translation.future,
              onCancelSelectedWordTranslation: (_) => cancellation.future,
            ),
          ),
        );

        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
        );
        await tester.pump();
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 6,
          extentOffset: 11,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();

        cancellation.complete(false);
        translation.complete('你好');
        await tester.pumpAndSettle();

        expect(find.text('本地词典暂未收录“world”。'), findsOneWidget);
        expect(find.text('模型试译 · 非词典释义'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('model translation failure links to model settings', (
      tester,
    ) async {
      var settingsOpened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: const ScreenshotTranslationSession(
              id: 'model-word-provider-missing',
              recognizedText: 'hello world',
              translatedText: '你好世界',
              status: ScreenshotTranslationStatus.completed,
            ),
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
            onOpenModels: () => settingsOpened++,
            onLookupDictionary: (_) async => null,
            onTranslateSelectedWord: (_, __) async =>
                throw const ScreenshotWordRequestException(
                  'translation_unavailable',
                ),
          ),
        ),
      );

      final sourceField = tester.widget<TextField>(find.byType(TextField));
      sourceField.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('screenshot-model-word-translation')),
      );
      await tester.pumpAndSettle();

      final configure = find.byKey(
        const ValueKey('screenshot-word-open-model-settings'),
      );
      expect(configure, findsOneWidget);
      expect(
        find.byKey(const ValueKey('screenshot-model-word-translation')),
        findsNothing,
      );
      await tester.tap(configure);
      expect(settingsOpened, 1);
      expect(find.text('hello world'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'cancelled timed-out model translation explains how to continue',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: const ScreenshotTranslationSession(
                id: 'model-word-timeout-message',
                recognizedText: 'hello world',
                translatedText: '你好世界',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onLookupDictionary: (_) async => null,
              onTranslateSelectedWord: (_, __) async =>
                  throw const ScreenshotWordRequestException(
                    'translation_cancelled',
                  ),
            ),
          ),
        );
        final sourceField = tester.widget<TextField>(find.byType(TextField));
        sourceField.controller!.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('已请求停止上一次试译'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('screenshot-model-word-translation')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final errorCode in <String>[
      'translation_timeout',
      'translation_in_progress',
    ]) {
      testWidgets(
        'selected word $errorCode explains the pending request state',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: ScreenshotTranslationResultWindow(
                session: ScreenshotTranslationSession(
                  id: 'model-word-$errorCode',
                  recognizedText: 'hello world',
                  translatedText: '你好世界',
                  status: ScreenshotTranslationStatus.completed,
                ),
                onCapture: () {},
                onRetranslate: (_) {},
                onHistory: () {},
                onClose: () {},
                onLookupDictionary: (_) async => null,
                onTranslateSelectedWord: (_, __) async =>
                    throw ScreenshotWordRequestException(errorCode),
              ),
            ),
          );
          final sourceField = tester.widget<TextField>(find.byType(TextField));
          sourceField.controller!.selection = const TextSelection(
            baseOffset: 0,
            extentOffset: 5,
          );
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('screenshot-source-dictionary-lookup')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('screenshot-model-word-translation')),
          );
          await tester.pumpAndSettle();

          expect(find.textContaining('后台处理中'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('screenshot-model-word-translation')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'translation pane selection does not offer the screenshot wordbook action',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: ScreenshotTranslationSession(
                id: 'translation-only-word',
                recognizedText: 'hello context',
                translatedText: 'steady progress',
                status: ScreenshotTranslationStatus.completed,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
              onAddScreenshotWord: (_) async => ScreenshotWordAddStatus.added,
            ),
          ),
        );
        final translation = find.byType(SelectableText);
        final editable = find.descendant(
          of: translation,
          matching: find.byType(EditableText),
        );
        tester.widget<EditableText>(editable).controller.selection =
            const TextSelection(baseOffset: 0, extentOffset: 6);
        await tester.pump();
        tester.state<EditableTextState>(editable).showToolbar();
        await tester.pumpAndSettle();

        expect(find.text('加入截屏生词'), findsNothing);
      },
    );

    testWidgets(
      'keeps text comparison when OCR block identity is unavailable',
      (tester) async {
        final bytes = (await tester.runAsync(
          () => _previewPng(width: 640, height: 400),
        ))!;
        const layout = ScreenshotTranslationOcrLayout(
          imageWidth: 640,
          imageHeight: 400,
          sourceText: 'Heading\n\nBody text',
          blocks: [
            ScreenshotTranslationOcrBlock(
              text: 'Heading',
              left: 20,
              top: 30,
              width: 200,
              height: 40,
            ),
            ScreenshotTranslationOcrBlock(
              text: 'Body text',
              left: 20,
              top: 100,
              width: 300,
              height: 90,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: ScreenshotTranslationSession(
                id: 'layout-overlay',
                recognizedText: 'Heading\n\nBody text',
                translatedText: '标题\n\n正文翻译',
                status: ScreenshotTranslationStatus.completed,
                imageBytes: bytes,
                ocrLayout: layout,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('screenshot-result-window-overlay-toggle')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('screenshot-translation-overlay-block-0')),
          findsNothing,
        );
        expect(find.text('位置叠译不可用：无法与原图文字区域可靠对齐；仍可查看完整原文和译文。'), findsOneWidget);
        expect(find.text('文本对照'), findsOneWidget);
        expect(find.text('原图对照'), findsOneWidget);
        expect(find.text('原图位置叠译'), findsOneWidget);
        final modes = tester.widget<SegmentedButton<dynamic>>(
          find.byKey(const ValueKey('screenshot-comparison-mode')),
        );
        expect(
          modes.segments
              .singleWhere(
                (segment) => (segment.label as Text).data == '原图位置叠译',
              )
              .enabled,
          isFalse,
        );
        await tester.tap(find.text('文本对照'));
        await tester.pumpAndSettle();
        expect(find.text('标题\n\n正文翻译'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('screenshot-result-image-comparison-pane')),
          findsNothing,
        );
        expect(find.text('位置叠译不可用：无法与原图文字区域可靠对齐；仍可查看完整原文和译文。'), findsOneWidget);
        final sourceText = find.byWidgetPredicate(
          (widget) =>
              widget is EditableText &&
              widget.controller.text == 'Heading\n\nBody text',
        );
        expect(sourceText, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('offers spatial overlay only for validated OCR identities', (
      tester,
    ) async {
      final bytes = (await tester.runAsync(
        () => _previewPng(width: 640, height: 400),
      ))!;
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 640,
        imageHeight: 400,
        sourceText: 'Heading\n\nBody text',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'Heading',
            left: 20,
            top: 30,
            width: 200,
            height: 40,
          ),
          ScreenshotTranslationOcrBlock(
            text: 'Body text',
            left: 20,
            top: 100,
            width: 300,
            height: 90,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: ScreenshotTranslationSession(
              id: 'layout-overlay-aligned',
              recognizedText: 'Heading\n\nBody text',
              translatedText: '正文翻译\n\n标题',
              translatedSourceBlockIndices: const [1, 0],
              status: ScreenshotTranslationStatus.completed,
              imageBytes: bytes,
              ocrLayout: layout,
            ),
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('文本对照'), findsOneWidget);
      expect(find.text('原图对照'), findsOneWidget);
      expect(find.text('原图位置叠译'), findsOneWidget);
      expect(find.text('位置叠译不可用：无法与原图文字区域可靠对齐；仍可查看完整原文和译文。'), findsNothing);
      await tester.tap(find.text('文本对照'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('screenshot-result-image-comparison-pane')),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is EditableText &&
              widget.controller.text == 'Heading\n\nBody text',
        ),
        findsOneWidget,
      );
      expect(find.text('正文翻译\n\n标题'), findsOneWidget);
      await tester.tap(find.text('原图位置叠译'));
      await tester.pumpAndSettle();
      final headingOverlay = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byKey(
                const ValueKey('screenshot-translation-overlay-block-0'),
              ),
              matching: find.byType(Positioned),
            )
            .first,
      );
      final bodyOverlay = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byKey(
                const ValueKey('screenshot-translation-overlay-block-1'),
              ),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(headingOverlay.top, lessThan(bodyOverlay.top!));
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('screenshot-translation-overlay-block-0'),
          ),
          matching: find.text('标题'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('screenshot-translation-overlay-block-1'),
          ),
          matching: find.text('正文翻译'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('screenshot-translation-overlay-block-0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('原图位置对照'), findsOneWidget);
      expect(find.text('Heading'), findsOneWidget);
      expect(find.text('标题'), findsWidgets);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('隐藏叠译'), findsOneWidget);
      await tester.tap(find.text('隐藏叠译'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('screenshot-translation-overlay-block-0')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'long spatial translations clearly explain how to read the full text',
      (tester) async {
        final bytes = (await tester.runAsync(
          () => _previewPng(width: 640, height: 400),
        ))!;
        const layout = ScreenshotTranslationOcrLayout(
          imageWidth: 640,
          imageHeight: 400,
          sourceText: 'A short heading',
          blocks: [
            ScreenshotTranslationOcrBlock(
              text: 'A short heading',
              left: 20,
              top: 30,
              width: 140,
              height: 28,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ScreenshotTranslationResultWindow(
              session: ScreenshotTranslationSession(
                id: 'long-spatial-translation-guidance',
                recognizedText: 'A short heading',
                translatedText: '这是一个很长的译文，完整内容需要点击文字块后才能在对照窗口中阅读。',
                translatedSourceBlockIndices: const [0],
                status: ScreenshotTranslationStatus.completed,
                imageBytes: bytes,
                ocrLayout: layout,
              ),
              onCapture: () {},
              onRetranslate: (_) {},
              onHistory: () {},
              onClose: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('原图位置叠译'));
        await tester.pumpAndSettle();

        final overlayText = tester.widget<Text>(
          find.descendant(
            of: find.byKey(
              const ValueKey('screenshot-translation-overlay-block-0'),
            ),
            matching: find.byType(Text),
          ),
        );
        expect(overlayText.overflow, TextOverflow.ellipsis);
        expect(overlayText.maxLines, isNotNull);
        expect(
          find.byKey(
            const ValueKey('screenshot-result-overlay-full-text-hint'),
          ),
          findsOneWidget,
        );
        expect(find.text('译文可能省略 · 点按文字块查看全文'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'medium image comparison windows keep each reading pane full width',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bytes = (await tester.runAsync(
          () => _previewPng(width: 640, height: 400),
        ))!;

        for (final width in const [720.0, 900.0]) {
          await tester.binding.setSurfaceSize(Size(width, 720));
          await tester.pumpWidget(
            MaterialApp(
              home: ScreenshotTranslationResultWindow(
                session: ScreenshotTranslationSession(
                  id: 'medium-image-comparison-$width',
                  recognizedText: 'Source sentence for comparison',
                  translatedText: '用于对照阅读的译文句子',
                  status: ScreenshotTranslationStatus.completed,
                  imageBytes: bytes,
                ),
                onCapture: () {},
                onRetranslate: (_) {},
                onHistory: () {},
                onClose: () {},
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byType(TabBar),
            findsOneWidget,
            reason: 'comparison should use readable tabs at ${width}px',
          );
          await tester.tap(find.text('OCR 原文'));
          await tester.pumpAndSettle();
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is EditableText &&
                  widget.controller.text == 'Source sentence for comparison',
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('译文'));
          await tester.pumpAndSettle();
          expect(find.text('用于对照阅读的译文句子'), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );
    testWidgets('result preview decodes only bounded thumbnail dimensions', (
      tester,
    ) async {
      final bytes = (await tester.runAsync(
        () => _previewPng(width: 2000, height: 512),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: ScreenshotTranslationSession(
              id: 'bounded-preview',
              imageBytes: bytes,
              status: ScreenshotTranslationStatus.completed,
            ),
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      final resized = image.image as ResizeImage;
      expect(resized.width, 1600);
      expect(resized.height, 1200);
      expect(resized.policy, ResizeImagePolicy.fit);
      expect(
        find.byKey(const ValueKey('screenshot-result-image-comparison-pane')),
        findsOneWidget,
      );
      expect(find.text('原图对照'), findsOneWidget);
      await tester.tap(find.text('文本对照'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('screenshot-result-image-comparison-pane')),
        findsNothing,
      );
      await tester.tap(find.text('原图对照'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('screenshot-result-image-comparison-pane')),
        findsOneWidget,
      );

      final decoded = (await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: 1000,
          targetHeight: 256,
        );
        try {
          final frame = await codec.getNextFrame();
          final size = Size(
            frame.image.width.toDouble(),
            frame.image.height.toDouble(),
          );
          frame.image.dispose();
          return size;
        } finally {
          codec.dispose();
        }
      }))!;
      expect(decoded.width, 1000);
      expect(decoded.height, 256);
    });

    for (final word in ['hello', "don't", 'well-being']) {
      testWidgets(
        'offers selection-menu action for $word and sends text snapshots',
        (tester) async {
          ScreenshotWordRequest? saved;
          await showSelection(
            tester,
            '$word context',
            TextSelection(baseOffset: 0, extentOffset: word.length),
            save: (request) async {
              saved = request;
              return ScreenshotWordAddStatus.added;
            },
          );
          expect(find.text('加入截屏生词'), findsOneWidget);
          await tester.tap(find.text('加入截屏生词'));
          await tester.pumpAndSettle();
          expect(saved!.word, word);
          expect(saved!.recognizedText, '$word context');
          expect(saved!.translatedText, '文章译文快照');
          expect(saved!.sessionId, 'selected-session');
          expect(saved!.historyEntryId, 'selected-session');
          expect(saved!.toPayload().containsKey('imageBytes'), isFalse);
          expect(find.text('已加入截屏生词'), findsOneWidget);
          await expectSourceAndTranslation(
            tester,
            source: '$word context',
            translation: '文章译文快照',
          );
        },
      );
    }

    testWidgets(
      'offers Chinese word lookup without offering English wordbook',
      (tester) async {
        String? requested;
        await showSelection(
          tester,
          '我正在学习语言',
          const TextSelection(baseOffset: 3, extentOffset: 5),
          lookup: (word) async {
            requested = word;
            return null;
          },
        );

        expect(find.text('查词释义'), findsOneWidget);
        expect(find.text('加入截屏生词'), findsNothing);
        await tester.tap(find.text('查词释义'));
        await tester.pumpAndSettle();
        expect(requested, '学习');
        expect(find.text('本地词典暂未收录“学习”。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('keeps an in-window lookup history with its OCR context', (
      tester,
    ) async {
      const dictionaryEntry = ScreenshotDictionaryLookupResult(
        word: '学习',
        ipa: '',
        partOfSpeech: '动词',
        meanings: ['获得知识'],
        example: '',
        exampleTranslation: '',
        qualityStatus: 'verified',
        examples: [],
      );
      await showSelection(
        tester,
        '我正在学习语言',
        const TextSelection(baseOffset: 3, extentOffset: 5),
        translatedText: 'I am learning a language.',
        lookup: (_) async => dictionaryEntry,
      );
      await tester.tap(find.text('查词释义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('查词记录 1'), findsOneWidget);
      await tester.tap(find.byTooltip('查词记录 1'));
      await tester.pumpAndSettle();
      expect(find.text('我正在学习语言'), findsOneWidget);
      expect(find.text('译文快照：I am learning a language.'), findsOneWidget);
      expect(
        find.text('保留最近 24 条跨截图查词记录，直到关闭本浮窗；原文片段和译文均为查词时快照，未做词句级对齐。'),
        findsOneWidget,
      );
      await tester.tap(find.text('学习').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('词典释义'));
      await tester.pumpAndSettle();
      expect(find.text('• 获得知识'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lookup history keeps the selected occurrence context', (
      tester,
    ) async {
      const dictionaryEntry = ScreenshotDictionaryLookupResult(
        word: '学习',
        ipa: '',
        partOfSpeech: '动词',
        meanings: ['获得知识'],
        example: '',
        exampleTranslation: '',
        qualityStatus: 'verified',
        examples: [],
      );
      final source =
          '早期学习${List<String>.filled(60, '前').join()}晚期学习${List<String>.filled(60, '后').join()}';
      final selectedStart = source.lastIndexOf('学习');
      await showSelection(
        tester,
        source,
        TextSelection(
          baseOffset: selectedStart,
          extentOffset: selectedStart + 2,
        ),
        translatedText: 'translation snapshot',
        lookup: (_) async => dictionaryEntry,
      );
      await tester.tap(find.text('查词释义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查词记录 1'));
      await tester.pumpAndSettle();

      final context = tester.widget<Text>(find.textContaining('原文片段：'));
      expect(context.data, contains('晚期学习'));
      expect(context.data, isNot(contains('早期学习')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('dictionary lookup remains available when translation fails', (
      tester,
    ) async {
      String? requested;
      await showSelection(
        tester,
        'hello world',
        const TextSelection(baseOffset: 0, extentOffset: 5),
        status: ScreenshotTranslationStatus.failed,
        lookup: (word) async {
          requested = word;
          return null;
        },
      );

      expect(find.text('查词释义'), findsOneWidget);
      await tester.tap(find.text('查词释义'));
      await tester.pumpAndSettle();

      expect(requested, 'hello');
      expect(find.text('本地词典暂未收录“hello”。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lookup history opens complete OCR and translation snapshots', (
      tester,
    ) async {
      const dictionaryEntry = ScreenshotDictionaryLookupResult(
        word: 'language',
        ipa: '',
        partOfSpeech: '名词',
        meanings: ['语言'],
        example: '',
        exampleTranslation: '',
        qualityStatus: 'verified',
        examples: [],
      );
      final source =
          'Start ${List<String>.filled(22, 'language').join(' ')} End';
      final translation = List<String>.filled(8, '完整译文快照。').join();

      await showSelection(
        tester,
        source,
        const TextSelection(baseOffset: 6, extentOffset: 14),
        translatedText: translation,
        lookup: (_) async => dictionaryEntry,
      );
      await tester.tap(find.text('查词释义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查词记录 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('language').first);
      await tester.pumpAndSettle();

      final recordDetails = find.byType(AlertDialog).last;
      await tester.drag(
        find
            .descendant(of: recordDetails, matching: find.byType(ListView))
            .last,
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: recordDetails,
          matching: find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == source,
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('完整译文快照'), findsOneWidget);
      expect(
        find.descendant(
          of: recordDetails,
          matching: find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == translation,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('lookup history shows the queried form beside its headword', (
      tester,
    ) async {
      const dictionaryEntry = ScreenshotDictionaryLookupResult(
        word: 'run',
        ipa: '/rʌn/',
        partOfSpeech: '动词',
        meanings: ['跑'],
        example: '',
        exampleTranslation: '',
        qualityStatus: 'verified',
        examples: [],
      );

      await showSelection(
        tester,
        'running fast',
        const TextSelection(baseOffset: 0, extentOffset: 7),
        lookup: (_) async => dictionaryEntry,
      );
      await tester.tap(find.text('查词释义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查词记录 1'));
      await tester.pumpAndSettle();

      expect(find.text('running'), findsOneWidget);
      expect(find.text('词头：run · 动词'), findsOneWidget);
      await tester.tap(find.text('running'));
      await tester.pumpAndSettle();
      expect(find.text('查词记录 · running'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps recent lookup context when a new screenshot arrives', (
      tester,
    ) async {
      const dictionaryEntry = ScreenshotDictionaryLookupResult(
        word: '学习',
        ipa: '',
        partOfSpeech: '动词',
        meanings: ['获得知识'],
        example: '',
        exampleTranslation: '',
        qualityStatus: 'verified',
        examples: [],
      );
      const resultKey = ValueKey('same-result-window');
      await showSelection(
        tester,
        '我正在学习语言',
        const TextSelection(baseOffset: 3, extentOffset: 5),
        key: resultKey,
        sessionId: 'first-capture',
        translatedText: 'I am learning a language.',
        lookup: (_) async => dictionaryEntry,
      );
      await tester.tap(find.text('查词释义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('查词记录 1'), findsOneWidget);

      await showSelection(
        tester,
        '新的截图原文',
        const TextSelection(baseOffset: 0, extentOffset: 2),
        key: resultKey,
        sessionId: 'second-capture',
        lookup: (_) async => dictionaryEntry,
      );

      expect(find.byTooltip('查词记录 1'), findsOneWidget);
      await tester.tap(find.byTooltip('查词记录 1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('原文片段：我正在学习语言'), findsOneWidget);
      expect(find.text('译文快照：I am learning a language.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final text in [
      'hello world',
      'hello!',
      'foo--bar',
      List.filled(33, 'a').join(),
      '',
    ]) {
      testWidgets('invalid selection $text does not offer wordbook action', (
        tester,
      ) async {
        await showSelection(
          tester,
          text,
          TextSelection(baseOffset: 0, extentOffset: text.length),
        );
        expect(find.text('加入截屏生词'), findsNothing);
      });
    }
    testWidgets(
      'collapsed caret inside a word does not offer wordbook action',
      (tester) async {
        await showSelection(
          tester,
          'hello context',
          const TextSelection.collapsed(offset: 2),
        );
        expect(find.text('加入截屏生词'), findsNothing);
      },
    );

    for (final status in [
      ScreenshotWordAddStatus.alreadyExists,
      ScreenshotWordAddStatus.meaningPending,
    ]) {
      testWidgets('displays precise $status feedback and keeps content', (
        tester,
      ) async {
        await showSelection(
          tester,
          'hello context',
          const TextSelection(baseOffset: 0, extentOffset: 5),
          save: (_) async => status,
        );
        await tester.tap(find.text('加入截屏生词'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            status == ScreenshotWordAddStatus.alreadyExists
                ? '该词已在截屏生词中'
                : '已加入截屏生词 · 尚未填写释义',
          ),
          findsOneWidget,
        );
        await expectSourceAndTranslation(
          tester,
          source: 'hello context',
          translation: '文章译文快照',
        );
      });
    }
    testWidgets('save failure keeps OCR and translation visible', (
      tester,
    ) async {
      await showSelection(
        tester,
        'hello context',
        const TextSelection(baseOffset: 0, extentOffset: 5),
        save: (_) async => throw StateError('save failed'),
      );
      await tester.tap(find.text('加入截屏生词'));
      await tester.pumpAndSettle();
      expect(find.text('加入失败，请重试；原文与译文已保留。'), findsOneWidget);
      await expectSourceAndTranslation(
        tester,
        source: 'hello context',
        translation: '文章译文快照',
      );
    });

    testWidgets('editing OCR hides the snapshot-based wordbook action', (
      tester,
    ) async {
      final editable = await showSelection(
        tester,
        'hello context',
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );
      await tester.enterText(find.byType(TextField), 'edited context');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 6,
      );
      await tester.pump();
      editable.showToolbar();
      await tester.pumpAndSettle();

      expect(find.text('加入截屏生词'), findsNothing);
    });

    testWidgets(
      'editing OCR still allows dictionary lookup with edited context',
      (tester) async {
        final historyStore = _MemoryScreenshotLookupHistoryStore();
        String? requestedWord;
        await showSelection(
          tester,
          'hello context',
          const TextSelection(baseOffset: 0, extentOffset: 5),
          lookupHistoryStore: historyStore,
          lookup: (word) async {
            requestedWord = word;
            return const ScreenshotDictionaryLookupResult(
              word: 'world',
              ipa: '/wɜːld/',
              partOfSpeech: 'noun',
              meanings: ['世界'],
              example: 'world peace',
              exampleTranslation: '世界和平',
              qualityStatus: 'reviewed',
              examples: [],
            );
          },
        );
        await tester.enterText(
          find.byType(TextField),
          'world context corrected',
        );
        final sourceController = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        sourceController.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();

        final lookupButton = find.byKey(
          const ValueKey('screenshot-source-dictionary-lookup'),
        );
        expect(tester.widget<TextButton>(lookupButton).onPressed, isNotNull);
        await tester.tap(lookupButton);
        await tester.pumpAndSettle();

        expect(requestedWord, 'world');
        expect(historyStore.records, hasLength(1));
        expect(
          historyStore.records.single.recognizedTextSnapshot,
          'world context corrected',
        );
        expect(historyStore.records.single.sourceContext, contains('world'));
        expect(find.text('加入截屏生词'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('locks OCR text only while adding a selected word', (
      tester,
    ) async {
      final pending = Completer<ScreenshotWordAddStatus>();
      await showSelection(
        tester,
        'hello context',
        const TextSelection(baseOffset: 0, extentOffset: 5),
        save: (_) => pending.future,
      );
      await tester.tap(find.text('加入截屏生词'));
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      expect(find.text('正在加入截屏生词…'), findsOneWidget);

      pending.complete(ScreenshotWordAddStatus.added);
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      expect(find.text('已加入截屏生词'), findsOneWidget);
    });
  });

  for (final logical in [const Size(1000, 700), const Size(300, 48)]) {
    test(
      'placement uses actual logical size $logical at the target monitor scale',
      () async {
        final position = await screenshotResultPlacement(
          selection: const Rect.fromLTWH(-900, 100, 400, 100),
          readLogicalSize: () async => logical,
          readDisplays: () async => const [
            Display(
              id: 'negative',
              size: Size(1600, 1000),
              visiblePosition: Offset(-1600, 0),
              visibleSize: Size(1600, 960),
              scaleFactor: 1.5,
            ),
          ],
          isCurrent: () => true,
        );
        final workArea = const Rect.fromLTWH(-2400, 0, 2400, 1440);
        final physicalWindow = position! & (logical * 1.5);
        expect(physicalWindow.left, greaterThanOrEqualTo(workArea.left));
        expect(physicalWindow.right, lessThanOrEqualTo(workArea.right));
        expect(physicalWindow.bottom, lessThanOrEqualTo(workArea.bottom));
        expect(
          position,
          screenshotResultPosition(
            const Rect.fromLTWH(-900, 100, 400, 100),
            workArea,
            logical * 1.5,
          ),
        );
      },
    );
  }
  test('late size lookup cannot position an obsolete result', () async {
    final size = Completer<Size>();
    var current = true;
    var displayReads = 0;
    final pending = screenshotResultPlacement(
      selection: const Rect.fromLTWH(0, 0, 20, 20),
      readLogicalSize: () => size.future,
      readDisplays: () async {
        displayReads++;
        return const [];
      },
      isCurrent: () => current,
    );
    current = false;
    size.complete(const Size(560, 400));
    expect(await pending, isNull);
    expect(displayReads, 0);
  });
  test('late display lookup cannot position an obsolete result', () async {
    final displays = Completer<List<Display>>();
    var current = true;
    final pending = screenshotResultPlacement(
      selection: const Rect.fromLTWH(0, 0, 20, 20),
      readLogicalSize: () async => const Size(560, 400),
      readDisplays: () => displays.future,
      isCurrent: () => current,
    );
    await Future<void>.delayed(Duration.zero);
    current = false;
    displays.complete(const [Display(id: 'main', size: Size(1920, 1080))]);
    expect(await pending, isNull);
  });
  for (final removal in ['replace', 'close', 'dispose']) {
    testWidgets('preview cache is evicted on $removal', (tester) async {
      final bytes = (await tester.runAsync(_previewPng))!;
      final replacementBytes = (await tester.runAsync(_previewPng))!;
      Widget result(String? id) => MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: id == null
              ? null
              : ScreenshotTranslationSession(
                  id: id,
                  imageBytes: id == 'second' ? replacementBytes : bytes,
                  status: ScreenshotTranslationStatus.completed,
                ),
          onCapture: () {},
          onRetranslate: (_) {},
          onHistory: () {},
          onClose: () {},
        ),
      );
      await tester.pumpWidget(result('first'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final provider = tester.widget<Image>(find.byType(Image)).image;
      final key = await provider.obtainKey(ImageConfiguration.empty);
      expect(tester.binding.imageCache.statusForKey(key).untracked, isFalse);
      await tester.pumpWidget(
        removal == 'dispose'
            ? const SizedBox.shrink()
            : result(removal == 'replace' ? 'second' : null),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(tester.binding.imageCache.statusForKey(key).untracked, isTrue);
      if (removal == 'replace') {
        final replacementProvider = tester
            .widget<Image>(find.byType(Image))
            .image;
        final replacementKey = await replacementProvider.obtainKey(
          ImageConfiguration.empty,
        );
        expect(replacementKey, isNot(key));
        expect(
          tester.binding.imageCache.statusForKey(replacementKey).untracked,
          isFalse,
        );
      }
    });
  }
  for (final removal in ['replace', 'close', 'dispose']) {
    testWidgets('late preview decode cannot restore cache after $removal', (
      tester,
    ) async {
      final bytes = (await tester.runAsync(_previewPng))!;
      final replacementBytes = (await tester.runAsync(_previewPng))!;
      final decoded = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawColor(Colors.white, ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1, 1);
        picture.dispose();
        return image;
      });
      final pending = Completer<ImageInfo>();
      final stream = OneFrameImageStreamCompleter(pending.future);
      var delivered = 0;
      final observer = ImageStreamListener((image, _) {
        delivered++;
        image.dispose();
      });
      stream.addListener(observer);
      final provider = ResizeImage(
        MemoryImage(bytes),
        width: 1600,
        height: 1200,
        policy: ResizeImagePolicy.fit,
      );
      final cacheKey = await provider.obtainKey(ImageConfiguration.empty);
      final cache = tester.binding.imageCache;
      cache.putIfAbsent(cacheKey, () => stream);
      final unrelated = Object();
      cache.putIfAbsent(
        unrelated,
        () => OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
      );
      Widget result(String? id) => MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: id == null
              ? null
              : ScreenshotTranslationSession(
                  id: id,
                  imageBytes: id == 'second' ? replacementBytes : bytes,
                  status: ScreenshotTranslationStatus.completed,
                ),
          onCapture: () {},
          onRetranslate: (_) {},
          onHistory: () {},
          onClose: () {},
        ),
      );
      await tester.pumpWidget(result('first'));
      expect(cache.statusForKey(cacheKey).pending, isTrue);
      await tester.pumpWidget(
        removal == 'dispose'
            ? const SizedBox.shrink()
            : result(removal == 'replace' ? 'second' : null),
      );
      expect(cache.statusForKey(cacheKey).untracked, isTrue);
      Object? replacementKey;
      if (removal == 'replace') {
        final replacementProvider = tester
            .widget<Image>(find.byType(Image))
            .image;
        replacementKey = await replacementProvider.obtainKey(
          ImageConfiguration.empty,
        );
        expect(replacementKey, isNot(cacheKey));
        expect(cache.statusForKey(replacementKey).untracked, isFalse);
      }
      pending.complete(ImageInfo(image: decoded!));
      await tester.pump();
      expect(delivered, 1);
      expect(cache.statusForKey(cacheKey).untracked, isTrue);
      if (replacementKey != null) {
        expect(cache.statusForKey(replacementKey).untracked, isFalse);
      }
      expect(cache.statusForKey(unrelated).pending, isTrue);
      stream.removeListener(observer);
      cache.evict(unrelated);
      await tester.pump();
    });
  }
  testWidgets('empty result offers recapture at the minimum window size', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var recaptures = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: const ScreenshotTranslationSession(
            id: 'empty',
            status: ScreenshotTranslationStatus.empty,
          ),
          onCapture: () => recaptures++,
          onRetranslate: (_) {},
          onHistory: () {},
          onClose: () {},
        ),
      ),
    );
    expect(find.textContaining('未识别到文字'), findsWidgets);
    await tester.tap(find.text('重新截取'));
    expect(recaptures, 1);
    expect(tester.takeException(), isNull);
  });
  test(
    'physical placement avoids selection and clamps negative monitor edges',
    () {
      final position = screenshotResultPosition(
        const Rect.fromLTWH(-700, 100, 500, 200),
        const Rect.fromLTWH(-1920, 0, 1920, 1040),
        const Size(560, 400),
      );
      expect(position, const Offset(-1272, 100));
      final constrained = screenshotResultPosition(
        const Rect.fromLTWH(10, 900, 100, 100),
        const Rect.fromLTWH(0, 0, 700, 1040),
        const Size(560, 400),
      );
      expect(constrained.dx, inInclusiveRange(12, 128));
      expect(constrained.dy, 628);
    },
  );
  final failed = ScreenshotTranslationSession(
    id: 's1',
    recognizedText: 'original source',
    direction: TranslationDirection.englishToChinese,
    status: ScreenshotTranslationStatus.failed,
    errorCode: 'network_error',
    imageBytes: Uint8List.fromList([1]),
  );
  testWidgets('failed result keeps editable source and retries edited text', (
    tester,
  ) async {
    String? retry;
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: failed,
          onCapture: () {},
          onRetranslate: (text) => retry = text,
          onHistory: () {},
          onClose: () {},
        ),
      ),
    );
    await showSourcePane(tester);
    expect(find.text('original source'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'corrected source');
    await tester.tap(find.text('重试翻译'));
    expect(retry, 'corrected source');
    expect(find.textContaining('网络连接失败'), findsOneWidget);
  });
  testWidgets(
    'shows the remote OCR-text route and opens model settings without losing source',
    (tester) async {
      var settingsOpened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: ScreenshotTranslationSession(
              id: 'remote-route-failure',
              recognizedText: 'OCR source must remain available',
              status: ScreenshotTranslationStatus.failed,
              errorCode: 'missing_credential',
              translationRoute: TranslationExecutionRoute.remoteProvider(
                'Example API',
              ),
            ),
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onOpenModels: () => settingsOpened++,
            onClose: () {},
          ),
        ),
      );

      expect(find.text('OCR source must remain available'), findsOneWidget);
      expect(
        find.textContaining('处理位置：网络服务「Example API」 · 截图原图不会随请求发送'),
        findsOneWidget,
      );
      expect(find.textContaining('本次没有发送 OCR 文字'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('screenshot-open-model-settings')),
      );

      expect(settingsOpened, 1);
      expect(find.text('OCR source must remain available'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('explains the loopback API privacy boundary', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: ScreenshotTranslationSession(
            id: 'local-compatible-route',
            recognizedText: 'Local OCR source',
            translatedText: '本地译文',
            status: ScreenshotTranslationStatus.completed,
            translationRoute: TranslationExecutionRoute.localCompatibleApi(
              '本机 Ollama',
            ),
          ),
          onCapture: () {},
          onRetranslate: (_) {},
          onHistory: () {},
          onClose: () {},
        ),
      ),
    );

    expect(
      find.textContaining('处理位置：本机兼容接口「本机 Ollama」 · 请求发往本机；服务可能联网'),
      findsOneWidget,
    );
    expect(find.textContaining('网络服务'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed result states the manually selected direction', (
    tester,
  ) async {
    final failedManual = failed.withState(
      ScreenshotTranslationStatus.failed,
      direction: TranslationDirection.chineseToEnglish,
      directionManuallyOverridden: true,
      errorCode: 'network_error',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: failedManual,
          onCapture: () {},
          onRetranslate: (_) {},
          onHistory: () {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('手动切换中译英 · 网络连接失败，原文已保留，请重试。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'offers an optional reverse-direction retry for auto-detection correction',
    (tester) async {
      String? reversedSource;
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: failed,
            onCapture: () {},
            onRetranslate: (_) {},
            onReverseDirection: (source) => reversedSource = source,
            onHistory: () {},
            onClose: () {},
          ),
        ),
      );

      await showSourcePane(tester);
      await tester.tap(find.byTooltip('方向不准？改用中译英重新翻译'));

      expect(reversedSource, 'original source');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow result uses source and translation tabs and preserves edits',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(450, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: failed,
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
          ),
        ),
      );
      expect(find.byType(TabBar), findsOneWidget);
      await tester.tap(find.text('OCR 原文'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'edited text');
      await tester.tap(find.text('译文'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OCR 原文'));
      await tester.pumpAndSettle();
      expect(find.text('edited text'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'minimum-width OCR pane keeps dictionary lookup usable after word selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? requestedWord;
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenshotTranslationResultWindow(
            session: failed,
            onCapture: () {},
            onRetranslate: (_) {},
            onHistory: () {},
            onClose: () {},
            onLookupDictionary: (word) async {
              requestedWord = word;
              return null;
            },
          ),
        ),
      );
      await showSourcePane(tester);

      final source = tester.widget<TextField>(find.byType(TextField));
      source.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 8,
      );
      await tester.pump();

      final lookupButton = find.byKey(
        const ValueKey('screenshot-source-dictionary-lookup'),
      );
      expect(find.text('查询“original”'), findsOneWidget);
      expect(lookupButton.hitTestable(), findsOneWidget);
      expect(tester.widget<TextButton>(lookupButton).onPressed, isNotNull);
      await tester.tap(lookupButton);
      await tester.pumpAndSettle();

      expect(requestedWord, 'original');
      expect(find.textContaining('本地词典暂未收录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('image archive status stays visible beside translation status', (
    tester,
  ) async {
    const session = ScreenshotTranslationSession(
      id: 'saved-text-image-cache-full',
      recognizedText: 'local source',
      translatedText: '本地译文',
      status: ScreenshotTranslationStatus.completed,
      imageSaveAllowed: true,
      imageSaveStatus: ScreenshotTranslationImageSaveStatus.cacheLimitReached,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: session,
          onCapture: _noop,
          onRetranslate: _ignoreText,
          onHistory: _noop,
          onClose: _noop,
        ),
      ),
    );
    expect(find.text('翻译完成 · 自动判定英译中 · 已保存到本地文字历史'), findsOneWidget);
    expect(find.text(session.imageSaveMessage!), findsOneWidget);
    expect(find.text('本地译文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final direction in TranslationDirection.values) {
    for (final status in [
      ScreenshotTranslationStatus.translating,
      ScreenshotTranslationStatus.completed,
    ]) {
      testWidgets(
        'shows automatic ${direction.actionLabel} direction during $status',
        (tester) async {
          final session = ScreenshotTranslationSession(
            id: 'direction-${direction.name}-${status.name}',
            recognizedText: 'recognized source',
            translatedText: 'translated result',
            direction: direction,
            status: status,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: ScreenshotTranslationResultWindow(
                session: session,
                onCapture: _noop,
                onRetranslate: _ignoreText,
                onHistory: _noop,
                onClose: _noop,
              ),
            ),
          );

          final statusMessage = switch (status) {
            ScreenshotTranslationStatus.translating =>
              '正在翻译 · 自动判定${direction.actionLabel}',
            ScreenshotTranslationStatus.completed =>
              '翻译完成 · 自动判定${direction.actionLabel} · 已保存到本地文字历史',
            _ => throw StateError('unexpected screenshot status'),
          };
          expect(find.text(statusMessage), findsOneWidget);
          if (status == ScreenshotTranslationStatus.translating) {
            expect(find.text('正在确认本次翻译的处理位置…'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('labels a manually selected translation direction', (
    tester,
  ) async {
    const session = ScreenshotTranslationSession(
      id: 'manual-direction',
      recognizedText: 'hello',
      translatedText: '你好',
      direction: TranslationDirection.chineseToEnglish,
      directionManuallyOverridden: true,
      status: ScreenshotTranslationStatus.completed,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: session,
          onCapture: _noop,
          onRetranslate: _ignoreText,
          onHistory: _noop,
          onClose: _noop,
        ),
      ),
    );

    expect(find.text('翻译完成 · 手动切换中译英 · 已保存到本地文字历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('result-window actions preserve their callback semantics', (
    tester,
  ) async {
    var captures = 0;
    var histories = 0;
    var closes = 0;
    var topmostChanges = 0;
    var collapsedChanges = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenshotTranslationResultWindow(
          session: const ScreenshotTranslationSession(
            id: 'actions',
            translatedText: 'result',
            status: ScreenshotTranslationStatus.completed,
          ),
          onCapture: () => captures++,
          onRetranslate: _ignoreText,
          onHistory: () => histories++,
          onClose: () => closes++,
          onToggleTopmost: () => topmostChanges++,
          onToggleCollapsed: () => collapsedChanges++,
        ),
      ),
    );
    await tester.tap(find.byTooltip('取消置顶'));
    await tester.tap(find.byTooltip('收起结果'));
    await tester.tap(find.text('重新截取'));
    await tester.tap(find.text('查看历史'));
    await tester.tap(find.byTooltip('关闭结果'));
    expect(topmostChanges, 1);
    expect(collapsedChanges, 1);
    expect(captures, 1);
    expect(histories, 1);
    expect(closes, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('launcher invokes runtime capture, history and model callbacks', (
    tester,
  ) async {
    var captures = 0;
    var history = 0;
    var models = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async {
        captures++;
        return null;
      },
      recognize: (_, [_]) async => '',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => '',
      onOpenHistory: () async {
        history++;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenshotTranslationWorkspace(
            runtime: runtime,
            onOpenModels: () => models++,
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-capture')),
    );
    await tester.pumpAndSettle();
    expect(captures, 1);
    expect(find.text('已取消截屏。'), findsOneWidget);
    await tester.tap(find.text('打开完整翻译历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('模型与服务'));
    expect(history, 1);
    expect(models, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}

final class _MemoryScreenshotLookupHistoryStore
    implements ScreenshotDictionaryLookupHistoryStore {
  List<ScreenshotDictionaryLookupHistoryRecord> records = const [];

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read() async =>
      List.unmodifiable(records);

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) async {
    records = [
      record,
      ...records,
    ].take(screenshotDictionaryLookupHistoryLimit).toList(growable: false);
    return List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(
    String id,
  ) async {
    records = records.where((record) => record.id != id).toList();
    return List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear() async {
    records = const [];
    return const [];
  }
}

Future<Uint8List> _previewPng({int width = 1, int height = 1}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(Colors.white, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

void _noop() {}

void _ignoreText(String _) {}
