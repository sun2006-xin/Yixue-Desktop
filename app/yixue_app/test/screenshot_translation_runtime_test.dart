import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/core/screenshot_translation_capture_service.dart';
import 'package:yixue_app/core/screenshot_translation_image_store.dart';
import 'package:yixue_app/core/screenshot_translation_ocr_layout.dart';
import 'package:yixue_app/core/translation_execution_route.dart';
import 'package:yixue_app/core/translation_format_protector.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';

CapturedData pixels() => CapturedData(
  width: 20,
  height: 10,
  bytes: Uint8List.fromList([1]),
  left: -40,
);

void main() {
  group('screenshot translation direction detection', () {
    test('pure English and Han text select their supported routes', () {
      expect(
        detectScreenshotTranslationDirection(
          'Hello, world.',
          fallback: TranslationDirection.chineseToEnglish,
        ),
        TranslationDirection.englishToChinese,
      );
      expect(
        detectScreenshotTranslationDirection(
          '你好世界',
          fallback: TranslationDirection.englishToChinese,
        ),
        TranslationDirection.chineseToEnglish,
      );
    });

    test('supplementary CJK ideographs select Chinese-to-English', () {
      for (final codePoint in [
        0x20BB7, // Extension B
        0x2EBF0, // Extension I
        0x30000, // Extension G
        0x323B0, // Extension J
      ]) {
        final source = String.fromCharCode(codePoint);
        expect(
          detectScreenshotTranslationDirection(
            source,
            fallback: TranslationDirection.englishToChinese,
          ),
          TranslationDirection.chineseToEnglish,
          reason: 'U+${codePoint.toRadixString(16).toUpperCase()}',
        );
      }
    });

    test('Han text outweighs embedded brand names and acronyms', () {
      expect(
        detectScreenshotTranslationDirection(
          '这是 OpenAI 的 API 文档',
          fallback: TranslationDirection.englishToChinese,
        ),
        TranslationDirection.chineseToEnglish,
      );
    });

    test(
      'common long technical acronyms do not look like English headings',
      () {
        expect(
          detectScreenshotTranslationDirection(
            'CUDA BIOS 世界',
            fallback: TranslationDirection.englishToChinese,
          ),
          TranslationDirection.chineseToEnglish,
        );
      },
    );

    test('short Chinese technical labels are not forced to English', () {
      for (final source in ['安装 node', '初始化 config']) {
        expect(
          detectScreenshotTranslationDirection(
            source,
            fallback: TranslationDirection.englishToChinese,
          ),
          TranslationDirection.chineseToEnglish,
          reason: source,
        );
      }
    });

    test('a few embedded English function words do not outweigh Han text', () {
      expect(
        detectScreenshotTranslationDirection(
          '这是 the API and 文档',
          fallback: TranslationDirection.englishToChinese,
        ),
        TranslationDirection.chineseToEnglish,
      );
    });

    test('English function words identify mixed English prose', () {
      expect(
        detectScreenshotTranslationDirection(
          'The API 文档 is ready',
          fallback: TranslationDirection.chineseToEnglish,
        ),
        TranslationDirection.englishToChinese,
      );
    });

    test('capitalized English words contribute to English prose evidence', () {
      expect(
        detectScreenshotTranslationDirection(
          'Hello friend 世界',
          fallback: TranslationDirection.chineseToEnglish,
        ),
        TranslationDirection.englishToChinese,
      );
    });

    test('long uppercase English headings are not discarded as acronyms', () {
      expect(
        detectScreenshotTranslationDirection(
          'WELCOME 世界',
          fallback: TranslationDirection.chineseToEnglish,
        ),
        TranslationDirection.englishToChinese,
      );
    });

    test('digits and symbols keep the current direction as fallback', () {
      expect(
        detectScreenshotTranslationDirection(
          '1234 🔍 --',
          fallback: TranslationDirection.chineseToEnglish,
        ),
        TranslationDirection.chineseToEnglish,
      );
    });
  });

  test(
    'result session updates reuse image bytes only for the same session',
    () {
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 20,
        imageHeight: 10,
        sourceText: 'visible OCR',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'visible OCR',
            left: 1,
            top: 2,
            width: 10,
            height: 4,
          ),
        ],
      );
      final original = ScreenshotTranslationSession(
        id: 'image-session',
        imageBytes: Uint8List.fromList([1, 2, 3]),
        recognizedText: 'visible OCR',
        ocrLayout: layout,
        status: ScreenshotTranslationStatus.recognizing,
      );
      final compactUpdate = original
          .withState(ScreenshotTranslationStatus.translating)
          .toMap(includeImageBytes: false);
      expect(compactUpdate.containsKey('imageBytes'), isFalse);

      final merged = ScreenshotTranslationSession.fromMap(
        compactUpdate,
        previous: original,
      );
      expect(identical(merged.imageBytes, original.imageBytes), isTrue);
      expect(merged.ocrLayout?.sourceText, 'visible OCR');

      final differentSession = ScreenshotTranslationSession.fromMap({
        ...compactUpdate,
        'id': 'different-session',
      }, previous: original);
      expect(differentSession.imageBytes, isNull);
      expect(differentSession.ocrLayout?.sourceText, 'visible OCR');

      final legacyPayload = original.toMap(includeImageBytes: false)
        ..remove('ocrLayout');
      expect(
        ScreenshotTranslationSession.fromMap(legacyPayload).ocrLayout,
        isNull,
      );
    },
  );

  test('publishes and preserves the selected translation route', () async {
    final window = RecordingWindow();
    var modelsOpened = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'visible OCR text',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => throw StateError('route-aware runner should be used'),
      translateWithRoute:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
            required onRouteSelected,
          }) async {
            onRouteSelected(
              TranslationExecutionRoute.remoteProvider('Example API'),
            );
            return '翻译结果';
          },
      createResultWindow: () async => window,
      onOpenModels: () async {
        modelsOpened++;
      },
    );
    addTearDown(() async {
      await runtime.shutdown();
      runtime.dispose();
    });

    await runtime.startCapture();

    expect(runtime.session?.status, ScreenshotTranslationStatus.completed);
    expect(
      runtime.session?.translationRoute?.kind,
      TranslationExecutionRouteKind.remoteProvider,
    );
    expect(runtime.session?.translationRoute?.displayName, 'Example API');
    expect(
      window.sessions.whereType<ScreenshotTranslationSession>().any(
        (session) =>
            session.translationRoute?.kind ==
            TranslationExecutionRouteKind.remoteProvider,
      ),
      isTrue,
    );
    final roundTrip = ScreenshotTranslationSession.fromMap(
      runtime.session!.toMap(),
    );
    expect(roundTrip.translationRoute?.displayName, 'Example API');

    await runtime.handleMessage(
      ScreenshotTranslationWindowMessage(
        type: 'openModels',
        requestId: 'open-screenshot-models',
        payload: const {},
      ),
    );
    expect(modelsOpened, 1);

    final retry = runtime.session!.withState(
      ScreenshotTranslationStatus.translating,
      clearTranslationRoute: true,
    );
    expect(retry.translationRoute, isNull);
  });

  test(
    'structured OCR boxes survive translation and result-window snapshots',
    () async {
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 20,
        imageHeight: 10,
        sourceText: 'Hello world',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'Hello world',
            left: 2,
            top: 1,
            width: 12,
            height: 5,
          ),
        ],
      );
      final window = RecordingWindow();
      var legacyRecognizerCalled = false;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async {
          legacyRecognizerCalled = true;
          return 'legacy OCR';
        },
        recognizeDocument: (_, [_]) async =>
            const ScreenshotTranslationOcrDocument(
              text: 'Hello world',
              layout: layout,
            ),
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好，世界',
        createResultWindow: () async => window,
      );
      addTearDown(() async {
        await runtime.shutdown();
        runtime.dispose();
      });

      await runtime.startCapture();

      expect(legacyRecognizerCalled, isFalse);
      expect(runtime.session?.recognizedText, 'Hello world');
      expect(runtime.session?.ocrLayout?.blocks.single.left, 2);
      expect(
        window.sessions
            .whereType<ScreenshotTranslationSession>()
            .last
            .ocrLayout
            ?.sourceText,
        'Hello world',
      );
      expect(
        ScreenshotTranslationSession.fromMap(runtime.session!.toMap())
            .ocrLayout
            ?.blocks
            .single
            .width,
        12,
      );
      final wireMap = const StandardMessageCodec().decodeMessage(
        const StandardMessageCodec().encodeMessage({
          'session': runtime.session!.toMap(includeImageBytes: false),
        }),
      ) as Map;
      final wireSession = ScreenshotTranslationSession.fromMap(
        wireMap['session'] as Map,
      );
      expect(wireSession.ocrLayout?.imageHeight, 10);
    },
  );

  test('OCR block translations retain explicit source identities', () async {
    const layout = ScreenshotTranslationOcrLayout(
      imageWidth: 300,
      imageHeight: 180,
      sourceText: 'Heading\n\nBody paragraph',
      blocks: [
        ScreenshotTranslationOcrBlock(
          text: 'Heading',
          left: 10,
          top: 12,
          width: 120,
          height: 26,
        ),
        ScreenshotTranslationOcrBlock(
          text: 'Body paragraph',
          left: 10,
          top: 70,
          width: 260,
          height: 50,
        ),
      ],
    );
    final requested = <({int index, String text})>[];

    final result = await translateScreenshotOcrLayoutBlocks(
      layout,
      translateBlock: (text, index) async {
        requested.add((index: index, text: text));
        return index == 0 ? '标题' : '正文段落';
      },
    );

    expect(requested, [
      (index: 0, text: 'Heading'),
      (index: 1, text: 'Body paragraph'),
    ]);
    expect(result.translatedText, '标题\n\n正文段落');
    expect(result.translatedSourceBlockIndices, [0, 1]);
  });

  test('OCR batch markup maps one response back to its source blocks', () {
    const layout = ScreenshotTranslationOcrLayout(
      imageWidth: 300,
      imageHeight: 180,
      sourceText: 'Heading\n\nBody paragraph',
      blocks: [
        ScreenshotTranslationOcrBlock(
          text: 'Heading',
          left: 10,
          top: 12,
          width: 120,
          height: 26,
        ),
        ScreenshotTranslationOcrBlock(
          text: 'Body paragraph',
          left: 10,
          top: 70,
          width: 260,
          height: 50,
        ),
      ],
    );
    final markup = buildScreenshotTranslationOcrMarkup(
      layout,
      markerNamespace: 'capture_123',
    );
    expect(markup, isNotNull);
    final markers = markup!;
    expect(markers.sourceText.startsWith(markers.startMarker), isTrue);
    expect(markers.sourceText, contains(markers.boundaryMarkers.single));
    expect(markers.sourceText.endsWith(markers.endMarker), isTrue);
    expect(markers.startMarker.length, 1);
    expect(markers.boundaryMarkers.single.length, 1);
    expect(markers.endMarker.length, 1);
    final protected = TranslationFormatProtector.protect(markers.sourceText);
    expect(protected.spans, isEmpty);
    expect(protected.restore(protected.maskedText), markers.sourceText);
    final result = markers.parse(
      layout,
      '${markers.startMarker}标题${markers.boundaryMarkers.single}'
      '正文段落${markers.endMarker}',
    );

    expect(result, isNotNull);
    final parsed = result!;
    expect(parsed.translatedText, '标题\n\n正文段落');
    expect(parsed.translatedSourceBlockIndices, [0, 1]);
  });

  test(
    'OCR marker failures fall back without returning block alignment',
    () async {
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 300,
        imageHeight: 180,
        sourceText: 'Heading\n\nBody paragraph\n\nFootnote',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'Heading',
            left: 10,
            top: 12,
            width: 120,
            height: 26,
          ),
          ScreenshotTranslationOcrBlock(
            text: 'Body paragraph',
            left: 10,
            top: 70,
            width: 260,
            height: 50,
          ),
          ScreenshotTranslationOcrBlock(
            text: 'Footnote',
            left: 10,
            top: 140,
            width: 150,
            height: 20,
          ),
        ],
      );
      final markup = buildScreenshotTranslationOcrMarkup(
        layout,
        markerNamespace: 'capture_123',
      )!;
      final firstBoundary = markup.boundaryMarkers[0];
      final secondBoundary = markup.boundaryMarkers[1];
      final malformedResponses = <String, String>{
        'missing':
            '${markup.startMarker}标题$secondBoundary正文段落${markup.endMarker}',
        'reordered':
            '${markup.startMarker}标题$secondBoundary正文段落'
            '$firstBoundary脚注${markup.endMarker}',
        'duplicate':
            '${markup.startMarker}标题$firstBoundary正文段落'
            '$firstBoundary重复$secondBoundary脚注${markup.endMarker}',
        'empty segment':
            '${markup.startMarker}$firstBoundary正文段落'
            '$secondBoundary脚注${markup.endMarker}',
      };

      for (final entry in malformedResponses.entries) {
        var markedCalls = 0;
        var blockCalls = 0;
        var fallbackCalls = 0;
        final result = await translateScreenshotOcrMarkupOrFallback(
          layout: layout,
          markup: markup,
          translateMarkedText: (_) async {
            markedCalls++;
            return entry.value;
          },
          translateBlock: (source, index) async {
            blockCalls++;
            expect(source, layout.blocks[index].text, reason: entry.key);
            return '区块译文$index';
          },
          translateWholeText: (source) async {
            fallbackCalls++;
            expect(source, layout.sourceText, reason: entry.key);
            return '完整整段译文';
          },
          shouldFallbackOnException:
              shouldFallbackScreenshotTranslationOnException,
        );

        expect(markedCalls, 1, reason: entry.key);
        expect(blockCalls, layout.blocks.length, reason: entry.key);
        expect(fallbackCalls, 0, reason: entry.key);
        expect(
          result.translatedText,
          '区块译文0\n\n区块译文1\n\n区块译文2',
          reason: entry.key,
        );
        expect(result.translatedSourceBlockIndices, [
          0,
          1,
          2,
        ], reason: entry.key);
      }
    },
  );

  test('OCR markup stays within the service limit for 16 blocks at 5000 characters', () async {
    final blocks = List.generate(16, (index) {
      final text = List.filled(index == 15 ? 320 : 310, 'A').join();
      return ScreenshotTranslationOcrBlock(
        text: text,
        left: 0,
        top: index * 10,
        width: 500,
        height: 5,
      );
    }, growable: false);
    final source = blocks.map((block) => block.text).join('\n\n');
    expect(source.length, 5000);
    final layout = ScreenshotTranslationOcrLayout(
      imageWidth: 500,
      imageHeight: 200,
      sourceText: source,
      blocks: blocks,
    );
    final markup = buildScreenshotTranslationOcrMarkup(
      layout,
      markerNamespace: List.filled(80, 'h').join(),
    )!;
    expect(markup.startMarker.length, 1);
    expect(
      markup.boundaryMarkers.every((marker) => marker.length == 1),
      isTrue,
    );
    expect(markup.endMarker.length, 1);
    expect(
      <String>{
        markup.startMarker,
        ...markup.boundaryMarkers,
        markup.endMarker,
      }.length,
      17,
    );
    var markedCalls = 0;
    var fallbackCalls = 0;

    final result = await translateScreenshotOcrMarkupOrFallback(
      layout: layout,
      markup: markup,
      translateMarkedText: (markedText) async {
        markedCalls++;
        if (markedText.length > 5000) {
          throw const QuickTranslationException('invalid_input');
        }
        final response = StringBuffer(markup.startMarker);
        for (var index = 0; index < blocks.length; index++) {
          if (index > 0) {
            response.write(markup.boundaryMarkers[index - 1]);
          }
          response.write('译文$index');
        }
        response.write(markup.endMarker);
        return response.toString();
      },
      translateWholeText: (_) async {
        fallbackCalls++;
        return '整段回退';
      },
      shouldFallbackOnException: shouldFallbackScreenshotTranslationOnException,
    );

    expect(markedCalls, 1);
    expect(fallbackCalls, 0);
    expect(markup.sourceText.length, lessThanOrEqualTo(5000));
    expect(
      result.translatedSourceBlockIndices,
      List<int>.generate(16, (i) => i),
    );
    expect(
      result.translatedText,
      List.generate(16, (i) => '译文$i').join('\n\n'),
    );
  });

  test(
    'OCR markup re-translates malformed marker responses per block',
    () async {
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 300,
        imageHeight: 180,
        sourceText: 'Heading\n\nBody paragraph',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'Heading',
            left: 10,
            top: 12,
            width: 120,
            height: 26,
          ),
          ScreenshotTranslationOcrBlock(
            text: 'Body paragraph',
            left: 10,
            top: 70,
            width: 260,
            height: 50,
          ),
        ],
      );
      final markup = buildScreenshotTranslationOcrMarkup(
        layout,
        markerNamespace: 'capture_123',
      );
      var markedCalls = 0;
      var blockCalls = 0;
      var fallbackCalls = 0;

      final result = await translateScreenshotOcrMarkupOrFallback(
        layout: layout,
        markup: markup,
        translateMarkedText: (_) async {
          markedCalls++;
          return '译文返回了，但标记丢失';
        },
        translateBlock: (source, index) async {
          blockCalls++;
          expect(source, layout.blocks[index].text);
          return '区块译文$index';
        },
        translateWholeText: (source) async {
          fallbackCalls++;
          expect(source, layout.sourceText);
          return '完整译文';
        },
        shouldFallbackOnException:
            shouldFallbackScreenshotTranslationOnException,
      );

      expect(markedCalls, 1);
      expect(blockCalls, layout.blocks.length);
      expect(fallbackCalls, 0);
      expect(result.translatedText, '区块译文0\n\n区块译文1');
      expect(result.translatedSourceBlockIndices, [0, 1]);
    },
  );

  test(
    'OCR marker recovery avoids a burst of per-block requests for long layouts',
    () async {
      final blocks = List.generate(
        8,
        (index) => ScreenshotTranslationOcrBlock(
          text: 'Paragraph $index',
          left: 10,
          top: index * 30,
          width: 250,
          height: 24,
        ),
        growable: false,
      );
      final layout = ScreenshotTranslationOcrLayout(
        imageWidth: 300,
        imageHeight: 260,
        sourceText: blocks.map((block) => block.text).join('\n\n'),
        blocks: blocks,
      );
      final markup = buildScreenshotTranslationOcrMarkup(
        layout,
        markerNamespace: 'many_blocks',
      )!;
      var blockCalls = 0;
      var wholeTextCalls = 0;

      final result = await translateScreenshotOcrMarkupOrFallback(
        layout: layout,
        markup: markup,
        translateMarkedText: (_) async => '标记丢失的整段输出',
        translateBlock: (_, _) async {
          blockCalls++;
          return '不应逐块重试';
        },
        translateWholeText: (_) async {
          wholeTextCalls++;
          return '一次请求完成的整段译文';
        },
        shouldFallbackOnException:
            shouldFallbackScreenshotTranslationOnException,
      );

      expect(blockCalls, 0);
      expect(wholeTextCalls, 1);
      expect(result.translatedText, '一次请求完成的整段译文');
      expect(result.translatedSourceBlockIndices, isNull);
    },
  );

  test(
    'OCR markup cancellation propagates without a full-text retry',
    () async {
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 300,
        imageHeight: 180,
        sourceText: 'Heading\n\nBody paragraph',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'Heading',
            left: 10,
            top: 12,
            width: 120,
            height: 26,
          ),
          ScreenshotTranslationOcrBlock(
            text: 'Body paragraph',
            left: 10,
            top: 70,
            width: 260,
            height: 50,
          ),
        ],
      );
      final markup = buildScreenshotTranslationOcrMarkup(
        layout,
        markerNamespace: 'capture_123',
      );
      var fallbackCalls = 0;

      await expectLater(
        translateScreenshotOcrMarkupOrFallback(
          layout: layout,
          markup: markup,
          translateMarkedText: (_) async =>
              throw const QuickTranslationException('cancelled'),
          translateWholeText: (_) async {
            fallbackCalls++;
            return '不应触发';
          },
          shouldFallbackOnException:
              shouldFallbackScreenshotTranslationOnException,
        ),
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );

      expect(fallbackCalls, 0);
    },
  );

  test(
    'only translation-format failures trigger the one-shot OCR fallback',
    () {
      for (final code in const <String>[
        'suspicious_model_output',
        'format_integrity_failed',
      ]) {
        expect(
          shouldFallbackScreenshotTranslationOnException(
            QuickTranslationException(code),
          ),
          isTrue,
          reason: code,
        );
      }
      for (final code in const <String>[
        'cancelled',
        'service_disposed',
        'provider_route_changed',
        'translation_in_progress',
        'network_error',
        'no_remote_provider',
        'ambiguous_translation_provider',
        'invalid_response',
      ]) {
        expect(
          shouldFallbackScreenshotTranslationOnException(
            QuickTranslationException(code),
          ),
          isFalse,
          reason: code,
        );
      }
      expect(
        shouldFallbackScreenshotTranslationOnException(
          const FormatException('model output changed marker identity'),
        ),
        isFalse,
      );
    },
  );

  test(
    'network failure propagates without a second OCR translation request',
    () async {
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 300,
        imageHeight: 180,
        sourceText: 'Heading\n\nBody paragraph',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'Heading',
            left: 10,
            top: 12,
            width: 120,
            height: 26,
          ),
          ScreenshotTranslationOcrBlock(
            text: 'Body paragraph',
            left: 10,
            top: 70,
            width: 260,
            height: 50,
          ),
        ],
      );
      final markup = buildScreenshotTranslationOcrMarkup(
        layout,
        markerNamespace: 'network_failure',
      );
      var fallbackCalls = 0;

      await expectLater(
        translateScreenshotOcrMarkupOrFallback(
          layout: layout,
          markup: markup,
          translateMarkedText: (_) async =>
              throw const QuickTranslationException('network_error'),
          translateWholeText: (_) async {
            fallbackCalls++;
            return '不应再次发送';
          },
          shouldFallbackOnException:
              shouldFallbackScreenshotTranslationOnException,
        ),
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'network_error',
          ),
        ),
      );

      expect(fallbackCalls, 0);
    },
  );

  test(
    'OCR block translation falls back when output cannot map one-to-one',
    () async {
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 300,
        imageHeight: 180,
        sourceText: 'Heading\n\nBody paragraph',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'Heading',
            left: 10,
            top: 12,
            width: 120,
            height: 26,
          ),
          ScreenshotTranslationOcrBlock(
            text: 'Body paragraph',
            left: 10,
            top: 70,
            width: 260,
            height: 50,
          ),
        ],
      );

      final result = await translateScreenshotOcrLayoutBlocks(
        layout,
        translateBlock: (text, index) async =>
            index == 0 ? '标题\n\n补充标题' : '正文段落',
      );

      expect(result.translatedText, '标题\n\n补充标题\n\n正文段落');
      expect(result.translatedSourceBlockIndices, isNull);
    },
  );

  test(
    'OCR layouts beyond the alignment limit fall back to full-text translation',
    () async {
      final blocks = List.generate(
        screenshotTranslationMaxAlignedOcrBlocks + 1,
        (index) => ScreenshotTranslationOcrBlock(
          text: 'Block $index',
          left: (index % 4) * 70,
          top: (index ~/ 4) * 30,
          width: 60,
          height: 20,
        ),
        growable: false,
      );
      final source = blocks.map((block) => block.text).join('\n\n');
      final layout = ScreenshotTranslationOcrLayout(
        imageWidth: 300,
        imageHeight: 180,
        sourceText: source,
        blocks: blocks,
      );
      var fullTextTranslations = 0;
      var alignedTranslations = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => CapturedData(
          width: 300,
          height: 180,
          bytes: Uint8List.fromList([1]),
          left: 0,
        ),
        recognize: (_, [_]) async => source,
        recognizeDocument: (_, [_]) async =>
            ScreenshotTranslationOcrDocument(text: source, layout: layout),
        translate:
            (
              text,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              fullTextTranslations++;
              expect(text, source);
              return 'Full text translation';
            },
        translateDocumentWithRoute:
            (
              text,
              ocrLayout,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
              required onRouteSelected,
            }) async {
              alignedTranslations++;
              return const ScreenshotTranslationDocumentTranslation(
                translatedText: 'Must use fallback',
              );
            },
        createResultWindow: () async => RecordingWindow(),
      );
      addTearDown(() async {
        await runtime.shutdown();
        runtime.dispose();
      });

      await runtime.startCapture();

      expect(runtime.session?.status, ScreenshotTranslationStatus.completed);
      expect(runtime.session?.translatedText, 'Full text translation');
      expect(runtime.session?.translatedSourceBlockIndices, isNull);
      expect(fullTextTranslations, 1);
      expect(alignedTranslations, 0);
    },
  );

  test(
    'runtime validates and publishes explicit OCR translation identities',
    () async {
      const layout = ScreenshotTranslationOcrLayout(
        imageWidth: 300,
        imageHeight: 180,
        sourceText: 'Heading\n\nBody paragraph',
        blocks: [
          ScreenshotTranslationOcrBlock(
            text: 'Heading',
            left: 10,
            top: 12,
            width: 120,
            height: 26,
          ),
          ScreenshotTranslationOcrBlock(
            text: 'Body paragraph',
            left: 10,
            top: 70,
            width: 260,
            height: 50,
          ),
        ],
      );
      final window = RecordingWindow();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'legacy OCR',
        recognizeDocument: (_, [_]) async =>
            const ScreenshotTranslationOcrDocument(
              text: 'Heading\n\nBody paragraph',
              layout: layout,
            ),
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => throw StateError('structured runner should be used'),
        translateDocumentWithRoute:
            (
              source,
              ocrLayout,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
              required onRouteSelected,
            }) async {
              expect(ocrLayout, same(layout));
              onRouteSelected(
                TranslationExecutionRoute.localModel('test model'),
              );
              return translateScreenshotOcrLayoutBlocks(
                ocrLayout,
                translateBlock: (sourceBlock, blockIndex) async =>
                    blockIndex == 0 ? '标题' : '正文段落',
              );
            },
        createResultWindow: () async => window,
      );
      addTearDown(() async {
        await runtime.shutdown();
        runtime.dispose();
      });

      await runtime.startCapture();

      expect(runtime.session?.status, ScreenshotTranslationStatus.completed);
      expect(runtime.session?.translatedText, '标题\n\n正文段落');
      expect(runtime.session?.translatedSourceBlockIndices, [0, 1]);
      final roundTrip = ScreenshotTranslationSession.fromMap(
        runtime.session!.toMap(includeImageBytes: false),
      );
      expect(roundTrip.translatedSourceBlockIndices, [0, 1]);
      final childUpdate = window.sessions
          .whereType<ScreenshotTranslationSession>()
          .last;
      expect(childUpdate.translatedSourceBlockIndices, [0, 1]);
    },
  );

  group('wordbook main-engine requests', () {
    late ScreenshotTranslationRuntime runtime;
    late LearningRepository repository;
    late MemoryLearningStore store;
    late String translationResult;
    var failSave = false;

    setUp(() async {
      failSave = false;
      translationResult = '你好，保持健康';
      store = MemoryLearningStore();
      repository = LearningRepository(store);
      runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => "hello don’t well-being mystery",
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => translationResult,
        onAddScreenshotWord: (request) async {
          if (failSave) throw StateError('storage unavailable');
          final result = await repository.addScreenshotWord(
            word: request.word,
            sourceContext: request.recognizedText,
            sourceTranslation: request.translatedText,
            sourceHistoryId: request.historyEntryId,
            dictionaryMeaning: request.word == 'hello' ? '你好' : null,
          );
          return !result.added
              ? ScreenshotWordAddStatus.alreadyExists
              : request.word == 'hello'
              ? ScreenshotWordAddStatus.added
              : ScreenshotWordAddStatus.meaningPending;
        },
      );
      await runtime.startCapture();
    });
    tearDown(() async => runtime.shutdown());

    ScreenshotTranslationWindowMessage request(
      String word, {
      Map<String, Object?>? overrides,
    }) => ScreenshotTranslationWindowMessage(
      type: 'addScreenshotWord',
      requestId: 'word-$word',
      payload: {
        'sessionId': runtime.session!.id,
        'historyEntryId': runtime.session!.historyEntryId,
        'word': word,
        'recognizedText': runtime.session!.recognizedText,
        'translatedText': runtime.session!.translatedText,
        ...?overrides,
      },
    );

    test(
      'independently rejects a payload mutated after protocol decoding',
      () async {
        final message = request('hello');
        message.payload['imageBytes'] = Uint8List.fromList([1]);
        expect(
          (await runtime.handleMessage(message))!.payload['errorCode'],
          'invalid_word_request',
        );
        expect((await repository.load()).items, isEmpty);
      },
    );

    test('adds dictionary word with exact snapshots and deduplicates repeated message', () async {
      final before = runtime.session;
      final message = request('hello');
      final ack = await runtime.handleMessage(message);
      expect(ack!.type, 'ack');
      expect(ack.requestId, message.requestId);
      expect(ack.payload, {'status': 'added'});
      final repeated = await runtime.handleMessage(message);
      expect(repeated!.payload, {'status': 'alreadyExists'});
      final state = await repository.load();
      final item = state.items.single;
      expect(item.word, 'hello');
      expect(item.meaning, '你好');
      expect(item.meaningSource, 'dictionary');
      expect(item.sourceContext, before!.recognizedText);
      expect(item.sourceTranslation, before.translatedText);
      expect(item.sourceHistoryId, before.id);
      expect(runtime.session, same(before));
    });

    test(
      'apostrophes hyphens and unknown words save with meaningPending',
      () async {
        for (final word in ["don't", 'well-being', 'mystery']) {
          expect((await runtime.handleMessage(request(word)))!.payload, {
            'status': 'meaningPending',
          });
        }
        final state = await repository.load();
        expect(state.items.map((item) => item.word), [
          "don't",
          'well-being',
          'mystery',
        ]);
        expect(state.items.every((item) => item.meaning == null), isTrue);
      },
    );

    test('rejects a word that appears only in translated text', () async {
      translationResult = 'steady progress';
      await runtime.retranslate(runtime.session!.recognizedText);

      final ack = await runtime.handleMessage(request('steady'));
      expect(ack!.payload, {'errorCode': 'invalid_word_request'});
      expect((await repository.load()).items, isEmpty);
    });

    test('rejects stale session snapshot history and word not present without writes', () async {
      final before = runtime.session;
      for (final overrides in [
        {'sessionId': 'old'},
        {'historyEntryId': 'wrong-history'},
        {'recognizedText': 'hello different text'},
        {'translatedText': 'wrong translation'},
      ]) {
        final ack = await runtime.handleMessage(
          request('hello', overrides: overrides),
        );
        expect(ack!.payload['errorCode'], 'stale_session');
      }
      for (final word in ['other', 'hell', 'being']) {
        expect(
          (await runtime.handleMessage(request(word)))!.payload['errorCode'],
          'invalid_word_request',
        );
      }
      expect((await repository.load()).items, isEmpty);
      expect(runtime.session, same(before));
      final closedMessage = request('hello');
      await runtime.closeResult();
      expect(
        (await runtime.handleMessage(closedMessage))!.payload['errorCode'],
        'stale_session',
      );
    });

    test('save failure returns an error without losing source or translation and allows retry', () async {
      final before = runtime.session;
      failSave = true;
      expect(
        (await runtime.handleMessage(request('hello')))!.payload['errorCode'],
        'save_failed',
      );
      expect(runtime.session, same(before));
      expect((await repository.load()).items, isEmpty);
      failSave = false;
      expect(
        (await runtime.handleMessage(request('hello')))!.payload['status'],
        'added',
      );
    });
  });

  test(
    'capture service forwards the runtime cancellation token to OCR',
    () async {
      final token = ScreenshotTranslationCancellationToken()
        ..cancel('test cancellation');

      await expectLater(
        ScreenshotTranslationCaptureService().recognize(pixels(), token),
        throwsA(isA<ScreenshotTranslationCancelledException>()),
      );
    },
  );

  test(
    'original image saving stays off until the persisted preference loads',
    () async {
      final preferences = _DeferredScreenshotPreferencesStore();
      final desktop = ScreenshotTranslationDesktopController(
        store: preferences,
        hotKeys: _NoopScreenshotHotKeys(),
        createOrb: () async => _NoopScreenshotOrb(),
        onCapture: () async {},
        onOpenMain: () async {},
        onOpenSettings: () async {},
        onHideMain: () async {},
        onReleaseSession: () async {},
        onCloseChildren: () async {},
        onExit: () async {},
      );
      final imageStore = MemoryScreenshotImageStore();
      final guardedRuntime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好',
        imageStore: imageStore,
        saveScreenshotImages: () => desktop.imagePersistenceEnabled,
      );

      final initialization = desktop.initialize();
      await preferences.readStarted.future;
      expect(desktop.imagePersistenceEnabled, isFalse);
      await guardedRuntime.startCapture();
      expect(
        guardedRuntime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.notRequested,
      );
      expect(imageStore.savedIds, isEmpty);

      preferences.complete(const ScreenshotTranslationPreferences());
      await initialization;
      expect(desktop.imagePersistenceEnabled, isTrue);
      await guardedRuntime.startCapture();
      final id = guardedRuntime.session!.id;
      expect(imageStore.savedIds, [id]);
      expect(
        guardedRuntime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.saved,
      );

      await guardedRuntime.shutdown();
      guardedRuntime.dispose();
      await desktop.shutdown();
      desktop.dispose();
    },
  );

  test('workbench restores the main window before OCR on success, cancel, and failure', () async {
    final events = <String>[];
    final desktop = ScreenshotTranslationDesktopController(
      store: _DeferredScreenshotPreferencesStore(),
      hotKeys: _NoopScreenshotHotKeys(),
      createOrb: () async => _NoopScreenshotOrb(),
      onCapture: () async {},
      onOpenMain: () async => events.add('restore'),
      onOpenSettings: () async {},
      onHideMain: () async => events.add('hide'),
      onReleaseSession: () async {},
      onCloseChildren: () async {},
      onExit: () async {},
    );

    ScreenshotTranslationRuntime runtimeFor(
      Future<CapturedData?> Function() capture,
    ) => ScreenshotTranslationRuntime(
      capture: () async {
        events.add('capture');
        return capture();
      },
      recognize: (_, [_]) async {
        events.add('ocr');
        return 'hello';
      },
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) async {
            events.add('translate');
            return '你好';
          },
    );

    final success = runtimeFor(() async => pixels());
    await success.startWorkbenchCapture(
      captureGuard: (capture) => desktop.captureWithMainHidden(capture),
    );
    expect(events, ['hide', 'capture', 'restore', 'ocr', 'translate']);
    await success.shutdown();
    success.dispose();

    events.clear();
    final cancelled = runtimeFor(() async => null);
    await cancelled.startWorkbenchCapture(
      captureGuard: (capture) => desktop.captureWithMainHidden(capture),
    );
    expect(events, ['hide', 'capture', 'restore']);
    expect(cancelled.session!.status, ScreenshotTranslationStatus.cancelled);
    await cancelled.shutdown();
    cancelled.dispose();

    events.clear();
    final failed = runtimeFor(() async => throw StateError('capture failed'));
    await failed.startWorkbenchCapture(
      captureGuard: (capture) => desktop.captureWithMainHidden(capture),
    );
    expect(events, ['hide', 'capture', 'restore']);
    expect(failed.session!.status, ScreenshotTranslationStatus.failed);
    await failed.shutdown();
    failed.dispose();
    desktop.dispose();
  });

  test('recovering result connection notifies launcher listeners', () async {
    var failed = true;
    final handle = FakeWindow();
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'hello',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => '你好',
      createResultWindow: () async {
        if (failed) throw StateError('child startup failed');
        return handle;
      },
    );
    await runtime.startCapture();
    expect(runtime.windowError, isNotNull);
    var notifications = 0;
    runtime.addListener(() => notifications++);
    failed = false;
    await runtime.reopenResult();
    expect(runtime.windowError, isNull);
    expect(notifications, 1);
    runtime.dispose();
  });

  test(
    'superseded result handle reconnects and republishes current session',
    () async {
      final replacement = RecordingWindow();
      var creations = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好',
        createResultWindow: () async {
          creations++;
          return creations == 1 ? _SupersededWindow() : replacement;
        },
      );

      await runtime.startCapture();

      expect(creations, 2);
      expect(
        replacement.sessions.any(
          (session) =>
              session?.id == runtime.session?.id &&
              session?.recognizedText == 'hello' &&
              session?.translatedText == '你好',
        ),
        isTrue,
      );
      expect(runtime.windowError, isNull);
      await runtime.shutdown();
      runtime.dispose();
    },
  );

  test(
    'closing a result while reopening cannot hide a newer capture',
    () async {
      final window = _GatedResultWindow();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'latest text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        createResultWindow: () async => window,
      );

      await runtime.startCapture();
      window.gateNextUpdate();
      final reopening = runtime.reopenResult();
      await window.updateStarted.future;
      final closing = runtime.closeResult();
      // Let close queue its guarded clear behind the blocked update.
      await Future<void>.delayed(Duration.zero);
      final nextCapture = runtime.startCapture();
      final latestId = runtime.session!.id;
      window.updateGate.complete();
      await Future.wait([reopening, closing, nextCapture]);

      expect(runtime.session?.id, latestId);
      expect(window.events.last, 'update:$latestId');
      expect(
        window.events.lastIndexOf('hide'),
        lessThan(window.events.lastIndexOf('update:$latestId')),
      );
      await runtime.shutdown();
      runtime.dispose();
    },
  );

  test(
    'a stale result window cannot cancel a fresh screenshot capture',
    () async {
      final oldWindow = _ToggleSupersededWindow();
      final replacement = RecordingWindow();
      var captures = 0;
      var creations = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async {
          captures++;
          return pixels();
        },
        recognize: (_, [_]) async => 'hello',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好',
        createResultWindow: () async {
          creations++;
          return creations == 1 ? oldWindow : replacement;
        },
      );

      await runtime.startCapture();
      oldWindow.superseded = true;
      await runtime.startCapture();

      expect(captures, 2);
      expect(creations, 2);
      expect(runtime.session?.status, ScreenshotTranslationStatus.completed);
      expect(
        replacement.sessions.any((session) => session?.translatedText == '你好'),
        isTrue,
      );
      await runtime.shutdown();
      runtime.dispose();
    },
  );

  test(
    'a stale result window cannot turn a cancelled screenshot into failure',
    () async {
      final window = _ToggleSupersededWindow();
      var captureCount = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async {
          captureCount++;
          if (captureCount == 1) return pixels();
          window.superseded = true;
          return null;
        },
        recognize: (_, [_]) async => 'hello',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好',
        createResultWindow: () async => window,
      );

      await runtime.startCapture();
      window.superseded = false;
      await runtime.startCapture();

      expect(runtime.session?.status, ScreenshotTranslationStatus.cancelled);
      expect(runtime.windowError, isNull);
      await runtime.shutdown();
      runtime.dispose();
    },
  );

  test(
    'deleting history continues when its result window was superseded',
    () async {
      final window = _ToggleSupersededWindow();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好',
        createResultWindow: () async => window,
      );

      await runtime.startCapture();
      final historyEntryId = runtime.session!.id;
      window.superseded = true;
      await runtime.deleteHistoryEntry(historyEntryId);

      expect(runtime.session, isNull);
      expect(runtime.windowError, isNull);
      await runtime.shutdown();
      runtime.dispose();
    },
  );

  test(
    'deleting an older active translation leaves a newer capture open',
    () async {
      final oldTranslation = Completer<String>();
      final newTranslation = Completer<String>();
      final oldTranslationStarted = Completer<void>();
      final newRecognitionFinished = Completer<void>();
      final newTranslationStarted = Completer<void>();
      var captures = 0;
      var translations = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async {
          captures++;
          return pixels();
        },
        recognize: (_, [_]) async {
          if (captures == 2) newRecognitionFinished.complete();
          return 'text $captures';
        },
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) {
              translations++;
              if (translations == 1) {
                oldTranslationStarted.complete();
                return oldTranslation.future;
              }
              newTranslationStarted.complete();
              return newTranslation.future;
            },
        // Let capture B proceed while A's provider future is still settling.
        cancelTranslation: () async => false,
      );

      final captureA = runtime.startCapture();
      await oldTranslationStarted.future;
      final historyEntryA = runtime.session!.id;
      final captureB = runtime.startCapture();
      await newRecognitionFinished.future;
      final captureIdB = runtime.session!.id;
      expect(captureIdB, isNot(historyEntryA));

      final deletingA = runtime.deleteHistoryEntry(historyEntryA);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.session?.id, captureIdB);

      oldTranslation.complete('old result');
      await Future.wait([captureA, deletingA]);
      await newTranslationStarted.future;
      newTranslation.complete('new result');
      await captureB;

      expect(runtime.session?.id, captureIdB);
      expect(runtime.session?.translatedText, 'new result');
      await runtime.shutdown();
      runtime.dispose();
    },
  );

  test(
    'shutdown waits for an image save already started after provider success',
    () async {
      final imageStore = MemoryScreenshotImageStore()
        ..saveStarted = Completer<void>()
        ..saveGate = Completer<void>();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'visible text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        imageStore: imageStore,
      );

      final capture = runtime.startCapture();
      await imageStore.saveStarted!.future;
      final historyId = runtime.session!.id;
      var shutdownCompleted = false;
      final shutdown = runtime.shutdown().then((_) => shutdownCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(shutdownCompleted, isFalse);

      imageStore.saveGate!.complete();
      await Future.wait([capture, shutdown]);
      expect(shutdownCompleted, isTrue);
      expect(imageStore.images.keys, [historyId]);
    },
  );

  test('shutdown preserves history and saves the image when provider completes just before shutdown', () async {
    final providerStarted = Completer<void>();
    final providerResult = Completer<String>();
    final imageStore = MemoryScreenshotImageStore()
      ..saveStarted = Completer<void>()
      ..saveGate = Completer<void>();
    var historyAlreadyWritten = false;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'visible text',
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) {
            providerStarted.complete();
            return providerResult.future;
          },
      imageStore: imageStore,
    );

    final capture = runtime.startCapture();
    await providerStarted.future;
    final historyId = runtime.session!.id;
    historyAlreadyWritten = true;
    providerResult.complete('译文');
    // Call in the same turn as completing the provider Future. The runtime
    // continuation has not yet resumed, although the service has persisted.
    var shutdownFinished = false;
    final shutdown = runtime.shutdown().then((_) => shutdownFinished = true);

    await imageStore.saveStarted!.future;
    expect(historyAlreadyWritten, isTrue);
    expect(shutdownFinished, isFalse);
    imageStore.saveGate!.complete();
    await Future.wait([capture, shutdown]);

    expect(shutdownFinished, isTrue);
    expect(imageStore.savedIds, [historyId]);
    expect(imageStore.images[historyId], [1]);
  });

  test('a screenshot translation cannot recreate an image after its history was deleted', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-runtime-delete-race-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final backingStore = FileScreenshotTranslationImageStore(directory);
    final deferredStore = DeferredCoordinatedImageStore(backingStore);
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'visible text',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => '译文',
      imageStore: deferredStore,
    );

    final capture = runtime.startCapture();
    await deferredStore.saveStarted.future;
    final historyId = runtime.session!.id;
    var historyDeleted = false;
    await backingStore.deleteImageAndThen(historyId, () async {
      historyDeleted = true;
    });
    expect(historyDeleted, isTrue);

    deferredStore.allowSave.complete();
    await capture;

    expect(runtime.session!.status, ScreenshotTranslationStatus.completed);
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.invalidated,
    );
    expect(runtime.retryableImageSaves, isEmpty);
    expect(await backingStore.read(historyId), isNull);
    runtime.dispose();
  });

  test(
    'failed image write after deletion does not restore retry bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-runtime-invalidated-save-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final backingStore = FileScreenshotTranslationImageStore(directory);
      final deferredStore = DeferredCoordinatedImageStore(backingStore)
        ..failAfterGate = true;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'visible text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        imageStore: deferredStore,
      );

      final capture = runtime.startCapture();
      await deferredStore.saveStarted.future;
      final historyId = runtime.session!.id;
      await backingStore.deleteImageAndThen(historyId, () async {});
      deferredStore.allowSave.complete();
      await capture;

      expect(runtime.retryableImageSaves, isEmpty);
      expect(runtime.retryableImageSaveCacheBytes, 0);
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.invalidated,
      );
      expect(await runtime.retryImageSave(historyEntryId: historyId), isFalse);
      runtime.dispose();
    },
  );

  test(
    'successful save invalidated by queued deletion is not reported saved',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-runtime-save-delete-commit-race-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final commitStarted = Completer<void>();
      final releaseCommit = Completer<void>();
      final backingStore = FileScreenshotTranslationImageStore(
        directory,
        commit: (staged, destination) async {
          commitStarted.complete();
          await releaseCommit.future;
          await staged.rename(destination.path);
        },
      );
      final deferredStore = DeferredCoordinatedImageStore(backingStore);
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'visible text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        imageStore: deferredStore,
      );

      final capture = runtime.startCapture();
      await deferredStore.saveStarted.future;
      final historyId = runtime.session!.id;
      deferredStore.allowSave.complete();
      await commitStarted.future;
      final deletion = backingStore.deleteImageAndThen(historyId, () async {});
      releaseCommit.complete();
      await Future.wait([capture, deletion]);

      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.invalidated,
      );
      expect(runtime.retryableImageSaves, isEmpty);
      expect(await backingStore.read(historyId), isNull);
      runtime.dispose();
    },
  );

  test(
    'failed image save stays retryable after closing its result window',
    () async {
      final imageStore = MemoryScreenshotImageStore()
        ..failNextSave = true
        ..saveStarted = Completer<void>()
        ..saveGate = Completer<void>();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'visible text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        imageStore: imageStore,
      );

      final capture = runtime.startCapture();
      await imageStore.saveStarted!.future;
      final historyId = runtime.session!.id;
      await runtime.closeResult();
      imageStore.saveGate!.complete();
      await capture;

      expect(runtime.session, isNull);
      expect(runtime.retryableImageSaves.map((item) => item.historyEntryId), [
        historyId,
      ]);
      await runtime.retryImageSave(historyEntryId: historyId);
      expect(imageStore.savedIds, [historyId, historyId]);
      expect(runtime.retryableImageSaves, isEmpty);
      runtime.dispose();
    },
  );

  test(
    'failed image save remains retryable after a replacement screenshot starts',
    () async {
      final imageStore = MemoryScreenshotImageStore()
        ..failNextSave = true
        ..saveStarted = Completer<void>()
        ..saveGate = Completer<void>();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'visible text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        imageStore: imageStore,
      );

      final firstCapture = runtime.startCapture();
      await imageStore.saveStarted!.future;
      final firstHistoryId = runtime.session!.id;
      final replacementCapture = runtime.startCapture();
      await Future<void>.delayed(Duration.zero);
      expect(runtime.session!.id, isNot(firstHistoryId));
      imageStore.saveGate!.complete();
      await Future.wait([firstCapture, replacementCapture]);

      expect(runtime.session!.status, ScreenshotTranslationStatus.completed);
      expect(runtime.retryableImageSaves.map((item) => item.historyEntryId), [
        firstHistoryId,
      ]);
      await runtime.retryImageSave(historyEntryId: firstHistoryId);
      expect(imageStore.savedIds, [
        firstHistoryId,
        runtime.session!.id,
        firstHistoryId,
      ]);
      expect(runtime.retryableImageSaves, isEmpty);
      runtime.dispose();
    },
  );

  test(
    'retry cache has count and byte limits and reports the limit reason',
    () async {
      final imageStore = MemoryScreenshotImageStore();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'visible text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        imageStore: imageStore,
      );
      final historyIds = <String>[];

      for (
        var index = 0;
        index <= ScreenshotTranslationRuntime.maxRetryableImageSaveCount;
        index++
      ) {
        imageStore.failNextSave = true;
        await runtime.startCapture();
        historyIds.add(runtime.session!.id);
      }

      final retryableBefore = runtime.retryableImageSaves
          .map((item) => item.historyEntryId)
          .toList();
      final currentBefore = runtime.session!;
      expect(
        runtime.retryableImageSaveCacheCount,
        ScreenshotTranslationRuntime.maxRetryableImageSaveCount,
      );
      expect(runtime.retryableImageSaveCacheBytes, 5);
      await runtime.retryImageSave(historyEntryId: historyIds.last);
      expect(imageStore.images[historyIds.last], [1]);
      expect(retryableBefore, historyIds);
      expect(
        currentBefore.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.cacheLimitReached,
      );
      expect(currentBefore.imageBytes, isNotNull);
      expect(currentBefore.imageSaveMessage, contains('当前结果仍可重试'));
      expect(currentBefore.toMap()['imageSaveMessage'], contains('关闭结果'));
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.saved,
      );
      expect(runtime.retryableImageSaveCacheCount, 5);
      runtime.purgeRetryableImageSave(historyIds.first);
      expect(runtime.retryableImageSaveCacheCount, 4);
      expect(runtime.retryableImageSaveCacheBytes, 4);
      runtime.purgeAllRetryableImageSaves();
      expect(runtime.retryableImageSaveCacheCount, 0);
      expect(runtime.retryableImageSaveCacheBytes, 0);
      runtime.dispose();
    },
  );

  test(
    'retranslation gets a new history ID while keeping the capture ID stable',
    () async {
      final receivedHistoryEntryIds = <String>[];
      final receivedCaptureIds = <String>[];
      String? receivedOrigin;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello',
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              receivedOrigin = origin;
              receivedHistoryEntryIds.add(historyEntryId);
              receivedCaptureIds.add(screenshotCaptureId);
              return '你好';
            },
      );

      await runtime.startCapture();
      final screenshotId = runtime.session!.id;
      await runtime.retranslate('edited screenshot text');

      expect(receivedOrigin, 'screenshot_translation');
      expect(receivedHistoryEntryIds, [screenshotId, '$screenshotId-v1']);
      expect(receivedCaptureIds, [screenshotId, screenshotId]);
      expect(runtime.session!.id, screenshotId);
      expect(runtime.session!.historyEntryId, '$screenshotId-v1');
      expect(screenshotId, startsWith('screenshot-'));
      runtime.dispose();
    },
  );

  test('result window can retry with the opposite detected direction on same history row', () async {
    final requests =
        <
          ({
            TranslationDirection direction,
            String origin,
            String historyEntryId,
            String screenshotCaptureId,
          })
        >[];
    final completed = Completer<void>();
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'hello',
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) async {
            requests.add((
              direction: direction,
              origin: origin,
              historyEntryId: historyEntryId,
              screenshotCaptureId: screenshotCaptureId,
            ));
            return 'translation ${requests.length}';
          },
    );
    await runtime.startCapture();
    final historyId = runtime.session!.id;
    runtime.addListener(() {
      final session = runtime.session;
      if (session?.status == ScreenshotTranslationStatus.completed &&
          session?.direction == TranslationDirection.chineseToEnglish &&
          !completed.isCompleted) {
        completed.complete();
      }
    });

    await runtime.handleMessage(
      ScreenshotTranslationWindowMessage(
        type: 'retranslateRequested',
        requestId: 'reverse-direction',
        payload: {
          'sessionId': historyId,
          'source': 'hello',
          'reverseDirection': true,
        },
      ),
    );
    await completed.future;

    expect(requests.map((request) => request.direction), [
      TranslationDirection.englishToChinese,
      TranslationDirection.chineseToEnglish,
    ]);
    expect(requests.map((request) => request.historyEntryId), [
      historyId,
      '$historyId-v1',
    ]);
    expect(requests.map((request) => request.screenshotCaptureId), [
      historyId,
      historyId,
    ]);
    expect(requests.map((request) => request.origin), [
      'screenshot_translation',
      'screenshot_translation',
    ]);
    expect(runtime.session!.id, historyId);
    expect(runtime.session!.recognizedText, 'hello');
    expect(runtime.session!.direction, TranslationDirection.chineseToEnglish);
    expect(runtime.session!.directionManuallyOverridden, isTrue);
    expect(
      ScreenshotTranslationSession.fromMap(runtime.session!.toMap())
          .directionManuallyOverridden,
      isTrue,
    );
    final legacyPayload = runtime.session!.toMap()
      ..remove('directionManuallyOverridden');
    expect(
      ScreenshotTranslationSession.fromMap(legacyPayload)
          .directionManuallyOverridden,
      isFalse,
    );
    await runtime.shutdown();
    runtime.dispose();
  });

  test('oversized OCR text is rejected before entering the session or result window', () async {
    final window = RecordingWindow();
    var translations = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async =>
          'x' * (screenshotTranslationMaxSourceCharacters + 1),
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) async {
            translations++;
            return '译文';
          },
      createResultWindow: () async => window,
    );

    await runtime.startCapture();

    expect(runtime.session!.status, ScreenshotTranslationStatus.failed);
    expect(runtime.session!.errorCode, 'ocr_output_limit');
    expect(runtime.session!.recognizedText, isEmpty);
    expect(translations, 0);
    expect(window.sessions, isNotEmpty);
    expect(
      window.sessions.whereType<ScreenshotTranslationSession>().every(
        (session) =>
            session.recognizedText.length <=
            screenshotTranslationMaxSourceCharacters,
      ),
      isTrue,
    );
    runtime.dispose();
  });

  test(
    'oversized edited source does not reach the translation provider',
    () async {
      var translations = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello',
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              translations++;
              return '你好';
            },
      );

      await runtime.startCapture();
      await runtime.retranslate(
        'x' * (screenshotTranslationMaxSourceCharacters + 1),
      );

      expect(translations, 1);
      expect(runtime.session!.status, ScreenshotTranslationStatus.failed);
      expect(runtime.session!.errorCode, 'ocr_output_limit');
      expect(runtime.session!.recognizedText, 'hello');
      runtime.dispose();
    },
  );

  test(
    'manual direction survives an unchanged retry and resets after an edit',
    () async {
      var translationCalls = 0;
      final directions = <TranslationDirection>[];
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello',
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              directions.add(direction);
              translationCalls++;
              if (translationCalls == 2) {
                throw const QuickTranslationException('network_error');
              }
              return 'translation $translationCalls';
            },
      );

      await runtime.startCapture();
      await runtime.retranslateInOppositeDirection('hello');
      expect(runtime.session!.status, ScreenshotTranslationStatus.failed);
      expect(runtime.session!.directionManuallyOverridden, isTrue);

      await runtime.retranslate('hello');
      expect(runtime.session!.direction, TranslationDirection.chineseToEnglish);
      expect(runtime.session!.directionManuallyOverridden, isTrue);

      await runtime.retranslate('hello edited');
      expect(runtime.session!.direction, TranslationDirection.englishToChinese);
      expect(runtime.session!.directionManuallyOverridden, isFalse);
      expect(directions, [
        TranslationDirection.englishToChinese,
        TranslationDirection.chineseToEnglish,
        TranslationDirection.chineseToEnglish,
        TranslationDirection.englishToChinese,
      ]);

      await runtime.shutdown();
      runtime.dispose();
    },
  );

  test(
    'capture snapshots image-retention preference before awaiting capture',
    () async {
      var saveEnabled = true;
      final captureResult = Completer<CapturedData?>();
      final imageStore = MemoryScreenshotImageStore();
      final runtime = ScreenshotTranslationRuntime(
        capture: () => captureResult.future,
        recognize: (_, [_]) async => 'visible text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        imageStore: imageStore,
        saveScreenshotImages: () => saveEnabled,
      );

      final capture = runtime.startCapture();
      saveEnabled = false;
      captureResult.complete(pixels());
      await capture;

      final session = runtime.session!;
      expect(session.imageSaveAllowed, isTrue);
      expect(
        session.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.saved,
      );
      expect(imageStore.savedIds, [session.id]);
      expect(imageStore.images[session.id], [1]);
      runtime.dispose();
    },
  );

  test(
    'retranslation creates a new history ID but saves under the capture ID',
    () async {
      final events = <String>[];
      final imageStore = MemoryScreenshotImageStore(events: events);
      final runnerIds = <String>[];
      final captureIds = <String>[];
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'visible text',
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              runnerIds.add(historyEntryId);
              captureIds.add(screenshotCaptureId);
              events.add('translation:$historyEntryId');
              return '译文';
            },
        imageStore: imageStore,
      );

      await runtime.startCapture();
      final historyId = runtime.session!.id;
      await runtime.retranslate('edited text');

      expect(runnerIds, [historyId, '$historyId-v1']);
      expect(captureIds, [historyId, historyId]);
      expect(imageStore.savedIds, [historyId, historyId]);
      expect(events, [
        'translation:$historyId',
        'image-save:$historyId',
        'translation:$historyId-v1',
        'image-save:$historyId',
      ]);
      expect(imageStore.images.keys, [historyId]);
      expect(runtime.session!.id, historyId);
      expect(runtime.session!.recognizedText, 'edited text');
      runtime.dispose();
    },
  );

  test(
    'disabled capture-time preference skips image persistence and retry',
    () async {
      final imageStore = MemoryScreenshotImageStore();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'visible text',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '译文',
        imageStore: imageStore,
        saveScreenshotImages: () => false,
      );

      await runtime.startCapture();
      expect(runtime.session!.imageBytes, [1]);
      expect(runtime.session!.imageSaveAllowed, isFalse);
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.notRequested,
      );
      expect(imageStore.savedIds, isEmpty);
      await runtime.retryImageSave();
      expect(imageStore.savedIds, isEmpty);
      runtime.dispose();
    },
  );

  test('image save failure preserves translation and retry uses retained session bytes', () async {
    final imageStore = MemoryScreenshotImageStore()..failNextSave = true;
    var runnerCalls = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'visible text',
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) async {
            runnerCalls++;
            return '译文';
          },
      imageStore: imageStore,
    );

    await runtime.startCapture();
    final failedSession = runtime.session!;
    expect(failedSession.status, ScreenshotTranslationStatus.completed);
    expect(failedSession.translatedText, '译文');
    expect(
      failedSession.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.failed,
    );
    expect(failedSession.errorCode, isNull);
    expect(failedSession.imageBytes, [1]);
    expect(runnerCalls, 1);

    await runtime.retryImageSave();
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.saved,
    );
    expect(imageStore.savedIds, [failedSession.id, failedSession.id]);
    expect(runnerCalls, 1);
    final roundTrip = ScreenshotTranslationSession.fromMap(
      runtime.session!.toMap(),
    );
    expect(roundTrip.imageSaveAllowed, isTrue);
    expect(
      roundTrip.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.saved,
    );
    runtime.dispose();
  });

  test('retry cache rejects a crop larger than its byte budget', () async {
    final imageStore = MemoryScreenshotImageStore()..failNextSave = true;
    final oversizedCapture = CapturedData(
      width: ScreenshotTranslationRuntime.maxRetryableImageSaveBytes + 1,
      height: 1,
      bytes: Uint8List(
        ScreenshotTranslationRuntime.maxRetryableImageSaveBytes + 1,
      ),
      left: 0,
    );
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => oversizedCapture,
      recognize: (_, [_]) async => 'visible text',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => '译文',
      imageStore: imageStore,
    );

    await runtime.startCapture();

    expect(
      runtime.retryableImageSaves.single.historyEntryId,
      runtime.session!.id,
    );
    expect(runtime.retryableImageSaveCacheCount, 0);
    expect(runtime.retryableImageSaveCacheBytes, 0);
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.cacheLimitReached,
    );
    expect(runtime.session!.imageSaveMessage, contains('当前结果仍可重试'));
    final id = runtime.session!.id;
    await runtime.retryImageSave();
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.saved,
    );
    expect(
      imageStore.images[id]!.lengthInBytes,
      ScreenshotTranslationRuntime.maxRetryableImageSaveBytes + 1,
    );
    expect(runtime.retryableImageSaveCacheBytes, 0);
    runtime.dispose();
  });

  test('active cache-overflow retry is invalidated by purge and unavailable after close', () async {
    final imageStore = MemoryScreenshotImageStore();
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'visible text',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => '译文',
      imageStore: imageStore,
    );
    for (
      var i = 0;
      i <= ScreenshotTranslationRuntime.maxRetryableImageSaveCount;
      i++
    ) {
      imageStore.failNextSave = true;
      await runtime.startCapture();
    }
    final id = runtime.session!.id;
    runtime.purgeRetryableImageSave(id);
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.invalidated,
    );
    final saveCount = imageStore.savedIds.length;
    await runtime.retryImageSave(historyEntryId: id);
    expect(imageStore.savedIds.length, saveCount);
    imageStore.failNextSave = true;
    await runtime.startCapture();
    final nextId = runtime.session!.id;
    await runtime.closeResult();
    final closedCount = imageStore.savedIds.length;
    expect(
      runtime.retryableImageSaves.any((item) => item.historyEntryId == nextId),
      isFalse,
    );
    await runtime.retryImageSave(historyEntryId: nextId);
    expect(imageStore.savedIds.length, closedCount);
    await runtime.shutdown();
    runtime.dispose();
  });

  test(
    'translation runner receives only recognized text and history metadata',
    () async {
      final received = <String, Object?>{};
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'OCR words',
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              received.addAll({
                'source': source,
                'direction': direction.name,
                'origin': origin,
                'historyEntryId': historyEntryId,
              });
              return '译文';
            },
        imageStore: MemoryScreenshotImageStore(),
      );

      await runtime.startCapture();

      expect(received.keys, {
        'source',
        'direction',
        'origin',
        'historyEntryId',
      });
      expect(received['source'], 'OCR words');
      expect(received['origin'], 'screenshot_translation');
      expect(runtime.session!.imageBytes, [1]);
      runtime.dispose();
    },
  );
  test('new capture does not cancel an unrelated quick translation', () async {
    var cancellations = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => null,
      recognize: (_, [_]) async => '',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => '',
      cancelTranslation: () async {
        cancellations++;
        return true;
      },
    );
    await runtime.startCapture();
    expect(cancellations, 0);
    runtime.dispose();
  });

  test('simultaneous retranslate keeps the latest edited source', () async {
    final cancel = Completer<bool>();
    final firstResult = Completer<String>();
    var calls = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'original',
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) {
            calls++;
            return calls == 1 ? firstResult.future : Future.value(source);
          },
      cancelTranslation: () => cancel.future,
    );
    final capture = runtime.startCapture();
    await Future<void>.delayed(Duration.zero);
    final firstEdit = runtime.retranslate('outdated edit');
    final latestEdit = runtime.retranslate('latest edit');
    cancel.complete(true);
    firstResult.complete('old result');
    await Future.wait([capture, firstEdit, latestEdit]);
    expect(runtime.session!.recognizedText, 'latest edit');
    expect(runtime.session!.translatedText, 'latest edit');
    expect(calls, 2);
    runtime.dispose();
  });

  test(
    'slow result creation is reused across two replacement captures',
    () async {
      final created = Completer<ScreenshotTranslationResultHandle>();
      var windows = 0;
      var captures = 0;
      final handle = RecordingWindow();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async {
          captures++;
          return pixels();
        },
        recognize: (_, [_]) async => 'hello',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好',
        createResultWindow: () {
          windows++;
          return created.future;
        },
      );
      final first = runtime.startCapture();
      await Future<void>.delayed(Duration.zero);
      final second = runtime.startCapture();
      await Future<void>.delayed(Duration.zero);
      final latest = runtime.session!.id;
      created.complete(handle);
      await Future.wait([first, second]);
      expect(captures, 2);
      expect(windows, 1);
      expect(
        handle.sessions.whereType<ScreenshotTranslationSession>().every(
          (s) => s.id == latest,
        ),
        isTrue,
      );
      runtime.dispose();
    },
  );
  test('late_translation_for_previous_session_is_ignored', () async {
    final late = Completer<String>();
    var calls = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'hello',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) => ++calls == 1 ? late.future : Future.value('新译文'),
      cancelTranslation: () async => true,
    );
    final first = runtime.startCapture();
    await Future<void>.delayed(Duration.zero);
    final second = runtime.startCapture();
    await Future<void>.delayed(Duration.zero);
    final latestId = runtime.session!.id;
    late.complete('旧译文');
    await Future.wait([first, second]);
    expect(runtime.session!.id, latestId);
    expect(runtime.session!.translatedText, '新译文');
    runtime.dispose();
  });

  test('failed_translation_preserves_recognized_source', () async {
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'hello world',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => throw const QuickTranslationException('network_error'),
    );
    await runtime.startCapture();
    expect(runtime.session!.status, ScreenshotTranslationStatus.failed);
    expect(runtime.session!.recognizedText, 'hello world');
    expect(runtime.session!.imageBytes, isNotNull);
    expect(runtime.session!.errorCode, 'network_error');
    runtime.dispose();
  });

  test(
    'dictionary lookup remains available after screenshot translation fails',
    () async {
      var lookedUpWord = '';
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello world',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => throw const QuickTranslationException('network_error'),
        onLookupDictionary: (word) async {
          lookedUpWord = word;
          return const DictionaryEntry(
            word: 'hello',
            ipa: '/həˈləʊ/',
            partOfSpeech: 'int.',
            meanings: ['你好'],
            example: 'Hello there.',
            exampleTranslation: '你好。',
            variants: ['hellos'],
            collocationCandidates: ['say hello'],
          );
        },
      );
      await runtime.startCapture();
      final session = runtime.session!;
      expect(session.status, ScreenshotTranslationStatus.failed);

      final ack = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'lookupScreenshotWord',
          requestId: 'lookup-failed-session',
          payload: {
            'sessionId': session.id,
            'word': 'hello',
            'recognizedText': session.recognizedText,
          },
        ),
      );

      expect(lookedUpWord, 'hello');
      expect(ack?.payload['entry'], isA<Map>());
      expect((ack!.payload['entry'] as Map)['variants'], ['hellos']);
      expect((ack.payload['entry'] as Map)['collocations'], ['say hello']);
      await runtime.shutdown();
    },
  );

  test(
    'selected OCR word can use the configured translation service',
    () async {
      var translatedWord = '';
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello world',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => 'unused',
        translateSelectedWord: (word, _) async {
          translatedWord = word;
          return '你好';
        },
      );
      await runtime.startCapture();
      final session = runtime.session!;

      final ack = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'translate-word-1',
          payload: {
            'sessionId': session.id,
            'word': 'hello',
            'recognizedText': session.recognizedText,
          },
        ),
      );

      expect(translatedWord, 'hello');
      expect(ack?.payload['translation'], '你好');
      await runtime.shutdown();
    },
  );

  test(
    'selected OCR word rejects stale session text before translation',
    () async {
      var translationCalls = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello world',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => 'unused',
        translateSelectedWord: (word, _) async {
          translationCalls++;
          return '你好';
        },
      );
      await runtime.startCapture();
      final session = runtime.session!;
      final ack = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'translate-word-stale',
          payload: {
            'sessionId': session.id,
            'word': 'hello',
            'recognizedText': 'different source text',
          },
        ),
      );

      expect(ack?.payload['errorCode'], 'stale_session');
      expect(translationCalls, 0);
      await runtime.shutdown();
    },
  );

  test(
    'timed out selected word translation cannot be retried while still running',
    () async {
      final inFlightTranslation = Completer<String>();
      var translationCalls = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello world',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => 'unused',
        selectedWordTranslationTimeout: const Duration(milliseconds: 5),
        translateSelectedWord: (word, _) {
          translationCalls++;
          return translationCalls == 1
              ? inFlightTranslation.future
              : Future<String>.value('你好');
        },
      );
      await runtime.startCapture();
      final session = runtime.session!;

      final request = ScreenshotTranslationWindowMessage(
        type: 'translateScreenshotWord',
        requestId: 'translate-word-timeout',
        payload: {
          'sessionId': session.id,
          'word': 'hello',
          'recognizedText': session.recognizedText,
        },
      );
      final timedOut = await runtime.handleMessage(request);
      final blockedRetry = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'translate-word-retry-too-soon',
          payload: {
            'sessionId': session.id,
            'word': 'world',
            'recognizedText': session.recognizedText,
          },
        ),
      );

      expect(timedOut?.payload['errorCode'], 'translation_timeout');
      expect(blockedRetry?.payload['errorCode'], 'translation_in_progress');
      expect(translationCalls, 1);

      inFlightTranslation.complete('你好');
      await Future<void>.delayed(Duration.zero);
      final retryAfterSettle = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'translate-word-retry-after-settle',
          payload: {
            'sessionId': session.id,
            'word': 'world',
            'recognizedText': session.recognizedText,
          },
        ),
      );

      expect(retryAfterSettle?.payload['translation'], '你好');
      expect(translationCalls, 2);
      await runtime.shutdown();
    },
  );

  test(
    'timed out selected word translation asks its exact operation to stop',
    () async {
      final cancelledWork = Completer<String>();
      final operationIds = <String>[];
      final cancelledOperationIds = <String>[];
      var translationCalls = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello world',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => 'unused',
        selectedWordTranslationTimeout: const Duration(milliseconds: 5),
        translateSelectedWord: (word, operationId) {
          operationIds.add(operationId);
          translationCalls++;
          return translationCalls == 1
              ? cancelledWork.future
              : Future<String>.value('世界');
        },
        cancelSelectedWordTranslation: (operationId) async {
          cancelledOperationIds.add(operationId);
          cancelledWork.completeError(
            const QuickTranslationException('cancelled'),
          );
          return true;
        },
      );
      await runtime.startCapture();
      final session = runtime.session!;

      final timedOut = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'translate-word-cancel',
          payload: {
            'sessionId': session.id,
            'word': 'hello',
            'recognizedText': session.recognizedText,
          },
        ),
      );
      final retried = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'translate-word-after-cancel',
          payload: {
            'sessionId': session.id,
            'word': 'world',
            'recognizedText': session.recognizedText,
          },
        ),
      );

      expect(timedOut?.payload['errorCode'], 'translation_cancelled');
      expect(cancelledOperationIds, [operationIds.first]);
      expect(retried?.payload['translation'], '世界');
      expect(translationCalls, 2);
      await runtime.shutdown();
    },
  );

  test(
    'a refused selected word cancellation keeps the single-flight reservation',
    () async {
      final pendingTranslation = Completer<String>();
      final operationIds = <String>[];
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [_]) async => 'hello world',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => 'unused',
        translateSelectedWord: (word, operationId) {
          operationIds.add(operationId);
          return pendingTranslation.future;
        },
        cancelSelectedWordTranslation: (_) async => false,
      );
      await runtime.startCapture();
      final session = runtime.session!;
      final firstRequest = runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'word-operation-1',
          payload: {
            'sessionId': session.id,
            'word': 'hello',
            'recognizedText': session.recognizedText,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final cancellation = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'cancelScreenshotWordTranslation',
          requestId: 'word-cancel-1',
          payload: const {'operationId': 'word-operation-1'},
        ),
      );
      expect(cancellation!.payload['cancelled'], isFalse);

      final rejectedRetry = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'word-operation-2',
          payload: {
            'sessionId': session.id,
            'word': 'world',
            'recognizedText': session.recognizedText,
          },
        ),
      );
      expect(rejectedRetry!.payload['errorCode'], 'translation_in_progress');
      expect(operationIds, ['word-operation-1']);

      pendingTranslation.complete('你好');
      final firstAck = await firstRequest;
      expect(firstAck!.payload['translation'], '你好');
      final retryAfterCompletion = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'translateScreenshotWord',
          requestId: 'word-operation-3',
          payload: {
            'sessionId': session.id,
            'word': 'world',
            'recognizedText': session.recognizedText,
          },
        ),
      );
      expect(retryAfterCompletion!.payload['translation'], '你好');
      expect(operationIds, ['word-operation-1', 'word-operation-3']);
      await runtime.shutdown();
    },
  );

  test('selected OCR word reports missing translation configuration', () async {
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [_]) async => 'hello world',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => 'unused',
      translateSelectedWord: (word, _) async =>
          throw const QuickTranslationException('no_remote_provider'),
    );
    await runtime.startCapture();
    final session = runtime.session!;
    final ack = await runtime.handleMessage(
      ScreenshotTranslationWindowMessage(
        type: 'translateScreenshotWord',
        requestId: 'translate-word-no-provider',
        payload: {
          'sessionId': session.id,
          'word': 'hello',
          'recognizedText': session.recognizedText,
        },
      ),
    );

    expect(ack?.payload['errorCode'], 'translation_unavailable');
    await runtime.shutdown();
  });

  test('cancelled_or_empty_capture_does_not_record_history', () async {
    var records = 0;
    var cancelled = true;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => cancelled ? null : pixels(),
      recognize: (_, [_]) async => '  ',
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) async {
            records++;
            return 'never';
          },
    );
    await runtime.startCapture();
    expect(runtime.session!.status, ScreenshotTranslationStatus.cancelled);
    cancelled = false;
    await runtime.startCapture();
    expect(runtime.session!.status, ScreenshotTranslationStatus.empty);
    expect(records, 0);
    runtime.dispose();
  });

  test(
    'simultaneous_capture_requests_use_one_overlay_and_result_window',
    () async {
      final nativeCapture = Completer<CapturedData?>();
      var captures = 0;
      var windows = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () {
          captures++;
          return nativeCapture.future;
        },
        recognize: (_, [_]) async => 'hello',
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              expect(origin, 'screenshot_translation');
              return '你好';
            },
        createResultWindow: () async {
          windows++;
          return FakeWindow();
        },
      );
      final first = runtime.startCapture();
      final second = runtime.startCapture();
      nativeCapture.complete(pixels());
      await Future.wait([first, second]);
      expect(captures, 1);
      expect(windows, 1);
      runtime.dispose();
    },
  );

  test(
    'pinned region refresh uses exact bounds and reports image changes',
    () async {
      final bounds = pixels().bounds;
      ScreenshotBounds? pinnedRegion;
      ScreenshotBounds? requestedBounds;
      var recognitionCalls = 0;
      final refreshedOcrStarted = Completer<void>();
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        captureAtBounds: (value) async {
          requestedBounds = value;
          return CapturedData(
            width: value.width,
            height: value.height,
            left: value.left,
            top: value.top,
            bytes: Uint8List.fromList([2]),
          );
        },
        pinnedRegion: () => pinnedRegion,
        persistPinnedRegion: (value) async {
          pinnedRegion = value;
          return true;
        },
        recognize: (_, [_]) async {
          if (++recognitionCalls == 2) refreshedOcrStarted.complete();
          return 'hello';
        },
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好',
      );
      addTearDown(() async {
        await runtime.shutdown();
        runtime.dispose();
      });

      await runtime.startCapture();
      final firstSession = runtime.session!;
      final pinAck = await runtime.handleMessage(
        ScreenshotTranslationWindowMessage(
          type: 'togglePinnedRegionRequested',
          requestId: 'pin-current-region',
          payload: {'sessionId': firstSession.id, 'pinned': true},
        ),
      );
      expect(pinAck?.payload['pinned'], isTrue);
      expect(pinnedRegion, bounds);

      expect(
        await runtime.startPinnedCapture(
          bounds: bounds,
          expectedSessionId: 'stale-session',
        ),
        isFalse,
      );
      expect(requestedBounds, isNull);

      expect(
        await runtime.startPinnedCapture(
          bounds: bounds,
          expectedSessionId: firstSession.id,
        ),
        isTrue,
      );
      await refreshedOcrStarted.future;
      expect(requestedBounds, bounds);
      expect(runtime.session?.regionPinned, isTrue);
      expect(runtime.session?.regionContentChanged, isTrue);
    },
  );

  test(
    'pinned refresh waits for preference mutation and rejects a cleared region',
    () async {
      final bounds = pixels().bounds;
      ScreenshotBounds? pinnedRegion = bounds;
      final persistenceStarted = Completer<void>();
      final persistenceGate = Completer<void>();
      var fixedCaptureCalls = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        captureAtBounds: (value) async {
          fixedCaptureCalls++;
          return CapturedData(
            width: value.width,
            height: value.height,
            left: value.left,
            top: value.top,
            bytes: Uint8List.fromList([2]),
          );
        },
        pinnedRegion: () => pinnedRegion,
        persistPinnedRegion: (value) async {
          persistenceStarted.complete();
          await persistenceGate.future;
          pinnedRegion = value;
          return true;
        },
        recognize: (_, [_]) async => 'hello',
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => '你好',
      );
      addTearDown(() async {
        await runtime.shutdown();
        runtime.dispose();
      });

      await runtime.startCapture();
      final expectedSessionId = runtime.session!.id;
      final clearing = runtime.updatePinnedRegionPreference(null);
      await persistenceStarted.future;
      final refresh = runtime.startPinnedCapture(
        bounds: bounds,
        expectedSessionId: expectedSessionId,
      );
      expect(fixedCaptureCalls, 0);

      persistenceGate.complete();
      expect(await clearing, isTrue);
      expect(await refresh, isFalse);
      expect(fixedCaptureCalls, 0);
    },
  );

  test(
    'close_during_recognition_releases_image_and_ignores_late_result',
    () async {
      var translated = false;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [token]) async {
          await token!.whenCancelled;
          return 'late OCR result';
        },
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              translated = true;
              return '你好';
            },
      );
      final work = runtime.startCapture();
      await Future<void>.delayed(Duration.zero);
      await runtime.closeResult();
      await work;
      expect(runtime.session, isNull);
      expect(translated, isFalse);
      runtime.dispose();
    },
  );

  test('closing a result cancels OCR and waits for cleanup', () async {
    final ocrStarted = Completer<ScreenshotTranslationCancellationToken>();
    final cleanup = Completer<void>();
    var cleanupFinished = false;
    var translations = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [token]) async {
        ocrStarted.complete(token!);
        await token.whenCancelled;
        await cleanup.future;
        cleanupFinished = true;
        throw const ScreenshotTranslationCancelledException();
      },
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) async {
            translations++;
            return 'must not translate';
          },
    );

    final work = runtime.startCapture();
    final token = await ocrStarted.future;
    var closeFinished = false;
    final close = runtime.closeResult().then((_) => closeFinished = true);
    await Future<void>.delayed(Duration.zero);

    expect(token.isCancelled, isTrue);
    expect(closeFinished, isFalse);
    expect(cleanupFinished, isFalse);
    cleanup.complete();
    await Future.wait([work, close]);

    expect(cleanupFinished, isTrue);
    expect(runtime.session, isNull);
    expect(translations, 0);
    runtime.dispose();
  });

  test(
    'a replacement capture cancels and waits for previous OCR cleanup',
    () async {
      final firstOcrStarted =
          Completer<ScreenshotTranslationCancellationToken>();
      final firstOcrCleanup = Completer<void>();
      var captures = 0;
      var recognitions = 0;
      var firstCleanupFinished = false;
      final translatedSources = <String>[];
      final runtime = ScreenshotTranslationRuntime(
        capture: () async {
          captures++;
          return pixels();
        },
        recognize: (_, [token]) async {
          recognitions++;
          if (recognitions == 1) {
            firstOcrStarted.complete(token!);
            await token.whenCancelled;
            await firstOcrCleanup.future;
            firstCleanupFinished = true;
            throw const ScreenshotTranslationCancelledException();
          }
          return 'latest text';
        },
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              translatedSources.add(source);
              return '译文';
            },
      );

      final first = runtime.startCapture();
      final firstToken = await firstOcrStarted.future;
      final replacement = runtime.startCapture();
      await Future<void>.delayed(Duration.zero);
      expect(firstToken.isCancelled, isTrue);
      expect(captures, 1);
      expect(firstCleanupFinished, isFalse);

      firstOcrCleanup.complete();
      await Future.wait([first, replacement]);

      expect(firstCleanupFinished, isTrue);
      expect(captures, 2);
      expect(translatedSources, ['latest text']);
      expect(runtime.session?.recognizedText, 'latest text');
      runtime.dispose();
    },
  );

  test(
    'shutdown waits for a native screenshot selection before returning',
    () async {
      final captureStarted = Completer<void>();
      final captureGate = Completer<CapturedData?>();
      var recognitionCalls = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () {
          captureStarted.complete();
          return captureGate.future;
        },
        recognize: (_, [_]) async {
          recognitionCalls++;
          return 'must not recognize after shutdown';
        },
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => 'must not translate',
      );

      final capture = runtime.startCapture();
      await captureStarted.future;
      var shutdownFinished = false;
      final shutdown = runtime.shutdown().then((_) => shutdownFinished = true);
      await Future<void>.delayed(Duration.zero);

      expect(shutdownFinished, isFalse);
      captureGate.complete(pixels());
      await Future.wait([capture, shutdown]);

      expect(shutdownFinished, isTrue);
      expect(recognitionCalls, 0);
      expect(runtime.session, isNull);
      runtime.dispose();
    },
  );

  test(
    'shutdown waits for capture-guard cleanup after native capture returns',
    () async {
      final nativeCaptureReturned = Completer<void>();
      final guardCleanupStarted = Completer<void>();
      final guardCleanupGate = Completer<void>();
      var recognitionCalls = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async {
          nativeCaptureReturned.complete();
          return pixels();
        },
        recognize: (_, [_]) async {
          recognitionCalls++;
          return 'must not recognize after shutdown';
        },
        translate: (
          source,
          direction, {
          required origin,
          required historyEntryId,
          required screenshotCaptureId,
        }) async => 'must not translate',
      );

      final capture = runtime.startWorkbenchCapture(
        captureGuard: (runCapture) async {
          try {
            return await runCapture();
          } finally {
            guardCleanupStarted.complete();
            await guardCleanupGate.future;
          }
        },
      );
      await nativeCaptureReturned.future;
      await guardCleanupStarted.future;
      var shutdownFinished = false;
      final shutdown = runtime.shutdown().then((_) => shutdownFinished = true);
      await Future<void>.delayed(Duration.zero);

      expect(shutdownFinished, isFalse);
      guardCleanupGate.complete();
      await Future.wait([capture, shutdown]);

      expect(shutdownFinished, isTrue);
      expect(recognitionCalls, 0);
      expect(runtime.session, isNull);
      runtime.dispose();
    },
  );

  test('shutdown cancels OCR and waits for cleanup before returning', () async {
    final ocrStarted = Completer<ScreenshotTranslationCancellationToken>();
    final cleanup = Completer<void>();
    var cleanupFinished = false;
    var translations = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => pixels(),
      recognize: (_, [token]) async {
        ocrStarted.complete(token!);
        await token.whenCancelled;
        await cleanup.future;
        cleanupFinished = true;
        throw const ScreenshotTranslationCancelledException();
      },
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) async {
            translations++;
            return 'must not translate';
          },
    );

    final work = runtime.startCapture();
    final token = await ocrStarted.future;
    var shutdownFinished = false;
    final shutdown = runtime.shutdown().then((_) => shutdownFinished = true);
    await Future<void>.delayed(Duration.zero);

    expect(token.isCancelled, isTrue);
    expect(shutdownFinished, isFalse);
    expect(cleanupFinished, isFalse);
    cleanup.complete();
    await Future.wait([work, shutdown]);

    expect(cleanupFinished, isTrue);
    expect(runtime.session, isNull);
    expect(translations, 0);
    runtime.dispose();
  });

  test(
    'shutdown still waits for OCR cleanup after dispose has started',
    () async {
      final ocrStarted = Completer<ScreenshotTranslationCancellationToken>();
      final cleanup = Completer<void>();
      var cleanupFinished = false;
      var translations = 0;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async => pixels(),
        recognize: (_, [token]) async {
          ocrStarted.complete(token!);
          await token.whenCancelled;
          await cleanup.future;
          cleanupFinished = true;
          throw const ScreenshotTranslationCancelledException();
        },
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              translations++;
              return 'must not translate';
            },
      );

      final work = runtime.startCapture();
      final token = await ocrStarted.future;
      runtime.dispose();
      var shutdownFinished = false;
      final shutdown = runtime.shutdown().then((_) => shutdownFinished = true);
      await Future<void>.delayed(Duration.zero);
      final finishedBeforeCleanup = shutdownFinished;

      expect(token.isCancelled, isTrue);
      cleanup.complete();
      await Future.wait([work, shutdown]);

      expect(finishedBeforeCleanup, isFalse);
      expect(cleanupFinished, isTrue);
      expect(translations, 0);
    },
  );

  test(
    'OCR timeout and temp cleanup failure never reach translation',
    () async {
      Future<void> expectOcrFailure(Object error, String expectedCode) async {
        var translations = 0;
        final runtime = ScreenshotTranslationRuntime(
          capture: () async => pixels(),
          recognize: (_, [_]) async => throw error,
          translate:
              (
                source,
                direction, {
                required origin,
                required historyEntryId,
                required screenshotCaptureId,
              }) async {
                translations++;
                return 'must not translate';
              },
        );

        await runtime.startCapture();

        expect(runtime.session?.status, ScreenshotTranslationStatus.failed);
        expect(runtime.session?.recognizedText, isEmpty);
        expect(runtime.session?.errorCode, expectedCode);
        expect(translations, 0);
        runtime.dispose();
      }

      await expectOcrFailure(
        const ScreenshotTranslationOcrException(
          'ocr_timeout',
          'OCR 页面处理超时，已取消',
        ),
        'ocr_timeout',
      );
      await expectOcrFailure(
        FileSystemException('temporary cleanup failed'),
        'unknown_error',
      );
    },
  );
}

class FakeWindow implements ScreenshotTranslationResultHandle {
  @override
  Future<void> update(ScreenshotTranslationSession? session) async {}
  @override
  Future<void> hide() async {}
}

class RecordingWindow extends FakeWindow {
  final sessions = <ScreenshotTranslationSession?>[];
  @override
  Future<void> update(ScreenshotTranslationSession? session) async {
    sessions.add(session);
  }
}

class _SupersededWindow extends FakeWindow {
  @override
  Future<void> update(ScreenshotTranslationSession? session) async {
    throw const ScreenshotTranslationResultHandleSupersededException();
  }
}

class _ToggleSupersededWindow extends RecordingWindow {
  bool superseded = false;

  @override
  Future<void> update(ScreenshotTranslationSession? session) async {
    if (superseded) {
      throw const ScreenshotTranslationResultHandleSupersededException();
    }
    await super.update(session);
  }
}

class _GatedResultWindow extends RecordingWindow {
  final events = <String>[];
  final updateStarted = Completer<void>();
  final updateGate = Completer<void>();
  var _gateNextUpdate = false;

  void gateNextUpdate() => _gateNextUpdate = true;

  @override
  Future<void> update(ScreenshotTranslationSession? session) async {
    sessions.add(session);
    events.add(session == null ? 'clear' : 'update:${session.id}');
    if (!_gateNextUpdate) return;
    _gateNextUpdate = false;
    updateStarted.complete();
    await updateGate.future;
  }

  @override
  Future<void> hide() async => events.add('hide');
}

class MemoryScreenshotImageStore implements ScreenshotTranslationImageStore {
  MemoryScreenshotImageStore({this.events});

  final List<String>? events;
  final images = <String, Uint8List>{};
  final savedIds = <String>[];
  var failNextSave = false;
  Completer<void>? saveStarted;
  Completer<void>? saveGate;

  @override
  Future<void> save(String historyId, Uint8List pngBytes) async {
    savedIds.add(historyId);
    final started = saveStarted;
    if (started != null && !started.isCompleted) started.complete();
    await saveGate?.future;
    if (failNextSave) {
      failNextSave = false;
      throw FileSystemException('simulated image storage failure');
    }
    events?.add('image-save:$historyId');
    images[historyId] = Uint8List.fromList(pngBytes);
  }

  @override
  Future<Uint8List?> read(String historyId) async => images[historyId];

  @override
  Future<void> delete(String historyId) async => images.remove(historyId);

  @override
  Future<ScreenshotTranslationImageStats> inspect() async =>
      ScreenshotTranslationImageStats(
        imageCount: images.length,
        totalBytes: images.values.fold(0, (sum, bytes) => sum + bytes.length),
      );

  @override
  Future<void> clearAll() async => images.clear();
}

class _DeferredScreenshotPreferencesStore
    implements ScreenshotTranslationPreferencesStore {
  final readStarted = Completer<void>();
  final readResult = Completer<ScreenshotTranslationPreferences>();

  void complete(ScreenshotTranslationPreferences value) =>
      readResult.complete(value);

  @override
  Future<ScreenshotTranslationPreferences> read() {
    if (!readStarted.isCompleted) readStarted.complete();
    return readResult.future;
  }

  @override
  Future<void> write(ScreenshotTranslationPreferences value) async {}
}

class _NoopScreenshotHotKeys implements ScreenshotGlobalHotKey {
  @override
  Future<void> register(
    ScreenshotHotKey key,
    void Function() onPressed,
  ) async {}

  @override
  Future<void> unregister() async {}
}

class _NoopScreenshotOrb implements ScreenshotOrbHandle {
  @override
  Future<void> open(ScreenshotOrbPosition? position) async {}

  @override
  Future<void> close() async {}
}

class DeferredCoordinatedImageStore
    implements ScreenshotTranslationCoordinatedImageStore {
  DeferredCoordinatedImageStore(this.delegate);

  final FileScreenshotTranslationImageStore delegate;
  final saveStarted = Completer<void>();
  final allowSave = Completer<void>();
  bool failAfterGate = false;

  @override
  ScreenshotTranslationImageWriteLease beginImageWrite(String historyId) =>
      delegate.beginImageWrite(historyId);

  @override
  bool acceptsImageWriteLease(
    String historyId,
    ScreenshotTranslationImageWriteLease lease,
  ) => delegate.acceptsImageWriteLease(historyId, lease);

  @override
  Future<bool> saveWithLease(
    String historyId,
    Uint8List pngBytes,
    ScreenshotTranslationImageWriteLease lease,
  ) async {
    saveStarted.complete();
    await allowSave.future;
    if (failAfterGate) throw StateError('simulated save failure after purge');
    return delegate.saveWithLease(historyId, pngBytes, lease);
  }

  @override
  Future<void> save(String historyId, Uint8List pngBytes) =>
      delegate.save(historyId, pngBytes);

  @override
  Future<Uint8List?> read(String historyId) => delegate.read(historyId);

  @override
  Future<void> delete(String historyId) => delegate.delete(historyId);

  @override
  Future<T> deleteImageAndThen<T>(
    String historyId,
    Future<T> Function() deleteHistory,
  ) => delegate.deleteImageAndThen(historyId, deleteHistory);

  @override
  Future<T> serializeArchiveDeletion<T>(Future<T> Function() operation) =>
      delegate.serializeArchiveDeletion(operation);

  @override
  Future<bool> hasImageOrDeletionResidue(String historyId) =>
      delegate.hasImageOrDeletionResidue(historyId);

  @override
  Future<ScreenshotTranslationImageStats> inspect() => delegate.inspect();

  @override
  Future<void> clearAll() => delegate.clearAll();
}
