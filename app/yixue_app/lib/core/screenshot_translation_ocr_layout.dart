/// Tesseract OCR text and its optional, image-local layout metadata.
///
/// Layout metadata is deliberately optional. Older saved sessions and IPC
/// messages contain only text; invalid or unsupported layout is ignored so
/// those sessions keep using the existing image-and-text comparison view.
import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

const screenshotTranslationOcrLayoutVersion = 1;
const screenshotTranslationOcrLayoutCoordinateSpace = 'image_pixels';
const screenshotTranslationMaxTsvCharacters = 1024 * 1024;
const screenshotTranslationMaxTsvRows = 30000;
const screenshotTranslationMaxOcrLayoutBlocks = 500;
const screenshotTranslationMaxOcrLayoutTextCharacters = 20000;
const screenshotTranslationMinLayoutConfidence = 25.0;

final class ScreenshotTranslationOcrDocument {
  const ScreenshotTranslationOcrDocument({required this.text, this.layout});

  /// Existing Tesseract TXT output, kept authoritative for translation.
  final String text;
  final ScreenshotTranslationOcrLayout? layout;
}

final class ScreenshotTranslationOcrBlock {
  const ScreenshotTranslationOcrBlock({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String text;
  final int left;
  final int top;
  final int width;
  final int height;

  Map<String, Object?> toMap() => {
    'text': text,
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  static ScreenshotTranslationOcrBlock? tryParse(
    Object? value, {
    required int imageWidth,
    required int imageHeight,
  }) {
    if (value is! Map) return null;
    final text = value['text'];
    final left = value['left'];
    final top = value['top'];
    final width = value['width'];
    final height = value['height'];
    if (text is! String || text.trim().isEmpty || text.length > 5000) {
      return null;
    }
    if (left is! int || top is! int || width is! int || height is! int) {
      return null;
    }
    if (left < 0 || top < 0 || width <= 0 || height <= 0) return null;
    if (left + width > imageWidth || top + height > imageHeight) return null;
    return ScreenshotTranslationOcrBlock(
      text: text,
      left: left,
      top: top,
      width: width,
      height: height,
    );
  }
}

/// Versioned OCR boxes in pixels relative to the captured screenshot image.
final class ScreenshotTranslationOcrLayout {
  const ScreenshotTranslationOcrLayout({
    required this.imageWidth,
    required this.imageHeight,
    required this.sourceText,
    required this.blocks,
  });

  final int imageWidth;
  final int imageHeight;
  final String sourceText;
  final List<ScreenshotTranslationOcrBlock> blocks;

  Map<String, Object?> toMap() => {
    'version': screenshotTranslationOcrLayoutVersion,
    'coordinateSpace': screenshotTranslationOcrLayoutCoordinateSpace,
    'imageWidth': imageWidth,
    'imageHeight': imageHeight,
    'sourceText': sourceText,
    'blocks': blocks.map((block) => block.toMap()).toList(growable: false),
  };

  /// Returns null for old, malformed, oversized, or out-of-image metadata.
  /// This keeps a bad optional layout from breaking the existing text flow.
  static ScreenshotTranslationOcrLayout? tryParse(Object? value) {
    if (value is! Map ||
        value['version'] != screenshotTranslationOcrLayoutVersion ||
        value['coordinateSpace'] !=
            screenshotTranslationOcrLayoutCoordinateSpace) {
      return null;
    }
    final imageWidth = value['imageWidth'];
    final imageHeight = value['imageHeight'];
    final sourceText = value['sourceText'];
    final rawBlocks = value['blocks'];
    if (imageWidth is! int ||
        imageHeight is! int ||
        imageWidth <= 0 ||
        imageHeight <= 0 ||
        imageWidth > 100000 ||
        imageHeight > 100000 ||
        sourceText is! String ||
        sourceText.isEmpty ||
        sourceText.length > screenshotTranslationMaxOcrLayoutTextCharacters ||
        rawBlocks is! List ||
        rawBlocks.isEmpty ||
        rawBlocks.length > screenshotTranslationMaxOcrLayoutBlocks) {
      return null;
    }

    final blocks = <ScreenshotTranslationOcrBlock>[];
    for (final rawBlock in rawBlocks) {
      final block = ScreenshotTranslationOcrBlock.tryParse(
        rawBlock,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
      if (block == null) return null;
      blocks.add(block);
    }
    if (blocks.map((block) => block.text).join('\n\n') != sourceText) {
      return null;
    }
    return ScreenshotTranslationOcrLayout(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      sourceText: sourceText,
      blocks: List.unmodifiable(blocks),
    );
  }
}

/// Extracts conservative line/block boxes from Tesseract's TSV output.
///
/// Any malformed, low-confidence, multi-page, or unbounded input returns null;
/// callers should still keep the normal text result and show image/text panes.
ScreenshotTranslationOcrLayout? parseScreenshotTranslationTesseractTsv(
  String tsv, {
  double minimumConfidence = screenshotTranslationMinLayoutConfidence,
}) {
  if (tsv.isEmpty ||
      tsv.length > screenshotTranslationMaxTsvCharacters ||
      !minimumConfidence.isFinite ||
      minimumConfidence < 0 ||
      minimumConfidence > 100) {
    return null;
  }
  final lines = tsv.split(RegExp(r'\r?\n'));
  final headerLineIndex = lines.indexWhere((line) => line.trim().isNotEmpty);
  if (headerLineIndex < 0) return null;
  final header = lines[headerLineIndex]
      .replaceFirst('\uFEFF', '')
      .split('\t')
      .map((value) => value.trim())
      .toList(growable: false);
  const requiredColumns = <String>[
    'level',
    'page_num',
    'block_num',
    'par_num',
    'line_num',
    'word_num',
    'left',
    'top',
    'width',
    'height',
    'conf',
    'text',
  ];
  final columnIndex = <String, int>{
    for (var index = 0; index < header.length; index++) header[index]: index,
  };
  if (requiredColumns.any((column) => !columnIndex.containsKey(column))) {
    return null;
  }

  int? imageWidth;
  int? imageHeight;
  final words = <_TesseractLayoutWord>[];
  var rowCount = 0;
  for (var index = headerLineIndex + 1; index < lines.length; index++) {
    final row = lines[index];
    if (row.trim().isEmpty) continue;
    if (++rowCount > screenshotTranslationMaxTsvRows) return null;
    final fields = row.split('\t');
    String field(String name) {
      final position = columnIndex[name]!;
      return position < fields.length ? fields[position].trim() : '';
    }

    final level = int.tryParse(field('level'));
    if (level == 1) {
      final page = int.tryParse(field('page_num'));
      final width = int.tryParse(field('width'));
      final height = int.tryParse(field('height'));
      if (page != 1 ||
          width == null ||
          height == null ||
          width <= 0 ||
          height <= 0 ||
          width > 100000 ||
          height > 100000) {
        return null;
      }
      if (imageWidth != null &&
          (imageWidth != width || imageHeight != height)) {
        return null;
      }
      imageWidth = width;
      imageHeight = height;
      continue;
    }
    if (level != 5) continue;

    final page = int.tryParse(field('page_num'));
    final block = int.tryParse(field('block_num'));
    final paragraph = int.tryParse(field('par_num'));
    final lineNumber = int.tryParse(field('line_num'));
    final wordNumber = int.tryParse(field('word_num'));
    final left = int.tryParse(field('left'));
    final top = int.tryParse(field('top'));
    final width = int.tryParse(field('width'));
    final height = int.tryParse(field('height'));
    final confidence = double.tryParse(field('conf'));
    final textColumn = columnIndex['text']!;
    final wordText = textColumn < fields.length
        ? fields.sublist(textColumn).join('\t').trim()
        : '';
    if (page != 1 ||
        block == null ||
        paragraph == null ||
        lineNumber == null ||
        wordNumber == null ||
        left == null ||
        top == null ||
        width == null ||
        height == null ||
        confidence == null ||
        !confidence.isFinite ||
        confidence < minimumConfidence ||
        confidence > 100 ||
        wordText.isEmpty ||
        wordText.length > 500 ||
        left < 0 ||
        top < 0 ||
        width <= 0 ||
        height <= 0) {
      continue;
    }
    // Defer bounds validation until the page row has been read. The TSV page
    // row normally appears first, but parsers should not depend on row order.
    words.add(
      _TesseractLayoutWord(
        block: block,
        paragraph: paragraph,
        line: lineNumber,
        word: wordNumber,
        left: left,
        top: top,
        width: width,
        height: height,
        text: wordText,
      ),
    );
  }

  final width = imageWidth;
  final height = imageHeight;
  if (width == null || height == null || words.isEmpty) return null;
  final boundedWords = words
      .where(
        (word) =>
            word.left + word.width <= width && word.top + word.height <= height,
      )
      .toList();
  if (boundedWords.isEmpty) return null;
  final byBlock = <int, List<_TesseractLayoutWord>>{};
  for (final word in boundedWords) {
    (byBlock[word.block] ??= <_TesseractLayoutWord>[]).add(word);
  }
  if (byBlock.length > screenshotTranslationMaxOcrLayoutBlocks) return null;

  final blocks = <ScreenshotTranslationOcrBlock>[];
  for (final blockNumber in byBlock.keys.toList()..sort()) {
    final blockWords = byBlock[blockNumber]!..sort(_compareWords);
    final groupedLines = <String, List<_TesseractLayoutWord>>{};
    for (final word in blockWords) {
      final key = '${word.paragraph}:${word.line}';
      (groupedLines[key] ??= <_TesseractLayoutWord>[]).add(word);
    }
    final lineEntries = groupedLines.entries.toList()
      ..sort((left, right) {
        final leftParts = left.key.split(':').map(int.parse).toList();
        final rightParts = right.key.split(':').map(int.parse).toList();
        final paragraphOrder = leftParts[0].compareTo(rightParts[0]);
        return paragraphOrder != 0
            ? paragraphOrder
            : leftParts[1].compareTo(rightParts[1]);
      });
    final textLines = <String>[];
    for (final entry in lineEntries) {
      entry.value.sort(_compareWords);
      textLines.add(_joinTesseractWords(entry.value));
    }
    final blockText = textLines.where((line) => line.isNotEmpty).join('\n');
    if (blockText.isEmpty) continue;
    final left = blockWords.map((word) => word.left).reduce(_min);
    final top = blockWords.map((word) => word.top).reduce(_min);
    final right = blockWords.map((word) => word.left + word.width).reduce(_max);
    final bottom = blockWords
        .map((word) => word.top + word.height)
        .reduce(_max);
    blocks.add(
      ScreenshotTranslationOcrBlock(
        text: blockText,
        left: left,
        top: top,
        width: right - left,
        height: bottom - top,
      ),
    );
  }
  if (blocks.isEmpty) return null;
  final sourceText = blocks.map((block) => block.text).join('\n\n');
  if (sourceText.length > screenshotTranslationMaxOcrLayoutTextCharacters) {
    return null;
  }
  return ScreenshotTranslationOcrLayout(
    imageWidth: width,
    imageHeight: height,
    sourceText: sourceText,
    blocks: List.unmodifiable(blocks),
  );
}

/// A potential overlay pairing, only when every translation paragraph carries
/// an explicit identity for the OCR block it translates.
final class ScreenshotTranslationOcrOverlayPair {
  const ScreenshotTranslationOcrOverlayPair({
    required this.block,
    required this.translation,
  });

  final ScreenshotTranslationOcrBlock block;
  final String translation;
}

/// Returns an overlay rectangle constrained to its source OCR block.
///
/// Translation text may be longer than the recognized source. Keeping the
/// overlay inside this rectangle prevents it from covering neighboring text;
/// tap the block to read the full original and translation side by side.
Rect? screenshotTranslationOverlayBounds({
  required ScreenshotTranslationOcrBlock block,
  required Size canvasSize,
  required double scale,
}) {
  if (!scale.isFinite ||
      scale <= 0 ||
      !canvasSize.width.isFinite ||
      !canvasSize.height.isFinite ||
      canvasSize.width <= 0 ||
      canvasSize.height <= 0) {
    return null;
  }

  final left = (block.left * scale).clamp(0.0, canvasSize.width).toDouble();
  final top = (block.top * scale).clamp(0.0, canvasSize.height).toDouble();
  final right = ((block.left + block.width) * scale)
      .clamp(0.0, canvasSize.width)
      .toDouble();
  final bottom = ((block.top + block.height) * scale)
      .clamp(0.0, canvasSize.height)
      .toDouble();
  if (right <= left || bottom <= top) return null;
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Text layout that keeps an in-place translation inside its OCR source box.
///
/// The translation box deliberately does not grow over neighboring text. Its
/// font and padding therefore follow the visible box dimensions, and overflow
/// is summarized with an ellipsis; tapping the box opens the full comparison.
final class ScreenshotTranslationOverlayTextMetrics {
  const ScreenshotTranslationOverlayTextMetrics({
    required this.fontSize,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.maxLines,
  });

  final double fontSize;
  final double horizontalPadding;
  final double verticalPadding;
  final int maxLines;
}

ScreenshotTranslationOverlayTextMetrics screenshotTranslationOverlayTextMetrics(
  Rect bounds,
) {
  if (!bounds.width.isFinite ||
      !bounds.height.isFinite ||
      bounds.width <= 0 ||
      bounds.height <= 0) {
    return const ScreenshotTranslationOverlayTextMetrics(
      fontSize: 1,
      horizontalPadding: 0,
      verticalPadding: 0,
      maxLines: 1,
    );
  }

  // Reserve one logical pixel for each side of the border painted around the
  // overlay. Tiny OCR boxes receive proportionally smaller padding and type.
  final innerWidth = math.max(0.0, bounds.width - 2).toDouble();
  final innerHeight = math.max(0.0, bounds.height - 2).toDouble();
  final horizontalPadding = math.min(4.0, innerWidth * .025).toDouble();
  final verticalPadding = math.min(2.0, innerHeight * .035).toDouble();
  final textWidth = math
      .max(0.0, innerWidth - horizontalPadding * 2)
      .toDouble();
  final textHeight = math
      .max(0.0, innerHeight - verticalPadding * 2)
      .toDouble();
  final fontSize = math
      .min(18.0, math.min(textHeight * .66, textWidth * .88))
      .clamp(.1, 18.0)
      .toDouble();
  final lineHeight = fontSize * 1.12;
  final visibleLineCount = (textHeight / lineHeight).floor();
  final maxLines = visibleLineCount < 1 ? 1 : visibleLineCount;

  return ScreenshotTranslationOverlayTextMetrics(
    fontSize: fontSize,
    horizontalPadding: horizontalPadding,
    verticalPadding: verticalPadding,
    maxLines: maxLines,
  );
}

/// Pairs translated paragraphs with OCR geometry only when block identity is
/// explicit. [translatedSourceBlockIndices] must be produced alongside the
/// translated paragraphs; null means the source relationship is unverified.
List<ScreenshotTranslationOcrOverlayPair>? pairScreenshotTranslationOverlay({
  required String recognizedText,
  required String translatedText,
  required ScreenshotTranslationOcrLayout? layout,
  required List<int>? translatedSourceBlockIndices,
}) {
  if (layout == null ||
      recognizedText != layout.sourceText ||
      ScreenshotTranslationOcrLayout.tryParse(layout.toMap()) == null) {
    return null;
  }
  if (_hasOverlappingScreenshotTranslationOcrBlocks(layout.blocks)) {
    return null;
  }
  final normalizedTranslation = translatedText
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .trim();
  final translatedBlocks = normalizedTranslation
      .split(RegExp(r'\n[\t ]*\n+'))
      .map((block) => block.trim())
      .toList(growable: false);
  final sourceBlockIndices = translatedSourceBlockIndices;
  if (sourceBlockIndices == null ||
      translatedBlocks.length != layout.blocks.length ||
      sourceBlockIndices.length != translatedBlocks.length ||
      sourceBlockIndices.any(
        (index) => index < 0 || index >= layout.blocks.length,
      ) ||
      sourceBlockIndices.toSet().length != layout.blocks.length ||
      translatedBlocks.any((block) => block.trim().isEmpty)) {
    return null;
  }

  // Aggregate translated text has no reliable relationship to OCR geometry.
  // Pair only when the translation pipeline supplies an explicit source block
  // index for each paragraph; never infer identity from paragraph count/order.
  final translationBySourceBlock = <int, String>{};
  for (var index = 0; index < translatedBlocks.length; index++) {
    translationBySourceBlock[sourceBlockIndices[index]] =
        translatedBlocks[index];
  }
  return List.unmodifiable([
    for (var index = 0; index < layout.blocks.length; index++)
      ScreenshotTranslationOcrOverlayPair(
        block: layout.blocks[index],
        translation: translationBySourceBlock[index]!.trim(),
      ),
  ]);
}

bool _hasOverlappingScreenshotTranslationOcrBlocks(
  List<ScreenshotTranslationOcrBlock> blocks,
) {
  for (var index = 0; index < blocks.length; index += 1) {
    final block = blocks[index];
    final bounds = Rect.fromLTWH(
      block.left.toDouble(),
      block.top.toDouble(),
      block.width.toDouble(),
      block.height.toDouble(),
    );
    for (final other in blocks.skip(index + 1)) {
      if (bounds.overlaps(
        Rect.fromLTWH(
          other.left.toDouble(),
          other.top.toDouble(),
          other.width.toDouble(),
          other.height.toDouble(),
        ),
      )) {
        return true;
      }
    }
  }
  return false;
}

final class _TesseractLayoutWord {
  const _TesseractLayoutWord({
    required this.block,
    required this.paragraph,
    required this.line,
    required this.word,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.text,
  });

  final int block;
  final int paragraph;
  final int line;
  final int word;
  final int left;
  final int top;
  final int width;
  final int height;
  final String text;
}

int _compareWords(_TesseractLayoutWord left, _TesseractLayoutWord right) {
  final paragraph = left.paragraph.compareTo(right.paragraph);
  if (paragraph != 0) return paragraph;
  final line = left.line.compareTo(right.line);
  if (line != 0) return line;
  final word = left.word.compareTo(right.word);
  if (word != 0) return word;
  return left.left.compareTo(right.left);
}

String _joinTesseractWords(List<_TesseractLayoutWord> words) {
  final result = StringBuffer();
  String previous = '';
  for (final word in words) {
    if (previous.isNotEmpty && _needsTesseractSpace(previous, word.text)) {
      result.write(' ');
    }
    result.write(word.text);
    previous = word.text;
  }
  return result.toString();
}

bool _needsTesseractSpace(String previous, String next) {
  final previousLast = previous.runes.isEmpty ? 0 : previous.runes.last;
  final nextFirst = next.runes.isEmpty ? 0 : next.runes.first;
  if (_isClosingLayoutPunctuation(nextFirst) ||
      _isOpeningLayoutPunctuation(previousLast)) {
    return false;
  }
  return !(_isCjkLayoutRune(previousLast) && _isCjkLayoutRune(nextFirst));
}

bool _isCjkLayoutRune(int rune) =>
    (rune >= 0x2E80 && rune <= 0x2FFF) ||
    (rune >= 0x3000 && rune <= 0x30FF) ||
    (rune >= 0x3400 && rune <= 0x9FFF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0x20000 && rune <= 0x323AF);

bool _isCjkLayoutPunctuation(int rune) => const <int>{
  0x3001,
  0x3002,
  0x3009,
  0x300B,
  0x300D,
  0x300F,
  0x3011,
  0x3015,
  0xFF09,
  0xFF0C,
  0xFF0E,
  0xFF1A,
  0xFF1B,
  0xFF1F,
  0xFF01,
  0xFF3D,
}.contains(rune);

bool _isClosingLayoutPunctuation(int rune) =>
    _isCjkLayoutPunctuation(rune) ||
    const <int>{
      0x2C,
      0x2E,
      0x3A,
      0x3B,
      0x21,
      0x3F,
      0x29,
      0x5D,
      0x7D,
    }.contains(rune);

bool _isOpeningLayoutPunctuation(int rune) => const <int>{
  0x28,
  0x5B,
  0x7B,
  0x2018,
  0x201C,
  0x3008,
  0x300A,
  0x300C,
  0x300E,
  0x3010,
  0x3014,
  0xFF08,
  0xFF3B,
}.contains(rune);

int _min(int left, int right) => left < right ? left : right;
int _max(int left, int right) => left > right ? left : right;
