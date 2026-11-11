import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/screenshot_translation_ocr_layout.dart';

const _sampleTsv = '''
level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
1\t1\t0\t0\t0\t0\t0\t0\t400\t200\t-1\t
2\t1\t1\t0\t0\t0\t20\t30\t130\t20\t-1\t
5\t1\t1\t1\t1\t1\t20\t30\t40\t20\t95.0\tHello
5\t1\t1\t1\t1\t2\t70\t30\t50\t20\t90.0\tworld
5\t1\t2\t1\t1\t1\t220\t80\t20\t20\t88.0\t中
5\t1\t2\t1\t1\t2\t242\t80\t20\t20\t86.0\t文
5\t1\t2\t1\t1\t3\t270\t80\t20\t20\t12.0\tlow-confidence
5\t1\t2\t1\t1\t4\t390\t80\t20\t20\t90.0\tout-of-bounds
''';

void main() {
  test('translation overlay stays inside the paired OCR source block', () {
    const block = ScreenshotTranslationOcrBlock(
      text: 'Hello world',
      left: 25,
      top: 15,
      width: 30,
      height: 12,
    );

    final bounds = screenshotTranslationOverlayBounds(
      block: block,
      canvasSize: const Size(200, 120),
      scale: 2,
    );

    expect(bounds, const Rect.fromLTWH(50, 30, 60, 24));
  });

  test(
    'overlay text scales to OCR bounds and exposes finite line capacity',
    () {
      final shortLine = screenshotTranslationOverlayTextMetrics(
        const Rect.fromLTWH(0, 0, 100, 20),
      );
      final largeParagraph = screenshotTranslationOverlayTextMetrics(
        const Rect.fromLTWH(0, 0, 500, 120),
      );

      expect(shortLine.fontSize, greaterThan(0));
      expect(shortLine.fontSize, lessThan(largeParagraph.fontSize));
      expect(shortLine.maxLines, greaterThanOrEqualTo(1));
      expect(largeParagraph.fontSize, lessThanOrEqualTo(18));
      expect(largeParagraph.maxLines, greaterThan(shortLine.maxLines));
      expect(shortLine.horizontalPadding, lessThanOrEqualTo(4));
      expect(shortLine.verticalPadding, lessThanOrEqualTo(2));
    },
  );

  test('tiny and invalid overlay bounds return safe one-line metrics', () {
    final tiny = screenshotTranslationOverlayTextMetrics(
      const Rect.fromLTWH(0, 0, .5, .5),
    );
    final invalid = screenshotTranslationOverlayTextMetrics(
      const Rect.fromLTWH(0, 0, double.infinity, 10),
    );

    for (final metrics in [tiny, invalid]) {
      expect(metrics.fontSize.isFinite, isTrue);
      expect(metrics.fontSize, greaterThan(0));
      expect(metrics.horizontalPadding.isFinite, isTrue);
      expect(metrics.verticalPadding.isFinite, isTrue);
      expect(metrics.maxLines, 1);
    }
  });

  test(
    'translation overlay clips to the visible image instead of expanding',
    () {
      const block = ScreenshotTranslationOcrBlock(
        text: 'Edge text',
        left: 40,
        top: 30,
        width: 20,
        height: 10,
      );

      final bounds = screenshotTranslationOverlayBounds(
        block: block,
        canvasSize: const Size(50, 40),
        scale: 1,
      );

      expect(bounds, const Rect.fromLTWH(40, 30, 10, 10));
      expect(
        screenshotTranslationOverlayBounds(
          block: block,
          canvasSize: const Size(50, 40),
          scale: double.nan,
        ),
        isNull,
      );
    },
  );

  test('parses image-local OCR block bounds and filters unsafe word boxes', () {
    final parsedLayout = parseScreenshotTranslationTesseractTsv(_sampleTsv);

    expect(parsedLayout, isNotNull);
    final layout = parsedLayout!;
    expect(layout.imageWidth, 400);
    expect(layout.imageHeight, 200);
    expect(layout.blocks, hasLength(2));
    expect(layout.blocks.first.text, 'Hello world');
    expect(layout.blocks.first.left, 20);
    expect(layout.blocks.first.top, 30);
    expect(layout.blocks.first.width, 100);
    expect(layout.blocks.first.height, 20);
    expect(layout.blocks.last.text, '中文');
    expect(layout.blocks.last.left, 220);
    expect(layout.blocks.last.top, 80);
    expect(layout.sourceText, 'Hello world\n\n中文');
    expect(
      layout.blocks.any((block) => block.text.contains('low-confidence')),
      isFalse,
    );
    expect(
      layout.blocks.any((block) => block.text.contains('out-of-bounds')),
      isFalse,
    );
  });

  test('invalid, oversized and low-confidence-only TSV falls back without layout', () {
    expect(parseScreenshotTranslationTesseractTsv('not tsv'), isNull);
    expect(
      parseScreenshotTranslationTesseractTsv(
        'x' * (screenshotTranslationMaxTsvCharacters + 1),
      ),
      isNull,
    );
    expect(
      parseScreenshotTranslationTesseractTsv(
        '${_sampleTsv.trim().split('\n').first}\n${List<String>.filled(screenshotTranslationMaxTsvRows + 1, 'bad').join('\n')}',
      ),
      isNull,
    );
    expect(
      parseScreenshotTranslationTesseractTsv(
        _sampleTsv
            .replaceAll('95.0\tHello', '5.0\tHello')
            .replaceAll('90.0\tworld', '5.0\tworld')
            .replaceAll('88.0\t中', '5.0\t中')
            .replaceAll('86.0\t文', '5.0\t文'),
      ),
      isNull,
    );
  });

  test('layout map round trips and rejects malformed metadata', () {
    final original = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;
    final restored = ScreenshotTranslationOcrLayout.tryParse(original.toMap());

    expect(restored, isNotNull);
    expect(restored!.sourceText, original.sourceText);
    expect(
      restored.blocks.map((block) => block.toMap()),
      original.blocks.map((block) => block.toMap()),
    );
    expect(
      ScreenshotTranslationOcrLayout.tryParse({
        ...original.toMap(),
        'blocks': [
          {...original.blocks.first.toMap(), 'left': 390},
        ],
        'sourceText': original.blocks.first.text,
      }),
      isNull,
    );
  });

  test(
    'overlay pairing requires exact source and explicit one-to-one identities',
    () {
      final layout = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;

      final pairs = pairScreenshotTranslationOverlay(
        recognizedText: layout.sourceText,
        translatedText: '你好，世界\n\nChinese text',
        layout: layout,
        translatedSourceBlockIndices: const [0, 1],
      );
      expect(pairs, isNotNull);
      expect(pairs!.map((pair) => pair.block.left), [20, 220]);
      expect(pairs.map((pair) => pair.translation), ['你好，世界', 'Chinese text']);
      expect(
        pairScreenshotTranslationOverlay(
          recognizedText: 'edited OCR text',
          translatedText: '译文一\n\n译文二',
          layout: layout,
          translatedSourceBlockIndices: const [0, 1],
        ),
        isNull,
      );
      expect(
        pairScreenshotTranslationOverlay(
          recognizedText: layout.sourceText,
          translatedText: '翻译结果没有保留分段',
          layout: layout,
          translatedSourceBlockIndices: const [0, 1],
        ),
        isNull,
      );
    },
  );

  test('overlapping OCR blocks disable spatial translation overlays', () {
    const layout = ScreenshotTranslationOcrLayout(
      imageWidth: 100,
      imageHeight: 80,
      sourceText: 'First block\n\nSecond block',
      blocks: [
        ScreenshotTranslationOcrBlock(
          text: 'First block',
          left: 10,
          top: 10,
          width: 40,
          height: 20,
        ),
        ScreenshotTranslationOcrBlock(
          text: 'Second block',
          left: 30,
          top: 20,
          width: 35,
          height: 20,
        ),
      ],
    );

    expect(
      pairScreenshotTranslationOverlay(
        recognizedText: layout.sourceText,
        translatedText: '第一段\n\n第二段',
        layout: layout,
        translatedSourceBlockIndices: const [0, 1],
      ),
      isNull,
    );
  });

  test('overlay pairing accepts Windows CRLF paragraph separators', () {
    final layout = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;

    final pairs = pairScreenshotTranslationOverlay(
      recognizedText: layout.sourceText,
      translatedText: '你好，世界\r\n\r\nChinese text\r\n',
      layout: layout,
      translatedSourceBlockIndices: const [0, 1],
    );

    expect(pairs, isNotNull);
    expect(pairs!.map((pair) => pair.translation), ['你好，世界', 'Chinese text']);
  });

  test('overlay pairing accepts bare CR and repeated blank separators', () {
    final layout = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;

    for (final separator in ['\r\r', '\n\n\n']) {
      final pairs = pairScreenshotTranslationOverlay(
        recognizedText: layout.sourceText,
        translatedText: '你好，世界${separator}Chinese text',
        layout: layout,
        translatedSourceBlockIndices: const [0, 1],
      );

      expect(pairs?.map((pair) => pair.translation), [
        '你好，世界',
        'Chinese text',
      ], reason: 'separator ${separator.codeUnits}');
    }
  });

  test('overlay pairing accepts spaces or tabs on blank separator lines', () {
    final layout = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;

    for (final separator in ['\n \n', '\n\t\n']) {
      final pairs = pairScreenshotTranslationOverlay(
        recognizedText: layout.sourceText,
        translatedText: '你好，世界${separator}Chinese text',
        layout: layout,
        translatedSourceBlockIndices: const [0, 1],
      );

      expect(pairs?.map((pair) => pair.translation), [
        '你好，世界',
        'Chinese text',
      ], reason: 'separator ${separator.codeUnits}');
    }
  });

  test(
    'overlay pairing rejects more translation paragraphs than OCR blocks',
    () {
      final layout = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;

      expect(
        pairScreenshotTranslationOverlay(
          recognizedText: layout.sourceText,
          translatedText: '译文一\n\n译文二\n\n多出的一段',
          layout: layout,
          translatedSourceBlockIndices: const [0, 1],
        ),
        isNull,
      );
    },
  );

  test('does not spatially pair same-count paragraphs without OCR block identities', () {
    final layout = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;

    // The paragraphs have the expected count but may have been reordered by
    // the translator. Position-based pairing would place them on the wrong
    // screenshot blocks without source block identities.
    expect(
      pairScreenshotTranslationOverlay(
        recognizedText: layout.sourceText,
        translatedText: 'Chinese text\n\n你好，世界',
        layout: layout,
        translatedSourceBlockIndices: null,
      ),
      isNull,
    );
  });

  test('uses explicit OCR block identities when translation order changes', () {
    final layout = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;

    final pairs = pairScreenshotTranslationOverlay(
      recognizedText: layout.sourceText,
      translatedText: 'Chinese text\n\n你好，世界',
      layout: layout,
      translatedSourceBlockIndices: const [1, 0],
    );

    expect(pairs, isNotNull);
    expect(pairs!.map((pair) => pair.block.text), ['Hello world', '中文']);
    expect(pairs.map((pair) => pair.translation), ['你好，世界', 'Chinese text']);
  });

  test('rejects missing, duplicate, or out-of-range OCR block identities', () {
    final layout = parseScreenshotTranslationTesseractTsv(_sampleTsv)!;

    for (final indices in <List<int>>[
      const [0],
      const [0, 0],
      const [0, 2],
    ]) {
      expect(
        pairScreenshotTranslationOverlay(
          recognizedText: layout.sourceText,
          translatedText: '译文一\n\n译文二',
          layout: layout,
          translatedSourceBlockIndices: indices,
        ),
        isNull,
        reason: 'indices $indices do not uniquely map every OCR block',
      );
    }
  });
}
